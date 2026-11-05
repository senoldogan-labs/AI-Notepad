import AINotepadCore
import Foundation
import UserNotifications

/// Bildirim yanıtları (Mac'teki `AppDelegate`'in karşılığı): toplantı hatırlatmasındaki "Dinlemeye başla" ya da
/// bildirime dokunma Kayıt sekmesini açar ve kaydı başlatır (kayıt kısayolundaki gibi); not hazır, görev günü, haftalık
/// özet ve kayıtsız hafta bildirimleri kendi yerini açar ya da görevi işaretler (bkz. `engagementRoute`). Uygulama
/// öndeyken de bildirim görünür.
final class PhoneNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared: PhoneNotificationDelegate = PhoneNotificationDelegate()
    /// Kaydı başlatır; uygulama açılışında bağlanır.
    @MainActor static var onStartRecording: (@MainActor () -> Void)?
    /// Not hazır, görev günü, haftalık özet ve kayıtsız hafta bildirimlerinin yanıtı; uygulama açılışında bağlanır.
    /// "Tamamlandı" uygulama arka planda açılmışken de gelir: iş bitene dek beklenir.
    @MainActor static var onEngagementResponse: (@MainActor (EngagementRoute) async -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
            return
        }
        if response.notification.request.content.categoryIdentifier == MeetingNotificationID.category {
            await MainActor.run { PhoneNotificationDelegate.onStartRecording?() }
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
