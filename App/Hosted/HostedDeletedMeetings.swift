import AINotepadCore
import Foundation
import os

// Bu cihazda silinen hesabın toplantıları (Mac ve iPhone ortak): hesap silinince anahtarı bu cihazda saklanır (bkz.
// `HostedAccount.deleteAccount`), toplantıları `Accounts/<anahtar>/Sessions` altında kalır. Yeniden hesap açılınca
// (yeni kullanıcı, yeni klasör) bu toplantılar bir kez önerilir: Mac'te ana pencerenin üstünde şerit, iPhone'da kayıt
// ekranında kart; "Şimdi değil" denince yalnızca Ayarlar › Hesap'ta kalır. Taşıma pakettedir (bkz.
// `moveDeletedAccountMeetings`): toplantı başına atomik, hiçbir şey silinmez.

private let deletedMeetingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedDeletedMeetings")

/// Yüklü hesabın ayar alanında: taşıma teklifine "Şimdi değil" denen silinmiş hesapların anahtarları.
private let dismissedDeletedAccountsKey: String = "deletedAccounts.dismissed"

/// Silinen hesabın toplantılarının durumu ve taşınması (yüklü hesap için). Hesap verisi yüklenince ve hesap değişince
/// yeniden okunur (`refresh`).
@MainActor
@Observable
final class HostedDeletedMeetings {
    static let shared: HostedDeletedMeetings = HostedDeletedMeetings()

    /// Bu cihazda silinen hesaplardan kalan toplantılar (yüklü hesap hariç); okunmadıysa boş.
    private(set) var found: [DeletedAccountMeetings] = []
    /// Taşıma teklifine "Şimdi değil" denen silinmiş hesaplar.
    private(set) var dismissedKeys: Set<String> = []
    /// Okuma ya da taşıma hatası (teklifte ve Ayarlar › Hesap'ta görünür); yoksa nil.
    private(set) var problem: String?

    private init() {}

    /// Taşınabilecek toplantı sayısı.
    var count: Int {
        deletedAccountMeetingCount(found: found)
    }

    /// Teklif kendiliğinden (Mac'te şerit, iPhone'da kart) görünsün mü.
    var isOfferVisible: Bool {
        isDeletedMeetingsOfferVisible(found: found, dismissedKeys: dismissedKeys)
    }

    /// Yüklü hesap için yeniden okur (hesap verisi yüklenince ve hesap değişince). Hesap yüklenmediyse liste boşalır.
    func refresh() {
        guard let accountKey = AppPaths.activeAccountKey() else {
            found = []
            dismissedKeys = []
            return
        }
        do {
            found = try findDeletedAccountMeetings(dataRoot: try AppPaths.applicationSupport(), accountKey: accountKey)
            dismissedKeys = Set(try hostedActiveAccountDefaults().stringArray(forKey: dismissedDeletedAccountsKey) ?? [])
            problem = nil
        } catch {
            deletedMeetingsLogger.error("Silinen hesabın toplantıları okunamadı, hata: \(String(describing: error), privacy: .private)")
            problem = userFacingMessage(error: error)
        }
    }

    /// Teklifi geçer ("Şimdi değil"): bulunan silinmiş hesaplar bir daha kendiliğinden önerilmez; Ayarlar › Hesap'ta
    /// kalır. Saklanamazsa neden görünür.
    func dismiss() {
        let updated: Set<String> = dismissedKeys.union(found.map(\.accountKey))
        do {
            try hostedActiveAccountDefaults().set(updated.sorted(), forKey: dismissedDeletedAccountsKey)
            dismissedKeys = updated
        } catch {
            deletedMeetingsLogger.error("Teklif geçilemedi, hata: \(String(describing: error), privacy: .private)")
            problem = userFacingMessage(error: error)
        }
    }

    /// Silinen hesapların toplantılarını yüklü hesaba taşır; taşınan toplantı sayısı döner (çağıran toplantı listesini
    /// yeniden okur). Silinen hesabın bekleyen (çevrimdışı) kayıtları artık giriş yapan kullanıcınındır (`userID`):
    /// bağlantı gelince bu hesabın kuyruğunda işlenir. Teklif kapanır; aynı adlı toplantı yüzünden taşınamayan kalırsa
    /// Ayarlar › Hesap'ta görünür. Taşıma yarıda kalırsa neden görünür, taşınanlar yeni hesapta, kalanlar yerinde kalır.
    func moveIntoActiveAccount(userID: String) -> Int {
        guard let accountKey = AppPaths.activeAccountKey() else {
            problem = userFacingMessage(error: StorageError.accountNotSelected)
            return 0
        }
        let failure: String?
        do {
            let dataRoot: URL = try AppPaths.applicationSupport()
            // Taşımadan önceki plan: yarıda kalsa da taşınanların (kaynağı gitmiş, hedefi var) sahipliği güncellenir.
            let planned: [DataMove] = deletedAccountMeetingMoves(dataRoot: dataRoot, found: found, accountKey: accountKey)
            do {
                let result: DeletedMeetingsMoveResult = try moveDeletedAccountMeetings(dataRoot: dataRoot, accountKey: accountKey)
                deletedMeetingsLogger.info("Silinen hesabın toplantıları taşındı, taşınan: \(result.moves.count, privacy: .public), kalan: \(result.skipped.count, privacy: .public)")
                failure = nil
            } catch {
                deletedMeetingsLogger.error("Silinen hesabın toplantıları taşınamadı, hata: \(String(describing: error), privacy: .private)")
                failure = userFacingMessage(error: error)
            }
            reassignMovedRecordOwners(planned: planned, userID: userID)
        } catch {
            deletedMeetingsLogger.error("Veri klasörü açılamadı, hata: \(String(describing: error), privacy: .private)")
            failure = userFacingMessage(error: error)
        }
        let before: Int = count
        refresh()
        let movedCount: Int = max(0, before - count)
        // Okuma başarılı olsa da taşımanın hatası görünür kalır.
        problem = failure ?? problem
        if failure == nil {
            dismiss()
        }
        return movedCount
    }

    /// Taşınan toplantılardan (kaynağı gitmiş, hedefi var) bekleyen kaydı olanların sahibi artık giriş yapan kullanıcıdır:
    /// silinen hesabın kuyruğunda değil bu hesabınkinde işlenir.
    private func reassignMovedRecordOwners(planned: [DataMove], userID: String) {
        let owners: [String: String] = loadHostedRecordOwners()
        let moved: [DataMove] = planned.filter { (move: DataMove) -> Bool in
            !FileManager.default.fileExists(atPath: move.source.path) && FileManager.default.fileExists(atPath: move.destination.path)
        }
        for move in moved where owners[move.destination.lastPathComponent].map({ $0 != userID }) ?? false {
            saveHostedRecordOwner(recordID: move.destination.lastPathComponent, userId: userID)
        }
    }
}
