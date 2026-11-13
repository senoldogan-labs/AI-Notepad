import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

// Local server (`wrangler dev`) only; prepared with `Process`, so macOS only. Enable with `AINOTEPAD_HOSTED_E2E=1` and
// `AINOTEPAD_HOSTED_BASE` (see `HostedE2ETests`).
#if os(macOS)

/// A second session (refresh family) of an existing local user: the account's second device.
private func insertDeviceSession(userID: String, refreshToken: String) throws {
    let hash: String = SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    let now: Int = nowMs()
    let familyID: String = "e2e-\(UUID().uuidString.lowercased())"
    try executeLocalD1(sql: [
        "INSERT INTO refresh_families (id, user_id, created_at) VALUES ('\(familyID)', '\(userID)', \(now));",
        "INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES ('\(hash)', '\(familyID)', \(now), \(now + 24 * 3_600_000));",
    ].joined(separator: " "))
}

/// One simulated device: its own session and sync client, sharing the account.
private struct SyncDevice {
    let client: HostedSyncClient
    let deviceID: String
}

private func device(baseURL: URL, userID: String, refreshToken: String) async throws -> SyncDevice {
    let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(accessToken: "gecersiz", refreshToken: refreshToken, accessExpiresAt: Date.distantPast, userId: userID))
    let session: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
    // The app agrees to the AI disclosure before any AI request (see `HostedAIConsent.swift`).
    session.setAIConsent(granted: true)
    _ = try await awaitingAuthLimit { try await session.validAccessToken() }
    let deviceID: String = UUID().uuidString.lowercased()
    return SyncDevice(client: HostedSyncClient(baseURL: baseURL, credentials: session, deviceID: deviceID, userID: userID), deviceID: deviceID)
}

/// `sync_objects` row as the server stores it.
private struct ObjectRow: Decodable, Equatable {
    let object_id: String
    let kind: String
    let rev: Int
    let size: Int
    let deleted: Int
}

/// Every byte under the local server's persisted state (D1 SQLite files and R2 blobs) contains none of `markers`.
private func localServerStateContainsNone(of markers: [String]) throws -> Bool {
    let state: URL = serverDirectory().appending(path: ".wrangler/state", directoryHint: .isDirectory)
    let files: [URL] = (FileManager.default.enumerator(at: state, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL]) ?? []
    #expect(!files.isEmpty, "wrangler dev keeps its local state under server/.wrangler/state")
    for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let data: Data = try Data(contentsOf: file)
        if markers.contains(where: { data.range(of: Data($0.utf8)) != nil }) {
            Issue.record("Plaintext found in server state: \(file.lastPathComponent)")
            return false
        }
    }
    return true
}

/// Seals and uploads a payload; returns the new revision.
private func upload<Value: Encodable>(
    device: SyncDevice, value: Value, key: SyncAccountKey, userID: String, objectID: String, kind: SyncObjectKind, baseRevision: UInt64
) async throws -> UInt64 {
    let blob: Data = try sealSyncObject(payload: try encodeSyncPayload(value: value), accountKey: key, userID: userID, objectID: objectID, kind: kind, baseRevision: baseRevision)
    return try await device.client.put(objectID: objectID, kind: kind, baseRevision: baseRevision, blob: blob)
}

/// Downloads, verifies and decodes an object.
private func download<Value: Decodable>(device: SyncDevice, type: Value.Type, key: SyncAccountKey, userID: String, objectID: String) async throws -> (value: Value, revision: UInt64) {
    let object: HostedSyncObject = try await device.client.object(objectID: objectID)
    let payload: Data = try openSyncObject(blob: object.blob, accountKey: key, userID: userID, objectID: objectID, kind: object.kind, servedRevision: object.revision)
    return (try decodeSyncPayload(type: type, data: payload), object.revision)
}

/// A test device's long note jobs, and a one-shot hook run at the next "busy" query: it lands another device's write
/// between this device's pull and its upload (the `409 sync_conflict` path).
private final class DeviceJobs: Sendable {
    private let busy: Mutex<Set<String>> = Mutex([])
    private let hook: Mutex<(@Sendable () async -> Void)?> = Mutex(nil)

    func set(busy ids: Set<String>) {
        busy.withLock { $0 = ids }
    }

    func arm(hook newHook: @escaping @Sendable () async -> Void) {
        hook.withLock { $0 = newHook }
    }

    func query() async -> Set<String> {
        let armed: (@Sendable () async -> Void)? = hook.withLock { (current: inout (@Sendable () async -> Void)?) -> (@Sendable () async -> Void)? in
            let taken: (@Sendable () async -> Void)? = current
            current = nil
            return taken
        }
        if let armed {
            await armed()
        }
        return busy.withLock { $0 }
    }
}

/// Forwards pass outcomes to a stream once armed (passes before that are not the ones a step waits for).
private final class PassWatcher: Sendable {
    private let sink: Mutex<AsyncStream<Result<SyncPassReport, any Error>>.Continuation?> = Mutex(nil)

    func arm() -> AsyncStream<Result<SyncPassReport, any Error>> {
        let (stream, continuation): (AsyncStream<Result<SyncPassReport, any Error>>, AsyncStream<Result<SyncPassReport, any Error>>.Continuation) =
            AsyncStream.makeStream(of: Result<SyncPassReport, any Error>.self)
        sink.withLock { $0 = continuation }
        return stream
    }

    func deliver(result: Result<SyncPassReport, any Error>) {
        sink.withLock { $0 }?.yield(result)
    }
}

/// `SyncPrefs` as the first sync release wrote it (an older app: no settings field).
private struct OlderClientPrefs: Codable {
    let schema: Int
    let folders: [String]
    let recipes: [Recipe]
}

/// Whether a test device records right now (read on the main actor, as the apps' recorders are).
@MainActor
private final class RecordingSwitch {
    var isOn: Bool = false
}

/// One device running the sync engine over its own temporary account folder and preferences domains.
private struct EngineDevice {
    let engine: SyncEngine
    let store: SyncAccountFolderStore
    let jobs: DeviceJobs
    let recording: RecordingSwitch

    var settingsDomains: SyncedSettingsDomains {
        SyncedSettingsDomains(valuesDomain: store.valuesDomain, accountSuite: store.defaultsSuite)
    }

    func values() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: store.valuesDomain))
    }

    /// What the app does on every preferences change: stamps the user's setting changes; returns the changed keys.
    func recordSettingChanges(now: Date) async throws -> [String] {
        let domains: SyncedSettingsDomains = settingsDomains
        return try await MainActor.run { () throws -> [String] in try recordSyncedSettingChanges(domains: domains, now: now) }
    }

    func removeDomains() {
        for domain in [store.defaultsSuite, store.valuesDomain] {
            UserDefaults().removePersistentDomain(forName: domain)
        }
    }
}

private let e2eSyncSettings: SyncEngineSettings = SyncEngineSettings(
    debounceSeconds: 0.2, maxConflictRounds: 5, pageSize: 2, conflictReason: "Changed on another device", myNotesSeparator: "---"
)

private func engineDevice(
    device: SyncDevice, key: SyncAccountKey, userID: String, root: URL, observer: @escaping @Sendable (Result<SyncPassReport, any Error>) -> Void
) async throws -> EngineDevice {
    let account: URL = root.appending(path: "Accounts/\(UUID().uuidString)", directoryHint: .isDirectory)
    let jobs: DeviceJobs = DeviceJobs()
    let recording: RecordingSwitch = RecordingSwitch()
    let store: SyncAccountFolderStore = SyncAccountFolderStore(
        accountDirectory: account, defaultsSuite: "ainotepad.e2e.\(UUID().uuidString)", valuesDomain: "ainotepad.e2e.values.\(UUID().uuidString)",
        busy: { () async -> Set<String> in await jobs.query() }, recordingInProgress: { () -> Bool in recording.isOn }, now: { () -> Date in Date() }
    )
    let engine: SyncEngine = try SyncEngine(
        client: device.client, store: store, accountKey: key, userID: userID, files: SyncMetadataFiles(directory: account.appending(path: syncFolderName)),
        clock: SystemSyncClock(), settings: e2eSyncSettings, observer: observer
    )
    return EngineDevice(engine: engine, store: store, jobs: jobs, recording: recording)
}

/// Writes a meeting as the app would and queues it for the next pass (without the debounced pass, so the explicit
/// passes of the test report what they did).
private func edit(device: EngineDevice, id: String, change: (MeetingRecord) -> MeetingRecord) async throws {
    let current: MeetingRecord = try #require(try await device.store.meeting(id: id))
    #expect(try await device.store.writeMeeting(record: change(current), replacing: current) == .written)
    try await device.engine.queueEverything()
}

/// The sync key a device keeps (the apps: the account's Keychain item; here memory, so no real Keychain item is touched).
private final class MemorySyncKeyStore: SyncKeyStore {
    private let stored: Mutex<SyncDeviceKey?> = Mutex(nil)

    func load() throws -> SyncDeviceKey? {
        stored.withLock { $0 }
    }

    func save(key: SyncDeviceKey) throws {
        stored.withLock { $0 = key }
    }

    func delete() throws {
        stored.withLock { $0 = nil }
    }
}

@Suite(.enabled(if: hostedE2EEnabled), .serialized) struct HostedSyncE2ETests {
    // Two sync engines on temporary account folders (the Mac and the iPhone of one account) converge through the local
    // server: a meeting, a person, a folder and an Ask chat made on the Mac appear on the iPhone, whose own meeting of the
    // same second lands as "-2"; an idle pass changes nothing; edits made at once on both merge after a 409 (the Mac's
    // write lands between the iPhone's pull and upload) and the debounced pass reports it; a meeting under a long note
    // job waits; a delete propagates; purged tombstones are found by the full listing after `sync_cursor_expired`; and
    // after sync is reset on the server neither device loses or duplicates anything.
    @Test func twoEnginesConvergeAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let macRefresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: macRefresh)
        let phoneRefresh: String = randomToken()
        try insertDeviceSession(userID: userID, refreshToken: phoneRefresh)
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
        let macDevice: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: macRefresh)
        let phoneDevice: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: phoneRefresh)
        let key: SyncAccountKey = newSyncAccountKey()
        _ = try await macDevice.client.enable(keyID: key.keyID)

        let root: URL = FileManager.default.temporaryDirectory.appending(path: "sync-engine-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let phoneWatcher: PassWatcher = PassWatcher()
        let mac: EngineDevice = try await engineDevice(device: macDevice, key: key, userID: userID, root: root) { (_: Result<SyncPassReport, any Error>) -> Void in }
        let phone: EngineDevice = try await engineDevice(device: phoneDevice, key: key, userID: userID, root: root) { (result: Result<SyncPassReport, any Error>) -> Void in
            phoneWatcher.deliver(result: result)
        }
        defer {
            for device in [mac, phone] {
                device.removeDomains()
            }
            try? FileManager.default.removeItem(at: root)
        }

        // The Mac: a meeting, a person, a saved folder with a recipe, an Ask chat.
        let marker: String = "Secret-\(UUID().uuidString)"
        let record: MeetingRecord = syncSampleRecord().with(title: "Budget \(marker)").with(myNotes: "Ask about Q3\nKeep the scope\nCheck travel")
        let meetingID: String = record.id
        let tasks: [NoteTask] = try #require(record.note?.tasks)
        #expect(try await mac.store.writeMeeting(record: record, replacing: nil) == .written)
        let book: PeopleBook = PeopleBook(saved: [SavedPerson(name: "Aino", role: "CFO", email: "aino@example.com", addedAt: Date(timeIntervalSince1970: 1_800_000_000))], removed: [])
        #expect(try await mac.store.writePeopleBook(book: book, replacing: .empty) == .written)
        let prefs: SyncPrefs = SyncPrefs(
            schema: syncPayloadSchema, folders: ["Board"], recipes: [Recipe(id: "r1", title: "Risks", prompt: "List the risks", symbol: "bookmark", isBuiltIn: false)],
            settings: nil
        )
        #expect(try await mac.store.writePrefs(prefs: prefs, replacing: try await mac.store.prefs()) == .written)
        let start: Date = Date(timeIntervalSince1970: 1_800_000_100)
        let turn: AskConversationTurn = AskConversationTurn(
            id: UUID(), question: "What did we decide? \(marker)", scopeMeetingIDs: [], scopeTitles: [], recipeTitle: nil, startedAt: start,
            finishedAt: start.addingTimeInterval(5), terms: [], readPassages: [], readScreens: nil, answer: "The budget.", sources: [], webSources: nil, webQueries: nil, webSearchNotice: nil, skippedMeetings: nil, wasStopped: nil, scope: nil
        )
        let chat: AskConversation = askConversation(existing: nil, id: UUID(), turns: [turn], now: start)
        #expect(try await mac.store.writeAskChat(conversation: chat, replacing: nil) == .written)
        // The iPhone recorded another meeting in the same second (different transcript).
        let phoneRecord: MeetingRecord = syncSampleRecord().with(title: "Phone standup").with(translations: [:])
        #expect(try await phone.store.writeMeeting(record: phoneRecord, replacing: nil) == .written)

        let macFirst: SyncPassReport = try await mac.engine.syncNow()
        #expect(macFirst.uploaded == 5 && macFirst.failures.isEmpty)
        let phoneFirst: SyncPassReport = try await phone.engine.syncNow()
        #expect(phoneFirst.failures.isEmpty && phoneFirst.uploaded == 2)
        let collided: String = "\(meetingID)-2"
        #expect(try await phone.store.meetingIDs() == [meetingID, collided])
        #expect(try await phone.store.meeting(id: collided) == localMeetingRecord(
            state: try newMeetingState(record: record, contentObjectID: "", originDeviceID: "", now: Date()), content: meetingSyncContent(record: record),
            localID: collided, voiceprints: nil
        ))
        #expect(try await phone.store.meeting(id: meetingID)?.title == "Phone standup")
        #expect(try await phone.store.peopleBook() == book)
        #expect(try await phone.store.prefs() == prefs)
        #expect(try await phone.store.askChat(id: chat.id) == chat)
        let macSecond: SyncPassReport = try await mac.engine.syncNow()
        #expect(macSecond.changedMeetingIDs == [collided] && macSecond.uploaded == 0)
        #expect(try await mac.store.meeting(id: collided)?.title == "Phone standup")

        // Nothing changed: an idle pass uploads and downloads nothing (no value bounces between the devices).
        for engine in [mac.engine, phone.engine] {
            let idle: SyncPassReport = try await engine.syncNow()
            #expect(idle.uploaded == 0 && idle.downloaded == 0 && idle.changedMeetingIDs.isEmpty)
        }

        // Edits at once: the Mac completes a task and rewrites the first line of its own notes; the iPhone moves the
        // meeting to a folder, renames it and rewrites the last line. The Mac's upload lands between the iPhone's pull and
        // its upload, so the iPhone's write conflicts, merges three-way and is retried (the debounced pass).
        try await edit(device: mac, id: meetingID) { (current: MeetingRecord) -> MeetingRecord in
            togglingTask(record: current, task: tasks[0]).with(myNotes: "Ask about Q4\nKeep the scope\nCheck travel")
        }
        try await edit(device: phone, id: collided) { (current: MeetingRecord) -> MeetingRecord in
            current.with(folder: "Board").with(title: "Budget final").with(myNotes: "Ask about Q3\nKeep the scope\nCheck hotels")
        }
        let macEngine: SyncEngine = mac.engine
        phone.jobs.arm { () async -> Void in
            do {
                #expect(try await macEngine.syncNow().uploaded == 1)
            } catch {
                Issue.record(error)
            }
        }
        var passes: AsyncStream<Result<SyncPassReport, any Error>>.Iterator = phoneWatcher.arm().makeAsyncIterator()
        try await phone.engine.noteLocalChange(item: .meeting(id: collided))
        let debounced: SyncPassReport = try #require(await passes.next()).get()
        #expect(debounced.uploaded == 1 && debounced.downloaded == 1 && debounced.failures.isEmpty)
        _ = try await mac.engine.syncNow()
        for (device, id) in [(mac, meetingID), (phone, collided)] {
            let merged: MeetingRecord = try #require(try await device.store.meeting(id: id))
            #expect(merged.title == "Budget final" && merged.folder == "Board" && merged.myNotes == "Ask about Q4\nKeep the scope\nCheck hotels")
            #expect(Set(merged.completedTasks ?? []) == Set(tasks.map { taskKey(task: $0) }))
        }
        #expect(try localServerStateContainsNone(of: [marker, "approve the budget", "Ask about Q4"]))

        // A long note job runs on the iPhone's copy: the Mac's rename waits until it ends, then applies.
        phone.jobs.set(busy: [collided])
        try await edit(device: mac, id: meetingID) { (current: MeetingRecord) -> MeetingRecord in current.with(title: "Budget v3") }
        #expect(try await mac.engine.syncNow().uploaded == 1)
        let waiting: SyncPassReport = try await phone.engine.syncNow()
        #expect(waiting.deferred == 1 && waiting.uploaded == 0)
        #expect(try await phone.store.meeting(id: collided)?.title == "Budget final")
        phone.jobs.set(busy: [])
        #expect(try await phone.engine.syncNow().changedMeetingIDs == [collided])
        #expect(try await phone.store.meeting(id: collided)?.title == "Budget v3")

        // The iPhone deletes its own meeting: the Mac's copy goes to Recently Deleted.
        try await phone.store.deleteMeeting(id: meetingID)
        #expect(try await phone.engine.syncNow().deletedOnServer == 2)
        let macAfterDelete: SyncPassReport = try await mac.engine.syncNow()
        #expect(macAfterDelete.deletedLocally == 1 && macAfterDelete.changedMeetingIDs == [collided])
        #expect(try await mac.store.meetingIDs() == [meetingID])

        // The Mac deletes the meeting and the server purges the tombstones before the iPhone syncs: the iPhone's cursor
        // expires, and the full listing lacks the meeting, so its copy is deleted.
        try await mac.store.deleteMeeting(id: meetingID)
        #expect(try await mac.engine.syncNow().deletedOnServer == 2)
        try executeLocalD1(sql: [
            "DELETE FROM sync_objects WHERE user_id = '\(userID)' AND deleted = 1;",
            "UPDATE sync_accounts SET purged_through_rev = last_rev WHERE user_id = '\(userID)';",
        ].joined(separator: " "))
        let resynced: SyncPassReport = try await phone.engine.syncNow()
        #expect(resynced.fullResync && resynced.deletedLocally == 1 && resynced.failures.isEmpty)
        #expect(try await phone.store.meetingIDs().isEmpty)

        // A new meeting reaches both; then sync is turned off and on again (same key, new epoch). Both start their
        // bookkeeping over: the iPhone uploads everything again, the Mac recognizes it all (same transcript, same chat,
        // same people) and neither deletes or duplicates anything.
        let later: MeetingRecord = localMeetingRecord(
            state: try newMeetingState(record: record, contentObjectID: "", originDeviceID: "", now: Date()), content: meetingSyncContent(record: record),
            localID: "20261104-090000", voiceprints: nil
        ).with(title: "Retro")
        #expect(try await mac.store.writeMeeting(record: later, replacing: nil) == .written)
        _ = try await mac.engine.syncNow()
        _ = try await phone.engine.syncNow()
        #expect(try await phone.store.meeting(id: later.id) == later)
        _ = try await macDevice.client.disableAndWipe()
        _ = try await macDevice.client.enable(keyID: key.keyID)
        let phoneReset: SyncPassReport = try await phone.engine.syncNow()
        #expect(phoneReset.fullResync && phoneReset.deletedLocally == 0 && phoneReset.uploaded == 5 && phoneReset.failures.isEmpty)
        let macReset: SyncPassReport = try await mac.engine.syncNow()
        #expect(macReset.fullResync && macReset.deletedLocally == 0 && macReset.uploaded == 0 && macReset.failures.isEmpty)
        #expect(try await mac.store.meetingIDs() == [later.id])
        #expect(try await phone.store.meetingIDs() == [later.id])
        #expect(try await mac.store.askChatIDs() == [chat.id])
        #expect(try await mac.store.peopleBook() == book)
        #expect(try await mac.store.prefs() == prefs)
        for engine in [mac.engine, phone.engine] {
            let idle: SyncPassReport = try await engine.syncNow()
            #expect(idle.uploaded == 0 && idle.downloaded == 0)
            await engine.stop()
        }
        _ = try await macDevice.client.disableAndWipe()
    }

    // The Mac records a meeting and syncs it; the iPhone (same account, its own session) gets the key through the
    // recovery envelope, reads the meeting, and both edit it at once: the Mac's stale write conflicts, it merges
    // three-way and wins the retry, and the iPhone sees both edits. Then a delete reaches the iPhone as a tombstone and
    // opting out wipes the server copy. Throughout, the server's D1 and R2 state never contain the meeting's text.
    @Test func meetingSyncsBetweenTwoDevicesAsCiphertextAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let macRefresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: macRefresh)
        let phoneRefresh: String = randomToken()
        try insertDeviceSession(userID: userID, refreshToken: phoneRefresh)
        // A started trial may write (DEVICECHECK_POLICY is off locally).
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
        let mac: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: macRefresh)
        let phone: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: phoneRefresh)

        // Unique plaintext that must never reach the server.
        let marker: String = "Secret-\(UUID().uuidString)"
        let record: MeetingRecord = syncSampleRecord().with(title: "Budget \(marker)").with(myNotes: "Notes \(marker)")
        let tasks: [NoteTask] = try #require(record.note?.tasks)

        // Mac: turns sync on, uploads the meeting, stores a recovery envelope.
        let key: SyncAccountKey = newSyncAccountKey()
        let enabled: HostedSyncAccount = try await mac.client.enable(keyID: key.keyID)
        #expect(enabled.enabled && enabled.keyId == key.keyID)
        let stateID: String = newSyncObjectID()
        let contentID: String = newSyncObjectID()
        let parts: MeetingSyncParts = meetingSyncParts(record: record, contentObjectID: contentID, originDeviceID: mac.deviceID, clocks: [:])
        let base: MeetingSyncState = try stampingChanges(previous: nil, updated: parts.state, now: Date())
        let stateRev: UInt64 = try await upload(device: mac, value: base, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: 0)
        _ = try await upload(device: mac, value: parts.content, key: key, userID: userID, objectID: contentID, kind: .meetingContent, baseRevision: 0)
        let code: SyncRecoveryCode = newSyncRecoveryCode()
        try await mac.client.putEnvelope(envelopeID: newSyncObjectID(), kind: .recovery, ciphertext: try sealRecoveryEnvelope(accountKey: key, code: code, userID: userID))
        // The phone's own key loses the race to turn sync on.
        await #expect(throws: HostedSyncError.keyMismatch) { _ = try await phone.client.enable(keyID: newSyncAccountKey().keyID) }

        // iPhone: recovers the key with the code, reads the change feed and the meeting.
        let envelope: HostedSyncEnvelope = try #require(try await phone.client.envelopes().first { $0.kind == .recovery })
        let phoneKey: SyncAccountKey = try openRecoveryEnvelope(envelope: try #require(Data(base64Encoded: envelope.ciphertext)), code: code, userID: userID)
        #expect(phoneKey == key)
        let feed: HostedSyncChanges = try await phone.client.changes(since: 0, epoch: nil, limit: 500)
        #expect(Set(feed.changes.map(\.objectId)) == [stateID, contentID] && feed.keyId == key.keyID && !feed.hasMore)
        let phoneState: (value: MeetingSyncState, revision: UInt64) = try await download(device: phone, type: MeetingSyncState.self, key: phoneKey, userID: userID, objectID: stateID)
        let phoneContent: (value: MeetingSyncContent, revision: UInt64) = try await download(device: phone, type: MeetingSyncContent.self, key: phoneKey, userID: userID, objectID: contentID)
        var expected: MeetingRecord = record
        expected = expected.with(voiceprints: nil)
        #expect(joinedMeetingRecord(state: phoneState.value, content: phoneContent.value, voiceprints: nil) == expected)

        // Both edit at once: the phone completes a task and syncs first; the Mac moves it to a folder from the old base.
        let phoneRecord: MeetingRecord = togglingTask(record: joinedMeetingRecord(state: phoneState.value, content: phoneContent.value, voiceprints: nil), task: tasks[0])
        let phoneEdit: MeetingSyncState = try stampingChanges(
            previous: phoneState.value,
            updated: meetingSyncParts(record: phoneRecord, contentObjectID: contentID, originDeviceID: mac.deviceID, clocks: phoneState.value.fieldClocks).state,
            now: Date()
        )
        let phoneRev: UInt64 = try await upload(device: phone, value: phoneEdit, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: phoneState.revision)
        let macEdit: MeetingSyncState = try stampingChanges(
            previous: base, updated: meetingSyncParts(record: record.with(folder: "Board"), contentObjectID: contentID, originDeviceID: mac.deviceID, clocks: base.fieldClocks).state,
            now: Date()
        )
        await #expect(throws: HostedSyncError.conflict(objectID: stateID)) {
            _ = try await upload(device: mac, value: macEdit, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: stateRev)
        }
        let remote: (value: MeetingSyncState, revision: UInt64) = try await download(device: mac, type: MeetingSyncState.self, key: key, userID: userID, objectID: stateID)
        #expect(remote.revision == phoneRev)
        let merged: MeetingStateMerge = mergeMeetingState(base: base, local: macEdit, remote: remote.value, localDeviceID: mac.deviceID, conflictReason: "Changed on another device", myNotesSeparator: "---")
        let mergedRev: UInt64 = try await upload(device: mac, value: merged.state, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: remote.revision)

        // The phone pulls from its cursor and sees both edits.
        let next: HostedSyncChanges = try await phone.client.changes(since: feed.cursor, epoch: feed.epoch, limit: 500)
        #expect(next.changes.map(\.rev).last == mergedRev)
        let final: MeetingSyncState = try await download(device: phone, type: MeetingSyncState.self, key: key, userID: userID, objectID: stateID).value
        #expect(final.folder == "Board" && Set(final.completedTasks ?? []) == Set(tasks.map { taskKey(task: $0) }))

        // What the server holds: opaque ids, fixed kinds, sizes; the blobs start with GSY1 and hold no plaintext.
        let rows: [ObjectRow] = try localD1Rows(sql: "SELECT object_id, kind, rev, size, deleted FROM sync_objects WHERE user_id = '\(userID)' ORDER BY rev;", as: ObjectRow.self)
        #expect(Set(rows.map(\.kind)) == ["meeting.state", "meeting.content"])
        let blob: Data = try await phone.client.object(objectID: contentID).blob
        #expect(blob.prefix(4) == Data("GSY1".utf8) && blob.range(of: Data("approve the budget".utf8)) == nil)
        #expect(try localServerStateContainsNone(of: [marker, "approve the budget", "Ask about Q3"]))

        // The Mac deletes the meeting: the phone sees a tombstone and the blob is gone.
        let deletedRev: UInt64 = try await mac.client.delete(objectID: contentID, baseRevision: try await mac.client.object(objectID: contentID).revision)
        let afterDelete: HostedSyncChanges = try await phone.client.changes(since: next.cursor, epoch: next.epoch, limit: 500)
        #expect(afterDelete.changes.contains { $0.objectId == contentID && $0.deleted && $0.rev == deletedRev })
        await #expect(throws: HostedSyncError.objectNotFound(objectID: contentID)) { _ = try await phone.client.object(objectID: contentID) }

        // Opting out removes the whole server copy; the old cursor no longer works.
        #expect(try await phone.client.disableAndWipe() == 1)
        #expect(try await mac.client.account().enabled == false)
        await #expect(throws: HostedSyncError.notEnabled) { _ = try await mac.client.changes(since: 0, epoch: nil, limit: 10) }
        #expect(try localD1Rows(sql: "SELECT object_id, kind, rev, size, deleted FROM sync_objects WHERE user_id = '\(userID)';", as: ObjectRow.self).isEmpty)
    }

    // Settings follow the account: the Mac (settings stored before sync recorded changes, plus one changed since) uploads
    // them; a fresh iPhone install restores them (its first-launch values were never changed by the user, so the
    // account's win) without bouncing anything back; edits on both devices merge per setting by change time; an older
    // app's upload without the settings field does not erase them (the next newer device restores them); and a setting
    // from another device waits while a recording runs.
    @Test func settingsFollowTheAccountAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let macRefresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: macRefresh)
        let phoneRefresh: String = randomToken()
        try insertDeviceSession(userID: userID, refreshToken: phoneRefresh)
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
        let macDevice: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: macRefresh)
        let phoneDevice: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: phoneRefresh)
        let key: SyncAccountKey = newSyncAccountKey()
        _ = try await macDevice.client.enable(keyID: key.keyID)
        let root: URL = FileManager.default.temporaryDirectory.appending(path: "sync-settings-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let mac: EngineDevice = try await engineDevice(device: macDevice, key: key, userID: userID, root: root) { (_: Result<SyncPassReport, any Error>) -> Void in }
        let phone: EngineDevice = try await engineDevice(device: phoneDevice, key: key, userID: userID, root: root) { (_: Result<SyncPassReport, any Error>) -> Void in }
        defer {
            for device in [mac, phone] {
                device.removeDomains()
            }
            try? FileManager.default.removeItem(at: root)
        }
        let t0: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let macValues: UserDefaults = try mac.values()
        let phoneValues: UserDefaults = try phone.values()

        // The Mac's settings predate the bookkeeping; then the user changes one.
        macValues.set("fi", forKey: "language.note")
        macValues.set("bilingual", forKey: "displayMode")
        macValues.set("sales", forKey: "noteTemplate")
        #expect(try await mac.recordSettingChanges(now: t0).isEmpty)
        macValues.set(5, forKey: "missedWindowMinutes")
        #expect(try await mac.recordSettingChanges(now: t0.addingTimeInterval(10)) == ["missedWindowMinutes"])
        // The fresh iPhone stored its first-launch default; the user changed nothing.
        phoneValues.set("en", forKey: "language.note")
        #expect(try await phone.recordSettingChanges(now: t0.addingTimeInterval(20)).isEmpty)

        let macFirst: SyncPassReport = try await mac.engine.syncNow()
        #expect(macFirst.uploaded == 1 && macFirst.failures.isEmpty)
        let phoneFirst: SyncPassReport = try await phone.engine.syncNow()
        #expect(phoneFirst.prefsChanged && phoneFirst.uploaded == 0 && phoneFirst.failures.isEmpty)
        #expect(phoneValues.string(forKey: "language.note") == "fi" && phoneValues.string(forKey: "displayMode") == "bilingual")
        #expect(phoneValues.string(forKey: "noteTemplate") == "sales" && phoneValues.integer(forKey: "missedWindowMinutes") == 5)
        #expect(try await phone.recordSettingChanges(now: t0.addingTimeInterval(30)).isEmpty)
        for engine in [mac.engine, phone.engine] {
            let idle: SyncPassReport = try await engine.syncNow()
            #expect(idle.uploaded == 0 && idle.downloaded == 0)
        }

        // Edits on both: the iPhone's display mode is newer than the Mac's; the Mac's template is the only change of it.
        macValues.set("turkishOnly", forKey: "displayMode")
        macValues.set("general", forKey: "noteTemplate")
        #expect(try await mac.recordSettingChanges(now: t0.addingTimeInterval(60)) == ["displayMode", "noteTemplate"])
        phoneValues.set("originalOnly", forKey: "displayMode")
        #expect(try await phone.recordSettingChanges(now: t0.addingTimeInterval(90)) == ["displayMode"])
        #expect(try await phone.engine.syncNow().uploaded == 1)
        let macMerge: SyncPassReport = try await mac.engine.syncNow()
        #expect(macMerge.uploaded == 1 && macMerge.prefsChanged)
        _ = try await phone.engine.syncNow()
        for values in [macValues, phoneValues] {
            #expect(values.string(forKey: "displayMode") == "originalOnly" && values.string(forKey: "noteTemplate") == "general")
        }
        let merged: SyncPrefs = try await mac.store.prefs()
        #expect(try await phone.store.prefs() == merged)

        // An older app (no settings field) re-uploads the prefs with a new folder: the settings are not lost.
        let objectID: String = singletonSyncObjectID(accountKey: key, kind: .prefs)
        let current: UInt64 = try await phoneDevice.client.object(objectID: objectID).revision
        _ = try await upload(
            device: phoneDevice, value: OlderClientPrefs(schema: 1, folders: ["Board"], recipes: []), key: key, userID: userID, objectID: objectID, kind: .prefs,
            baseRevision: current
        )
        let restored: SyncPassReport = try await mac.engine.syncNow()
        #expect(restored.uploaded == 1 && restored.failures.isEmpty)
        let onServer: SyncPrefs = try await download(device: macDevice, type: SyncPrefs.self, key: key, userID: userID, objectID: objectID).value
        let macPrefs: SyncPrefs = try await mac.store.prefs()
        #expect(onServer.folders == ["Board"] && onServer.settings == macPrefs.settings && onServer.settings != nil)
        _ = try await phone.engine.syncNow()
        #expect(try await phone.store.prefs() == macPrefs)
        #expect(phoneValues.string(forKey: "displayMode") == "originalOnly")

        // A recording runs on the iPhone: the Mac's new note language waits until it ends.
        await MainActor.run { phone.recording.isOn = true }
        macValues.set("de", forKey: "language.note")
        #expect(try await mac.recordSettingChanges(now: t0.addingTimeInterval(120)) == ["language.note"])
        #expect(try await mac.engine.syncNow().uploaded == 1)
        let waiting: SyncPassReport = try await phone.engine.syncNow()
        #expect(waiting.deferred == 1 && !waiting.prefsChanged)
        #expect(phoneValues.string(forKey: "language.note") == "fi")
        await MainActor.run { phone.recording.isOn = false }
        let applied: SyncPassReport = try await phone.engine.syncNow()
        #expect(applied.prefsChanged && applied.uploaded == 0)
        #expect(phoneValues.string(forKey: "language.note") == "de")
        #expect(try await phone.recordSettingChanges(now: t0.addingTimeInterval(130)).isEmpty)
        for engine in [mac.engine, phone.engine] {
            let idle: SyncPassReport = try await engine.syncNow()
            #expect(idle.uploaded == 0 && idle.downloaded == 0)
            await engine.stop()
        }
        _ = try await macDevice.client.disableAndWipe()
    }

    // The apps' path from setup to deletion: the Mac turns sync on (new key and link code), the iPhone is told to type
    // the code, a wrong code is refused and the right one brings the key over. The Mac's meeting reaches the iPhone (its
    // onboarding sample meeting never does) and is marked as recorded elsewhere (the audio stays on the Mac); the
    // iPhone's edit goes back to the Mac and its own meeting reaches the Mac; deletes on either side propagate. Turning
    // sync off on the Mac wipes the server copy, and the iPhone's next pass learns that it was turned off elsewhere.
    @Test func macToPhoneAndBackWithLinkCodeAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let macRefresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: macRefresh)
        let phoneRefresh: String = randomToken()
        try insertDeviceSession(userID: userID, refreshToken: phoneRefresh)
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
        let macDevice: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: macRefresh)
        let phoneDevice: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: phoneRefresh)
        let macKeys: MemorySyncKeyStore = MemorySyncKeyStore()
        let phoneKeys: MemorySyncKeyStore = MemorySyncKeyStore()

        // Setup: the Mac creates the key; the iPhone needs the Mac's link code.
        guard case .ready(let macKey, createdAccountKey: true) = try await startSync(client: macDevice.client, keyStore: macKeys, userID: userID) else {
            Issue.record("The Mac did not turn sync on with a new key")
            return
        }
        #expect(try macKeys.load() == macKey)
        #expect(try await startSync(client: phoneDevice.client, keyStore: phoneKeys, userID: userID) == .needsLinkCode)
        let wrongCode: String = newSyncRecoveryCode().formatted
        await #expect(throws: SyncCryptoError.authenticationFailed) {
            try await joinSync(client: phoneDevice.client, keyStore: phoneKeys, userID: userID, codeText: wrongCode)
        }
        #expect(try phoneKeys.load() == nil)
        let phoneKey: SyncDeviceKey = try await joinSync(client: phoneDevice.client, keyStore: phoneKeys, userID: userID, codeText: macKey.code.lowercased())
        #expect(phoneKey.accountKey.keyID == macKey.accountKey.keyID)
        #expect(try await startSync(client: phoneDevice.client, keyStore: phoneKeys, userID: userID) == .ready(key: phoneKey, createdAccountKey: false))

        let root: URL = FileManager.default.temporaryDirectory.appending(path: "sync-link-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let mac: EngineDevice = try await engineDevice(device: macDevice, key: macKey.accountKey, userID: userID, root: root) { (_: Result<SyncPassReport, any Error>) -> Void in }
        let phone: EngineDevice = try await engineDevice(device: phoneDevice, key: phoneKey.accountKey, userID: userID, root: root) { (_: Result<SyncPassReport, any Error>) -> Void in }
        defer {
            for device in [mac, phone] {
                device.removeDomains()
            }
            try? FileManager.default.removeItem(at: root)
        }

        // The Mac: a finished meeting and the onboarding sample meeting.
        let record: MeetingRecord = syncSampleRecord()
        let meetingID: String = record.id
        let tasks: [NoteTask] = try #require(record.note?.tasks)
        let sample: MeetingRecord = sampleMeetingRecord(
            id: "20261101-090000", script: SampleMeetingScript(durationSec: 4, lines: [SampleMeetingLine(person: 1, text: "Sample line", startSec: 0, endSec: 3)]),
            note: MeetingNote(title: "Sample", summary: "A sample.", decisions: [], tasks: [], glossary: []), speakerNames: [:], startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            myNotes: ""
        )
        #expect(sample.isSampleMeeting)
        for meeting in [record, sample] {
            #expect(try await mac.store.writeMeeting(record: meeting, replacing: nil) == .written)
        }
        try await mac.engine.queueEverything()
        let macFirst: SyncPassReport = try await mac.engine.syncNow()
        #expect(macFirst.failures.isEmpty && macFirst.uploaded >= 2)
        try await phone.engine.queueEverything()
        let phoneFirst: SyncPassReport = try await phone.engine.syncNow()
        #expect(phoneFirst.failures.isEmpty && phoneFirst.changedMeetingIDs == [meetingID])
        #expect(try await phone.store.meetingIDs() == [meetingID])
        #expect(try await phone.store.meeting(id: meetingID)?.title == record.title)
        #expect(try await phone.engine.meetingsRecordedElsewhere() == [meetingID])
        #expect(try await mac.engine.meetingsRecordedElsewhere().isEmpty)
        #expect(try localServerStateContainsNone(of: ["Sample line", "approve the budget"]))

        // The iPhone edits the meeting and records its own: both reach the Mac.
        try await edit(device: phone, id: meetingID) { (current: MeetingRecord) -> MeetingRecord in
            togglingTask(record: current, task: tasks[0]).with(title: "Budget from the iPhone")
        }
        let phoneRecord: MeetingRecord = syncSampleRecord().with(title: "Phone standup").with(translations: [:])
        let phoneMeetingID: String = "20261104-080000"
        let phoneOwn: MeetingRecord = localMeetingRecord(
            state: try newMeetingState(record: phoneRecord, contentObjectID: "", originDeviceID: "", now: Date()), content: meetingSyncContent(record: phoneRecord),
            localID: phoneMeetingID, voiceprints: nil
        )
        #expect(try await phone.store.writeMeeting(record: phoneOwn, replacing: nil) == .written)
        try await phone.engine.queueEverything()
        #expect(try await phone.engine.syncNow().failures.isEmpty)
        let macBack: SyncPassReport = try await mac.engine.syncNow()
        #expect(macBack.failures.isEmpty && Set(macBack.changedMeetingIDs) == [meetingID, phoneMeetingID])
        let macCopy: MeetingRecord = try #require(try await mac.store.meeting(id: meetingID))
        #expect(macCopy.title == "Budget from the iPhone")
        #expect(Set(macCopy.completedTasks ?? []) == Set(tasks.map { taskKey(task: $0) }))
        #expect(try await mac.store.meeting(id: phoneMeetingID)?.title == "Phone standup")
        #expect(try await mac.engine.meetingsRecordedElsewhere() == [phoneMeetingID])
        #expect(try await mac.store.meeting(id: sample.id)?.isSampleMeeting == true)

        // Deletes: the Mac deletes its meeting, the iPhone deletes its own; each other's copy goes to Recently Deleted.
        try await mac.store.deleteMeeting(id: meetingID)
        #expect(try await mac.engine.syncNow().deletedOnServer == 2)
        try await phone.store.deleteMeeting(id: phoneMeetingID)
        let phoneDeletes: SyncPassReport = try await phone.engine.syncNow()
        #expect(phoneDeletes.deletedLocally == 1 && phoneDeletes.deletedOnServer == 2 && phoneDeletes.failures.isEmpty)
        #expect(try await phone.store.meetingIDs().isEmpty)
        let macDeletes: SyncPassReport = try await mac.engine.syncNow()
        #expect(macDeletes.deletedLocally == 1 && macDeletes.failures.isEmpty)
        #expect(try await mac.store.meetingIDs() == [sample.id])
        #expect(try await phone.engine.meetingsRecordedElsewhere().isEmpty)
        #expect(try await mac.engine.meetingsRecordedElsewhere().isEmpty)

        // The Mac turns sync off: the server copy is wiped and the Mac forgets its key; the iPhone learns it on its next
        // pass and keeps its local data.
        await mac.engine.stop()
        let macMetadata: URL = mac.store.accountDirectory.appending(path: syncFolderName)
        #expect(FileManager.default.fileExists(atPath: macMetadata.appending(path: "ledger.json").path))
        try await stopSync(client: macDevice.client, keyStore: macKeys, metadataDirectory: macMetadata)
        #expect(try macKeys.load() == nil && !FileManager.default.fileExists(atPath: macMetadata.path))
        do {
            _ = try await phone.engine.syncNow()
            Issue.record("The iPhone's pass succeeded after sync was turned off on the Mac")
        } catch {
            #expect(syncFailureKind(error: error) == .turnedOffElsewhere)
        }
        await phone.engine.stop()
        #expect(try localD1Rows(sql: "SELECT object_id, kind, rev, size, deleted FROM sync_objects WHERE user_id = '\(userID)';", as: ObjectRow.self).isEmpty)
    }
}

#endif
