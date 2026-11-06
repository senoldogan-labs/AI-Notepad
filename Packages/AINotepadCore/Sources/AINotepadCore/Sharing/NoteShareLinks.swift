import Foundation

// Bu cihazda oluşturulan paylaşım bağlantıları. Sunucu anahtarı hiç görmediği için bağlantıyı yeniden kopyalamak ancak
// onu oluşturan cihazda olur; sunucu toplantıyı da bilmez (toplantı kimliği ya da özeti gönderilmez), hangi bağlantının
// hangi toplantıya ait olduğunu yalnızca bu dosya bilir. Dosya kullanıcı verisinin altındadır (`NoteShareLinks.json`,
// hesap başına) ve eşitlemeye girmez. Bağlantı yalnızca zaten bu klasörde düz metin duran notu açtığı için dosya notlarla
// aynı korumayı paylaşır.

/// Bu cihazın bildiği bir bağlantı.
public struct NoteShareLinkEntry: Sendable, Equatable, Codable, Identifiable {
    public let shareID: String
    public let meetingID: String
    /// Tam bağlantı (anahtar `#` parçasında).
    public let link: URL
    public let createdAt: Date
    public let expiresAt: Date
    /// Transkript eklendi mi (listede gösterilir).
    public let includesTranscript: Bool

    public var id: String { shareID }

    public init(shareID: String, meetingID: String, link: URL, createdAt: Date, expiresAt: Date, includesTranscript: Bool) {
        self.shareID = shareID
        self.meetingID = meetingID
        self.link = link
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.includesTranscript = includesTranscript
    }
}

/// Cihazdaki bağlantı defteri.
public struct NoteShareLinks: Sendable, Equatable, Codable {
    public let entries: [NoteShareLinkEntry]

    public init(entries: [NoteShareLinkEntry]) {
        self.entries = entries
    }

    public static let empty: NoteShareLinks = NoteShareLinks(entries: [])
}

/// Yeni bağlantı eklenmiş defter (aynı kimlik varsa yenisiyle değişir). Saf fonksiyondur.
public func addingNoteShareLink(links: NoteShareLinks, entry: NoteShareLinkEntry) -> NoteShareLinks {
    NoteShareLinks(entries: links.entries.filter { $0.shareID != entry.shareID } + [entry])
}

/// Sunucuda artık olmayan (kaldırılmış ya da süresi dolmuş) bağlantıları çıkarılmış defter: `liveShareIDs` sunucunun
/// listesidir. Saf fonksiyondur.
public func keepingLiveNoteShareLinks(links: NoteShareLinks, liveShareIDs: Set<String>) -> NoteShareLinks {
    NoteShareLinks(entries: links.entries.filter { liveShareIDs.contains($0.shareID) })
}

/// Bağlantısı çıkarılmış defter. Saf fonksiyondur.
public func removingNoteShareLink(links: NoteShareLinks, shareID: String) -> NoteShareLinks {
    NoteShareLinks(entries: links.entries.filter { $0.shareID != shareID })
}

/// Toplantının bağlantıları, yeniden eskiye. Saf fonksiyondur.
public func noteShareLinks(links: NoteShareLinks, meetingID: String) -> [NoteShareLinkEntry] {
    links.entries.filter { $0.meetingID == meetingID }.sorted { $0.createdAt > $1.createdAt }
}

/// Defterin dosyası: kullanıcı verisinin altında `NoteShareLinks.json` (bkz. `AppPaths.userDataDirectory`).
public func noteShareLinksFileURL() throws -> URL {
    try AppPaths.userDataDirectory().appending(path: "NoteShareLinks.json")
}

/// Defteri okur; dosya henüz yoksa boş.
public func loadNoteShareLinks(url: URL) throws -> NoteShareLinks {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return .empty
    }
    do {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NoteShareLinks.self, from: Data(contentsOf: url))
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Defteri yazar (atomik; yalnızca bu kullanıcı okuyabilir).
public func saveNoteShareLinks(links: NoteShareLinks, url: URL) throws {
    do {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(links).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
}
