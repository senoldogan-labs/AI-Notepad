import Foundation
import Testing
@testable import AINotepadCore

/// UTC Gregoryen takvim, hafta Pazartesi başlar (sonuçlar makinenin saat diliminden bağımsız).
private func utcCalendar() -> Calendar {
    var calendar: Calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    calendar.firstWeekday = 2
    return calendar
}

/// 2026-11-06 Cuma 12:00 UTC.
private let now: Date = Date(timeIntervalSince1970: 1_793_966_400)

private func meeting(
    id: String, daysAgo: Double, hour: Int, minutes: Double, tasks: [NoteTask], done: [NoteTask], speakers: [Int: String], folder: String?
) -> MeetingRecord {
    let day: Date = utcCalendar().startOfDay(for: now.addingTimeInterval(-daysAgo * 86_400))
    let start: Date = day.addingTimeInterval(Double(hour) * 3600)
    let record: MeetingRecord = MeetingRecord(
        id: id, title: id, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60), language: .english, status: .done,
        failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: speakers,
        note: MeetingNote(title: id, summary: "S", decisions: [], tasks: tasks, glossary: []), audioDeleted: false, engine: .cloud,
        notice: nil, meNeedsFinalPass: nil
    )
    .with(completedTasks: done.map { taskKey(task: $0) })
    return folder.map { record.with(folder: $0) } ?? record
}

private let taskA: NoteTask = NoteTask(owner: "Sen", description: "Send recap", dueDate: nil, isMine: true)
private let taskB: NoteTask = NoteTask(owner: "Ayşe", description: "Fix build", dueDate: nil, isMine: false)

@Suite struct MeetingAnalyticsTests {
    // Dönem toplamları: süre, ortalama, görevler ve notlar; önceki dönem ayrı sayılır; dönem dışı ve örnek toplantı yok.
    @Test func totalsCountPeriodAndPreviousPeriod() {
        let records: [MeetingRecord] = [
            meeting(id: "a", daysAgo: 0, hour: 9, minutes: 30, tasks: [taskA, taskB], done: [taskA], speakers: [:], folder: nil),
            meeting(id: "b", daysAgo: 6, hour: 14, minutes: 60, tasks: [], done: [], speakers: [:], folder: nil),
            meeting(id: "c", daysAgo: 8, hour: 10, minutes: 45, tasks: [taskA], done: [], speakers: [:], folder: nil),
            meeting(id: "sample", daysAgo: 1, hour: 10, minutes: 90, tasks: [taskA], done: [], speakers: [:], folder: nil).markedAsSample(),
            meeting(id: "old", daysAgo: 40, hour: 10, minutes: 10, tasks: [], done: [], speakers: [:], folder: nil),
        ]
        let result: MeetingAnalytics = meetingAnalytics(records: records, period: .week, userName: "", now: now, calendar: utcCalendar())
        #expect(result.totals == AnalyticsTotals(meetings: 2, seconds: 5400, timedMeetings: 2, tasksCreated: 2, tasksMine: 1, tasksCompleted: 1, notes: 2))
        #expect(result.totals.averageSeconds == 2700)
        #expect(result.previous == AnalyticsTotals(meetings: 1, seconds: 2700, timedMeetings: 1, tasksCreated: 1, tasksMine: 1, tasksCompleted: 0, notes: 1))
        #expect(result.allTimeMeetings == 4)
        #expect(meetingAnalytics(records: records, period: .all, userName: "", now: now, calendar: utcCalendar()).previous == nil)
    }

    // Süren kayıt sayılmaz; bitişi olmayan toplantı sayıya girer, ortalamaya girmez.
    @Test func recordingAndUntimedMeetings() {
        let base: MeetingRecord = meeting(id: "live", daysAgo: 0, hour: 9, minutes: 10, tasks: [], done: [], speakers: [:], folder: nil)
        let recording: MeetingRecord = base.with(status: .recording, failureMessage: nil)
        #expect(analyticsMeetings(records: [recording]).isEmpty)
        let untimed: MeetingRecord = MeetingRecord(
            id: "u", title: "u", startedAt: now, endedAt: nil, language: nil, status: .interrupted, failureMessage: nil, liveSegments: [],
            finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: nil, notice: nil, meNeedsFinalPass: nil
        )
        let totals: AnalyticsTotals = analyticsTotals(meetings: [base, untimed], userName: "")
        #expect(totals.meetings == 2)
        #expect(totals.timedMeetings == 1)
        #expect(totals.averageSeconds == 600)
        #expect(analyticsTotals(meetings: [untimed], userName: "").averageSeconds == nil)
    }

    // Çubuklar dönemin her gününü kapsar; toplantısız günler sıfır, görevler toplantının gününde açık/tamamlanan.
    @Test func timelineFillsEmptyBuckets() {
        let records: [MeetingRecord] = [
            meeting(id: "a", daysAgo: 0, hour: 9, minutes: 90, tasks: [taskA, taskB], done: [taskB], speakers: [:], folder: nil),
            meeting(id: "b", daysAgo: 6, hour: 14, minutes: 30, tasks: [], done: [], speakers: [:], folder: nil),
        ]
        let result: MeetingAnalytics = meetingAnalytics(records: records, period: .week, userName: "", now: now, calendar: utcCalendar())
        #expect(result.bucketSize == .day)
        #expect(result.timeline.count == 7)
        #expect(result.timeline.first?.hours == 0.5)
        #expect(result.timeline.last == AnalyticsTimePoint(start: utcCalendar().startOfDay(for: now), hours: 1.5, meetings: 1, openTasks: 1, completedTasks: 1))
        #expect(result.timeline.dropFirst().dropLast().allSatisfy { $0.meetings == 0 && $0.hours == 0 })
        #expect(meetingAnalytics(records: records, period: .quarter, userName: "", now: now, calendar: utcCalendar()).bucketSize == .week)
    }

    // Isı haritası ilk ve son saat arasını her gün için doldurur; satırlar Pazartesi'den başlar.
    @Test func heatmapCoversHourRange() {
        let records: [MeetingRecord] = [
            meeting(id: "a", daysAgo: 0, hour: 9, minutes: 30, tasks: [], done: [], speakers: [:], folder: nil),
            meeting(id: "b", daysAgo: 7, hour: 9, minutes: 30, tasks: [], done: [], speakers: [:], folder: nil),
            meeting(id: "c", daysAgo: 1, hour: 11, minutes: 30, tasks: [], done: [], speakers: [:], folder: nil),
        ]
        let cells: [AnalyticsHeatCell] = analyticsHeatmap(meetings: records, calendar: utcCalendar())
        #expect(analyticsWeekdays(calendar: utcCalendar()) == [2, 3, 4, 5, 6, 7, 1])
        #expect(cells.count == 7 * 3)
        // Cuma (6) 09:00 iki toplantı, Perşembe (5) 11:00 bir.
        #expect(cells.first { $0.weekday == 6 && $0.hour == 9 }?.meetings == 2)
        #expect(cells.first { $0.weekday == 5 && $0.hour == 11 }?.meetings == 1)
        #expect(cells.map(\.meetings).reduce(0, +) == 3)
        #expect(analyticsHeatmap(meetings: [], calendar: utcCalendar()).isEmpty)
    }

    // Kişiler: konuşmacı adları ve katılımcılar, toplantı başına bir kez, kullanıcı hariç; çoktan aza.
    @Test func peopleRankByMeetings() {
        let records: [MeetingRecord] = [
            meeting(id: "a", daysAgo: 0, hour: 9, minutes: 30, tasks: [], done: [], speakers: [1: "Ayşe", 2: "Şenol"], folder: nil)
                .with(attendees: ["Ayşe", "Mehmet"]),
            meeting(id: "b", daysAgo: 1, hour: 9, minutes: 30, tasks: [], done: [], speakers: [1: "Ayşe "], folder: nil),
        ]
        #expect(analyticsPeople(meetings: records, userName: "Şenol Doğan") == [
            AnalyticsRankedName(name: "Ayşe", meetings: 2), AnalyticsRankedName(name: "Mehmet", meetings: 1),
        ])
    }

    // Konuşmacının ilk adı aynı toplantıdaki katılımcıyla birleşir; Kişiler'deki gibi konuşmacı adıyla sayılır.
    @Test func speakerFirstNameMergesWithAttendee() {
        let record: MeetingRecord = meeting(id: "a", daysAgo: 0, hour: 9, minutes: 30, tasks: [], done: [], speakers: [1: "Elif", 2: "Jonas"], folder: nil)
            .with(attendees: ["Elif Kaya"])
        #expect(analyticsPeople(meetings: [record], userName: "") == [
            AnalyticsRankedName(name: "Elif", meetings: 1), AnalyticsRankedName(name: "Jonas", meetings: 1),
        ])
    }

    // Klasörler büyük/küçük harf duyarsız; şablonlar hepsi genelse boş, değilse çoktan aza.
    @Test func foldersAndTemplates() {
        let a: MeetingRecord = meeting(id: "a", daysAgo: 0, hour: 9, minutes: 30, tasks: [], done: [], speakers: [:], folder: "Sales")
        let b: MeetingRecord = meeting(id: "b", daysAgo: 1, hour: 9, minutes: 30, tasks: [], done: [], speakers: [:], folder: "sales")
        let c: MeetingRecord = meeting(id: "c", daysAgo: 2, hour: 9, minutes: 30, tasks: [], done: [], speakers: [:], folder: nil)
        #expect(analyticsFolders(meetings: [a, b, c]) == [AnalyticsRankedName(name: "Sales", meetings: 2)])
        #expect(analyticsTemplates(meetings: [a, b, c]).isEmpty)
        let oneOnOne: NoteTemplate = NoteTemplate(kind: .oneOnOne, customInstructions: "")
        #expect(analyticsTemplates(meetings: [a.with(template: oneOnOne), b.with(template: oneOnOne), c]) == [
            AnalyticsTemplateCount(kind: .oneOnOne, meetings: 2), AnalyticsTemplateCount(kind: .general, meetings: 1),
        ])
    }

    // Değişim oranı; önceki sıfırsa tanımsız.
    @Test func changeRatio() {
        #expect(analyticsChange(current: 15, previous: 10) == 0.5)
        #expect(analyticsChange(current: 5, previous: 10) == -0.5)
        #expect(analyticsChange(current: 5, previous: 0) == nil)
    }
}

@Suite struct AnalyticsMyTasksTests {
    // Kullanıcının görevleri Görevlerim'deki gibi sayılır: adı kullanıcının adı olan konuşmacının görevi de onundur.
    @Test func namedSpeakerTaskCountsAsMine() {
        let speakerTask: NoteTask = NoteTask(owner: "Konuşmacı 2", description: "Book room", dueDate: nil, isMine: false)
        let record: MeetingRecord = meeting(
            id: "a", daysAgo: 0, hour: 9, minutes: 30, tasks: [taskA, taskB, speakerTask], done: [], speakers: [2: "Şenol"], folder: nil
        )
        let totals: AnalyticsTotals = analyticsTotals(meetings: [record], userName: "Şenol Doğan")
        #expect(totals.tasksCreated == 3)
        #expect(totals.tasksMine == myTasks(meetings: [record], userName: "Şenol Doğan").count)
    }
}

@Suite struct MemoCacheTests {
    // Girdi aynıyken hesap yeniden yapılmaz; girdi değişince yapılır.
    @Test func recomputesOnlyWhenInputChanges() {
        var calls: Int = 0
        let compute: (Int) -> String = { (value: Int) -> String in
            calls += 1
            return String(value)
        }
        let first: (output: String, cache: MemoCache<Int, String>) = memoized(input: 1, cache: .empty, compute: compute)
        let second: (output: String, cache: MemoCache<Int, String>) = memoized(input: 1, cache: first.cache, compute: compute)
        let third: (output: String, cache: MemoCache<Int, String>) = memoized(input: 2, cache: second.cache, compute: compute)
        #expect(first.output == "1")
        #expect(second.output == "1")
        #expect(third.output == "2")
        #expect(calls == 2)
    }
}
