import Foundation
import Testing
@testable import AINotepadCore

private let askedAt: Date = Date(timeIntervalSince1970: 1_792_000_000)

/// Bitmiş bir tur: soru, cevap, `@` kapsamı, tarif adı ve web kaynakları.
private func turn(question: String, answer: String, scopeTitles: [String], recipeTitle: String?, webSources: [WebSource]?) -> AskConversationTurn {
    AskConversationTurn(
        id: UUID(), question: question, scopeMeetingIDs: scopeTitles.map { "id-\($0)" }, scopeTitles: scopeTitles, recipeTitle: recipeTitle,
        startedAt: askedAt, finishedAt: askedAt.addingTimeInterval(5), terms: [], readPassages: [], readScreens: nil, answer: answer, sources: [],
        webSources: webSources, webQueries: nil, webSearchNotice: nil, skippedMeetings: nil, wasStopped: nil
    )
}

/// Tek turlu, saklanmış sohbet.
private func chat(question: String, answer: String, scopeTitles: [String], webSources: [WebSource]?) -> AskConversation {
    askConversation(
        existing: nil, id: UUID(), turns: [turn(question: question, answer: answer, scopeTitles: scopeTitles, recipeTitle: nil, webSources: webSources)],
        now: askedAt
    )
}

@Suite struct AskHistoryTests {
    // Ad değiştirme: ad tek satıra iner ve görünen ad olur; türetilmiş başlık ve son güncellenme (listedeki yer) değişmez.
    // Boş ya da aynı ad değişiklik değildir. Sonraki devam sorusu kullanıcının adını korur.
    @Test func renameOverridesTheDerivedTitle() throws {
        let original: AskConversation = chat(question: "Bütçe ne oldu?", answer: "Arttı.", scopeTitles: [], webSources: nil)
        #expect(askConversationDisplayTitle(conversation: original) == "Bütçe ne oldu?")
        let renamed: AskConversation = try #require(renamedAskConversation(conversation: original, title: "  Bütçe\n  2027 ", now: askedAt.addingTimeInterval(60)))
        #expect(askConversationDisplayTitle(conversation: renamed) == "Bütçe 2027")
        #expect(renamed.title == "Bütçe ne oldu?")
        #expect(renamed.updatedAt == original.updatedAt && renamed.turns == original.turns)
        #expect(renamed.customTitle == AskCustomTitle(text: "Bütçe 2027", editedAt: askedAt.addingTimeInterval(60)))
        #expect(renamedAskConversation(conversation: renamed, title: " \n ", now: askedAt) == nil)
        #expect(renamedAskConversation(conversation: renamed, title: "Bütçe 2027", now: askedAt) == nil)
        let followUp: AskConversationTurn = turn(question: "Kim onayladı?", answer: "Maria.", scopeTitles: [], recipeTitle: nil, webSources: nil)
        let continued: AskConversation = askConversation(existing: renamed, id: renamed.id, turns: renamed.turns + [followUp], now: askedAt.addingTimeInterval(120))
        #expect(askConversationDisplayTitle(conversation: continued) == "Bütçe 2027")
    }

    // Ad dosyaya yazılır ve geri okunur; ad alanı olmadan saklanan (eski sürümlerin yazdığı) sohbet de okunur (adı yok).
    @Test func customTitleIsStoredAndOldFilesStillLoad() throws {
        let directory: URL = try temporaryDirectory()
        let original: AskConversation = chat(question: "Bütçe ne oldu?", answer: "Arttı.", scopeTitles: [], webSources: nil)
        try saveAskConversation(conversation: original, directory: directory)
        let file: URL = directory.appending(path: "\(original.id.uuidString).json")
        #expect(try !String(contentsOf: file, encoding: .utf8).contains("customTitle"))
        #expect(try loadAskConversation(id: original.id, directory: directory) == original)
        let renamed: AskConversation = try #require(renamedAskConversation(conversation: original, title: "Bütçe 2027", now: askedAt))
        try saveAskConversation(conversation: renamed, directory: directory)
        #expect(try loadAskConversations(directory: directory).conversations == [renamed])
    }

    // Süzgeç: `@` ile toplantıya sorulanlar ve web kaynaklı cevabı olanlar; tümü hepsini gösterir, sıra korunur.
    @Test func filterBySourceKind() {
        let archive: AskConversation = chat(question: "Kararlar neler?", answer: "Üç karar.", scopeTitles: [], webSources: nil)
        let meeting: AskConversation = chat(question: "Kim ne üstlendi?", answer: "Mikko.", scopeTitles: ["Haftalık"], webSources: nil)
        let web: AskConversation = chat(question: "Rakip fiyatı?", answer: "29 €.", scopeTitles: [], webSources: [WebSource(url: "https://example.com", title: "Example")])
        let emptyWeb: AskConversation = chat(question: "Web yok", answer: "Bulunamadı.", scopeTitles: [], webSources: [])
        let all: [AskConversation] = [archive, meeting, web, emptyWeb]
        #expect(filteredAskConversations(conversations: all, query: "", filter: .all) == all)
        #expect(filteredAskConversations(conversations: all, query: "", filter: .meetings) == [meeting])
        #expect(filteredAskConversations(conversations: all, query: "", filter: .web) == [web])
    }

    // Arama: görünen ad, sorular, cevaplar, tarif ve etiketli toplantı adları; her kelime geçmeli; büyük/küçük harf, aksan
    // ve ı/i duyarsız. Süzgeçle birlikte uygulanır.
    @Test func searchMatchesTitleQuestionsAndAnswers() throws {
        let budget: AskConversation = try #require(renamedAskConversation(
            conversation: chat(question: "Bütçe ne oldu?", answer: "Pazarlama bütçesi araştırmaya kaydı.", scopeTitles: ["Yatırımcı"], webSources: nil),
            title: "Q3 planı", now: askedAt
        ))
        let coffee: AskConversation = chat(question: "Kahve makinesi?", answer: "Mikko yenisini ISMARLAYACAK.", scopeTitles: [], webSources: nil)
        let all: [AskConversation] = [budget, coffee]
        #expect(filteredAskConversations(conversations: all, query: "q3", filter: .all) == [budget])
        #expect(filteredAskConversations(conversations: all, query: "butce", filter: .all) == [budget])
        #expect(filteredAskConversations(conversations: all, query: "yatırımcı", filter: .all) == [budget])
        #expect(filteredAskConversations(conversations: all, query: "ısmarlayacak mikko", filter: .all) == [coffee])
        #expect(filteredAskConversations(conversations: all, query: "mikko bütçe", filter: .all).isEmpty)
        #expect(filteredAskConversations(conversations: all, query: "  ", filter: .all) == all)
        #expect(filteredAskConversations(conversations: all, query: "kahve", filter: .meetings).isEmpty)
        #expect(filteredAskConversations(conversations: all, query: "bütçe", filter: .meetings) == [budget])
    }
}
