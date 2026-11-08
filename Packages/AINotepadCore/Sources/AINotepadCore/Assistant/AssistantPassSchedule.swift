import Foundation

// Asistan kopyası yükleme geçişlerinin zamanlaması (uygulamanın asistan merkezi kullanır): yerel değişiklikten sonra
// kısa bekleme, aynı anda tek geçiş, geçiş sürerken gelen değişiklik için bir geçiş daha, başarısız geçişten sonra artan
// bekleme. Durum tek bir değerdir; geçişler saf fonksiyondur, zamanlayıcı ve geçiş görevleri uygulamada kalır.

/// Yükleme geçişlerinin durumu.
public enum AssistantPassPhase: Sendable, Equatable {
    /// Ne geçiş ne bekleme var.
    case idle
    /// Bir zamanlayıcı bekliyor (yerel değişiklikten sonraki kısa bekleme ya da başarısız geçişten sonraki bekleme);
    /// dolunca geçiş başlar.
    case waiting
    /// Bir geçiş sürüyor; `needsAnother`: bu sırada yeni değişiklik geldi, geçiş başarıyla bitince bir geçiş daha.
    case running(needsAnother: Bool)
}

/// Zamanlamayı değiştiren olaylar.
public enum AssistantPassEvent: Sendable, Equatable {
    /// Bir geçiş istendi (yerel değişiklik, yenileme, "Yeniden dene"); 0 saniye: hemen.
    case requested(delaySeconds: Double)
    /// Zamanlayıcı doldu.
    case timerFired
    case passSucceeded
    /// Geçiş başarısız; `retryDelaySeconds` sonra yeniden denenir.
    case passFailed(retryDelaySeconds: Double)
    /// Geçiş iptal edildi ya da başlayamadı (özellik kapandı, defter unutuldu): yeniden denenmez.
    case passStopped
    /// Bütün iş durduruldu (kapatma, cihazı kaldırma, hesap değişimi).
    case reset
}

/// Uygulamanın geçişten sonra yapacağı yan etki.
public enum AssistantPassEffect: Sendable, Equatable {
    case none
    /// Zamanlayıcıyı (varsa eskisinin yerine) bu kadar saniyeye kur.
    case startTimer(seconds: Double)
    /// Zamanlayıcıyı iptal et ve geçişi başlat.
    case startPass
    /// Zamanlayıcıyı ve süren geçişi iptal et.
    case cancelWork
}

/// Bir olayın sonucu: yeni durum ve yan etki.
public struct AssistantPassStep: Sendable, Equatable {
    public let phase: AssistantPassPhase
    public let effect: AssistantPassEffect

    public init(phase: AssistantPassPhase, effect: AssistantPassEffect) {
        self.phase = phase
        self.effect = effect
    }
}

/// Zamanlamanın geçiş fonksiyonu. Geç gelen olaylar (boştayken dolan zamanlayıcı, geçiş yokken gelen geçiş sonucu)
/// durumu değiştirmez. Saf fonksiyondur.
public func assistantPassStep(phase: AssistantPassPhase, event: AssistantPassEvent) -> AssistantPassStep {
    let unchanged: AssistantPassStep = AssistantPassStep(phase: phase, effect: .none)
    switch (phase, event) {
    case (_, .reset):
        return AssistantPassStep(phase: .idle, effect: .cancelWork)
    case (.running, .requested):
        return AssistantPassStep(phase: .running(needsAnother: true), effect: .none)
    case (.idle, .requested(let delay)), (.waiting, .requested(let delay)):
        return delay > 0 ? AssistantPassStep(phase: .waiting, effect: .startTimer(seconds: delay)) : AssistantPassStep(phase: .running(needsAnother: false), effect: .startPass)
    case (.waiting, .timerFired):
        return AssistantPassStep(phase: .running(needsAnother: false), effect: .startPass)
    case (.running(let needsAnother), .passSucceeded):
        return needsAnother ? AssistantPassStep(phase: .running(needsAnother: false), effect: .startPass) : AssistantPassStep(phase: .idle, effect: .none)
    case (.running, .passFailed(let delay)):
        return AssistantPassStep(phase: .waiting, effect: .startTimer(seconds: delay))
    case (.running, .passStopped):
        return AssistantPassStep(phase: .idle, effect: .none)
    case (.idle, .timerFired), (.running, .timerFired), (.idle, .passSucceeded), (.waiting, .passSucceeded), (.idle, .passFailed), (.waiting, .passFailed),
        (.idle, .passStopped), (.waiting, .passStopped):
        return unchanged
    }
}
