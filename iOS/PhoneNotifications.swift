import AINotepadCore
import Foundation
import UserNotifications

/// Bildirim yanıtları (Mac'teki `AppDelegate`'in karşılığı): toplantı hatırlatmasındaki taze "Kaydı başlat" ana
/// ekranı açar ve kaydı başlatır, bildirime dokunma yalnız ana ekranı açar; "Toplantı bitti mi?" kaydı bitirir; not hazır, görev günü, haftalık
/// özet ve kayıtsız hafta bildirimleri kendi yerini açar ya da görevi işaretler (bkz. `engagementRoute`). Uygulama
/// öndeyken de bildirim görünür.
final class PhoneNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared: PhoneNotificationDelegate = PhoneNotificationDelegate()
    /// Toplantı bildirimine yanıt: "Kaydı başlat" eylemi mi ve bildirimin geldiği an; uygulama açılışında bağlanır.
    @MainActor static var onMeetingNotification: (@MainActor (Bool, Date) -> Void)?
    /// "Toplantı bitti mi?" yanıtı: kaydı bitir (true) ya da sürüyor (false); uygulama açılışında bağlanır.
    @MainActor static var onMeetingOverResponse: (@MainActor (Bool) -> Void)?
    /// Not hazır, görev günü, haftalık özet ve kayıtsız hafta bildirimlerinin yanıtı; uygulama açılışında bağlanır.
    /// "Tamamlandı" uygulama arka planda açılmışken de gelir: iş bitene dek beklenir.
    @MainActor static var onEngagementResponse: (@MainActor (EngagementRoute) async -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            return
        }
        let category: String = response.notification.request.content.categoryIdentifier
        if category == MeetingNotificationID.category {
            let isStartAction: Bool = response.actionIdentifier == MeetingNotificationID.startAction
            let deliveredAt: Date = response.notification.date
            await MainActor.run { PhoneNotificationDelegate.onMeetingNotification?(isStartAction, deliveredAt) }
            return
        }
        if category == MeetingNotificationID.meetingOverCategory {
            // Bildirime dokunmak uygulamayı açar (kayıt ekranında soru görünür); yalnız "Kaydı bitir" kaydı bitirir.
            guard response.actionIdentifier != UNNotificationDefaultActionIdentifier else {
                return
            }
            let finish: Bool = response.actionIdentifier == MeetingNotificationID.finishMeetingAction
            await MainActor.run { PhoneNotificationDelegate.onMeetingOverResponse?(finish) }
            return
        }
        guard let route = engagementRoute(response: response) else {
            return
        }
        await Self.handle(route: route)
    }

    @MainActor private static func handle(route: EngagementRoute) async {
        await onEngagementResponse?(route)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
