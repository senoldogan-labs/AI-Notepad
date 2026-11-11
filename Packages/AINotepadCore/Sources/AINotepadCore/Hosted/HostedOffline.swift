import Foundation

// Abonelik sürümünde çevrimdışı kayıt: sunucuya ulaşılamazsa kayıt yine başlar (canlı metin Mac'te), toplantı
// "işlenmeyi bekliyor" olur; bağlantı gelince sunucuda bir oturum açılır (sunucu hakları yine denetler; aynı kayıt
// için yinelenen başlatma `clientRef` sayesinde aynı oturumu döndürür), son geçiş ve not o oturumla üretilir.
// Çevrimdışı başlatma, son bilinen hak durumu kaydı en çok 7 gün önce izin verdiyse ve hakkın bitişi (deneme süresi,
// iptal edilmiş aboneliğin ya da ek sürenin sonu) gelmediyse yapılabilir; kayıt o bitişi geçemez.

/// Son bilinen hak durumunun çevrimdışı kayda izni: kimin, ne zaman, en çok kaç dakikalık kayıt ve ne zamana dek.
/// `validUntil` alanını taşımayan eski izin çözülemez (izin yok sayılır; sonraki başarılı okuma yenisini yazar).
public struct HostedOfflinePermit: Codable, Sendable, Equatable {
    public let userId: String
    /// İzni veren hak durumunun okunduğu an.
    public let checkedAt: Date
    /// O andaki planla bir toplantının en çok süresi (deneme ya da abonelik üst sınırı ve kalan aylık süre).
    public let maxMinutes: Int
    /// İznin bittiği an: okumadan en çok `hostedOfflinePermitMaxAgeSec` sonra, hak daha önce bitiyorsa (deneme süresi,
    /// iptal edilmiş aboneliğin ya da ek sürenin sonu) o an.
    public let validUntil: Date

    public init(userId: String, checkedAt: Date, maxMinutes: Int, validUntil: Date) {
        self.userId = userId
        self.checkedAt = checkedAt
        self.maxMinutes = maxMinutes
        self.validUntil = validUntil
    }
}

/// Çevrimdışı kayıt iznin en çok yaşı (saniye): 7 gün.
public let hostedOfflinePermitMaxAgeSec: Double = 7 * 86_400

/// Hak durumundan çevrimdışı izin: kayıt başlatılabiliyorsa izin (süre: deneme ya da abonelik üst sınırı, abonede kalan
/// aylık dakikayla sınırlı; geçerlilik: en çok `maxAgeSec`, hak daha önce bitiyorsa o ana dek), başlatılamıyorsa
/// (deneme bitti, sınır doldu) nil. Yenilenen abonelik ve ücretsiz erişim için bitiş yoktur (yenileme ödemesi
/// alınamazsa sunucu ek süre tanır). Saf fonksiyondur.
public func hostedOfflinePermit(entitlements: HostedEntitlements, now: Date, maxAgeSec: Double) -> HostedOfflinePermit? {
    let minutes: Int
    let entitlementEnd: Date?
    switch hostedPlanStatus(entitlements: entitlements, now: now) {
    case .trial(.ended), .expired, .paymentOverdue:
        return nil
    case .trial(.notStarted):
        // Deneme ilk toplantıyla başlar: süresi o toplantıdan sonra işler.
        minutes = hostedUsualTrialMeetingMinutes
        entitlementEnd = nil
    case .trial(.running(_, _, let endsAt)):
        minutes = hostedUsualTrialMeetingMinutes
        entitlementEnd = endsAt
    case .subscribed, .complimentary:
        minutes = hostedSubscriberOfflineMinutes(entitlements: entitlements)
        entitlementEnd = nil
    case .ending(let endsAt), .grace(let endsAt):
        minutes = hostedSubscriberOfflineMinutes(entitlements: entitlements)
        entitlementEnd = endsAt
    }
    let maxAgeEnd: Date = now.addingTimeInterval(maxAgeSec)
    let validUntil: Date = entitlementEnd.map { (end: Date) -> Date in min(end, maxAgeEnd) } ?? maxAgeEnd
    guard minutes > 0, validUntil > now else {
        return nil
    }
    return HostedOfflinePermit(userId: entitlements.userId, checkedAt: now, maxMinutes: minutes, validUntil: validUntil)
}

/// Abonenin çevrimdışı toplantısının en çok süresi: olağan üst süre, kalan aylık dakikayla sınırlı (en az 0).
private func hostedSubscriberOfflineMinutes(entitlements: HostedEntitlements) -> Int {
    let remaining: Int = Int(((entitlements.monthlyHoursCap - entitlements.monthlyHoursUsed) * 60).rounded(.down))
    return max(0, min(hostedUsualSubscriberMeetingMinutes, remaining))
}

/// Çevrimdışı kayıt yapılabilir mi: izin aynı hesabın olmalı, okunduğu andan sonra ve bitişinden (`validUntil`) önce
/// olunmalı. Yapılabiliyorsa en çok süre (dakika): iznin süresi, iznin bitişine kalan tam dakikayla sınırlı (kayıt
/// deneme ya da abonelik bittikten sonra sürmez); bir dakikadan az kaldıysa ya da yapılamıyorsa nil. Saf fonksiyondur.
public func hostedOfflineRecordingMinutes(permit: HostedOfflinePermit?, userId: String?, now: Date) -> Int? {
    guard let permit, let userId, permit.userId == userId else {
        return nil
    }
    guard now >= permit.checkedAt, now < permit.validUntil else {
        return nil
    }
    let untilEnd: Int = Int((permit.validUntil.timeIntervalSince(now) / 60).rounded(.down))
    let minutes: Int = min(permit.maxMinutes, untilEnd)
    return minutes > 0 ? minutes : nil
}

/// Toplantı başlatma hatası sunucuya ulaşılamamaktan mı (ağ yok, sunucu ya da önündeki vekil yanıt vermiyor): öyleyse
/// kayıt çevrimdışı sürebilir. Sunucunun bilerek verdiği retler (deneme bitti, sınır, yetki) değildir. Saf fonksiyondur.
public func isOfflineStartError(error: any Error) -> Bool {
    switch error {
    case HostedClientError.network:
        return true
    case let error as HostedAPIError:
        switch error.code {
        case .none:
            return error.status >= 500 || error.status == 408
        case .some(.internalError), .some(.upstreamUnavailable):
            return true
        default:
            return false
        }
    default:
        return false
    }
}

/// Bekleyen (çevrimdışı) kaydın sunucu oturumunun hazırlığı.
public enum HostedQueuedMeetingPreparation: Sendable, Equatable {
    /// Oturum açık (ya da önceden açılmıştı): son geçiş ve not bu oturumla üretilebilir.
    case ready(serverMeetingID: String)
    /// Sunucuya hâlâ ulaşılamıyor: sonra yeniden denenir.
    case waitingForNetwork
    /// Son hak durumu kaydı şimdilik işlemiyor (deneme bitti, aylık sınır…; sunucuya istek atılmadı); kayıt bu Mac'te
    /// kalır, durum değişince yeniden denenir. Neden kullanıcıya gösterilir.
    case blocked(reason: String)
    /// Sunucu kaydın oturumunu reddetti (istek atıldı); neden gösterilir, kayıt bir süre denenmez
    /// (`hostedQueueRejectionCooldownSec`) ve kuyruk bu tetiklemede durur (başlatma hız sınırı canlı kayda kalsın).
    case rejected(reason: String)
}

/// Sunucunun reddettiği bekleyen kaydın yeniden denenmeden beklediği süre (saniye).
public let hostedQueueRejectionCooldownSec: Double = 10 * 60

/// Bu tetiklemede denenecek bekleyen kayıtlar: sunucunun son `cooldownSec` içinde reddettikleri atlanır (reddedilen
/// kayıt sonrakileri bekletmez, sürekli de denenmez). Sıra korunur. Saf fonksiyondur.
public func hostedQueueCandidates(records: [MeetingRecord], rejections: [String: Date], now: Date, cooldownSec: Double) -> [MeetingRecord] {
    records.filter { (record: MeetingRecord) -> Bool in
        guard let rejectedAt = rejections[record.id] else {
            return true
        }
        return now.timeIntervalSince(rejectedAt) >= cooldownSec
    }
}

/// Bekleyen kayıtların oturumdaki kullanıcıya göre ayrımı.
public struct HostedQueuedRecords: Sendable, Equatable {
    /// Bu kullanıcının bekleyen kayıtları (en eskisi önce); sırayla denenir, biri reddedilirse sonrakine geçilir.
    public let own: [MeetingRecord]
    /// Başka bir hesapla kaydedilmiş bekleyenler: bu hesapla işlenmez (o hesabın deneme ya da süresi düşer).
    public let foreign: [MeetingRecord]
}

/// Bekleyen kayıtları sahiplerine göre ayırır (`owners`: kayıt kimliği → kuyruğa alındığı andaki kullanıcı). Sahibi
/// bilinmeyen (sahiplik saklanmadan önce kuyruğa girmiş) kayıt oturumdaki kullanıcınındır. Saf fonksiyondur.
public func hostedQueuedRecords(records: [MeetingRecord], owners: [String: String], userId: String) -> HostedQueuedRecords {
    let queued: [MeetingRecord] = records.filter { $0.status == .queued }.sorted { $0.startedAt < $1.startedAt }
    let isOwn: (MeetingRecord) -> Bool = { (record: MeetingRecord) -> Bool in (owners[record.id] ?? userId) == userId }
    return HostedQueuedRecords(own: queued.filter(isOwn), foreign: queued.filter { !isOwn($0) })
}

/// How many times a meeting found still `processing` at launch is resumed automatically. A result that cannot be
/// written (a full disk) leaves the meeting `processing`; without a limit every launch would run the paid processing
/// again. After the limit the meeting stays interrupted and the user's "process again" resumes it.
public let automaticResumeLimit: Int = 2

/// Açılışta işlenirken yarıda kalmış bulunan (durumu hâlâ `processing`) ve sunucu oturumuna bağlı kayıtlar: kaldığı
/// yerden kendiliğinden işlenir (bkz. `processMeeting`). Kayıt sürerken kesilenler (`recording`) ve bağsız (çevrimdışı)
/// kayıtlar girmez; `resumeAttempts` (meeting id → automatic resumes so far) reaching `automaticResumeLimit` neither.
/// Saf fonksiyondur.
public func processingToResume(records: [MeetingRecord], linkedRecordIDs: Set<String>, resumeAttempts: [String: Int]) -> [MeetingRecord] {
    records.filter { (record: MeetingRecord) -> Bool in
        record.status == .processing && linkedRecordIDs.contains(record.id) && resumeAttempts[record.id, default: 0] < automaticResumeLimit
    }
}

/// Açılışta yarıda kalmış bulunan ve sunucu oturumuna bağlı olmayan (çevrimdışı) kayıtlar kuyruğa döner: bağlantı
/// gelince kendi oturumuyla işlenir. Bağlı kayıt "yarıda kaldı" kalır ("Tekrar işle" kendi oturumunu yeniden açar). Saf
/// fonksiyondur.
public func queuingUnlinkedInterrupted(records: [MeetingRecord], linkedRecordIDs: Set<String>) -> [MeetingRecord] {
    records.map { (record: MeetingRecord) -> MeetingRecord in
        guard record.status == .interrupted, !linkedRecordIDs.contains(record.id) else {
            return record
        }
        return record.with(status: .queued, failureMessage: nil)
            .with(notice: String(localized: "Çevrimdışı kayıt yarıda kaldı; kaydedilen kısım bağlantı gelince işlenir."))
    }
}
