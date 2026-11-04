import Foundation
import os

// Bu cihazda silinen hesabın toplantıları (yalnız abonelik sürümü). Hesap silinince sunucudaki veri gider, cihazdaki
// toplantılar `Accounts/<anahtar>/Sessions` altında kalır. Aynı kişi yeniden hesap açınca (yeni kullanıcı kimliği, yeni
// anahtar) eski klasöre ulaşamaz: silinen hesapların anahtarları silme anında bu cihazda saklanır, girişten sonra o
// klasörlerde toplantı varsa yeni hesaba taşımak önerilir. Taşıma eski verinin taşınmasıyla aynı yoldur (bkz.
// `migrateLegacyUserData`): toplantı başına atomik yeniden adlandırma, hiçbir şey silinmez ya da üzerine yazılmaz.

private let deletedAccountLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "DeletedAccountData")

/// Bu cihazda silinen hesapların anahtarlarını tutan dosyanın adı (`Accounts` içinde; satır başına bir anahtar).
public let deletedAccountsFileName: String = "deleted-accounts"

public extension AppPaths {
    /// Bu cihazda silinen hesapların listesi: `<veri klasörü>/Accounts/deleted-accounts`. Saf fonksiyondur.
    static func deletedAccountsFile(dataRoot: URL) -> URL {
        accountsDirectory(dataRoot: dataRoot).appending(path: deletedAccountsFileName, directoryHint: .notDirectory)
    }
}

/// Bu cihazda silinen hesapların anahtarları (kayıt sırasıyla); dosya yoksa boş. Bozuk satır varsa
/// `invalidAccountKey`: tahminle başka bir klasör önerilmez.
public func readDeletedAccountKeys(dataRoot: URL) throws -> [String] {
    let file: URL = AppPaths.deletedAccountsFile(dataRoot: dataRoot)
    guard FileManager.default.fileExists(atPath: file.path) else {
        return []
    }
    let text: String
    do {
        text = try String(contentsOf: file, encoding: .utf8)
    } catch {
        throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
    }
    let keys: [String] = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    for key in keys where !isValidAccountDataKey(key: key) {
        throw StorageError.invalidAccountKey(key: key)
    }
    return keys
}

/// Silinen hesabın anahtarını bu cihazın listesine ekler (zaten varsa bir şey olmaz). Dosya atomik yazılır: yarıda kalan
/// yazma listeyi bozmaz.
public func recordDeletedAccount(dataRoot: URL, accountKey: String) throws {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    let current: [String] = try readDeletedAccountKeys(dataRoot: dataRoot)
    guard !current.contains(accountKey) else {
        return
    }
    let file: URL = AppPaths.deletedAccountsFile(dataRoot: dataRoot)
    do {
        try FileManager.default.createDirectory(at: AppPaths.accountsDirectory(dataRoot: dataRoot), withIntermediateDirectories: true)
        try Data((current + [accountKey]).map { $0 + "\n" }.joined().utf8).write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
    deletedAccountLogger.info("Silinen hesap bu cihazda kaydedildi")
}

/// Silinen bir hesabın bu cihazda kalan toplantı klasörleri.
public struct DeletedAccountMeetings: Equatable, Sendable {
    public let accountKey: String
    /// Toplantı klasörlerinin adları (sıralı; gizli dosyalar sayılmaz).
    public let meetingFolders: [String]

    public init(accountKey: String, meetingFolders: [String]) {
        self.accountKey = accountKey
        self.meetingFolders = meetingFolders
    }
}

/// Bu cihazda silinen hesapların (`accountKey`, yani yüklü hesap hariç) toplantı klasörleri; toplantısı kalmayan hesap
/// listede yer almaz. Yalnızca adlar okunur, içerik okunmaz.
public func findDeletedAccountMeetings(dataRoot: URL, accountKey: String) throws -> [DeletedAccountMeetings] {
    try readDeletedAccountKeys(dataRoot: dataRoot)
        .filter { $0 != accountKey }
        .map { (key: String) throws -> DeletedAccountMeetings in
            DeletedAccountMeetings(
                accountKey: key, meetingFolders: try visibleFolders(directory: AppPaths.accountSessionsDirectory(dataRoot: dataRoot, accountKey: key))
            )
        }
        .filter { !$0.meetingFolders.isEmpty }
}

/// Klasördeki gizli olmayan alt klasörlerin adları (sıralı; dosyalar sayılmaz); klasör yoksa boş.
private func visibleFolders(directory: URL) throws -> [String] {
    try visibleEntries(directory: directory).filter { (name: String) -> Bool in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.appending(path: name).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Bulunan toplantıların sayısı. Saf fonksiyondur.
public func deletedAccountMeetingCount(found: [DeletedAccountMeetings]) -> Int {
    found.reduce(0) { (total: Int, item: DeletedAccountMeetings) -> Int in total + item.meetingFolders.count }
}

/// Taşıma teklifi kendiliğinden (ana pencerede, kayıt ekranında) görünsün mü: kullanıcının "Şimdi değil" dediği
/// (`dismissedKeys`) hesaplar dışında toplantısı kalan silinmiş hesap var. Geçilen teklif Ayarlar › Hesap'ta durur. Saf
/// fonksiyondur.
public func isDeletedMeetingsOfferVisible(found: [DeletedAccountMeetings], dismissedKeys: Set<String>) -> Bool {
    found.contains { !dismissedKeys.contains($0.accountKey) }
}

/// Silinen hesapların toplantılarının yüklü hesaba (`accountKey`) taşınma planı: her toplantı klasörü aynı adla
/// `Accounts/<accountKey>/Sessions` altına. Saf fonksiyondur.
public func deletedAccountMeetingMoves(dataRoot: URL, found: [DeletedAccountMeetings], accountKey: String) -> [DataMove] {
    let destination: URL = AppPaths.accountSessionsDirectory(dataRoot: dataRoot, accountKey: accountKey)
    return found.flatMap { (item: DeletedAccountMeetings) -> [DataMove] in
        let source: URL = AppPaths.accountSessionsDirectory(dataRoot: dataRoot, accountKey: item.accountKey)
        return item.meetingFolders.map { (name: String) -> DataMove in
            DataMove(
                source: source.appending(path: name, directoryHint: .isDirectory),
                destination: destination.appending(path: name, directoryHint: .isDirectory)
            )
        }
    }
}

/// Silinen hesapların toplantılarının taşınmasının sonucu.
public struct DeletedMeetingsMoveResult: Equatable, Sendable {
    /// Taşınan toplantılar.
    public let moves: [DataMove]
    /// Hedefte aynı adlı toplantı olduğu için taşınmayan, eski yerinde bırakılanlar.
    public let skipped: [DataMove]
}

/// Bu cihazda silinen hesapların toplantılarını yüklü hesaba (`accountKey`) taşır. Her toplantı aynı disk içinde atomik
/// yeniden adlandırmayla taşınır (`renamex_np`, `RENAME_EXCL`): kopyalanmaz, hedefteki hiçbir şeyin üzerine yazılmaz,
/// hiçbir şey silinmez; yarıda kalırsa taşınanlar yeni hesapta, kalanlar eski yerindedir ve yeniden denemek kaldığı
/// yerden sürer. Hedefinde aynı adlı toplantı olanlar taşınmaz (`skipped`). Bir taşıma başarısız olursa
/// `legacyDataMoveFailed` (taşınmamış olanlar yerinde kalır). Silinen hesabın klasörü (Sor geçmişi, kişiler) yerinde kalır.
public func moveDeletedAccountMeetings(dataRoot: URL, accountKey: String) throws -> DeletedMeetingsMoveResult {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    let planned: [DataMove] = deletedAccountMeetingMoves(
        dataRoot: dataRoot, found: try findDeletedAccountMeetings(dataRoot: dataRoot, accountKey: accountKey), accountKey: accountKey
    )
    let skipped: [DataMove] = planned.filter { FileManager.default.fileExists(atPath: $0.destination.path) }
    let moves: [DataMove] = planned.filter { !FileManager.default.fileExists(atPath: $0.destination.path) }
    for conflict in skipped {
        deletedAccountLogger.warning("Silinen hesabın toplantısı taşınmadı, hedefte aynı adlı toplantı var, toplantı: \(conflict.source.lastPathComponent, privacy: .private)")
    }
    for (index, move) in moves.enumerated() {
        try renameExclusively(move: move, movedSoFar: index)
    }
    if !moves.isEmpty {
        deletedAccountLogger.info("Silinen hesabın toplantıları hesaba taşındı, toplantı: \(moves.count, privacy: .public)")
    }
    return DeletedMeetingsMoveResult(moves: moves, skipped: skipped)
}
