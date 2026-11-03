import Foundation

/// Bir klasör ve içindeki toplantı sayısı.
public struct FolderSummary: Sendable, Equatable, Identifiable {
    public let name: String
    public let count: Int

    public var id: String { name }
}

/// Klasörler: toplantılarda kullanılanlar ve kullanıcının oluşturduğu (henüz boş) klasörler; ada göre sıralı, aynı ad
/// (büyük/küçük harf duyarsız) bir kez. Saf fonksiyondur.
public func meetingFolders(records: [MeetingRecord], saved: [String]) -> [FolderSummary] {
    let used: [String] = records.compactMap(\.folder)
    let names: [String] = (saved + used).reduce(into: [String]()) { (result: inout [String], name: String) -> Void in
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !result.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            result.append(trimmed)
        }
    }
    return names
        .map { (name: String) -> FolderSummary in
            FolderSummary(name: name, count: used.filter { $0.caseInsensitiveCompare(name) == .orderedSame }.count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

/// Klasördeki toplantılar; klasör nil ise hepsi. Saf fonksiyondur.
public func meetingsInFolder(records: [MeetingRecord], folder: String?) -> [MeetingRecord] {
    guard let folder else {
        return records
    }
    return records.filter { $0.folder?.caseInsensitiveCompare(folder) == .orderedSame }
}

/// Oluşturulan klasörlerin (toplantısız olanlar dahil) ayar anahtarı; abonelikte hesabın ayar alanında.
public let savedFoldersKey: String = "folders"

/// Yeni klasörle kayıtlı klasörler: ad kırpılır; boşsa ya da aynı adda (büyük/küçük harf duyarsız) kayıtlı ya da
/// toplantılarda kullanılan klasör varsa nil (bir şey değişmez). Saf fonksiyondur.
public func addingFolder(saved: [String], records: [MeetingRecord], name: String) -> [String]? {
    let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !meetingFolders(records: records, saved: saved).contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
        return nil
    }
    return saved + [trimmed]
}

/// Klasör çıkarılmış kayıtlı klasörler (büyük/küçük harf duyarsız). İçindeki toplantılar ayrıca klasörden çıkarılır.
/// Saf fonksiyondur.
public func removingFolder(saved: [String], name: String) -> [String] {
    saved.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
}
