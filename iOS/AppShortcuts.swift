import AppIntents

/// Kısayollar ve Siri'de hazır gelen komutlar.
struct AINotepadShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["\(.applicationName) ile toplantıyı kaydet", "\(.applicationName) kaydı başlat"],
            shortTitle: "Toplantıyı kaydet",
            systemImageName: "mic.fill"
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
