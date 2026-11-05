import Foundation

/// Kullanıcıyı uygulamaya ve görevlerine geri getiren yerel bildirimler (sunucu push'u yok): not hazır, görev günü,
/// haftalık özet ve kayıtsız geçen hafta. Dördü de Ayarlar › Bildirimler'den ayrı ayrı kapatılır.
public enum EngagementKind: String, Sendable, CaseIterable {
    case noteReady
    case taskDue
    case weeklySummary
    case inactive
}

/// Bildirim ayarlarının UserDefaults anahtarları (Bool, varsayılan açık); Mac'te ve iPhone'da aynı adlar (cihazlar
/// arasında eşitlenebilsin).
public enum EngagementSettingKey {
    public static let noteReady: String = "notify.noteReady"
    public static let taskDue: String = "notify.taskDue"
    public static let weeklySummary: String = "notify.weeklySummary"
    public static let inactive: String = "notify.inactive"

    /// Türün ayar anahtarı. Saf fonksiyondur.
    public static func key(kind: EngagementKind) -> String {
        switch kind {
        case .noteReady: noteReady
        case .taskDue: taskDue
        case .weeklySummary: weeklySummary
        case .inactive: inactive
        }
    }
}

/// Bildirim kimlikleri, kategorileri, eylemleri ve `userInfo` anahtarları. Kimlikler kararlıdır: aynı bildirim yeniden
/// kurulunca öncekinin yerine geçer.
public enum EngagementNotificationID {
    /// Bu bildirimlerin hepsinin kimlik öneki (çıkışta hepsi kaldırılır).
    public static let prefix: String = "engage."
    public static let noteReadyPrefix: String = "engage.noteReady."
    public static let taskDuePrefix: String = "engage.taskDue."
    public static let weeklySummary: String = "engage.weekly"
    public static let inactive: String = "engage.inactive"
    public static let noteReadyCategory: String = "engage.noteReady"
    public static let taskDueCategory: String = "engage.taskDue"
    public static let weeklySummaryCategory: String = "engage.weekly"
    public static let inactiveCategory: String = "engage.inactive"
    /// Görev bildirimindeki "Tamamlandı" eylemi.
    public static let taskDoneAction: String = "engage.taskDue.done"
    public static let meetingIDKey: String = "meetingID"
    public static let taskKeyKey: String = "taskKey"

    /// Bekleyen bildirim bu türden mi (kimliğine göre). Saf fonksiyondur.
    public static func matches(identifier: String, kind: EngagementKind) -> Bool {
        switch kind {
        case .noteReady: identifier.hasPrefix(noteReadyPrefix)
        case .taskDue: identifier.hasPrefix(taskDuePrefix)
        case .weeklySummary: identifier == weeklySummary
        case .inactive: identifier == inactive
        }
    }
}

/// Hangi bildirimlerin açık olduğu (Ayarlar › Bildirimler).
public struct EngagementSettings: Sendable, Equatable {
    public let noteReady: Bool
    public let taskDue: Bool
    public let weeklySummary: Bool
    public let inactive: Bool

    public init(noteReady: Bool, taskDue: Bool, weeklySummary: Bool, inactive: Bool) {
        self.noteReady = noteReady
        self.taskDue = taskDue
        self.weeklySummary = weeklySummary
        self.inactive = inactive
    }

    /// Tür açık mı. Saf fonksiyondur.
    public func isEnabled(kind: EngagementKind) -> Bool {
        switch kind {
        case .noteReady: noteReady
        case .taskDue: taskDue
        case .weeklySummary: weeklySummary
        case .inactive: inactive
        }
    }
}

/// Kurulacak bir bildirimin içeriği ve zamanı. Metinler kilit ekranında görünebilir: yalnız başlıklar, sayılar ve
/// görev metni yazar (konuşma metni ya da özet yazmaz).
public struct EngagementNotification: Sendable, Equatable {
    public let identifier: String
    public let categoryIdentifier: String
    public let title: String
    public let subtitle: String
    public let body: String
    /// Gösterileceği yerel takvim anı (yıl, ay, gün, saat, dakika); nil hemen gösterilir.
    public let fireAt: DateComponents?
    /// Dokununca açılacak toplantı.
    public let meetingID: String?
    /// "Tamamlandı" eyleminin işaretleyeceği görev (`taskKey`).
    public let taskKey: String?
}

/// Haftalık özette listelenen en çok açık görev sayısı.
public let weeklySummaryTaskLimit: Int = 3

/// Bir uygulamanın bekleyen bildirim sınırı (iOS en yakın 64 taneyi tutar, gerisini atar).
public let pendingNotificationLimit: Int = 64

/// Sonradan kurulabilecek toplantı hatırlatmaları (3 saatlik pencere) ve süre sınırı bildirimleri için ayrılan pay.
public let pendingNotificationReserve: Int = 12

/// Görev günü bildirimleri için kalan yer: sınırdan başka bekleyen bildirimler (`otherPendingCount`, bu bildirimlerin
/// dışındakiler), haftalık özet, kayıtsız hafta ve ayrılan pay düşülür. Saf fonksiyondur.
public func taskDueBudget(otherPendingCount: Int) -> Int {
    max(0, pendingNotificationLimit - pendingNotificationReserve - otherPendingCount - 2)
}

/// Toplantının gösterilen adı: notun başlığı, yoksa kaydın adı. Saf fonksiyondur.
private func shownTitle(record: MeetingRecord) -> String {
    record.note?.title ?? record.title
}

/// Tarihin yerel takvimdeki anı (bildirim tetiklemesi için yıl…dakika). Saf fonksiyondur.
private func fireComponents(date: Date, calendar: Calendar) -> DateComponents {
    calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
}

/// "Not hazır" bildirimi: toplantının başlığı ve kullanıcıya düşen görev ile karar sayısı ("Sana 3 görev · 2 karar");
/// ikisi de yoksa kısa bir cümle. Not yazılamadıysa (işleme başarısız ya da not yok) ya da örnek toplantıysa nil. Görevler konuşmacı adlarıyla
/// (`namedTasks`) sayılır: adı verilen kullanıcıya düşenler de kullanıcınındır. Saf fonksiyondur.
public func noteReadyNotification(record: MeetingRecord, userName: String) -> EngagementNotification? {
    guard record.status == .done, !record.isSampleMeeting, let note = record.note else {
        return nil
    }
    let mine: Int = namedTasks(record: record, userName: userName).filter(\.isMine).count
    let decisions: Int = note.decisions.count
    let parts: [String] = (mine > 0 ? [String(localized: "Sana \(mine) görev")] : [])
        + (decisions > 0 ? [String(localized: "\(decisions) karar")] : [])
    return EngagementNotification(
        identifier: EngagementNotificationID.noteReadyPrefix + record.id,
        categoryIdentifier: EngagementNotificationID.noteReadyCategory,
        title: String(localized: "\(shownTitle(record: record)) notu hazır"),
        subtitle: "",
        body: parts.isEmpty ? String(localized: "Özet ve görevler hazır.") : parts.joined(separator: " · "),
        fireAt: nil,
        meetingID: record.id,
        taskKey: nil
    )
}

/// Kullanıcının açık (tamamlanmamış) görevleri, toplantıların verilen sırasında, konuşmacı adlarıyla. Saf fonksiyondur.
private func openTasks(records: [MeetingRecord], userName: String) -> [(record: MeetingRecord, task: NoteTask)] {
    myTasks(meetings: records, userName: userName).filter { !isTaskDone(record: $0.record, task: $0.task) }
}

/// Görev günü bildirimleri: kullanıcının açık görevlerinden son günü bir takvim gününe çözülenler (bkz. `parseDueDate`,
/// notun dilinde) için o gün 09:00'da "Bugün: <görev>" (alt başlık toplantı). Saati geçmiş günler atlanır; en yakın
/// `limit` tanesi döner (yakından uzağa). Kimlik toplantı ve görev kimliğinden: yeniden kurmak aynı bildirimi
/// değiştirir. Saf fonksiyondur.
public func taskDueNotifications(records: [MeetingRecord], userName: String, now: Date, calendar: Calendar, limit: Int) -> [EngagementNotification] {
    let dated: [(fire: Date, order: Int, notification: EngagementNotification)] = openTasks(records: records, userName: userName)
        .enumerated()
        .compactMap { (item: (offset: Int, element: (record: MeetingRecord, task: NoteTask))) -> (fire: Date, order: Int, notification: EngagementNotification)? in
            let record: MeetingRecord = item.element.record
            let task: NoteTask = item.element.task
            guard let text = task.dueDate, let language = record.note?.writtenLanguage,
                  let day = parseDueDate(text: text, meetingDate: record.startedAt, calendar: calendar, language: language),
                  let fire = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 9, minute: 0)),
                  fire > now else {
                return nil
            }
            let key: String = taskKey(task: task)
            let notification: EngagementNotification = EngagementNotification(
                identifier: EngagementNotificationID.taskDuePrefix + record.id + "." + key,
                categoryIdentifier: EngagementNotificationID.taskDueCategory,
                title: String(localized: "Bugün: \(task.description)"),
                subtitle: shownTitle(record: record),
                body: "",
                fireAt: fireComponents(date: fire, calendar: calendar),
                meetingID: record.id,
                taskKey: key
            )
            return (fire: fire, order: item.offset, notification: notification)
        }
    return dated
        .sorted { $0.fire == $1.fire ? $0.order < $1.order : $0.fire < $1.fire }
        .prefix(max(0, limit))
        .map(\.notification)
}

/// Haftalık özet: bir sonraki pazartesi 09:00'da "Bu hafta: <n> açık görev"; gövdede en çok 3 açık görev ve önceki 7
/// günün toplantı sayısı. Açık görev ve son haftada toplantı yoksa nil. Tek bekleyen bildirimdir (kararlı kimlik); veri
/// değişince yeniden kurulur ki içerik güncel kalsın. Saf fonksiyondur.
public func weeklySummaryNotification(records: [MeetingRecord], userName: String, now: Date, calendar: Calendar) -> EngagementNotification? {
    guard let fire = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime),
          let weekStart = calendar.date(byAdding: .day, value: -7, to: fire) else {
        return nil
    }
    let open: [(record: MeetingRecord, task: NoteTask)] = openTasks(records: records, userName: userName)
    let lastWeek: Int = records.filter { $0.startedAt >= weekStart && $0.startedAt < fire }.count
    guard !open.isEmpty || lastWeek > 0 else {
        return nil
    }
    let meetingCount: String = String(localized: "\(lastWeek) toplantı")
    let lines: [String] = open.prefix(weeklySummaryTaskLimit).map { "• \($0.task.description)" }
        + (lastWeek > 0 ? [String(localized: "Geçen hafta: \(meetingCount)")] : [])
    return EngagementNotification(
        identifier: EngagementNotificationID.weeklySummary,
        categoryIdentifier: EngagementNotificationID.weeklySummaryCategory,
        title: open.isEmpty ? String(localized: "Haftalık özet") : String(localized: "Bu hafta: \(open.count) açık görev"),
        subtitle: "",
        body: lines.joined(separator: "\n"),
        fireAt: fireComponents(date: fire, calendar: calendar),
        meetingID: nil,
        taskKey: nil
    )
}

/// Kayıtsız geçen haftanın hatırlatma anı: son kaydın gününden 7 gün sonra 10:00. Hiç kayıt yoksa nil. Saf
/// fonksiyondur.
public func inactiveReminderDate(records: [MeetingRecord], calendar: Calendar) -> Date? {
    guard let last = records.map(\.startedAt).max(),
          let day = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: last)) else {
        return nil
    }
    return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day)
}

/// Kayıtsız geçen hafta: son kayıttan 7 gün sonra 10:00'da bir kez "Bir sonraki toplantını kaydetmeyi unutma"; takvim o
/// gün 10:00'dan sonra bir toplantı biliyorsa (`calendarMeetings`) adı ve saati yazar. Anı geçmişse nil: yeni kayıt
/// olana dek bir daha kurulmaz (aynı dönemde tekrar etmez). Saf fonksiyondur.
public func inactiveReminderNotification(
    records: [MeetingRecord], calendarMeetings: [CalendarMeeting], now: Date, calendar: Calendar, locale: Locale
) -> EngagementNotification? {
    guard let fire = inactiveReminderDate(records: records, calendar: calendar), fire > now else {
        return nil
    }
    let next: CalendarMeeting? = calendarMeetings
        .filter { $0.start >= fire && calendar.isDate($0.start, inSameDayAs: fire) }
        .min { $0.start < $1.start }
    let body: String = next.map { (meeting: CalendarMeeting) -> String in
        let time: String = meeting.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        return String(localized: "Bugün \(time): \(meeting.title)")
    } ?? String(localized: "Son kaydının üzerinden bir hafta geçti; toplantı başlarken kayda başlaman yeterli.")
    return EngagementNotification(
        identifier: EngagementNotificationID.inactive,
        categoryIdentifier: EngagementNotificationID.inactiveCategory,
        title: String(localized: "Bir sonraki toplantını kaydetmeyi unutma"),
        subtitle: "",
        body: body,
        fireAt: fireComponents(date: fire, calendar: calendar),
        meetingID: nil,
        taskKey: nil
    )
}

/// Bekleyen bildirimlerin planı için girdi: giriş yapan hesabın toplantıları, kullanıcı adı, açık bildirimler, takvimin
/// kayıtsız hafta hatırlatması gününde bildiği toplantılar ve bu bildirimlerin dışında bekleyenlerin sayısı.
public struct EngagementPlanInput: Sendable {
    public let records: [MeetingRecord]
    public let userName: String
    public let settings: EngagementSettings
    public let calendarMeetings: [CalendarMeeting]
    public let otherPendingCount: Int
    public let now: Date
    public let calendar: Calendar
    public let locale: Locale

    public init(
        records: [MeetingRecord], userName: String, settings: EngagementSettings, calendarMeetings: [CalendarMeeting], otherPendingCount: Int,
        now: Date, calendar: Calendar, locale: Locale
    ) {
        self.records = records
        self.userName = userName
        self.settings = settings
        self.calendarMeetings = calendarMeetings
        self.otherPendingCount = otherPendingCount
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }
}

/// Kurulu olması gereken zamanlı bildirimlerin tamamı (görev günleri, haftalık özet, kayıtsız hafta); kapalı türler
/// boştur. Uygulama bunların dışında bekleyen bu bildirimleri kaldırır, bunları kurar. Saf fonksiyondur.
public func plannedEngagementNotifications(input: EngagementPlanInput) -> [EngagementNotification] {
    // Örnek toplantı (karşılamadaki deneme) ne görev günü, ne haftalık özet, ne de etkinlik sayılır.
    let records: [MeetingRecord] = realMeetings(records: input.records)
    let tasks: [EngagementNotification] = input.settings.taskDue
        ? taskDueNotifications(
            records: records, userName: input.userName, now: input.now, calendar: input.calendar,
            limit: taskDueBudget(otherPendingCount: input.otherPendingCount)
        )
        : []
    let weekly: [EngagementNotification] = input.settings.weeklySummary
        ? weeklySummaryNotification(records: records, userName: input.userName, now: input.now, calendar: input.calendar).map { [$0] } ?? []
        : []
    let inactive: [EngagementNotification] = input.settings.inactive
        ? inactiveReminderNotification(
            records: records, calendarMeetings: input.calendarMeetings, now: input.now, calendar: input.calendar, locale: input.locale
        ).map { [$0] } ?? []
        : []
    return tasks + weekly + inactive
}

/// Bekleyen bildirimlerden kaldırılacak olanlar: bu bildirimlerden (`EngagementNotificationID.prefix`) olup planda
/// olmayanlar (görev tamamlandı, silindi, günü değişti ya da tür kapandı). Saf fonksiyondur.
public func staleEngagementIdentifiers(pending: [String], planned: [EngagementNotification]) -> [String] {
    let keep: Set<String> = Set(planned.map(\.identifier))
    return pending.filter { $0.hasPrefix(EngagementNotificationID.prefix) && !keep.contains($0) }
}

/// Bildirimdeki "Tamamlandı": görev tamamlandı diye işaretlenir; zaten tamamlandıysa kayıt değişmez (iki cihazdan ya
/// da iki kez basılınca geri açılmasın). Saf fonksiyondur.
public func markingTaskDone(record: MeetingRecord, key: String) -> MeetingRecord {
    let done: [String] = record.completedTasks ?? []
    return done.contains(key) ? record : record.with(completedTasks: done + [key])
}

/// Toplantının notunda bu kimlikte görev var mı (not bildirimden sonra yeniden yazılmış olabilir). Saf fonksiyondur.
public func hasTask(record: MeetingRecord, key: String) -> Bool {
    (record.note?.tasks ?? []).contains { taskKey(task: $0) == key }
}

/// Bildirime yanıtın uygulamadaki karşılığı.
public enum EngagementRoute: Sendable, Equatable {
    /// Toplantıyı aç (Mac: ana pencere › Toplantılar; iPhone: Toplantılar sekmesi).
    case openMeeting(String)
    /// Görevleri aç (haftalık özet).
    case openTasks
    /// Kayda başlanan yeri aç (Mac: Ana sayfa; iPhone: Kayıt sekmesi).
    case openRecording
    /// Görevi tamamlandı diye işaretle (uygulama öne gelmez).
    case completeTask(meetingID: String, taskKey: String)
}

/// Bildirim yanıtının yolu: kategori ve eylemden (`actionIdentifier`; "Tamamlandı" dışındaki her eylem bildirime
/// dokunmadır) ve bildirimin toplantı ile görev kimliğinden. Bu bildirimlerden değilse ya da gereken kimlik yoksa nil.
/// Saf fonksiyondur.
public func engagementRoute(categoryIdentifier: String, actionIdentifier: String, meetingID: String?, taskKey: String?) -> EngagementRoute? {
    switch categoryIdentifier {
    case EngagementNotificationID.noteReadyCategory:
        return meetingID.map { EngagementRoute.openMeeting($0) }
    case EngagementNotificationID.taskDueCategory:
        guard let meetingID else {
            return nil
        }
        guard actionIdentifier == EngagementNotificationID.taskDoneAction else {
            return .openMeeting(meetingID)
        }
        return taskKey.map { EngagementRoute.completeTask(meetingID: meetingID, taskKey: $0) }
    case EngagementNotificationID.weeklySummaryCategory:
        return .openTasks
    case EngagementNotificationID.inactiveCategory:
        return .openRecording
    default:
        return nil
    }
}
