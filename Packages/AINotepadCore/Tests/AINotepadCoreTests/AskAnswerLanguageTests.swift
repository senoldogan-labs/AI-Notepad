import Foundation
import Testing
@testable import AINotepadCore

/// Sor cevabının temizliği (yankılanan istem etiketleri, bozuk web işaretleri), cevap dili ve konuşmacı etiketleri.
@Suite struct AskAnswerLanguageTests {
    // Sahibin ekran görüntüsündeki hata: model istemdeki kapsam etiketini cevabın sonuna yazıyordu. Etiket içeriğiyle
    // atılır; diğer istem etiketlerinin yalnız kendisi atılır; kod (çitli ve satır içi) dokunulmadan kalır.
    @Test func echoedPromptTagsAreRemoved() {
        let echoed: String = "Sana iki görev verildi [1].\n\n<kapsam>10 toplantıya dayanıyor: 3 Kas 2026 - 6 Kas 2026</kapsam>"
        #expect(withoutPromptTags(text: echoed) == "Sana iki görev verildi [1].\n")
        let multiline: String = "Cevap.\n<KAPSAM>\nOkunan toplantı: 3\n</kapsam>\nSon satır."
        #expect(withoutPromptTags(text: multiline) == "Cevap.\nSon satır.")
        #expect(withoutPromptTags(text: "<cevap>Mikko alacak.</cevap>") == "Mikko alacak.")
        #expect(withoutPromptTags(text: "Bkz. <parca no=\"2\" toplanti=\"X\">burada</parca>.") == "Bkz. burada.")
        let code: String = "İstem:\n```xml\n<soru>Ne konuşuldu?</soru>\n<kapsam>x</kapsam>\n```\nSatır içi `<cevap>` kalır."
        #expect(withoutPromptTags(text: code) == code)
        #expect(withoutPromptTags(text: "a < b ve <div> kalır") == "a < b ve <div> kalır")
        // Akış sürerken sonda yarım kalan etiket görünmez; etiket olmayan "<" kalır.
        #expect(withoutPromptTags(text: "Cevap.\n<kap") == "Cevap.\n")
        #expect(withoutPromptTags(text: "Cevap. </cev") == "Cevap. ")
        #expect(withoutPromptTags(text: "Cevap <parca no=\"2") == "Cevap ")
        #expect(withoutPromptTags(text: "x <turnover") == "x <turnover")
    }

    // Kaynak numaralama da etiketi atar (akan, saklanan ve kopyalanan cevap temiz); var olmayan web kaynağının işareti
    // ("[w5]") bozuk rozet olmasın diye atılır, var olanı kalır.
    @Test func citedAnswerDropsTagsAndInvalidWebMarkers() {
        let passage: ArchivePassage = ArchivePassage(
            id: "a-note", meetingID: "a", meetingTitle: "A", meetingDate: Date(timeIntervalSince1970: 0), kind: .note, startSec: 0, text: "x"
        )
        let web: [WebSource] = [WebSource(url: "https://example.com", title: "Example")]
        let answer: ArchiveAnswer = citedAnswer(
            text: "Fiyat 29 € [w1] [w5]. Karar [1].\n<kapsam>1 toplantıya dayanıyor</kapsam>", passages: [passage], webSources: web
        )
        #expect(answer.text == "Fiyat 29 € [w1]. Karar [1].")
        #expect(citedAnswer(text: "Bilgi [w1].", passages: [], webSources: []).text == "Bilgi.")
    }

    // Saklanmış eski cevaplardaki etiket devam sorusunun istemine girmez (model örnek alıp yeniden yazmasın).
    @Test func historyDropsEchoedTags() {
        let block: String = historyTurnBlock(turn: ArchiveTurn(question: "Görevler?", answer: "İki görev [1].\n<kapsam>2 toplantıya dayanıyor</kapsam>", sources: []))
        #expect(!block.contains("dayanıyor") && block.contains("<cevap>İki görev.</cevap>"))
    }

    // Cevap dili: sorunun dili (kısa sorular da), anlaşılmazsa sohbetteki son anlaşılan soru, o da yoksa arayüz dili.
    @Test func answerLanguageFollowsTheQuestion() {
        #expect(askAnswerLanguage(question: "Which tasks were given to me?", history: [], interfaceLanguage: .turkish) == .english)
        #expect(askAnswerLanguage(question: "Bana hangi görevler verildi?", history: [], interfaceLanguage: .english) == .turkish)
        #expect(askAnswerLanguage(question: "Mitä päätettiin?", history: [], interfaceLanguage: .english) == .finnish)
        #expect(askAnswerLanguage(question: "Was haben wir beschlossen?", history: [], interfaceLanguage: .english) == .german)
        #expect(askAnswerLanguage(question: "Ne karar verdik?", history: [], interfaceLanguage: .english) == .turkish)
        // Tek ad: arayüz dili; sohbette anlaşılan soru varsa onun dili.
        #expect(askAnswerLanguage(question: "Pekka?", history: [], interfaceLanguage: .english) == .english)
        let earlier: ArchiveTurn = ArchiveTurn(question: "Kuka vastaa budjetista?", answer: "Pekka.", sources: [])
        #expect(askAnswerLanguage(question: "Pekka?", history: [earlier], interfaceLanguage: .english) == .finnish)
        #expect(detectedQuestionLanguage(text: "123?") == nil)
    }

    // İstem: cevap sorunun dilinde (yedek dil adıyla), kapsam satırı ve kapsam bloğu istenmez, tarihler dilden bağımsız.
    @Test func answerPromptAsksForTheQuestionLanguageWithoutCoverage() {
        let passage: ArchivePassage = ArchivePassage(
            id: "a-note", meetingID: "a", meetingTitle: "Weekly", meetingDate: Date(timeIntervalSince1970: 1_792_000_000), kind: .note, startSec: 0, text: "Görev: Speaker 2 — X"
        )
        let request: LLMRequest = archiveAnswerRequest(
            question: "Which tasks were given to me?", passages: [passage], screens: [], history: [], userName: "Doğan", profile: .empty,
            now: Date(timeIntervalSince1970: 1_792_000_000), answerLanguage: .english, webSearch: false
        )
        #expect(request.system.contains("sorunun yazıldığı dilde yaz (büyük olasılıkla English)"))
        #expect(request.system.contains("\"Speaker 2\""))
        #expect(!request.userText.contains("<kapsam>") && !request.system.contains("<kapsam>"))
        #expect(request.userText.range(of: #"tarih="\d{4}-\d{2}-\d{2} \d{2}:\d{2}""#, options: .regularExpression) != nil)
    }

    // Adsız konuşmacılar parçalarda cevap dilinin etiketiyle geçer: notun dilindeki "Konuşmacı 2" ve transkriptteki adsız
    // kişi "Speaker N" olur; ad verilmiş konuşmacı adıyla kalır.
    @Test func passagesUseTheAnswerLanguageSpeakerLabel() {
        let record: MeetingRecord = MeetingRecord(
            id: "s", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_790_000_000), endedAt: nil, language: .finnish,
            status: .done, failureMessage: nil, liveSegments: [],
            finalSegments: [stored("final-0", .others, 1, 0, "Hei."), stored("final-1", .others, 2, 10, "Moi.")],
            translations: [:], speakerNames: [2: "Aino"],
            note: MeetingNote(
                title: "Haftalık", summary: "Konuşmacı 1 bütçeyi anlattı.", decisions: [],
                tasks: [NoteTask(owner: "Konuşmacı 1", description: "Raporu yaz", dueDate: nil, isMine: false)], glossary: []
            ).with(language: .turkish),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let text: String = archivePassages(records: [record], userLabel: promptUserLabel, speakerWord: speakerLabelWord(language: .english)).map(\.text).joined(separator: "\n")
        #expect(text.contains("Özet: Speaker 1 bütçeyi anlattı.") && text.contains("Görev: Speaker 1 — Raporu yaz"))
        #expect(text.contains("[00:00] Speaker 1: Hei.") && text.contains("[00:10] Aino: Moi."))
        #expect(!text.contains("Konuşmacı"))
    }

    // Etiket çevirisi yalnız tam etiketi değiştirir: daha uzun sözcük ya da sayı içindeki etiket kalır.
    @Test func relabelingSpeakersChangesOnlyLabels() {
        #expect(relabelingSpeakers(text: "Konuşmacı 2 ve konuşmacı 12 geldi.", from: "Konuşmacı", to: "Speaker") == "Speaker 2 ve Speaker 12 geldi.")
        #expect(relabelingSpeakers(text: "Loudspeaker 1 ok", from: "Speaker", to: "Puhuja") == "Loudspeaker 1 ok")
        #expect(relabelingSpeakers(text: "发言人2说", from: "发言人", to: "Speaker") == "Speaker 2说")
        #expect(relabelingSpeakers(text: "Speaker 2", from: "Speaker", to: "speaker") == "Speaker 2")
    }
}
