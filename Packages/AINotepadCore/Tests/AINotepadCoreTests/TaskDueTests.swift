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
        #expect(taskDueDay(record: meeting, task: today, calendar: calendar) == calendar.startOfDay(for: day(11, 9, hour: 0)))
        #expect(taskDueDay(record: meeting, task: friday, calendar: calendar) == calendar.startOfDay(for: day(11, 13, hour: 0)))
        let later: Date = day(11, 30, hour: 9)
        let label: TaskDueLabel? = taskDueLabel(record: meeting, task: today, now: later, calendar: calendar, locale: Locale(identifier: "en"))
        #expect(label?.isOverdue == true)
        #expect(taskDueBucket(dueDay: taskDueDay(record: meeting, task: today, calendar: calendar), now: later, calendar: calendar) == .overdue)
    }

    // Çözülemeyen tarih notta yazıldığı gibi kalır, tarihsiz gruba düşer.
    @Test func unresolvedTextStaysAsWritten() {
        let vague: NoteTask = NoteTask(owner: "You", description: "Plan offsite", dueDate: "next quarter", isMine: true)
        let meeting: MeetingRecord = record(tasks: [vague])
        #expect(taskDueDay(record: meeting, task: vague, calendar: calendar) == nil)
        #expect(taskDueLabel(record: meeting, task: vague, now: day(11, 9, hour: 12), calendar: calendar, locale: Locale(identifier: "en"))
            == TaskDueLabel(text: "next quarter", isOverdue: false, isToday: false))
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
}
