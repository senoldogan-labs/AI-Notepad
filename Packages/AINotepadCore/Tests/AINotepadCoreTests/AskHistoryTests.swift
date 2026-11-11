import Foundation
import Testing
@testable import AINotepadCore

private let askedAt: Date = Date(timeIntervalSince1970: 1_792_000_000)

/// Bitmiş bir tur: soru, cevap, `@` kapsamı, tarif adı ve web kaynakları.
private func turn(question: String, answer: String, scopeTitles: [String], recipeTitle: String?, webSources: [WebSource]?) -> AskConversationTurn {
    AskConversationTurn(
        id: UUID(), question: question, scopeMeetingIDs: scopeTitles.map { "id-\($0)" }, scopeTitles: scopeTitles, recipeTitle: recipeTitle,
        startedAt: askedAt, finishedAt: askedAt.addingTimeInterval(5), terms: [], readPassages: [], readScreens: nil, answer: answer, sources: [],
        webSources: webSources, webQueries: nil, webSearchNotice: nil, skippedMeetings: nil, wasStopped: nil, scope: nil
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

    // Bölümler: bugün, bu hafta (önceki aya düşen gün de), bu ay ve daha önce; boş bölüm yok, sıra korunur; saat farkıyla
    // gelecekte görünen sohbet bugündür.
    @Test func sectionsGroupByTodayWeekMonthAndEarlier() throws {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Helsinki"))
        calendar.firstWeekday = 2
        // Çarşamba 2 Aralık 2026, 15:00; hafta 30 Kasım Pazartesi başlar (önceki ay).
        let now: Date = try #require(calendar.date(from: DateComponents(year: 2026, month: 12, day: 2, hour: 15)))
        func at(month: Int, day: Int, hour: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour)))
        }
        func updated(_ date: Date) -> AskConversation {
            let base: AskConversation = chat(question: "Soru", answer: "Cevap", scopeTitles: [], webSources: nil)
            return AskConversation(id: base.id, createdAt: date, updatedAt: date, title: base.title, customTitle: nil, turns: base.turns)
        }
        let future: AskConversation = updated(now.addingTimeInterval(90))
        let morning: AskConversation = updated(try at(month: 12, day: 2, hour: 0))
        let monday: AskConversation = updated(try at(month: 11, day: 30, hour: 9))
        let lastSunday: AskConversation = updated(try at(month: 11, day: 29, hour: 23))
        let october: AskConversation = updated(try at(month: 10, day: 20, hour: 12))
        let sections: [AskHistorySection] = askHistorySections(
            conversations: [future, morning, monday, lastSunday, october], now: now, calendar: calendar
        )
        #expect(sections.map(\.period) == [.today, .thisWeek, .earlier])
        #expect(sections[0].conversations == [future, morning])
        #expect(sections[1].conversations == [monday])
        #expect(sections[2].conversations == [lastSunday, october])
        // Ayın ortasında: haftadan önceki ama aynı aydaki gün "bu ay".
        let midMonth: Date = try at(month: 12, day: 17, hour: 10)
        #expect(askHistoryPeriod(date: try at(month: 12, day: 9, hour: 10), now: midMonth, calendar: calendar) == .thisMonth)
        #expect(askHistoryPeriod(date: try at(month: 12, day: 14, hour: 0), now: midMonth, calendar: calendar) == .thisWeek)
        #expect(askHistorySections(conversations: [], now: now, calendar: calendar).isEmpty)
    }

    // Önizleme: son cevaplanmış turun düz metni tek satırda; Markdown işaretleri ve kaynak numaraları düşer; cevapsız sohbet boş.
    @Test func previewIsTheLastAnswerAsOneLine() {
        let first: AskConversationTurn = turn(question: "Bütçe?", answer: "Eski cevap.", scopeTitles: [], recipeTitle: nil, webSources: nil)
        let second: AskConversationTurn = turn(
            question: "Kim onayladı?", answer: "**Maria** onayladı [2].\n\n- Q3 bütçesi\n- Yeni işe alım [w1]", scopeTitles: [], recipeTitle: nil, webSources: nil
        )
        let stopped: AskConversationTurn = turn(question: "Devam?", answer: "  \n", scopeTitles: [], recipeTitle: nil, webSources: nil)
        let conversation: AskConversation = askConversation(existing: nil, id: UUID(), turns: [first, second, stopped], now: askedAt)
        #expect(askConversationPreview(conversation: conversation) == "Maria onayladı. Q3 bütçesi Yeni işe alım")
        let unanswered: AskConversation = askConversation(existing: nil, id: UUID(), turns: [stopped], now: askedAt)
        #expect(askConversationPreview(conversation: unanswered).isEmpty)
    }
}
