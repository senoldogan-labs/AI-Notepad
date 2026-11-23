import Foundation

/// Toplantı listesinin tarih grubu.
public struct MeetingSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let meetings: [MeetingRecord]

    public init(id: String, title: String, meetings: [MeetingRecord]) {
        self.id = id
        self.title = title
        self.meetings = meetings
    }
}

/// Toplantıları tarihe göre gruplar (en yeni önce): Bugün, Dün, Önceki 7 gün (2–6 gün önce; takvim haftasına bağlı
/// değil), sonra ay ve yıl. Mac listesi ve iPhone kartları aynı grupları gösterir. Saf fonksiyondur.
public func meetingSections(records: [MeetingRecord], now: Date, calendar: Calendar, locale: Locale) -> [MeetingSection] {
    let today: Date = calendar.startOfDay(for: now)
    // A month's title is formatted once, not once per meeting in it.
    var monthTitles: [Int: String] = [:]
    let title: (MeetingRecord) -> String = { (record: MeetingRecord) -> String in
        let day: Date = calendar.startOfDay(for: record.startedAt)
        let days: Int = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ..<1: return String(localized: "Bugün")
        case 1: return String(localized: "Dün")
        case 2..<7: return String(localized: "Önceki 7 gün")
        default:
            let month: DateComponents = calendar.dateComponents([.year, .month], from: record.startedAt)
            let key: Int = (month.year ?? 0) * 100 + (month.month ?? 0)
            if let known = monthTitles[key] {
                return known
            }
            let formatted: String = record.startedAt.formatted(Date.FormatStyle().month(.wide).year().locale(locale)).capitalized(with: locale)
            monthTitles[key] = formatted
            return formatted
        }
    }
    return groupedSections(records: records) { (record: MeetingRecord) -> MeetingSectionKey in
        let name: String = title(record)
        return MeetingSectionKey(id: name, title: name)
    }
}

/// A meeting's section: its id and title.
private struct MeetingSectionKey {
    let id: String
    let title: String
}

/// Consecutive meetings with the same section id in one section (titled by its first meeting), in order. Appends in
/// place, so a long month stays linear. Pure function (when `section` is).
private func groupedSections(records: [MeetingRecord], section: (MeetingRecord) -> MeetingSectionKey) -> [MeetingSection] {
    var keys: [MeetingSectionKey] = []
    var groups: [[MeetingRecord]] = []
    for record in records {
        let key: MeetingSectionKey = section(record)
        if let last = keys.last, last.id == key.id {
            groups[groups.count - 1].append(record)
        } else {
            keys.append(key)
            groups.append([record])
        }
    }
    return zip(keys, groups).map { (item: (key: MeetingSectionKey, meetings: [MeetingRecord])) -> MeetingSection in
        MeetingSection(id: item.key.id, title: item.key.title, meetings: item.meetings)
    }
}

/// Toplantıları güne göre gruplar (en yeni önce; kayıt sırası korunur): Bugün, Dün, sonra gün adıyla kısa tarih
/// ("11 Kas Çar"). Mac ana sayfasındaki son toplantılar listesi. Saf fonksiyondur.
public func meetingDaySections(records: [MeetingRecord], now: Date, calendar: Calendar, locale: Locale) -> [MeetingSection] {
    let today: Date = calendar.startOfDay(for: now)
    return groupedSections(records: records) { (record: MeetingRecord) -> MeetingSectionKey in
        let day: Date = calendar.startOfDay(for: record.startedAt)
        let days: Int = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let name: String = switch days {
        case ..<1: String(localized: "Bugün")
        case 1: String(localized: "Dün")
        default: record.startedAt.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).day().month(.abbreviated).weekday(.abbreviated)
        )
        }
        return MeetingSectionKey(id: String(Int(day.timeIntervalSince1970)), title: name)
    }
}

/// Mac toplantı listesinin süzgeci.
public enum MeetingListFilter: String, Sendable, CaseIterable {
    case all
    /// Notunda sana düşen görev olanlar.
    case myTasks
    /// Hata veren ya da yarıda kalan (yeniden işlenmesi gereken) toplantılar.
    case problems
}

/// Süzgece uyan toplantılar, sıra korunur; "görevlerim" konuşmacı adlarıyla kullanıcıya düşen görevleri de sayar
/// (`namedTasks`; notun geri kalanı adlandırılmaz). Saf fonksiyondur.
public func filterMeetings(records: [MeetingRecord], listFilter: MeetingListFilter, userName: String) -> [MeetingRecord] {
    switch listFilter {
    case .all:
        records
    case .myTasks:
        records.filter { (record: MeetingRecord) -> Bool in
            namedTasks(record: record, userName: userName).contains(where: \.isMine)
        }
    case .problems:
        records.filter { (record: MeetingRecord) -> Bool in record.status == .failed || record.status == .interrupted }
    }
}
