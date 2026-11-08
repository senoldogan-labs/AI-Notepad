import Foundation
import Testing
@testable import AINotepadCore

@Suite struct EngagementNotificationsTests {
    private let calendar: Calendar = {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func record(id: String, startedAt: Date, status: MeetingStatus, tasks: [NoteTask], decisions: [String]) -> MeetingRecord {
        MeetingRecord(
            id: id, title: "Kayıt \(id)", startedAt: startedAt, endedAt: nil, language: .finnish, status: status, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Bütçe \(id)", summary: "S", decisions: decisions, tasks: tasks, glossary: []).with(language: .finnish),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    // Not hazır: yalnız not yazıldıysa; gövdede kullanıcıya düşen görev ve karar sayısı, ikisi de yoksa kısa cümle.
    @Test func noteReadyCountsMyTasksAndDecisionsOnlyWhenDone() {
        let tasks: [NoteTask] = [
            NoteTask(owner: "Sen", description: "Slaytlar", dueDate: nil, isMine: true),
            NoteTask(owner: "Aino", description: "Bütçe", dueDate: nil, isMine: false),
        ]
        let done: MeetingRecord = record(id: "1", startedAt: date(12, 15, 10), status: .done, tasks: tasks, decisions: ["A", "B"])
        let ready: EngagementNotification? = noteReadyNotification(record: done, userName: "")
        #expect(ready?.title == "Bütçe 1 notu hazır")
        #expect(ready?.body == "Sana 1 görev · 2 karar")
        #expect(ready?.meetingID == "1")
        #expect(ready?.fireAt == nil)
        #expect(noteReadyNotification(record: record(id: "2", startedAt: date(12, 15, 10), status: .done, tasks: [], decisions: []), userName: "")?.body
            == "Özet ve görevler hazır.")
        #expect(noteReadyNotification(record: record(id: "3", startedAt: date(12, 15, 10), status: .failed, tasks: tasks, decisions: []), userName: "") == nil)
    }

    // Görev günü: yalnız kullanıcının açık, günü çözülen ve saati geçmemiş görevleri; o gün 09:00, en yakın önce, sınırlı.
    @Test func taskDueNotificationsAreNearestFirstAndSkipDoneOrPast() {
        let tasks: [NoteTask] = [
            NoteTask(owner: "Sen", description: "Perjantain työ", dueDate: "perjantaina", isMine: true),
            NoteTask(owner: "Sen", description: "Huominen työ", dueDate: "huomenna", isMine: true),
            NoteTask(owner: "Sen", description: "Valmis", dueDate: "huomenna", isMine: true),
            NoteTask(owner: "Sen", description: "Epämääräinen", dueDate: "ensi viikolla", isMine: true),
            NoteTask(owner: "Aino", description: "Ainon työ", dueDate: "huomenna", isMine: false),
            NoteTask(owner: "Sen", description: "Mennyt", dueDate: "14.12.2026", isMine: true),
        ]
        let meeting: MeetingRecord = togglingTask(
            record: record(id: "m", startedAt: date(12, 15, 10), status: .done, tasks: tasks, decisions: []), task: tasks[2]
        )
        let now: Date = date(12, 15, 12)
        let planned: [EngagementNotification] = taskDueNotifications(records: [meeting], userName: "", now: now, calendar: calendar, limit: 10)
        #expect(planned.map(\.title) == ["Bugün: Huominen työ", "Bugün: Perjantain työ"])
        #expect(planned.first?.fireAt == DateComponents(year: 2026, month: 12, day: 16, hour: 9, minute: 0))
        #expect(planned.first?.subtitle == "Bütçe m")
        #expect(planned.first?.identifier == EngagementNotificationID.taskDuePrefix + "m." + taskKey(task: tasks[1]))
        #expect(planned.first?.taskKey == taskKey(task: tasks[1]))
        #expect(taskDueNotifications(records: [meeting], userName: "", now: now, calendar: calendar, limit: 1).map(\.title) == ["Bugün: Huominen työ"])
        // 09:00'u geçmiş gün kurulmaz.
        #expect(taskDueNotifications(records: [meeting], userName: "", now: date(12, 16, 10), calendar: calendar, limit: 10).map(\.title) == ["Bugün: Perjantain työ"])
    }

    // Haftalık özet: sonraki pazartesi 09:00, en çok 3 açık görev ve önceki haftanın toplantı sayısı; ikisi de yoksa yok.
    @Test func weeklySummaryListsOpenTasksAndLastWeekMeetings() {
        let tasks: [NoteTask] = ["Yksi", "Kaksi", "Kolme", "Neljä"].map { NoteTask(owner: "Sen", description: $0, dueDate: nil, isMine: true) }
        let meetings: [MeetingRecord] = [
            record(id: "a", startedAt: date(12, 16, 10), status: .done, tasks: tasks, decisions: []),
            record(id: "b", startedAt: date(12, 1, 10), status: .done, tasks: [], decisions: []),
        ]
        // 17.12.2026 perşembe: sonraki pazartesi 21.12.
        let weekly: EngagementNotification? = weeklySummaryNotification(records: meetings, userName: "", now: date(12, 17, 12), calendar: calendar)
        #expect(weekly?.title == "Bu hafta: 4 açık görev")
        #expect(weekly?.body == "• Yksi\n• Kaksi\n• Kolme\nGeçen hafta: 1 toplantı")
        #expect(weekly?.fireAt == DateComponents(year: 2026, month: 12, day: 21, hour: 9, minute: 0))
        #expect(weekly?.identifier == EngagementNotificationID.weeklySummary)
        let quiet: [MeetingRecord] = [record(id: "c", startedAt: date(11, 1, 10), status: .done, tasks: [], decisions: [])]
        #expect(weeklySummaryNotification(records: quiet, userName: "", now: date(12, 17, 12), calendar: calendar) == nil)
    }

    // Kayıtsız hafta: son kayıttan 7 gün sonra 10:00'da bir kez; o gün takvimde 10:00'dan sonraki toplantı yazılır; anı
    // geçmişse kurulmaz.
    @Test func inactiveReminderFiresOnceSevenDaysAfterLastRecording() {
        let meetings: [MeetingRecord] = [
            record(id: "a", startedAt: date(12, 1, 15), status: .done, tasks: [], decisions: []),
            record(id: "b", startedAt: date(12, 3, 9), status: .done, tasks: [], decisions: []),
        ]
        let upcoming: [CalendarMeeting] = [
            CalendarMeeting(id: "early", title: "Aamu", start: date(12, 10, 8), end: date(12, 10, 9), attendees: [], joinURL: nil),
            CalendarMeeting(id: "next", title: "Viikkopalaveri", start: date(12, 10, 14), end: date(12, 10, 15), attendees: [], joinURL: nil),
        ]
        let locale: Locale = Locale(identifier: "fi_FI")
        let reminder: EngagementNotification? = inactiveReminderNotification(records: meetings, calendarMeetings: upcoming, now: date(12, 4, 12), calendar: calendar, locale: locale)
        #expect(reminder?.fireAt == DateComponents(year: 2026, month: 12, day: 10, hour: 10, minute: 0))
        #expect(reminder?.body.contains("Viikkopalaveri") == true)
        #expect(inactiveReminderNotification(records: meetings, calendarMeetings: [], now: date(12, 4, 12), calendar: calendar, locale: locale)?.body
            == "Son kaydının üzerinden bir hafta geçti; toplantı başlarken kayda başlaman yeterli.")
        #expect(inactiveReminderNotification(records: meetings, calendarMeetings: [], now: date(12, 10, 11), calendar: calendar, locale: locale) == nil)
        #expect(inactiveReminderNotification(records: [], calendarMeetings: [], now: date(12, 4, 12), calendar: calendar, locale: locale) == nil)
    }

    // Plan kapalı türleri içermez; planda olmayan bekleyen bildirimler (yalnız bu bildirimlerden) kaldırılır.
    @Test func planHonoursSettingsAndStaleIdentifiersAreOnlyEngagementOnes() {
        let tasks: [NoteTask] = [NoteTask(owner: "Sen", description: "Huominen työ", dueDate: "huomenna", isMine: true)]
        let meetings: [MeetingRecord] = [record(id: "m", startedAt: date(12, 15, 10), status: .done, tasks: tasks, decisions: [])]
        let input: (EngagementSettings) -> EngagementPlanInput = { (settings: EngagementSettings) -> EngagementPlanInput in
            EngagementPlanInput(
                records: meetings, userName: "", settings: settings, calendarMeetings: [], otherPendingCount: 3, trial: nil, now: date(12, 15, 12),
                calendar: calendar, locale: Locale(identifier: "fi_FI")
            )
        }
        let all: [EngagementNotification] = plannedEngagementNotifications(input: input(EngagementSettings(noteReady: true, taskDue: true, weeklySummary: true, inactive: true, trialReminder: true)))
        #expect(all.map(\.categoryIdentifier) == [
            EngagementNotificationID.taskDueCategory, EngagementNotificationID.weeklySummaryCategory, EngagementNotificationID.inactiveCategory,
        ])
        let onlyWeekly: [EngagementNotification] = plannedEngagementNotifications(input: input(EngagementSettings(noteReady: true, taskDue: false, weeklySummary: true, inactive: false, trialReminder: false)))
        #expect(onlyWeekly.map(\.identifier) == [EngagementNotificationID.weeklySummary])
        let pending: [String] = all.map(\.identifier) + ["meeting.reminder.x", "recording-limit-warning"]
        #expect(staleEngagementIdentifiers(pending: pending, planned: onlyWeekly).sorted() == [EngagementNotificationID.inactive, all[0].identifier].sorted())
        #expect(taskDueBudget(otherPendingCount: 3) == pendingNotificationLimit - pendingNotificationReserve - 3 - 2)
        #expect(taskDueBudget(otherPendingCount: 100) == 0)
    }

    // Bildirimden "Tamamlandı" görevi işaretler; zaten tamamlandıysa geri açmaz.
    @Test func markingTaskDoneIsIdempotent() {
        let task: NoteTask = NoteTask(owner: "Sen", description: "Slaytlar", dueDate: nil, isMine: true)
        let meeting: MeetingRecord = record(id: "m", startedAt: date(12, 15, 10), status: .done, tasks: [task], decisions: [])
        let key: String = taskKey(task: task)
        let done: MeetingRecord = markingTaskDone(record: meeting, key: key)
        #expect(isTaskDone(record: done, task: task))
        #expect(markingTaskDone(record: done, key: key) == done)
        #expect(hasTask(record: meeting, key: key))
        #expect(!hasTask(record: meeting, key: "başka|iş"))
    }
}

@Suite struct EngagementRouteTests {
    // Görev bildiriminde "Tamamlandı" görevi işaretler, dokunma toplantıyı açar; başka bildirimler bu yoldan geçmez.
    @Test func responsesRouteByCategoryAndAction() {
        let tap: String = "com.apple.UNNotificationDefaultActionIdentifier"
        #expect(engagementRoute(categoryIdentifier: EngagementNotificationID.taskDueCategory, actionIdentifier: EngagementNotificationID.taskDoneAction, meetingID: "m", taskKey: "k")
            == .completeTask(meetingID: "m", taskKey: "k"))
        #expect(engagementRoute(categoryIdentifier: EngagementNotificationID.taskDueCategory, actionIdentifier: tap, meetingID: "m", taskKey: "k") == .openMeeting("m"))
        #expect(engagementRoute(categoryIdentifier: EngagementNotificationID.noteReadyCategory, actionIdentifier: tap, meetingID: "m", taskKey: nil) == .openMeeting("m"))
        #expect(engagementRoute(categoryIdentifier: EngagementNotificationID.weeklySummaryCategory, actionIdentifier: tap, meetingID: nil, taskKey: nil) == .openTasks)
        #expect(engagementRoute(categoryIdentifier: EngagementNotificationID.inactiveCategory, actionIdentifier: tap, meetingID: nil, taskKey: nil) == .openRecording)
        #expect(engagementRoute(categoryIdentifier: "meeting.start", actionIdentifier: tap, meetingID: "m", taskKey: nil) == nil)
    }
}
