import Foundation

// İlk açılış karşılamasının adımları (Mac ve iPhone aynı akış): hoş geldin, takvim, izinler, örnek toplantı, hazırsın.
// Kendi anahtarlarıyla çalışan Mac sürümünde motor ve anahtar adımları da vardır. Şimdiki adım saklanır: uygulama
// yarıda kapanırsa karşılama kaldığı adımdan sürer; bitince `onboardingCompleted` yazılır ve bir daha gösterilmez.

/// Karşılamanın bir adımı; ham değer saklanan anahtardır (`onboardingStepKey`), değiştirilmez.
public enum OnboardingStep: String, Sendable, CaseIterable {
    /// Ne yaptığı, gizlilik sözü ve kullanıcının adı.
    case welcome
    /// Canlı metin motoru (yalnız kendi anahtarlarıyla çalışan Mac sürümü).
    case engine
    /// Bulut ve Claude anahtarları (yalnız kendi anahtarlarıyla çalışan Mac sürümü).
    case keys
    /// Takvimi bağlama ve sıradaki toplantılar.
    case calendar
    /// Mikrofon, toplantı sesi, bildirimler.
    case permissions
    /// Rehberli örnek toplantı.
    case sampleMeeting = "sample"
    /// Kısayollar ve ilk kayıt.
    case ready
}

/// Şimdiki adımın saklandığı ayar anahtarı (Mac ve iPhone; cihaza özgü, eşitlenmez).
public let onboardingStepKey: String = "onboarding.step"

/// Abonelik sürümünün (Mac ve iPhone) adımları: giriş, karşılamadan önce giriş kapısında yapılır.
public let hostedOnboardingSteps: [OnboardingStep] = [.welcome, .calendar, .permissions, .sampleMeeting, .ready]

/// Kendi anahtarlarıyla çalışan Mac sürümünün adımları.
public let ownKeysOnboardingSteps: [OnboardingStep] = [.welcome, .engine, .keys, .calendar, .permissions, .sampleMeeting, .ready]

/// Sıradaki adım; son adımdaysa (ya da adım listede yoksa) nil: karşılama biter. Saf fonksiyondur.
public func nextOnboardingStep(steps: [OnboardingStep], current: OnboardingStep) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: current), index + 1 < steps.count else {
        return nil
    }
    return steps[index + 1]
}

/// Önceki adım; ilk adımdaysa (ya da adım listede yoksa) nil. Saf fonksiyondur.
public func previousOnboardingStep(steps: [OnboardingStep], current: OnboardingStep) -> OnboardingStep? {
    guard let index = steps.firstIndex(of: current), index > 0 else {
        return nil
    }
    return steps[index - 1]
}

/// Açılışta gösterilecek adım: saklanan adım bu sürümün listesindeyse o, değilse (hiç saklanmadı, tanınmıyor ya da bu
/// sürümde yok) ilk adım. Saf fonksiyondur.
public func resumedOnboardingStep(steps: [OnboardingStep], stored: String?) -> OnboardingStep {
    guard let first = steps.first else {
        preconditionFailure("Karşılamanın adım listesi boş")
    }
    guard let stored, let step = OnboardingStep(rawValue: stored), steps.contains(step) else {
        return first
    }
    return step
}

/// İlerleme: adımın sırası (0 tabanlı) ve adım sayısı; adım listede yoksa sıra 0. Saf fonksiyondur.
public func onboardingProgress(steps: [OnboardingStep], current: OnboardingStep) -> (index: Int, count: Int) {
    (index: steps.firstIndex(of: current) ?? 0, count: steps.count)
}

/// Bir iznin durumu (karşılamanın izin satırı).
public enum PermissionStatus: Sendable, Equatable {
    /// Henüz okunmadı.
    case checking
    /// Hiç sorulmadı: "İzin ver" sistemin penceresini açar.
    case notDetermined
    /// Verildi.
    case granted
    /// Soruldu ama sistem durumunu göstermiyor (Mac'te sistem sesi kaydı): kullanıcı izin penceresinde seçtiyse hazır.
    case requested
    /// Reddedildi ya da sistem ayarlarında kapatıldı: yalnız Ayarlar'dan açılır.
    case denied
}

/// İzin satırının eylemi.
public enum PermissionAction: Sendable, Equatable {
    /// Eylem yok (verildi ya da okunuyor).
    case none
    /// Sistemin izin penceresini aç.
    case request
    /// Sistem ayarlarını aç (reddedildi; ya da durumu görünmeyen izni denetlemek için).
    case openSettings
}

/// Durumun eylemi. Saf fonksiyondur.
public func permissionAction(status: PermissionStatus) -> PermissionAction {
    switch status {
    case .checking, .granted: .none
    case .notDetermined: .request
    case .requested, .denied: .openSettings
    }
}

/// Takvimden kanıt olarak gösterilecek sıradaki toplantılar: henüz bitmemiş olanlar başlangıç sırasıyla, en fazla
/// `limit` tane. Saf fonksiyondur.
public func upcomingProofMeetings(meetings: [CalendarMeeting], now: Date, limit: Int) -> [CalendarMeeting] {
    Array(meetings.filter { $0.end > now }.sorted { $0.start < $1.start }.prefix(limit))
}
