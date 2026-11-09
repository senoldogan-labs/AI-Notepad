import Foundation

/// `POST /v1/auth/apple`, `/v1/auth/google` ve `/v1/auth/refresh` yanıtı.
public struct HostedSessionResponse: Decodable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    /// Erişim jetonunun ömrü (saniye).
    public let expiresIn: Int
    public let userId: String
}

/// Anahtar Zinciri'nde saklanan oturum.
public struct HostedTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    /// Erişim jetonunun bittiği an (yanıtın alındığı andan `expiresIn` sonra).
    public let accessExpiresAt: Date
    public let userId: String

    public init(accessToken: String, refreshToken: String, accessExpiresAt: Date, userId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.userId = userId
    }
}

/// Oturum yanıtından saklanacak jetonlar. Saf fonksiyondur.
public func hostedTokens(response: HostedSessionResponse, receivedAt: Date) -> HostedTokens {
    HostedTokens(
        accessToken: response.accessToken, refreshToken: response.refreshToken,
        accessExpiresAt: receivedAt.addingTimeInterval(Double(response.expiresIn)), userId: response.userId
    )
}

/// Kullanıcının planı.
public enum HostedPlan: String, Decodable, Sendable, Equatable {
    case trial
    case subscription
}

/// Aboneliğin erişim durumu: ödenmiş dönem, ödeme gecikmesinde ek süre ya da erişim yok.
public enum HostedSubscriptionAccess: String, Decodable, Sendable, Equatable {
    case active
    case grace
    case none
}

/// Hesabın asıl aboneliğinin özeti: Stripe (webhook'tan yazılır) ya da App Store (iPhone, RevenueCat; aynı biçimde).
public struct HostedSubscription: Decodable, Sendable, Equatable {
    /// Ödeme kaynağı (`stripe` ya da `app_store`); alanı bilmeyen eski sunucuda nil (Stripe). Tanınmayan değer yanıtı
    /// bozmasın diye metin olarak okunur; arayüz `paymentSource`'u kullanır.
    public let source: String?
    /// Stripe durumu (`active`, `past_due`, `canceled`…).
    public let status: String
    public let currentPeriodEnd: Date
    /// İptal edilmiş aboneliğin biteceği an (yenilenmez); yenilenecekse nil.
    public let cancelAt: Date?
    public let access: HostedSubscriptionAccess
    /// Ek sürenin bittiği an; ek süre yoksa nil.
    public let graceEndsAt: Date?
    /// Aboneliğin planı (`monthly`, `yearly`); tanınmayan eski fiyatta ve alanı bilmeyen eski sunucuda nil. Tanınmayan
    /// değer hak yanıtını bozmasın diye metin olarak okunur; arayüz `billingPlan`'ı kullanır.
    public let plan: String?
    /// Yöneticinin verdiği ücretsiz erişim (Stripe'ta karşılığı yok): plan `monthly` görünür ama ödeme, yenileme ve
    /// yönetilecek bir şey yoktur; davet ödülü uygulanmaz.
    public let complimentary: Bool

    /// Aboneliğin planı; bilinmiyorsa nil.
    public var billingPlan: HostedBillingPlan? {
        plan.flatMap { (value: String) -> HostedBillingPlan? in HostedBillingPlan(rawValue: value) }
    }

    /// Ödeme kaynağı; alan yoksa (eski sunucu) Stripe, tanınmıyorsa nil.
    public var paymentSource: HostedPaymentSource? {
        guard let source else {
            return .stripe
        }
        return HostedPaymentSource(rawValue: source)
    }
}

/// Aboneliğin ödeme kaynağı (sunucunun `source` değerleri): Stripe (Mac ve site) ya da App Store (iPhone).
public enum HostedPaymentSource: String, Sendable, Equatable {
    case stripe
    case appStore = "app_store"
}

/// App Store aboneliği (`GET /v1/me` → `appStoreSubscription`): iPhone'dan alınır, yalnızca Apple'da yönetilir.
public struct HostedAppStoreSubscription: Decodable, Sendable, Equatable {
    /// `active`, `canceled`, `billing_issue`, `expired`, `refunded`.
    public let status: String
    public let plan: String?
    public let productId: String
    public let access: HostedSubscriptionAccess
    public let expiresAt: Date
    public let willRenew: Bool
    public let graceEndsAt: Date?
    /// `PRODUCTION` ya da `SANDBOX`.
    public let environment: String
    /// Apple'ın abonelik yönetim sayfası.
    public let manageUrl: URL
}

/// `DELETE /v1/me` yanıtı. Eski sunucu gövdesiz 204 döner (o zaman nil).
public struct HostedAccountDeletion: Decodable, Sendable, Equatable {
    public let deleted: Bool
    /// Silinen hesabın süren App Store aboneliği: Apple onu iptal etmez; kullanıcı iPhone'da iptal etmeli.
    public let appStoreSubscription: HostedDeletedAppStoreSubscription?
    /// Sunucunun İngilizce uyarısı; App Store aboneliği yoksa nil.
    public let notice: String?
}

/// Silinen hesabın süren App Store aboneliği.
public struct HostedDeletedAppStoreSubscription: Decodable, Sendable, Equatable {
    public let willRenew: Bool
    public let expiresAt: Date
    public let manageUrl: URL
}

/// Hesabın aboneliği App Store'dan mı yönetiliyor: asıl abonelik App Store'dan ve erişimi sürüyor ya da (Stripe'ta
/// yönetilecek abonelik yokken) App Store aboneliği var. Mac'te Stripe portalı ve ikinci satın alma gösterilmez. Saf
/// fonksiyondur.
public func isHostedAppStoreManaged(entitlements: HostedEntitlements) -> Bool {
    entitlements.subscription?.paymentSource == .appStore
}

/// Abonelik planı: aylık ya da yıllık (sunucunun `plan` değerleri).
public enum HostedBillingPlan: String, Codable, Sendable, Equatable, CaseIterable {
    case monthly
    case yearly
}

/// `POST /v1/billing/checkout` gövdesi: seçilen plan ve doğrulanmış davet kodu (nil ise gövdeye yazılmaz).
struct HostedCheckoutBody: Encodable, Equatable {
    let plan: HostedBillingPlan
    let referralCode: String?
}

/// `GET /v1/referral` yanıtı: abonenin davet kodu ve davet sayıları. Kod ve bağlantı yalnızca program açıkken ve hesabın
/// abonelik erişimi varken dolu gelir.
public struct HostedReferral: Decodable, Sendable, Equatable {
    /// Davet programı açık mı.
    public let enabled: Bool
    public let code: String?
    public let inviteUrl: URL?
    /// Kodla abone olan arkadaş sayısı.
    public let joined: Int
    /// Verilen ödül sayısı (her biri bir aylık ücret kadar alacak).
    public let rewarded: Int
    /// Abone olmuş ama ödülü henüz yazılmamış arkadaş sayısı (ilk ödemesi bekleme süresinde).
    public let pending: Int
    /// Bekleyen ödüllerin en yakınının tahmini tarihi; bekleyen yoksa nil.
    public let nextRewardAt: Date?
    /// Hesabın ücretsiz erişimi var: ödenecek fatura olmadığından ödül uygulanmaz.
    public let complimentary: Bool
    /// Hesabın asıl aboneliği App Store'dan: ödül (web ödemesinden düşülen alacak) Apple faturasına uygulanmaz. Bu alanı
    /// bilmeyen eski sunucuda nil.
    public let appStoreBilled: Bool?
    public let rewardsLeftThisYear: Int
    public let rewardsPerYear: Int
    /// Ödülün tutarı (USD; bir aylık abonelik).
    public let rewardUsd: Double
    /// Arkadaşın ilk ödemesinden ödüle dek beklenen gün (iade süresi).
    public let holdDays: Int

    public init(
        enabled: Bool, code: String?, inviteUrl: URL?, joined: Int, rewarded: Int, pending: Int, nextRewardAt: Date?,
        complimentary: Bool, appStoreBilled: Bool?, rewardsLeftThisYear: Int, rewardsPerYear: Int, rewardUsd: Double, holdDays: Int
    ) {
        self.enabled = enabled
        self.code = code
        self.inviteUrl = inviteUrl
        self.joined = joined
        self.rewarded = rewarded
        self.pending = pending
        self.nextRewardAt = nextRewardAt
        self.complimentary = complimentary
        self.appStoreBilled = appStoreBilled
        self.rewardsLeftThisYear = rewardsLeftThisYear
        self.rewardsPerYear = rewardsPerYear
        self.rewardUsd = rewardUsd
        self.holdDays = holdDays
    }
}

/// `POST /v1/referral/validate` gövdesi.
struct HostedReferralValidateBody: Encodable {
    let code: String
}

/// `POST /v1/referral/validate` yanıtı: sunucunun sadeleştirdiği geçerli kod.
public struct HostedReferralValidation: Decodable, Sendable, Equatable {
    public let code: String
}

/// Davet kodunun harfleri: karışan 0, 1, I, L ve O yoktur (sunucuyla aynı).
public let hostedReferralAlphabet: Set<Character> = Set("23456789ABCDEFGHJKMNPQRSTUVWXYZ")

/// Davet kodunun uzunluğu.
public let hostedReferralCodeLength: Int = 8

/// Girilen davet kodunu sunucunun biçimine getirir: boşluklar ve tireler atılır, harfler büyütülür (sunucu da aynısını
/// yapar). Saf fonksiyondur.
public func normalizedHostedReferralCode(input: String) -> String {
    String(input.uppercased(with: Locale(identifier: "en_US_POSIX")).filter { (character: Character) -> Bool in !character.isWhitespace && character != "-" })
}

/// Sadeleşmiş kod davet kodu biçiminde mi (8 harf, alfabeden); biçimsiz kod sunucuya sorulmaz. Saf fonksiyondur.
public func isWellFormedHostedReferralCode(code: String) -> Bool {
    code.count == hostedReferralCodeLength && code.allSatisfy { (character: Character) -> Bool in hostedReferralAlphabet.contains(character) }
}

/// `GET /v1/me` yanıtı: plan, deneme hakkı, aylık kullanım ve abonelik.
public struct HostedEntitlements: Decodable, Sendable, Equatable {
    public let userId: String
    public let plan: HostedPlan
    public let trialMeetingsTotal: Int
    /// Denemenin süresi (gün; ilk deneme toplantısından başlar); alanı bilmeyen eski sunucuda nil.
    public let trialDays: Int?
    /// Etkin kalan deneme (hesap ve doğrulanmış cihazın küçüğü). Sunucu bu Mac'te denemeyi reddettiyse uygulama 0 yapar
    /// (bkz. `hostedEntitlementsOnThisMac`).
    public internal(set) var trialMeetingsLeft: Int
    public let accountTrialMeetingsLeft: Int
    public let deviceTrialMeetingsLeft: Int?
    /// Deneme süresinin bittiği an (ilk deneme toplantısı + deneme günleri); deneme başlamadıysa, abonelikte ya da
    /// alanı bilmeyen eski sunucuda nil.
    public let trialEndsAt: Date?
    public let monthlyHoursUsed: Double
    public let monthlyHoursCap: Double
    public let subscription: HostedSubscription?
    /// Yeni toplantının canlı metin motoru (`deepgram` ya da `whisperkit`); bkz. `hostedLiveEngine(entitlements:)`.
    /// Alanı bilmeyen eski sunucuda nil.
    public let liveEngine: String?
    /// The user is in the on-device live preview rollout (see `hostedLiveOnDevice`); nil on an older server.
    public let liveOnDevice: Bool?
    /// Toplantı dışı yapay zekâ hakkı (Sor, not düzenleme…): dönemde sayılan token, sınır, dönem (`month` abonede,
    /// `day` denemede) ve sıfırlanma anı. Alanları bilmeyen eski sunucuda nil (kullanım göstergesi gizlenir).
    public let accountTokensUsed: Int?
    public let accountTokensCap: Int?
    public let accountTokensPeriod: String?
    public let accountTokensResetsAt: Date?
    /// Aylık sınırların sıfırlandığı an (sonraki UTC ayının başı); eski sunucuda nil.
    public let monthlyResetsAt: Date?
    /// Şimdi açılacak toplantının en çok süresi ve ses hakkı (dakika; abonede aylık kalanla sınırlı); eski sunucuda nil.
    public let meetingMaxMinutes: Int?
    /// Erişimi süren aboneliklerin kaynakları (`stripe`, `app_store`); eski sunucuda nil.
    public let subscriptionSources: [String]?
    /// App Store aboneliği (iPhone); hiç olmadıysa ya da eski sunucuda nil.
    public let appStoreSubscription: HostedAppStoreSubscription?
}

/// Abonelik sürümünde canlı metni üreten motor.
public enum HostedLiveEngine: String, Sendable, Equatable {
    /// Bulut (Deepgram); jeton her bağlantıda sunucudan alınır.
    case deepgram
    /// Mac'te (WhisperKit).
    case whisperKit = "whisperkit"
}

/// Sunucunun yeni toplantı için önerdiği canlı motor. Alanı bilmeyen eski sunucu Deepgram jetonu da vermez, tanınmayan
/// değer de Deepgram'ı açmaz: ikisinde de Mac'te (WhisperKit). Saf fonksiyondur.
public func hostedLiveEngine(entitlements: HostedEntitlements) -> HostedLiveEngine {
    entitlements.liveEngine.flatMap { HostedLiveEngine(rawValue: $0) } ?? .whisperKit
}

/// `POST /v1/live/deepgram-token` yanıtı: tek bağlantılık kısa ömürlü Deepgram jetonu. Jeton saklanmaz ve loglanmaz.
public struct HostedDeepgramGrant: Decodable, Sendable {
    /// Deepgram JWT'si (`Authorization: Bearer`); yalnızca bağlantı kurulurken geçerli olmalı.
    public let accessToken: String
    /// Jetonun kalan ömrü (saniye).
    public let expiresIn: Double
    /// Akış modeli (ör. `nova-3`).
    public let model: String
    /// Bu toplantıda kalan jeton.
    public let grantsLeft: Int
}

/// Abonelik sürümünün akış seçenekleri: model sunucunun jetonundan; model geliştirme programından her zaman çıkılır
/// (`mip_opt_out=true`: Deepgram ses ve metni yalnızca işlerken tutar, eğitimde kullanmaz; gizlilik metni bunu söyler).
/// Saf fonksiyondur.
public func hostedDeepgramListenOptions(grant: HostedDeepgramGrant) -> DeepgramListenOptions {
    DeepgramListenOptions(model: grant.model, optOutOfModelImprovement: true)
}

/// `POST /v1/meetings/start` yanıtı.
public struct HostedStartedMeeting: Decodable, Sendable, Equatable {
    public let meetingId: String
    /// `trial` ya da `subscription`.
    public let kind: String
    public let tokenBudget: Int
    public let maxDurationMinutes: Int
    public let expiresAt: Date
    /// Deneme toplantısında kalan deneme; abonelikte nil.
    public let trialMeetingsLeft: Int?
}

/// `POST /v1/meetings/{id}/reprocess` yanıtı.
public struct HostedReprocessedMeeting: Decodable, Sendable, Equatable {
    public let meetingId: String
    public let usableUntil: Date
    public let reprocessesLeft: Int
}

/// `POST /v1/meetings/{id}/end` yanıtı.
public struct HostedEndedMeeting: Decodable, Sendable, Equatable {
    public let meetingId: String
    public let minutes: Int?
    public let tokensUsed: Int
    public let audioSeconds: Double
}

/// `POST /v1/meetings/{id}/pause` ve `/resume` yanıtı: duraklatılan süre toplantının süre sınırından ve aylık
/// süreden sayılmaz (sunucu saatiyle ölçülür, en çok toplantının en uzun süresi kadar).
public struct HostedMeetingPause: Decodable, Sendable, Equatable {
    public let meetingId: String
    public let paused: Bool
    /// Toplantının şimdiki en geç bitişi: duraklatmada kalan duraklatma hakkının tamamı kadar ileridedir, sürdürünce
    /// gerçek duraklatma kadar kısalır.
    public let expiresAt: Date
    /// Sayılmayan (duraklatılmış) toplam süre, süren duraklatma dahil.
    public let pausedSeconds: Int
}

/// Ödeme ve portal uçlarının yanıtı.
struct HostedURLResponse: Decodable {
    let url: URL
}

/// `POST /v1/device/challenge` yanıtı.
public struct HostedDeviceChallenge: Decodable, Sendable, Equatable {
    public let challenge: String
    public let expiresInSeconds: Int
}

/// `POST /v1/meetings/start` ile gönderilen App Attest onayı (alanlar base64).
public struct HostedDeviceAssertion: Encodable, Sendable, Equatable {
    public let keyId: String
    public let assertion: String
    /// `{"action":"meetings.start","challenge":…}` JSON'unun base64'ü.
    public let clientData: String

    public init(keyId: String, assertion: String, clientData: String) {
        self.keyId = keyId
        self.assertion = assertion
        self.clientData = clientData
    }
}

/// Sunucu yanıtlarının çözücüsü: tarihler kesirli saniyeli ISO 8601 (`toISOString`).
func hostedJSONDecoder() -> JSONDecoder {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { (decoder: any Decoder) throws -> Date in
        let container: any SingleValueDecodingContainer = try decoder.singleValueContainer()
        let text: String = try container.decode(String.self)
        do {
            return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        } catch {
            return try Date.ISO8601FormatStyle().parse(text)
        }
    }
    return decoder
}

/// Ücretsiz denemenin bitme nedeni.
public enum HostedTrialEndReason: Sendable, Equatable {
    /// Deneme toplantılarının hepsi kullanıldı (ya da sunucu denemeyi bu cihazda reddetti).
    case meetingsUsed
    /// Deneme süresi (`trialEndsAt`) doldu; toplantı kalmış olsa da deneme biter.
    case timeExpired
}

/// Ücretsiz denemenin durumu: sunucunun okuma anındaki kalan toplantı sayısı ve `trialEndsAt`, şimdiki ana göre
/// yorumlanır (hak durumu bir süre bayat kalabilir; süre bu arada dolabilir).
public enum HostedTrialState: Sendable, Equatable {
    /// Deneme başlamadı: ilk deneme toplantısıyla başlar (sunucu o zaman `trialEndsAt` yazar); süre işlemiyor. Kalan
    /// toplantı (en az 1) toplamdan az olabilir (önceki hesaptan devralınan deneme toplantıları).
    case notStarted(left: Int, total: Int)
    /// Deneme sürüyor: kalan toplantı (en az 1) ve bitiş anı. Bitişi bilmeyen eski sunucuda `endsAt` nil.
    case running(left: Int, total: Int, endsAt: Date?)
    /// Deneme bitti; yeni kayıt için abone olunmalı.
    case ended(reason: HostedTrialEndReason, total: Int)

    /// Kalan deneme toplantısı (bittiyse 0).
    public var meetingsLeft: Int {
        switch self {
        case .notStarted(let left, _): left
        case .running(let left, _, _): left
        case .ended: 0
        }
    }

    /// Toplam deneme toplantısı.
    public var meetingsTotal: Int {
        switch self {
        case .notStarted(_, let total), .running(_, let total, _), .ended(_, let total): total
        }
    }
}

/// Hak yanıtından denemenin şimdiki durumu: süresi dolduysa (`trialEndsAt <= now`) toplantı kalmış olsa da biter;
/// toplantı kalmadıysa biter; bitiş anı yoksa ve sunucu deneme süresini biliyorsa (`trialDays`) deneme başlamamıştır.
/// Saf fonksiyondur.
public func hostedTrialState(entitlements: HostedEntitlements, now: Date) -> HostedTrialState {
    let total: Int = entitlements.trialMeetingsTotal
    if let endsAt = entitlements.trialEndsAt, endsAt <= now {
        return .ended(reason: .timeExpired, total: total)
    }
    guard entitlements.trialMeetingsLeft > 0 else {
        return .ended(reason: .meetingsUsed, total: total)
    }
    if entitlements.trialEndsAt == nil, entitlements.trialDays != nil {
        return .notStarted(left: entitlements.trialMeetingsLeft, total: total)
    }
    return .running(left: entitlements.trialMeetingsLeft, total: total, endsAt: entitlements.trialEndsAt)
}

/// Hesabın arayüzde gösterilen durumu.
public enum HostedPlanStatus: Sendable, Equatable {
    /// Deneme: başlamadı, sürüyor ya da bitti (bkz. `HostedTrialState`).
    case trial(HostedTrialState)
    /// Abonelik etkin; dönem sonunda yenilenir.
    case subscribed(renewsAt: Date)
    /// Yöneticinin verdiği ücretsiz tam erişim: ödeme ve yenileme yok.
    case complimentary
    /// Abonelik iptal edildi; erişim bu ana dek sürer, yenilenmez.
    case ending(endsAt: Date)
    /// Ödeme gecikti; erişim ek süre boyunca sürer.
    case grace(endsAt: Date)
    /// Ödeme alınamadı ve ek süre bitti, ama abonelik Stripe'ta sürüyor (`past_due`, `unpaid`): ödeme yeniden denenir;
    /// yeni kayıt için kart "Hesabı yönet"ten güncellenir (yeni abonelik açılamaz, sunucu `subscription_exists` der).
    case paymentOverdue
    /// Abonelik sona erdi (iptal edildi ya da ödenmedi) ve deneme hakkı kalmadı: yeni kayıt için yeniden abone olunmalı.
    case expired(endedAt: Date)
}

/// Bu Mac'te görülen hak durumu: sunucu bu hesabın ücretsiz denemesini bu Mac'te reddettiyse (`trial_device_used`: Mac
/// denemesini başka bir hesapla kullandı; Apple DeviceCheck yalnızca toplantı açılırken sorulur, hak yanıtı bunu
/// bilemez) ve hesap denemedeyse kalan deneme 0 gösterilir; kenar çubuğu, Hesap kartı ve Başlat düğmesi böylece aynı
/// şeyi söyler. Abonelikte değişmez. Saf fonksiyondur.
public func hostedEntitlementsOnThisMac(entitlements: HostedEntitlements, trialRefusedOnThisMac: Bool, now: Date) -> HostedEntitlements {
    guard trialRefusedOnThisMac, case .trial = hostedPlanStatus(entitlements: entitlements, now: now) else {
        return entitlements
    }
    var shown: HostedEntitlements = entitlements
    shown.trialMeetingsLeft = 0
    return shown
}

/// Bu Mac'teki deneme reddinin geçerli kaldığı süre (saniye): sonra Başlat sunucuya yeniden sorar (sunucuda düzeltilmiş
/// ya da reddin yanlış çıktığı hesap kalıcı olarak kilitlenmesin).
public let hostedTrialRefusalMaxAgeSec: Double = 24 * 60 * 60

/// Deneme reddi hâlâ geçerli mi: kaydedildiyse ve `maxAgeSec`'ten yeniyse. Saf fonksiyondur.
public func isHostedTrialRefusalActive(refusedAt: Date?, now: Date, maxAgeSec: Double) -> Bool {
    guard let refusedAt else {
        return false
    }
    return now.timeIntervalSince(refusedAt) < maxAgeSec
}

/// Ödemesi alınamamış ama Stripe'ta süren aboneliğin durumları: erişim ek süreden sonra kapanır, abonelik bitmez.
private let hostedUnpaidSubscriptionStatuses: Set<String> = ["past_due", "unpaid"]

/// Hak yanıtından arayüz durumu: erişimi olan abonelik önce gelir, yoksa deneme (`hostedTrialState`, `now`'a göre).
/// Erişimi kapanmış abonelikte deneme bittiyse ödemesi alınamamış (`paymentOverdue`) ya da bitmiş (`expired`)
/// abonelik. Saf fonksiyondur.
public func hostedPlanStatus(entitlements: HostedEntitlements, now: Date) -> HostedPlanStatus {
    let trial: HostedTrialState = hostedTrialState(entitlements: entitlements, now: now)
    if let subscription = entitlements.subscription {
        switch subscription.access {
        case .active:
            if subscription.complimentary {
                return .complimentary
            }
            if let cancelAt = subscription.cancelAt {
                return .ending(endsAt: cancelAt)
            }
            return .subscribed(renewsAt: subscription.currentPeriodEnd)
        case .grace:
            return .grace(endsAt: subscription.graceEndsAt ?? subscription.currentPeriodEnd)
        case .none:
            // Eski abone: deneme bittiyse "deneme bitti" değil "abonelik sona erdi". Stripe yenilemede dönem sonunu
            // hemen ilerlettiği için ödemesi alınamamış abonelikte dönem sonu gelecektedir: "sona erdi" denmez.
            if case .ended = trial {
                if hostedUnpaidSubscriptionStatuses.contains(subscription.status) {
                    return .paymentOverdue
                }
                return .expired(endedAt: subscription.cancelAt ?? subscription.currentPeriodEnd)
            }
        }
    }
    return .trial(trial)
}
