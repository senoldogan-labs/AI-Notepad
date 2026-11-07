import AINotepadCore
import Foundation
import Observation
import os

/// Paylaşım sayfasından ("Gistsmith") gelen dosyaların bekleme kutusu: iOS dosyayı uygulamanın `Documents/Inbox`
/// klasörüne kopyalar ve adresini verir (`onOpenURL`). Kutu uygulama kökünde yaşar: giriş kapısı ya da yapay zekâ
/// açıklaması açıkken gelen dosya da bekler; ana ekran açılınca `PhoneImportHost` alır ve toplantı olarak içe aktarır.
/// Telefon görüşmesi için asıl yol budur: iPhone'un arama kaydı Notlar'dan sesi paylaşılarak gelir.
@MainActor
@Observable
final class PhoneSharedFileInbox {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SharedFiles")

    /// İçe aktarılmayı bekleyen dosyalar (gelen kutusundaki kopyalar).
    private(set) var pending: [URL] = []
    /// Ses ya da video olmadığı için alınmayan dosyaların adları (ana ekranda bir kez görünür).
    private(set) var rejected: [String] = []

    /// Önceki açılışta içe aktarma bitmeden uygulama kapandıysa gelen kutusunda kalan kopyalar yeniden bekler (kopya ancak
    /// içe aktarmadan sonra silinir).
    init() {
        for url in leftoverSharedInboxFiles() {
            receive(url: url)
        }
    }

    /// Sistemin verdiği adresi alır. Dosya olmayan adres bu kutunun işi değildir (giriş dönüşü kendi oturumuna gelir);
    /// ses ya da video olmayan dosyanın kopyası silinir, adı bildirilir.
    func receive(url: URL) {
        guard url.isFileURL else {
            Self.logger.info("Dosya olmayan adres açıldı, yok sayıldı, şema: \(url.scheme ?? "-", privacy: .public)")
            return
        }
        guard isImportableSharedMedia(url: url) else {
            Self.logger.warning("Paylaşılan dosya ses ya da video değil, uzantı: \(url.pathExtension, privacy: .public)")
            rejected.append(url.lastPathComponent)
            removeSharedInboxCopy(url: url)
            return
        }
        Self.logger.info("Paylaşılan dosya alındı, uzantı: \(url.pathExtension, privacy: .public)")
        pending.append(url)
    }

    /// Bekleyen dosyaları verir ve kutuyu boşaltır.
    func takePending() -> [URL] {
        let taken: [URL] = pending
        pending = []
        return taken
    }

    /// Alınmayan dosyaların adlarını verir ve listeyi boşaltır.
    func takeRejected() -> [String] {
        let taken: [String] = rejected
        rejected = []
        return taken
    }
}

/// Paylaşım sayfasının gelen kutusuna kopyalanan dosyayı siler (içe aktarıldıktan ya da reddedildikten sonra). Kutu dışındaki
/// dosyaya dokunulmaz; silinemezse loglanır (kopya uygulamanın kabında kalır, kaynak dosya etkilenmez).
@MainActor
func removeSharedInboxCopy(url: URL) {
    // Sistem adresi `/private/var/…` ya da `/var/…` biçiminde verebilir: iki yol da aynı biçime çözülür.
    let documents: URL = URL.documentsDirectory.resolvingSymlinksInPath()
    guard isSharedInboxCopy(url: url.resolvingSymlinksInPath(), documentsDirectory: documents) else {
        sharedFilesLogger.info("Paylaşılan dosya gelen kutusunda değil, silinmedi")
        return
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        sharedFilesLogger.error("Paylaşılan dosyanın kopyası silinemedi, hata: \(String(describing: error), privacy: .private)")
    }
}

/// Gelen kutusunda kalan dosyalar (yoksa boş). Okunamazsa loglanır; kopyalar bir sonraki açılışta yeniden denenir.
@MainActor
private func leftoverSharedInboxFiles() -> [URL] {
    let inbox: URL = URL.documentsDirectory.appending(path: "Inbox", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: inbox.path) else {
        return []
    }
    do {
        return try FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    } catch {
        sharedFilesLogger.error("Gelen kutusu okunamadı, hata: \(String(describing: error), privacy: .private)")
        return []
    }
}

private let sharedFilesLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SharedFiles")
