import Foundation
import os

private let reportsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Reports")

/// Geri bildirim ve çökme raporlarının gittiği sunucunun Info.plist anahtarı (geliştirici sürümü ve iPhone; abonelik
/// sürümü kendi `HostedAPIBase`'ini kullanır).
public let reportsAPIBaseInfoKey: String = "ReportsAPIBase"

/// Mesajın en uzun hali (sunucunun sınırı; JavaScript uzunluğu gibi UTF-16 birimiyle sayılır).
public let reportMessageLimit: Int = 5000

/// Teşhis paketinin (MetricKit JSON) en büyük hali, bayt (sunucunun sınırı: rapor başına 64 KB).
public let reportPayloadLimitBytes: Int = 64 * 1024

/// E-posta adresinin en uzun hali (RFC 5321).
private let reportEmailLimit: Int = 254

/// Alıntı izniyle verilen ön adın en uzun hali (Unicode kod noktası; sunucunun sınırı).
public let feedbackQuoteNameLimit: Int = 40

/// Rapor isteğinin zaman aşımı.
private let reportRequestTimeoutSec: Double = 30

/// `POST /v1/reports` yolu.
private let reportsPath: String = "/v1/reports"

/// Raporun türü (sunucunun `kind` alanı).
public enum ReportKind: String, Encodable, Sendable, Equatable {
    case feedback
    case crash
}

/// Kullanıcının isteğiyle rapora eklenen tanılama bilgisi: sürüm ve sistem.
public struct ReportDiagnostics: Sendable, Equatable {
    /// Ör. "0.1.3 (4)".
    public let appVersion: String
    /// Ör. "macOS Version 26.1 (Build 25B78)".
    public let os: String

    public init(appVersion: String, os: String) {
        self.appVersion = appVersion
        self.os = os
    }
}

/// `POST /v1/reports` gövdesi; boş alanlar gönderilmez.
public struct ReportRequest: Encodable, Sendable, Equatable {
    public let kind: ReportKind
    public let message: String?
    /// Yanıt için e-posta (isteğe bağlı).
    public let email: String?
    public let appVersion: String?
    public let os: String?
    /// MetricKit teşhis paketi, JSON metni olarak (yalnızca çökme raporunda).
    public let payload: String?
    /// Kullanıcı "gistsmith.com'da ön adımla alıntılanabilir" kutusunu işaretlediyse ön adı (yalnızca geri bildirimde);
    /// yoksa izin yok. Sunucu bunu yalnızca saklar: hiçbir şey kendiliğinden yayımlanmaz.
    public let quoteFirstName: String?
}

/// Raporun gideceği sunucu ve (giriş yapılmışsa) erişim jetonu.
public struct ReportDestination: Sendable, Equatable {
    public let baseURL: URL
    /// Abonelik sürümünde giriş yapılmışsa bearer olarak eklenir; yoksa nil.
    public let accessToken: String?

    public init(baseURL: URL, accessToken: String?) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }
}

/// Rapor gönderilmeden önce yakalanan sorunlar.
public enum ReportError: Error, Sendable, Equatable {
    /// Geri bildirim mesajı boş.
    case emptyMessage
    /// Mesaj sunucunun sınırını aşıyor.
    case messageTooLong(count: Int, limit: Int)
    /// Yanıt e-postası geçerli bir adres değil.
    case invalidEmail
    /// Teşhis paketi sunucunun sınırını aşıyor.
    case payloadTooLarge(bytes: Int, limit: Int)
    /// Teşhis paketi UTF-8 metin değil.
    case payloadNotText
    /// Alıntı izni verildi ama ön ad boş ya da geçersiz (yalnız harf, boşluk, kesme, nokta ve tire; en çok 40).
    case invalidQuoteName
}

/// Sunucunun saydığı mesaj uzunluğu (UTF-16 birimi). Saf fonksiyondur.
public func reportMessageLength(text: String) -> Int {
    text.utf16.count
}

/// E-posta denetimi: sunucunun kuralıyla aynı (`server/src/reports.ts`, zod `z.email().max(254)`): `@` öncesi ASCII
/// harf, rakam ve `_ ' + -`, boş olmayan noktalı parçalar; alan adı harf ya da rakamla başlayan etiketler ve en az iki
/// harfli uzantı; en çok 254 karakter. Sunucunun reddedeceği adres burada `invalidEmail` olur ("sürüm uyuşmuyor"
/// görünmez). Saf fonksiyondur.
public func isPlausibleEmail(text: String) -> Bool {
    let pattern: Regex = /(?:[A-Za-z0-9_'+\-]+\.)*[A-Za-z0-9_'+\-]*[A-Za-z0-9_+\-]@(?:[A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}/
    return text.utf16.count <= reportEmailLimit && text.wholeMatch(of: pattern) != nil
}

/// Alıntı izniyle verilen ön adın gönderilen hali: kırpılır, tipografik kesme (’, klavyenin akıllı tırnağı) düz kesmeye
/// (') çevrilir. Sunucu da aynı çeviriyi yapar (`server/src/reports.ts`, `quoteFirstNameSchema`). Saf fonksiyondur.
public func normalizedQuoteFirstName(text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2019}", with: "'")
}

/// Alıntı izniyle verilen ön ad: sunucunun kuralıyla aynı (`server/src/reports.ts`, `quoteFirstNameSchema`): harfle
/// başlar, yalnız harf, birleşen işaret, boşluk, kesme (' ya da ’), nokta ve tire; en çok 40 kod noktası. Saf
/// fonksiyondur.
public func isValidQuoteFirstName(text: String) -> Bool {
    let pattern: Regex = /[\p{L}][\p{L}\p{M}'\u{2019} .\-]*/
    return text.unicodeScalars.count <= feedbackQuoteNameLimit
        && text.wholeMatch(of: pattern.matchingSemantics(.unicodeScalar)) != nil
}

/// Geri bildirim raporu: mesaj, e-posta ve ön ad kırpılır; mesaj boşsa ya da sınırı aşıyorsa, e-posta yazılmış ama
/// geçersizse, alıntı izni verilmiş (`quoteFirstName` nil değil) ama ön ad geçersizse hata. Tanılama yalnızca
/// verildiyse eklenir. Saf fonksiyondur.
public func feedbackReport(message: String, email: String, diagnostics: ReportDiagnostics?, quoteFirstName: String?) throws -> ReportRequest {
    let trimmedMessage: String = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEmail: String = email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMessage.isEmpty else {
        throw ReportError.emptyMessage
    }
    let length: Int = reportMessageLength(text: trimmedMessage)
    guard length <= reportMessageLimit else {
        throw ReportError.messageTooLong(count: length, limit: reportMessageLimit)
    }
    guard trimmedEmail.isEmpty || isPlausibleEmail(text: trimmedEmail) else {
        throw ReportError.invalidEmail
    }
    let trimmedQuoteName: String? = quoteFirstName.map { normalizedQuoteFirstName(text: $0) }
    if let trimmedQuoteName, !isValidQuoteFirstName(text: trimmedQuoteName) {
        throw ReportError.invalidQuoteName
    }
    return ReportRequest(
        kind: .feedback, message: trimmedMessage, email: trimmedEmail.isEmpty ? nil : trimmedEmail,
        appVersion: diagnostics?.appVersion, os: diagnostics?.os, payload: nil, quoteFirstName: trimmedQuoteName
    )
}

/// Çökme raporu: saklanan MetricKit JSON'u temizlenmiş ve gerekirse sunucunun sınırına sığacak kadar küçültülmüş
/// haliyle (bkz. `uploadableCrashPayload`), çöken sürüm ve sistemle. Paket metin değilse ya da en küçük hali de
/// sığmıyorsa `ReportError`; JSON çözülemezse `DecodingError`. Saf fonksiyondur.
public func crashReportRequest(payload: Data, diagnostic: CrashDiagnostic) throws -> ReportRequest {
    guard String(data: payload, encoding: .utf8) != nil else {
        throw ReportError.payloadNotText
    }
    let redacted: Data = try uploadableCrashPayload(payload: payload, limit: reportPayloadLimitBytes)
    return ReportRequest(
        kind: .crash, message: nil, email: nil,
        appVersion: appVersionText(version: diagnostic.appVersion, build: diagnostic.appBuild), os: diagnostic.osVersion,
        payload: String(decoding: redacted, as: UTF8.self), quoteFirstName: nil
    )
}

/// Sürüm metni: "0.1.3 (4)". Saf fonksiyondur.
public func appVersionText(version: String, build: String) -> String {
    "\(version) (\(build))"
}

/// Bu uygulamanın sürümü ve sistemi (ör. "0.1.3 (4)", "macOS Version 26.1 (Build 25B78)"); geri bildirim formunda
/// gönderilecek haliyle gösterilir.
public func currentReportDiagnostics(bundle: Bundle, platformName: String) -> ReportDiagnostics {
    let version: String = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build: String = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    return ReportDiagnostics(
        appVersion: appVersionText(version: version, build: build),
        os: "\(platformName) \(ProcessInfo.processInfo.operatingSystemVersionString)"
    )
}

/// Rapor sunucusunun adresi: geçerli ve https olmalı (değilse `HostedClientError`). Saf fonksiyondur.
public func reportsAPIBaseURL(value: String) throws -> URL {
    let url: URL = try parseHostedBaseURL(value: value)
    try requireSecureHostedBaseURL(url: url)
    return url
}

/// Hesapsız sürümlerin (geliştirici sürümü, iPhone) rapor hedefi: Info.plist'teki `ReportsAPIBase`, jetonsuz.
public func anonymousReportDestination(bundle: Bundle) throws -> ReportDestination {
    let value: String = bundle.object(forInfoDictionaryKey: reportsAPIBaseInfoKey) as? String ?? ""
    return ReportDestination(baseURL: try reportsAPIBaseURL(value: value), accessToken: nil)
}

/// Rapor gönderimi tekrarı zararlı sayılır (aynı rapor iki kez oluşur): yalnızca istek sunucuya hiç ulaşmadıysa
/// yeniden denenir. Hız sınırı (429) beklenmez, kullanıcıya hemen gösterilir. Saf fonksiyondur.
public func isRetryableReportRequest(failure: HostedAttemptFailure) -> Bool {
    switch failure {
    case .network(let code):
        isSafeToRetryPost(code: code)
    case .server:
        false
    }
}

/// Raporu `POST /v1/reports` ile gönderir (sunucu 202 döner); jeton varsa bearer eklenir. 2xx dışı yanıt
/// `HostedAPIError`, ağ hatası `HostedClientError.network`. İçerik loglanmaz.
public func submitReport(report: ReportRequest, destination: ReportDestination) async throws {
    let request: URLRequest = try hostedJSONRequest(
        baseURL: destination.baseURL, path: reportsPath, method: "POST", body: try JSONEncoder().encode(report),
        accessToken: destination.accessToken, timeoutSec: reportRequestTimeoutSec
    )
    let response: (data: Data, status: Int) = try await sendHostedRequest(path: reportsPath, isRetryable: isRetryableReportRequest) {
        try await URLSession.shared.data(for: request)
    }
    reportsLogger.info("Rapor gönderildi, tür: \(report.kind.rawValue, privacy: .public), durum: \(response.status, privacy: .public), hesaplı: \(destination.accessToken != nil, privacy: .public)")
}

/// Rapor hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func reportErrorMessage(error: ReportError) -> String {
    switch error {
    case .emptyMessage:
        String(localized: "Mesaj boş; ne olduğunu birkaç cümleyle yaz.")
    case .messageTooLong(let count, let limit):
        String(localized: "Mesaj çok uzun (\(count) / \(limit) karakter); kısaltıp yeniden gönder.")
    case .invalidEmail:
        String(localized: "E-posta adresi geçersiz; düzelt ya da boş bırak.")
    case .payloadTooLarge(let bytes, let limit):
        String(localized: "Çökme raporu gönderilemeyecek kadar büyük (\(bytes / 1024) KB, sınır \(limit / 1024) KB).")
    case .payloadNotText:
        String(localized: "Çökme raporu okunamadı (metin değil); raporu silip yenisini bekle.")
    case .invalidQuoteName:
        String(localized: "Alıntı için yalnızca ön adını yaz (harfler; en çok 40) ya da kutunun işaretini kaldır.")
    }
}
