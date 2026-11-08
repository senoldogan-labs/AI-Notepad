import AINotepadCore
import Foundation
import Testing

/// Notu olan toplantı: başlık, gün (2026-11-08'den geriye), klasör ve konuşmacı adları.
private func meeting(id: String, daysAgo: Int, folder: String?, speakers: [Int: String]) -> MeetingRecord {
    let record: MeetingRecord = MeetingRecord(
        id: id, title: "Toplantı \(id)", startedAt: askScopeNow.addingTimeInterval(Double(-daysAgo) * 86_400), endedAt: nil, language: .finnish, status: .done,
        failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: speakers,
        note: MeetingNote(title: "Not \(id)", summary: "Özet", decisions: [], tasks: [], glossary: []), audioDeleted: false, engine: .cloud, notice: nil,
        meNeedsFinalPass: nil
    )
    return folder.map { record.with(folder: $0) } ?? record
}

private let askScopeNow: Date = Date(timeIntervalSince1970: 1_794_139_200)

private var utc: Calendar {
    var calendar: Calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func turn(meetingIDs: [String], scope: AskScope?) -> AskConversationTurn {
    AskConversationTurn(
        id: UUID(), question: "Q", scopeMeetingIDs: meetingIDs, scopeTitles: meetingIDs, recipeTitle: nil, startedAt: askScopeNow, finishedAt: askScopeNow,
        terms: [], readPassages: [], readScreens: nil, answer: "A", sources: [], webSources: nil, webQueries: nil, webSearchNotice: nil, skippedMeetings: nil,
        wasStopped: nil, scope: scope
    )
}

@Suite struct AskScopeTests {
    private let records: [MeetingRecord] = [
        meeting(id: "a", daysAgo: 0, folder: "Müşteriler", speakers: [1: "Anna", 2: "Sen"]),
        meeting(id: "b", daysAgo: 10, folder: "müşteriler", speakers: [1: " anna "]),
        meeting(id: "c", daysAgo: 40, folder: nil, speakers: [1: "Mikko"]),
    ]

    // Kapsamın toplantıları: klasör ve kişi büyük/küçük harf duyarsız, tarih aralığı bugünle birlikte, en yeni önce;
    // kayıttaki toplantı okunamaz.
    @Test func scopeResolvesToItsMeetings() {
        let ids: (AskScope) -> [String] = { (scope: AskScope) -> [String] in
            askScopeMeetings(scope: scope, records: records, now: askScopeNow, calendar: utc).map(\.id)
        }
        #expect(ids(.allMeetings) == ["a", "b", "c"])
        #expect(ids(.meeting(id: "b")) == ["b"])
        #expect(ids(.folder(name: "müşteriler")) == ["a", "b"])
        #expect(ids(.person(name: "ANNA")) == ["a", "b"])
        #expect(ids(.lastDays(days: 7)) == ["a"])
        #expect(ids(.lastDays(days: 30)) == ["a", "b"])
        #expect(ids(.meeting(id: "silinmis")).isEmpty)
        // Örnek toplantı yalnız kendisi seçilince okunur; kişi listesine de kurgusal konuşmacıları girmez.
        let withSample: [MeetingRecord] = records + [meeting(id: "s", daysAgo: 0, folder: "Müşteriler", speakers: [1: "Anna", 2: "Kurgu"]).markedAsSample()]
        for scope in [AskScope.allMeetings, .folder(name: "Müşteriler"), .person(name: "Anna"), .lastDays(days: 7)] {
            #expect(!askScopeMeetings(scope: scope, records: withSample, now: askScopeNow, calendar: utc).contains { $0.id == "s" })
        }
        #expect(askScopeMeetings(scope: .meeting(id: "s"), records: withSample, now: askScopeNow, calendar: utc).map(\.id) == ["s"])
        #expect(!askScopePeople(records: withSample, userName: "Sen", limit: 5).contains("Kurgu"))
    }

    // Sorunun okuyacağı toplantılar: `@` etiketleri kapsamı geçersiz kılar; tüm toplantılar bütün arşivde aranır (nil);
    // boş kapsam ve silinen etiket sessizce genişlemez, hata verir.
    @Test func targetUsesMentionsThenScope() throws {
        let target: (AskScope, [String]) throws -> [String]? = { (scope: AskScope, mentions: [String]) throws -> [String]? in
            try askTargetMeetings(scope: scope, mentionIDs: mentions, records: records, now: askScopeNow, calendar: utc)?.map(\.id)
        }
        #expect(try target(.allMeetings, []) == nil)
        #expect(try target(.folder(name: "Müşteriler"), []) == ["a", "b"])
        #expect(try target(.folder(name: "Müşteriler"), ["c"]) == ["c"])
        #expect(throws: AskScopeError.noMeetings(scope: .person(name: "Ville"))) { try target(.person(name: "Ville"), []) }
        #expect(throws: ArchiveScopeError.meetingsNotFound(ids: ["x"])) { try target(.allMeetings, ["x"]) }
    }

    // Menünün ilk bölümü: bulunulan yer, seçili kapsam, tüm toplantılar, toplantının klasörü ve kişileri (kullanıcı
    // hariç), tarih aralıkları; tekrar yok.
    @Test func optionsFollowTheContext() {
        let options: [AskScope] = askScopeOptions(context: .meeting(id: "a"), selected: .meeting(id: "a"), contextMeeting: records[0], userName: "sen")
        #expect(options == [.meeting(id: "a"), .allMeetings, .folder(name: "Müşteriler"), .person(name: "Anna"), .lastDays(days: 7), .lastDays(days: 30)])
        let reopened: [AskScope] = askScopeOptions(context: .allMeetings, selected: .person(name: "Mikko"), contextMeeting: nil, userName: "sen")
        #expect(reopened == [.allMeetings, .person(name: "Mikko"), .lastDays(days: 7), .lastDays(days: 30)])
        // Örnek toplantının sayfasında klasörü ve kurgusal konuşmacıları önerilmez.
        let sample: [AskScope] = askScopeOptions(context: .meeting(id: "a"), selected: .meeting(id: "a"), contextMeeting: records[0].markedAsSample(), userName: "sen")
        #expect(sample == [.meeting(id: "a"), .allMeetings, .lastDays(days: 7), .lastDays(days: 30)])
        #expect(askScopePeople(records: records, userName: "Sen", limit: 5) == ["Anna", "Mikko"])
    }

    // Saklanan turun kapsamı: kapsam alanı yoksa tek `@` toplantı o toplantının sohbetidir; sohbetin kapsamı son turun;
    // toplantı sayfası sohbeti kapsam alanıyla da, eski biçimle de bulunur.
    @Test func turnScopeAndMeetingConversation() {
        #expect(askTurnScope(turn: turn(meetingIDs: ["a"], scope: nil)) == .meeting(id: "a"))
        #expect(askTurnScope(turn: turn(meetingIDs: ["a", "b"], scope: nil)) == .allMeetings)
        #expect(askTurnScope(turn: turn(meetingIDs: [], scope: .folder(name: "X"))) == .folder(name: "X"))
        let widened: AskConversation = askConversation(
            existing: nil, id: UUID(), turns: [turn(meetingIDs: ["a"], scope: .meeting(id: "a")), turn(meetingIDs: [], scope: .allMeetings)], now: askScopeNow
        )
        #expect(askConversationScope(conversation: widened) == .allMeetings)
        let meetingChat: AskConversation = askConversation(existing: nil, id: UUID(), turns: [turn(meetingIDs: ["a"], scope: .meeting(id: "a"))], now: askScopeNow)
        #expect(latestMeetingConversation(conversations: [widened, meetingChat], meetingID: "a") == meetingChat)
        #expect(latestMeetingConversation(conversations: [widened], meetingID: "a") == nil)
    }

    // Kapsam saklanır ve eşitlenir: JSON'da gider gelir; kapsamsız eski JSON da okunur.
    @Test func scopeRoundTripsInJSON() throws {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for scope in [AskScope.allMeetings, .meeting(id: "a"), .folder(name: "Müşteriler"), .person(name: "Anna"), .lastDays(days: 7)] {
            let saved: AskConversationTurn = turn(meetingIDs: [], scope: scope)
            #expect(try decoder.decode(AskConversationTurn.self, from: encoder.encode(saved)).scope == scope)
        }
        let legacy: AskConversationTurn = turn(meetingIDs: ["a"], scope: nil)
        let decoded: AskConversationTurn = try decoder.decode(AskConversationTurn.self, from: encoder.encode(legacy))
        #expect(decoded.scope == nil && askTurnScope(turn: decoded) == .meeting(id: "a"))
    }

    // Boş Sor'un önerileri kullanıcının verisinden: en yeni toplantı ve son kişi; kişi kapsamında o kişi; tek toplantı
    // kapsamında yok (orada hazır eylemler var); toplantı yoksa yok; dün toplantı varsa önce o.
    @Test func suggestionsComeFromTheUsersMeetings() {
        let all: [AskSuggestion] = askSuggestions(scope: .allMeetings, records: records, userName: "Sen", now: askScopeNow, calendar: utc, limit: 4)
        #expect(all == [.lastMeeting(title: "Not a"), .lastPerson(name: "Anna"), .attention])
        let person: [AskSuggestion] = askSuggestions(scope: .person(name: "Mikko"), records: records, userName: "Sen", now: askScopeNow, calendar: utc, limit: 4)
        #expect(person == [.lastMeeting(title: "Not c"), .lastPerson(name: "Mikko"), .attention])
        #expect(askSuggestions(scope: .meeting(id: "a"), records: records, userName: "Sen", now: askScopeNow, calendar: utc, limit: 4).isEmpty)
        #expect(askSuggestions(scope: .allMeetings, records: [], userName: "Sen", now: askScopeNow, calendar: utc, limit: 4).isEmpty)
        let yesterday: [MeetingRecord] = [meeting(id: "y", daysAgo: 1, folder: nil, speakers: [:])]
        #expect(askSuggestions(scope: .allMeetings, records: yesterday, userName: "Sen", now: askScopeNow, calendar: utc, limit: 2) == [.yesterday, .lastMeeting(title: "Not y")])
    }
}
