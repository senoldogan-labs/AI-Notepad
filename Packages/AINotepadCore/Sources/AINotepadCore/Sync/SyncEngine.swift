import Foundation
import os

private let engineLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SyncEngine")

/// Result of a conditional local write.
public enum SyncStoreWrite: Sendable, Equatable {
    case written
    /// The local copy is no longer the one the engine read (the app wrote it meanwhile, or a long note job runs on the
    /// meeting): nothing was written; the engine tries again on a later pass.
    case changedMeanwhile
}

/// The account's local data as the sync engine reads and writes it. Writes are conditional: `replacing` is the copy the
/// engine read (nil: must not exist yet); the adapter writes only if the stored copy still equals it, so an edit the
/// user made meanwhile is never overwritten. Adapters route writes through the app's "apply to the latest copy" path so
/// the open lists see them; the engine never touches files of the account directly (except its own `.sync` folder).
public protocol SyncLocalStore: Sendable {
    /// Folder names of the meetings on disk, including ones that cannot be read (they are not deleted).
    func meetingIDs() async throws -> Set<String>
    /// A meeting; nil if its folder does not exist.
    func meeting(id: String) async throws -> MeetingRecord?
    /// Writes a meeting into `Sessions/<record.id>` (creating the folder when `previous` is nil). Answers
    /// `changedMeanwhile` when the stored meeting is not `previous`, or a long note job runs on it.
    func writeMeeting(record: MeetingRecord, replacing previous: MeetingRecord?) async throws -> SyncStoreWrite
    /// Removes a meeting deleted on another device (the app moves it to Recently Deleted).
    func deleteMeeting(id: String) async throws
    /// Meetings a long note job (processing, rewriting, editing the note) works on right now: their incoming changes wait
    /// until the job saved its result (`withJobMarks` against the latest copy on disk), then merge three-way.
    func busyMeetingIDs() async -> Set<String>
    /// Ids of the stored Ask conversations.
    func askChatIDs() async throws -> Set<UUID>
    /// An Ask conversation; nil if not stored.
    func askChat(id: UUID) async throws -> AskConversation?
    /// Conditional write of an Ask conversation.
    func writeAskChat(conversation: AskConversation, replacing previous: AskConversation?) async throws -> SyncStoreWrite
    /// Removes an Ask conversation deleted on another device.
    func deleteAskChat(id: UUID) async throws
    /// The people book (empty when there is none).
    func peopleBook() async throws -> PeopleBook
    /// Conditional write of the people book.
    func writePeopleBook(book: PeopleBook, replacing previous: PeopleBook) async throws -> SyncStoreWrite
    /// Saved folders, the user's own Ask recipes and the synced settings.
    func prefs() async throws -> SyncPrefs
    /// Conditional write of the preferences; also `changedMeanwhile` while a recording runs and the write would change a
    /// setting (a recording never changes its settings midway; the download is retried on a later pass).
    func writePrefs(prefs: SyncPrefs, replacing previous: SyncPrefs) async throws -> SyncStoreWrite
}

/// Time source of the engine (field clocks, the debounce wait).
public protocol SyncClock: Sendable {
    func now() -> Date
    func sleep(seconds: Double) async throws
}

/// The system clock.
public struct SystemSyncClock: SyncClock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// Tuning and the user-facing texts the merge writes (the app passes them localized).
public struct SyncEngineSettings: Sendable {
    /// Wait after a local change before uploading (more changes in the meantime go in the same pass).
    public let debounceSeconds: Double
    /// Download → merge → retry rounds of one upload before giving up until the next pass.
    public let maxConflictRounds: Int
    /// Changes per page of the change feed.
    public let pageSize: Int
    /// `NoteVersion.reason` of a note that lost to a rewrite on another device.
    public let conflictReason: String
    /// Line between the two versions of the user's own notes when both devices edited the same lines.
    public let myNotesSeparator: String

    public init(debounceSeconds: Double, maxConflictRounds: Int, pageSize: Int, conflictReason: String, myNotesSeparator: String) {
        self.debounceSeconds = debounceSeconds
        self.maxConflictRounds = maxConflictRounds
        self.pageSize = pageSize
        self.conflictReason = conflictReason
        self.myNotesSeparator = myNotesSeparator
    }
}

/// One object that could not be synced this pass (the rest went on; it is tried again on the next pass).
public struct SyncItemFailure: Sendable, Equatable {
    /// The local item, when the failure happened while uploading.
    public let item: SyncLocalItem?
    /// The server object, when the failure happened while downloading.
    public let objectID: String?
    /// The error's description (no content).
    public let reason: String
}

/// What one sync pass did.
public struct SyncPassReport: Sendable, Equatable {
    /// Objects uploaded (created or changed).
    public let uploaded: Int
    /// Server versions downloaded and applied (including the ones read to resolve a conflict).
    public let downloaded: Int
    /// Local deletions sent to the server.
    public let deletedOnServer: Int
    /// Deletions from other devices applied here.
    public let deletedLocally: Int
    /// Meetings written or removed here (the app reloads them).
    public let changedMeetingIDs: [String]
    /// Ask conversations written or removed here.
    public let changedChatIDs: [UUID]
    public let peopleChanged: Bool
    public let prefsChanged: Bool
    /// Meetings whose own notes were edited on the same lines on two devices (both versions kept; the app says so).
    public let myNotesConflictMeetingIDs: [String]
    /// Downloads waiting for a long note job or a local write to finish.
    public let deferred: Int
    /// The cursor had expired: everything was listed again from the start.
    public let fullResync: Bool
    public let failures: [SyncItemFailure]
}

/// Counters of the running pass.
private struct SyncTally {
    var uploaded: Int = 0
    var downloaded: Int = 0
    var deletedOnServer: Int = 0
    var deletedLocally: Int = 0
    var changedMeetingIDs: [String] = []
    var changedChatIDs: [UUID] = []
    var peopleChanged: Bool = false
    var prefsChanged: Bool = false
    var myNotesConflictMeetingIDs: [String] = []
    var deferred: Int = 0
    var fullResync: Bool = false
    var failures: [SyncItemFailure] = []

    func report() -> SyncPassReport {
        SyncPassReport(
            uploaded: uploaded, downloaded: downloaded, deletedOnServer: deletedOnServer, deletedLocally: deletedLocally,
            changedMeetingIDs: uniqued(items: changedMeetingIDs), changedChatIDs: uniqued(items: changedChatIDs), peopleChanged: peopleChanged,
            prefsChanged: prefsChanged, myNotesConflictMeetingIDs: uniqued(items: myNotesConflictMeetingIDs), deferred: deferred, fullResync: fullResync, failures: failures
        )
    }
}

/// Items in first-seen order without repeats. Pure function.
private func uniqued<Item: Hashable>(items: [Item]) -> [Item] {
    var seen: Set<Item> = []
    return items.filter { seen.insert($0).inserted }
}

/// How an upload ended.
private enum SyncUploadOutcome {
    /// The server holds the local version (uploaded, or the merge equalled the server's).
    case uploaded
    /// The app changed the local copy while merging: try again later.
    case localChangedMeanwhile
    /// Another device deleted the object.
    case deletedRemotely
}

/// Whether a local item is done for now.
private enum SyncPushOutcome {
    case synced
    /// Not uploadable yet (recording, processing, long note job, written meanwhile): stays queued.
    case waiting
}

/// The engine's own files in the account's `.sync` folder: `ledger.json` (`SyncLedger`), `pending.json`
/// (`SyncPending`) and `bases/<object id>.json`, the last version both sides agreed on (the three-way merge base; for
/// `meeting.content` only its digest). Bases are plain JSON on this device only, like the account's other files.
public struct SyncMetadataFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var ledgerFile: URL {
        directory.appending(path: "ledger.json", directoryHint: .notDirectory)
    }

    private var pendingFile: URL {
        directory.appending(path: "pending.json", directoryHint: .notDirectory)
    }

    private var basesDirectory: URL {
        directory.appending(path: "bases", directoryHint: .isDirectory)
    }

    private func baseFile(objectID: String) throws -> URL {
        guard isSyncObjectID(value: objectID) else {
            throw SyncEngineError.invalidObjectID(value: objectID)
        }
        return basesDirectory.appending(path: "\(objectID).json", directoryHint: .notDirectory)
    }

    public func readLedger() throws -> SyncLedger {
        try read(file: ledgerFile, type: SyncLedger.self) ?? .empty
    }

    public func writeLedger(ledger: SyncLedger) throws {
        try write(file: ledgerFile, value: ledger)
    }

    public func readPending() throws -> SyncPending {
        try read(file: pendingFile, type: SyncPending.self) ?? .empty
    }

    public func writePending(pending: SyncPending) throws {
        try write(file: pendingFile, value: pending)
    }

    public func readBase<Value: Decodable>(objectID: String, type: Value.Type) throws -> Value? {
        try read(file: try baseFile(objectID: objectID), type: type)
    }

    public func writeBase<Value: Encodable>(objectID: String, value: Value) throws {
        try write(file: try baseFile(objectID: objectID), value: value)
    }

    public func removeBase(objectID: String) throws {
        let file: URL = try baseFile(objectID: objectID)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw StorageError.deleteFailed(path: file.path, reason: error.localizedDescription)
        }
    }

    /// Removes every base (sync was reset on the server: the old bases describe a wiped copy).
    public func removeAllBases() throws {
        guard FileManager.default.fileExists(atPath: basesDirectory.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: basesDirectory)
        } catch {
            throw StorageError.deleteFailed(path: basesDirectory.path, reason: error.localizedDescription)
        }
    }

    private func read<Value: Decodable>(file: URL, type: Value.Type) throws -> Value? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: file))
        } catch {
            throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
        }
    }

    private func write<Value: Encodable>(file: URL, value: Value) throws {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try canonicalSyncJSON(value: value).write(to: file, options: .atomic)
        } catch {
            throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
        }
    }
}

/// Syncs one account's meetings, Ask conversations, people and preferences with the server, end to end encrypted
/// (doc §8). A pass pulls the change feed (applying newer versions: written directly when there are no local edits,
/// merged three-way otherwise), retries waiting downloads, then uploads local changes (a `409 sync_conflict` downloads
/// the server version, merges and retries with `If-Match` of that version, at most `maxConflictRounds` times), and pulls
/// again after writing. Passes never overlap. A local change queues its item and starts a pass after
/// `debounceSeconds`; the app also calls `syncNow` when it comes to the foreground.
///
/// Only finished meetings sync (`isSyncableMeeting`); a meeting under a long note job keeps its incoming changes waiting
/// until the job saved its result. A meeting from another device lands in the account's `Sessions` folder under its own
/// folder name, with `-2` when a different local meeting has that name. An expired cursor lists everything from the
/// start; objects the full listing lacks were deleted elsewhere (`missingFromFullListing`), unless sync was reset on the
/// server (new epoch), which starts the bookkeeping over and keeps every local item.
///
/// Every outcome (also of the debounced passes) goes to `observer`. Nothing about content, keys or tokens is logged.
public actor SyncEngine {
    private let client: HostedSyncClient
    private let store: any SyncLocalStore
    private let accountKey: SyncAccountKey
    private let userID: String
    private let files: SyncMetadataFiles
    private let clock: any SyncClock
    private let settings: SyncEngineSettings
    private let observer: @Sendable (Result<SyncPassReport, any Error>) -> Void
    private var ledger: SyncLedger
    private var pending: SyncPending
    /// Change counter per queued item: an item re-queued while it uploads stays queued.
    private var generations: [SyncLocalItem: UInt64] = [:]
    private var generationCounter: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var lastPass: Task<Void, Never>?
    private var tally: SyncTally = SyncTally()

    /// Opens the engine with the ledger and queue stored in `files`. `userID` binds every object to the account
    /// (`SyncCrypto` associated data); `client.deviceID` is this device's sync id.
    public init(
        client: HostedSyncClient, store: any SyncLocalStore, accountKey: SyncAccountKey, userID: String, files: SyncMetadataFiles, clock: any SyncClock,
        settings: SyncEngineSettings, observer: @escaping @Sendable (Result<SyncPassReport, any Error>) -> Void
    ) throws {
        self.client = client
        self.store = store
        self.accountKey = accountKey
        self.userID = userID
        self.files = files
        self.clock = clock
        self.settings = settings
        self.observer = observer
        ledger = try files.readLedger()
        pending = try files.readPending()
    }

    // MARK: Public

    /// A local item changed: queue it and sync after the debounce wait.
    public func noteLocalChange(item: SyncLocalItem) throws {
        try enqueue(items: [item])
        scheduleDebouncedPass()
    }

    /// Queues every local item (sync was just turned on, or the bookkeeping was reset); the next pass compares them all.
    public func queueEverything() async throws {
        let meetings: [SyncLocalItem] = try await store.meetingIDs().sorted().map { SyncLocalItem.meeting(id: $0) }
        let chats: [SyncLocalItem] = try await store.askChatIDs().sorted { $0.uuidString < $1.uuidString }.map { SyncLocalItem.askChat(id: $0) }
        try enqueue(items: meetings + chats + [.people, .prefs])
    }

    /// Runs a pass now (after the running one, if any) and returns what it did.
    public func syncNow() async throws -> SyncPassReport {
        let previous: Task<Void, Never>? = lastPass
        let pass: Task<SyncPassReport, any Error> = Task { () async throws -> SyncPassReport in
            await previous?.value
            return try await self.runPass()
        }
        lastPass = Task { () async -> Void in
            _ = await pass.result
        }
        let result: Result<SyncPassReport, any Error> = await pass.result
        if case .failure(let error) = result {
            engineLogger.error("Sync pass failed: \(String(describing: error), privacy: .private)")
        }
        observer(result)
        return try result.get()
    }

    /// Stops the debounce timer and waits for the running pass (before the account is switched or signed out).
    public func stop() async {
        debounceTask?.cancel()
        debounceTask = nil
        await lastPass?.value
    }

    /// The items waiting for upload and the downloads waiting to be retried.
    public func pendingWork() -> SyncPending {
        pending
    }

    /// Local ids of the synced meetings another device recorded: their audio and screen snapshots stay on that device
    /// (phase 1), so the apps neither offer playback nor reprocessing for them. Read from the stored merge bases.
    public func meetingsRecordedElsewhere() throws -> Set<String> {
        var ids: Set<String> = []
        for entry in ledger.entries.values where entry.kind == .meetingState {
            guard let base = try files.readBase(objectID: entry.objectID, type: MeetingSyncState.self) else {
                continue
            }
            if base.originDeviceID != client.deviceID {
                ids.insert(entry.localID)
            }
        }
        return ids
    }

    // MARK: Pass

    private func scheduleDebouncedPass() {
        debounceTask?.cancel()
        let clock: any SyncClock = clock
        let delay: Double = settings.debounceSeconds
        let observer: @Sendable (Result<SyncPassReport, any Error>) -> Void = observer
        debounceTask = Task { [weak self] () async -> Void in
            do {
                try await clock.sleep(seconds: delay)
            } catch is CancellationError {
                // A newer change restarted the wait.
                return
            } catch {
                observer(.failure(error))
                return
            }
            guard let self else {
                return
            }
            do {
                _ = try await self.syncNow()
            } catch {
                // `syncNow` already logged it and handed it to the observer.
            }
        }
    }

    private func runPass() async throws -> SyncPassReport {
        tally = SyncTally()
        let deferredBefore: [String: SyncObjectKind] = pending.deferred
        let listed: Set<String> = try await pull()
        // What this pull listed was just handled (and deferred again if it still has to wait).
        try await retryDeferred(waiting: deferredBefore.filter { !listed.contains($0.key) })
        try await push()
        if tally.uploaded > 0 || tally.deletedOnServer > 0 {
            // Moves the cursor past this device's own writes and picks up what changed meanwhile.
            _ = try await pull()
        }
        let report: SyncPassReport = tally.report()
        engineLogger.info(
            "Sync pass done, uploaded: \(report.uploaded, privacy: .public), downloaded: \(report.downloaded, privacy: .public), deleted on server: \(report.deletedOnServer, privacy: .public), deleted here: \(report.deletedLocally, privacy: .public), deferred: \(report.deferred, privacy: .public), failures: \(report.failures.count, privacy: .public)"
        )
        return report
    }

    // MARK: Pull

    /// Applies the change feed since the cursor; returns the object ids it listed.
    private func pull() async throws -> Set<String> {
        let first: HostedSyncChanges
        do {
            first = try await client.changes(since: ledger.cursor, epoch: ledger.epoch, limit: settings.pageSize)
        } catch HostedSyncError.cursorExpired {
            return try await resyncFromStart()
        }
        if let epoch = ledger.epoch, epoch != first.epoch {
            // A cursor of 0 is never "expired", but the account may have been reset meanwhile.
            return try await resyncFromStart()
        }
        let client: HostedSyncClient = client
        let pageSize: Int = settings.pageSize
        return try await applyPages(first: first) { (since: UInt64, epoch: Int64) async throws -> HostedSyncChanges in
            try await client.changes(since: since, epoch: epoch, limit: pageSize)
        }
    }

    /// Applies the feed from `first` to its end (`nextPage` reads the page after a cursor); returns every object id
    /// listed.
    private func applyPages(
        first: HostedSyncChanges, nextPage: (UInt64, Int64) async throws -> HostedSyncChanges
    ) async throws -> Set<String> {
        var page: HostedSyncChanges = first
        var listed: Set<String> = []
        while true {
            guard page.keyId == accountKey.keyID else {
                throw HostedSyncError.keyMismatch
            }
            listed.formUnion(page.changes.map(\.objectId))
            let applied: (ledger: SyncLedger, actions: [SyncAction]) = applyingChanges(ledger: ledger, changes: page.changes, epoch: page.epoch, cursor: page.cursor)
            for action in applied.actions {
                try await perform(action: action)
            }
            // Entries change only as actions succeed (a failed local delete keeps its entry); the cursor moves last.
            ledger = SyncLedger(epoch: applied.ledger.epoch, cursor: applied.ledger.cursor, entries: ledger.entries)
            try saveProgress()
            guard page.hasMore else {
                return listed
            }
            page = try await nextPage(page.cursor, page.epoch)
        }
    }

    /// A listing from revision 0, paged with `listing=full` (it may pass tombstones purged meanwhile).
    private func applyFullListing(first: HostedSyncChanges) async throws -> Set<String> {
        let client: HostedSyncClient = client
        let pageSize: Int = settings.pageSize
        return try await applyPages(first: first) { (since: UInt64, epoch: Int64) async throws -> HostedSyncChanges in
            try await client.fullListingChanges(since: since, epoch: epoch, limit: pageSize)
        }
    }

    /// Lists everything from revision 0 after `sync_cursor_expired`; returns the object ids listed.
    private func resyncFromStart() async throws -> Set<String> {
        tally.fullResync = true
        let first: HostedSyncChanges = try await client.changes(since: 0, epoch: nil, limit: settings.pageSize)
        guard first.keyId == accountKey.keyID else {
            throw HostedSyncError.keyMismatch
        }
        guard ledger.epoch == first.epoch else {
            // Sync was turned off and on again: the old bookkeeping describes a wiped copy. Nothing local is deleted;
            // everything is compared again (meetings the other device re-uploaded are recognized by their content).
            engineLogger.notice("Sync was reset on the server, starting the bookkeeping over")
            ledger = SyncLedger(epoch: first.epoch, cursor: 0, entries: [:])
            pending = SyncPending(items: pending.items, deferred: [:])
            try files.removeAllBases()
            try saveProgress()
            try await queueEverything()
            return try await applyFullListing(first: first)
        }
        ledger = SyncLedger(epoch: ledger.epoch, cursor: 0, entries: ledger.entries)
        let listed: Set<String> = try await applyFullListing(first: first)
        for entry in missingFromFullListing(ledger: ledger, listedObjectIDs: listed) {
            try await applyRemoteDeleteOfItem(entry: entry)
        }
        try saveProgress()
        return listed
    }

    /// Applies another device's deletion; if removing this one local copy fails, the failure is recorded, the entry kept
    /// and the deletion retried on the next pass (the object is gone on the server, so the retry finds it deleted).
    private func applyRemoteDeleteOfItem(entry: SyncLedgerEntry) async throws {
        do {
            try await applyRemoteDelete(entry: entry)
        } catch where isItemSyncError(error: error) {
            recordFailure(item: nil, objectID: entry.objectID, error: error)
            deferDownload(objectID: entry.objectID, kind: entry.kind)
        }
    }

    private func perform(action: SyncAction) async throws {
        switch action {
        case .forget(let objectID):
            pending = settingDeferred(pending: pending, objectID: objectID, kind: nil)
        case .deleteLocal(let entry):
            try await applyRemoteDeleteOfItem(entry: entry)
        case .download(let objectID, let kind, let revision):
            if let known = ledger.entries[objectID], known.baseRevision >= revision {
                // Already applied in this page (a meeting's content comes with its state).
                return
            }
            pending = settingDeferred(pending: pending, objectID: objectID, kind: nil)
            do {
                if let object = try await fetchObject(objectID: objectID, kind: kind) {
                    try await applyFetched(object: object)
                }
                // Not found: deleted after it was listed; its tombstone follows in the feed.
            } catch where isItemSyncError(error: error) {
                recordFailure(item: nil, objectID: objectID, error: error)
                deferDownload(objectID: objectID, kind: kind)
            }
        }
    }

    /// Downloads that waited (long note job, local write meanwhile, item failure) are tried again.
    private func retryDeferred(waiting: [String: SyncObjectKind]) async throws {
        for (objectID, kind) in waiting.sorted(by: { $0.key < $1.key }) where pending.deferred[objectID] != nil {
            pending = settingDeferred(pending: pending, objectID: objectID, kind: nil)
            do {
                if let object = try await fetchObject(objectID: objectID, kind: kind) {
                    try await applyFetched(object: object)
                } else if let entry = ledger.entries[objectID] {
                    // Its tombstone was already read while the meeting was busy.
                    try await applyRemoteDelete(entry: entry)
                }
            } catch where isItemSyncError(error: error) {
                recordFailure(item: nil, objectID: objectID, error: error)
                deferDownload(objectID: objectID, kind: kind)
            }
            try saveProgress()
        }
    }

    /// The object's current version; nil when it is deleted (or a meeting's content not yet known here).
    private func fetchObject(objectID: String, kind: SyncObjectKind) async throws -> HostedSyncObject? {
        guard isSyncObjectID(value: objectID) else {
            throw SyncEngineError.invalidObjectID(value: objectID)
        }
        if kind == .meetingContent, ledger.entries[objectID] == nil {
            // A new meeting's content is read together with its state (`applyRemoteMeetingState`).
            return nil
        }
        return try await currentObject(objectID: objectID, kind: kind)
    }

    /// GET of an object; nil when deleted.
    private func currentObject(objectID: String, kind: SyncObjectKind) async throws -> HostedSyncObject? {
        let object: HostedSyncObject
        do {
            object = try await client.object(objectID: objectID)
        } catch HostedSyncError.objectNotFound {
            return nil
        }
        guard object.kind == kind else {
            throw SyncEngineError.kindMismatch(objectID: objectID, expected: kind, found: object.kind)
        }
        return object
    }

    private func applyFetched(object: HostedSyncObject) async throws {
        switch object.kind {
        case .meetingState:
            try await applyRemoteMeetingState(objectID: object.objectID, remote: try payload(object: object, type: MeetingSyncState.self), revision: object.revision)
        case .meetingContent:
            try await applyRemoteMeetingContent(objectID: object.objectID, remote: try payload(object: object, type: MeetingSyncContent.self), revision: object.revision)
        case .askChat:
            let remote: AskConversation = try payload(object: object, type: AskChatSyncPayload.self).conversation
            let local: AskConversation? = try await store.askChat(id: remote.id)
            if try await applyIncoming(
                objectID: object.objectID, kind: .askChat, localID: remote.id.uuidString, revision: object.revision, remote: remote, local: local,
                item: .askChat(id: remote.id),
                merge: { (_: AskConversation?, mine: AskConversation, theirs: AskConversation) -> AskConversation in mergeAskConversation(local: mine, remote: theirs) },
                writeLocal: { (merged: AskConversation, previous: AskConversation?) async throws -> SyncStoreWrite in
                    try await self.store.writeAskChat(conversation: merged, replacing: previous)
                }
            ) {
                tally.changedChatIDs.append(remote.id)
            }
        case .people:
            let remote: PeopleBook = try payload(object: object, type: PeopleSyncPayload.self).book
            let local: PeopleBook = try await store.peopleBook()
            if try await applyIncoming(
                objectID: object.objectID, kind: .people, localID: "", revision: object.revision, remote: remote, local: local, item: .people,
                merge: { (base: PeopleBook?, mine: PeopleBook, theirs: PeopleBook) -> PeopleBook in mergePeopleBook(base: base, local: mine, remote: theirs) },
                writeLocal: { (merged: PeopleBook, _: PeopleBook?) async throws -> SyncStoreWrite in try await self.store.writePeopleBook(book: merged, replacing: local) }
            ) {
                tally.peopleChanged = true
            }
        case .prefs:
            let remote: SyncPrefs = try payload(object: object, type: SyncPrefs.self)
            let local: SyncPrefs = try await store.prefs()
            if try await applyIncoming(
                objectID: object.objectID, kind: .prefs, localID: "", revision: object.revision, remote: remote, local: local, item: .prefs,
                merge: { (base: SyncPrefs?, mine: SyncPrefs, theirs: SyncPrefs) -> SyncPrefs in mergeSyncPrefs(base: base, local: mine, remote: theirs) },
                writeLocal: { (merged: SyncPrefs, _: SyncPrefs?) async throws -> SyncStoreWrite in try await self.store.writePrefs(prefs: merged, replacing: local) }
            ) {
                tally.prefsChanged = true
            }
        }
    }

    /// A newer version of a chat, the people book or the prefs: written over an unedited local copy, merged with an
    /// edited one (and queued for upload when the merge adds to the server's). Returns whether the local copy changed.
    private func applyIncoming<Value: Codable & Equatable & Sendable>(
        objectID: String, kind: SyncObjectKind, localID: String, revision: UInt64, remote: Value, local: Value?, item: SyncLocalItem,
        merge: (Value?, Value, Value) -> Value, writeLocal: (Value, Value?) async throws -> SyncStoreWrite
    ) async throws -> Bool {
        let base: Value? = ledger.entries[objectID] == nil ? nil : try files.readBase(objectID: objectID, type: Value.self)
        let resolution: SyncResolution<Value> = resolvingIncoming(base: base, local: local, remote: remote, merge: merge)
        let changed: Bool = resolution.local != local
        if changed {
            guard try await writeLocal(resolution.local, local) == .written else {
                deferDownload(objectID: objectID, kind: kind)
                return false
            }
        }
        try files.writeBase(objectID: objectID, value: remote)
        ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: kind, localID: localID, baseRevision: revision))
        tally.downloaded += 1
        if resolution.needsUpload {
            try enqueue(items: [item])
        }
        return changed
    }

    private func applyRemoteMeetingState(objectID: String, remote: MeetingSyncState, revision: UInt64) async throws {
        guard let entry = ledger.entries[objectID] else {
            try await applyNewRemoteMeeting(objectID: objectID, remote: remote, revision: revision)
            return
        }
        let localID: String = entry.localID
        guard let record = try await store.meeting(id: localID) else {
            // Deleted here and not yet sent: the upload pass deletes it on the server too.
            return
        }
        guard try await isMeetingReady(record: record) else {
            deferDownload(objectID: objectID, kind: .meetingState)
            return
        }
        let base: MeetingSyncState? = try files.readBase(objectID: objectID, type: MeetingSyncState.self)
        let local: MeetingSyncState = try base.map { try uploadMeetingState(record: record, base: $0, now: syncNowDate()) }
            ?? adoptedMeetingState(record: record, remote: remote)
        var conflicted: Bool = false
        let resolution: SyncResolution<MeetingSyncState> = resolvingIncoming(base: base, local: local, remote: remote) {
            (base: MeetingSyncState?, mine: MeetingSyncState, theirs: MeetingSyncState) -> MeetingSyncState in
            let merged: MeetingStateMerge = mergeMeetingState(
                base: base, local: mine, remote: theirs, localDeviceID: client.deviceID, conflictReason: settings.conflictReason,
                myNotesSeparator: settings.myNotesSeparator
            )
            conflicted = merged.myNotesConflicted
            return merged.state
        }
        let updated: MeetingRecord = localMeetingRecord(state: resolution.local, content: meetingSyncContent(record: record), localID: localID, voiceprints: record.voiceprints)
        if updated != record {
            guard try await store.writeMeeting(record: updated, replacing: record) == .written else {
                deferDownload(objectID: objectID, kind: .meetingState)
                return
            }
            tally.changedMeetingIDs.append(localID)
        }
        try files.writeBase(objectID: objectID, value: remote)
        ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: .meetingState, localID: localID, baseRevision: revision))
        tally.downloaded += 1
        if conflicted {
            tally.myNotesConflictMeetingIDs.append(localID)
        }
        if resolution.needsUpload {
            try enqueue(items: [.meeting(id: localID)])
        }
    }

    /// A meeting this device has no ledger entry for: recorded on another device (lands in its own folder, `-2` when a
    /// different local meeting has the name), or this device's own meeting after a bookkeeping reset (same folder and
    /// same transcript: merged without a base).
    private func applyNewRemoteMeeting(objectID: String, remote: MeetingSyncState, revision: UInt64) async throws {
        guard isSafeMeetingFolderName(value: remote.meetingID) else {
            throw SyncEngineError.invalidMeetingFolder(objectID: objectID)
        }
        guard isSyncObjectID(value: remote.contentObjectID) else {
            throw SyncEngineError.invalidObjectID(value: remote.contentObjectID)
        }
        guard let contentObject = try await currentObject(objectID: remote.contentObjectID, kind: .meetingContent) else {
            // Deleted meanwhile: its tombstone follows.
            return
        }
        let content: MeetingSyncContent = try payload(object: contentObject, type: MeetingSyncContent.self)
        let digest: String = try syncDigest(value: content)
        let localIDs: Set<String> = try await store.meetingIDs()
        let mapped: Set<String> = Set(ledger.entries.values.filter { $0.kind == .meetingState }.map(\.localID))
        var localID: String = incomingMeetingFolder(meetingID: remote.meetingID, taken: localIDs.union(mapped))
        var needsUpload: Bool = false
        var conflicted: Bool = false
        if localIDs.contains(remote.meetingID), !mapped.contains(remote.meetingID), let local = try await store.meeting(id: remote.meetingID) {
            guard try await isMeetingReady(record: local) else {
                deferDownload(objectID: objectID, kind: .meetingState)
                return
            }
            if try syncDigest(value: meetingSyncContent(record: local)) == digest {
                let merged: MeetingStateMerge = mergeMeetingState(
                    base: nil, local: adoptedMeetingState(record: local, remote: remote), remote: remote, localDeviceID: client.deviceID,
                    conflictReason: settings.conflictReason, myNotesSeparator: settings.myNotesSeparator
                )
                let updated: MeetingRecord = localMeetingRecord(state: merged.state, content: content, localID: remote.meetingID, voiceprints: local.voiceprints)
                if updated != local {
                    guard try await store.writeMeeting(record: updated, replacing: local) == .written else {
                        deferDownload(objectID: objectID, kind: .meetingState)
                        return
                    }
                }
                localID = remote.meetingID
                needsUpload = merged.state != remote
                conflicted = merged.myNotesConflicted
            }
        }
        if localID != remote.meetingID || !localIDs.contains(localID) {
            let record: MeetingRecord = localMeetingRecord(state: remote, content: content, localID: localID, voiceprints: nil)
            guard try await store.writeMeeting(record: record, replacing: nil) == .written else {
                deferDownload(objectID: objectID, kind: .meetingState)
                return
            }
        }
        try files.writeBase(objectID: objectID, value: remote)
        try files.writeBase(objectID: remote.contentObjectID, value: SyncContentBase(digest: digest))
        ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: .meetingState, localID: localID, baseRevision: revision))
        ledger = recordingRevision(
            ledger: ledger, entry: SyncLedgerEntry(objectID: remote.contentObjectID, kind: .meetingContent, localID: localID, baseRevision: contentObject.revision)
        )
        tally.downloaded += 2
        tally.changedMeetingIDs.append(localID)
        if conflicted {
            tally.myNotesConflictMeetingIDs.append(localID)
        }
        if needsUpload {
            try enqueue(items: [.meeting(id: localID)])
        }
    }

    /// Another device's processing result for a known meeting (reprocessing on the recording device).
    private func applyRemoteMeetingContent(objectID: String, remote: MeetingSyncContent, revision: UInt64) async throws {
        guard let entry = ledger.entries[objectID] else {
            return
        }
        guard let record = try await store.meeting(id: entry.localID) else {
            return
        }
        guard try await isMeetingReady(record: record) else {
            deferDownload(objectID: objectID, kind: .meetingContent)
            return
        }
        let base: SyncContentBase? = try files.readBase(objectID: objectID, type: SyncContentBase.self)
        let localDigest: String = try syncDigest(value: meetingSyncContent(record: record))
        let remoteDigest: String = try syncDigest(value: remote)
        if let base, base.digest != localDigest, localDigest != remoteDigest {
            // Processed again here too: the later upload wins, and this device's goes next.
            try enqueue(items: [.meeting(id: entry.localID)])
        } else if localDigest != remoteDigest {
            guard try await store.writeMeeting(record: replacingContent(record: record, content: remote), replacing: record) == .written else {
                deferDownload(objectID: objectID, kind: .meetingContent)
                return
            }
            tally.changedMeetingIDs.append(entry.localID)
        }
        try files.writeBase(objectID: objectID, value: SyncContentBase(digest: remoteDigest))
        ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: .meetingContent, localID: entry.localID, baseRevision: revision))
        tally.downloaded += 1
    }

    /// An object deleted on another device: the local copy goes too (a meeting to Recently Deleted, by the app).
    private func applyRemoteDelete(entry: SyncLedgerEntry) async throws {
        switch entry.kind {
        case .meetingState:
            if let record = try await store.meeting(id: entry.localID) {
                guard try await isMeetingReady(record: record) else {
                    ledger = recordingRevision(ledger: ledger, entry: entry)
                    deferDownload(objectID: entry.objectID, kind: entry.kind)
                    return
                }
                try await store.deleteMeeting(id: entry.localID)
                tally.deletedLocally += 1
                tally.changedMeetingIDs.append(entry.localID)
            }
            if let content = ledgerEntry(ledger: ledger, kind: .meetingContent, localID: entry.localID) {
                try forget(objectID: content.objectID)
            }
        case .askChat:
            if let id = UUID(uuidString: entry.localID), try await store.askChat(id: id) != nil {
                try await store.deleteAskChat(id: id)
                tally.deletedLocally += 1
                tally.changedChatIDs.append(id)
            }
        case .meetingContent, .people, .prefs:
            // Content goes with its meeting's state; the account objects are only removed by turning sync off.
            break
        }
        try forget(objectID: entry.objectID)
    }

    // MARK: Push

    private func push() async throws {
        let items: [SyncLocalItem] = syncPushItems(
            pending: pending.items, ledger: ledger, localMeetingIDs: try await store.meetingIDs(), localChatIDs: try await store.askChatIDs()
        )
        for item in items {
            let generation: UInt64? = generations[item]
            let outcome: SyncPushOutcome
            do {
                outcome = try await pushItem(item: item)
            } catch where isItemSyncError(error: error) {
                recordFailure(item: item, objectID: nil, error: error)
                continue
            }
            if outcome == .synced, generations[item] == generation {
                pending = removingPendingItem(pending: pending, item: item)
                generations[item] = nil
            }
            try saveProgress()
        }
    }

    private func pushItem(item: SyncLocalItem) async throws -> SyncPushOutcome {
        switch item {
        case .meeting(let id):
            return try await pushMeeting(id: id)
        case .askChat(let id):
            return try await pushAskChat(id: id)
        case .people:
            return try await pushPeople()
        case .prefs:
            return try await pushPrefs()
        }
    }

    private func pushMeeting(id: String) async throws -> SyncPushOutcome {
        let stateEntry: SyncLedgerEntry? = ledgerEntry(ledger: ledger, kind: .meetingState, localID: id)
        let contentEntry: SyncLedgerEntry? = ledgerEntry(ledger: ledger, kind: .meetingContent, localID: id)
        // The onboarding sample meeting (`isSampleMeeting`) never syncs: like a deleted meeting, nothing of it stays on the
        // server.
        guard let record = try await store.meeting(id: id), !record.isSampleMeeting else {
            for entry in [stateEntry, contentEntry].compactMap({ $0 }) {
                try await deleteOnServer(entry: entry)
            }
            return .synced
        }
        guard try await isMeetingReady(record: record) else {
            return .waiting
        }
        let base: MeetingSyncState?
        if let stateEntry {
            guard let stored = try files.readBase(objectID: stateEntry.objectID, type: MeetingSyncState.self) else {
                // The base is gone: merge with the server copy first (without a base), upload on the next pass.
                if let object = try await currentObject(objectID: stateEntry.objectID, kind: .meetingState) {
                    try await applyRemoteMeetingState(objectID: object.objectID, remote: try payload(object: object, type: MeetingSyncState.self), revision: object.revision)
                } else {
                    try await applyRemoteDelete(entry: stateEntry)
                }
                return .waiting
            }
            base = stored
        } else {
            base = nil
        }
        let now: Date = syncNowDate()
        // A new meeting whose content went up but whose state did not (the pass stopped) reuses that content object.
        let contentID: String = base?.contentObjectID ?? contentEntry?.objectID ?? newSyncObjectID()
        let knownContent: SyncLedgerEntry? = contentEntry?.objectID == contentID ? contentEntry : nil
        let stateID: String = stateEntry?.objectID ?? newSyncObjectID()
        let state: MeetingSyncState = try base.map { try uploadMeetingState(record: record, base: $0, now: now) }
            ?? newMeetingState(record: record, contentObjectID: contentID, originDeviceID: client.deviceID, now: now)
        let content: MeetingSyncContent = meetingSyncContent(record: record)
        let digest: String = try syncDigest(value: content)
        let contentBase: SyncContentBase? = knownContent == nil ? nil : try files.readBase(objectID: contentID, type: SyncContentBase.self)
        // Content first: a device that sees the new state can read its content.
        if contentBase?.digest != digest {
            try await uploadContent(objectID: contentID, localID: id, content: content, digest: digest, startRevision: knownContent?.baseRevision ?? 0)
        }
        guard stateEntry == nil || state != base else {
            return .synced
        }
        var current: MeetingRecord = record
        var conflicted: Bool = false
        let outcome: SyncUploadOutcome = try await uploadMerging(
            objectID: stateID, kind: .meetingState, localID: id, startRevision: stateEntry?.baseRevision ?? 0, base: base, local: state,
            wrap: { (value: MeetingSyncState) -> MeetingSyncState in value }, unwrap: { (value: MeetingSyncState) -> MeetingSyncState in value },
            merge: { (base: MeetingSyncState?, mine: MeetingSyncState, theirs: MeetingSyncState) -> MeetingSyncState in
                let merged: MeetingStateMerge = mergeMeetingState(
                    base: base, local: mine, remote: theirs, localDeviceID: client.deviceID, conflictReason: settings.conflictReason,
                    myNotesSeparator: settings.myNotesSeparator
                )
                conflicted = conflicted || merged.myNotesConflicted
                return merged.state
            },
            writeLocal: { (merged: MeetingSyncState) async throws -> SyncStoreWrite in
                let updated: MeetingRecord = localMeetingRecord(state: merged, content: content, localID: id, voiceprints: record.voiceprints)
                let written: SyncStoreWrite = try await self.store.writeMeeting(record: updated, replacing: current)
                if written == .written {
                    current = updated
                }
                return written
            }
        )
        if current != record {
            tally.changedMeetingIDs.append(id)
        }
        if conflicted {
            tally.myNotesConflictMeetingIDs.append(id)
        }
        switch outcome {
        case .uploaded:
            return .synced
        case .localChangedMeanwhile:
            return .waiting
        case .deletedRemotely:
            // Deleted on another device while edited here: the deletion wins (the app keeps it in Recently Deleted).
            if let stateEntry {
                try await applyRemoteDelete(entry: stateEntry)
            }
            return .synced
        }
    }

    /// Uploads a meeting's content; on a conflict the server version is read: equal → nothing to do, different → this
    /// device's later processing wins (last writer).
    private func uploadContent(objectID: String, localID: String, content: MeetingSyncContent, digest: String, startRevision: UInt64) async throws {
        var revision: UInt64 = startRevision
        for _ in 0..<settings.maxConflictRounds {
            do {
                let written: UInt64 = try await put(objectID: objectID, kind: .meetingContent, baseRevision: revision, value: content)
                try files.writeBase(objectID: objectID, value: SyncContentBase(digest: digest))
                ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: .meetingContent, localID: localID, baseRevision: written))
                tally.uploaded += 1
                return
            } catch HostedSyncError.conflict {
                guard let object = try await currentObject(objectID: objectID, kind: .meetingContent) else {
                    // Deleted on another device: the meeting's state upload finds it deleted too.
                    return
                }
                if try syncDigest(value: try payload(object: object, type: MeetingSyncContent.self)) == digest {
                    try files.writeBase(objectID: objectID, value: SyncContentBase(digest: digest))
                    ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: .meetingContent, localID: localID, baseRevision: object.revision))
                    return
                }
                revision = object.revision
            }
        }
        throw SyncEngineError.conflictRoundsExhausted(objectID: objectID, rounds: settings.maxConflictRounds)
    }

    /// Uploads `local` replacing `startRevision`; a conflict downloads the server version, merges it three-way with
    /// `base`, writes the merge locally (conditionally) and retries with the server's revision. Bases hold `Value`; the
    /// server gets `wrap(value)` (the schema-versioned payload).
    private func uploadMerging<Value: Codable & Equatable & Sendable, Payload: Codable>(
        objectID: String, kind: SyncObjectKind, localID: String, startRevision: UInt64, base: Value?, local: Value, wrap: (Value) -> Payload,
        unwrap: (Payload) -> Value, merge: (Value?, Value, Value) -> Value, writeLocal: (Value) async throws -> SyncStoreWrite
    ) async throws -> SyncUploadOutcome {
        var revision: UInt64 = startRevision
        var currentBase: Value? = base
        var current: Value = local
        for _ in 0..<settings.maxConflictRounds {
            do {
                let written: UInt64 = try await put(objectID: objectID, kind: kind, baseRevision: revision, value: wrap(current))
                try files.writeBase(objectID: objectID, value: current)
                ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: kind, localID: localID, baseRevision: written))
                tally.uploaded += 1
                return .uploaded
            } catch HostedSyncError.conflict {
                guard let object = try await currentObject(objectID: objectID, kind: kind) else {
                    return .deletedRemotely
                }
                let remote: Value = unwrap(try payload(object: object, type: Payload.self))
                tally.downloaded += 1
                let merged: Value = merge(currentBase, current, remote)
                if merged != current {
                    guard try await writeLocal(merged) == .written else {
                        return .localChangedMeanwhile
                    }
                }
                currentBase = remote
                current = merged
                revision = object.revision
                if merged == remote {
                    try files.writeBase(objectID: objectID, value: remote)
                    ledger = recordingRevision(ledger: ledger, entry: SyncLedgerEntry(objectID: objectID, kind: kind, localID: localID, baseRevision: revision))
                    return .uploaded
                }
            }
        }
        throw SyncEngineError.conflictRoundsExhausted(objectID: objectID, rounds: settings.maxConflictRounds)
    }

    private func pushAskChat(id: UUID) async throws -> SyncPushOutcome {
        let objectID: String = askChatSyncObjectID(accountKey: accountKey, chatID: id)
        let entry: SyncLedgerEntry? = ledger.entries[objectID]
        guard let local = try await store.askChat(id: id) else {
            if let entry {
                try await deleteOnServer(entry: entry)
            }
            return .synced
        }
        let base: AskConversation? = entry == nil ? nil : try files.readBase(objectID: objectID, type: AskConversation.self)
        if entry != nil, base == local {
            return .synced
        }
        var current: AskConversation = local
        let outcome: SyncUploadOutcome = try await uploadMerging(
            objectID: objectID, kind: .askChat, localID: id.uuidString, startRevision: entry?.baseRevision ?? 0, base: base, local: local,
            wrap: { (value: AskConversation) -> AskChatSyncPayload in AskChatSyncPayload(schema: syncPayloadSchema, conversation: value) },
            unwrap: { (payload: AskChatSyncPayload) -> AskConversation in payload.conversation },
            merge: { (_: AskConversation?, mine: AskConversation, theirs: AskConversation) -> AskConversation in mergeAskConversation(local: mine, remote: theirs) },
            writeLocal: { (merged: AskConversation) async throws -> SyncStoreWrite in
                let written: SyncStoreWrite = try await self.store.writeAskChat(conversation: merged, replacing: current)
                if written == .written {
                    current = merged
                }
                return written
            }
        )
        if current != local {
            tally.changedChatIDs.append(id)
        }
        switch outcome {
        case .uploaded:
            return .synced
        case .localChangedMeanwhile:
            return .waiting
        case .deletedRemotely:
            try await applyRemoteDelete(entry: entry ?? SyncLedgerEntry(objectID: objectID, kind: .askChat, localID: id.uuidString, baseRevision: 0))
            return .synced
        }
    }

    private func pushPeople() async throws -> SyncPushOutcome {
        let objectID: String = singletonSyncObjectID(accountKey: accountKey, kind: .people)
        let entry: SyncLedgerEntry? = ledger.entries[objectID]
        let local: PeopleBook = try await store.peopleBook()
        let base: PeopleBook? = entry == nil ? nil : try files.readBase(objectID: objectID, type: PeopleBook.self)
        if entry == nil ? local == .empty : base == local {
            return .synced
        }
        var current: PeopleBook = local
        let outcome: SyncUploadOutcome = try await uploadMerging(
            objectID: objectID, kind: .people, localID: "", startRevision: entry?.baseRevision ?? 0, base: base, local: local,
            wrap: { (book: PeopleBook) -> PeopleSyncPayload in PeopleSyncPayload(schema: syncPayloadSchema, book: book) },
            unwrap: { (payload: PeopleSyncPayload) -> PeopleBook in payload.book },
            merge: { (base: PeopleBook?, mine: PeopleBook, theirs: PeopleBook) -> PeopleBook in mergePeopleBook(base: base, local: mine, remote: theirs) },
            writeLocal: { (merged: PeopleBook) async throws -> SyncStoreWrite in
                let written: SyncStoreWrite = try await self.store.writePeopleBook(book: merged, replacing: current)
                if written == .written {
                    current = merged
                }
                return written
            }
        )
        tally.peopleChanged = tally.peopleChanged || current != local
        return try singletonOutcome(outcome: outcome, kind: .people)
    }

    private func pushPrefs() async throws -> SyncPushOutcome {
        let objectID: String = singletonSyncObjectID(accountKey: accountKey, kind: .prefs)
        let entry: SyncLedgerEntry? = ledger.entries[objectID]
        let local: SyncPrefs = try await store.prefs()
        let base: SyncPrefs? = entry == nil ? nil : try files.readBase(objectID: objectID, type: SyncPrefs.self)
        if entry == nil ? isEmptySyncPrefs(prefs: local) : base == local {
            return .synced
        }
        var current: SyncPrefs = local
        let outcome: SyncUploadOutcome = try await uploadMerging(
            objectID: objectID, kind: .prefs, localID: "", startRevision: entry?.baseRevision ?? 0, base: base, local: local,
            wrap: { (value: SyncPrefs) -> SyncPrefs in value }, unwrap: { (value: SyncPrefs) -> SyncPrefs in value },
            merge: { (base: SyncPrefs?, mine: SyncPrefs, theirs: SyncPrefs) -> SyncPrefs in mergeSyncPrefs(base: base, local: mine, remote: theirs) },
            writeLocal: { (merged: SyncPrefs) async throws -> SyncStoreWrite in
                let written: SyncStoreWrite = try await self.store.writePrefs(prefs: merged, replacing: current)
                if written == .written {
                    current = merged
                }
                return written
            }
        )
        tally.prefsChanged = tally.prefsChanged || current != local
        return try singletonOutcome(outcome: outcome, kind: .prefs)
    }

    private func singletonOutcome(outcome: SyncUploadOutcome, kind: SyncObjectKind) throws -> SyncPushOutcome {
        switch outcome {
        case .uploaded:
            return .synced
        case .localChangedMeanwhile:
            return .waiting
        case .deletedRemotely:
            throw SyncEngineError.singletonDeleted(kind: kind)
        }
    }

    /// Deletes an object on the server (it becomes a tombstone the other devices apply); a newer version there is
    /// deleted too (a deletion wins over an edit), an object already gone is fine.
    private func deleteOnServer(entry: SyncLedgerEntry) async throws {
        var revision: UInt64 = entry.baseRevision
        for _ in 0..<settings.maxConflictRounds {
            do {
                _ = try await client.delete(objectID: entry.objectID, baseRevision: revision)
                tally.deletedOnServer += 1
                try forget(objectID: entry.objectID)
                return
            } catch HostedSyncError.conflict {
                guard let object = try await currentObject(objectID: entry.objectID, kind: entry.kind) else {
                    try forget(objectID: entry.objectID)
                    return
                }
                revision = object.revision
            } catch HostedSyncError.objectNotFound {
                try forget(objectID: entry.objectID)
                return
            }
        }
        throw SyncEngineError.conflictRoundsExhausted(objectID: entry.objectID, rounds: settings.maxConflictRounds)
    }

    // MARK: Helpers

    private func put<Value: Encodable>(objectID: String, kind: SyncObjectKind, baseRevision: UInt64, value: Value) async throws -> UInt64 {
        let blob: Data = try sealSyncObject(
            payload: try encodeSyncPayload(value: value), accountKey: accountKey, userID: userID, objectID: objectID, kind: kind, baseRevision: baseRevision
        )
        return try await client.put(objectID: objectID, kind: kind, baseRevision: baseRevision, blob: blob)
    }

    private func payload<Value: Decodable>(object: HostedSyncObject, type: Value.Type) throws -> Value {
        let opened: Data = try openSyncObject(
            blob: object.blob, accountKey: accountKey, userID: userID, objectID: object.objectID, kind: object.kind, servedRevision: object.revision
        )
        return try decodeSyncPayload(type: type, data: opened)
    }

    /// Whether a meeting may be written or uploaded now: finished, and no long note job runs on it.
    private func isMeetingReady(record: MeetingRecord) async throws -> Bool {
        guard isSyncableMeeting(record: record) else {
            return false
        }
        return await !store.busyMeetingIDs().contains(record.id)
    }

    private func syncNowDate() -> Date {
        syncWholeSecond(date: clock.now())
    }

    private func enqueue(items: [SyncLocalItem]) throws {
        for item in items {
            generationCounter += 1
            generations[item] = generationCounter
        }
        pending = addingPendingItems(pending: pending, added: items)
        try files.writePending(pending: pending)
    }

    private func deferDownload(objectID: String, kind: SyncObjectKind) {
        pending = settingDeferred(pending: pending, objectID: objectID, kind: kind)
        tally.deferred += 1
    }

    private func forget(objectID: String) throws {
        ledger = removingEntry(ledger: ledger, objectID: objectID)
        pending = settingDeferred(pending: pending, objectID: objectID, kind: nil)
        try files.removeBase(objectID: objectID)
    }

    private func recordFailure(item: SyncLocalItem?, objectID: String?, error: any Error) {
        engineLogger.error("Sync item failed, will retry: \(String(describing: error), privacy: .private)")
        tally.failures.append(SyncItemFailure(item: item, objectID: objectID, reason: String(describing: error)))
    }

    private func saveProgress() throws {
        try files.writeLedger(ledger: ledger)
        try files.writePending(pending: pending)
    }
}
