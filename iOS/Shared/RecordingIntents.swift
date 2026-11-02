import ActivityKit
import AppIntents
import Foundation

// Uygulama ve widget eklentisinde ortak: canlı etkinliğin verisi ve kaydı başlatan/bitiren niyetler. Eklentide
// (`WIDGET_EXTENSION`) niyetlerin gövdesi boştur; sistem onları uygulamanın sürecinde çalıştırır.

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
    }

    let startedAt: Date
    /// Toplantının adı (takvim etkinliği ya da "Toplantı").
    let title: String
}

/// Toplantıyı kaydet (Kısayollar, Siri, Denetim Merkezi, Eylem düğmesi): uygulamayı açar ve kaydı başlatır.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toplantıyı kaydet"
    static let description: IntentDescription = IntentDescription("Gistsmith'i açar ve yüz yüze toplantıyı kaydetmeye başlar.")
    static let openAppWhenRun: Bool = true

    #if !WIDGET_EXTENSION
    @Dependency private var sessions: PhoneSessionHost
    @Dependency private var router: PhoneRouter
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        router.tab = .record
        await sessions.session.recorder.start()
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
