import AppIntents

/// Kısayollar ve Siri'de hazır gelen komutlar: kayıt, toplantılarına sor, açık görevler, toplantıyı aç (Mac'teki
/// `AINotepadMacShortcuts` ile aynı; ifadelerin çevirileri ortak `App/AppShortcuts.xcstrings`'te).
struct AINotepadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["\(.applicationName) ile toplantıyı kaydet", "\(.applicationName) kaydı başlat"],
            shortTitle: "Toplantıyı kaydet",
            systemImageName: "mic.fill"
        )
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
            intent: StopRecordingIntent(),
            phrases: ["\(.applicationName) kaydı bitir"],
            shortTitle: "Kaydı bitir",
            systemImageName: "stop.fill"
        )
        AppShortcut(
            intent: PauseRecordingIntent(),
            phrases: ["\(.applicationName) kaydı duraklat"],
            shortTitle: "Kaydı duraklat",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeRecordingIntent(),
            phrases: ["\(.applicationName) kayda devam et"],
            shortTitle: "Kayda devam et",
            systemImageName: "play.fill"
        )
    }
}
