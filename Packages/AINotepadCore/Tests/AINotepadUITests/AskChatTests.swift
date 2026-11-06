import AINotepadCore
import Foundation
import Testing
@testable import AINotepadUI

/// Bitmiş bir soru: `@` kapsamı ve (varsa) tarif adıyla.
private func finished(question: String, scope: [String], recipeTitle: String?) -> ArchiveExchange {
    ArchiveExchange(
        id: UUID(), question: question, scopeMeetingIDs: scope, scopeTitles: scope.map { "Toplantı \($0)" }, recipeTitle: recipeTitle,
        startedAt: Date(timeIntervalSince1970: 1_792_000_000), phase: .done, terms: [], passages: [],
        screens: 0, answer: ArchiveAnswer(text: "Cevap", sources: [], webSources: []), webQueries: [], webSearchNotice: .unavailable, finishedAt: Date(timeIntervalSince1970: 1_792_000_005)
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
        let followUp: ArchiveExchange = startedExchange(id: UUID(), question: "Peki kim üstlendi?", scope: scope, recipeTitle: nil, startedAt: Date())
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
            question: "Bu konuyu webde ara", passages: [], coverage: ArchiveCoverage(read: [], skipped: []), screens: [], history: history, userName: "", now: Date(timeIntervalSince1970: 0), language: .turkish,
            webSearch: true
        )
        for request in [terms, answer] {
            #expect(request.userText.contains("Kahve makinesi ne oldu?") && request.userText.contains("Bütçe konusu ne?"))
            #expect(!request.userText.contains("Yarım kalan"))
        }
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
}
