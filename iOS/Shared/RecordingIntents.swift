import ActivityKit
#if !WIDGET_EXTENSION
import AINotepadCore
#endif
import AppIntents
import Foundation

// Uygulama ve widget eklentisinde ortak: canlı etkinliğin verisi ve kaydı başlatan/bitiren niyetler. Eklentide
// (`WIDGET_EXTENSION`) niyetlerin gövdesi boştur; sistem onları uygulamanın sürecinde çalıştırır.

/// Denetim Merkezi düğmesinin türü: uygulama kayıt durumu değişince bu türü yeniler.
let recordControlKind: String = "com.senoldogan.AINotepad.record"

/// Kaydın canlı etkinliği: kilit ekranı ve Dynamic Island'da başlık, süre, durum ve son cümle.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Son kesinleşen cümle; henüz yoksa boş.
        var lastLine: String
        /// Cümlenin konuşmacısı ("Konuşmacı 2"); bilinmiyorsa boş.
        var speaker: String
        /// Mikrofon kapandı, son bölümler bitiriliyor.
        var isFinishing: Bool
        /// Mikrofon kesildi (çağrı, alarm) ya da yeniden bağlanıyor; kayıt açık.
        var isMicrophonePaused: Bool
        /// "Bitir"e basılan an: süre burada durur; kayıt sürüyorsa nil.
        var stoppedAt: Date?
        /// Kullanıcı kaydı duraklattı: süren duraklatmanın başladığı an (süre burada durur); duraklatılmamışsa nil.
        var pausedAt: Date?
        /// Biten duraklatmaların toplamı (sn): sayaç kayıt başından bu kadar sonra başlamış gibi akar.
        var pausedSec: Double

        /// Duraklatılmış ve bitirilmiyor.
        var isPaused: Bool {
            pausedAt != nil && !isFinishing
        }
    }

    let startedAt: Date
    /// Toplantının adı (takvim etkinliği ya da "Toplantı").
    let title: String
    /// Kaydın kimliği (`RecordingID`): etkinlikteki düğmeler yalnız bu kaydı bitirir, duraklatır, sürdürür. Eski sürümün
    /// etkinliğinde yoksa nil.
    let recordingID: String?
}

/// Toplantıyı kaydet (Kısayollar, Siri, Denetim Merkezi, Eylem düğmesi, widget): uygulamayı öne getirmeden kaydı
/// başlatır (ses kaydı niyeti; canlı etkinlik mikrofon açılır açılmaz kilit ekranında görünür). Kayıt arka planda
/// başlayamıyorsa (giriş yok, yapay zekâ açıklaması onaylanmadı, abonelik gerekli, mikrofon izni sorulmadı ya da
/// verilmedi) uygulama açılır ve neden ana ekranda görünür.
struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Toplantıyı kaydet"
    static let description: IntentDescription = IntentDescription("Gistsmith'le yüz yüze toplantıyı kaydetmeye başlar; uygulama açılmadan kilit ekranında görünür.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    @Dependency private var router: PhoneRouter
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let recorder: PhoneRecorder = sessions.session.recorder
        router.showHome()
        if !canStartRecordingInBackground() {
            try await continueInForeground(nil, alwaysConfirm: false)
        }
        await recorder.start()
        #endif
        return .result()
    }
}

/// Kaydı başlat ya da bitir (Denetim Merkezi düğmesi): açmak kayıt yokken başlatır, kapatmak süren kaydı bitirir.
/// Kapatma hiçbir zaman kayıt başlatmaz (düğme eskimiş "Kaydediliyor" gösterirken uygulama yeniden açılmış olabilir;
/// kayıt yoksa `stop` yalnız kalan canlı etkinliği kaldırır); açma süren kayda dokunmaz.
struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Kaydı başlat ya da bitir"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Kayıt")
    var value: Bool

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    @Dependency private var router: PhoneRouter
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        let recorder: PhoneRecorder = sessions.session.recorder
        guard value else {
            recorder.stop()
            return .result()
        }
        guard recorder.phase == .idle else {
            return .result()
        }
        router.showHome()
        if !canStartRecordingInBackground() {
            try await continueInForeground(nil, alwaysConfirm: false)
        }
        await recorder.start()
        #endif
        return .result()
    }
}

/// Bu anı işaretle (canlı etkinlikteki düğme, Kısayollar): uygulamayı açmadan notta öne çıkacak anı işaretler.
struct MarkMomentIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Bu anı işaretle"
    static let description: IntentDescription = IntentDescription("Süren Gistsmith kaydında şu anı işaretler; notta öne çıkar.")

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        sessions.session.recorder.markMoment()
        #endif
        return .result()
    }
}

/// Kaydı bitir (Kısayollar, canlı etkinlikteki düğme): uygulamayı açmadan mikrofonu kapatır; toplantı işlenir.
struct StopRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kaydı bitir"
    static let description: IntentDescription = IntentDescription("Süren Gistsmith kaydını bitirir; not hazırlanır.")

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        sessions.session.recorder.stop()
        #endif
        return .result()
    }
}

/// Canlı etkinlikteki "Bitir": yalnız etkinliğin kaydını bitirir (başka kayıt başladıysa eski etkinliğin düğmesi bir
/// şey yapmaz). Kısayollar'da görünmez.
struct StopLiveRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kaydı bitir"
    static let isDiscoverable: Bool = false

    @Parameter(title: "Kayıt")
    var recordingID: String

    init() {
        recordingID = ""
    }

    init(recordingID: String) {
        self.recordingID = recordingID
    }

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        sessions.session.recorder.stop(target: .recording(RecordingID(rawValue: recordingID)))
        #endif
        return .result()
    }
}

/// Canlı etkinlikteki "Duraklat": yalnız etkinliğin kaydını duraklatır. Kısayollar'da görünmez.
struct PauseLiveRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kaydı duraklat"
    static let isDiscoverable: Bool = false

    @Parameter(title: "Kayıt")
    var recordingID: String

    init() {
        recordingID = ""
    }

    init(recordingID: String) {
        self.recordingID = recordingID
    }

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        sessions.session.recorder.pause(target: .recording(RecordingID(rawValue: recordingID)))
        #endif
        return .result()
    }
}

/// Canlı etkinlikteki "Devam": yalnız etkinliğin kaydını sürdürür. Kısayollar'da görünmez.
struct ResumeLiveRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kayda devam et"
    static let isDiscoverable: Bool = false

    @Parameter(title: "Kayıt")
    var recordingID: String

    init() {
        recordingID = ""
    }

    init(recordingID: String) {
        self.recordingID = recordingID
    }

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        sessions.session.recorder.resume(target: .recording(RecordingID(rawValue: recordingID)))
        #endif
        return .result()
    }
}

/// Kaydı duraklat (Kısayollar, canlı etkinlikteki düğme): uygulamayı açmadan sesi kaydetmeyi durdurur; kayıt açık kalır.
struct PauseRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kaydı duraklat"
    static let description: IntentDescription = IntentDescription("Süren Gistsmith kaydını duraklatır; duraklatılan süre kaydedilmez.")

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        sessions.session.recorder.pause()
        #endif
        return .result()
    }
}

/// Kayda devam et (Kısayollar, canlı etkinlikteki düğme): duraklatılan kaydı uygulamayı açmadan sürdürür.
struct ResumeRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Kayda devam et"
    static let description: IntentDescription = IntentDescription("Duraklatılan Gistsmith kaydını sürdürür.")

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        sessions.session.recorder.resume()
        #endif
        return .result()
    }
}
