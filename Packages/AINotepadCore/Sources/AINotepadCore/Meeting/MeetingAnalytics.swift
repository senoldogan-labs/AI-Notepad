import Foundation

// İstatistikler (Mac ve iPhone): kullanıcının kendi toplantılarından cihazda hesaplanan sayılar ve grafikler. Hiçbir şey
// sunucuya gitmez; örnek toplantı ve süren kayıt sayılmaz (`analyticsMeetings`). Yalnızca kayıtta gerçekten bulunan veri
// kullanılır: süre başlangıç ve bitişten, görevler nottan, tamamlanma işaretlerden (tamamlanma anı saklanmaz, bu yüzden
// görevler toplantının tarihine göre gösterilir), kişiler konuşmacılara verilen adlardan ve takvim katılımcılarından.

/// İstatistiklerin dönemi.
public enum AnalyticsPeriod: String, Sendable, CaseIterable, Identifiable {
    case week
    case month
    case quarter
    case all

    public var id: String { rawValue }

    /// Dönemin gün sayısı (bugün dahil); tümünde nil.
    public var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all: nil
        }
    }
}

/// Zaman grafiğinin bir çubuğunun kapsadığı süre.
public enum AnalyticsBucketSize: String, Sendable, Equatable {
    case day
    case week
    case month
}

/// Bir dönemin toplamları.
public struct AnalyticsTotals: Sendable, Equatable {
    public let meetings: Int
    /// Bitişi bilinen toplantıların toplam süresi (saniye).
    public let seconds: Double
    /// Bitişi bilinen toplantı sayısı (ortalama bunlardan).
    public let timedMeetings: Int
    /// Notlardaki görevler.
    public let tasksCreated: Int
    /// Bunlardan tamamlanan işaretli olanlar.
    public let tasksCompleted: Int
    /// Notu yazılmış toplantılar.
    public let notes: Int

    public init(meetings: Int, seconds: Double, timedMeetings: Int, tasksCreated: Int, tasksCompleted: Int, notes: Int) {
        self.meetings = meetings
        self.seconds = seconds
        self.timedMeetings = timedMeetings
        self.tasksCreated = tasksCreated
        self.tasksCompleted = tasksCompleted
        self.notes = notes
    }

    /// Ortalama toplantı süresi (saniye); süresi bilinen toplantı yoksa nil.
    public var averageSeconds: Double? {
        timedMeetings > 0 ? seconds / Double(timedMeetings) : nil
    }
}

/// Zaman grafiğinde bir çubuk: başladığı an, toplantı saatleri ve o aralıktaki toplantıların görevleri.
public struct AnalyticsTimePoint: Sendable, Equatable, Identifiable {
    public let start: Date
    public let hours: Double
    public let meetings: Int
    /// Bu aralıktaki toplantıların görevlerinden hâlâ açık olanlar.
    public let openTasks: Int
    /// Bu aralıktaki toplantıların görevlerinden tamamlananlar.
    public let completedTasks: Int

    public init(start: Date, hours: Double, meetings: Int, openTasks: Int, completedTasks: Int) {
        self.start = start
        self.hours = hours
        self.meetings = meetings
        self.openTasks = openTasks
        self.completedTasks = completedTasks
    }

    public var id: Date { start }
}

/// Isı haritasında bir hücre: haftanın günü (`Calendar` numarası, 1 = Pazar), saat (0–23) ve o saatte başlayan
/// toplantılar.
public struct AnalyticsHeatCell: Sendable, Equatable, Identifiable {
    public let weekday: Int
    public let hour: Int
    public let meetings: Int

    public init(weekday: Int, hour: Int, meetings: Int) {
        self.weekday = weekday
        self.hour = hour
        self.meetings = meetings
    }

    public var id: String { "\(weekday)-\(hour)" }
}

/// Adıyla sayılan bir şey (kişi, klasör) ve kaç toplantıda geçtiği.
public struct AnalyticsRankedName: Sendable, Equatable, Identifiable {
    public let name: String
    public let meetings: Int

    public init(name: String, meetings: Int) {
        self.name = name
        self.meetings = meetings
    }

    public var id: String { name.lowercased() }
}

/// Bir not şablonu türü ve kaç toplantıda kullanıldığı.
public struct AnalyticsTemplateCount: Sendable, Equatable, Identifiable {
    public let kind: NoteTemplateKind
    public let meetings: Int

    public init(kind: NoteTemplateKind, meetings: Int) {
        self.kind = kind
        self.meetings = meetings
    }

    public var id: String { kind.rawValue }
}

/// İstatistikler sayfasının bütün verisi.
public struct MeetingAnalytics: Sendable, Equatable {
    public let period: AnalyticsPeriod
    /// Sayılan toplantıların hepsi (dönemden bağımsız); sıfırsa sayfa ilk açılış hâlini gösterir.
    public let allTimeMeetings: Int
    public let totals: AnalyticsTotals
    /// Bir önceki aynı uzunluktaki dönem; "tümü"nde nil.
    public let previous: AnalyticsTotals?
    public let bucketSize: AnalyticsBucketSize
    /// Dönemin baştan sona çubukları (toplantısız aralıklar sıfırla).
    public let timeline: [AnalyticsTimePoint]
    /// Gün sırası (takvimin hafta başından); ısı haritasının satırları.
    public let weekdays: [Int]
    /// Toplantıların başladığı ilk ve son saat arasındaki bütün hücreler; toplantı yoksa boş.
    public let heatmap: [AnalyticsHeatCell]
    /// En çok kullanılan klasörler (en fazla `analyticsRankLimit`).
    public let folders: [AnalyticsRankedName]
    /// Şablon türleri; hepsi genel şablonsa boş (anlamlı bir dağılım yok).
    public let templates: [AnalyticsTemplateCount]
    /// En çok birlikte toplantı yapılan kişiler (en fazla `analyticsRankLimit`).
    public let people: [AnalyticsRankedName]

    public init(
        period: AnalyticsPeriod, allTimeMeetings: Int, totals: AnalyticsTotals, previous: AnalyticsTotals?, bucketSize: AnalyticsBucketSize,
        timeline: [AnalyticsTimePoint], weekdays: [Int], heatmap: [AnalyticsHeatCell], folders: [AnalyticsRankedName],
        templates: [AnalyticsTemplateCount], people: [AnalyticsRankedName]
    ) {
        self.period = period
        self.allTimeMeetings = allTimeMeetings
        self.totals = totals
        self.previous = previous
        self.bucketSize = bucketSize
        self.timeline = timeline
        self.weekdays = weekdays
        self.heatmap = heatmap
        self.folders = folders
        self.templates = templates
        self.people = people
    }
}

/// Sıralı listelerin en fazla uzunluğu.
public let analyticsRankLimit: Int = 6

/// Sayılan toplantılar: örnek toplantı (`realMeetings`) ve süren kayıt hariç. Saf fonksiyondur.
public func analyticsMeetings(records: [MeetingRecord]) -> [MeetingRecord] {
    realMeetings(records: records).filter { $0.status != .recording }
}

/// Toplantının süresi (saniye); bitişi bilinmiyorsa nil, saat geri gittiyse 0. Saf fonksiyondur.
public func meetingDurationSeconds(record: MeetingRecord) -> Double? {
    record.endedAt.map { max(0, $0.timeIntervalSince(record.startedAt)) }
}

/// İki dönem arasındaki değişim oranı (0,25 = %25 artış); önceki dönem sıfırsa nil (oran tanımsız). Saf fonksiyondur.
public func analyticsChange(current: Double, previous: Double) -> Double? {
    previous > 0 ? (current - previous) / previous : nil
}

/// Toplantıların toplamları. Saf fonksiyondur.
public func analyticsTotals(meetings: [MeetingRecord]) -> AnalyticsTotals {
    let durations: [Double] = meetings.compactMap(meetingDurationSeconds(record:))
    let tasks: [(record: MeetingRecord, task: NoteTask)] = meetings.flatMap { (record: MeetingRecord) -> [(record: MeetingRecord, task: NoteTask)] in
        (record.note?.tasks ?? []).map { (record: record, task: $0) }
    }
    return AnalyticsTotals(
        meetings: meetings.count, seconds: durations.reduce(0, +), timedMeetings: durations.count, tasksCreated: tasks.count,
        tasksCompleted: tasks.filter { isTaskDone(record: $0.record, task: $0.task) }.count,
        notes: meetings.filter { $0.note != nil }.count
    )
}

/// Dönemin başı: bugün dahil `days` gün öncesinin gün başı; tümünde en eski toplantının gün başı (toplantı yoksa bugün).
/// Saf fonksiyondur.
public func analyticsPeriodStart(period: AnalyticsPeriod, meetings: [MeetingRecord], now: Date, calendar: Calendar) -> Date {
    let today: Date = calendar.startOfDay(for: now)
    guard let days = period.days else {
        return calendar.startOfDay(for: meetings.map(\.startedAt).min() ?? now)
    }
    return calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
}

/// Çubuk büyüklüğü: 7 ve 30 günde gün, 90 günde hafta; tümünde yarım yıla kadar hafta, sonra ay. Saf fonksiyondur.
public func analyticsBucketSize(period: AnalyticsPeriod, start: Date, now: Date) -> AnalyticsBucketSize {
    switch period {
    case .week, .month: return .day
    case .quarter: return .week
    case .all: return now.timeIntervalSince(start) <= 183 * 86_400 ? .week : .month
    }
}

/// Tarihin içinde bulunduğu çubuğun başı. Saf fonksiyondur.
public func analyticsBucketStart(date: Date, size: AnalyticsBucketSize, calendar: Calendar) -> Date {
    let component: Calendar.Component = switch size {
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    }
    return calendar.dateInterval(of: component, for: date)?.start ?? calendar.startOfDay(for: date)
}

/// Dönemin çubukları, baştan bugüne; toplantısız aralıklar sıfırla (grafik boşluğu doğru gösterir). Saf fonksiyondur.
public func analyticsTimeline(meetings: [MeetingRecord], start: Date, now: Date, size: AnalyticsBucketSize, calendar: Calendar) -> [AnalyticsTimePoint] {
    let component: Calendar.Component = switch size {
    case .day: .day
    case .week: .weekOfYear
    case .month: .month
    }
    let first: Date = analyticsBucketStart(date: start, size: size, calendar: calendar)
    let starts: [Date] = Array(sequence(first: first) { (previous: Date) -> Date? in
        guard let next = calendar.date(byAdding: component, value: 1, to: previous), next <= now else {
            return nil
        }
        return next
    })
    let grouped: [Date: [MeetingRecord]] = Dictionary(grouping: meetings) { analyticsBucketStart(date: $0.startedAt, size: size, calendar: calendar) }
    return starts.map { (bucket: Date) -> AnalyticsTimePoint in
        let inBucket: [MeetingRecord] = grouped[bucket] ?? []
        let totals: AnalyticsTotals = analyticsTotals(meetings: inBucket)
        return AnalyticsTimePoint(
            start: bucket, hours: totals.seconds / 3600, meetings: totals.meetings, openTasks: totals.tasksCreated - totals.tasksCompleted,
            completedTasks: totals.tasksCompleted
        )
    }
}

/// Haftanın günleri, takvimin hafta başından (ör. Pazartesi = 2 önce). Saf fonksiyondur.
public func analyticsWeekdays(calendar: Calendar) -> [Int] {
    (0..<7).map { ((calendar.firstWeekday - 1 + $0) % 7) + 1 }
}

/// Gün × saat ısı haritası: toplantıların başladığı ilk ve son saat arasındaki bütün hücreler (toplantısızlar sıfırla);
/// toplantı yoksa boş. Saf fonksiyondur.
public func analyticsHeatmap(meetings: [MeetingRecord], calendar: Calendar) -> [AnalyticsHeatCell] {
    let slots: [(weekday: Int, hour: Int)] = meetings.map { (record: MeetingRecord) -> (weekday: Int, hour: Int) in
        (weekday: calendar.component(.weekday, from: record.startedAt), hour: calendar.component(.hour, from: record.startedAt))
    }
    guard let firstHour = slots.map(\.hour).min(), let lastHour = slots.map(\.hour).max() else {
        return []
    }
    return analyticsWeekdays(calendar: calendar).flatMap { (weekday: Int) -> [AnalyticsHeatCell] in
        (firstHour...lastHour).map { (hour: Int) -> AnalyticsHeatCell in
            AnalyticsHeatCell(weekday: weekday, hour: hour, meetings: slots.filter { $0.weekday == weekday && $0.hour == hour }.count)
        }
    }
}

/// Adları (büyük/küçük harf duyarsız tek ad) toplantı sayısına göre sıralar: bir toplantıda bir kez sayılır, görünen ad
/// en yeni toplantıdaki yazılış; eşitlikte ada göre. En fazla `analyticsRankLimit`. Saf fonksiyondur.
func rankedNames(entries: [(name: String, meetingID: String, date: Date)]) -> [AnalyticsRankedName] {
    let cleaned: [(name: String, meetingID: String, date: Date)] = entries.compactMap { (entry: (name: String, meetingID: String, date: Date)) -> (name: String, meetingID: String, date: Date)? in
        let name: String = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : (name: name, meetingID: entry.meetingID, date: entry.date)
    }
    return Dictionary(grouping: cleaned) { $0.name.lowercased() }.values
        .compactMap { (group: [(name: String, meetingID: String, date: Date)]) -> AnalyticsRankedName? in
            let latest: (name: String, meetingID: String, date: Date)? = group.min { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
            return latest.map { AnalyticsRankedName(name: $0.name, meetings: Set(group.map(\.meetingID)).count) }
        }
        .sorted { $0.meetings != $1.meetings ? $0.meetings > $1.meetings : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .prefix(analyticsRankLimit)
        .map { $0 }
}

/// En çok birlikte toplantı yapılan kişiler: takvim katılımcıları ve konuşmacılara verilen adlar; kullanıcının kendisi
/// (`isUserName`) hariç. Konuşmacı adı aynı toplantıdaki bir katılımcının adı ya da ilk adıysa ("Elif" ve "Elif Kaya")
/// o katılımcı sayılır. Saf fonksiyondur.
public func analyticsPeople(meetings: [MeetingRecord], userName: String) -> [AnalyticsRankedName] {
    rankedNames(entries: meetings.flatMap { (record: MeetingRecord) -> [(name: String, meetingID: String, date: Date)] in
        let attendees: [String] = record.attendees ?? []
        let speakers: [String] = record.speakerNames.values.filter { (speaker: String) -> Bool in
            !attendees.contains { (attendee: String) -> Bool in isUserName(name: speaker, userName: attendee) }
        }
        return (attendees + speakers)
            .filter { !isUserName(name: $0, userName: userName) }
            .map { (name: $0, meetingID: record.id, date: record.startedAt) }
    })
}

/// En çok kullanılan klasörler. Saf fonksiyondur.
public func analyticsFolders(meetings: [MeetingRecord]) -> [AnalyticsRankedName] {
    rankedNames(entries: meetings.compactMap { (record: MeetingRecord) -> (name: String, meetingID: String, date: Date)? in
        record.folder.map { (name: $0, meetingID: record.id, date: record.startedAt) }
    })
}

/// Not şablonu türlerinin dağılımı (şablonsuz eski toplantılar genel sayılır), çoktan aza; hepsi genelse boş. Saf
/// fonksiyondur.
public func analyticsTemplates(meetings: [MeetingRecord]) -> [AnalyticsTemplateCount] {
    let kinds: [NoteTemplateKind] = meetings.map { $0.template?.kind ?? .general }
    guard kinds.contains(where: { $0 != .general }) else {
        return []
    }
    return NoteTemplateKind.allCases
        .map { (kind: NoteTemplateKind) -> AnalyticsTemplateCount in AnalyticsTemplateCount(kind: kind, meetings: kinds.filter { $0 == kind }.count) }
        .filter { $0.meetings > 0 }
        .sorted { $0.meetings > $1.meetings }
}

/// İstatistikler sayfasının verisi: dönemdeki toplantılar (`analyticsMeetings`, başlangıcı dönemin başından şimdiye),
/// bir önceki aynı uzunluktaki dönemin toplamları, çubuklar, ısı haritası ve sıralı listeler. Saf fonksiyondur.
public func meetingAnalytics(records: [MeetingRecord], period: AnalyticsPeriod, userName: String, now: Date, calendar: Calendar) -> MeetingAnalytics {
    let counted: [MeetingRecord] = analyticsMeetings(records: records)
    let start: Date = analyticsPeriodStart(period: period, meetings: counted, now: now, calendar: calendar)
    let inPeriod: [MeetingRecord] = counted.filter { $0.startedAt >= start && $0.startedAt <= now }
    let previous: AnalyticsTotals? = period.days.map { (days: Int) -> AnalyticsTotals in
        let previousStart: Date = calendar.date(byAdding: .day, value: -days, to: start) ?? start
        return analyticsTotals(meetings: counted.filter { $0.startedAt >= previousStart && $0.startedAt < start })
    }
    let size: AnalyticsBucketSize = analyticsBucketSize(period: period, start: start, now: now)
    return MeetingAnalytics(
        period: period, allTimeMeetings: counted.count, totals: analyticsTotals(meetings: inPeriod), previous: previous, bucketSize: size,
        timeline: analyticsTimeline(meetings: inPeriod, start: start, now: now, size: size, calendar: calendar),
        weekdays: analyticsWeekdays(calendar: calendar), heatmap: analyticsHeatmap(meetings: inPeriod, calendar: calendar),
        folders: analyticsFolders(meetings: inPeriod), templates: analyticsTemplates(meetings: inPeriod),
        people: analyticsPeople(meetings: inPeriod, userName: userName)
    )
}
