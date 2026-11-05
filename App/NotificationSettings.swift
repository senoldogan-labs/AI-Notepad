import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Ayarlar › Genel › Bildirimler: not hazır, görev günü, haftalık özet ve kayıtsız hafta (her biri varsayılan açık).
/// Açılan anahtar bildirim iznini (sorulmadıysa) sorar, kapanan anahtar o türün bekleyen bildirimlerini hemen kaldırır.
/// İzin reddedildiyse nedeni ve sistem bildirim ayarlarını açan düğme görünür.
struct NotificationSettingsGroup: View {
    @AppStorage(SettingsKey.notifyNoteReady) private var noteReady: Bool = true
    @AppStorage(SettingsKey.notifyTaskDue) private var taskDue: Bool = true
    @AppStorage(SettingsKey.notifyWeeklySummary) private var weeklySummary: Bool = true
    @AppStorage(SettingsKey.notifyInactive) private var inactive: Bool = true
    private let notifier: EngagementNotifier = .shared

    var body: some View {
        SettingsGroupHeader(title: "Bildirimler")
        VStack(alignment: .leading, spacing: 6) {
            Text("Bildirimler kilit ekranında da görünebilir: yalnız toplantı adı, sayılar ve görev metni yazar; konuşma metni ve özet yazmaz.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if notifier.authorization == .denied {
                HStack(spacing: 12) {
                    NoticeText(notificationMessage(error: NotificationError.denied), severity: .attention)
                    Button("Sistem Ayarları'nı aç") { openSystemNotificationSettings() }
                }
            }
        }
        .padding(.bottom, 4)
        row(
            title: "Not hazır olunca bildir",
            help: "Toplantının notu hazırlanınca, uygulama öndeyken değilse bildirim gelir: başlık, sana düşen görev ve karar sayısı. Tıklayınca toplantı açılır. Not hazırlanamadıysa bildirim gelmez.",
            isOn: $noteReady, kind: .noteReady
        )
        row(
            title: "Görevin günü gelince hatırlat",
            help: "Sana düşen açık bir görevin notta günü yazıyorsa (tarih, gün adı ya da \"yarın\") o gün saat 09:00'da bildirim gelir. \"Tamamlandı\" görevi uygulamayı açmadan işaretler; tıklayınca toplantı açılır. Belirsiz günler (\"gelecek hafta\") hatırlatılmaz.",
            isOn: $taskDue, kind: .taskDue
        )
        row(
            title: "Haftalık özet",
            help: "Pazartesi saat 09:00'da açık görev sayın, ilk üç açık görev ve geçen haftanın toplantı sayısı. Açık görev ve toplantı yoksa gelmez. Tıklayınca Görevler açılır.",
            isOn: $weeklySummary, kind: .weeklySummary
        )
        row(
            title: "Bir hafta kayıt yoksa hatırlat",
            help: "Son kayıttan 7 gün sonra saat 10:00'da bir kez, bir sonraki toplantını kaydetmeyi hatırlatır; takvim açıksa o günün toplantısı yazar. Yeni bir kayıtla yeniden kurulur.",
            isOn: $inactive, kind: .inactive
        )
        SettingsDivider().opacity(0)
            .padding(.bottom, 16)
            .task { await notifier.refreshAuthorization() }
    }

    private func row(title: LocalizedStringKey, help: LocalizedStringKey, isOn: Binding<Bool>, kind: EngagementKind) -> some View {
        SettingsRow(title: Text(title)) {
            Text(help)
        } control: {
            Toggle(title, isOn: isOn)
                .settingsToggle()
                .onChange(of: isOn.wrappedValue) { (_: Bool, enabled: Bool) in
                    Task { await notifier.settingChanged(kind: kind, enabled: enabled) }
                }
        }
    }

    /// Sistem Ayarları › Bildirimler'de bu uygulamanın sayfasını açar.
    private func openSystemNotificationSettings() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
