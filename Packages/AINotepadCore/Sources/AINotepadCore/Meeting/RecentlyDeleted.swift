import Foundation

// "Son silinenler" (iPhone'da Çöp Sepeti yok): silinen toplantının klasörü (metin, not, ses) hesabın
// `RecentlyDeleted` klasörüne taşınır, `recentlyDeletedRetentionDays` gün geri yüklenebilir, süre dolunca kalıcı
// silinir. Silinme anı klasördeki `deleted.json`'dadır. Toplantı listesi yalnız `Sessions`'ı okur: silinen toplantı
// görevlerde, Sor'da, Kişiler'de ve takvimde görünmez; geri yüklenince hepsine döner.

/// Silinen toplantının geri yüklenebileceği gün sayısı; sonra kalıcı silinir.
public let recentlyDeletedRetentionDays: Int = 30

/// Silinen toplantıların klasörü (kullanıcı verisinin altında, `Sessions`'ın yanında).
public let recentlyDeletedFolderName: String = "RecentlyDeleted"

/// Silinen toplantı klasöründe silinme anını tutan dosya.
let deletionMarkerFileName: String = "deleted.json"

/// Son silinenlerdeki toplantı ve silinme anı.
public struct DeletedMeeting: Sendable, Equatable, Identifiable {
    public let record: MeetingRecord
    public let deletedAt: Date

    public var id: String { record.id }

    public init(record: MeetingRecord, deletedAt: Date) {
        self.record = record
        self.deletedAt = deletedAt
    }
}

/// Son silinenlerin okunma sonucu: okunan toplantılar (en son silinen önce) ve okunamayan klasörler.
public struct DeletedMeetingsLoadResult: Sendable, Equatable {
    public let meetings: [DeletedMeeting]
    public let failures: [MeetingLoadFailure]
}

/// `deleted.json`'un içeriği.
private struct DeletionMarker: Codable {
    let deletedAt: Date
}

// MARK: Saklama kuralı

/// Silinen toplantının kalıcı silineceği an: silinmeden `retentionDays` gün sonra. Saf fonksiyondur.
public func deletedMeetingExpiry(deletedAt: Date, retentionDays: Int) -> Date {
    deletedAt.addingTimeInterval(Double(retentionDays) * 86_400)
}

/// Süresi dolan (kalıcı silinecek) toplantıların kimlikleri. Saf fonksiyondur.
public func deletedMeetingsToPurge(meetings: [DeletedMeeting], now: Date, retentionDays: Int) -> [String] {
    meetings.filter { deletedMeetingExpiry(deletedAt: $0.deletedAt, retentionDays: retentionDays) <= now }.map(\.id)
}

/// Kalıcı silinmeye kalan gün (yukarı yuvarlanır: son gün de 1 gün sayılır); süre dolduysa 0. Saf fonksiyondur.
public func deletedMeetingDaysLeft(deletedAt: Date, now: Date, retentionDays: Int) -> Int {
    let remaining: Double = deletedMeetingExpiry(deletedAt: deletedAt, retentionDays: retentionDays).timeIntervalSince(now)
    return remaining <= 0 ? 0 : Int((remaining / 86_400).rounded(.up))
}

/// En son silinen önce; eşitse kimliğe göre. Saf fonksiyondur.
public func newestDeletedFirst(meetings: [DeletedMeeting]) -> [DeletedMeeting] {
    meetings.sorted { (left: DeletedMeeting, right: DeletedMeeting) -> Bool in
        left.deletedAt == right.deletedAt ? left.id > right.id : left.deletedAt > right.deletedAt
    }
}

// MARK: Dosyalar

public extension AppPaths {
    /// Silinen toplantıların klasörü: kullanıcı verisinin altında `RecentlyDeleted` (yoksa oluşturulur).
    static func recentlyDeletedDirectory() throws -> URL {
        let url: URL = try userDataDirectory().appending(path: recentlyDeletedFolderName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw StorageError.directoryUnavailable(path: url.path, reason: error.localizedDescription)
        }
        return url
    }
}

/// Toplantının klasörünü son silinenlere taşır: önce silinme anı klasöre yazılır, sonra klasör taşınır. Taşınamazsa
/// yazılan işaret geri silinir ve `moveFailed` fırlar (toplantı yerinde kalır). Son silinenlerde aynı adlı klasör varsa
/// `alreadyExists` (üzerine yazılmaz).
public func moveMeetingToRecentlyDeleted(meetingDirectory: URL, recentlyDeleted: URL, deletedAt: Date) throws {
    let destination: URL = recentlyDeleted.appending(path: meetingDirectory.lastPathComponent, directoryHint: .isDirectory)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw StorageError.alreadyExists(path: destination.path)
    }
    let marker: URL = meetingDirectory.appending(path: deletionMarkerFileName, directoryHint: .notDirectory)
    let encoder: JSONEncoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do {
        try encoder.encode(DeletionMarker(deletedAt: deletedAt)).write(to: marker, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: marker.path, reason: error.localizedDescription)
    }
    do {
        try FileManager.default.moveItem(at: meetingDirectory, to: destination)
    } catch let moveError {
        do {
            try FileManager.default.removeItem(at: marker)
        } catch {
            throw StorageError.moveFailed(
                path: meetingDirectory.path,
                reason: "\(moveError.localizedDescription); silinme işareti de kaldırılamadı: \(error.localizedDescription)"
            )
        }
        throw StorageError.moveFailed(path: meetingDirectory.path, reason: moveError.localizedDescription)
    }
}

/// Silinen toplantıyı toplantı klasörüne geri taşır ve silinme işaretini kaldırır; geri yüklenen kaydı döndürür.
/// Toplantılarda aynı adlı klasör varsa `alreadyExists` (üzerine yazılmaz); taşınamazsa `moveFailed`.
public func restoreMeetingFromRecentlyDeleted(id: String, recentlyDeleted: URL, sessions: URL) throws -> MeetingRecord {
    let source: URL = recentlyDeleted.appending(path: id, directoryHint: .isDirectory)
    let destination: URL = sessions.appending(path: id, directoryHint: .isDirectory)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw StorageError.alreadyExists(path: destination.path)
    }
    do {
        try FileManager.default.moveItem(at: source, to: destination)
    } catch {
        throw StorageError.moveFailed(path: source.path, reason: error.localizedDescription)
    }
    let marker: URL = destination.appending(path: deletionMarkerFileName, directoryHint: .notDirectory)
    do {
        try FileManager.default.removeItem(at: marker)
    } catch {
        throw StorageError.deleteFailed(path: marker.path, reason: error.localizedDescription)
    }
    return try loadMeeting(directory: destination)
}

/// Silinen toplantıyı kalıcı olarak siler (metin, not ve ses). Silinemezse `deleteFailed`.
public func deleteRecentlyDeletedMeeting(id: String, recentlyDeleted: URL) throws {
    try deleteMeetingDirectory(directory: recentlyDeleted.appending(path: id, directoryHint: .isDirectory))
}

/// Son silinenleri okur (en son silinen önce): her klasörün `meeting.json`'u ve silinme anı. İkisinden biri okunamayan
/// klasör `failures`'a girer (kendiliğinden silinmez; nedeni görünür). Klasör yoksa boş sonuç. Ana iş parçacığında
/// çağrılmaz (bkz. `loadRecentlyDeletedInBackground`).
public func loadRecentlyDeleted(directory: URL) -> DeletedMeetingsLoadResult {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return DeletedMeetingsLoadResult(meetings: [], failures: [])
    }
    let folders: [URL]
    do {
        folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    } catch {
        return DeletedMeetingsLoadResult(meetings: [], failures: [MeetingLoadFailure(folder: directory.lastPathComponent, reason: error.localizedDescription)])
    }
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let outcomes: [DeletedFolderOutcome] = folders.map { (folder: URL) -> DeletedFolderOutcome in
        do {
            let marker: DeletionMarker = try decoder.decode(
                DeletionMarker.self, from: try Data(contentsOf: folder.appending(path: deletionMarkerFileName, directoryHint: .notDirectory))
            )
            return .meeting(DeletedMeeting(record: try loadMeeting(directory: folder), deletedAt: marker.deletedAt))
        } catch {
            return .failure(MeetingLoadFailure(folder: folder.lastPathComponent, reason: error.localizedDescription))
        }
    }
    return DeletedMeetingsLoadResult(
        meetings: newestDeletedFirst(meetings: outcomes.compactMap { (outcome: DeletedFolderOutcome) -> DeletedMeeting? in
            if case .meeting(let meeting) = outcome { meeting } else { nil }
        }),
        failures: outcomes.compactMap { (outcome: DeletedFolderOutcome) -> MeetingLoadFailure? in
            if case .failure(let failure) = outcome { failure } else { nil }
        }
    )
}

/// Son silinenlerdeki bir klasörün okunma sonucu.
private enum DeletedFolderOutcome {
    case meeting(DeletedMeeting)
    case failure(MeetingLoadFailure)
}

/// Son silinenleri arka planda okur (bkz. `loadRecentlyDeleted`).
public func loadRecentlyDeletedInBackground() async throws -> DeletedMeetingsLoadResult {
    let directory: URL = try AppPaths.recentlyDeletedDirectory()
    return await runBlocking(qos: .userInitiated) { () -> DeletedMeetingsLoadResult in
        loadRecentlyDeleted(directory: directory)
    }
}
