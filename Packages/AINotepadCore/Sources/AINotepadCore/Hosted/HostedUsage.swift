import Foundation

// Abonelik sürümünün kullanım göstergeleri ve bildirimleri: aylık saat sınırı (abone), toplantı dışı yapay zekâ payı,
// ücretsiz deneme ve kısaltılmış toplantı süresi. Sunucu ayı UTC'ye göre sayar (`server/src/usage.ts`, `monthKey`).

/// Ölçerin uyarı rengine geçtiği doluluk oranı.
public let hostedUsageWarningFraction: Double = 0.8

/// Sunucunun olağan toplantı üst süresi (dakika; `server/wrangler.jsonc` `SUBSCRIBER_MAX_MEETING_MINUTES`,
/// `TRIAL_MAX_MEETING_MINUTES`). Açılan toplantının süresi bundan kısaysa kayıtta kalan dakika gösterilir.
public let hostedUsualSubscriberMeetingMinutes: Int = 240
public let hostedUsualTrialMeetingMinutes: Int = 90

/// Ölçerin doluluk düzeyi.
public enum HostedUsageLevel: Sendable, Equatable {
    case normal
    /// %80 ve üstü.
    case warning
    /// Sınıra ulaşıldı (%100).
    case full
}

/// Kullanım oranı, 0…1 aralığında. Sınır sıfır ya da negatifse dolu sayılır (kullanılabilir pay yok). Saf fonksiyondur.
public func hostedUsageFraction(used: Double, cap: Double) -> Double {
    guard cap > 0 else {
        return 1
    }
    return min(1, max(0, used / cap))
}

/// Orana göre düzey. Saf fonksiyondur.
public func hostedUsageLevel(fraction: Double) -> HostedUsageLevel {
    if fraction >= 1 {
        return .full
    }
    return fraction >= hostedUsageWarningFraction ? .warning : .normal
}

/// Kalan deneme toplantısına göre düzey: 1 kaldıysa dikkat, bittiyse dolu (Mac ve iPhone'daki deneme göstergeleri). Saf
/// fonksiyondur.
public func hostedTrialLevel(left: Int) -> HostedUsageLevel {
    switch left {
    case ...0: .full
    case 1: .warning
    default: .normal
    }
}

/// UTC takvimi (sunucunun ay sınırı).
private func utcCalendar() -> Calendar {
    var calendar: Calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

/// Aylık sınırın sıfırlandığı an: bir sonraki UTC ayının ilk anı. Saf fonksiyondur.
public func hostedMonthResetDate(now: Date) -> Date {
    let calendar: Calendar = utcCalendar()
    let start: Date = calendar.dateInterval(of: .month, for: now)?.start ?? now
    return calendar.date(byAdding: .month, value: 1, to: start) ?? now
}

/// Dönem anahtarı "YYYY-MM" (UTC; sunucunun `monthKey`'i). Saf fonksiyondur.
public func hostedPeriodKey(now: Date) -> String {
    let components: DateComponents = utcCalendar().dateComponents([.year, .month], from: now)
    return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
}

/// Kullanıcıya bir kez gösterilen kullanım bildirimi.
public enum HostedUsageNotice: String, Sendable, Equatable, CaseIterable {
    /// Aylık saatlerin %80'i doldu.
    case monthlyWarning
    /// Aylık saatler doldu: yeni kayıt başlamaz.
    case monthlyFull
    /// Ücretsiz denemede tek toplantı kaldı.
    case trialOneLeft
    /// Ücretsiz deneme bitti.
    case trialEnded
}

/// Hak durumundan gösterilecek bildirim (varsa): abonede aylık doluluk, denemede kalan toplantı. Saf fonksiyondur.
public func hostedUsageNotice(entitlements: HostedEntitlements, now: Date) -> HostedUsageNotice? {
    switch hostedPlanStatus(entitlements: entitlements, now: now) {
    case .trial(.ended):
        return .trialEnded
    case .trial(let trial):
        return trial.meetingsLeft == 1 ? .trialOneLeft : nil
    case .expired, .paymentOverdue:
        // Başlat düğmesinin yanındaki neden yeterli (bkz. `hostedStartBlock`).
        return nil
    case .subscribed, .complimentary, .ending, .grace:
        switch hostedUsageLevel(fraction: hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)) {
        case .full:
            return .monthlyFull
        case .warning:
            return .monthlyWarning
        case .normal:
            return nil
        }
    }
}

/// Bildirimin "gösterildi" kaydının anahtarı: aylık bildirimler hesap ve ay başına, deneme bildirimleri hesap başına
/// (deneme bir kez yaşanır). Saf fonksiyondur.
public func hostedNoticeStorageKey(notice: HostedUsageNotice, userId: String, now: Date) -> String {
    switch notice {
    case .monthlyWarning, .monthlyFull:
        "hosted.notice.\(notice.rawValue).\(userId).\(hostedPeriodKey(now: now))"
    case .trialOneLeft, .trialEnded:
        "hosted.notice.\(notice.rawValue).\(userId)"
    }
}

/// Açılan toplantının süresi olağandan kısa mı (ör. aylık sınıra az kaldı): kayıtta kalan dakika gösterilir. Saf
/// fonksiyondur.
public func isShortenedHostedMeeting(started: HostedStartedMeeting) -> Bool {
    let usual: Int = started.kind == "trial" ? hostedUsualTrialMeetingMinutes : hostedUsualSubscriberMeetingMinutes
    return started.maxDurationMinutes < usual
}

/// Kayda kalan tam dakika (yukarı yuvarlanır, en az 0). Saf fonksiyondur.
public func hostedMinutesLeft(deadline: Date, now: Date) -> Int {
    max(0, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
}

/// Kaydın başlayamama nedeni (hak durumundan; Ana sayfadaki başlat düğmesi kapanır ve yanında yazar).
public enum HostedStartBlock: Sendable, Equatable {
    /// Ücretsiz deneme bitti (toplantılar ya da süre).
    case trialEnded
    /// Bu ayın adil kullanım saatleri doldu.
    case monthlyCapReached
    /// Abonelik sona erdi, deneme hakkı da yok.
    case subscriptionEnded
    /// Yenileme ödemesi alınamadı ve ek süre bitti: kart güncellenene dek kayıt başlamaz.
    case paymentOverdue
}

/// Hak durumuna göre kayıt başlayabilir mi; başlayamıyorsa neden. Ek süredeki ve iptal edilip dönemi süren abonelik
/// kayıt yapabilir (sınır dolmadıkça). Deneme süresi hak durumu okunduktan sonra dolduysa da kayıt başlamaz (`now`).
/// Saf fonksiyondur.
public func hostedStartBlock(entitlements: HostedEntitlements, now: Date) -> HostedStartBlock? {
    switch hostedPlanStatus(entitlements: entitlements, now: now) {
    case .trial(.ended):
        return .trialEnded
    case .trial(.notStarted), .trial(.running):
        return nil
    case .expired:
        return .subscriptionEnded
    case .paymentOverdue:
        return .paymentOverdue
    case .subscribed, .complimentary, .ending, .grace:
        let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
        return hostedUsageLevel(fraction: fraction) == .full ? .monthlyCapReached : nil
    }
}

/// Kaydı engelleyen hak durumunun çözümü: nedenin yanındaki tek düğme.
public enum HostedStartBlockRemedy: Sendable, Equatable {
    /// Abone ol (deneme bitti, abonelik sona erdi).
    case subscribe
    /// Hesap ekranı: kullanım ve sıfırlanma günü (aylık sınır) ya da ödeme yöntemini güncelleme (ödeme alınamadı).
    case openAccount
}

/// Engelin çözümü (Mac'teki `hostedStartBlockNotice` ile aynı eşleme). Saf fonksiyondur.
public func hostedStartBlockRemedy(block: HostedStartBlock) -> HostedStartBlockRemedy {
    switch block {
    case .trialEnded, .subscriptionEnded: .subscribe
    case .monthlyCapReached, .paymentOverdue: .openAccount
    }
}

/// Hak durumunun eskimiş sayıldığı süre (saniye): uygulama her öne geldiğinde, son okuma bundan eskiyse yeniden okunur
/// (ödeme sayfasından dönüşte beklemeden; bkz. `HostedAccount.refreshOnActivation`).
public let hostedStaleRefreshIntervalSec: Double = 60

/// İçe aktarılan dosya, şimdi açılacak toplantının ses hakkından uzun: kuyruğa alınmaz (son geçiş yarıda kesilirdi).
public enum HostedImportError: Error, Sendable, Equatable {
    case longerThanMeetingAllowance(durationMinutes: Int, maxMinutes: Int)
}

/// Sunucunun parça örtüşmesi için toplantının ses hakkına eklediği pay (saniye): her 2900 saniyelik adım için 60 sn
/// (sunucudaki `chunkOverlapAllowance` ile aynı). Saf fonksiyondur.
public func hostedServerOverlapAllowanceSec(seconds: Double) -> Double {
    (seconds / 2900).rounded(.towardZero) * 60
}

/// Kaydın sunucuya gidecek toplam sesi (saniye): parçalar bir dakika örtüştüğü için süreden uzundur. 95 MB'lık WAV
/// parçalamasıyla (~49,5 dk; `wavChunkSpans`) hesaplanır; sunucunun örtüşme payı da bu adıma dayanır. FLAC parçaları
/// (en çok 60 dk, `writeHostedFlacChunks`) konuşma kayıtlarında bundan uzundur (daha az örtüşme), tahmin üst sınır
/// kalır; yalnızca sıkışmayan seste (beyaz gürültü) FLAC parçası 95 MB'a sığmak için ~%1 kısalır. Saf fonksiyondur.
public func hostedUploadedAudioSec(durationSec: Double) -> Double {
    let spans: [AudioChunkSpan] = wavChunkSpans(
        totalSamples: Int((durationSec * Double(hostedTranscribeSampleRate)).rounded(.up)),
        maxSamples: maxSamplesPerWavChunk(maxBytes: hostedTranscribeMaxBytes),
        overlapSamples: Int(hostedChunkOverlapSec * Double(hostedTranscribeSampleRate))
    )
    return Double(spans.reduce(0) { $0 + $1.sampleCount }) / Double(hostedTranscribeSampleRate)
}

/// İçe aktarılacak dosyayı son okunan hak durumuyla karşılaştırır: sunucuya gidecek sesi (parça örtüşmesi dahil)
/// toplantının ses hakkını (`meetingMaxMinutes` + sunucunun örtüşme payı) aşıyorsa `HostedImportError`. Alanı bilmeyen
/// eski sunucuda denetlenmez (sunucu son geçişte yine reddeder). Saf fonksiyondur.
public func requireHostedImportFits(durationSec: Double, entitlements: HostedEntitlements) throws {
    guard let maxMinutes = entitlements.meetingMaxMinutes else {
        return
    }
    let allowance: Double = Double(maxMinutes) * 60 + hostedServerOverlapAllowanceSec(seconds: Double(maxMinutes) * 60)
    guard hostedUploadedAudioSec(durationSec: durationSec) > allowance else {
        return
    }
    throw HostedImportError.longerThanMeetingAllowance(durationMinutes: Int((durationSec / 60).rounded(.up)), maxMinutes: maxMinutes)
}

/// Hak durumu yeniden okunmalı mı: hiç okunmadıysa ya da son okuma `intervalSec`'ten eskiyse. Saf fonksiyondur.
public func isHostedRefreshDue(lastRefresh: Date?, now: Date, intervalSec: Double) -> Bool {
    guard let lastRefresh else {
        return true
    }
    return now.timeIntervalSince(lastRefresh) >= intervalSec
}

/// Abone olma teklifinin (ana pencerede açılan kart) gösterildiği an.
public enum HostedUpsellMoment: String, Sendable, Equatable {
    /// Deneme toplantısının notu hazır; denemede hâlâ toplantı var.
    case trialNoteReady
    /// Deneme bitmek üzere (son toplantı kaldı ya da süresi `hostedTrialEndingWindowSec` içinde doluyor): o ana dek
    /// yapılanların özeti ve planlar.
    case trialEnding
    /// Son deneme toplantısının notu hazır: deneme bitti.
    case trialEnded
    /// Kullanıcı abonelik gerektiren bir şey denedi (kayıt başlatma, Sor, not) ama hakkı yok: deneme bitti, bu Mac'te
    /// deneme kullanıldı ya da abonelik sona erdi.
    case subscriptionRequired
    /// Kullanıcı "Abone ol"a bastı (Ayarlar › Hesap, kullanım bildirimi): planlar.
    case planChoice
}

/// Teklifin gösterimi: kendiliğinden gelen anlar (not hazır, deneme bitiyor ya da bitti) sayfayı kapatmaz, altta ince
/// şerit olur (kullanıcı önce notunu görür, şeritten planları açar); kullanıcının istediği ya da abonelik gerektiren bir
/// şeyi denediği anlar planları hemen açar.
public enum HostedUpsellPresentation: Sendable, Equatable {
    case strip
    case sheet
}

/// Anın gösterimi (bkz. `HostedUpsellPresentation`). Saf fonksiyondur.
public func hostedUpsellPresentation(moment: HostedUpsellMoment) -> HostedUpsellPresentation {
    switch moment {
    case .trialNoteReady, .trialEnding, .trialEnded: .strip
    case .subscriptionRequired, .planChoice: .sheet
    }
}

/// Sunucunun abonelik reddinden açılan teklif en çok bu aralıkla bir gösterilir (saniye): arka plandaki işler (bekleyen
/// kayıtlar, uygulama öne gelince yenileme) teklifi art arda açmasın. Kullanıcının kendi denemesi (Başlat) her zaman açar.
public let hostedSubscriptionPromptIntervalSec: Double = 10 * 60

/// Deneme notu hazır olunca teklif en çok bu aralıkla bir gösterilir (saniye): günde bir.
public let hostedUpsellIntervalSec: Double = 24 * 60 * 60

/// Deneme süresinin bitmesine bu kadar (saniye) kala deneme "bitmek üzere" sayılır.
public let hostedTrialEndingWindowSec: Double = 48 * 60 * 60

/// Deneme bitmek üzere mi: sürüyor ve tek toplantı kaldı ya da süresi `hostedTrialEndingWindowSec` içinde doluyor
/// (bitmiş ya da başlamamış deneme bitmek üzere değildir). Saf fonksiyondur.
public func isHostedTrialEnding(trial: HostedTrialState, now: Date) -> Bool {
    guard case .running(let left, _, let endsAt) = trial else {
        return false
    }
    if left == 1 {
        return true
    }
    guard let endsAt else {
        return false
    }
    return endsAt.timeIntervalSince(now) <= hostedTrialEndingWindowSec
}

/// Bir toplantının notu hazır olunca teklif gösterilsin mi; gösterilecekse hangi an. Yalnızca denemede: deneme bittiyse
/// (kalan 0) hesap başına bir kez `trialEnded`; bitmek üzereyse (`isHostedTrialEnding`) hesap başına bir kez
/// `trialEnding`; değilse son gösterimden en az `intervalSec` geçtiyse `trialNoteReady`. Abonede, süresi bitmiş
/// abonelikte ve aralık dolmadıysa nil. Saf fonksiyondur.
public func hostedUpsellMoment(
    entitlements: HostedEntitlements, lastShownAt: Date?, trialEndedShown: Bool, trialEndingShown: Bool, now: Date, intervalSec: Double
) -> HostedUpsellMoment? {
    guard case .trial(let trial) = hostedPlanStatus(entitlements: entitlements, now: now) else {
        return nil
    }
    if case .ended = trial {
        return trialEndedShown ? nil : .trialEnded
    }
    if !trialEndingShown && isHostedTrialEnding(trial: trial, now: now) {
        return .trialEnding
    }
    if let lastShownAt, now.timeIntervalSince(lastShownAt) < intervalSec {
        return nil
    }
    return .trialNoteReady
}
