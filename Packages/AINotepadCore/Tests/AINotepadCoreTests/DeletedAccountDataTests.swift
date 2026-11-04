import Foundation
import Testing
@testable import AINotepadCore

/// Silinen hesap (eski), yeniden açılan hesap (yeni) ve başka bir hesap.
private let deletedKey: String = accountDataKey(userId: "google:silinen")
private let newKey: String = accountDataKey(userId: "google:yeni")
private let otherKey: String = accountDataKey(userId: "apple:baska")

/// Hesabın toplantı klasörüne kayıtlı toplantılar kurar.
private func addMeetings(dataRoot: URL, accountKey: String, ids: [String]) throws {
    let sessions: URL = AppPaths.accountSessionsDirectory(dataRoot: dataRoot, accountKey: accountKey)
    for id in ids {
        let folder: URL = sessions.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: MeetingRecord = MeetingRecord(
            id: id, title: "Toplantı \(id)", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: nil, status: .done,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
            engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        try saveMeeting(record: record, directory: folder)
    }
}

/// Klasördeki toplantıların kimlikleri (sıralı).
private func meetingIDs(dataRoot: URL, accountKey: String) -> [String] {
    loadMeetings(sessionsDirectory: AppPaths.accountSessionsDirectory(dataRoot: dataRoot, accountKey: accountKey)).meetings.map(\.id).sorted()
}

@Suite struct DeletedAccountDataTests {
    // Silinen hesap bir kez kaydedilir; yüklü hesap kendi silinmiş listesinde olsa da kendisine önerilmez.
    @Test func deletedAccountsAreRecordedOnce() throws {
        let root: URL = try temporaryDirectory()
        #expect(try readDeletedAccountKeys(dataRoot: root).isEmpty)
        try recordDeletedAccount(dataRoot: root, accountKey: deletedKey)
        try recordDeletedAccount(dataRoot: root, accountKey: deletedKey)
        try recordDeletedAccount(dataRoot: root, accountKey: otherKey)
        #expect(try readDeletedAccountKeys(dataRoot: root) == [deletedKey, otherKey])
        #expect(throws: StorageError.invalidAccountKey(key: "../Sessions")) {
            try recordDeletedAccount(dataRoot: root, accountKey: "../Sessions")
        }
        try addMeetings(dataRoot: root, accountKey: deletedKey, ids: ["20260101-090000"])
        #expect(try findDeletedAccountMeetings(dataRoot: root, accountKey: deletedKey).isEmpty)
    }

    // Bozuk liste tahminle okunmaz.
    @Test func corruptListThrows() throws {
        let root: URL = try temporaryDirectory()
        try FileManager.default.createDirectory(at: AppPaths.accountsDirectory(dataRoot: root), withIntermediateDirectories: true)
        try Data("\(deletedKey)\nbozuk\n".utf8).write(to: AppPaths.deletedAccountsFile(dataRoot: root))
        #expect(throws: StorageError.invalidAccountKey(key: "bozuk")) {
            try readDeletedAccountKeys(dataRoot: root)
        }
    }

    // Yalnızca bu cihazda silinmiş hesapların toplantıları bulunur (silinmemiş başka hesabınkiler değil); gizli dosyalar
    // ve klasör olmayan öğeler toplantı sayılmaz; toplantısı kalmayan hesap listede yer almaz.
    @Test func findsMeetingsOfDeletedAccountsOnly() throws {
        let root: URL = try temporaryDirectory()
        try addMeetings(dataRoot: root, accountKey: deletedKey, ids: ["20260101-090000", "20260102-090000"])
        try addMeetings(dataRoot: root, accountKey: otherKey, ids: ["20260103-090000"])
        let sessions: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: deletedKey)
        try Data().write(to: sessions.appending(path: ".DS_Store"))
        try Data().write(to: sessions.appending(path: "notlar.txt"))
        #expect(try findDeletedAccountMeetings(dataRoot: root, accountKey: newKey).isEmpty)
        try recordDeletedAccount(dataRoot: root, accountKey: deletedKey)
        let empty: String = accountDataKey(userId: "google:bos")
        try recordDeletedAccount(dataRoot: root, accountKey: empty)
        let found: [DeletedAccountMeetings] = try findDeletedAccountMeetings(dataRoot: root, accountKey: newKey)
        #expect(found == [DeletedAccountMeetings(accountKey: deletedKey, meetingFolders: ["20260101-090000", "20260102-090000"])])
        #expect(deletedAccountMeetingCount(found: found) == 2)
        #expect(isDeletedMeetingsOfferVisible(found: found, dismissedKeys: []))
        #expect(!isDeletedMeetingsOfferVisible(found: found, dismissedKeys: [deletedKey]))
        #expect(!isDeletedMeetingsOfferVisible(found: [], dismissedKeys: []))
    }

    // Taşıma toplantı başına yeniden adlandırmadır (kopya değil): toplantılar yeni hesapta açılır, eski hesabın diğer
    // verisi (Sor geçmişi) yerinde kalır, hiçbir şey silinmez. Yeni hesapta aynı adlı toplantı varsa üzerine yazılmaz.
    @Test func movesMeetingsIntoNewAccountWithoutOverwriting() throws {
        let root: URL = try temporaryDirectory()
        try addMeetings(dataRoot: root, accountKey: deletedKey, ids: ["20260101-090000", "20260102-090000"])
        try addMeetings(dataRoot: root, accountKey: newKey, ids: ["20260102-090000", "20260201-090000"])
        let ask: URL = AppPaths.accountDataDirectory(dataRoot: root, accountKey: deletedKey).appending(path: askHistoryFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ask, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ask.appending(path: "sohbet.json"))
        try recordDeletedAccount(dataRoot: root, accountKey: deletedKey)
        let source: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: deletedKey).appending(path: "20260101-090000")
        let inode: Int = try #require(try FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? Int)

        let result: DeletedMeetingsMoveResult = try moveDeletedAccountMeetings(dataRoot: root, accountKey: newKey)

        #expect(result.moves.map(\.destination.lastPathComponent) == ["20260101-090000"])
        #expect(result.skipped.map(\.source.lastPathComponent) == ["20260102-090000"])
        #expect(meetingIDs(dataRoot: root, accountKey: newKey) == ["20260101-090000", "20260102-090000", "20260201-090000"])
        #expect(meetingIDs(dataRoot: root, accountKey: deletedKey) == ["20260102-090000"])
        let moved: URL = AppPaths.accountSessionsDirectory(dataRoot: root, accountKey: newKey).appending(path: "20260101-090000")
        #expect(try FileManager.default.attributesOfItem(atPath: moved.path)[.systemFileNumber] as? Int == inode)
        #expect(FileManager.default.fileExists(atPath: ask.appending(path: "sohbet.json").path))
        // Yeniden denemek kalanı yine üzerine yazmadan bırakır; taşınan bir daha taşınmaz.
        let again: DeletedMeetingsMoveResult = try moveDeletedAccountMeetings(dataRoot: root, accountKey: newKey)
        #expect(again.moves.isEmpty && again.skipped.count == 1)
    }

    // Yarıda kalan taşıma (ör. uygulama kapandı) kaldığı yerden sürer: taşınanlar yeni hesapta kalır, kalanlar taşınır.
    @Test func interruptedMoveResumes() throws {
        let root: URL = try temporaryDirectory()
        try addMeetings(dataRoot: root, accountKey: deletedKey, ids: ["20260101-090000", "20260102-090000", "20260103-090000"])
        try recordDeletedAccount(dataRoot: root, accountKey: deletedKey)
        let planned: [DataMove] = deletedAccountMeetingMoves(
            dataRoot: root, found: try findDeletedAccountMeetings(dataRoot: root, accountKey: newKey), accountKey: newKey
        )
        #expect(planned.count == 3)
        try renameExclusively(move: planned[0], movedSoFar: 0)
        #expect(try deletedAccountMeetingCount(found: findDeletedAccountMeetings(dataRoot: root, accountKey: newKey)) == 2)
        let result: DeletedMeetingsMoveResult = try moveDeletedAccountMeetings(dataRoot: root, accountKey: newKey)
        #expect(result.moves.count == 2 && result.skipped.isEmpty)
        #expect(meetingIDs(dataRoot: root, accountKey: newKey) == ["20260101-090000", "20260102-090000", "20260103-090000"])
        #expect(try findDeletedAccountMeetings(dataRoot: root, accountKey: newKey).isEmpty)
    }
}

@Suite struct AccountIdentityTests {
    /// Testin kendi ayar alanı (uygulamanın ayarlarına dokunmaz).
    private func scratchDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite: String = "ainotepad-tests-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    // Güncellemeden önce ortak ayarda duran ad ve sözlük, güncellemeden sonra ilk yüklenen hesaba bir kez taşınır; ikinci
    // hesap boş başlar. Boş değer taşınmaz; hesapta dolu değerin üzerine yazılmaz.
    @Test func identityMovesIntoFirstAccountOnly() throws {
        let (shared, sharedSuite): (UserDefaults, String) = try scratchDefaults()
        let (first, firstSuite): (UserDefaults, String) = try scratchDefaults()
        let (second, secondSuite): (UserDefaults, String) = try scratchDefaults()
        defer {
            for suite in [sharedSuite, firstSuite, secondSuite] {
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
        }
        shared.set("Doğan", forKey: userNameDefaultsKey)
        shared.set("Gistsmith\nKubernetes", forKey: customVocabularyDefaultsKey)

        let moved: IdentityMigrationResult = moveIdentityToAccountOnce(source: shared, destination: first)
        #expect(moved == IdentityMigrationResult(ran: true, moved: [userNameDefaultsKey, customVocabularyDefaultsKey], kept: []))
        #expect(first.string(forKey: userNameDefaultsKey) == "Doğan" && first.string(forKey: customVocabularyDefaultsKey) == "Gistsmith\nKubernetes")
        #expect(shared.string(forKey: userNameDefaultsKey) == nil && shared.string(forKey: customVocabularyDefaultsKey) == nil)

        shared.set("Eski", forKey: userNameDefaultsKey)
        #expect(moveIdentityToAccountOnce(source: shared, destination: second) == IdentityMigrationResult(ran: false, moved: [], kept: []))
        #expect(second.string(forKey: userNameDefaultsKey) == nil)
    }

    @Test func identityNeverOverwritesAccountValue() throws {
        let (shared, sharedSuite): (UserDefaults, String) = try scratchDefaults()
        let (account, accountSuite): (UserDefaults, String) = try scratchDefaults()
        defer {
            for suite in [sharedSuite, accountSuite] {
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
        }
        shared.set("Ortak", forKey: userNameDefaultsKey)
        shared.set("", forKey: customVocabularyDefaultsKey)
        account.set("Hesabın adı", forKey: userNameDefaultsKey)
        let result: IdentityMigrationResult = moveIdentityToAccountOnce(source: shared, destination: account)
        #expect(result == IdentityMigrationResult(ran: true, moved: [], kept: [userNameDefaultsKey]))
        #expect(account.string(forKey: userNameDefaultsKey) == "Hesabın adı")
        #expect(account.string(forKey: customVocabularyDefaultsKey) == nil)
        #expect(shared.bool(forKey: accountIdentityMigratedKey))
    }
}
