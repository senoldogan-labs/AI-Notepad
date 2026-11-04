import AINotepadCore
import Foundation
import os
import UserNotifications

private let limitNotificationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "RecordingLimit")

/// Süre sınırı bildirimlerinin kimlikleri (kayıt bitince bekleyenler silinir).
private let recordingLimitWarningID: String = "recording-limit-warning"
private let recordingLimitReachedID: String = "recording-limit-reached"

/// Toplantının süre sınırı (abonelikte 4 saat, denemede 90 dakika) yaklaşınca ve dolunca yerel bildirim: uzun yüz yüze
/// toplantıda iPhone çoğunlukla kilitli masada durur; uyarı yalnızca kayıt ekranında olsaydı kayıt sınırda sessizce
/// biterdi ve kilit ekranındaki canlı etkinlik kaybolurdu. Metinler kayıt ekranındaki uyarılarla aynıdır. Bildirim izni
/// yoksa sistem göstermez (kayıt ekranındaki uyarı yine görünür).
@MainActor
func scheduleRecordingLimitNotifications(deadline: Date, warningLeadSec: Double) async {
    let time: String = deadline.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))
    let warningAt: TimeInterval = deadline.timeIntervalSinceNow - warningLeadSec
    let reachedAt: TimeInterval = deadline.timeIntervalSinceNow
    var requests: [UNNotificationRequest] = []
    if warningAt > 1 {
        requests.append(limitNotification(
            id: recordingLimitWarningID, body: String(localized: "Bu toplantının süre sınırına 5 dakika kaldı; kayıt \(time) itibarıyla bitirilecek."), afterSec: warningAt
        ))
    }
    if reachedAt > 1 {
        requests.append(limitNotification(
            id: recordingLimitReachedID, body: String(localized: "Bu toplantının süre sınırına ulaşıldı; kayıt bitirildi."), afterSec: reachedAt
        ))
    }
    for request in requests {
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            limitNotificationLogger.warning("Süre sınırı bildirimi kurulamadı, bildirim: \(request.identifier, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }
}

/// Kayıt bitti (ya da yenisi başladı): bekleyen süre sınırı bildirimleri silinir.
func cancelRecordingLimitNotifications() {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [recordingLimitWarningID, recordingLimitReachedID])
}

/// `afterSec` saniye sonra gösterilecek bildirim.
private func limitNotification(id: String, body: String, afterSec: TimeInterval) -> UNNotificationRequest {
    let content: UNMutableNotificationContent = UNMutableNotificationContent()
    content.body = body
    content.sound = .default
    return UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: afterSec, repeats: false))
}
