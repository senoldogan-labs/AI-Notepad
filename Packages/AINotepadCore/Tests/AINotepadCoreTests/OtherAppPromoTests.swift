import Foundation
import Testing
@testable import AINotepadCore

@Suite struct OtherAppPromoTests {
    private func calendar(timeZone: String) throws -> Calendar {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZone))
        return calendar
    }

    @Test func remindsTomorrowMorningEvenBeforeNineToday() throws {
        let helsinki: Calendar = try calendar(timeZone: "Europe/Helsinki")
        // 07:30 Helsinki time: the reminder is still the next day, not today at 09:00.
        let now: Date = try #require(helsinki.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 7, minute: 30)))
        let reminder: Date = try otherAppReminderDate(now: now, calendar: helsinki, hour: 9)
        #expect(helsinki.dateComponents([.year, .month, .day, .hour, .minute], from: reminder) == DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 0))
    }

    @Test func crossesMonthEndLateAtNight() throws {
        let newYork: Calendar = try calendar(timeZone: "America/New_York")
        let now: Date = try #require(newYork.date(from: DateComponents(year: 2026, month: 11, day: 30, hour: 23, minute: 50)))
        let reminder: Date = try otherAppReminderDate(now: now, calendar: newYork, hour: 9)
        #expect(newYork.dateComponents([.year, .month, .day, .hour], from: reminder) == DateComponents(year: 2026, month: 12, day: 1, hour: 9))
    }
}
