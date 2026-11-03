import Foundation
import Testing
@testable import AINotepadCore

@Suite struct RelatedOpenTasksTests {
    private let base: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(id: String, title: String, daysAgo: Double, eventID: String?, attendees: [String]?, tasks: [NoteTask]) -> MeetingRecord {
        let plain: MeetingRecord = MeetingRecord(
            id: id, title: title, startedAt: base.addingTimeInterval(-daysAgo * 86400), endedAt: nil, language: .finnish, status: .done,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Not: \(title)", summary: "S", decisions: [], tasks: tasks, glossary: []),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let linked: MeetingRecord = eventID.map { plain.with(calendarEventID: $0) } ?? plain
        return attendees.map { linked.with(attendees: $0) } ?? linked
    }

    private func task(_ description: String, mine: Bool) -> NoteTask {
        NoteTask(owner: mine ? "Sen" : "Aino", description: description, dueDate: nil, isMine: mine)
    }

    // Dizinin kimliği etkinlik kimliğinden başlangıç saniyesi atılarak çıkar.
    @Test func seriesIDDropsStartSuffix() {
        #expect(calendarSeriesID(eventID: "ABC:123-1800000000") == "ABC:123")
        #expect(calendarSeriesID(eventID: "A-B-C-1800000000") == "A-B-C")
        #expect(calendarSeriesID(eventID: "ornek-x") == "ornek-x")
        #expect(calendarSeriesID(eventID: "-123") == "-123")
        #expect(calendarSeriesID(eventID: "plain") == "plain")
    }

    // İlgili: aynı dizi, aynı başlık ya da katılımcıların yarısı; takvime bağlanmamış kayıt hiç sayılmaz.
    @Test func relatedMeetingRules() {
        let meeting: CalendarMeeting = CalendarMeeting(
            id: "SERIES-1800000000", title: "Haftalık  Planlama", start: base, end: base.addingTimeInterval(1800), attendees: ["Aino", "Mikko"], joinURL: nil
        )
        #expect(isRelatedMeeting(record: record(id: "1", title: "Başka", daysAgo: 7, eventID: "SERIES-1799395200", attendees: nil, tasks: []), meeting: meeting))
        #expect(isRelatedMeeting(record: record(id: "2", title: "haftalık planlama", daysAgo: 7, eventID: "OTHER-1", attendees: nil, tasks: []), meeting: meeting))
        #expect(isRelatedMeeting(record: record(id: "3", title: "Başka", daysAgo: 7, eventID: "OTHER-1", attendees: ["mikko", "Liisa"], tasks: []), meeting: meeting))
        // Büyük toplantıda tek ortak kişi yetmez.
        #expect(!isRelatedMeeting(record: record(id: "4", title: "Başka", daysAgo: 7, eventID: "OTHER-1", attendees: ["Mikko", "Liisa", "Pekka", "Kalle", "Anna"], tasks: []), meeting: meeting))
        // Takvime bağlanmamış kayıt (genel "Toplantı" başlığı) başlığı tutsa da sayılmaz.
        #expect(!isRelatedMeeting(record: record(id: "5", title: "Haftalık Planlama", daysAgo: 7, eventID: nil, attendees: nil, tasks: []), meeting: meeting))
    }

    // Açık görevler: önceki ilgili toplantılardan, tamamlananlar hariç; yeni toplantı önce, kullanıcınınkiler önce.
    @Test func openTasksFromRelatedMeetings() {
        let meeting: CalendarMeeting = CalendarMeeting(id: "SERIES-1800000000", title: "Planlama", start: base, end: base.addingTimeInterval(1800), attendees: [], joinURL: nil)
        let done: NoteTask = task("Raporu gönder", mine: true)
        let older: MeetingRecord = togglingTask(
            record: record(id: "older", title: "Planlama", daysAgo: 14, eventID: "SERIES-1798790400", attendees: nil, tasks: [done, task("Bütçeyi gözden geçir", mine: false)]),
            task: done
        )
        let newer: MeetingRecord = record(id: "newer", title: "Planlama", daysAgo: 7, eventID: "SERIES-1799395200", attendees: nil, tasks: [task("Teklifi yaz", mine: false), task("Slaytları hazırla", mine: true)])
        let unrelated: MeetingRecord = record(id: "x", title: "Satış", daysAgo: 1, eventID: "OTHER-1", attendees: nil, tasks: [task("Ara", mine: true)])
        // Kaydın kendisi (şimdi başladı) ve sonraki toplantılar sayılmaz.
        let current: MeetingRecord = record(id: "now", title: "Planlama", daysAgo: 0, eventID: meeting.id, attendees: nil, tasks: [task("Yeni", mine: true)])
        let result: [RelatedOpenTask] = relatedOpenTasks(meeting: meeting, records: [older, unrelated, newer, current], userName: "", before: base)
        #expect(result.map(\.task.description) == ["Slaytları hazırla", "Teklifi yaz", "Bütçeyi gözden geçir"])
        #expect(result.map(\.meetingID) == ["newer", "newer", "older"])
        #expect(result.first?.meetingTitle == "Not: Planlama")
        #expect(Set(result.map(\.id)).count == result.count)
    }
}
