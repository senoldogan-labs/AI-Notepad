import Foundation

/// Şirkete sayılmayan ücretsiz e-posta sağlayıcıları. `.*` ile biten kalıp o adın her uzantısını kapsar
/// (`hotmail.*` → hotmail.com, hotmail.fr, hotmail.co.uk).
public let freeMailDomainPatterns: [String] = [
    "gmail.com", "googlemail.com", "outlook.com", "hotmail.*", "live.com", "msn.com", "icloud.com", "me.com", "mac.com",
    "yahoo.*", "aol.com", "proton.me", "protonmail.com", "gmx.*", "yandex.*", "mail.ru",
]

/// Bir şirketin bir toplantısı: o toplantıda konuşan kişileri ve toplam konuşma süreleri.
public struct CompanyMeeting: Sendable, Equatable {
    public let meetingID: String
    public let title: String
    public let date: Date
    /// Şirketin bu toplantıdaki kişileri (ad sırasıyla).
    public let people: [String]
    public let seconds: Double
}

/// E-posta alan adına göre gruplanmış kişiler (Kişiler › Şirketler).
public struct CompanySummary: Sendable, Equatable, Identifiable {
    /// Küçük harfli alan adı (ör. "nordia.fi").
    public let domain: String
    /// Görünen ad: uzantısız, baş harfi büyük alan adı (ör. "Nordia").
    public let name: String
    /// Kullanıcının kendi şirketi (hesabının e-posta alan adı).
    public let isOwn: Bool
    /// Ad sırasıyla.
    public let people: [PersonSummary]
    /// Kişilerinin toplantıları, her toplantı bir kez; yeniden eskiye.
    public let meetings: [CompanyMeeting]

    public var id: String { domain }
    public var meetingCount: Int { meetings.count }
    public var totalSeconds: Double { people.map(\.totalSeconds).reduce(0, +) }
    /// Son toplantının tarihi; toplantısı yoksa nil.
    public var lastSeen: Date? { meetings.first?.date }
}

/// E-postanın küçük harfli alan adı; geçerli bir adres değilse (yerel kısım ya da noktalı alan adı yoksa) nil.
/// Saf fonksiyondur.
public func emailDomain(email: String) -> String? {
    let trimmed: String = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let at = trimmed.lastIndex(of: "@"), at > trimmed.startIndex else {
        return nil
    }
    let domain: String = String(trimmed[trimmed.index(after: at)...])
    let labels: [Substring] = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), !domain.contains(" ") else {
        return nil
    }
    return domain
}

/// Alan adı ücretsiz bir e-posta sağlayıcısının mı (bkz. `freeMailDomainPatterns`). Saf fonksiyondur.
public func isFreeMailDomain(domain: String) -> Bool {
    freeMailDomainPatterns.contains { (pattern: String) -> Bool in
        if pattern.hasSuffix(".*") {
            return domain.hasPrefix(String(pattern.dropLast(1)))
        }
        return domain == pattern
    }
}

/// Alan adının görünen adı: uzantı (ve "co.uk", "com.tr" gibi ikinci düzey uzantı) atılır, kalan son parçanın baş
/// harfi büyütülür ("eu.nordia.fi" → "Nordia"). Saf fonksiyondur.
public func companyName(domain: String) -> String {
    let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
    let labels: [String] = domain.split(separator: ".").map(String.init)
    let withoutTLD: [String] = Array(labels.dropLast())
    let core: [String] = withoutTLD.count >= 2 && secondLevel.contains(withoutTLD[withoutTLD.count - 1]) ? Array(withoutTLD.dropLast()) : withoutTLD
    guard let name = core.last, let first = name.first else {
        return domain
    }
    return first.uppercased() + name.dropFirst()
}

/// Şirketler: e-postası olan kişiler alan adına göre gruplanır; ücretsiz sağlayıcılar ve e-postasız kişiler hiçbir
/// şirkete girmez. Kullanıcının kendi alan adı (`ownEmail`'den; yoksa nil) dahildir ve işaretlenir. Toplantı sayısı
/// kişilerin toplantılarının tekil sayısıdır. Son görüldüğü toplantıya göre yeniden eskiye, toplantısızlar sonda ada
/// göre sıralanır. Saf fonksiyondur.
public func companies(people: [PersonSummary], ownEmail: String?) -> [CompanySummary] {
    let ownDomain: String? = ownEmail.flatMap { emailDomain(email: $0) }
    let entries: [(domain: String, person: PersonSummary)] = people.compactMap { (person: PersonSummary) -> (domain: String, person: PersonSummary)? in
        guard let domain = emailDomain(email: person.email), !isFreeMailDomain(domain: domain) else {
            return nil
        }
        return (domain: domain, person: person)
    }
    let grouped: [String: [PersonSummary]] = Dictionary(grouping: entries) { $0.domain }.mapValues { $0.map(\.person) }
    let summaries: [CompanySummary] = grouped.map { (entry: (key: String, value: [PersonSummary])) -> CompanySummary in
        let members: [PersonSummary] = entry.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return CompanySummary(
            domain: entry.key, name: companyName(domain: entry.key), isOwn: entry.key == ownDomain, people: members,
            meetings: companyMeetings(people: members)
        )
    }
    return summaries.sorted { (lhs: CompanySummary, rhs: CompanySummary) -> Bool in
        switch (lhs.lastSeen, rhs.lastSeen) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return lhs.domain < rhs.domain
        }
    }
}

/// Kişilerin toplantıları, her toplantı bir kez (kişileri ve konuşma süreleri toplanır); yeniden eskiye. Saf fonksiyondur.
private func companyMeetings(people: [PersonSummary]) -> [CompanyMeeting] {
    let rows: [(person: String, meeting: PersonMeeting)] = people.flatMap { (person: PersonSummary) -> [(person: String, meeting: PersonMeeting)] in
        person.meetings.map { (person: person.name, meeting: $0) }
    }
    return Dictionary(grouping: rows) { $0.meeting.meetingID }.values
        .compactMap { (group: [(person: String, meeting: PersonMeeting)]) -> CompanyMeeting? in
            group.first.map { (first: (person: String, meeting: PersonMeeting)) -> CompanyMeeting in
                CompanyMeeting(
                    meetingID: first.meeting.meetingID, title: first.meeting.title, date: first.meeting.date, people: group.map(\.person),
                    seconds: group.map(\.meeting.seconds).reduce(0, +)
                )
            }
        }
        .sorted { $0.date != $1.date ? $0.date > $1.date : $0.meetingID < $1.meetingID }
}
