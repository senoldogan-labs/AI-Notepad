import Foundation

/// Görevin çözülmüş son günü ya da dönemi. Not "gelecek hafta" ya da "Kasım" diyorsa gün değil dönem bellidir: dönem
/// bitene kadar gecikmiş sayılmaz.
public enum TaskDue: Sendable, Equatable {
    /// Belli gün (günün başı).
    case day(Date)
    /// Hafta: pazartesi başlar (günün başı), 7 gün sürer.
    case week(start: Date)
    /// Ay: ayın ilk günü (günün başı).
    case month(start: Date)

    /// Dönemin ilk günü: sıralamada bu kullanılır.
    public var start: Date {
        switch self {
        case .day(let day): day
        case .week(let start): start
        case .month(let start): start
        }
    }

    /// Dönemin son günü (günün başı): bu gün geçince görev gecikmiştir.
    func lastDay(calendar: Calendar) -> Date {
        switch self {
        case .day(let day):
            return day
        case .week(let start):
            return calendar.date(byAdding: .day, value: 6, to: start) ?? start
        case .month(let start):
            let next: Date = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return calendar.date(byAdding: .day, value: -1, to: next) ?? start
        }
    }
}

/// Görevin son günü ya da dönemi: notta serbest metin olarak yazılan tarih toplantı gününe göre çözülür, notun dilinde.
/// Önce gün (`parseDueDate`: "Cuma", "yarın", "14 Kasım", elle eklenende "2026-11-14"), yoksa hafta ("bu hafta",
/// "gelecek hafta"), yoksa ay ("bu ay", "gelecek ay", ay adı "Kasım"). Böylece "Bugün" yazılan görev haftalar sonra da
/// toplantı gününü gösterir ve eski notlar da kendiliğinden çözülür. Hiçbiri değilse ("sonraki dönem") ya da tarihsiz
/// görevde nil. Saf fonksiyondur.
public func taskDue(record: MeetingRecord, task: NoteTask, calendar: Calendar) -> TaskDue? {
    task.dueDate.flatMap { resolvedDue(text: $0, meetingDate: record.startedAt, language: record.note?.writtenLanguage ?? .turkish, calendar: calendar) }
}

/// Serbest metin tarihin (`text`) toplantı gününe göre çözülmüşü (bkz. `taskDue`). Saf fonksiyondur.
func resolvedDue(text: String, meetingDate: Date, language: ShareLanguage, calendar: Calendar) -> TaskDue? {
    if let components = parseDueDate(text: text, meetingDate: meetingDate, calendar: calendar, language: language),
       let date = calendar.date(from: components) {
        return .day(calendar.startOfDay(for: date))
    }
    return dueWeek(text: text, meetingDate: meetingDate, language: language, calendar: calendar)
        ?? dueMonth(text: text, meetingDate: meetingDate, language: language, calendar: calendar)
}

/// Metnin sözcükleri, notun dilinde küçük harfle (harf ve rakam dışı ayırır).
private func dueTokens(text: String, locale: Locale) -> [String] {
    text.lowercased(with: locale).split { (character: Character) -> Bool in !character.isLetter && !character.isNumber }.map(String.init)
}

/// `words` sözcük öbeği `tokens` içinde geçiyor mu: son sözcük dışındakiler aynen, son sözcük önekten (çekim ekleri).
private func containsPhrase(tokens: [String], words: [String]) -> Bool {
    guard !words.isEmpty, tokens.count >= words.count else {
        return false
    }
    return (0...(tokens.count - words.count)).contains { (index: Int) -> Bool in
        zip(words, tokens[index..<(index + words.count)]).enumerated().allSatisfy { (item: (offset: Int, element: (String, String))) -> Bool in
            item.offset == words.count - 1 ? item.element.1.hasPrefix(item.element.0) : item.element.1 == item.element.0
        }
    }
}

/// Notun dilinde "bu/gelecek <birim>" sözcükleri (`RelativeDateTimeFormatter`, adlandırılmış biçim: "next week",
/// "gelecek hafta", "ensi viikolla"); uzun öbek önce denenir ("gelecek hafta" "hafta"dan önce). Bulunamazsa nil.
private func relativePeriodOffset(tokens: [String], unit: Calendar.Component, locale: Locale) -> Int? {
    let formatter: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.dateTimeStyle = .named
    formatter.unitsStyle = .full
    let phrases: [(words: [String], offset: Int)] = [1, 0].map { (offset: Int) -> (words: [String], offset: Int) in
        var components: DateComponents = DateComponents()
        components.setValue(offset, for: unit)
        return (dueTokens(text: formatter.localizedString(from: components), locale: locale), offset)
    }
    return phrases.filter { !$0.words.isEmpty && containsPhrase(tokens: tokens, words: $0.words) }
        .max { $0.words.count < $1.words.count }?.offset
}

/// "Bu hafta" ya da "gelecek hafta": toplantının haftasının ya da sonrakinin pazartesisi. Saf fonksiyondur.
func dueWeek(text: String, meetingDate: Date, language: ShareLanguage, calendar: Calendar) -> TaskDue? {
    let locale: Locale = Locale(identifier: language.rawValue)
    guard let offset = relativePeriodOffset(tokens: dueTokens(text: text, locale: locale), unit: .weekOfMonth, locale: locale) else {
        return nil
    }
    let meetingDay: Date = calendar.startOfDay(for: meetingDate)
    // Pazartesi başlangıcı (1 pazar … 7 cumartesi): toplantı gününden geriye o haftanın pazartesisi.
    let sinceMonday: Int = (calendar.component(.weekday, from: meetingDay) + 5) % 7
    guard let start = calendar.date(byAdding: .day, value: 7 * offset - sinceMonday, to: meetingDay) else {
        return nil
    }
    return .week(start: start)
}

/// "Bu ay", "gelecek ay" ya da ay adı ("Kasım", "marraskuussa"; uzun ad önekten, kısa ad tam eşleşir): o ayın ilk günü.
/// Ay adında yıl toplantınınki, ay toplantıdan önceyse ertesi yıl. Saf fonksiyondur.
func dueMonth(text: String, meetingDate: Date, language: ShareLanguage, calendar: Calendar) -> TaskDue? {
    let locale: Locale = Locale(identifier: language.rawValue)
    let tokens: [String] = dueTokens(text: text, locale: locale)
    let meeting: DateComponents = calendar.dateComponents([.year, .month], from: meetingDate)
    guard let meetingYear = meeting.year, let meetingMonth = meeting.month,
          let meetingMonthStart = calendar.date(from: DateComponents(year: meetingYear, month: meetingMonth, day: 1)) else {
        return nil
    }
    if let offset = relativePeriodOffset(tokens: tokens, unit: .month, locale: locale) {
        return calendar.date(byAdding: .month, value: offset, to: meetingMonthStart).map { TaskDue.month(start: $0) }
    }
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = locale
    let lowered: (String) -> String = { (name: String) -> String in
        name.lowercased(with: locale).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    let longNames: [(name: String, month: Int)] = [formatter.monthSymbols ?? [], formatter.standaloneMonthSymbols ?? []]
        .flatMap { (symbols: [String]) -> [(name: String, month: Int)] in
            symbols.enumerated().map { (item: (offset: Int, element: String)) -> (name: String, month: Int) in (lowered(item.element), item.offset + 1) }
        }
    let shortNames: [(name: String, month: Int)] = [formatter.shortMonthSymbols ?? [], formatter.shortStandaloneMonthSymbols ?? []]
        .flatMap { (symbols: [String]) -> [(name: String, month: Int)] in
            symbols.enumerated().map { (item: (offset: Int, element: String)) -> (name: String, month: Int) in (lowered(item.element), item.offset + 1) }
        }
    let found: Int? = tokens.lazy.compactMap { (token: String) -> Int? in
        // Kısa uzun adlar ("may", "june") tam eşleşir: "maybe" mayıs değildir.
        longNames.filter { !$0.name.isEmpty && (token == $0.name || ($0.name.count >= 5 && token.hasPrefix($0.name))) }
            .max { $0.name.count < $1.name.count }?.month
            ?? shortNames.first { $0.name.count >= 3 && $0.name == token }?.month
    }.first
    guard let month = found else {
        return nil
    }
    let year: Int = month < meetingMonth ? meetingYear + 1 : meetingYear
    return calendar.date(from: DateComponents(year: year, month: month, day: 1)).map { TaskDue.month(start: $0) }
}

/// Kişinin görevinin tarih etiketi (bkz. `taskDueLabel`). Saf fonksiyondur.
public func personTaskDueLabel(task: PersonTask, now: Date, calendar: Calendar, locale: Locale) -> TaskDueLabel? {
    guard let text = task.task.dueDate else {
        return nil
    }
    guard let due = resolvedDue(text: text, meetingDate: task.meetingStartedAt, language: task.noteLanguage, calendar: calendar) else {
        return TaskDueLabel(text: text, isOverdue: false, isToday: false)
    }
    return dueLabel(due: due, now: now, calendar: calendar, locale: locale)
}

/// Görevlerim'deki gruplar, ekrandaki sırayla.
public enum TaskDueBucket: Int, Sendable, Equatable, CaseIterable {
    /// Son günü (ya da dönemi) geçmiş.
    case overdue
    /// Son günü bugün.
    case today
    /// Önümüzdeki 7 gün içinde (ya da süren hafta).
    case nextSevenDays
    /// Daha ileride (ay olarak yazılanlar da).
    case later
    /// Tarihi yok ya da çözülemedi.
    case undated
}

/// Son günün ya da dönemin (`due`, nil = tarihsiz) bugüne (`now`) göre grubu: dönem bitmeden gecikmiş sayılmaz; hafta
/// önümüzdeki 7 günde başlıyorsa ya da sürüyorsa "önümüzdeki 7 gün", ay "daha sonra". Saf fonksiyondur.
public func taskDueBucket(due: TaskDue?, now: Date, calendar: Calendar) -> TaskDueBucket {
    guard let due else {
        return .undated
    }
    if dayDistance(from: now, to: due.lastDay(calendar: calendar), calendar: calendar) < 0 {
        return .overdue
    }
    switch due {
    case .day(let day):
        let days: Int = dayDistance(from: now, to: day, calendar: calendar)
        if days == 0 {
            return .today
        }
        return days <= 7 ? .nextSevenDays : .later
    case .week(let start):
        return dayDistance(from: now, to: start, calendar: calendar) <= 7 ? .nextSevenDays : .later
    case .month:
        return .later
    }
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

/// Görevin tarih etiketi, arayüz dilinde (`locale`; bkz. `dueLabel`). Tarih çözülemediyse notta yazıldığı gibi;
/// tarihsiz görevde nil. Saf fonksiyondur.
public func taskDueLabel(record: MeetingRecord, task: NoteTask, now: Date, calendar: Calendar, locale: Locale) -> TaskDueLabel? {
    guard let text = task.dueDate else {
        return nil
    }
    guard let due = taskDue(record: record, task: task, calendar: calendar) else {
        return TaskDueLabel(text: text, isOverdue: false, isToday: false)
    }
    return dueLabel(due: due, now: now, calendar: calendar, locale: locale)
}

/// Çözülmüş son günün ya da dönemin etiketi: dönem bittiyse "2 gün gecikti" (son günden sayılır); gün için "Son gün
/// bugün", "Son gün yarın", önümüzdeki 6 günde gün adı ("Cuma"), daha ilerisi kısa tarih ("Cum 14 Kas"; başka yılda
/// yıl da); hafta için "Bu hafta", "Gelecek hafta" ya da "16 Kas haftası"; ay için ay adı ("Kasım"; başka yılda yıl da).
/// Saf fonksiyondur.
public func dueLabel(due: TaskDue, now: Date, calendar: Calendar, locale: Locale) -> TaskDueLabel {
    let late: Int = -dayDistance(from: now, to: due.lastDay(calendar: calendar), calendar: calendar)
    if late > 0 {
        return TaskDueLabel(text: String(localized: "\(late) gün gecikti"), isOverdue: true, isToday: false)
    }
    let base: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    let otherYear: Bool = calendar.component(.year, from: due.start) != calendar.component(.year, from: now)
    switch due {
    case .day(let day):
        return dueDayLabel(dueDay: day, now: now, calendar: calendar, locale: locale)
    case .week(let start):
        let weeks: Int = Int((Double(dayDistance(from: now, to: start, calendar: calendar)) / 7).rounded(.up))
        if weeks <= 0 {
            return TaskDueLabel(text: String(localized: "Bu hafta"), isOverdue: false, isToday: false)
        }
        if weeks == 1 {
            return TaskDueLabel(text: String(localized: "Gelecek hafta"), isOverdue: false, isToday: false)
        }
        let day: String = start.formatted(otherYear ? base.day().month(.abbreviated).year() : base.day().month(.abbreviated))
        return TaskDueLabel(text: String(localized: "\(day) haftası"), isOverdue: false, isToday: false)
    case .month(let start):
        return TaskDueLabel(text: start.formatted(otherYear ? base.month(.wide).year() : base.month(.wide)), isOverdue: false, isToday: false)
    }
}

/// Çözülmüş son günün etiketi (bkz. `dueLabel`). Saf fonksiyondur.
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

/// Görevlerim'de bir görev: toplantısı, görevi ve çözülmüş son günü ya da dönemi.
public struct DatedTask: Sendable, Equatable {
    public let record: MeetingRecord
    public let task: NoteTask
    public let due: TaskDue?

    public init(record: MeetingRecord, task: NoteTask, due: TaskDue?) {
        self.record = record
        self.task = task
        self.due = due
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

/// Görevleri son günlerine göre gruplar (boş grup yok, `TaskDueBucket` sırasıyla). Grup içinde dönemi önce başlayan
/// önce; aynı başlangıçta ve tarihsizlerde verilen sıra (en yeni toplantı önce) korunur. Saf fonksiyondur.
public func groupedByDueDay(items: [(record: MeetingRecord, task: NoteTask)], now: Date, calendar: Calendar) -> [TaskDueGroup] {
    let dated: [(offset: Int, element: DatedTask)] = items.enumerated().map { (item: (offset: Int, element: (record: MeetingRecord, task: NoteTask))) -> (offset: Int, element: DatedTask) in
        (item.offset, DatedTask(record: item.element.record, task: item.element.task, due: taskDue(record: item.element.record, task: item.element.task, calendar: calendar)))
    }
    return TaskDueBucket.allCases.compactMap { (bucket: TaskDueBucket) -> TaskDueGroup? in
        let inBucket: [(offset: Int, element: DatedTask)] = dated
            .filter { taskDueBucket(due: $0.element.due, now: now, calendar: calendar) == bucket }
            .sorted { (left: (offset: Int, element: DatedTask), right: (offset: Int, element: DatedTask)) -> Bool in
                switch (left.element.due?.start, right.element.due?.start) {
                case (let leftDay?, let rightDay?) where leftDay != rightDay:
                    return leftDay < rightDay
                default:
                    return left.offset < right.offset
                }
            }
        return inBucket.isEmpty ? nil : TaskDueGroup(bucket: bucket, tasks: inBucket.map(\.element))
    }
}

/// Tamamlanmamış görevler aciliyet sırasıyla (gecikmiş, bugün, önümüzdeki 7 gün, daha sonra, tarihsiz; bkz.
/// `groupedByDueDay`): ana sayfada önce bugünün ve gecikmiş görevler görünür. Saf fonksiyondur.
public func openTasksByUrgency(items: [(record: MeetingRecord, task: NoteTask)], now: Date, calendar: Calendar) -> [DatedTask] {
    groupedByDueDay(items: items.filter { !isTaskDone(record: $0.record, task: $0.task) }, now: now, calendar: calendar).flatMap(\.tasks)
}

/// Bugün (ya da daha önce) son günü gelen, tamamlanmamış görevler. Saf fonksiyondur.
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
    return withTasks(record: record) { (tasks: [NoteTask]) -> [NoteTask] in tasks + [task] }
}

/// Elle eklenmiş görevi (`NoteTask.isAdded`) nottan ve işaretlerinden siler; nottan gelen görev silinmez (kayıt
/// değişmez). Saf fonksiyondur.
public func removingAddedTask(record: MeetingRecord, task: NoteTask) -> MeetingRecord {
    let key: String = taskKey(task: task)
    guard let note = record.note, note.tasks.contains(where: { taskKey(task: $0) == key && $0.isAdded == true }) else {
        return record
    }
    let updated: MeetingRecord = withTasks(record: record) { (tasks: [NoteTask]) -> [NoteTask] in
        tasks.filter { taskKey(task: $0) != key }
    }
    let completed: MeetingRecord = record.completedTasks.map { updated.with(completedTasks: $0.filter { $0 != key }) } ?? updated
    return record.remindedTasks.map { completed.with(remindedTasks: $0.filter { $0 != key }) } ?? completed
}

/// Görevin son günü, bugüne göre olmayan kalıcı biçimde (yazdırılan belge, dışa aktarım): çözülürse arayüz dilinde
/// kısa tarih ("Cum 14 Kas 2026"), hafta "16 Kas 2026 haftası", ay "Kasım 2026"; çözülemezse notta yazıldığı gibi;
/// tarihsizde nil. Saf fonksiyondur.
public func taskDueDateText(record: MeetingRecord, task: NoteTask, calendar: Calendar, locale: Locale) -> String? {
    guard let text = task.dueDate else {
        return nil
    }
    guard let due = taskDue(record: record, task: task, calendar: calendar) else {
        return text
    }
    let base: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    switch due {
    case .day(let day):
        return day.formatted(base.weekday(.abbreviated).day().month(.abbreviated).year())
    case .week(let start):
        let day: String = start.formatted(base.day().month(.abbreviated).year())
        return String(localized: "\(day) haftası")
    case .month(let start):
        return start.formatted(base.month(.wide).year())
    }
}

/// Notun ve saklı çevirilerinin (`sharedNotes`) görevleri `change` ile değişmiş kopya. Elle eklenen görev kullanıcının
/// kendi metnidir, çevrilmez: çeviriler de aynı görevle güncel kalır, `with(note:)` gibi silinip yeniden çevrilmez
/// (yeniden çeviri ücretli bir çağrıdır). Görev sayısı asıl notunkiyle tutmayan çeviri (eski) olduğu gibi bırakılır.
/// Notsuz kayıt değişmez. Saf fonksiyondur.
func withTasks(record: MeetingRecord, change: @escaping ([NoteTask]) -> [NoteTask]) -> MeetingRecord {
    guard let note = record.note else {
        return record
    }
    let changed: (MeetingNote) -> MeetingNote = { (version: MeetingNote) -> MeetingNote in
        version.with(title: version.title, summary: version.summary, decisions: version.decisions, tasks: change(version.tasks), glossary: version.glossary)
    }
    let shared: [String: MeetingNote]? = record.sharedNotes?.mapValues { (version: MeetingNote) -> MeetingNote in
        version.tasks.count == note.tasks.count ? changed(version) : version
    }
    let updated: MeetingRecord = record.with(note: changed(note))
    return shared.map { updated.with(sharedNotes: $0) } ?? updated
}
