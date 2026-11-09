import Foundation

/// Canlı oturumun arayüze bildirdiği olaylar.
public enum LiveSessionEvent: Sendable, Equatable {
    /// Yeni ya da güncellenmiş bölüm (geçici veya kesin).
    case segment(LiveSegment)
    /// Otomatik modda toplantı dili belirlendi.
    case languageLocked(MeetingLanguage)
    /// Bir konuşmacının ses akışı bitti (durduruldu ya da cihaz kayboldu).
    case captureEnded(speaker: Speaker)
    /// Ses dosyasına yazılamadı; yazıya dökme devam eder.
    case recordingFailed(speaker: Speaker, message: String)
    /// Konuşmacı ayırma bölümlere kişi numarası atadı.
    case speakersAssigned([SegmentID: Int])
    /// Bir konuşmacının canlı metin akışı kalıcı olarak durdu (ses kaydı sürer).
    case streamFailed(speaker: Speaker, message: String)
    /// A speaker's live text that stopped with `message` (`streamFailed`) is written again: the error line goes.
    case streamRecovered(speaker: Speaker, message: String)
    /// Kapanışta konuşmacının sesinin sonu yazıya dökülemedi (ses dosyada); toplantı sonunda kayıttan yazıya dökülmeli.
    case streamIncomplete(speaker: Speaker, untranscribedSec: Double)
    /// Bir konuşmacı ayırma penceresi başarısız oldu; sonraki pencere denenir.
    case diarizationFailed(message: String)
    /// Bulut canlı metni (Deepgram) durdu; canlı metin bu andan sonra Mac'te (WhisperKit) sürer. Ses kaydı kesilmez;
    /// geçiş sırasında kesinleşmemiş metin toplantı sonunda kayıttan yazıya dökülür. `message` nedeni söyler.
    case liveEngineFellBack(message: String)
    /// Bulut canlı metni durdu ve cihazda motor yok (iPhone, iOS 18–25): bağlantı geri çekilerek yeniden kuruluyor
    /// (`HybridCloudFailure.reconnectCloud`). Ses kaydı kesilmez; aradaki metin toplantı sonunda kayıttan yazılır.
    /// `message` kullanıcıya gösterilir.
    case liveTextReconnecting(message: String)
    /// Yeniden kurulan bulut bağlantısından ilk sonuç geldi: `liveTextReconnecting`'in aynı `message`'ı kalkar.
    case liveTextReconnected(message: String)
}

/// Çalışan canlı oturum: olay akışı ve kayıt sırasında verilebilen komutlar.
public struct LiveSessionHandle: Sendable {
    public let events: AsyncStream<LiveSessionEvent>
    private let languageSetter: @Sendable (MeetingLanguage) async -> Void
    private let canceller: @Sendable () async -> Void

    public init(
        events: AsyncStream<LiveSessionEvent>, languageSetter: @escaping @Sendable (MeetingLanguage) async -> Void, canceller: @escaping @Sendable () async -> Void
    ) {
        self.events = events
        self.languageSetter = languageSetter
        self.canceller = canceller
    }

    /// Oturumu kapanışı beklemeden bırakır (çağıranın bitirme süresi doldu): bulut bağlantıları (Deepgram WebSocket)
    /// hemen kesilir, kalan ses yazıya dökülmez ve olay akışı biter. Ses kaydı (dosyalar) etkilenmez; son geçiş kaydın
    /// tamamını yazıya döker.
    public func cancel() async {
        await canceller()
    }

    /// Toplantı dilini bu andan itibaren değiştirir; otomatik algılama artık dili değiştirmez.
    /// Oturum `.languageLocked` olayı yayınlar.
    public func setLanguage(_ language: MeetingLanguage) async {
        await languageSetter(language)
    }
}
