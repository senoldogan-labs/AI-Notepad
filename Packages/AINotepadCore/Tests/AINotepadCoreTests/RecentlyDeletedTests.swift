import Foundation
import Testing
@testable import AINotepadCore

@Suite struct RecentlyDeletedTests {
    private let day: Double = 86_400

    // Silinen toplantı 30 gün geri yüklenebilir; 30. günün sonunda kalıcı silinir, öncesinde değil.
    @Test func retentionPurgesOnlyExpired() {
        let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let base: MeetingRecord = record(id: "a", startedAt: now, status: .done, audioDeleted: false)
        let meetings: [DeletedMeeting] = [
            DeletedMeeting(record: base.withID("fresh"), deletedAt: now.addingTimeInterval(-2 * day)),
            DeletedMeeting(record: base.withID("edge"), deletedAt: now.addingTimeInterval(-30 * day)),
            DeletedMeeting(record: base.withID("almost"), deletedAt: now.addingTimeInterval(-30 * day + 60)),
            DeletedMeeting(record: base.withID("old"), deletedAt: now.addingTimeInterval(-45 * day)),
        ]
        #expect(deletedMeetingsToPurge(meetings: meetings, now: now, retentionDays: recentlyDeletedRetentionDays) == ["edge", "old"])
        #expect(recentlyDeletedRetentionDays == 30)
    }

    // Kalan gün yukarı yuvarlanır (son gün de 1 gün); süre dolduysa 0.
    @Test func daysLeftRoundsUp() {
        let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(deletedMeetingDaysLeft(deletedAt: now, now: now, retentionDays: 30) == 30)
        #expect(deletedMeetingDaysLeft(deletedAt: now.addingTimeInterval(-29.5 * day), now: now, retentionDays: 30) == 1)
        #expect(deletedMeetingDaysLeft(deletedAt: now.addingTimeInterval(-30 * day), now: now, retentionDays: 30) == 0)
        #expect(deletedMeetingDaysLeft(deletedAt: now.addingTimeInterval(-40 * day), now: now, retentionDays: 30) == 0)
    }

    // Silme klasörü son silinenlere taşır (liste görmez), son silinenler okunur, geri yükleme klasörü ve kaydı aynen
    // geri getirir; kalıcı silme klasörü siler.
    @Test func trashRestoreAndPurgeRoundTrip() throws {
        let root: URL = try temporaryDirectory()
        let sessions: URL = root.appending(path: "Sessions", directoryHint: .isDirectory)
        let trash: URL = root.appending(path: recentlyDeletedFolderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let ids: [String] = ["20261026-100000", "20261027-100000"]
        let originals: [MeetingRecord] = try ids.map { (id: String) -> MeetingRecord in
            let folder: URL = sessions.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("ses".utf8).write(to: folder.appending(path: "others.m4a"))
            let original: MeetingRecord = record(id: id, startedAt: Date(timeIntervalSince1970: 1_800_000_000), status: .done, audioDeleted: false)
                .with(folder: "Proje")
            try saveMeeting(record: original, directory: folder)
            return original
        }
        let deletedAt: Date = Date(timeIntervalSince1970: 1_800_100_000)
        for (index, id) in ids.enumerated() {
            try moveMeetingToRecentlyDeleted(
                meetingDirectory: sessions.appending(path: id, directoryHint: .isDirectory), recentlyDeleted: trash,
                deletedAt: deletedAt.addingTimeInterval(Double(index))
            )
        }
        #expect(loadMeetings(sessionsDirectory: sessions).meetings.isEmpty)
        let loaded: DeletedMeetingsLoadResult = loadRecentlyDeleted(directory: trash)
        #expect(loaded.failures.isEmpty)
        // En son silinen önce.
        #expect(loaded.meetings == [
            DeletedMeeting(record: originals[1], deletedAt: deletedAt.addingTimeInterval(1)),
            DeletedMeeting(record: originals[0], deletedAt: deletedAt),
        ])

        let restored: MeetingRecord = try restoreMeetingFromRecentlyDeleted(id: ids[0], recentlyDeleted: trash, sessions: sessions)
        #expect(restored == originals[0])
        #expect(loadMeetings(sessionsDirectory: sessions).meetings == [originals[0]])
        let restoredFolder: URL = sessions.appending(path: ids[0], directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: restoredFolder.appending(path: "others.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: restoredFolder.appending(path: deletionMarkerFileName).path))

        try deleteRecentlyDeletedMeeting(id: ids[1], recentlyDeleted: trash)
        #expect(loadRecentlyDeleted(directory: trash).meetings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: trash.appending(path: ids[1]).path))
    }

    // Aynı adlı toplantı varsa geri yükleme üzerine yazmaz; silinmiş toplantı yerinde kalır.
    @Test func restoreRefusesToOverwrite() throws {
        let root: URL = try temporaryDirectory()
        let sessions: URL = root.appending(path: "Sessions", directoryHint: .isDirectory)
        let trash: URL = root.appending(path: recentlyDeletedFolderName, directoryHint: .isDirectory)
        let id: String = "20261026-100000"
        let folder: URL = sessions.appending(path: id, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try saveMeeting(record: record(id: id, startedAt: Date(), status: .done, audioDeleted: false), directory: folder)
        try moveMeetingToRecentlyDeleted(meetingDirectory: folder, recentlyDeleted: trash, deletedAt: Date())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: StorageError.alreadyExists(path: folder.path)) {
            try restoreMeetingFromRecentlyDeleted(id: id, recentlyDeleted: trash, sessions: sessions)
        }
        #expect(loadRecentlyDeleted(directory: trash).meetings.map(\.id) == [id])
    }

    // Silinme işareti olmayan klasör okunamayanlara girer (kendiliğinden silinmez).
    @Test func folderWithoutMarkerIsReported() throws {
        let trash: URL = try temporaryDirectory()
        let folder: URL = trash.appending(path: "20261026-100000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveMeeting(record: record(id: "20261026-100000", startedAt: Date(), status: .done, audioDeleted: false), directory: folder)
        let loaded: DeletedMeetingsLoadResult = loadRecentlyDeleted(directory: trash)
        #expect(loaded.meetings.isEmpty)
        #expect(loaded.failures.map(\.folder) == ["20261026-100000"])
    }
}

private extension MeetingRecord {
    func withID(_ id: String) -> MeetingRecord {
        MeetingRecord(
            id: id, title: title, startedAt: startedAt, endedAt: endedAt, language: language, status: status, failureMessage: failureMessage,
            liveSegments: liveSegments, finalSegments: finalSegments, translations: translations, speakerNames: speakerNames, note: note,
            audioDeleted: audioDeleted, engine: engine, notice: notice, meNeedsFinalPass: meNeedsFinalPass
        )
    }
}
