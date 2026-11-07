import Foundation

/// Görevin son günü: notta serbest metin olarak yazılan tarih ("Cuma", "yarın", "14 Kasım", elle eklenende
/// "2026-11-14") toplantı gününe göre takvim gününe çevrilir (`parseDueDate`, notun dilinde). Böylece "Bugün" yazılan
/// görev haftalar sonra da toplantı gününü gösterir ve eski notlar da kendiliğinden çözülür. Çözülemeyen ("sonraki
/// dönem") ya da tarihsiz görevde nil. Dönen an o günün başıdır (`calendar`). Saf fonksiyondur.
public func taskDueDay(record: MeetingRecord, task: NoteTask, calendar: Calendar) -> Date? {
    task.dueDate.flatMap { dueDay(text: $0, meetingDate: record.startedAt, language: record.note?.writtenLanguage ?? .turkish, calendar: calendar) }
}

/// Serbest metin tarihin (`text`) toplantı gününe göre çözülmüş günü (bkz. `taskDueDay`). Saf fonksiyondur.
func dueDay(text: String, meetingDate: Date, language: ShareLanguage, calendar: Calendar) -> Date? {
    guard let components = parseDueDate(text: text, meetingDate: meetingDate, calendar: calendar, language: language),
          let date = calendar.date(from: components) else {
        return nil
    }
    return calendar.startOfDay(for: date)
}

/// Kişinin görevinin tarih etiketi (bkz. `taskDueLabel`). Saf fonksiyondur.
public func personTaskDueLabel(task: PersonTask, now: Date, calendar: Calendar, locale: Locale) -> TaskDueLabel? {
    guard let text = task.task.dueDate else {
        return nil
    }
    guard let day = dueDay(text: text, meetingDate: task.meetingStartedAt, language: task.noteLanguage, calendar: calendar) else {
        return TaskDueLabel(text: text, isOverdue: false, isToday: false)
    }
    return dueDayLabel(dueDay: day, now: now, calendar: calendar, locale: locale)
}

/// Görevlerim'deki gruplar, ekrandaki sırayla.
public enum TaskDueBucket: Int, Sendable, Equatable, CaseIterable {
    /// Son günü geçmiş.
    case overdue
    /// Son günü bugün.
    case today
    /// Yarından başlayarak önümüzdeki 7 gün içinde.
    case nextSevenDays
    /// Daha ileride.
    case later
    /// Tarihi yok ya da çözülemedi.
    case undated
}

/// Son günün (`dueDay`, nil = tarihsiz) bugüne (`now`) göre grubu. Saf fonksiyondur.
public func taskDueBucket(dueDay: Date?, now: Date, calendar: Calendar) -> TaskDueBucket {
    guard let dueDay else {
        return .undated
    }
    let days: Int = dayDistance(from: now, to: dueDay, calendar: calendar)
    if days < 0 {
        return .overdue
    }
    if days == 0 {
        return .today
    }
    return days <= 7 ? .nextSevenDays : .later
}

/// İki an arasındaki takvim günü farkı (saat farkı sayılmaz). Saf fonksiyondur.
func dayDistance(from start: Date, to end: Date, calendar: Calendar) -> Int {
    calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
}

/// Görev satırındaki tarih: arayüz dilinde göreli metin ve gecikti mi (kırmızı gösterilir).
public struct TaskDueLabel: Sendable, Equatable {
    public let text: String
    public let isOverdue: Bool
    /// Son günü bugün (vurgulu gösterilir).
    public let isToday: Bool

    public init(text: String, isOverdue: Bool, isToday: Bool) {
        self.text = text
        self.isOverdue = isOverdue
        self.isToday = isToday
    }
}

/// Görevin tarih etiketi, arayüz dilinde (`locale`): gecikmişte "2 gün gecikti", bugünse "Bugün", yarınsa "Yarın",
/// önümüzdeki 6 gündeyse gün adı ("Cuma"), daha ilerideyse kısa tarih ("Cum 14 Kas"; başka yıldaysa yıl da). Tarih
/// çözülemediyse notta yazıldığı gibi; tarihsiz görevde nil. Saf fonksiyondur.
public func taskDueLabel(record: MeetingRecord, task: NoteTask, now: Date, calendar: Calendar, locale: Locale) -> TaskDueLabel? {
    guard let text = task.dueDate else {
        return nil
    }
    guard let day = taskDueDay(record: record, task: task, calendar: calendar) else {
        return TaskDueLabel(text: text, isOverdue: false, isToday: false)
    }
    return dueDayLabel(dueDay: day, now: now, calendar: calendar, locale: locale)
}

/// Çözülmüş son günün etiketi (bkz. `taskDueLabel`). Saf fonksiyondur.
public func dueDayLabel(dueDay: Date, now: Date, calendar: Calendar, locale: Locale) -> TaskDueLabel {
    let days: Int = dayDistance(from: now, to: dueDay, calendar: calendar)
    var style: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    if days < 0 {
        return TaskDueLabel(text: String(localized: "\(-days) gün gecikti"), isOverdue: true, isToday: false)
    }
    if days == 0 {
        return TaskDueLabel(text: String(localized: "Son gün bugün"), isOverdue: false, isToday: true)
    }
    if days == 1 {
        return TaskDueLabel(text: String(localized: "Son gün yarın"), isOverdue: false, isToday: false)
    }
    if days < 7 {
        style = style.weekday(.wide)
    } else {
        style = style.weekday(.abbreviated).day().month(.abbreviated)
        if calendar.component(.year, from: dueDay) != calendar.component(.year, from: now) {
            style = style.year()
        }
    }
    return TaskDueLabel(text: dueDay.formatted(style), isOverdue: false, isToday: false)
}

/// Görevlerim'de bir görev: toplantısı, görevi ve çözülmüş son günü.
public struct DatedTask: Sendable, Equatable {
    public let record: MeetingRecord
    public let task: NoteTask
    public let dueDay: Date?

    public init(record: MeetingRecord, task: NoteTask, dueDay: Date?) {
        self.record = record
        self.task = task
        self.dueDay = dueDay
    }

    /// Listelerde satır kimliği: toplantı ve görev kimliği.
    public var rowID: String { record.id + "|" + task.trackingKey }
}

/// Görevlerim'in bir grubu (gecikmiş, bugün, önümüzdeki 7 gün, daha sonra, tarihsiz) ve sıralı görevleri.
public struct TaskDueGroup: Sendable, Equatable {
    public let bucket: TaskDueBucket
    public let tasks: [DatedTask]

    public init(bucket: TaskDueBucket, tasks: [DatedTask]) {
        self.bucket = bucket
        self.tasks = tasks
    }
}

/// Görevleri son günlerine göre gruplar (boş grup yok, `TaskDueBucket` sırasıyla). Grup içinde son günü yakın olan
/// önce; aynı günde ve tarihsizlerde verilen sıra (en yeni toplantı önce) korunur. Saf fonksiyondur.
public func groupedByDueDay(items: [(record: MeetingRecord, task: NoteTask)], now: Date, calendar: Calendar) -> [TaskDueGroup] {
    let dated: [(offset: Int, element: DatedTask)] = items.enumerated().map { (item: (offset: Int, element: (record: MeetingRecord, task: NoteTask))) -> (offset: Int, element: DatedTask) in
        (item.offset, DatedTask(record: item.element.record, task: item.element.task, dueDay: taskDueDay(record: item.element.record, task: item.element.task, calendar: calendar)))
    }
    return TaskDueBucket.allCases.compactMap { (bucket: TaskDueBucket) -> TaskDueGroup? in
        let inBucket: [(offset: Int, element: DatedTask)] = dated
            .filter { taskDueBucket(dueDay: $0.element.dueDay, now: now, calendar: calendar) == bucket }
            .sorted { (left: (offset: Int, element: DatedTask), right: (offset: Int, element: DatedTask)) -> Bool in
                switch (left.element.dueDay, right.element.dueDay) {
                case (let leftDay?, let rightDay?) where leftDay != rightDay:
                    return leftDay < rightDay
                default:
                    return left.offset < right.offset
                }
            }
        return inBucket.isEmpty ? nil : TaskDueGroup(bucket: bucket, tasks: inBucket.map(\.element))
    }
}

/// Bugün (ya da daha önce) son günü gelen, tamamlanmamış görevler: ana sayfadaki "Bugünkü görevler". Saf fonksiyondur.
public func dueTodayOrOverdue(items: [(record: MeetingRecord, task: NoteTask)], now: Date, calendar: Calendar) -> [DatedTask] {
    groupedByDueDay(items: items.filter { !isTaskDone(record: $0.record, task: $0.task) }, now: now, calendar: calendar)
        .filter { $0.bucket == .overdue || $0.bucket == .today }
        .flatMap(\.tasks)
}

/// Elle eklenecek görevin tarih metni: notta kalıcı ve her dilde çözülebilen ISO gün ("2026-11-14"). Saf fonksiyondur.
public func addedTaskDueText(day: Date, calendar: Calendar) -> String {
    let parts: DateComponents = calendar.dateComponents([.year, .month, .day], from: day)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

/// Kullanıcının elle eklediği görevi (kendisinin; boş işse nil) toplantının notuna ekler. Sahip kullanıcının adı, ad
/// yoksa arayüzdeki "Sen". Notu olmayan toplantıda ya da aynı iş zaten varsa nil. Saf fonksiyondur.
public func addingTask(record: MeetingRecord, description: String, dueDay: Date?, userName: String, calendar: Calendar) -> MeetingRecord? {
    let text: String = description.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let note = record.note else {
        return nil
    }
    let name: String = userName.trimmingCharacters(in: .whitespacesAndNewlines)
    let task: NoteTask = NoteTask(
        owner: name.isEmpty ? speakerLabel(speaker: .me, person: nil) : name, description: text,
        dueDate: dueDay.map { addedTaskDueText(day: $0, calendar: calendar) }, isMine: true
    ).markedAdded()
    guard !note.tasks.contains(where: { taskKey(task: $0) == taskKey(task: task) }) else {
        return nil
    }
    return record.with(note: note.with(title: note.title, summary: note.summary, decisions: note.decisions, tasks: note.tasks + [task], glossary: note.glossary))
}

/// Elle eklenmiş görevi (`NoteTask.isAdded`) nottan ve işaretlerinden siler; nottan gelen görev silinmez (kayıt
/// değişmez). Saf fonksiyondur.
public func removingAddedTask(record: MeetingRecord, task: NoteTask) -> MeetingRecord {
    let key: String = taskKey(task: task)
    guard let note = record.note, note.tasks.contains(where: { taskKey(task: $0) == key && $0.isAdded == true }) else {
        return record
    }
    let tasks: [NoteTask] = note.tasks.filter { taskKey(task: $0) != key }
    let updated: MeetingRecord = record.with(note: note.with(title: note.title, summary: note.summary, decisions: note.decisions, tasks: tasks, glossary: note.glossary))
    let completed: MeetingRecord = record.completedTasks.map { updated.with(completedTasks: $0.filter { $0 != key }) } ?? updated
    return record.remindedTasks.map { completed.with(remindedTasks: $0.filter { $0 != key }) } ?? completed
}

/// Görevin son günü, bugüne göre olmayan kalıcı biçimde (yazdırılan belge, dışa aktarım): çözülürse arayüz dilinde
/// kısa tarih ("Cum 14 Kas 2026"), çözülemezse notta yazıldığı gibi; tarihsizde nil. Saf fonksiyondur.
public func taskDueDateText(record: MeetingRecord, task: NoteTask, calendar: Calendar, locale: Locale) -> String? {
    guard let text = task.dueDate else {
        return nil
    }
    guard let day = taskDueDay(record: record, task: task, calendar: calendar) else {
        return text
    }
    let style: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        .weekday(.abbreviated).day().month(.abbreviated).year()
    return day.formatted(style)
}
