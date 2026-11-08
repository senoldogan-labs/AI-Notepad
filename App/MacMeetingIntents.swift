import AINotepadCore
import AppIntents
import Foundation
import SwiftUI

// Mac'te Kısayollar, Siri ve Spotlight'ın toplantılara ulaştığı yer (ortak varlıklar ve niyetler App/MeetingIntents.swift'te).

/// Mac'in arka ucu: toplantılar ve Sor AppModel'den, açma ana pencereden.
@MainActor
final class MacMeetingIntentsBackend: MeetingIntentsBackend {
    private let model: AppModel
    private let router: MainWindowRouter

    init(model: AppModel, router: MainWindowRouter) {
        self.model = model
        self.router = router
    }

    func intentMeetings() async throws -> [MeetingRecord] {
        try await model.meetingsForIntents()
    }

    func intentUserName() -> String {
        model.userName
    }

    func openMeeting(id: String) {
        openMeetingInMainWindow(router: router, meetingID: id)
    }

    func askAcrossMeetings(question: String) async throws -> String {
        try await model.askArchiveForIntent(question: question)
    }
}

/// Toplantıyı ana pencerede açar: listede görünsün diye arama ve klasör süzgeci kalkar (bildirim, Spotlight, Kısayollar).
@MainActor
func openMeetingInMainWindow(router: MainWindowRouter, meetingID: String) {
    router.searchQuery = ""
    router.folderFilter = nil
    router.selectedMeetingID = meetingID
    openMainWindow(router: router, section: .meetings)
}

/// Ayarlar › Genel: "Toplantıları Spotlight'ta göster" (varsayılan açık). Kapatınca dizin hemen silinir.
struct SpotlightSettingsRow: View {
    let model: AppModel
    @AppStorage(spotlightMeetingsSettingKey) private var enabled: Bool = true

    var body: some View {
        SettingsRow(icon: "magnifyingglass", title: Text("Toplantıları Spotlight'ta göster")) {
            SettingsMoreText(
                summary: Text("Spotlight'ta toplantının adını, kişileri ya da bir görevi yazınca not açılır."),
                details: Text("Spotlight'a toplantının adı, tarihi, katılımcıları, notun özeti ve görevleri girer; transkript, ses, ekran görüntüleri ve kendi notların girmez. Dizin yalnızca bu Mac'te durur ve Apple'a gönderilmez. Siri ve Kısayollar da toplantılarına buradan ulaşır (\"toplantılarıma sor\", \"görevlerim ne\"). Kapatınca dizin hemen silinir; oturumu kapatınca da silinir.")
            )
        } control: {
            Toggle("Toplantıları Spotlight'ta göster", isOn: Binding<Bool>(
                get: { enabled },
                set: { (isOn: Bool) -> Void in
                    enabled = isOn
                    MeetingSpotlightIndex.shared.update(records: model.meetings, userName: model.userName, isAllowed: isAccountDataReady() && !isSignInRequired())
                }
            ))
            .settingsToggle()
        }
    }
}

/// Kısayollar ve Siri'de hazır gelen komutlar (Mac), iPhone'daki `AINotepadShortcuts` ile aynı: sor, görevler, aç ve kayıt
/// komutları; ifadelerin çevirileri ortak `AppShortcuts.xcstrings`'te.
struct AINotepadMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskMeetingsIntent(),
            phrases: ["\(.applicationName) toplantılarıma sor", "\(.applicationName)'e sor"],
            shortTitle: "Toplantılarına sor",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
        AppShortcut(
            intent: MyTasksIntent(),
            phrases: ["\(.applicationName) görevlerim ne", "\(.applicationName) açık görevlerim"],
            shortTitle: "Açık görevlerim",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: OpenMeetingIntent(),
            phrases: ["\(.applicationName) toplantıyı aç", "\(.applicationName)'te toplantı aç"],
            shortTitle: "Toplantıyı aç",
            systemImageName: "doc.text.magnifyingglass"
        )
        AppShortcut(
            intent: MacStartRecordingIntent(),
            phrases: ["\(.applicationName) ile toplantıyı kaydet", "\(.applicationName) kaydı başlat"],
            shortTitle: "Toplantıyı kaydet",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: MacStopRecordingIntent(),
            phrases: ["\(.applicationName) kaydı bitir"],
            shortTitle: "Kaydı bitir",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: MacPauseRecordingIntent(),
            phrases: ["\(.applicationName) kaydı duraklat"],
            shortTitle: "Kaydı duraklat",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: MacResumeRecordingIntent(),
            phrases: ["\(.applicationName) kayda devam et"],
            shortTitle: "Kayda devam et",
            systemImageName: "play.fill"
        )
    }
}

// MARK: Kayıt (Mac)

/// Kayıt niyetlerinin AppModel'e ulaştığı yer; açılışta bağlanır. Başlatma menüdeki ve kısayoldaki yoldan geçer (giriş
/// kapısı, deneme, sınır denetimleri dahil).
@MainActor
enum MacRecordingControls {
    static var model: AppModel?
    static var start: (@MainActor () async -> Void)?

    static func requireModel() throws -> AppModel {
        guard let model else {
            throw MeetingIntentError.notReady
        }
        return model
    }
}

/// Toplantıyı kaydet (Kısayollar, Siri): kayıt yoksa menüdeki gibi başlatır; panel açılır.
struct MacStartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Toplantıyı kaydet"
    static let description: IntentDescription = IntentDescription("Bu Mac'te toplantıyı kaydetmeye başlar; canlı metin panelde akar.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        // Başlatma yolu kayıt sürerken ya da başlatılırken bir şey yapmaz (süren başlatmayı iptal etmez).
        _ = try MacRecordingControls.requireModel()
        guard let start = MacRecordingControls.start else {
            return .result()
        }
        await start()
        return .result()
    }
}

/// Kaydı bitir: süren kayıt "Bitir"e basılmış gibi biter, not hazırlanır.
struct MacStopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Kaydı bitir"
    static let description: IntentDescription = IntentDescription("Bu Mac'teki kaydı bitirir; not hazırlanır.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model: AppModel = try MacRecordingControls.requireModel()
        if model.isRecording {
            model.stopRecording()
        }
        return .result()
    }
}

/// Kaydı duraklat: duraklatılan süre kaydedilmez, kayıt açık kalır.
struct MacPauseRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Kaydı duraklat"
    static let description: IntentDescription = IntentDescription("Bu Mac'teki kaydı duraklatır; duraklatılan süre kaydedilmez.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model: AppModel = try MacRecordingControls.requireModel()
        if model.isRecording, !model.isPaused {
            model.togglePause()
        }
        return .result()
    }
}

/// Kayda devam et: duraklatılan kaydı sürdürür.
struct MacResumeRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Kayda devam et"
    static let description: IntentDescription = IntentDescription("Bu Mac'te duraklatılan kaydı sürdürür.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model: AppModel = try MacRecordingControls.requireModel()
        if model.isRecording, model.isPaused {
            model.togglePause()
        }
        return .result()
    }
}
