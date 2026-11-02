import Foundation
import UserNotifications

/// Bildirim yanıtları (Mac'teki `AppDelegate`'in karşılığı): toplantı hatırlatmasındaki "Dinlemeye başla" ya da
/// bildirime dokunma Kayıt sekmesini açar ve kaydı başlatır (kayıt kısayolundaki gibi). Uygulama öndeyken de hatırlatma
/// görünür.
final class PhoneNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared: PhoneNotificationDelegate = PhoneNotificationDelegate()
    /// Kaydı başlatır; uygulama açılışında bağlanır.
    @MainActor static var onStartRecording: (@MainActor () -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              response.notification.request.content.categoryIdentifier == MeetingNotificationID.category else {
            return
        }
        await MainActor.run { PhoneNotificationDelegate.onStartRecording?() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
