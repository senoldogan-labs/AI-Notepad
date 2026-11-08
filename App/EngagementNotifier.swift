import AINotepadCore
import Foundation
import Observation
import os
import UserNotifications

private let engagementLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Engagement")

/// Bildirim izninin Ayarlar'da gösterilen durumu.
enum EngagementAuthorization: Equatable {
    /// Henüz okunmadı.
    case unknown
    /// Sorulmadı: ilk toplantı işlenince ya da bir bildirim açılınca sorulur.
    case notDetermined
    case allowed
    /// Reddedildi ya da sistem ayarlarında kapatıldı: Ayarlar bildirim ayarlarını açan düğmeyi gösterir.
    case denied
}

/// Plan için uygulamanın verdiği giriş yapan hesabın verisi.
struct EngagementSnapshot {
    let records: [MeetingRecord]
    let userName: String
    /// Takvim açık mı: kayıtsız hafta hatırlatması o günün toplantısını takvimden okur.
    let calendarEnabled: Bool
}

/// Bildirimleri kurmak için verinin durumu.
enum EngagementDataState {
    /// Giriş yapan hesabın toplantıları okundu.
    case ready(EngagementSnapshot)
    /// Toplantılar henüz okunmadı (açılış, arka planda açılma) ya da tanıtım modu: bekleyenlere dokunulmaz.
    case notReady
    /// Oturum yok: bu bildirimlerin hepsi kalkar (kilit ekranında başka hesabın başlıkları görünmesin).
    case signedOut
}

/// Ayarlar › Bildirimler'deki dört anahtarın değeri (varsayılan açık; bkz. `EngagementSettingKey`).
func storedEngagementSettings(defaults: UserDefaults) -> EngagementSettings {
    EngagementSettings(
        noteReady: defaults.bool(forKey: EngagementSettingKey.noteReady),
        taskDue: defaults.bool(forKey: EngagementSettingKey.taskDue),
        weeklySummary: defaults.bool(forKey: EngagementSettingKey.weeklySummary),
        inactive: defaults.bool(forKey: EngagementSettingKey.inactive),
        trialReminder: defaults.bool(forKey: EngagementSettingKey.trialReminder)
    )
}

/// Süren ücretsiz deneme (deneme hatırlatması için; abonelik sürümünde, deneme süreyle sınırlı ve toplantı kaldıysa);
/// geliştirici sürümünde ve denemesiz hesapta nil.
@MainActor
func currentEngagementTrial() -> EngagementTrial? {
    #if HOSTED_EDITION
    guard case .signedIn(let entitlements) = HostedAccount.shared.state, case .trial(let left, _) = hostedPlanStatus(entitlements: entitlements),
          left > 0, let endsAt = entitlements.trialEndsAt else {
        return nil
    }
    return EngagementTrial(endsAt: endsAt, meetingsLeft: left)
    #else
    return nil
    #endif
}

/// Bildirim kategorileri: görev gününde "Tamamlandı" (uygulamayı öne getirmeden işaretler). Toplantı bildirimlerinin
/// kategorileriyle birlikte kurulur (bkz. `MeetingNotifier`; kategoriler tek seferde bütünüyle kurulur).
func engagementNotificationCategories() -> Set<UNNotificationCategory> {
    let done: UNNotificationAction = UNNotificationAction(identifier: EngagementNotificationID.taskDoneAction, title: String(localized: "Tamamlandı"), options: [])
    return [
        UNNotificationCategory(identifier: EngagementNotificationID.noteReadyCategory, actions: [], intentIdentifiers: []),
        UNNotificationCategory(identifier: EngagementNotificationID.taskDueCategory, actions: [done], intentIdentifiers: []),
        UNNotificationCategory(identifier: EngagementNotificationID.weeklySummaryCategory, actions: [], intentIdentifiers: []),
        UNNotificationCategory(identifier: EngagementNotificationID.inactiveCategory, actions: [], intentIdentifiers: []),
        UNNotificationCategory(identifier: EngagementNotificationID.trialEndingCategory, actions: [], intentIdentifiers: []),
    ]
}

/// Bildirim yanıtının yolu (bkz. `engagementRoute`); bu bildirimlerden değilse nil.
func engagementRoute(response: UNNotificationResponse) -> EngagementRoute? {
    let content: UNNotificationContent = response.notification.request.content
    return engagementRoute(
        categoryIdentifier: content.categoryIdentifier, actionIdentifier: response.actionIdentifier,
        meetingID: content.userInfo[EngagementNotificationID.meetingIDKey] as? String,
        taskKey: content.userInfo[EngagementNotificationID.taskKeyKey] as? String
    )
}

/// Not hazır, görev günü, haftalık özet ve kayıtsız hafta bildirimleri (yerel; Mac ve iPhone'da aynı). İçerik ve plan
/// çekirdekteki saf fonksiyonlardan gelir (`plannedEngagementNotifications`); burada yalnız bildirim merkezi çağrıları.
/// Veri değişince (toplantılar, görev işaretleri, ad), uygulama öne gelince ve birkaç saatte bir plan yeniden kurulur:
/// planda olmayan bekleyenler kalkar, plandakiler kararlı kimlikleriyle yerine konur.
@MainActor
@Observable
final class EngagementNotifier {
    static let shared: EngagementNotifier = EngagementNotifier()

    private(set) var authorization: EngagementAuthorization = .unknown
    @ObservationIgnored private let center: UNUserNotificationCenter = UNUserNotificationCenter.current()
    @ObservationIgnored private let eventKit: EventKitConnector = EventKitConnector()
    /// Giriş yapan hesabın verisi; uygulama açılışta bağlar (`start`).
    @ObservationIgnored private var dataState: (@MainActor () -> EngagementDataState)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// Son kurulan plan: aynı plan yeniden kurulmaz (kayıt sırasında toplantı sık saklanır).
    @ObservationIgnored private var lastApplied: [EngagementNotification]?

    private init() {}

    /// Veri kaynağını bağlar ve planı kurar; zaman geçtikçe (haftalık özetin yeni pazartesisi) 3 saatte bir yeniler.
    func start(dataState: @escaping @MainActor () -> EngagementDataState) {
        self.dataState = dataState
        scheduleRefresh()
        periodicTask?.cancel()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3 * 3600))
                } catch {
                    return
                }
                self?.scheduleRefresh()
            }
        }
    }

    /// Bildirim iznini okur (uygulama öne gelince: izin sistem ayarlarında değişmiş olabilir).
    func refreshAuthorization() async {
        let status: UNAuthorizationStatus = await center.notificationSettings().authorizationStatus
        authorization = engagementAuthorization(status: status)
    }

    /// İzin hiç sorulmadıysa sorar (ilk toplantı işlenince ya da bir bildirim açılınca; açılışta değil).
    func requestAuthorizationIfUndetermined() async {
        await refreshAuthorization()
        guard authorization == .notDetermined else {
            return
        }
        do {
            let granted: Bool = try await center.requestAuthorization(options: [.alert, .sound])
            engagementLogger.info("Bildirim izni soruldu, verildi: \(granted, privacy: .public)")
        } catch {
            engagementLogger.error("Bildirim izni istenemedi, hata: \(String(describing: error), privacy: .private)")
        }
        await refreshAuthorization()
        scheduleRefresh()
    }

    /// Kullanıcı deneme hatırlatmasını istedi ("Bir gün önce hatırlat"): izin sorulmadıysa sorulur; izin varsa true.
    func requestAuthorizationForReminder() async -> Bool {
        await requestAuthorizationIfUndetermined()
        return authorization == .allowed
    }

    /// Uygulama öne geldi: izin yeniden okunur; notu yazılmış bir toplantı varsa ve izin sorulmadıysa sorulur; plan yenilenir.
    func appBecameActive(records: [MeetingRecord]) async {
        // Örnek toplantının (karşılamadaki deneme) notu izin sormaz: izin karşılamada istenir.
        if realMeetings(records: records).contains(where: { $0.status == .done && $0.note != nil }) {
            await requestAuthorizationIfUndetermined()
        } else {
            await refreshAuthorization()
        }
        scheduleRefresh()
    }

    /// Toplantının işlenmesi bitti: uygulama öndeyse izin (sorulmadıysa) sorulur; arkadaysa ve "Not hazır" açıksa not
    /// hazır bildirimi gösterilir (not yazılamadıysa gösterilmez; bkz. `noteReadyNotification`).
    func meetingProcessed(record: MeetingRecord, userName: String, isAppActive: Bool) async {
        guard !isAppActive else {
            await requestAuthorizationIfUndetermined()
            return
        }
        await refreshAuthorization()
        guard authorization == .allowed, storedEngagementSettings(defaults: .standard).noteReady,
              let notification = noteReadyNotification(record: record, userName: userName) else {
            return
        }
        await add(notification: notification)
    }

    /// Bildirim ayarı değişti: açılınca izin (sorulmadıysa) sorulur, kapanınca o türün bekleyenleri hemen kalkar; plan
    /// yeniden kurulur.
    func settingChanged(kind: EngagementKind, enabled: Bool) async {
        if enabled {
            await requestAuthorizationIfUndetermined()
        } else {
            let pending: [UNNotificationRequest] = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
                EngagementNotificationID.matches(identifier: $0, kind: kind)
            })
        }
        lastApplied = nil
        scheduleRefresh()
    }

    /// Bu bildirimlerin hepsini (bekleyen ve gösterilmiş) kaldırır: çıkış ya da hesap değişimi.
    func removeAll() async {
        refreshTask?.cancel()
        lastApplied = nil
        let pending: [UNNotificationRequest] = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(EngagementNotificationID.prefix) })
        let delivered: [UNNotification] = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(EngagementNotificationID.prefix) })
    }

    /// Planı kısa bir bekleyişten sonra yeniden kurar; art arda gelen istekler birleşir.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await self?.refresh()
        }
    }

    /// Planı kurar: oturum yoksa hepsi kalkar; veri hazır değilse dokunulmaz; izin yoksa kurulmaz.
    private func refresh() async {
        guard let dataState else {
            return
        }
        let snapshot: EngagementSnapshot
        switch dataState() {
        case .notReady:
            return
        case .signedOut:
            await removeAll()
            return
        case .ready(let ready):
            snapshot = ready
        }
        await refreshAuthorization()
        guard authorization == .allowed else {
            return
        }
        let pending: [String] = await center.pendingNotificationRequests().map(\.identifier)
        let now: Date = Date()
        let calendar: Calendar = Calendar.current
        let planned: [EngagementNotification] = plannedEngagementNotifications(input: EngagementPlanInput(
            records: snapshot.records, userName: snapshot.userName, settings: storedEngagementSettings(defaults: .standard),
            calendarMeetings: inactiveDayMeetings(snapshot: snapshot, now: now, calendar: calendar),
            otherPendingCount: pending.filter { !$0.hasPrefix(EngagementNotificationID.prefix) }.count,
            trial: currentEngagementTrial(), now: now, calendar: calendar, locale: interfaceLocale()
        ))
        let stale: [String] = staleEngagementIdentifiers(pending: pending, planned: planned)
        center.removePendingNotificationRequests(withIdentifiers: stale)
        let pendingSet: Set<String> = Set(pending)
        guard planned != lastApplied || !planned.allSatisfy({ pendingSet.contains($0.identifier) }) else {
            return
        }
        for notification in planned {
            await add(notification: notification)
        }
        lastApplied = planned
        engagementLogger.info("Bildirimler kuruldu, sayı: \(planned.count, privacy: .public), kaldırılan: \(stale.count, privacy: .public)")
    }

    /// Kayıtsız hafta hatırlatmasının günündeki takvim toplantıları (takvim açık ve izinliyse); okunamazsa boş (bildirim
    /// toplantı adı olmadan kurulur) ve uyarı loglanır.
    private func inactiveDayMeetings(snapshot: EngagementSnapshot, now: Date, calendar: Calendar) -> [CalendarMeeting] {
        guard snapshot.calendarEnabled, eventKit.hasCalendarAccess,
              let fire = inactiveReminderDate(records: snapshot.records, calendar: calendar), fire > now else {
            return []
        }
        do {
            return try eventKit.meetings(from: calendar.startOfDay(for: fire), hours: 24)
        } catch {
            engagementLogger.warning("Takvim okunamadı, hatırlatma toplantı adı olmadan kurulacak, hata: \(String(describing: error), privacy: .private)")
            return []
        }
    }

    /// Bildirimi kurar (aynı kimlikteki bekleyenin yerine geçer); kurulamazsa hata loglanır.
    private func add(notification: EngagementNotification) async {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.categoryIdentifier = notification.categoryIdentifier
        content.sound = .default
        var info: [String: String] = [:]
        info[EngagementNotificationID.meetingIDKey] = notification.meetingID
        info[EngagementNotificationID.taskKeyKey] = notification.taskKey
        content.userInfo = info
        let trigger: UNCalendarNotificationTrigger? = notification.fireAt.map { UNCalendarNotificationTrigger(dateMatching: $0, repeats: false) }
        do {
            try await center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: trigger))
        } catch {
            engagementLogger.error("Bildirim kurulamadı, kimlik: \(notification.identifier, privacy: .private), hata: \(String(describing: error), privacy: .private)")
        }
    }
}

/// Sistemin izin durumunun Ayarlar'daki karşılığı. Saf fonksiyondur.
func engagementAuthorization(status: UNAuthorizationStatus) -> EngagementAuthorization {
    switch status {
    case .notDetermined: .notDetermined
    case .denied: .denied
    case .authorized, .provisional: .allowed
    #if os(iOS)
    case .ephemeral: .allowed
    #endif
    @unknown default: .denied
    }
}
