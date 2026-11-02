import Foundation

/// Sesle yazma kısayolunun durumu. Kısayol basılı tutulursa bas-konuş (bırakınca biter), kısa dokunulursa eller serbest
/// dinleme (yeniden dokunma ya da Esc bitirir).
public enum DictationKeyState: Sendable, Equatable {
    case idle
    /// Tuş basılı, dinleniyor; bırakılınca basılı tutma mı dokunma mı olduğu süreden anlaşılır. `since`: basılma anı
    /// (sistem açılışından beri saniye).
    case pressed(since: Double)
    /// Kısa dokunuşla başladı; yeniden dokunma, Esc ya da süre sınırı bitirir.
    case handsFree
    /// Dinleme bitti; metin yazıya dökülüp yapıştırılıyor. Bu sırada kısayol yok sayılır.
    case transcribing
}

/// Durum makinesine gelen olaylar. Zamanlar sistem açılışından beri saniyedir.
public enum DictationKeyEvent: Sendable, Equatable {
    case keyDown(at: Double)
    case keyUp(at: Double)
    /// Eller serbest dinlemede Esc.
    case escape
    /// Dinleme süre sınırına ulaştı (açık unutulan mikrofon).
    case timeLimit
    /// Dinleme başlatılamadı ya da toplantı kaydı başladı: ses atılır.
    case cancel
    /// Yazıya dökme ve yapıştırma bitti (başarılı ya da hatalı).
    case finished
}

/// Geçişin uygulamaya yaptırdığı iş.
public enum DictationKeyEffect: Sendable, Equatable {
    /// Mikrofonu aç, dinlemeye başla.
    case startListening
    /// Dokunuştu: dinleme sürer; Esc dinlenir ve ipucu gösterilir.
    case enterHandsFree
    /// Mikrofonu kapat; sesi yazıya döküp yapıştır.
    case finishListening
    /// Mikrofonu kapat; sesi at.
    case cancelListening
}

/// Yeni durum ve (varsa) yapılacak iş.
public struct DictationKeyTransition: Sendable, Equatable {
    public let state: DictationKeyState
    public let effect: DictationKeyEffect?

    public init(state: DictationKeyState, effect: DictationKeyEffect?) {
        self.state = state
        self.effect = effect
    }
}

/// Bundan uzun basılı tutulan kısayol bas-konuştur; daha kısası dokunuştur (eller serbest).
public let dictationHoldThresholdSec: Double = 0.3

/// Tek bir dikte en fazla bu kadar dinler; sonra kendiliğinden biter ve yazılır (açık unutulan mikrofon).
public let dictationMaxListeningSec: Double = 300

/// Sesle yazma kısayolunun durum makinesi. Tanımsız olaylar (ör. dinlemiyorken Esc, yazıya dökerken kısayol) durumu
/// değiştirmez. Saf fonksiyondur.
public func dictationTransition(state: DictationKeyState, event: DictationKeyEvent, holdThresholdSec: Double) -> DictationKeyTransition {
    let unchanged: DictationKeyTransition = DictationKeyTransition(state: state, effect: nil)
    switch (state, event) {
    case (.idle, .keyDown(let at)):
        return DictationKeyTransition(state: .pressed(since: at), effect: .startListening)
    case (.pressed(let since), .keyUp(let at)):
        return at - since >= holdThresholdSec
            ? DictationKeyTransition(state: .transcribing, effect: .finishListening)
            : DictationKeyTransition(state: .handsFree, effect: .enterHandsFree)
    case (.handsFree, .keyDown), (.handsFree, .escape), (.handsFree, .timeLimit), (.pressed, .timeLimit):
        return DictationKeyTransition(state: .transcribing, effect: .finishListening)
    case (.pressed, .cancel), (.handsFree, .cancel):
        return DictationKeyTransition(state: .idle, effect: .cancelListening)
    case (.transcribing, .finished):
        return DictationKeyTransition(state: .idle, effect: nil)
    case (.idle, _), (.pressed, _), (.handsFree, _), (.transcribing, _):
        return unchanged
    }
}

/// Dinleme hangi durumlarda sürer (mikrofon açık). Saf fonksiyondur.
public func dictationIsListening(state: DictationKeyState) -> Bool {
    switch state {
    case .pressed, .handsFree: true
    case .idle, .transcribing: false
    }
}
