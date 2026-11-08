import Foundation

/// Sor'un kapsamı: soru hangi toplantılara sorulur. Her Sor alanının üstündeki kapsam çipi bunu gösterir; varsayılanı
/// bulunulan yerden gelir (toplantı sayfası bu toplantı, klasör görünümü bu klasör, kişi sayfası bu kişi, Sor sayfası
/// tüm toplantılar). Sorulan her tur kapsamıyla saklanır (`AskConversationTurn.scope`).
public enum AskScope: Hashable, Sendable, Codable {
    /// Bütün toplantılar (arşivde aranır).
    case allMeetings
    /// Tek toplantı (kimliği).
    case meeting(id: String)
    /// Bir klasördeki toplantılar (klasörün adı; büyük/küçük harf duyarsız).
    case folder(name: String)
    /// Bir kişinin konuştuğu toplantılar (konuşmacıya verilen ad; büyük/küçük harf duyarsız).
    case person(name: String)
    /// Bugünle birlikte son `days` gündeki toplantılar.
    case lastDays(days: Int)
}

/// Kapsam menüsündeki tarih aralıkları (gün).
public let askScopeDayRanges: [Int] = [7, 30]

/// Kapsamda sorulacak toplantı yok (klasör boşaldı, kişinin toplantısı yok, toplantı silindi, aralıkta toplantı yok):
/// soru sorulmadan nedeni sohbette görünür; kapsam sessizce tüm arşive genişlemez.
public enum AskScopeError: Error, Sendable, Equatable {
    case noMeetings(scope: AskScope)
}

/// Kapsamdaki, Sor'un okuyabileceği (`isMentionableMeeting`) toplantılar, en yeni önce. Tüm toplantılar kapsamında
/// bütün okunabilir toplantılar. Örnek toplantı (karşılamadaki deneme) yalnız kendisi seçilince (bu toplantı) okunur:
/// klasör, kişi, tarih aralığı ve tüm toplantılar onu okumaz (cevaba kurgusal içerik karışmasın, sohbet saklanabilsin). Kişi kapsamı Kişiler sayfasıyla aynı kuraldadır: konuşmacılarından birine bu ad
/// verilmiş toplantılar (`peopleDirectory`). Son günler kapsamı `now`'ın günüyle birlikte `days` takvim günüdür. Saf
/// fonksiyondur.
public func askScopeMeetings(scope: AskScope, records: [MeetingRecord], now: Date, calendar: Calendar) -> [MeetingRecord] {
    let mentionable: [MeetingRecord] = newestFirst(records: records).filter { isMentionableMeeting(record: $0) }
    let readable: [MeetingRecord] = realMeetings(records: mentionable)
    switch scope {
    case .allMeetings:
        return readable
    case .meeting(let id):
        return mentionable.filter { $0.id == id }
    case .folder(let name):
        return meetingsInFolder(records: readable, folder: name)
    case .person(let name):
        let wanted: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return readable.filter { (record: MeetingRecord) -> Bool in
            record.speakerNames.values.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(wanted) == .orderedSame }
        }
    case .lastDays(let days):
        guard let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: calendar.startOfDay(for: now)) else {
            preconditionFailure("Takvim \(days) gün öncesini hesaplayamadı")
        }
        return readable.filter { $0.startedAt >= start }
    }
}

/// Sorunun okuyacağı toplantılar: `@` ile etiketlenenler varsa yalnız onlar (biri arşivde yoksa
/// `ArchiveScopeError.meetingsNotFound`); yoksa kapsam tüm toplantılarsa nil (bütün arşivde aranır); yoksa kapsamdaki
/// toplantılar (`askScopeMeetings`; hiç yoksa `AskScopeError.noMeetings`). Saf fonksiyondur.
public func askTargetMeetings(scope: AskScope, mentionIDs: [String], records: [MeetingRecord], now: Date, calendar: Calendar) throws -> [MeetingRecord]? {
    if !mentionIDs.isEmpty {
        return try archiveScope(records: records, meetingIDs: mentionIDs)
    }
    if scope == .allMeetings {
        return nil
    }
    let scoped: [MeetingRecord] = askScopeMeetings(scope: scope, records: records, now: now, calendar: calendar)
    guard !scoped.isEmpty else {
        throw AskScopeError.noMeetings(scope: scope)
    }
    return scoped
}

/// Kapsam menüsünün ilk bölümü: bulunulan yerin kapsamı (varsayılan), tüm toplantılar, toplantı sayfasında o
/// toplantının klasörü ve adı verilmiş en çok üç konuşmacısı, sonra tarih aralıkları; her biri bir kez, seçili kapsam
/// listede yoksa (geçmişten açılan sohbet) ikinci sırada. Klasör ve kişi listelerinin tamamı menünün alt
/// menülerindedir. Saf fonksiyondur.
public func askScopeOptions(context: AskScope, selected: AskScope, contextMeeting: MeetingRecord?, userName: String) -> [AskScope] {
    // Örnek toplantının klasörü ve kurgusal konuşmacıları kapsam olarak önerilmez.
    let meetingScopes: [AskScope] = contextMeeting.flatMap { (record: MeetingRecord) -> MeetingRecord? in record.isSampleMeeting ? nil : record }.map { (record: MeetingRecord) -> [AskScope] in
        let folder: [AskScope] = record.folder.map { [AskScope.folder(name: $0)] } ?? []
        let people: [AskScope] = record.speakerNames.keys.sorted()
            .compactMap { record.speakerNames[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(userName) != .orderedSame }
            .reduce(into: [String]()) { (names: inout [String], name: String) -> Void in
                if !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    names.append(name)
                }
            }
            .prefix(3)
            .map { AskScope.person(name: $0) }
        return folder + people
    } ?? []
    let ordered: [AskScope] = [context, selected, .allMeetings] + meetingScopes + askScopeDayRanges.map { AskScope.lastDays(days: $0) }
    return ordered.reduce(into: [AskScope]()) { (result: inout [AskScope], scope: AskScope) -> Void in
        if !result.contains(scope) {
            result.append(scope)
        }
    }
}

/// Kapsam menüsündeki kişiler: toplantılarda konuşmacılara verilen adlar (kullanıcının kendisi hariç; büyük/küçük harf
/// duyarsız bir kez; örnek toplantının kurgusal konuşmacıları hariç), en son görülen önce, en çok `limit`. Saf
/// fonksiyondur.
public func askScopePeople(records: [MeetingRecord], userName: String, limit: Int) -> [String] {
    let names: [String] = newestFirst(records: realMeetings(records: records)).flatMap { (record: MeetingRecord) -> [String] in
        record.speakerNames.keys.sorted().compactMap { record.speakerNames[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    let unique: [String] = names.reduce(into: [String]()) { (result: inout [String], name: String) -> Void in
        if !name.isEmpty, name.caseInsensitiveCompare(userName) != .orderedSame, !result.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            result.append(name)
        }
    }
    return Array(unique.prefix(limit))
}

/// Saklanan turun kapsamı: kapsam alanından önce saklanan turlarda `@` kapsamından çıkarılır (tek toplantıya sorulan
/// tur o toplantının sohbetiydi, diğerleri tüm toplantılara). Saf fonksiyondur.
public func askTurnScope(turn: AskConversationTurn) -> AskScope {
    if let scope = turn.scope {
        return scope
    }
    return turn.scopeMeetingIDs.count == 1 ? .meeting(id: turn.scopeMeetingIDs[0]) : .allMeetings
}

/// Sohbetin kapsamı (geçmişteki etiketi ve sohbet yeniden açılınca çipte seçili olan): son turunki; turu yoksa tüm
/// toplantılar. Saf fonksiyondur.
public func askConversationScope(conversation: AskConversation) -> AskScope {
    conversation.turns.last.map { askTurnScope(turn: $0) } ?? .allMeetings
}

/// Kapsam toplantı sayfasına mı ait (hazır eylemler ve not içeriğinden devam soruları yalnız orada). Saf fonksiyondur.
public func askScopeMeetingID(scope: AskScope) -> String? {
    if case .meeting(let id) = scope {
        return id
    }
    return nil
}

/// Sorunun okuyacağı toplantılar ve bağlamı: platformun Sor hattı buna göre arşivde arar ya da toplantıları okur
/// (`answerAskTarget`).
public struct AskTarget: Sendable {
    public let question: String
    /// Devam soruları için önceki bitmiş turlar.
    public let history: [ArchiveTurn]
    /// Okunacak toplantılar; nil ise bütün arşivde aranır (kapsam tüm toplantılar, `@` etiketi yok).
    public let meetings: [MeetingRecord]?

    public init(question: String, history: [ArchiveTurn], meetings: [MeetingRecord]?) {
        self.question = question
        self.history = history
        self.meetings = meetings
    }
}

/// Soruyu kapsamına göre cevaplar (Mac ve iPhone aynı hat): kapsam tüm toplantılarsa bütün arşivde aranır
/// (`askArchive`; örnek toplantı hariç, `realMeetings`), değilse yalnız kapsamın toplantıları okunur (`askAboutMeetings`: hepsi sığıyorsa tamamı, sığmıyorsa
/// onların içinde aranır). Cihaz içi modelde dili desteklenmeyen toplantılar birden çok toplantılı kapsamda atlanır
/// (`onDeviceAskableArchive`); tek toplantıda dili desteklenmiyorsa neden hata olarak döner.
public func answerAskTarget(
    target: AskTarget, archive: [MeetingRecord], userName: String, profile: UserProfile, noteLanguage: ShareLanguage, answerLanguage: ShareLanguage,
    provider: LLMProvider, screens: ArchiveScreensPlan, webSearch: Bool, onProgress: ArchiveProgressHandler
) async throws -> ArchiveAnswer {
    let maxChars: Int = noteLimits(provider: provider).archiveChars
    guard let meetings = target.meetings else {
        let readable: OnDeviceReadableRecords = try onDeviceAskableArchive(records: realMeetings(records: archive), provider: provider, outputLanguage: answerLanguage)
        return try await askArchive(
            question: target.question, history: target.history, records: readable.records, userName: userName, profile: profile, noteLanguage: noteLanguage,
            answerLanguage: answerLanguage, llm: provider, maxChars: maxChars, screens: screens, webSearch: webSearch, now: Date(), onProgress: onProgress
        )
    }
    let readable: [MeetingRecord]
    if meetings.count == 1 {
        try requireOnDeviceLanguages(provider: provider, meetingLanguages: meetings.compactMap(\.language), outputLanguage: answerLanguage)
        readable = meetings
    } else {
        readable = try onDeviceAskableArchive(records: meetings, provider: provider, outputLanguage: answerLanguage).records
    }
    return try await askAboutMeetings(
        question: target.question, history: target.history, records: readable, userName: userName, profile: profile, noteLanguage: noteLanguage,
        answerLanguage: answerLanguage, llm: provider, maxChars: maxChars, screens: screens, webSearch: webSearch, now: Date(), onProgress: onProgress
    )
}

/// Boş Sor'da soru alanının üstündeki öneri: kullanıcının kendi verisinden (dünkü toplantı, açık görevleri, son
/// toplantı, son konuştuğu kişi); arayüz kendi dilinde soruya çevirir.
public enum AskSuggestion: Hashable, Sendable {
    /// "Dün ne konuştuk?" (dün toplantı varsa).
    case yesterday
    /// "Kime ne söz verdim?" (kullanıcıya yazılmış açık görev varsa).
    case promises
    /// "<toplantı> toplantısında ne kararlaştırıldı?" (kapsamın en yeni toplantısı).
    case lastMeeting(title: String)
    /// "<kişi> ile en son ne konuştuk?" (kapsamda en son adı verilen kişi).
    case lastPerson(name: String)
    /// "Neye dikkat etmeliyim?" (her zaman).
    case attention
}

/// Boş Sor'un önerileri (en çok `limit`), kapsamın toplantılarından: dün toplantı varsa dün, kullanıcıya yazılmış açık
/// görev varsa sözler, en yeni toplantı, en son konuşulan kişi, sonda dikkat edilecekler. Kapsam tek toplantıysa boş:
/// orada toplantının hazır eylemleri var. Saf fonksiyondur.
public func askSuggestions(scope: AskScope, records: [MeetingRecord], userName: String, now: Date, calendar: Calendar, limit: Int) -> [AskSuggestion] {
    guard askScopeMeetingID(scope: scope) == nil else {
        return []
    }
    let scoped: [MeetingRecord] = askScopeMeetings(scope: scope, records: records, now: now, calendar: calendar)
    guard let latest = scoped.first else {
        return []
    }
    guard let yesterday = calendar.date(byAdding: .day, value: -1, to: now) else {
        preconditionFailure("Takvim dünü hesaplayamadı")
    }
    let hadYesterday: Bool = scoped.contains { calendar.isDate($0.startedAt, inSameDayAs: yesterday) }
    let hasPromises: Bool = myTasks(meetings: scoped, userName: userName).contains { !isTaskDone(record: $0.record, task: $0.task) }
    let person: String? = {
        if case .person(let chosen) = scope {
            return chosen
        }
        return askScopePeople(records: scoped, userName: userName, limit: 1).first
    }()
    let candidates: [AskSuggestion?] = [
        hadYesterday ? .yesterday : nil,
        hasPromises ? .promises : nil,
        .lastMeeting(title: latest.note?.title ?? latest.title),
        person.map { AskSuggestion.lastPerson(name: $0) },
        .attention,
    ]
    return Array(candidates.compactMap { $0 }.prefix(limit))
}
