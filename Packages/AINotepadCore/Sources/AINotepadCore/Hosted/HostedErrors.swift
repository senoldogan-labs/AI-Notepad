import Foundation

/// Abonelik sunucusunun hata kodları; `server/src/errors.ts` ile birebir aynıdır.
public enum HostedErrorCode: String, Sendable, CaseIterable, Equatable {
    case badRequest = "bad_request"
    case invalidBody = "invalid_body"
    case unauthorized
    case invalidToken = "invalid_token"
    case forbidden
    case notFound = "not_found"
    case methodNotAllowed = "method_not_allowed"
    case lengthRequired = "length_required"
    case payloadTooLarge = "payload_too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case rateLimited = "rate_limited"
    case turnstileFailed = "turnstile_failed"
    case attestationRequired = "attestation_required"
    case attestationInvalid = "attestation_invalid"
    case assertionInvalid = "assertion_invalid"
    case challengeInvalid = "challenge_invalid"
    case subscriptionRequired = "subscription_required"
    case subscriptionExists = "subscription_exists"
    case complimentarySubscription = "complimentary_subscription"
    /// Hesap App Store'dan (iPhone) abone: Stripe'ta ödeme açılmaz.
    case appStoreSubscription = "app_store_subscription"
    /// App Store satın alması şu an doğrulanamıyor (iPhone'un eşitleme ucu).
    case appStoreUnavailable = "app_store_unavailable"
    case trialExhausted = "trial_exhausted"
    case trialNotStarted = "trial_not_started"
    case trialIPLimit = "trial_ip_limit"
    case trialDeviceUsed = "trial_device_used"
    case deviceCheckRequired = "device_check_required"
    case deviceCheckInvalid = "device_check_invalid"
    case monthlyCapReached = "monthly_cap_reached"
    case dailyCapReached = "daily_cap_reached"
    case transcriptionClosed = "transcription_closed"
    case transcriptionInProgress = "transcription_in_progress"
    case meetingNotActive = "meeting_not_active"
    case reprocessLimitReached = "reprocess_limit_reached"
    /// Toplantı en çok duraklatma sayısına ulaştı: sonraki duraklatmalar süre sınırından sayılır, kayıt sürer.
    case pauseLimitReached = "pause_limit_reached"
    case meetingBudgetExhausted = "meeting_budget_exhausted"
    case audioTooLong = "audio_too_long"
    case upstreamRejected = "upstream_rejected"
    case upstreamUnavailable = "upstream_unavailable"
    case spendCeilingReached = "spend_ceiling_reached"
    case trialCapacityReached = "trial_capacity_reached"
    case deepgramUnavailable = "deepgram_unavailable"
    case deepgramGrantLimit = "deepgram_grant_limit"
    case referralInvalid = "referral_invalid"
    case referralSelf = "referral_self"
    case referralNotEligible = "referral_not_eligible"
    case referralUnavailable = "referral_unavailable"
    case referralLimitReached = "referral_limit_reached"
    case webhookInvalid = "webhook_invalid"
    /// `x-llm-purpose` başlığı bilinen bir amaç değil (istemci sunucudan yeni).
    case llmPurposeInvalid = "llm_purpose_invalid"
    /// The screen snapshots sent with a note are over the server's count, size or token cap.
    case screenImagesOverLimit = "screen_images_over_limit"
    // Blog yayını yalnızca yönetim panelinindir (`server/src/blog.ts`); uygulama bu uçları çağırmaz.
    case blogUnavailable = "blog_unavailable"
    case blogPostExists = "blog_post_exists"
    case blogConflict = "blog_conflict"
    case blogPostInvalid = "blog_post_invalid"
    case blogImageExists = "blog_image_exists"
    // Site istatistikleri yalnızca yönetim panelinindir (`server/src/siteAnalytics.ts`).
    case analyticsUnavailable = "analytics_unavailable"
    // Mac ↔ iPhone eşitleme (`server/src/sync.ts`, `HostedSyncClient`).
    case syncUnavailable = "sync_unavailable"
    case syncNotEnabled = "sync_not_enabled"
    case syncKeyMismatch = "sync_key_mismatch"
    case syncConflict = "sync_conflict"
    case syncQuotaExceeded = "sync_quota_exceeded"
    case syncCursorExpired = "sync_cursor_expired"
    // Notu bağlantıyla paylaşma (`server/src/shares.ts`, `HostedShareClient`).
    case shareUnavailable = "share_unavailable"
    case shareLimitReached = "share_limit_reached"
    case shareExists = "share_exists"
    // Yapay zekâ asistanı erişimi (`server/src/assistant/`); uygulamalar bu uçları 2. aşamada çağırmaya başlar, o zaman
    // kendi metinlerini alırlar.
    case assistantUnavailable = "assistant_unavailable"
    case assistantNotEnabled = "assistant_not_enabled"
    case assistantEpochMismatch = "assistant_epoch_mismatch"
    case assistantQuotaExceeded = "assistant_quota_exceeded"
    // Uygulamadan arama (iPhone pilotu; `server/src/phone/calls.ts`, `HostedPhoneClient`).
    case phoneUnavailable = "phone_unavailable"
    case phoneConsentRequired = "phone_consent_required"
    case phoneNumberRequired = "phone_number_required"
    case phoneNumberInvalid = "phone_number_invalid"
    case phoneNumberBlocked = "phone_number_blocked"
    case phoneNumberInUse = "phone_number_in_use"
    case phoneVerificationLimit = "phone_verification_limit"
    case phoneCallActive = "phone_call_active"
    case phoneMinutesExhausted = "phone_minutes_exhausted"
    case phoneCapacityReached = "phone_capacity_reached"
    case phoneRecordingUnavailable = "phone_recording_unavailable"
    // Apple ile girişin yetkilendirme kodu yalnızca sitenindir (`server/src/auth/appleTokens.ts`); uygulama bu ucu çağırmaz.
    case appleTokensUnavailable = "apple_tokens_unavailable"
    case internalError = "internal_error"
}

/// Sunucunun döndürdüğü hata (`{"error": {"code", "message"}}`). Kod tanınmıyorsa ya da gövde bu biçimde değilse
/// `code` nil'dir; `rawCode` sunucunun yazdığı kod (ya da `http_<durum>`).
public struct HostedAPIError: Error, Sendable, Equatable {
    public let code: HostedErrorCode?
    public let rawCode: String
    public let status: Int
    /// Sunucunun açıklaması; yalnızca hata ayıklama içindir (arayüz kendi yerelleştirilmiş metnini gösterir).
    public let serverMessage: String
    /// İsteğin yolu (ör. `/v1/meetings/start`).
    public let path: String

    public init(code: HostedErrorCode?, rawCode: String, status: Int, serverMessage: String, path: String) {
        self.code = code
        self.rawCode = rawCode
        self.status = status
        self.serverMessage = serverMessage
        self.path = path
    }
}

/// İstemci tarafında oturum, adres ya da yanıt sorunu. Jetonlar hiçbir zaman hataya girmez.
public enum HostedClientError: Error, Sendable, Equatable {
    /// Kayıtlı oturum yok.
    case notSignedIn
    /// Sunucu yenileme jetonunu reddetti (süresi doldu, çıkış yapıldı ya da jeton yeniden kullanıldığı için tüm
    /// oturumlar kapatıldı); yerel oturum silindi.
    case sessionEnded
    /// Yayın derlemesinde https olmayan sunucu adresi.
    case insecureBaseURL(url: String)
    /// Info.plist'teki adres eksik ya da geçersiz.
    case invalidBaseURL(value: String)
    /// Info.plist'te Anahtar Zinciri servis adı yok (derleme yapılandırması hatası).
    case keychainServiceNotConfigured(key: String)
    /// Paketin sürümü sunucunun kabul ettiği biçimde değil (derleme yapılandırması hatası; bkz. `hostedClientInfo`).
    case invalidAppVersion(value: String)
    /// Sunucuya ulaşılamıyor ve son bilinen hak durumu çevrimdışı kayda izin vermiyor (7 günden eski ya da izin yok).
    case offlineNotAllowed
    /// Kayıt çevrimdışı sürüyor: toplantıya bağlı yapay zekâ çağrıları (canlı çeviri…) yapılamaz.
    case offlineRecording
    /// Yapay zekâ çağrısı için açık toplantı oturumu yok.
    case noActiveMeeting
    /// Sunucuya ulaşılamadı.
    case network(path: String, reason: String)
    /// Yanıt beklenen biçimde değil; gövde hata ayıklama içindir (jeton içermez).
    case malformedResponse(path: String, status: Int, body: String)
    /// Sunucu bu uç noktayı tanımıyor (uygulama sunucudan yeni): işlem yapılmaz.
    case serverOutdated(path: String)
}

/// Hesap sunucuda silindi (2xx) ama bu cihazdaki son adım başarısız oldu: yanıt okunamadı ya da yerel oturum silinemedi.
/// Hesap silinmiş sayılır: çağıran yerel temizliği yine yapar ve hatayı gösterir.
public struct HostedAccountDeletedLocalFailure: Error, Sendable, Equatable {
    /// Okunabildiyse silme yanıtı (süren App Store aboneliği için); okunamadıysa ya da gövde yoksa nil.
    public let deletion: HostedAccountDeletion?
    /// Yanıt okunamadıysa nedeni (hata ayıklama içindir).
    public let decodeFailure: String?
    /// Yerel oturum (Anahtar Zinciri) silinemediyse nedeni (hata ayıklama içindir).
    public let tokenClearFailure: String?
}

/// Apple DeviceCheck jetonu üretilemedi (ücretsiz deneme toplantısı için gerekir).
public enum HostedDeviceCheckError: Error, Sendable, Equatable {
    /// Bu Mac'te DeviceCheck desteklenmiyor.
    case unsupported
    /// Jeton üretilemedi; neden hata ayıklama içindir.
    case tokenFailed(reason: String)
}

/// Sunucu hata gövdesinin biçimi.
private struct RawHostedErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }

    let error: Detail
}

/// Başarısız yanıttan hata üretir: gövde `{"error": {...}}` değilse kod `http_<durum>`, mesaj gövdenin ilk 500
/// karakteri olur. Saf fonksiyondur.
public func parseHostedAPIError(status: Int, data: Data, path: String) -> HostedAPIError {
    let body: RawHostedErrorBody
    do {
        body = try JSONDecoder().decode(RawHostedErrorBody.self, from: data)
    } catch {
        // Sunucu dışından (ör. vekil, Cloudflare sayfası) gelen gövde: durum ve gövdenin başı hatada kalır.
        return HostedAPIError(code: nil, rawCode: "http_\(status)", status: status, serverMessage: String(String(decoding: data, as: UTF8.self).prefix(500)), path: path)
    }
    return HostedAPIError(code: HostedErrorCode(rawValue: body.error.code), rawCode: body.error.code, status: status, serverMessage: body.error.message, path: path)
}

/// Aynı istek bir süre sonra başarılı olabilir mi: hız sınırı, üst servis kesintisi ve sunucu hatası. Günlük harcama
/// tavanı (503), kotalar ve ret kodları kalıcıdır. Saf fonksiyondur.
public func isRetryableHostedError(error: HostedAPIError) -> Bool {
    switch error.code {
    case .rateLimited, .upstreamUnavailable, .internalError:
        return true
    case .none:
        return error.status == 408 || error.status >= 500
    default:
        return false
    }
}

extension Notification.Name {
    /// Sunucu bir isteği abonelik gerektiği için reddetti (deneme bitti, bu Mac'te deneme kullanıldı, abonelik gerekli):
    /// uygulama abone olma teklifini gösterir. `userInfo["path"]`: isteğin yolu.
    public static let hostedSubscriptionRequired: Notification.Name = Notification.Name("com.senoldogan.AINotepad.hosted.subscriptionRequired")
}

/// Yalnızca abone olunca geçen ret kodları (geçici sınırlar ve cihaz doğrulaması değil): teklif bunlarda açılır.
public let hostedSubscriptionRequiredCodes: [HostedErrorCode] = [.subscriptionRequired, .trialExhausted, .trialDeviceUsed]

/// Ret abonelik gerektiriyorsa `hostedSubscriptionRequired` bildirimini yayınlar (sunucu isteği ve yapay zekâ çağrısı
/// bunu hatayı fırlatmadan önce çağırır).
func announceIfSubscriptionRequired(error: HostedAPIError) {
    guard let code = error.code, hostedSubscriptionRequiredCodes.contains(code) else {
        return
    }
    NotificationCenter.default.post(name: .hostedSubscriptionRequired, object: nil, userInfo: ["path": error.path])
}

/// Abone olunca geçersizleşen deneme ve abonelik hatalarının kodları (Başlat bunlardan biriyle reddedildiyse abonelik
/// açıldıktan sonra hata şeridinde kalmamalı).
public let hostedCodesResolvedBySubscription: [HostedErrorCode] = [
    .subscriptionRequired, .trialExhausted, .trialNotStarted, .trialIPLimit, .trialDeviceUsed,
    .deviceCheckRequired, .deviceCheckInvalid, .trialCapacityReached,
]

/// Abone olunca geçersizleşen hataların kullanıcıya gösterilen metinleri: deneme ve abonelik kodları (bkz.
/// `hostedCodesResolvedBySubscription`; bu kodların metni isteğin yoluna bağlı değildir) ve yalnızca deneme toplantısında
/// istenen Apple DeviceCheck hataları. Saf fonksiyondur.
public func hostedMessagesResolvedBySubscription() -> [String] {
    let server: [String] = hostedCodesResolvedBySubscription.map { (code: HostedErrorCode) -> String in
        hostedErrorMessage(error: HostedAPIError(code: code, rawCode: code.rawValue, status: 403, serverMessage: "", path: "/v1/meetings/start"))
    }
    let deviceCheck: [String] = [HostedDeviceCheckError.unsupported, HostedDeviceCheckError.tokenFailed(reason: "")].map(hostedDeviceCheckMessage)
    return server + deviceCheck
}

/// Sunucu hatasının kullanıcıya gösterilen, ne yapılacağını söyleyen metni. Saf fonksiyondur.
public func hostedErrorMessage(error: HostedAPIError) -> String {
    guard let code = error.code else {
        return String(localized: "Sunucu isteği şu an tamamlayamadı. Biraz sonra yeniden dene.")
    }
    switch code {
    case .trialExhausted:
        #if os(macOS)
        return String(localized: "Ücretsiz denemen bitti. Devam etmek için abone ol.")
        #else
        return String(localized: "Ücretsiz denemen bitti.")
        #endif
    case .trialNotStarted:
        return String(localized: "Ücretsiz deneme ilk toplantıyla başlar; önce bir toplantı başlat.")
    case .trialIPLimit:
        #if os(macOS)
        return String(localized: "Bu ağdan bugün çok fazla yeni deneme başlatıldı. Yarın yeniden dene ya da abone ol.")
        #else
        return String(localized: "Bu ağdan bugün çok fazla yeni deneme başlatıldı. Yarın yeniden dene.")
        #endif
    case .trialDeviceUsed:
        #if os(macOS)
        return String(localized: "Bu Mac'te ücretsiz deneme daha önce başka bir hesapla kullanıldı. Devam etmek için Ayarlar › Hesap'tan abone ol.")
        #else
        return String(localized: "Bu iPhone'da ücretsiz deneme daha önce başka bir hesapla kullanıldı.")
        #endif
    case .deviceCheckRequired:
        #if os(macOS)
        return String(localized: "Ücretsiz deneme için bu Mac'in Apple doğrulaması gerekiyor; uygulamayı güncelleyip yeniden dene.")
        #else
        return String(localized: "Ücretsiz deneme için bu iPhone'un Apple doğrulaması gerekiyor; uygulamayı güncelleyip yeniden dene.")
        #endif
    case .deviceCheckInvalid:
        #if os(macOS)
        return String(localized: "Bu Mac Apple tarafından doğrulanamadı; uygulamayı yeniden açıp tekrar dene.")
        #else
        return String(localized: "Bu iPhone Apple tarafından doğrulanamadı; uygulamayı yeniden açıp tekrar dene.")
        #endif
    case .monthlyCapReached:
        // Aynı kod farklı sınırlardan gelir: hangisi olduğu isteğin yolundan (kayıt, son geçiş ya da yapay zekâ).
        return monthlyCapMessage(path: error.path)
    case .dailyCapReached:
        return dailyCapMessage(path: error.path)
    case .subscriptionRequired:
        #if os(macOS)
        return String(localized: "Bu işlem için abonelik gerekiyor. Ayarlar › Hesap'tan abone ol.")
        #else
        return String(localized: "Bu işlem için hesabında etkin bir plan gerekiyor.")
        #endif
    case .subscriptionExists:
        return String(localized: "Zaten bir aboneliğin var; \"Hesabı yönet\" ile düzenleyebilirsin.")
    case .complimentarySubscription:
        return String(localized: "Hesabının ücretsiz tam erişimi var; ödenecek ya da yönetilecek bir şey yok.")
    case .appStoreSubscription:
        return String(localized: "Aboneliğin App Store üzerinden (iPhone). iPhone'da Ayarlar › Apple Hesabı › Abonelikler'den yönetebilirsin.")
    case .appStoreUnavailable:
        return String(localized: "App Store satın alması şu an doğrulanamıyor; biraz sonra yeniden dene.")
    case .trialCapacityReached:
        #if os(macOS)
        return String(localized: "Ücretsiz denemeler bugün kapasitede. Yarın yeniden dene ya da Ayarlar › Hesap'tan abone ol.")
        #else
        return String(localized: "Ücretsiz denemeler bugün kapasitede. Yarın yeniden dene.")
        #endif
    case .spendCeilingReached:
        return String(localized: "Servis bugün çok yoğun; yeni toplantılar ve yapay zekâ istekleri geçici olarak durduruldu. Biraz sonra yeniden dene.")
    case .meetingNotActive:
        // Kaydı bitmiş toplantının notu ve son geçişi bu hatada toplantıyı kendiliğinden yeniden açar
        // (`withRecordedMeetingReopen`); bu metin yalnızca açılamadığında ya da canlı çağrılarda görünür.
        return String(localized: "Bu toplantının sunucu oturumu kapandı. Kayıtlı toplantıyı \"Tekrar işle\" ile yeniden işleyebilir ya da yeni bir toplantı başlatabilirsin.")
    case .reprocessLimitReached:
        return String(localized: "Bu toplantı en çok iki kez yeniden işlenebilir; mevcut metin ve not korunur.")
    case .pauseLimitReached:
        return String(localized: "Bu toplantı çok kez duraklatıldı; bundan sonraki duraklatmalar toplantının süre sınırına sayılır.")
    case .transcriptionClosed:
        return String(localized: "Bu toplantının ses işleme hakkı kapandı (gönderilen ses toplantının süresini aştı). Canlı metin kullanılır.")
    case .transcriptionInProgress:
        return String(localized: "Bu toplantının sesi zaten işleniyor; bitince yeniden dene.")
    case .deepgramUnavailable:
        #if os(macOS)
        return String(localized: "Bulut canlı metni şu an kullanılamıyor; canlı metin bu Mac'te üretiliyor.")
        #else
        return String(localized: "Bulut canlı metni şu an kullanılamıyor; canlı metin bu iPhone'da üretiliyor.")
        #endif
    case .deepgramGrantLimit:
        #if os(macOS)
        return String(localized: "Bulut canlı metnine bu toplantıda çok sık yeniden bağlanıldı; canlı metin bu Mac'te sürüyor.")
        #else
        return String(localized: "Bulut canlı metnine bu toplantıda çok sık yeniden bağlanıldı; canlı metin bu iPhone'da sürüyor.")
        #endif
    case .meetingBudgetExhausted:
        return String(localized: "Bu toplantının yapay zekâ kullanım hakkı doldu.")
    case .referralInvalid:
        return String(localized: "Bu davet kodu bulunamadı. Kodu kontrol edip yeniden dene.")
    case .referralSelf:
        return String(localized: "Kendi davet kodunu kullanamazsın.")
    case .referralNotEligible:
        return String(localized: "Davet kodu yalnızca ilk aboneliğinde kullanılabilir; bu hesap için geçerli değil.")
    case .referralUnavailable:
        return String(localized: "Davet programı şu an kapalı; davet kodu olmadan abone olabilirsin.")
    case .referralLimitReached:
        // Kodun sahibinin ödül bekleyen davetleri sınırda: yer açılınca kod yeniden çalışır.
        return String(localized: "Bu davet kodu şu an yeni arkadaş kabul etmiyor; daha sonra yeniden dene ya da kodsuz abone ol.")
    case .audioTooLong:
        return String(localized: "Ses, toplantının süresinden ya da bu ay kalan süreden uzun; gönderilemedi.")
    case .unauthorized, .invalidToken:
        return String(localized: "Oturumun sona erdi; Ayarlar › Hesap'tan yeniden giriş yap.")
    case .rateLimited:
        return String(localized: "Çok fazla istek gönderildi; biraz bekleyip yeniden dene.")
    case .turnstileFailed:
        return String(localized: "İnsan doğrulaması başarısız; giriş sayfasını yenileyip yeniden dene.")
    case .attestationRequired:
        return String(localized: "Bu sürüm cihaz doğrulaması istiyor; uygulamayı güncelle.")
    case .attestationInvalid, .assertionInvalid, .challengeInvalid:
        #if os(macOS)
        return String(localized: "Bu Mac doğrulanamadı; uygulamayı yeniden açıp tekrar dene.")
        #else
        return String(localized: "Bu iPhone doğrulanamadı; uygulamayı yeniden açıp tekrar dene.")
        #endif
    case .upstreamRejected:
        return String(localized: "Yapay zekâ ya da konuşma tanıma servisi isteği reddetti. Sorun sürerse bize yaz.")
    case .upstreamUnavailable:
        return String(localized: "Yapay zekâ ya da konuşma tanıma servisi şu an yanıt vermiyor; biraz sonra yeniden dene.")
    case .payloadTooLarge:
        return String(localized: "Gönderilen veri sunucunun sınırını aşıyor.")
    case .screenImagesOverLimit:
        return String(localized: "Notla ya da soruyla gönderilen ekran görüntüleri sunucunun sınırını aşıyor. Ayarlar › Kayıt ve diller'de \"Notlarda ekran görüntülerini kullan\"ı kapatıp ya da Ekranlar sekmesinden bazılarını nottan çıkarıp yeniden dene.")
    case .syncUnavailable:
        return String(localized: "Eşitleme şu an kullanılamıyor; biraz sonra yeniden dene.")
    case .syncNotEnabled:
        return String(localized: "Bu hesapta eşitleme kapalı; Ayarlar › Eşitleme'den açabilirsin.")
    case .syncKeyMismatch:
        return String(localized: "Bu cihazdaki eşitleme anahtarı hesabınkiyle uyuşmuyor. Diğer cihazında Ayarlar › Eşitleme › Cihaz ekle'yi kullan ya da kurtarma kodunu gir.")
    case .syncConflict:
        return String(localized: "Bu toplantı diğer cihazda da değişti; değişiklikler birleştirilip yeniden gönderilecek.")
    case .syncQuotaExceeded:
        return String(localized: "Eşitlenen kopyanın yeri doldu; eski toplantıları ya da Sor sohbetlerini silip yeniden dene.")
    case .syncCursorExpired:
        return String(localized: "Eşitleme baştan yapılıyor; toplantıların yerinde kalır.")
    case .shareUnavailable:
        return String(localized: "Bağlantıyla paylaşma şu an kullanılamıyor; biraz sonra yeniden dene.")
    case .shareLimitReached:
        return String(localized: "Bir hesapta en çok \(noteShareMaxActiveLinks) etkin bağlantı olabilir; eski bağlantıları kaldırıp yeniden dene.")
    case .shareExists:
        return String(localized: "Bağlantı oluşturulamadı; yeniden dene.")
    case .phoneUnavailable:
        return String(localized: "Gistsmith'ten arama şu an kullanılamıyor.")
    case .phoneConsentRequired:
        return String(localized: "Aramadan önce kayıt koşullarını kabul et.")
    case .phoneNumberRequired:
        return String(localized: "Aramadan önce kendi telefon numaranı doğrula.")
    case .phoneNumberInvalid:
        return String(localized: "Numara geçersiz. Ülke koduyla yaz, ör. +1 415 555 0100.")
    case .phoneNumberBlocked:
        return String(localized: "Bu numara Gistsmith'ten aranamaz: ücretli, özel ya da desteklenmeyen bir ülkedeki numaralar engelli.")
    case .phoneNumberInUse:
        return String(localized: "Bu numara başka bir Gistsmith hesabında kullanılıyor.")
    case .phoneVerificationLimit:
        return String(localized: "Bugün çok fazla doğrulama araması yapıldı; yarın yeniden dene.")
    case .phoneCallActive:
        return String(localized: "Hesabında süren başka bir arama var; o bitince yeniden dene.")
    case .phoneMinutesExhausted:
        return String(localized: "Bu ayki arama dakikaların doldu; ay başında yenilenir.")
    case .phoneCapacityReached:
        return String(localized: "Arama bugün çok yoğun; yarın yeniden dene.")
    case .phoneRecordingUnavailable:
        return String(localized: "Aramanın kaydı henüz hazır değil ya da silindi.")
    case .forbidden:
        return String(localized: "Bu işleme izin yok.")
    case .internalError:
        return String(localized: "Sunucuda beklenmeyen bir hata oluştu; biraz sonra yeniden dene.")
    case .badRequest, .invalidBody, .notFound, .methodNotAllowed, .lengthRequired, .unsupportedMediaType, .webhookInvalid, .llmPurposeInvalid,
         .blogUnavailable, .blogPostExists, .blogConflict, .blogPostInvalid, .blogImageExists, .analyticsUnavailable,
         .appleTokensUnavailable, .assistantUnavailable, .assistantNotEnabled, .assistantEpochMismatch, .assistantQuotaExceeded:
        return String(localized: "Bu sürüm sunucuyla uyuşmuyor. Uygulamayı güncelleyip yeniden dene.")
    }
}

/// `monthly_cap_reached` metni: kayıt başlatma ve son geçişte aylık kayıt saatleri, yapay zekâ çağrısında toplantı dışı
/// yapay zekâ payı (kayıt etkilenmez). Saf fonksiyondur.
private func monthlyCapMessage(path: String) -> String {
    switch path {
    case "/v1/meetings/start":
        String(localized: "Bu ayki kayıt saatlerin doldu; yeni kayıt ay başında açılır. Notların ve toplantıların kullanılabilir.")
    case "/v1/transcribe":
        String(localized: "Bu ayki kayıt saatlerin bu kaydı işlemeye yetmiyor; canlı metin kullanılır. Sınır ay başında sıfırlanır.")
    case "/v1/llm/messages":
        String(localized: "Bu ayki yapay zekâ payın doldu (Sor, notu yeniden yazma…); ay başında sıfırlanır. Kayıt yapmaya devam edebilirsin.")
    case "/v1/phone/calls":
        String(localized: "Bu ayki kayıt saatlerin doldu; arama da kaydedileceği için yeni arama ay başında açılır.")
    default:
        String(localized: "Bu ayki kullanım sınırına ulaştın; sınır ay başında sıfırlanır.")
    }
}

/// `daily_cap_reached` metni: günlük toplantı başlatma, günlük yapay zekâ payı ya da günlük rapor sınırı. Saf
/// fonksiyondur.
private func dailyCapMessage(path: String) -> String {
    switch path {
    case "/v1/meetings/start":
        String(localized: "Bugün başlatılabilecek toplantı sayısına ulaştın; yarın yeniden dene.")
    case "/v1/llm/messages":
        String(localized: "Bugünkü yapay zekâ payın doldu (Sor, notu yeniden yazma…); yarın yeniden dene. Kayıt yapmaya devam edebilirsin.")
    case "/v1/reports":
        String(localized: "Bugün çok fazla rapor gönderildi; yarın yeniden dene.")
    default:
        String(localized: "Bugünkü kullanım sınırına ulaştın; yarın yeniden dene.")
    }
}

/// İstemci hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func hostedClientMessage(error: HostedClientError) -> String {
    switch error {
    case .notSignedIn:
        String(localized: "Giriş yapılmamış. Ayarlar › Hesap'tan Apple ya da Google ile giriş yap.")
    case .sessionEnded:
        String(localized: "Oturumun kapandı (çıkış yapılmış ya da güvenlik nedeniyle tüm oturumlar kapatılmış). Yeniden giriş yap.")
    case .insecureBaseURL:
        String(localized: "Uygulamanın sunucu ayarı güvenli değil; uygulamayı güncelle ya da yeniden kur.")
    case .invalidBaseURL:
        String(localized: "Uygulamanın sunucu ayarı eksik ya da bozuk; uygulamayı yeniden kur.")
    case .keychainServiceNotConfigured:
        String(localized: "Uygulamanın Anahtar Zinciri ayarı eksik; uygulamayı yeniden kur.")
    case .invalidAppVersion:
        String(localized: "Uygulamanın sürüm bilgisi bozuk; uygulamayı yeniden kur.")
    case .offlineNotAllowed:
        String(localized: "Sunucuya ulaşılamıyor ve son bilinen hesap durumun çevrimdışı kayda izin vermiyor (7 günden eski ya da kayıt hakkın kalmamış). Kayıt için internete bağlan.")
    case .offlineRecording:
        String(localized: "Kayıt çevrimdışı sürüyor: canlı çeviri kapalı; not ve konuşmacılar bağlantı gelince hazırlanır.")
    case .noActiveMeeting:
        String(localized: "Yapay zekâ özellikleri bir toplantı sırasında ve bittikten kısa süre sonrasına kadar kullanılabilir; önce bir toplantı başlat.")
    case .network:
        String(localized: "Sunucuya ulaşılamadı; internet bağlantını kontrol et.")
    case .malformedResponse:
        String(localized: "Sunucudan beklenmeyen bir yanıt geldi. Uygulamayı güncelleyip yeniden dene.")
    case .serverOutdated:
        String(localized: "Sunucu bu işlemi henüz desteklemiyor (güncelleniyor). Toplantı işlenmedi; biraz sonra \"Tekrar işle\" ile yeniden dene.")
    }
}

/// DeviceCheck hatasının kullanıcıya gösterilen metni. Saf fonksiyondur.
public func hostedDeviceCheckMessage(error: HostedDeviceCheckError) -> String {
    switch error {
    case .unsupported:
        #if os(macOS)
        String(localized: "Bu Mac Apple'ın cihaz doğrulamasını (DeviceCheck) desteklemiyor; ücretsiz deneme başlatılamıyor. Abone olarak devam edebilirsin.")
        #else
        String(localized: "Bu cihaz Apple'ın cihaz doğrulamasını (DeviceCheck) desteklemiyor; ücretsiz deneme başlatılamıyor.")
        #endif
    case .tokenFailed:
        #if os(macOS)
        String(localized: "Bu Mac Apple ile doğrulanamadı (DeviceCheck). İnternet bağlantını kontrol edip yeniden dene.")
        #else
        String(localized: "Bu iPhone Apple ile doğrulanamadı (DeviceCheck). İnternet bağlantını kontrol edip yeniden dene.")
        #endif
    }
}

/// Canlı çeviri bu kayıtta durmalı mı: anahtar reddedildi (401/403) ya da abonelik sunucusu toplantının yapay zekâ
/// hakkını kapattı (oturum yok, toplantı kapalı, bütçe ya da sınır doldu, harcama tavanı). Her cümle aynı hatayı
/// almasın diye çeviri durur; cümleler "Tekrar dene"de kalır. Saf fonksiyondur.
public func stopsLiveTranslation(error: any Error) -> Bool {
    switch error {
    case LLMError.http(let status, _, _, _):
        return status == 401 || status == 403
    case LLMError.hosted(let hosted):
        return isClosedHostedAccess(error: hosted)
    case let client as HostedClientError:
        switch client {
        case .notSignedIn, .sessionEnded, .noActiveMeeting, .insecureBaseURL, .invalidBaseURL, .keychainServiceNotConfigured, .invalidAppVersion, .offlineNotAllowed,
             .offlineRecording, .serverOutdated:
            return true
        case .network, .malformedResponse:
            return false
        }
    default:
        return false
    }
}

/// Sunucu bu kullanıcının yapay zekâ erişimini şimdilik kapattı mı (yeniden denemek aynı sonucu verir). Saf fonksiyondur.
private func isClosedHostedAccess(error: HostedAPIError) -> Bool {
    switch error.code {
    case .unauthorized, .invalidToken, .forbidden, .subscriptionRequired, .trialExhausted, .monthlyCapReached, .dailyCapReached,
         .meetingNotActive, .meetingBudgetExhausted, .spendCeilingReached, .trialCapacityReached:
        return true
    default:
        return false
    }
}
