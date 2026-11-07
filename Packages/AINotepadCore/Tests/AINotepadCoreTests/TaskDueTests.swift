import Foundation
import Testing
@testable import AINotepadCore

@Suite struct TaskDueTests {
    private let calendar: Calendar = {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return calendar
    }()

    private func day(_ month: Int, _ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// Pazartesi 9 Kasım 2026'da yapılmış, İngilizce notlu toplantı.
    private func record(tasks: [NoteTask]) -> MeetingRecord {
        MeetingRecord(
            id: "1", title: "Sync", startedAt: day(11, 9, hour: 10), endedAt: nil, language: .english, status: .done,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Sync", summary: "S", decisions: [], tasks: tasks, glossary: []).with(language: .english),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    // "Today" toplantı gününe çözülür: haftalar sonra bugün değil, gecikmiş görünür.
    @Test func relativeWordsResolveAgainstMeetingDay() {
        let today: NoteTask = NoteTask(owner: "You", description: "Send deck", dueDate: "Today", isMine: true)
        let friday: NoteTask = NoteTask(owner: "You", description: "Book room", dueDate: "by Friday", isMine: true)
        let meeting: MeetingRecord = record(tasks: [today, friday])
        #expect(taskDue(record: meeting, task: today, calendar: calendar) == .day(calendar.startOfDay(for: day(11, 9, hour: 0))))
        #expect(taskDue(record: meeting, task: friday, calendar: calendar) == .day(calendar.startOfDay(for: day(11, 13, hour: 0))))
        let later: Date = day(11, 30, hour: 9)
        let label: TaskDueLabel? = taskDueLabel(record: meeting, task: today, now: later, calendar: calendar, locale: Locale(identifier: "en"))
        #expect(label?.isOverdue == true)
        #expect(taskDueBucket(due: taskDue(record: meeting, task: today, calendar: calendar), now: later, calendar: calendar) == .overdue)
    }

    // Çözülemeyen tarih notta yazıldığı gibi kalır, tarihsiz gruba düşer.
    @Test func unresolvedTextStaysAsWritten() {
        let vague: NoteTask = NoteTask(owner: "You", description: "Plan offsite", dueDate: "next quarter", isMine: true)
        let meeting: MeetingRecord = record(tasks: [vague])
        #expect(taskDue(record: meeting, task: vague, calendar: calendar) == nil)
        #expect(taskDueLabel(record: meeting, task: vague, now: day(11, 9, hour: 12), calendar: calendar, locale: Locale(identifier: "en"))
            == TaskDueLabel(text: "next quarter", isOverdue: false, isToday: false))
    }

    // "Next week" gelecek haftanın pazartesisi, ay adı o ay: dönem bitmeden gecikmiş sayılmaz, etiketi dönemin adı.
    @Test func vagueWeekAndMonthResolveToPeriods() {
        let nextWeek: NoteTask = NoteTask(owner: "You", description: "Interviews", dueDate: "Next week", isMine: true)
        let thisWeek: NoteTask = NoteTask(owner: "You", description: "Book", dueDate: "This week", isMine: true)
        let november: NoteTask = NoteTask(owner: "You", description: "Research", dueDate: "November", isMine: true)
        let march: NoteTask = NoteTask(owner: "You", description: "Plan", dueDate: "by March", isMine: true)
        let meeting: MeetingRecord = record(tasks: [nextWeek, thisWeek, november, march])
        let monday: Date = calendar.startOfDay(for: day(11, 16, hour: 0))
        #expect(taskDue(record: meeting, task: nextWeek, calendar: calendar) == .week(start: monday))
        #expect(taskDue(record: meeting, task: thisWeek, calendar: calendar) == .week(start: calendar.startOfDay(for: day(11, 9, hour: 0))))
        #expect(taskDue(record: meeting, task: november, calendar: calendar) == .month(start: calendar.startOfDay(for: day(11, 1, hour: 0))))
        // Toplantıdan önceki ay ertesi yıldır.
        #expect(taskDue(record: meeting, task: march, calendar: calendar)
            == .month(start: calendar.date(from: DateComponents(year: 2027, month: 3, day: 1))!))
        let english: Locale = Locale(identifier: "en")
        let wednesday: Date = day(11, 11, hour: 9)
        #expect(taskDueLabel(record: meeting, task: nextWeek, now: wednesday, calendar: calendar, locale: english)?.text == "Gelecek hafta")
        #expect(taskDueBucket(due: taskDue(record: meeting, task: nextWeek, calendar: calendar), now: wednesday, calendar: calendar) == .nextSevenDays)
        #expect(taskDueBucket(due: taskDue(record: meeting, task: november, calendar: calendar), now: wednesday, calendar: calendar) == .later)
        #expect(taskDueLabel(record: meeting, task: november, now: wednesday, calendar: calendar, locale: english)?.text == "November")
        // Ay bitmeden gecikmez; bitince son günden sayılır.
        #expect(taskDueBucket(due: taskDue(record: meeting, task: november, calendar: calendar), now: day(11, 30, hour: 20), calendar: calendar) == .later)
        #expect(taskDueBucket(due: taskDue(record: meeting, task: november, calendar: calendar), now: day(12, 2, hour: 9), calendar: calendar) == .overdue)
        #expect(taskDueLabel(record: meeting, task: november, now: day(12, 2, hour: 9), calendar: calendar, locale: english)?.isOverdue == true)
        // Hafta pazar bitince gecikir.
        #expect(taskDueBucket(due: taskDue(record: meeting, task: nextWeek, calendar: calendar), now: day(11, 22, hour: 22), calendar: calendar) == .nextSevenDays)
        #expect(taskDueBucket(due: taskDue(record: meeting, task: nextWeek, calendar: calendar), now: day(11, 23, hour: 9), calendar: calendar) == .overdue)
    }

    // Belirsiz dönem sözcükleri notun dilinde de çözülür.
    @Test func vaguePeriodsInOtherNoteLanguages() {
        let start: Date = day(11, 9, hour: 10)
        #expect(resolvedDue(text: "gelecek hafta", meetingDate: start, language: .turkish, calendar: calendar) == .week(start: calendar.startOfDay(for: day(11, 16, hour: 0))))
        #expect(resolvedDue(text: "Kasım sonuna kadar", meetingDate: start, language: .turkish, calendar: calendar) == .month(start: calendar.startOfDay(for: day(11, 1, hour: 0))))
        #expect(resolvedDue(text: "joulukuussa", meetingDate: start, language: .finnish, calendar: calendar) == .month(start: calendar.startOfDay(for: day(12, 1, hour: 0))))
        #expect(resolvedDue(text: "after the beta", meetingDate: start, language: .english, calendar: calendar) == nil)
    }

    // Gruplar sabit sırada, boş grup yok; grup içinde yakın tarih önce.
    @Test func groupsInOrderAndSortedByDay() {
        let tasks: [NoteTask] = [
            NoteTask(owner: "You", description: "later", dueDate: "2026-12-20", isMine: true),
            NoteTask(owner: "You", description: "none", dueDate: nil, isMine: true),
            NoteTask(owner: "You", description: "sunday", dueDate: "2026-11-15", isMine: true),
            NoteTask(owner: "You", description: "today", dueDate: "2026-11-10", isMine: true),
            NoteTask(owner: "You", description: "wednesday", dueDate: "2026-11-11", isMine: true),
            NoteTask(owner: "You", description: "late", dueDate: "2026-11-09", isMine: true),
        ]
        let meeting: MeetingRecord = record(tasks: tasks)
        let groups: [TaskDueGroup] = groupedByDueDay(items: tasks.map { (record: meeting, task: $0) }, now: day(11, 10, hour: 18), calendar: calendar)
        #expect(groups.map(\.bucket) == [.overdue, .today, .nextSevenDays, .later, .undated])
        #expect(groups[2].tasks.map(\.task.description) == ["wednesday", "sunday"])
        #expect(dueTodayOrOverdue(items: tasks.map { (record: meeting, task: $0) }, now: day(11, 10, hour: 18), calendar: calendar).map(\.task.description) == ["late", "today"])
    }

    // Elle eklenen görev notta kalır, not yeniden yazılınca taşınır; yalnız elle eklenen silinir.
    @Test func addedTaskSurvivesRewriteAndCanBeRemoved() throws {
        let fromNote: NoteTask = NoteTask(owner: "You", description: "Send deck", dueDate: nil, isMine: true)
        let meeting: MeetingRecord = record(tasks: [fromNote])
        let added: MeetingRecord = try #require(addingTask(record: meeting, description: " Call Dana ", dueDay: day(11, 12, hour: 15), userName: "Alex", calendar: calendar))
        let task: NoteTask = try #require(added.note?.tasks.last)
        #expect(task.isAdded == true && task.isMine && task.owner == "Alex" && task.dueDate == "2026-11-12")
        #expect(addingTask(record: added, description: "call dana", dueDay: nil, userName: "Alex", calendar: calendar) == nil)
        let rewritten: MeetingRecord = withCarriedTaskMarks(old: added, new: added.with(note: try #require(meeting.note)))
        #expect(rewritten.note?.tasks.map(\.description) == ["Send deck", "Call Dana"])
        let done: MeetingRecord = togglingTask(record: rewritten, task: task)
        let removed: MeetingRecord = removingAddedTask(record: done, task: task)
        #expect(removed.note?.tasks == [fromNote])
        #expect(removed.completedTasks == [])
        #expect(removingAddedTask(record: removed, task: fromNote) == removed)
        let decoded: MeetingRecord = try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(added))
        #expect(decoded.note?.tasks.last?.isAdded == true)
    }

    // Saklı çeviri silinmez (yeniden çeviri ücretli): elle eklenen görev çevirilere de eklenir, çeviri gösterilmeye devam eder.
    @Test func addedTaskKeepsTranslations() throws {
        let fromNote: NoteTask = NoteTask(owner: "You", description: "Send deck", dueDate: nil, isMine: true)
        let meeting: MeetingRecord = record(tasks: [fromNote])
        let finnish: MeetingNote = MeetingNote(title: "Synkka", summary: "Y", decisions: [], tasks: [
            NoteTask(owner: "Sinä", description: "Lähetä esitys", dueDate: nil, isMine: true),
        ], glossary: [])
        let translated: MeetingRecord = meeting.with(sharedNotes: ["fi": finnish])
        let added: MeetingRecord = try #require(addingTask(record: translated, description: "Call Dana", dueDay: nil, userName: "Alex", calendar: calendar))
        let version: MeetingNote = try #require(sharedNoteVersion(record: added, language: .finnish))
        #expect(version.tasks.map(\.description) == ["Lähetä esitys", "Call Dana"])
        let task: NoteTask = try #require(added.note?.tasks.last)
        #expect(removingAddedTask(record: added, task: task).sharedNotes?["fi"]?.tasks.count == 1)
    }
}
