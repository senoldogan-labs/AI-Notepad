import Foundation
import Testing
@testable import KeyboardCore

/// How a finished dictation is written into the field under the user's dictation options.
@Suite struct KeyboardDictationFormatTests {
    private let all: KeyboardDictationOptions = .standard
    private let none: KeyboardDictationOptions = KeyboardDictationOptions(
        spokenPunctuation: false, formatLists: false, cleanUp: false, endWithPeriod: true, lowercase: false
    )

    private func format(_ text: String, _ language: String) -> String {
        keyboardFormatDictation(text: text, languageCode: language, options: all)
    }

    @Test func optionsOffLeaveTheTextAlone() {
        let text: String = "Um, first, milk. Second, eggs comma period"
        #expect(keyboardFormatDictation(text: text, languageCode: "en", options: none) == text)
    }

    @Test func spokenMarksReplaceTheGuessedPunctuation() {
        #expect(format("Hello comma how are you question mark", "en") == "Hello, how are you?")
        #expect(format("Hello. Comma. How are you? Question mark.", "en") == "Hello, how are you?")
        #expect(format("Great exclamation mark see you there", "en") == "Great! See you there")
        #expect(format("Dear Anna. New line. Thanks for the notes", "en") == "Dear Anna.\nThanks for the notes")
        #expect(format("Agenda, colon, budget and hiring", "en") == "Agenda: budget and hiring")
        #expect(format("Merhaba virgül nasılsın soru işareti", "tr-TR") == "Merhaba, nasılsın?")
        #expect(format("Toplantı bitti. Yeni paragraf. İlk konu bütçe", "tr") == "Toplantı bitti.\n\nİlk konu bütçe")
        #expect(format("Liste iki nokta üst üste elma ve armut", "tr") == "Liste: elma ve armut")
        #expect(format("Bonjour virgule ça va point d'interrogation", "fr") == "Bonjour, ça va?")
        #expect(format("Hallo Komma wie geht's Fragezeichen", "de") == "Hallo, wie geht's?")
    }

    @Test func commonWordsAreMarksOnlyAtTheEnd() {
        #expect(format("The trial period ends today period", "en") == "The trial period ends today.")
        #expect(format("Bu nokta önemli", "tr") == "Bu nokta önemli")
        #expect(format("Bu nokta önemli nokta", "tr") == "Bu nokta önemli.")
        #expect(format("İki nokta var", "tr") == "İki nokta var")
        #expect(format("We launched a new line of products", "en") == "We launched a new line of products")
        #expect(format("Quiero que coma más", "es") == "Quiero que coma más")
        #expect(format("Tenemos dos puntos que discutir", "es") == "Tenemos dos puntos que discutir")
        #expect(format("È a capo del team", "it") == "È a capo del team")
        #expect(format("Temos dois pontos e uma nova linha de produtos", "pt") == "Temos dois pontos e uma nova linha de produtos")
        #expect(format("Il a mis un point final au projet", "fr") == "Il a mis un point final au projet")
    }

    @Test func aMarkWithNothingBeforeItIsDropped() {
        #expect(format("Comma hello", "en") == "hello")
    }

    @Test func fillersAndStuttersGo() {
        #expect(format("Um, I think, uh, we should go.", "en") == "I think we should go.")
        #expect(format("I I think the the plan works", "en") == "I think the plan works")
        #expect(format("The the plan works", "en") == "The plan works")
        #expect(format("Ii ıı bence eee olur", "tr") == "Ii bence olur")
        #expect(format("Ben ben de geliyorum", "tr") == "Ben de geliyorum")
        #expect(format("Yavaş yavaş tek tek bakalım", "tr") == "Yavaş yavaş tek tek bakalım")
        #expect(format("No no no, very very good", "en") == "No no no, very very good")
        #expect(format("Ok uh.", "en") == "Ok.")
        #expect(format("Ich ich glaube, äh, das passt", "de") == "Ich glaube das passt")
    }

    @Test func realWordsAreNotFillersOrStutters() {
        #expect(format("Wir treffen uns um zehn Uhr", "de") == "Wir treffen uns um zehn Uhr")
        #expect(format("Tenho um problema", "pt") == "Tenho um problema")
        #expect(format("I think that that works and she had had enough", "en") == "I think that that works and she had had enough")
        #expect(format("Das ist die die Liste, der der kommt", "de") == "Das ist die die Liste, der der kommt")
        #expect(format("I told you you were right, if you need it it's there", "en") == "I told you you were right, if you need it it's there")
        #expect(format("Ik vind het het beste", "nl") == "Ik vind het het beste")
    }

    @Test func ordinalsMakeANumberedList() {
        #expect(format("Shopping list. First, milk. Second, eggs. Third, bread.", "en") == "Shopping list.\n1. Milk\n2. Eggs\n3. Bread")
        #expect(format("Plan, first, call Anna, second, send the deck", "en") == "Plan:\n1. Call Anna\n2. Send the deck")
        #expect(format("Birinci, bütçeyi gönder. İkinci, toplantıyı ayarla.", "tr") == "1. Bütçeyi gönder\n2. Toplantıyı ayarla")
    }

    @Test func ordinalsInProseStayProse() {
        let prose: String = "The first one was better than the second one."
        #expect(format(prose, "en") == prose)
        #expect(format("First, we met. Then we left.", "en") == "First, we met. Then we left.")
    }

    @Test func bulletsMakeABulletedList() {
        #expect(format("Bullet milk bullet point eggs", "en") == "- Milk\n- Eggs")
        #expect(format("Alınacaklar: madde süt, madde yumurta", "tr") == "Alınacaklar:\n- Süt\n- Yumurta")
        #expect(format("Bu madde tehlikeli, o madde de", "tr") == "Bu madde tehlikeli, o madde de")
    }

    @Test func finalPeriodAndLowercase() {
        let noPeriod: KeyboardDictationOptions = KeyboardDictationOptions(
            spokenPunctuation: true, formatLists: true, cleanUp: true, endWithPeriod: false, lowercase: false
        )
        #expect(keyboardFormatDictation(text: "See you soon.", languageCode: "en", options: noPeriod) == "See you soon")
        #expect(keyboardFormatDictation(text: "Really?", languageCode: "en", options: noPeriod) == "Really?")
        #expect(keyboardFormatDictation(text: "Well...", languageCode: "en", options: noPeriod) == "Well...")
        let lower: KeyboardDictationOptions = KeyboardDictationOptions(
            spokenPunctuation: true, formatLists: true, cleanUp: true, endWithPeriod: true, lowercase: true
        )
        #expect(keyboardFormatDictation(text: "Istanbul'da İzmir", languageCode: "tr", options: lower) == "ıstanbul'da izmir")
        #expect(keyboardFormatDictation(text: "I am In Istanbul", languageCode: "en", options: lower) == "i am in istanbul")
    }

    @Test func linesAndSpacesSurvive() {
        #expect(format("Hello\n\nWorld  again", "en") == "Hello\n\nWorld again")
        #expect(format("こんにちは。", "ja") == "こんにちは。")
    }

    @Test func micSideMovesTheMicrophoneKey() {
        let right: KeyboardLayoutOptions = KeyboardLayoutOptions(
            showsGlobe: false, showsMicrophone: true, showsLanguage: false, field: .text, microphoneSide: .right
        )
        let bottom: [KeyboardKeyKind] = keyboardRows(language: .english, page: .letters, options: right).last?.map(\.kind) ?? []
        #expect(bottom.suffix(2).first == .microphone)
        #expect(bottom.firstIndex(of: .microphone).map { $0 > (bottom.firstIndex(of: .space) ?? 0) } == true)
    }

    @Test func oldConfigsDecodeWithoutTheNewOptions() throws {
        let json: String = """
        {"languages":["tr"],"autocorrect":true,"swipeTyping":true,"mechanicalSounds":false,"sessionMinutes":15,
         "meetingNotesEnabled":false,"vocabulary":[]}
        """
        let config: KeyboardSharedConfig = try JSONDecoder().decode(KeyboardSharedConfig.self, from: Data(json.utf8))
        #expect(config.dictationOptions == nil)
        #expect(config.typingOptions == nil)
    }
}
