import Foundation
import Testing
@testable import AINotepadCore

private func record(id: String, startedAt: Date) -> MeetingRecord {
    MeetingRecord(
        id: id, title: id, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1800),
        language: .english, status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct MeetingDaySectionsTests {
    // One group per calendar day, newest first: today, yesterday, then a short dated title; order inside is kept.
    @Test func groupsByDay() throws {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Helsinki"))
        let now: Date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 18)))
        let hour: TimeInterval = 3600
        let records: [MeetingRecord] = [
            record(id: "a", startedAt: now.addingTimeInterval(-2 * hour)),
            record(id: "b", startedAt: now.addingTimeInterval(-3 * hour)),
            record(id: "c", startedAt: now.addingTimeInterval(-24 * hour)),
            record(id: "d", startedAt: now.addingTimeInterval(-72 * hour)),
        ]
        let sections: [MeetingSection] = meetingDaySections(records: records, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(sections.map { $0.meetings.map(\.id) } == [["a", "b"], ["c"], ["d"]])
        #expect(sections[0].title == String(localized: "Bugün"))
        #expect(sections[1].title == String(localized: "Dün"))
        #expect(sections[2].title.contains("11"))
    }

    // The meeting list: today, yesterday, the previous 7 days, then one section per month; order inside is kept.
    @Test func meetingListGroupsByRecencyThenMonth() throws {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Helsinki"))
        let now: Date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 18)))
        let day: TimeInterval = 24 * 3600
        let records: [MeetingRecord] = [
            record(id: "today", startedAt: now.addingTimeInterval(-3600)),
            record(id: "yesterday", startedAt: now.addingTimeInterval(-day)),
            record(id: "week", startedAt: now.addingTimeInterval(-3 * day)),
            record(id: "nov-a", startedAt: now.addingTimeInterval(-10 * day)),
            record(id: "nov-b", startedAt: now.addingTimeInterval(-12 * day)),
            record(id: "oct-a", startedAt: now.addingTimeInterval(-30 * day)),
            record(id: "oct-b", startedAt: now.addingTimeInterval(-40 * day)),
        ]
        let sections: [MeetingSection] = meetingSections(records: records, now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(sections.map { $0.meetings.map(\.id) } == [["today"], ["yesterday"], ["week"], ["nov-a", "nov-b"], ["oct-a", "oct-b"]])
        #expect(sections.map(\.title).suffix(2) == ["November 2026", "October 2026"])
        #expect(sections.map(\.id) == sections.map(\.title))
    }
}
