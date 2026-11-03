import AINotepadCore
import EventKit
import Foundation
import os

/// iPhone'da takvimin durumu.
enum PhoneCalendarState: Equatable {
    /// Ayar kapalı (varsayılan).
    case off
    case on
    /// Takvim izni yok ya da geri alındı: iPhone Ayarları'ndan verilmeli.
    case denied
    /// İzin istenemedi ya da takvim okunamadı; neden gösterilir.
    case failed(String)
}

/// iPhone takvimi (EventKit, Mac'teki bağlantıyla aynı): sıradaki toplantılar, kayda bağlanacak süren toplantı ve
/// (açıksa) toplantıdan 1 dk önce "Dinlemeye başla" hatırlatması. İzinler yalnızca kullanıcı Ayarlar'da açınca istenir.
@MainActor
@Observable
final class PhoneCalendar {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneCalendar")

    /// Bugünün başından (bugün biten ve süren toplantılar dahil) şu andan 12 saat sonrasına kadarki etkinlikler.
    private(set) var meetings: [CalendarMeeting] = []
    private(set) var state: PhoneCalendarState = .off
    @ObservationIgnored private let eventKit: EventKitConnector = EventKitConnector()
    /// Takvim değişikliklerini izleyen görev (etkinlik eklendi, taşındı).
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    /// Hatırlatma bildirimleri (Mac'teki `MeetingNotifier`).
    @ObservationIgnored private let notifier: MeetingNotifier = MeetingNotifier()
    /// Hatırlatmaları yeniden kuran görev (takvim her okunduğunda yenilenir).
    @ObservationIgnored private var remindersTask: Task<Void, Never>?
    /// Bildirim izni yok ya da hatırlatma kurulamadı: neden Ayarlar'daki hatırlatma satırında görünür.
    private(set) var reminderProblem: String?

    /// Ayar açıksa takvimi okur ve değişiklikleri izler; izin sonradan geri alındıysa "izin yok" durumu. İzin sorulmaz.
    /// Açılışta ve uygulama öne gelince çağrılır.
    func start() {
        #if DEBUG
        if isShowingSample {
            return
        }
        #endif
        guard UserDefaults.standard.bool(forKey: PhoneSettingsKey.calendarEnabled) else {
            stopObserving()
            meetings = []
            state = .off
            scheduleReminders()
            return
        }
        guard eventKit.hasCalendarAccess else {
            stopObserving()
            meetings = []
            state = .denied
            scheduleReminders()
            return
        }
        refresh()
        observeChanges()
    }

    /// Kullanıcı takvimi açtı: izin istenir (ilk kez iOS sorar). Verilmezse ayar kapalı kalır ve neden görünür.
    func enable() async {
        do {
            try await eventKit.requestCalendarAccess()
            UserDefaults.standard.set(true, forKey: PhoneSettingsKey.calendarEnabled)
            start()
        } catch EventKitError.calendarAccessDenied {
            UserDefaults.standard.set(false, forKey: PhoneSettingsKey.calendarEnabled)
            meetings = []
            state = .denied
        } catch {
            Self.logger.error("Takvim izni istenemedi, hata: \(String(describing: error), privacy: .private)")
            UserDefaults.standard.set(false, forKey: PhoneSettingsKey.calendarEnabled)
            meetings = []
            state = .failed(eventKitMessage(error: error))
        }
    }

    /// Kullanıcı takvimi kapattı: kurulu hatırlatmalar da kalkar.
    func disable() {
        UserDefaults.standard.set(false, forKey: PhoneSettingsKey.calendarEnabled)
        stopObserving()
        meetings = []
        state = .off
        scheduleReminders()
    }

    /// Kullanıcı hatırlatmaları açtı: bildirim izni istenir (ilk kez iOS sorar). Verilmezse ayar kapalı kalır ve neden
    /// görünür.
    func enableReminders() async {
        do {
            try await notifier.requestAuthorization()
            UserDefaults.standard.set(true, forKey: PhoneSettingsKey.meetingReminders)
            reminderProblem = nil
        } catch {
            Self.logger.warning("Bildirim izni alınamadı, hatırlatmalar kapalı, hata: \(String(describing: error), privacy: .private)")
            UserDefaults.standard.set(false, forKey: PhoneSettingsKey.meetingReminders)
            reminderProblem = notificationMessage(error: error)
        }
        scheduleReminders()
    }

    /// Kullanıcı hatırlatmaları kapattı: kurulu olanlar kalkar.
    func disableReminders() {
        UserDefaults.standard.set(false, forKey: PhoneSettingsKey.meetingReminders)
        reminderProblem = nil
        scheduleReminders()
    }

    /// Kayda bağlanacak toplantı: takvim açıksa şu an süren (10 dk erken başlama payıyla) etkinlik; yoksa nil. Takvim
    /// önce yeniden okunur (uygulama saatlerce açık kalmış olabilir).
    func meetingForRecording(now: Date) -> CalendarMeeting? {
        guard state == .on else {
            return nil
        }
        refresh()
        return currentMeeting(meetings: meetings, now: now)
    }

    /// Takvimi yeniden okur; okunamazsa neden durumda görünür.
    private func refresh() {
        do {
            // Mac'teki gibi günün başından: Kayıt'ta "Bugün biten toplantılar" da görünsün.
            let now: Date = Date()
            let dayStart: Date = Calendar.current.startOfDay(for: now)
            meetings = try eventKit.meetings(from: dayStart, hours: now.timeIntervalSince(dayStart) / 3600 + 12)
            state = .on
            scheduleReminders()
        } catch EventKitError.calendarAccessDenied {
            meetings = []
            state = .denied
        } catch {
            Self.logger.error("Takvim okunamadı, hata: \(String(describing: error), privacy: .private)")
            meetings = []
            state = .failed(eventKitMessage(error: error))
        }
    }

    /// Hatırlatmalar açıksa 3 saat içinde başlayacak toplantılar için başlangıçtan 1 dk önceye bildirim kurar (öncekiler
    /// kalkar); kapalıysa ya da takvim kapalıysa kurulu olanları kaldırır. Bildirim izni sonradan geri alındıysa neden
    /// `reminderProblem`'da. Bildirimler uygulama takvimi okuduğunda (açılış, öne gelme, takvim değişikliği) yenilenir.
    private func scheduleReminders() {
        remindersTask?.cancel()
        let isEnabled: Bool = state == .on && UserDefaults.standard.bool(forKey: PhoneSettingsKey.meetingReminders)
        let remind: [CalendarMeeting] = meetingsToRemind(meetings: meetings, now: Date().addingTimeInterval(60), horizonSec: 3 * 3600)
        remindersTask = Task { [weak self, notifier] in
            guard isEnabled else {
                await notifier.removeReminders()
                return
            }
            do {
                try await notifier.scheduleReminders(meetings: remind)
                self?.reminderProblem = nil
            } catch {
                Self.logger.error("Toplantı hatırlatmaları kurulamadı, hata: \(String(describing: error), privacy: .private)")
                self?.reminderProblem = notificationMessage(error: error)
            }
        }
    }

    #if DEBUG
    /// Örnek takvim gösteriliyor: öne gelince gerçek takvim okunmaz.
    @ObservationIgnored private var isShowingSample: Bool = false

    /// `--ornek-takvim` (yalnız Debug, görsel kontrol): izin ve takvim olmadan örnek sıradaki toplantılar gösterilir.
    func showSampleMeetings(now: Date) {
        isShowingSample = true
        meetings = [
            CalendarMeeting(
                id: "ornek-1", title: "Viikkopalaveri", start: now.addingTimeInterval(8 * 60),
                end: now.addingTimeInterval(38 * 60), attendees: ["Aino", "Mikko", "Liisa"], joinURL: URL(string: "https://teams.microsoft.com/l/meetup-join/ornek")
            ),
            CalendarMeeting(
                id: "ornek-2", title: "Asiakasesitys", start: now.addingTimeInterval(3 * 3600),
                end: now.addingTimeInterval(4 * 3600), attendees: ["Kela", "Aino"], joinURL: nil
            ),
            // Bugün biten (kaydı yok): "Bugün biten toplantılar" bölümü.
            CalendarMeeting(
                id: "ornek-3", title: "Aamupalaveri", start: now.addingTimeInterval(-90 * 60),
                end: now.addingTimeInterval(-60 * 60), attendees: ["Mikko"], joinURL: nil
            ),
        ]
        state = .on
    }
    #endif

    private func observeChanges() {
        guard changesTask == nil else {
            return
        }
        let changes: NotificationCenter.Notifications = eventKit.changes
        changesTask = Task { [weak self] in
            for await _ in changes {
                self?.refresh()
            }
        }
    }

    private func stopObserving() {
        changesTask?.cancel()
        changesTask = nil
    }
}
