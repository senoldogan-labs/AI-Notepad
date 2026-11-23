import Foundation
import Synchronization

/// A month's name in a note language, lowercased without a trailing dot ("kasım", "nov").
struct MonthName: Sendable, Equatable {
    let name: String
    let month: Int
}

/// Göreli gün sözcüğünün gösterdiği gün: toplantı gününden `offset` gün sonra ya da toplantı günü ya da sonrasındaki
/// ilk `weekday` (1 pazar … 7 cumartesi).
enum RelativeDay: Sendable, Equatable {
    case offset(Int)
    case weekday(Int)
}

/// A day word ("bugün", "tomorrow") or weekday name ("Cuma", "perjantai") split into lowercased words.
struct DayPhrase: Sendable, Equatable {
    let words: [String]
    let day: RelativeDay
}

/// A "this/next <unit>" phrase ("next week", "gelecek ay") split into lowercased words, and its offset (0 this, 1 next).
struct PeriodPhrase: Sendable, Equatable {
    let words: [String]
    let offset: Int
}

/// The words due dates are read with in one note language: month names, day words and weekday names, "this/next week"
/// and "this/next month". They come from the language's calendar and relative date formatter (`dueVocabulary`).
struct DueVocabulary: Sendable {
    let locale: Locale
    /// Long month names (format and standalone forms).
    let longMonths: [MonthName]
    /// Short month names (format and standalone forms).
    let shortMonths: [MonthName]
    /// "Bugün", "yarın" and the weekday names; empty phrases left out.
    let dayPhrases: [DayPhrase]
    /// "Next week" (offset 1) and "this week" (offset 0).
    let weekPhrases: [PeriodPhrase]
    /// "Next month" (offset 1) and "this month" (offset 0).
    let monthPhrases: [PeriodPhrase]
}

/// Metnin sözcükleri, `locale`'de küçük harfle (harf ve rakam dışı ayırır). Saf fonksiyondur.
func dueTokens(text: String, locale: Locale) -> [String] {
    text.lowercased(with: locale).split { (character: Character) -> Bool in !character.isLetter && !character.isNumber }.map(String.init)
}

/// Builds the due-date words of `language` from its formatters. Pure function (depends only on the system's locale
/// data); `dueVocabulary` keeps the result.
func makeDueVocabulary(language: ShareLanguage) -> DueVocabulary {
    let locale: Locale = Locale(identifier: language.rawValue)
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = locale
    let relative: RelativeDateTimeFormatter = RelativeDateTimeFormatter()
    relative.locale = locale
    relative.dateTimeStyle = .named
    relative.unitsStyle = .full
    let monthNames: ([[String]]) -> [MonthName] = { (lists: [[String]]) -> [MonthName] in
        lists.flatMap { (symbols: [String]) -> [MonthName] in
            symbols.enumerated().map { (item: (offset: Int, element: String)) -> MonthName in
                MonthName(name: item.element.lowercased(with: locale).trimmingCharacters(in: CharacterSet(charactersIn: ".")), month: item.offset + 1)
            }
        }
    }
    let dayWords: [DayPhrase] = [0, 1].map { (offset: Int) -> DayPhrase in
        DayPhrase(words: dueTokens(text: relative.localizedString(from: DateComponents(day: offset)), locale: locale), day: .offset(offset))
    }
    let weekdays: [DayPhrase] = [formatter.weekdaySymbols ?? [], formatter.standaloneWeekdaySymbols ?? []].flatMap { (symbols: [String]) -> [DayPhrase] in
        symbols.enumerated().map { (item: (offset: Int, element: String)) -> DayPhrase in
            DayPhrase(words: dueTokens(text: item.element, locale: locale), day: .weekday(item.offset + 1))
        }
    }
    let periodPhrases: (Calendar.Component) -> [PeriodPhrase] = { (unit: Calendar.Component) -> [PeriodPhrase] in
        [1, 0].map { (offset: Int) -> PeriodPhrase in
            var components: DateComponents = DateComponents()
            components.setValue(offset, for: unit)
            return PeriodPhrase(words: dueTokens(text: relative.localizedString(from: components), locale: locale), offset: offset)
        }
    }
    return DueVocabulary(
        locale: locale,
        longMonths: monthNames([formatter.monthSymbols ?? [], formatter.standaloneMonthSymbols ?? []]),
        shortMonths: monthNames([formatter.shortMonthSymbols ?? [], formatter.shortStandaloneMonthSymbols ?? []]),
        dayPhrases: (dayWords + weekdays).filter { !$0.words.isEmpty },
        weekPhrases: periodPhrases(.weekOfMonth),
        monthPhrases: periodPhrases(.month)
    )
}

/// Due-date words already built, by language.
private let dueVocabularies: Mutex<[ShareLanguage: DueVocabulary]> = Mutex([:])

/// The due-date words of `language` (`makeDueVocabulary`), built once per language rather than creating a
/// `DateFormatter` and a `RelativeDateTimeFormatter` for every task the task lists (Home, My tasks) date.
func dueVocabulary(language: ShareLanguage) -> DueVocabulary {
    if let known = dueVocabularies.withLock({ (cache: inout [ShareLanguage: DueVocabulary]) -> DueVocabulary? in cache[language] }) {
        return known
    }
    let built: DueVocabulary = makeDueVocabulary(language: language)
    dueVocabularies.withLock { (cache: inout [ShareLanguage: DueVocabulary]) -> Void in cache[language] = built }
    return built
}
