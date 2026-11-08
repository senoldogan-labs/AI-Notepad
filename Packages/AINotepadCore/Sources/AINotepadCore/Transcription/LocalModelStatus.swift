import Foundation

/// Bir cihaz içi konuşma modelinin durumu.
public enum ModelStatus: Sendable, Equatable {
    /// Abonelik: model henüz gerekmedi (canlı metin bulutta); gerekince (Mac'e geçişte) indirilir.
    case notLoaded
    case loading
    case ready
    case failed(String)
}

/// Mac'teki iki cihaz içi konuşma motoru.
public enum LocalSpeechModel: Sendable, Equatable {
    /// WhisperKit (geliştirici sürümünde canlı motor; abonelikte Mac'e geçiş ve eski macOS'ta sesle yazma).
    case whisperKit
    /// Apple'ın cihaz içi konuşma tanıması.
    case appleSpeech
}

/// İki motorun durumu ayrı ayrı: birinin geç biten yüklemesi ötekinin durumunu ezmez (ör. Apple modeli indirilirken
/// WhisperKit seçildi; Apple'ın "hazır"ı WhisperKit'i hazır göstermez).
public struct LocalModelStatuses: Sendable, Equatable {
    public let whisperKit: ModelStatus
    public let appleSpeech: ModelStatus

    public init(whisperKit: ModelStatus, appleSpeech: ModelStatus) {
        self.whisperKit = whisperKit
        self.appleSpeech = appleSpeech
    }

    /// `model`'in durumu.
    public func status(of model: LocalSpeechModel) -> ModelStatus {
        switch model {
        case .whisperKit:
            whisperKit
        case .appleSpeech:
            appleSpeech
        }
    }

    /// Yalnızca `model`'in durumu değişmiş kopya. Saf fonksiyondur.
    public func with(model: LocalSpeechModel, status: ModelStatus) -> LocalModelStatuses {
        switch model {
        case .whisperKit:
            LocalModelStatuses(whisperKit: status, appleSpeech: appleSpeech)
        case .appleSpeech:
            LocalModelStatuses(whisperKit: whisperKit, appleSpeech: status)
        }
    }
}
