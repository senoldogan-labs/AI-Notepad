import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Ayarlar › Bildirimler: not hazır, görev günü, haftalık özet ve kayıtsız hafta (her biri varsayılan açık).
/// Açılan anahtar bildirim iznini (sorulmadıysa) sorar, kapanan anahtar o türün bekleyen bildirimlerini hemen kaldırır.
/// İzin reddedildiyse nedeni ve sistem bildirim ayarlarını açan düğme görünür.
struct NotificationSettingsGroup: View {
    @AppStorage(SettingsKey.notifyNoteReady) private var noteReady: Bool = true
    @AppStorage(SettingsKey.notifyTaskDue) private var taskDue: Bool = true
    @AppStorage(SettingsKey.notifyWeeklySummary) private var weeklySummary: Bool = true
    @AppStorage(SettingsKey.notifyInactive) private var inactive: Bool = true
    private let notifier: EngagementNotifier = .shared

    var body: some View {
        SettingsGroup(title: Text("Bildirimler")) {
            if notifier.authorization == .denied {
                SettingsRow(icon: "bell.slash", title: Text("Bildirim izni yok")) {
                    NoticeText(notificationMessage(error: NotificationError.denied), severity: .attention)
                } control: {
                    Button("Sistem Ayarları'nı aç") { openSystemNotificationSettings() }
                }
            }
            row(
                icon: "bell.badge", title: "Not hazır olunca bildir",
                summary: "Not hazırlanınca bildirir; tıklayınca toplantı açılır.",
                help: "Toplantının notu hazırlanınca, uygulama öndeyken değilse bildirim gelir: başlık, sana düşen görev ve karar sayısı. Tıklayınca toplantı açılır. Not hazırlanamadıysa bildirim gelmez.",
                isOn: $noteReady, kind: .noteReady
            )
            row(
                icon: "checklist", title: "Görevin günü gelince hatırlat",
                summary: "O gün 09:00'da; \"Tamamlandı\" ile işaretlenir.",
                help: "Sana düşen açık bir görevin notta günü yazıyorsa (tarih, gün adı ya da \"yarın\") o gün saat 09:00'da bildirim gelir. \"Tamamlandı\" görevi uygulamayı açmadan işaretler; tıklayınca toplantı açılır. Belirsiz günler (\"gelecek hafta\") hatırlatılmaz.",
                isOn: $taskDue, kind: .taskDue
            )
            row(
                icon: "calendar.badge.clock", title: "Haftalık özet",
                summary: "Pazartesi 09:00'da açık görevler ve toplantı sayısı.",
                help: "Pazartesi saat 09:00'da açık görev sayın, ilk üç açık görev ve geçen haftanın toplantı sayısı. Açık görev ve toplantı yoksa gelmez. Tıklayınca Görevler açılır.",
                isOn: $weeklySummary, kind: .weeklySummary
            )
            row(
                icon: "hourglass", title: "Bir hafta kayıt yoksa hatırlat",
                summary: "Son kayıttan 7 gün sonra 10:00'da bir kez.",
                help: "Son kayıttan 7 gün sonra saat 10:00'da bir kez, bir sonraki toplantını kaydetmeyi hatırlatır; takvim açıksa o günün toplantısı yazar. Yeni bir kayıtla yeniden kurulur.",
                isOn: $inactive, kind: .inactive
            )
        } footer: {
            Text("Bildirimler kilit ekranında da görünebilir: yalnız toplantı adı, sayılar ve görev metni yazar; konuşma metni ve özet yazmaz.")
        }
        .task { await notifier.refreshAuthorization() }
    }

    private func row(icon: String, title: LocalizedStringKey, summary: LocalizedStringKey, help: LocalizedStringKey, isOn: Binding<Bool>, kind: EngagementKind) -> some View {
        SettingsRow(icon: icon, title: Text(title)) {
            SettingsMoreText(summary: Text(summary), details: Text(help))
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
