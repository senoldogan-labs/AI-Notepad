import AINotepadCore
import Foundation
import Testing
@testable import AINotepadUI

/// Bitmiş bir soru: `@` kapsamı ve (varsa) tarif adıyla.
private func finished(question: String, scope: [String], recipeTitle: String?) -> ArchiveExchange {
    ArchiveExchange(
        id: UUID(), question: question, scope: .allMeetings, scopeMeetingIDs: scope, scopeTitles: scope.map { "Toplantı \($0)" }, recipeTitle: recipeTitle,
        startedAt: Date(timeIntervalSince1970: 1_792_000_000), phase: .done, terms: [], passages: [],
        screens: 0, answer: ArchiveAnswer(text: "Cevap", sources: [], webSources: []), webQueries: [], webSearchNotice: .unavailable, skippedMeetings: [],
        finishedAt: Date(timeIntervalSince1970: 1_792_000_005)
    )
}

/// Not ve transkripti olan, `@` ile etiketlenebilir toplantı.
private func meeting(id: String, title: String) -> MeetingRecord {
    MeetingRecord(
        id: id, title: title, startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: nil, language: .finnish, status: .done, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: MeetingNote(title: title, summary: "Özet", decisions: [], tasks: [], glossary: []), audioDeleted: false, engine: .cloud, notice: nil,
        meNeedsFinalPass: nil
    )
}

@Suite struct AskChatTests {
    // Boş alanda ↑: kullanıcının yazdığı son soru gelir; tariften gelen uzun istem atlanır, soru yoksa nil.
    @Test func lastAskedQuestionSkipsRecipes() {
        let typed: ArchiveExchange = finished(question: "Bütçe ne oldu?", scope: [], recipeTitle: nil)
        let recipe: ArchiveExchange = finished(question: "Uzun tarif istemi…", scope: [], recipeTitle: "Takip e-postası")
        #expect(lastAskedQuestion(exchanges: [typed, recipe]) == "Bütçe ne oldu?")
        #expect(lastAskedQuestion(exchanges: [recipe]) == nil)
        #expect(lastAskedQuestion(exchanges: []) == nil)
    }

    // Saklanan tur sohbete geri açılınca `@` etiketleri (kimlik ve başlık) aynen görünür.
    @Test func reopenedTurnKeepsMentionChips() throws {
        let exchange: ArchiveExchange = finished(question: "Kim ne üstlendi?", scope: ["a", "b"], recipeTitle: nil)
        let turn: AskConversationTurn = try #require(askTurn(exchange: exchange))
        let reopened: ArchiveExchange = archiveExchange(turn: turn)
        #expect(reopened.scopeMeetingIDs == ["a", "b"])
        #expect(reopened.scopeTitles == ["Toplantı a", "Toplantı b"])
        #expect(reopened == exchange)
    }

    // Devam sorusu kapsamı: `@` ile tek toplantıya sorulan sohbette devam sorusu aynı toplantıda kalır (etiket alanda
    // görünür); etiket kaldırılıp tüm arşive sorulunca kapsam boşalır; silinen toplantı düşer; boş sohbette kapsam yok.
    @Test func followUpKeepsTheConversationScope() {
        let records: [MeetingRecord] = [meeting(id: "a", title: "Bütçe"), meeting(id: "b", title: "Haftalık")]
        #expect(followUpScope(exchanges: [], records: records).isEmpty)
        let first: ArchiveExchange = finished(question: "Bütçe ne oldu?", scope: ["a"], recipeTitle: nil)
        let scope: [MeetingRecord] = followUpScope(exchanges: [first], records: records)
        #expect(scope.map(\.id) == ["a"])
        // Devam sorusu bu kapsamla gönderilir ve yine aynı kapsamı taşır.
        let followUp: ArchiveExchange = startedExchange(id: UUID(), question: "Peki kim üstlendi?", scope: .allMeetings, tagged: scope, recipeTitle: nil, startedAt: Date())
        #expect(followUp.scopeMeetingIDs == ["a"] && followUp.scopeTitles == ["Bütçe"] && followUp.webSearchNotice == .ok)
        #expect(followUpScope(exchanges: [first, followUp], records: records).map(\.id) == ["a"])
        // Etiket kaldırıldı: soru tüm arşive gider, sonraki devam sorusu da.
        let unscoped: ArchiveExchange = finished(question: "Tüm toplantılarda?", scope: [], recipeTitle: nil)
        #expect(followUpScope(exchanges: [first, followUp, unscoped], records: records).isEmpty)
        // Sohbet açıkken toplantı silindi: kalan etiketler sırasıyla.
        let two: ArchiveExchange = finished(question: "İkisi?", scope: ["b", "silinmis", "a"], recipeTitle: nil)
        #expect(followUpScope(exchanges: [two], records: records).map(\.id) == ["b", "a"])
    }

    // Devam sorusunun bağlamı: bitmiş sorular (durdurulan ve hatalı olanlar değil) soru, cevap ve kaynaklarıyla geçmişe
    // girer ve devam sorusunun istemlerinde (arama terimleri ve cevap) önceki sorular görünür.
    @Test func followUpCarriesEarlierTurns() {
        var stopped: ArchiveExchange = finished(question: "Yarım kalan", scope: [], recipeTitle: nil)
        stopped.phase = .stopped
        let exchanges: [ArchiveExchange] = [
            finished(question: "Kahve makinesi ne oldu?", scope: ["a"], recipeTitle: nil), stopped,
            finished(question: "Bütçe konusu ne?", scope: ["a"], recipeTitle: nil),
        ]
        let history: [ArchiveTurn] = archiveHistory(exchanges: exchanges)
        #expect(history.map(\.question) == ["Kahve makinesi ne oldu?", "Bütçe konusu ne?"])
        let terms: LLMRequest = searchTermsRequest(question: "Bu konuyu webde ara", history: history, languages: [.finnish], language: .turkish)
        let answer: LLMRequest = archiveAnswerRequest(
            question: "Bu konuyu webde ara", passages: [], screens: [], history: history, userName: "", profile: .empty, now: Date(timeIntervalSince1970: 0), answerLanguage: .turkish,
            webSearch: true
        )
        for request in [terms, answer] {
            #expect(request.userText.contains("Kahve makinesi ne oldu?") && request.userText.contains("Bütçe konusu ne?"))
            #expect(!request.userText.contains("Yarım kalan"))
        }
    }

    // Eski sürümün sakladığı (ya da eşitlediği) cevaptaki kapsam etiketi sohbet yeniden açılınca görünmez.
    @Test func reopenedTurnHidesEchoedCoverageTag() throws {
        var exchange: ArchiveExchange = finished(question: "Which tasks were given to me?", scope: [], recipeTitle: nil)
        exchange.answer = ArchiveAnswer(text: "Two tasks [1].\n\n<kapsam>10 toplantıya dayanıyor: 3 Kas 2026 - 6 Kas 2026</kapsam>", sources: [], webSources: [])
        let turn: AskConversationTurn = try #require(askTurn(exchange: exchange))
        #expect(archiveExchange(turn: turn).answer.text == "Two tasks [1].\n")
    }

    // Kapsam dipnotu: okunmayan toplantılar ilerleyişle soruya yazılır, geçmişe saklanır ve geri okunur; dipnot yalnız
    // bitmiş, parça okumuş cevapta ve tüm arşive (ya da sığmayan `@` toplantılarına) sorulan soruda görünür.
    @Test func coverageFootnoteRoundTripsAndShowsOnlyWhereUseful() throws {
        let note: ArchivePassage = ArchivePassage(id: "a-note", meetingID: "a", meetingTitle: "A", meetingDate: Date(timeIntervalSince1970: 0), kind: .note, startSec: 0, text: "")
        let moment: ArchivePassage = ArchivePassage(id: "b-t0", meetingID: "b", meetingTitle: "B", meetingDate: Date(timeIntervalSince1970: 86_400), kind: .transcript, startSec: 42, text: "")
        let skipped: ArchiveMeetingRef = ArchiveMeetingRef(id: "c", title: "C", date: Date(timeIntervalSince1970: 172_800))
        var exchange: ArchiveExchange = applying(progress: .coverage(ArchiveCoverage(read: [], skipped: [skipped])), to: finished(question: "Q", scope: [], recipeTitle: nil))
        exchange.passages = [note, moment]
        #expect(exchange.skippedMeetings == [skipped] && showsCoverageFootnote(exchange: exchange))
        let reopened: ArchiveExchange = archiveExchange(turn: try #require(askTurn(exchange: exchange)))
        #expect(reopened.skippedMeetings == [skipped])
        #expect(coverageOpenPassage(meetingID: "a", passages: [moment, note]) == note)
        #expect(coverageOpenPassage(meetingID: "b", passages: [note, moment]) == moment)
        var scoped: ArchiveExchange = finished(question: "Q", scope: ["a"], recipeTitle: nil)
        scoped.passages = [note]
        #expect(!showsCoverageFootnote(exchange: scoped))
        var writing: ArchiveExchange = exchange
        writing.phase = .writing
        #expect(!showsCoverageFootnote(exchange: writing))
    }

    // Yazılırken durdurulan cevap (o ana kadarki metniyle) saklanır ve "Durduruldu" olarak geri açılır; cevap gelmeden
    // durdurulan soru saklanmaz.
    @Test func stoppedAnswerIsSavedWithItsText() throws {
        var stopped: ArchiveExchange = finished(question: "Q", scope: [], recipeTitle: nil)
        stopped.phase = .stopped
        let turn: AskConversationTurn = try #require(askTurn(exchange: stopped))
        #expect(turn.wasStopped == true && archiveExchange(turn: turn).phase == .stopped)
        stopped.answer = ArchiveAnswer(text: "", sources: [], webSources: [])
        #expect(askTurn(exchange: stopped) == nil)
        #expect(try #require(askTurn(exchange: finished(question: "Q", scope: [], recipeTitle: nil))).wasStopped == nil)
    }

    // Geçmiş satırının simgesi sohbetin türünü gösterir: web kaynaklı cevap, `@` ile toplantıya sorulan, tarif, tüm arşiv.
    @Test func historySymbolShowsTheConversationKind() throws {
        let archive: ArchiveExchange = finished(question: "Kararlar?", scope: [], recipeTitle: nil)
        let scoped: ArchiveExchange = finished(question: "Kim?", scope: ["a"], recipeTitle: nil)
        let recipe: ArchiveExchange = finished(question: "Uzun istem", scope: [], recipeTitle: "Takip e-postası")
        var web: ArchiveExchange = finished(question: "Fiyat?", scope: ["a"], recipeTitle: nil)
        web.answer = ArchiveAnswer(text: "29 € [w1]", sources: [], webSources: [WebSource(url: "https://example.com", title: "Example")])
        let symbol: ([ArchiveExchange]) throws -> String = { (exchanges: [ArchiveExchange]) throws -> String in
            let turns: [AskConversationTurn] = try exchanges.map { (exchange: ArchiveExchange) throws -> AskConversationTurn in try #require(askTurn(exchange: exchange)) }
            return askConversationSymbol(conversation: askConversation(existing: nil, id: UUID(), turns: turns, now: Date()))
        }
        #expect(try symbol([archive]) == "bubble.left.and.text.bubble.right")
        #expect(try symbol([scoped]) == "at")
        #expect(try symbol([recipe]) == "wand.and.stars")
        #expect(try symbol([archive, web]) == "globe")
        #expect(askHistoryFilterSymbol(filter: .web) == "globe" && askHistoryFilterSymbol(filter: .meetings) == "at")
    }

    // Tek motor, kapsamlı soru: klasör kapsamında yalnız klasörün toplantıları okunur, tur kapsamıyla saklanır ve dipnot
    // görünür; tüm toplantılarda bütün arşivde aranır; kapsamda toplantı yoksa sorulmaz, neden sohbette.
    @MainActor
    @Test func storeAsksTheSelectedScope() async throws {
        let records: [MeetingRecord] = [meeting(id: "a", title: "Bütçe").with(folder: "Müşteriler"), meeting(id: "b", title: "Haftalık")]
        let store: AskStore = AskStore()
        var targets: [[String]?] = []
        var saved: [AskConversationTurn] = []
        let passage: ArchivePassage = ArchivePassage(id: "a-note", meetingID: "a", meetingTitle: "Bütçe", meetingDate: Date(timeIntervalSince1970: 0), kind: .note, startSec: 0, text: "x")
        let answer: AskAnswer = { (target: AskTarget, onProgress: @escaping ArchiveProgressHandler) async throws -> Void in
            targets.append(target.meetings?.map(\.id))
            await onProgress(.passages([passage]))
            await onProgress(.answer(ArchiveAnswer(text: "Cevap [1]", sources: [passage], webSources: [])))
        }
        let save: AskSave = { (_: UUID, exchanges: [ArchiveExchange]) -> Void in
            saved = exchanges.compactMap { askTurn(exchange: $0) }
        }
        store.select(scope: .folder(name: "Müşteriler"), context: .allMeetings)
        store.ask(context: .allMeetings, question: "Ne karar verdik?", scope: store.scope(context: .allMeetings), mentionIDs: [], recipeTitle: nil, records: records, answer: answer, save: save)
        await store.waitForAnswer(context: .allMeetings)
        #expect(targets == [["a"]])
        let first: ArchiveExchange = try #require(store.exchanges(context: .allMeetings).first)
        #expect(first.scope == .folder(name: "Müşteriler") && first.scopeMeetingIDs.isEmpty && showsCoverageFootnote(exchange: first))
        #expect(saved.map(\.scope) == [.folder(name: "Müşteriler")])
        store.select(scope: .allMeetings, context: .allMeetings)
        store.ask(context: .allMeetings, question: "Ya hepsinde?", scope: .allMeetings, mentionIDs: [], recipeTitle: nil, records: records, answer: answer, save: save)
        await store.waitForAnswer(context: .allMeetings)
        #expect(targets == [["a"], nil])
        store.ask(context: .allMeetings, question: "Anna?", scope: .person(name: "Anna"), mentionIDs: [], recipeTitle: nil, records: records, answer: answer, save: save)
        #expect(targets.count == 2)
        if case .failed = store.exchanges(context: .allMeetings).last?.phase {} else {
            Issue.record("Kapsamı boş soru hatalı bitmeliydi")
        }
    }

    // Toplantı sayfası sohbeti: kapsamı o toplantı, etiketi yok, dipnot "bu toplantı"; saklı sohbet sayfada geri gelir ve
    // Sor sayfasında açılınca sayfadan kalkar (iki alan aynı sohbeti yazmasın).
    @MainActor
    @Test func meetingChatResumesAndMovesBetweenSurfaces() throws {
        let store: AskStore = AskStore()
        let exchange: ArchiveExchange = startedExchange(
            id: UUID(), question: "Kim?", scope: .meeting(id: "a"), tagged: [meeting(id: "a", title: "Bütçe")], recipeTitle: nil, startedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(exchangeMentionIDs(exchange: exchange).isEmpty && exchange.scopeMeetingIDs == ["a"])
        var done: ArchiveExchange = exchange
        done.phase = .done
        done.finishedAt = Date(timeIntervalSince1970: 5)
        done.answer = ArchiveAnswer(text: "Mikko", sources: [], webSources: [])
        let conversation: AskConversation = askConversation(existing: nil, id: UUID(), turns: [try #require(askTurn(exchange: done))], now: Date(timeIntervalSince1970: 5))
        store.resume(context: .meeting(id: "a"), conversations: [conversation])
        #expect(store.conversationID(context: .meeting(id: "a")) == conversation.id && store.scope(context: .meeting(id: "a")) == .meeting(id: "a"))
        store.open(conversation: conversation, context: .allMeetings)
        #expect(store.scope(context: .allMeetings) == .meeting(id: "a") && store.exchanges(context: .meeting(id: "a")).isEmpty)
        store.clear(context: .allMeetings)
        #expect(store.scope(context: .allMeetings) == .allMeetings && store.conversationID(context: .allMeetings) == nil)
    }

    // Örnek toplantının sohbeti saklanmaz (eşitlenmesin): kapsam sonra tüm toplantılara genişletilse de; yeni sohbet
    // yeniden saklanır.
    @MainActor
    @Test func sampleMeetingChatIsNeverSaved() async {
        let sample: MeetingRecord = meeting(id: "s", title: "Örnek").markedAsSample()
        let records: [MeetingRecord] = [sample, meeting(id: "b", title: "Haftalık")]
        let store: AskStore = AskStore()
        var saves: Int = 0
        let answer: AskAnswer = { (_: AskTarget, onProgress: @escaping ArchiveProgressHandler) async throws -> Void in
            await onProgress(.answer(ArchiveAnswer(text: "Cevap", sources: [], webSources: [])))
        }
        let save: AskSave = { (_: UUID, _: [ArchiveExchange]) -> Void in saves += 1 }
        let context: AskScope = .meeting(id: "s")
        store.ask(context: context, question: "Ne kararlaştırıldı?", scope: context, mentionIDs: [], recipeTitle: nil, records: records, answer: answer, save: save)
        await store.waitForAnswer(context: context)
        store.ask(context: context, question: "Ya hepsinde?", scope: .allMeetings, mentionIDs: [], recipeTitle: nil, records: records, answer: answer, save: save)
        await store.waitForAnswer(context: context)
        #expect(saves == 0 && store.exchanges(context: context).count == 2)
        store.clear(context: context)
        store.ask(context: context, question: "Yeni konu", scope: .allMeetings, mentionIDs: [], recipeTitle: nil, records: records, answer: answer, save: save)
        await store.waitForAnswer(context: context)
        #expect(saves == 1)
    }
}
