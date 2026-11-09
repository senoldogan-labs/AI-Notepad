import Foundation
import os
import UserNotifications
import WatchKit

// A Watch recording the system ends while the wrist is down (a call, Siri, the limit, low battery) would otherwise end
// silently: the user keeps talking to a watch that no longer records. A local notification says so at once.

private let notificationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.watch", category: "Notifications")

/// Asks once (at the first recording, in the foreground) to show a notice when the system ends a recording.
@MainActor
func watchRequestStopNotifications() {
    Task {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            notificationLogger.error("Notification permission request failed, error: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Shows `message` as a notification when the app is not on screen (on screen the alert in the app says it).
@MainActor
func watchNotifyRecordingEnded(message: String) {
    guard WKApplication.shared().applicationState != .active else {
        return
    }
    let content: UNMutableNotificationContent = UNMutableNotificationContent()
    content.title = "Gistsmith"
    content.body = message
    content.sound = .default
    let request: UNNotificationRequest = UNNotificationRequest(identifier: "watch-recording-ended", content: content, trigger: nil)
    Task {
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            notificationLogger.error("Recording-ended notification could not be shown, error: \(String(describing: error), privacy: .public)")
        }
    }
}
