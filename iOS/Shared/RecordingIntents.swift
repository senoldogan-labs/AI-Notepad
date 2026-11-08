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

/// Canlı etkinliğin gösterdiği durum (tek değer; öncelik: bitiriliyor, kullanıcı duraklattı, mikrofon bekleniyor,
/// kaydediliyor). Uygulama yalnız bunu verir; widget başlığı, rengi, simgeyi, sayacı ve düğmeleri bundan seçer.
enum LiveRecordingStatus: Hashable {
    case recording
    /// Mikrofon kesildi (çağrı, alarm) ya da yeniden bağlanıyor; kayıt açık, ses gelince kendiliğinden sürer. Kesintide
    /// süre `timerStoppedAt`te durur; yeniden bağlanırken akar (nil). "Devam" görünmez (kayıt kendiliğinden sürer).
    case waitingForMicrophone(timerStoppedAt: Date?)
    /// Kullanıcı duraklattı: süre `since`te durur, "Devam" görünür.
    case paused(since: Date)
    /// Mikrofon kapandı, son bölümler bitiriliyor: süre `stoppedAt`te durur (önceki sürümün etkinliğinde yoksa akar),
    /// düğmeler gizlenir.
    case finishing(stoppedAt: Date?)

    /// Son bölümler bitiriliyor (düğmeler gizlenir).
    var isFinishing: Bool {
        if case .finishing = self {
            return true
        }
        return false
    }

    /// Kullanıcı duraklattı ("Devam" görünür).
    var isPausedByUser: Bool {
        if case .paused = self {
            return true
        }
        return false
    }

    /// Sayacın durduğu an; akıyorsa nil.
    var timerStoppedAt: Date? {
        switch self {
        case .recording:
            nil
        case .waitingForMicrophone(let timerStoppedAt):
            timerStoppedAt
        case .paused(let since):
            since
        case .finishing(let stoppedAt):
            stoppedAt
        }
    }
}

/// Kaydın canlı etkinliği: kilit ekranı ve Dynamic Island'da başlık, süre, durum ve son cümle.
struct RecordingActivityAttributes: ActivityAttributes {
    /// Saklanan alanlar ActivityKit'in kodlanmış biçimidir (uygulama güncellenirken süren etkinlik okunabilsin diye
    /// adları ve anlamları korunur); birbirini tutsunlar diye yalnız `init(lastLine:speaker:status:pausedSec:)` ile
    /// kurulur ve `status` ile okunur.
    struct ContentState: Codable, Hashable {
        /// Son kesinleşen cümle; henüz yoksa boş.
        let lastLine: String
        /// Cümlenin konuşmacısı ("Konuşmacı 2"); bilinmiyorsa boş.
        let speaker: String
        /// Biten duraklatmaların toplamı (sn): sayaç kayıt başından bu kadar sonra başlamış gibi akar.
        let pausedSec: Double
        private let isFinishing: Bool
        private let isMicrophonePaused: Bool
        private let stoppedAt: Date?
        /// Sayacın durduğu an (kullanıcı duraklatması ya da kesinti); bitirilirken nil.
        private let pausedAt: Date?
        /// Duraklatmayı kullanıcı yaptı. Önceki sürümün etkinliğinde yoksa nil: o sürümde `pausedAt` duraklatma sayılırdı.
        private let isPausedByUser: Bool?

        init(lastLine: String, speaker: String, status: LiveRecordingStatus, pausedSec: Double) {
            self.lastLine = lastLine
            self.speaker = speaker
            self.pausedSec = pausedSec
            switch status {
            case .recording:
                (isFinishing, isMicrophonePaused, stoppedAt, pausedAt, isPausedByUser) = (false, false, nil, nil, false)
            case .waitingForMicrophone(let timerStoppedAt):
                (isFinishing, isMicrophonePaused, stoppedAt, pausedAt, isPausedByUser) = (false, true, nil, timerStoppedAt, false)
            case .paused(let since):
                (isFinishing, isMicrophonePaused, stoppedAt, pausedAt, isPausedByUser) = (false, false, nil, since, true)
            case .finishing(let finishedAt):
                (isFinishing, isMicrophonePaused, stoppedAt, pausedAt, isPausedByUser) = (true, false, finishedAt, nil, false)
            }
        }

        /// Gösterilen durum (önceki sürümün etkinliğinde "Bitir" anı yoksa duraklatmanın başı).
        var status: LiveRecordingStatus {
            if isFinishing {
                return .finishing(stoppedAt: stoppedAt ?? pausedAt)
            }
            if let pausedAt, isPausedByUser ?? true {
                return .paused(since: pausedAt)
            }
            if isMicrophonePaused {
                return .waitingForMicrophone(timerStoppedAt: pausedAt)
            }
            return .recording
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
    @available(iOS 26.0, *)
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
            try await continueRecordingInForeground()
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
    @available(iOS 26.0, *)
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
            try await continueRecordingInForeground()
        }
        await recorder.start()
        #endif
        return .result()
    }
}

/// iOS 18–25'te kayıt arka planda başlayamadı (giriş, yapay zekâ onayı, abonelik ya da mikrofon izni gerekiyor; bunlar
/// yalnız önde sorulabilir): niyet ne yapılacağını söyleyen hatayla biter. Uygulamayı öne getiren `supportedModes` ve
/// `continueInForeground` iOS 26'da geldi; eski yol `ForegroundContinuableIntent` uygulama eklentisinde yok, niyetin
/// tanımı uygulamayla eklentide ayrışırdı.
struct OpenAppToRecordError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource {
        "Kaydı başlatmak için Gistsmith'i aç: önce giriş, onay ya da mikrofon izni gerekiyor."
    }
}

#if !WIDGET_EXTENSION
extension StartRecordingIntent {
    /// Uygulamayı öne getirip kaydı orada sürdürür (iOS 26+); eski sürümde `OpenAppToRecordError`.
    @MainActor
    fileprivate func continueRecordingInForeground() async throws {
        guard #available(iOS 26.0, *) else {
            throw OpenAppToRecordError()
        }
        try await continueInForeground(nil, alwaysConfirm: false)
    }
}

extension ToggleRecordingIntent {
    /// Uygulamayı öne getirip kaydı orada sürdürür (iOS 26+); eski sürümde `OpenAppToRecordError`.
    @MainActor
    fileprivate func continueRecordingInForeground() async throws {
        guard #available(iOS 26.0, *) else {
            throw OpenAppToRecordError()
        }
        try await continueInForeground(nil, alwaysConfirm: false)
    }
}
#endif

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
