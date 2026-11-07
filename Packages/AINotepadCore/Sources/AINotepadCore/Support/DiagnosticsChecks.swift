import AVFAudio
import EventKit
import Foundation
import os

// Mac ve iPhone tanılamasının ortak bölümleri (Ayarlar › Tanılama): izin satırları, son hatalar, sunucu denetimi ve
// depolama. Ses, metin, not, anahtar, jeton ve e-posta girmez.

private let diagnosticsChecksLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Diagnostics")

/// Mikrofon izninin satırı; reddedildiyse hata (kayıt yapılamaz). Saf fonksiyondur.
public func microphonePermissionDiagnostics(permission: AVAudioApplication.recordPermission) -> DiagnosticsItem {
    let label: String = String(localized: "Mikrofon")
    switch permission {
    case .granted: return DiagnosticsItem(label: label, value: String(localized: "İzin verildi"), status: .plain)
    case .denied: return DiagnosticsItem(label: label, value: String(localized: "Reddedildi"), status: .error)
    case .undetermined: return DiagnosticsItem(label: label, value: String(localized: "Henüz sorulmadı"), status: .plain)
    @unknown default: return DiagnosticsItem(label: label, value: String(localized: "Bilinmiyor"), status: .plain)
    }
}

/// Takvim ya da anımsatıcı izninin satırı; reddedildiyse ya da kısıtlıysa dikkat. Saf fonksiyondur.
public func eventKitPermissionDiagnostics(label: String, status: EKAuthorizationStatus) -> DiagnosticsItem {
    switch status {
    case .fullAccess: DiagnosticsItem(label: label, value: String(localized: "Tam erişim"), status: .plain)
    case .writeOnly: DiagnosticsItem(label: label, value: String(localized: "Yalnızca yazma"), status: .plain)
    case .denied: DiagnosticsItem(label: label, value: String(localized: "Reddedildi"), status: .attention)
    case .restricted: DiagnosticsItem(label: label, value: String(localized: "Kısıtlı"), status: .attention)
    case .notDetermined: DiagnosticsItem(label: label, value: String(localized: "Henüz sorulmadı"), status: .plain)
    @unknown default: DiagnosticsItem(label: label, value: String(localized: "Bilinmiyor"), status: .plain)
    }
}

/// Son hatalar bölümü, ekranda (en çok 50): zaman ve kullanıcının anlayacağı alan. Kod ve günlük metni geliştirici
/// içindir (Türkçe, teknik); ekranda gösterilmez. Saf fonksiyondur.
public func recentErrorsDiagnostics(errors: Result<[DiagnosticErrorEntry], any Error>) -> DiagnosticsSection {
    let title: String = String(localized: "Son hatalar")
    switch errors {
    case .failure:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Okunamadı"), status: .error)])
    case .success(let entries) where entries.isEmpty:
        return DiagnosticsSection(title: title, items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Bu oturumda hata yok"), status: .plain)])
    case .success(let entries):
        return DiagnosticsSection(title: title, items: entries.map { (entry: DiagnosticErrorEntry) -> DiagnosticsItem in
            DiagnosticsItem(label: entry.date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(interfaceLocale())), value: diagnosticErrorArea(code: entry.code), status: .plain)
        })
    }
}

/// Son hatalar bölümü, günlük henüz okunurken: "hata yok" denmez (yanlış tanı olurdu). Saf fonksiyondur.
public func pendingRecentErrorsDiagnostics() -> DiagnosticsSection {
    DiagnosticsSection(title: String(localized: "Son hatalar"), items: [DiagnosticsItem(label: String(localized: "Kayıt"), value: String(localized: "Okunuyor…"), status: .plain)])
}

/// Hatanın günlük kategorisinden (`kategori.düzey`) kullanıcının anlayacağı alan adı. Saf fonksiyondur.
public func diagnosticErrorArea(code: String) -> String {
    let category: String = String(code.split(separator: ".").first ?? "")
    switch category {
    case "Update":
        return String(localized: "Güncelleme")
    case "Hosted", "HostedAccount", "HostedSeams", "HostedGate", "HostedAttest", "HostedAccountData", "AccountData", "PhoneHosted", "AppStorePurchases", "Paywall":
        return String(localized: "Hesap")
    case "Deepgram", "CloudLiveSession", "HybridLiveSession", "LiveSession", "WhisperKitEngine", "AppleSpeech":
        return String(localized: "Canlı metin")
    case "SystemAudioCapture", "MicrophoneCapture", "AudioPlayer", "PhoneRecorder", "MediaImport", "CallCapture":
        return String(localized: "Ses")
    case "ProcessMeeting", "ChunkedNote", "LLM", "OnDeviceLLM", "ElevenLabs", "HostedFinal", "LocalFinalPass", "VoiceModel":
        return String(localized: "Not hazırlama")
    case "Meetings", "CloudStorage", "PhoneStore":
        return String(localized: "Toplantılar")
    case "Webhook", "Destinations", "MCPRemote", "MCPIntegrations", "LoopbackRedirect", "Channel", "MCP":
        return String(localized: "Bağlantılar")
    default:
        return String(localized: "Uygulama")
    }
}

/// Bu uygulama oturumunun son hataları (`subsystem` günlüğünden, ana iş parçacığı dışında; bkz. `loadRecentAppErrors`).
public func loadRecentAppErrorsInBackground(subsystem: String, userNames: [String]) async -> Result<[DiagnosticErrorEntry], any Error> {
    await runBlocking(qos: .utility) { () -> Result<[DiagnosticErrorEntry], any Error> in
        Result { try loadRecentAppErrors(subsystem: subsystem, capacity: diagnosticErrorCapacity, userNames: userNames) }
    }
}

/// Sunucuya erişimi denetler (bkz. `checkAPIHealth`); adres yoksa nil (bölüm adres hatasını gösterir). URLError dışı
/// hata loglanır ve ulaşılamadı sayılır (nedeni hata türü).
public func probeAPIHealth(base: Result<URL, any Error>, timeoutSec: Double) async -> APIHealth? {
    guard case .success(let url) = base else {
        return nil
    }
    do {
        return try await checkAPIHealth(baseURL: url, timeoutSec: timeoutSec)
    } catch {
        diagnosticsChecksLogger.error("Sunucu denetlenemedi, hata: \(String(describing: error), privacy: .private)")
        return .unreachable(reason: String(describing: type(of: error)))
    }
}

/// Bu cihazın donanım tanımı (iPhone'da ör. "iPhone18,1"; Simülatör'de işlemci mimarisi). Seri numarası ya da donanım
/// kimliği değildir. Okunamazsa `POSIXError`.
public func deviceMachineIdentifier() throws -> String {
    var size: Int = 0
    guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    var buffer: [CChar] = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Klasörün içindeki dosyaların toplam boyutu (bayt; alt klasörler dahil). Klasör yoksa 0; okunamazsa
/// `StorageError.readFailed`.
public func directorySize(url: URL) throws -> Int64 {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return 0
    }
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: nil) else {
        throw StorageError.readFailed(path: url.path, reason: "klasör listelenemedi")
    }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        do {
            let values: URLResourceValues = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        } catch {
            throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
        }
    }
    return total
}

/// Cihazda önemli işler için kullanılabilir boş alan (bayt; iOS'un silinebilir önbellekleri dahil). Okunamazsa
/// `StorageError.readFailed`.
public func availableCapacity(url: URL) throws -> Int64 {
    do {
        let values: URLResourceValues = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
            throw StorageError.readFailed(path: url.path, reason: "boş alan bildirilmedi")
        }
        return capacity
    } catch let error as StorageError {
        throw error
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Depolama satırı: boyut okunduysa biçimlendirilmiş (ör. "1,2 GB"), okunamadıysa hata. Saf fonksiyondur.
public func storageSizeDiagnostics(label: String, size: Result<Int64, any Error>) -> DiagnosticsItem {
    switch size {
    case .success(let bytes):
        return DiagnosticsItem(label: label, value: bytes.formatted(.byteCount(style: .file)), status: .plain)
    case .failure(let error):
        return DiagnosticsItem(label: label, value: String(localized: "okunamadı: \(userFacingMessage(error: error))"), status: .error)
    }
}

/// Boş alan satırı: 1 GB'ın altında dikkat (uzun kayıt ve model indirmesi sığmayabilir). Saf fonksiyondur.
public func freeSpaceDiagnostics(capacity: Result<Int64, any Error>) -> DiagnosticsItem {
    let label: String = String(localized: "Boş alan")
    switch capacity {
    case .success(let bytes):
        return DiagnosticsItem(label: label, value: bytes.formatted(.byteCount(style: .file)), status: bytes < 1_000_000_000 ? .attention : .plain)
    case .failure(let error):
        return DiagnosticsItem(label: label, value: String(localized: "okunamadı: \(userFacingMessage(error: error))"), status: .error)
    }
}
