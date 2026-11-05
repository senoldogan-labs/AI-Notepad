import Foundation
import OSLog

// Uygulama içi tanılama (Ayarlar › Tanılama): sürüm, sistem, hesap, bağlantı, izinler, canlı metin, güncelleme ve
// son hatalar. Arayüz ve kopyalanan metin aynı bölümlerden üretilir. Ses, metin, not, anahtar, jeton ve e-posta
// girmez; son hatalar uygulamanın kendi loglarından (yalnızca bu süreç, bellekte) okunur, yollar, adresler,
// kullanıcı adları, anahtarlar ve jetonlar silinir (bkz. `redactedSensitiveText`).

/// Tanılama değerinin durumu: ekranda kötü değer uyarı renginde simgeyle gösterilir; kopyalanan metne yansımaz.
public enum DiagnosticsStatus: Sendable, Equatable {
    /// Olağan değer; renksiz.
    case plain
    /// Dikkat (reddedilen izin, bilinmeyen durum).
    case attention
    /// Hata (ulaşılamayan sunucu, başarısız işlem).
    case error
}

/// Tanılamanın bir satırı: etiket, değer ve değerin durumu.
public struct DiagnosticsItem: Sendable, Equatable {
    public let label: String
    public let value: String
    public let status: DiagnosticsStatus

    public init(label: String, value: String, status: DiagnosticsStatus) {
        self.label = label
        self.value = value
        self.status = status
    }
}

/// Tanılamanın başlıklı bölümü.
public struct DiagnosticsSection: Sendable, Equatable {
    public let title: String
    public let items: [DiagnosticsItem]

    public init(title: String, items: [DiagnosticsItem]) {
        self.title = title
        self.items = items
    }
}

/// Uygulamanın son hatalarından biri: zaman, kod (log kategorisi ve düzeyi) ve kısa, temizlenmiş mesaj.
public struct DiagnosticErrorEntry: Sendable, Equatable {
    public let date: Date
    public let code: String
    public let message: String

    public init(date: Date, code: String, message: String) {
        self.date = date
        self.code = code
        self.message = message
    }
}

/// Tanılamada tutulan en çok hata.
public let diagnosticErrorCapacity: Int = 50

/// Hata mesajının en uzun hali (karakter).
public let diagnosticMessageMaxLength: Int = 200

/// Sunucuya erişim denetiminin sonucu.
public enum APIHealth: Sendable, Equatable {
    /// `GET /v1/health` 2xx döndü.
    case reachable(latencyMs: Int)
    /// Sunucu yanıt verdi ama 2xx değil.
    case unhealthy(status: Int, latencyMs: Int)
    /// Sunucuya ulaşılamadı (ağ, DNS, zaman aşımı); neden URLError kodudur.
    case unreachable(reason: String)
}

/// Metinden kişisel ve gizli parçaları siler (kısaltmaz):
/// - web adresleri: yalnızca şema ve sunucu kalır; kullanıcı bilgisi, yol, sorgu ve parça `‹yol›` olur (Slack, Discord,
///   Teams ve MCP adreslerinin gizlisi yolda, Deepgram'ınki sorguda `token=`);
/// - dosya yolları (boşluklu adlar dahil; ev klasörü kullanıcı adını taşır) ve e-posta adresleri;
/// - `Bearer`, `Token` (Deepgram) ve `Basic` yetki başlıkları, JWT (abonelik erişim jetonu, Deepgram izni, Atlassian);
/// - önekli anahtar ve jetonlar: `sk-`/`sk_` (Anthropic, OpenAI, ElevenLabs, Stripe, RevenueCat), Stripe `rk_`/`pk_`/
///   `whsec_`, RevenueCat `appl_`/`goog_`, Slack `xox?-`/`xapp-`, Notion `ntn_`/`secret_`, Linear `lin_api_`/
///   `lin_oauth_`, Atlassian `ATATT`, GitHub `ghp_`, Google `ya29.`;
/// - Stripe ve RevenueCat müşteri/abonelik kimlikleri;
/// - `access_token=`, `"refreshToken":` gibi anahtar=değer biçimindeki gizli değerler;
/// - önekisiz uzun jetonlar (abonelik yenileme jetonu, Deepgram anahtarı): 32+ karakterlik, harf ve rakam içeren
///   base64url dizileri (UUID ve bellek adresi aralıkları hata ayıklamaya yaradığı için kalır);
/// - verilen kullanıcı adları (3 karakterden kısa adlar metni bozmasın diye atlanır).
/// Saf fonksiyondur.
public func redactedSensitiveText(text: String, userNames: [String]) -> String {
    var result: String = text
    result = result.replacing(/((?i:https?|wss?)):\/\/(?:[^\s\/@"'<>]+@)?([^\s\/?#"'<>@]+)([\/?#][^\s"'<>]*)?/) { match in
        let rest: Substring = match.output.3 ?? ""
        return "\(match.output.1)://\(match.output.2)" + (rest.isEmpty || rest == "/" ? "" : "/‹yol›")
    }
    result = result.replacing(
        /(?:file:\/\/)?(?:\/Users|\/private|\/var|\/Volumes|\/tmp|\/Library|~)\/(?:[^\n\r"'“”‘’,;:()\[\]{}<>]*[^\s"'“”‘’,;:()\[\]{}<>])?/,
        with: "‹yol›"
    )
    result = result.replacing(/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/, with: "‹e-posta›")
    result = result.replacing(/(?i:bearer)\s+\S+/, with: "Bearer ‹jeton›")
    result = result.replacing(/\b(?i:token)\s+[A-Za-z0-9._\-]{20,}/, with: "Token ‹jeton›")
    result = result.replacing(/\b(?i:basic)\s+[A-Za-z0-9+\/]{12,}={0,2}/, with: "Basic ‹jeton›")
    result = result.replacing(/eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+/, with: "‹jeton›")
    result = result.replacing(/\bsk[\-_][A-Za-z0-9_\-]{16,}/, with: "‹anahtar›")
    result = result.replacing(/\b(?:rk_|pk_|whsec_|appl_|goog_|amzn_|strp_|rcb_)[A-Za-z0-9_]{16,}/, with: "‹anahtar›")
    result = result.replacing(/\b(?:xox[abposre]|xapp)-[A-Za-z0-9\-]{8,}/, with: "‹jeton›")
    result = result.replacing(/\b(?:ntn_|secret_|lin_api_|lin_oauth_|lin_wh_|gh[pousr]_)[A-Za-z0-9_]{16,}/, with: "‹jeton›")
    result = result.replacing(/\bAT(?:ATT|CTT)[A-Za-z0-9_\-=]{16,}/, with: "‹jeton›")
    result = result.replacing(/\bya29\.[A-Za-z0-9_\-]{16,}/, with: "‹jeton›")
    result = result.replacing(/\b(?:cus|sub|evt|pi|pm|seti|cs_live|cs_test)_[A-Za-z0-9]{14,}/, with: "‹kimlik›")
    result = result.replacing(/\$RCAnonymousID:[0-9A-Fa-f]{16,}/, with: "‹kimlik›")
    result = result.replacing(
        /\b((?i:access_?token|refresh_?token|id_?token|client_?secret|api_?key|x-api-key|xi-api-key|token|secret|password|signature|sig)["']?\s*[=:]\s*["']?)[^\s"'&,;}]+/
    ) { match in
        "\(match.output.1)‹gizli›"
    }
    result = result.replacing(/[A-Za-z0-9_\-]{32,}/) { match in
        isLongOpaqueToken(text: match.output) ? "‹jeton›" : String(match.output)
    }
    for name in userNames where name.count >= 3 {
        result = result.replacingOccurrences(of: name, with: "‹kullanıcı›", options: .caseInsensitive)
    }
    return result
}

/// 32+ karakterlik base64url dizisinin jeton sayılıp sayılmadığı: harf ve rakam içerir; UUID ya da bellek adresi
/// (aralığı) değildir. Saf fonksiyondur.
private func isLongOpaqueToken(text: Substring) -> Bool {
    guard text.contains(where: \.isLetter), text.contains(where: \.isNumber) else {
        return false
    }
    let isUUID: Bool = text.wholeMatch(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/) != nil
    let isAddressRange: Bool = text.wholeMatch(of: /(?:0x)?[0-9A-Fa-f]{1,16}-(?:0x)?[0-9A-Fa-f]{1,16}/) != nil
    return !isUUID && !isAddressRange
}

/// Tanılama satırına girecek metin: `redactedSensitiveText` ile temizlenir, kırpılır ve `diagnosticMessageMaxLength`
/// karaktere kısaltılır. Saf fonksiyondur.
public func redactedDiagnosticText(text: String, userNames: [String]) -> String {
    let trimmed: String = redactedSensitiveText(text: text, userNames: userNames).trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > diagnosticMessageMaxLength ? String(trimmed.prefix(diagnosticMessageMaxLength - 1)) + "…" : trimmed
}

/// Hataları zamana göre sıralar ve en yeni `capacity` tanesini (eskiden yeniye) bırakır. Saf fonksiyondur.
public func recentDiagnosticErrors(entries: [DiagnosticErrorEntry], capacity: Int) -> [DiagnosticErrorEntry] {
    Array(entries.sorted { $0.date < $1.date }.suffix(capacity))
}

/// Bu sürecin `subsystem` loglarından son hata ve arıza kayıtları (en çok `capacity`, eskiden yeniye). Kod log
/// kategorisi ve düzeyidir; mesaj `redactedDiagnosticText` ile temizlenir. Loglarda `privacy: .private` değerler zaten
/// `<private>` olarak okunur. Kayıtlar bellekte kalır, hiçbir yere yazılmaz. Log deposu açılamazsa hata fırlar.
public func loadRecentAppErrors(subsystem: String, capacity: Int, userNames: [String]) throws -> [DiagnosticErrorEntry] {
    let store: OSLogStore = try OSLogStore(scope: .currentProcessIdentifier)
    let entries: AnySequence<OSLogEntry> = try store.getEntries(
        with: [.reverse], at: store.position(date: Date()), matching: NSPredicate(format: "subsystem == %@", subsystem)
    )
    var found: [DiagnosticErrorEntry] = []
    for entry in entries {
        guard let log = entry as? OSLogEntryLog, log.level == .error || log.level == .fault else {
            continue
        }
        let level: String = log.level == .fault ? "fault" : "error"
        found.append(DiagnosticErrorEntry(
            date: log.date, code: "\(log.category).\(level)", message: redactedDiagnosticText(text: log.composedMessage, userNames: userNames)
        ))
        if found.count >= capacity {
            break
        }
    }
    return recentDiagnosticErrors(entries: found, capacity: capacity)
}

/// Sunucunun `GET /v1/health` ucunu bir kez dener ve gecikmeyi ölçer (gecikme ölçümü olduğu için yeniden denenmez).
/// Ağ hatası `unreachable` olur; URLError dışı hata fırlar.
public func checkAPIHealth(baseURL: URL, timeoutSec: Double) async throws -> APIHealth {
    var request: URLRequest = URLRequest(url: baseURL.appending(path: "v1/health"))
    request.httpMethod = "GET"
    request.timeoutInterval = timeoutSec
    request.cachePolicy = .reloadIgnoringLocalCacheData
    let clock: ContinuousClock = ContinuousClock()
    let started: ContinuousClock.Instant = clock.now
    let response: URLResponse
    do {
        (_, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
        return .unreachable(reason: "URLError \(error.code.rawValue)")
    }
    let elapsed: Duration = clock.now - started
    let latencyMs: Int = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
    return (200..<300).contains(status) ? .reachable(latencyMs: latencyMs) : .unhealthy(status: status, latencyMs: latencyMs)
}

/// Bu Mac'in model tanımı (ör. "Mac15,6"; seri numarası ya da donanım kimliği değildir). Okunamazsa `POSIXError`.
public func macModelIdentifier() throws -> String {
    var size: Int = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    var buffer: [CChar] = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// Tanılamanın düz metni (panoya ve geri bildirime): başlık, oluşturulma zamanı ve bölümler. Saf fonksiyondur.
public func diagnosticsText(sections: [DiagnosticsSection], generatedAt: Date) -> String {
    let header: String = "Diagnostics · \(generatedAt.formatted(.iso8601))"
    let body: [String] = sections.map { (section: DiagnosticsSection) -> String in
        ([section.title] + section.items.map { "- \($0.label): \($0.value)" }).joined(separator: "\n")
    }
    return ([header] + body).joined(separator: "\n\n")
}

/// Geri bildirimin mesajına tanılama metnini ekler. Sunucu mesajı `limit` karakterle (UTF-16) sınırlar: tanılama sığmazsa
/// sonundan kısaltılır; kullanıcının mesajı hiç kısaltılmaz. Ayraçla birlikte en az 100 karakterlik yer yoksa
/// `messageTooLong` (kullanıcı mesajı kısaltmalı ya da tanılamayı kapatmalı). Saf fonksiyondur.
public func appendingDiagnostics(report: ReportRequest, diagnosticsText: String, limit: Int) throws -> ReportRequest {
    let message: String = report.message ?? ""
    let separator: String = "\n\n--- Diagnostics ---\n"
    let room: Int = limit - reportMessageLength(text: message) - reportMessageLength(text: separator)
    guard room >= 100 else {
        throw ReportError.messageTooLong(count: reportMessageLength(text: message + separator + diagnosticsText), limit: limit)
    }
    let fitted: String = fittingPrefix(text: diagnosticsText, maxLength: room)
    return ReportRequest(
        kind: report.kind, message: message + separator + fitted, email: report.email,
        appVersion: report.appVersion, os: report.os, payload: report.payload
    )
}

/// Metnin `maxLength` UTF-16 birimine sığan başı; kısaltıldıysa sonu "…". Saf fonksiyondur.
private func fittingPrefix(text: String, maxLength: Int) -> String {
    guard reportMessageLength(text: text) > maxLength else {
        return text
    }
    var result: String = ""
    var length: Int = 0
    for character in text {
        let size: Int = String(character).utf16.count
        guard length + size <= maxLength - 1 else {
            break
        }
        result.append(character)
        length += size
    }
    return result + "…"
}
