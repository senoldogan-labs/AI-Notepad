import Foundation
import Testing

@testable import KeyboardCore

@Suite struct KeyboardTypingChoicesTests {
    private func options(field: KeyboardFieldKind, commaPeriod: Bool, side: KeyboardMicrophoneSide) -> KeyboardLayoutOptions {
        KeyboardLayoutOptions(
            showsGlobe: true, showsMicrophone: true, showsLanguage: true, field: field, microphoneSide: side, showsCommaPeriod: commaPeriod
        )
    }

    @Test func oldConfigsDecodeWithTheDefaultChoices() throws {
        let typing: KeyboardTypingOptions = try JSONDecoder().decode(
            KeyboardTypingOptions.self, from: Data(#"{"haptics":"off","microphoneSide":"left","autoCapitalization":true,"keyPopups":true}"#.utf8)
        )
        #expect(typing.choices == nil)
        #expect(typing.typingChoices == .standard)
        #expect(!typing.typingChoices.commaPeriodKeys && typing.typingChoices.emojiShortcodes && typing.typingChoices.learnPerLanguage)
    }

    @Test func commaAndPeriodSurroundTheSpaceBarOnLettersOfTextFields() {
        for side in [KeyboardMicrophoneSide.left, .right] {
            let row: [KeyboardKey] = keyboardRows(language: .english, page: .letters, options: options(field: .text, commaPeriod: true, side: side)).last ?? []
            let kinds: [KeyboardKeyKind] = row.map(\.kind)
            let space: Int = kinds.firstIndex(of: .space) ?? -1
            #expect(kinds[space - 1] == .character(",") && kinds[space + 1] == .character("."))
            #expect(kinds.contains(.microphone) && kinds.contains(.globe) && kinds.contains(.page(.numbers)))
            let widths: [Double] = keyboardRows(language: .english, page: .letters, options: options(field: .text, commaPeriod: true, side: side)).map {
                (rowKeys: [KeyboardKey]) -> Double in rowKeys.reduce(0) { $0 + $1.widthUnits }
            }
            #expect(abs((widths.last ?? 0) - (widths.first ?? 0)) < 0.0001)
            #expect((row.first { $0.kind == .space }?.widthUnits ?? 0) >= 2 - 0.0001)
        }
    }

    @Test func addressFieldsAndOtherPagesKeepTheirOwnBottomRow() {
        for field in [KeyboardFieldKind.email, .url] {
            let with: [KeyboardKey] = keyboardRows(language: .english, page: .letters, options: options(field: field, commaPeriod: true, side: .left)).last ?? []
            let without: [KeyboardKey] = keyboardRows(language: .english, page: .letters, options: options(field: field, commaPeriod: false, side: .left)).last ?? []
            #expect(with == without)
            #expect(with.filter { $0.kind == .character(".") }.count == 1)
        }
        let numbers: [KeyboardKey] = keyboardRows(language: .english, page: .numbers, options: options(field: .text, commaPeriod: true, side: .left)).last ?? []
        #expect(!numbers.contains { $0.kind == .character(",") })
    }

    @Test func everyTouchLandsOnOneKeyWithCommaAndPeriod() {
        for language in [KeyboardLanguage.english, .turkish, .german] {
            let metrics: KeyboardMetrics = keyboardMetrics(width: 402, height: 216, rows: 4, style: keyboardPortraitKeyStyle)
            let frames: [KeyboardKeyFrame] = keyboardKeyFrames(
                rows: keyboardRows(language: language, page: .letters, options: options(field: .text, commaPeriod: true, side: .left)), metrics: metrics
            )
            for x in stride(from: CGFloat(0), to: 402, by: 1.5) {
                for y in stride(from: CGFloat(0), to: 216, by: 1.5) {
                    #expect(frames.filter { $0.hitFrame.contains(CGPoint(x: x, y: y)) }.count == 1, "\(language) \(x) \(y)")
                }
            }
        }
    }

    @Test func quickAccentsPreselectTheMainAccent() {
        func index(_ character: String, _ language: KeyboardLanguage) -> String? {
            let alternates: [String] = keyboardAlternates(character: character, language: language)
            return keyboardQuickAccentIndex(alternates: alternates, language: language).map { alternates[$0] }
        }
        #expect(index("e", .french) == "é")
        #expect(index("e", .english) == "é")
        #expect(index("s", .german) == "ß")
        #expect(index("u", .french) == "ù")
        #expect(index("a", .spanish) == "á")
        #expect(index("c", .turkish) == nil)
        #expect(index("a", .english) == nil)
        #expect(index("x", .english) == nil)
        #expect(index(".", .english) == nil)
    }

    @Test func shortcodesNeedAColonThatStartsAWordAndTwoLetters() {
        #expect(keyboardEmojiShortcode(contextBefore: "hi :pizza") == KeyboardEmojiShortcode(query: "pizza", length: 6))
        #expect(keyboardEmojiShortcode(contextBefore: ":pi")?.query == "pi")
        #expect(keyboardEmojiShortcode(contextBefore: "(:pi")?.query == "pi")
        #expect(keyboardEmojiShortcode(contextBefore: "hi :p") == nil)
        #expect(keyboardEmojiShortcode(contextBefore: "meet at 10:30") == nil)
        #expect(keyboardEmojiShortcode(contextBefore: "10:am") == nil)
        #expect(keyboardEmojiShortcode(contextBefore: "see https://pizza") == nil)
        #expect(keyboardEmojiShortcode(contextBefore: "hi pizza") == nil)
        #expect(keyboardEmojiShortcode(contextBefore: "hi ::pizza") == nil)
    }

    @Test func shortcodeMatchesRankExactFirstAndUseLocalKeywords() {
        #expect(keyboardEmojiShortcodeMatches(query: "pizza", language: .english, limit: 3) == ["🍕"])
        #expect(keyboardEmojiShortcodeMatches(query: "pi", language: .english, limit: 8).contains("🍕"))
        #expect(keyboardEmojiShortcodeMatches(query: "kedi", language: .turkish, limit: 3) == ["🐱"])
        #expect(keyboardEmojiShortcodeMatches(query: "kedi", language: .english, limit: 3).isEmpty)
        #expect(keyboardEmojiShortcodeMatches(query: "cat", language: .turkish, limit: 3).first == "🐱")
        #expect(keyboardEmojiShortcodeMatches(query: "ha", language: .english, limit: 2).count == 2)
        #expect(keyboardEmojiShortcodeMatches(query: "zzzzqq", language: .english, limit: 3).isEmpty)
    }

    @Test func learnedWordsStayWithTheirLanguageAndNothingIsLostOnMigration() {
        let migrated: KeyboardLearnedStore = keyboardLearnedStoreMigrating(legacyWords: ["gistsmith"])
        var store: KeyboardLearnedStore = keyboardLearnedStoreAdding(migrated, word: "kanka", language: .turkish, perLanguage: true, limit: 500)
        store = keyboardLearnedStoreAdding(store, word: "wanna", language: .english, perLanguage: true, limit: 500)
        #expect(keyboardLearnedWords(in: store, language: .turkish, perLanguage: true) == ["gistsmith", "kanka"])
        #expect(keyboardLearnedWords(in: store, language: .english, perLanguage: true) == ["gistsmith", "wanna"])
        #expect(Set(keyboardLearnedWords(in: store, language: .english, perLanguage: false)) == ["gistsmith", "kanka", "wanna"])
        #expect(Set(keyboardLearnedWordsAll(in: store)) == ["gistsmith", "kanka", "wanna"])
        let together: KeyboardLearnedStore = keyboardLearnedStoreAdding(store, word: "ciao", language: .italian, perLanguage: false, limit: 500)
        #expect(together.shared == ["gistsmith", "ciao"])
        #expect(keyboardLearningScope(language: .turkish, perLanguage: true) != keyboardLearningScope(language: .english, perLanguage: true))
        #expect(keyboardLearningScope(language: .turkish, perLanguage: false) == keyboardLearningScope(language: .english, perLanguage: false))
    }
}
