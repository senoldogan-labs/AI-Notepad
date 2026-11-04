import Foundation

/// `SyncLocalStore` over one account's data folder (`Accounts/<key>`: `Sessions`, `AskHistory`, `People.json`,
/// `RecentlyDeleted`) and the account's preferences domain (`defaultsSuite`: saved folders, the user's Ask recipes). It
/// reads and writes the files directly, so an app using it reloads what the engine reports as changed
/// (`SyncPassReport`). The conditional writes compare with the copy on disk right before writing; that is enough for one
/// writer per process (the app's own writes go through its model, which this adapter does not see).
public struct SyncAccountFolderStore: SyncLocalStore {
    public let accountDirectory: URL
    public let defaultsSuite: String
    private let busy: @Sendable () async -> Set<String>
    private let now: @Sendable () -> Date

    /// `busy`: meetings a long note job works on; `now`: deletion time of meetings moved to Recently Deleted.
    public init(accountDirectory: URL, defaultsSuite: String, busy: @escaping @Sendable () async -> Set<String>, now: @escaping @Sendable () -> Date) {
        self.accountDirectory = accountDirectory
        self.defaultsSuite = defaultsSuite
        self.busy = busy
        self.now = now
    }

    /// The account's preferences domain (`UserDefaults` is not `Sendable`, so it is opened per use).
    private func defaults() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
            throw StorageError.readFailed(path: defaultsSuite, reason: "preferences domain could not be opened")
        }
        return defaults
    }

    private var sessions: URL {
        accountDirectory.appending(path: sessionsFolderName, directoryHint: .isDirectory)
    }

    private var askHistory: URL {
        accountDirectory.appending(path: askHistoryFolderName, directoryHint: .isDirectory)
    }

    private var peopleFile: URL {
        accountDirectory.appending(path: "People.json", directoryHint: .notDirectory)
    }

    private func meetingDirectory(id: String) -> URL {
        sessions.appending(path: id, directoryHint: .isDirectory)
    }

    public func meetingIDs() async throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: sessions.path) else {
            return []
        }
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        } catch {
            throw StorageError.readFailed(path: sessions.path, reason: error.localizedDescription)
        }
        return Set(folders.filter { FileManager.default.fileExists(atPath: $0.appending(path: meetingFileName).path) }.map(\.lastPathComponent))
    }

    public func meeting(id: String) async throws -> MeetingRecord? {
        let directory: URL = meetingDirectory(id: id)
        guard FileManager.default.fileExists(atPath: directory.appending(path: meetingFileName).path) else {
            return nil
        }
        return try loadMeeting(directory: directory)
    }

    public func writeMeeting(record: MeetingRecord, replacing previous: MeetingRecord?) async throws -> SyncStoreWrite {
        guard try await meeting(id: record.id) == previous, await !busy().contains(record.id) else {
            return .changedMeanwhile
        }
        let directory: URL = meetingDirectory(id: record.id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: directory.path, reason: error.localizedDescription)
        }
        try saveMeeting(record: record, directory: directory)
        return .written
    }

    public func deleteMeeting(id: String) async throws {
        let recentlyDeleted: URL = accountDirectory.appending(path: recentlyDeletedFolderName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: recentlyDeleted, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: recentlyDeleted.path, reason: error.localizedDescription)
        }
        try moveMeetingToRecentlyDeleted(meetingDirectory: meetingDirectory(id: id), recentlyDeleted: recentlyDeleted, deletedAt: now())
    }

    public func busyMeetingIDs() async -> Set<String> {
        await busy()
    }

    public func askChatIDs() async throws -> Set<UUID> {
        guard FileManager.default.fileExists(atPath: askHistory.path) else {
            return []
        }
        do {
            let files: [URL] = try FileManager.default.contentsOfDirectory(at: askHistory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return Set(files.filter { $0.pathExtension == "json" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        } catch {
            throw StorageError.readFailed(path: askHistory.path, reason: error.localizedDescription)
        }
    }

    public func askChat(id: UUID) async throws -> AskConversation? {
        try loadAskConversation(id: id, directory: askHistory)
    }

    public func writeAskChat(conversation: AskConversation, replacing previous: AskConversation?) async throws -> SyncStoreWrite {
        guard try loadAskConversation(id: conversation.id, directory: askHistory) == previous else {
            return .changedMeanwhile
        }
        do {
            try FileManager.default.createDirectory(at: askHistory, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: askHistory.path, reason: error.localizedDescription)
        }
        try saveAskConversation(conversation: conversation, directory: askHistory)
        return .written
    }

    public func deleteAskChat(id: UUID) async throws {
        try deleteAskConversation(id: id, directory: askHistory)
    }

    public func peopleBook() async throws -> PeopleBook {
        try loadPeopleBook(url: peopleFile)
    }

    public func writePeopleBook(book: PeopleBook, replacing previous: PeopleBook) async throws -> SyncStoreWrite {
        guard try loadPeopleBook(url: peopleFile) == previous else {
            return .changedMeanwhile
        }
        try savePeopleBook(book: book, url: peopleFile)
        return .written
    }

    public func prefs() async throws -> SyncPrefs {
        let defaults: UserDefaults = try defaults()
        return SyncPrefs(
            schema: syncPayloadSchema, folders: defaults.stringArray(forKey: savedFoldersKey) ?? [],
            recipes: try loadUserRecipes(defaults: defaults).filter { !$0.isBuiltIn }
        )
    }

    public func writePrefs(prefs newPrefs: SyncPrefs, replacing previous: SyncPrefs) async throws -> SyncStoreWrite {
        guard try await prefs() == previous else {
            return .changedMeanwhile
        }
        let defaults: UserDefaults = try defaults()
        defaults.set(newPrefs.folders, forKey: savedFoldersKey)
        try saveUserRecipes(recipes: newPrefs.recipes, defaults: defaults)
        return .written
    }
}
