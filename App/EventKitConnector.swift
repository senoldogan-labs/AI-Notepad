import AINotepadCore
import EventKit
import Foundation

/// Takvim ve anımsatıcı erişimi reddedildi ya da kullanılamıyor.
enum EventKitError: Error, Equatable {
    case remindersAccessDenied
    case calendarAccessDenied
    case noReminderList
    case saveFailed(reason: String)
    /// Takvim izni istenirken sistem hatası.
    case calendarRequestFailed(reason: String)
}

/// Apple Takvim ve Anımsatıcılar bağlantısı (EventKit). İzin ilk kullanımda sorulur; tek bir mağaza örneği paylaşılır.
@MainActor
final class EventKitConnector {
    private let store: EKEventStore = EKEventStore()

    /// Takvim izni verilmiş mi (izin sorulmaz).
    var hasCalendarAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Takvim izni ister (ilk kez açılınca macOS sorar).
    func requestCalendarAccess() async throws {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            throw EventKitError.calendarRequestFailed(reason: error.localizedDescription)
        }
        guard granted else {
            throw EventKitError.calendarAccessDenied
        }
    }

    /// `start`tan (o anda sürenler dahil) `hours` saat sonrasına kadarki etkinlikler; tüm gün etkinlikleri hariç.
    func meetings(from start: Date, hours: Double) throws -> [CalendarMeeting] {
        guard hasCalendarAccess else {
            throw EventKitError.calendarAccessDenied
        }
        let predicate: NSPredicate = store.predicateForEvents(withStart: start.addingTimeInterval(-8 * 3600), end: start.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate)
            // Reddedilen davetler toplantı sayılmaz (kendiliğinden kayıt ve hatırlatma onlara bağlanmasın).
            .filter { (event: EKEvent) -> Bool in
                !event.isAllDay && event.endDate > start && event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .map { (event: EKEvent) -> CalendarMeeting in
                CalendarMeeting(
                    id: Self.meetingID(event: event),
                    title: event.title ?? String(localized: "Toplantı"),
                    start: event.startDate,
                    end: event.endDate,
                    attendees: (event.attendees ?? [])
                        .filter { !$0.isCurrentUser }
                        .compactMap { attendeeName(raw: $0.name ?? $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")) },
                    joinURL: meetingJoinURL(texts: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// Kayda bağlanan takvim toplantısının (`calendarEventID`) katılımcılarının e-posta adresleri, kullanıcının kendisi
    /// hariç (takip e-postasının alıcıları). Takvim izni yoksa, etkinlik artık yoksa ya da katılımcıların adresi yoksa
    /// boş: alıcılar e-posta uygulamasında elle yazılır. İzin sorulmaz.
    func attendeeEmails(calendarEventID: String) -> [String] {
        guard hasCalendarAccess, let start = calendarMeetingStart(id: calendarEventID) else {
            return []
        }
        let predicate: NSPredicate = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(60), calendars: nil)
        guard let event = store.events(matching: predicate).first(where: { Self.meetingID(event: $0) == calendarEventID }) else {
            return []
        }
        return uniqueEmailAddresses(addresses: (event.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { attendeeEmailAddress(url: $0.url) })
    }

    /// Etkinliğin toplantı kimliği (`CalendarMeeting.id`, bkz. `calendarMeetingID`).
    private static func meetingID(event: EKEvent) -> String {
        calendarMeetingID(eventIdentifier: event.eventIdentifier ?? event.calendarItemIdentifier, start: event.startDate)
    }

    /// Takvimde değişiklik olunca (etkinlik eklendi, taşındı) bildirilir.
    var changes: NotificationCenter.Notifications {
        NotificationCenter.default.notifications(named: .EKEventStoreChanged, object: store)
    }

    /// Görevi varsayılan anımsatıcı listesine ekler (son gün çözülebildiyse tarihli).
    func addReminder(draft: ReminderDraft) async throws {
        let granted: Bool
        do {
            granted = try await store.requestFullAccessToReminders()
        } catch {
            throw EventKitError.saveFailed(reason: error.localizedDescription)
        }
        guard granted else {
            throw EventKitError.remindersAccessDenied
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            throw EventKitError.noReminderList
        }
        let reminder: EKReminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.notes = draft.notes
        reminder.calendar = list
        reminder.dueDateComponents = draft.due
        do {
            try store.save(reminder, commit: true)
        } catch {
            throw EventKitError.saveFailed(reason: error.localizedDescription)
        }
    }
}

/// EventKit hatasının kullanıcı metni. Saf fonksiyondur.
func eventKitMessage(error: any Error) -> String {
    switch error {
    case EventKitError.remindersAccessDenied:
        String(localized: "Anımsatıcılar'a erişim izni yok: Sistem Ayarları › Gizlilik ve Güvenlik › Anımsatıcılar'dan \(appName)'e izin ver.")
    case EventKitError.calendarAccessDenied:
        String(localized: "Takvime erişim izni yok: Sistem Ayarları › Gizlilik ve Güvenlik › Takvimler'den \(appName)'e izin ver.")
    case EventKitError.noReminderList:
        String(localized: "Anımsatıcılar'da liste yok: Anımsatıcılar uygulamasında bir liste oluştur.")
    case EventKitError.saveFailed(let reason):
        String(localized: "Anımsatıcı kaydedilemedi: \(reason)")
    case EventKitError.calendarRequestFailed(let reason):
        String(localized: "Takvim izni istenemedi: \(reason)")
    default:
        userFacingMessage(error: error)
    }
}
