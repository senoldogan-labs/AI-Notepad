import CoreGraphics
import Foundation
import Testing
@testable import KeyboardCore

/// Klavyenin saf parçaları: düzen, metin kuralları, öneri ve düzeltme sıralaması, sesle yazma devri.
@Suite struct KeyboardTextRulesTests {
    // Türkçede büyük harf yerel kurala uyar: i → İ, ı → I.
    @Test func turkishCasingUsesLocaleRules() {
        #expect(keyboardUppercased("i", language: .turkish) == "İ")
        #expect(keyboardUppercased("ı", language: .turkish) == "I")
        #expect(keyboardUppercased("i", language: .english) == "I")
        #expect(keyboardCapitalizedFirst("istanbul", language: .turkish) == "İstanbul")
    }

    @Test func currentWordKeepsInWordApostrophes() {
        #expect(keyboardCurrentWord(contextBefore: "Merhaba Ali'nin") == "Ali'nin")
        #expect(keyboardCurrentWord(contextBefore: "c'est l'homme") == "l'homme")
        #expect(keyboardCurrentWord(contextBefore: "Hello, wor") == "wor")
        #expect(keyboardCurrentWord(contextBefore: "Hello ") == "")
    }

    @Test func sentenceCapitalization() {
        #expect(keyboardShouldCapitalize(contextBefore: "", rule: .sentences))
        #expect(keyboardShouldCapitalize(contextBefore: "Done. ", rule: .sentences))
        #expect(keyboardShouldCapitalize(contextBefore: "Really?  ", rule: .sentences))
        #expect(keyboardShouldCapitalize(contextBefore: "Line\n", rule: .sentences))
        #expect(!keyboardShouldCapitalize(contextBefore: "Hello ", rule: .sentences))
        #expect(!keyboardShouldCapitalize(contextBefore: "Hello", rule: .sentences))
        #expect(!keyboardShouldCapitalize(contextBefore: "", rule: .none))
        #expect(keyboardShouldCapitalize(contextBefore: "New ", rule: .words))
    }

    @Test func doubleSpacePeriodOnlyAfterAWord() {
        #expect(keyboardDoubleSpacePeriod(contextBefore: "Hello ") == 1)
        #expect(keyboardDoubleSpacePeriod(contextBefore: "Hello. ") == nil)
        #expect(keyboardDoubleSpacePeriod(contextBefore: "Hello  ") == nil)
        #expect(keyboardDoubleSpacePeriod(contextBefore: " ") == nil)
    }

    @Test func englishContractions() {
        #expect(keyboardContraction(word: "dont", language: .english)?.replacement == "don't")
        #expect(keyboardContraction(word: "Dont", language: .english)?.replacement == "Don't")
        #expect(keyboardContraction(word: "i", language: .english)?.replacement == "I")
        #expect(keyboardContraction(word: "ill", language: .english)?.autoApply == false)
        #expect(keyboardContraction(word: "dont", language: .turkish) == nil)
    }

    // Hassas alanlarda öğrenme ve kendiliğinden düzeltme kapalı.
    @Test func sensitiveFieldsDisableLearning() {
        #expect(keyboardAllowsLearning(traits: KeyboardFieldTraits(autocorrectionDisabled: false, contentType: nil, isNumeric: false)))
        #expect(!keyboardAllowsLearning(traits: KeyboardFieldTraits(autocorrectionDisabled: false, contentType: "one-time-code", isNumeric: false)))
        #expect(!keyboardAllowsLearning(traits: KeyboardFieldTraits(autocorrectionDisabled: false, contentType: "password", isNumeric: false)))
        #expect(!keyboardAllowsLearning(traits: KeyboardFieldTraits(autocorrectionDisabled: true, contentType: nil, isNumeric: false)))
        #expect(!keyboardAllowsLearning(traits: KeyboardFieldTraits(autocorrectionDisabled: false, contentType: nil, isNumeric: true)))
        #expect(!keyboardIsLearnable(word: "abc123"))
        #expect(keyboardIsLearnable(word: "Gistsmith"))
    }
}

@Suite struct KeyboardLayoutTests {
    private let options: KeyboardLayoutOptions = KeyboardLayoutOptions(showsGlobe: false, showsMicrophone: true, showsLanguage: false, field: .text)

    @Test func everyLanguageHasThreeLetterRowsAndABottomRow() {
        for language in KeyboardLanguage.allCases {
            let rows: [[KeyboardKey]] = keyboardRows(language: language, page: .letters, options: options)
            #expect(rows.count == 4)
            #expect(rows[2].first?.kind == .shift)
            #expect(rows[2].last?.kind == .delete)
            #expect(rows[3].contains { $0.kind == .space })
            #expect(rows[3].contains { $0.kind == .microphone })
        }
    }

    @Test func turkishLayoutHasTurkishLetters() {
        let letters: String = keyboardLetterRows(language: .turkish).joined()
        for letter in ["ğ", "ü", "ş", "ı", "i", "ö", "ç"] {
            #expect(letters.contains(letter))
        }
    }

    @Test func emailFieldAddsAtAndDot() {
        let email: KeyboardLayoutOptions = KeyboardLayoutOptions(showsGlobe: true, showsMicrophone: false, showsLanguage: false, field: .email)
        let bottom: [KeyboardKey] = keyboardRows(language: .english, page: .letters, options: email)[3]
        #expect(bottom.contains { $0.kind == .character("@") })
        #expect(bottom.contains { $0.kind == .globe })
        #expect(!bottom.contains { $0.kind == .microphone })
    }

    @Test func alternatesStartWithDigitOnTopRowAndSkipKeysOnTheLayout() {
        #expect(keyboardAlternates(character: "q", language: .english).first == "1")
        #expect(keyboardAlternates(character: "p", language: .english).first == "0")
        #expect(keyboardAlternates(character: "e", language: .french).dropFirst().first == "é")
        // Türkçe düzende "ç" kendi tuşunda: "c"nin seçeneklerinde yok.
        #expect(!keyboardAlternates(character: "c", language: .turkish).contains("ç"))
        #expect(keyboardAlternates(character: "s", language: .german).contains("ß"))
    }

    @Test func framesFillTheWidthAndHitTestingFindsTheNearestKey() {
        let rows: [[KeyboardKey]] = keyboardRows(language: .english, page: .letters, options: options)
        let metrics: KeyboardMetrics = KeyboardMetrics(
            width: 390, height: 216, horizontalGap: 6, verticalGap: 10, sideInset: 3, topInset: 4, bottomInset: 4, maximumKeysWidth: 640
        )
        let frames: [KeyboardKeyFrame] = keyboardKeyFrames(rows: rows, metrics: metrics)
        #expect(frames.count == rows.flatMap { $0 }.count)
        let q: KeyboardKeyFrame? = frames.first { $0.key.kind == .character("q") }
        #expect(q?.frame.minX ?? 0 > 3)
        // Kenara düşen dokunuş ilk tuşa gider; tuşlar arası boşluk boşa gitmez.
        #expect(keyboardKeyFrame(at: CGPoint(x: 0, y: 2), frames: frames)?.key.kind == .character("q"))
        // Orta satır ortalanır; satırın solundaki boşluk "a"ya gider.
        let a: KeyboardKeyFrame? = frames.first { $0.key.kind == .character("a") }
        #expect(keyboardKeyFrame(at: CGPoint(x: 1, y: a?.frame.midY ?? 0), frames: frames)?.key.kind == .character("a"))
    }

    // Açılmış iPhone Duo: tuşlar en fazla verilen genişlikte, ortada.
    @Test func wideScreensCenterTheKeys() {
        let rows: [[KeyboardKey]] = keyboardRows(language: .english, page: .letters, options: options)
        let metrics: KeyboardMetrics = KeyboardMetrics(
            width: 951, height: 216, horizontalGap: 6, verticalGap: 10, sideInset: 3, topInset: 4, bottomInset: 4, maximumKeysWidth: 640
        )
        let frames: [KeyboardKeyFrame] = keyboardKeyFrames(rows: rows, metrics: metrics)
        let minX: CGFloat = frames.map(\.frame.minX).min() ?? 0
        let maxX: CGFloat = frames.map(\.frame.maxX).max() ?? 0
        #expect(maxX - minX <= 640)
        #expect(abs((minX + maxX) / 2 - 951 / 2) < 1)
    }

    @Test func emojiCategoriesAreFilled() {
        for category in KeyboardEmojiCategory.allCases {
            #expect(!keyboardEmoji(category: category).isEmpty)
        }
        #expect(keyboardEmoji(category: .smileysAndPeople).first == "😀")
        #expect(keyboardRecentEmojiAdding(emoji: "👍", to: ["😀", "👍", "🎉"], limit: 2) == ["👍", "😀"])
    }

    @Test func defaultLanguagesFollowTheDevice() {
        #expect(defaultKeyboardLanguages(preferredLanguages: ["tr-TR", "en-US", "ja-JP"]) == [.turkish, .english])
        #expect(defaultKeyboardLanguages(preferredLanguages: ["ja-JP"]) == [.english])
        #expect(keyboardLanguage(identifier: "no-NO") == .norwegian)
    }
}

@Suite struct KeyboardAutocorrectTests {
    private func input(
        _ typed: String, known: Bool, guesses: [String], completions: [String] = [], personal: [String] = [], rejected: Set<String> = [],
        allowed: Bool = true, language: KeyboardLanguage = .english
    ) -> KeyboardSuggestionInput {
        KeyboardSuggestionInput(
            typed: typed, language: language, isKnownWord: known, guesses: guesses, completions: completions, personalWords: personal,
            shortcuts: ["omw": "On my way!"], rejected: rejected, autocorrectAllowed: allowed
        )
    }

    @Test func correctsAClearTypo() {
        let result: KeyboardSuggestions = keyboardSuggestions(input: input("teh", known: false, guesses: ["the", "ten"]))
        #expect(result.autocorrection == "the")
        #expect(result.items.first == KeyboardSuggestion(text: "teh", kind: .typed))
    }

    @Test func keepsCaseOfTypedWord() {
        #expect(keyboardSuggestions(input: input("Teh", known: false, guesses: ["the"])).autocorrection == "The")
        #expect(keyboardSuggestions(input: input("TEH", known: false, guesses: ["the"])).autocorrection == "THE")
    }

    // Kişisel sözlükteki ad düzeltilmez; küçük yazılırsa sözlükteki yazımına getirilir.
    @Test func dictionaryWordsAreNeverCorrected() {
        let personal: [String] = ["Gistsmith", "Senol"]
        #expect(keyboardSuggestions(input: input("Gistsmith", known: false, guesses: ["Goldsmith"], personal: personal)).autocorrection == nil)
        #expect(keyboardSuggestions(input: input("gistsmith", known: false, guesses: ["goldsmith"], personal: personal)).autocorrection == "Gistsmith")
        // Yakın yazım sözlükteki kelimeye düzelir, dil sözlüğünün önerisine değil.
        #expect(keyboardSuggestions(input: input("Senl", known: false, guesses: ["Seal"], personal: personal)).autocorrection == "Senol")
    }

    @Test func knownRejectedAndUnsafeWordsStayAsTyped() {
        #expect(keyboardSuggestions(input: input("hello", known: true, guesses: [])).autocorrection == nil)
        #expect(keyboardSuggestions(input: input("teh", known: false, guesses: ["the"], rejected: ["teh"])).autocorrection == nil)
        #expect(keyboardSuggestions(input: input("teh", known: false, guesses: ["the"], allowed: false)).autocorrection == nil)
        #expect(keyboardSuggestions(input: input("iPhne", known: false, guesses: ["iPhone"])).autocorrection == nil)
        #expect(keyboardSuggestions(input: input("ab", known: false, guesses: ["an"])).autocorrection == nil)
        // Uzak aday düzeltilmez.
        #expect(keyboardSuggestions(input: input("xyzzy", known: false, guesses: ["fuzzy"])).autocorrection == nil)
    }

    @Test func ambiguousLongCorrectionsAreOnlySuggested() {
        let result: KeyboardSuggestions = keyboardSuggestions(input: input("abcdefgh", known: false, guesses: ["abcdefxy", "abcdexgy"]))
        #expect(result.autocorrection == nil)
    }

    @Test func shortcutsAndContractionsApply() {
        #expect(keyboardSuggestions(input: input("omw", known: false, guesses: [])).autocorrection == "On my way!")
        #expect(keyboardSuggestions(input: input("dont", known: false, guesses: ["dint"])).autocorrection == "don't")
        #expect(keyboardSuggestions(input: input("i", known: true, guesses: [])).autocorrection == "I")
    }

    @Test func completionsPreferPersonalWords() {
        let result: KeyboardSuggestions = keyboardSuggestions(
            input: input("gis", known: false, guesses: [], completions: ["gist", "gissing"], personal: ["Gistsmith"])
        )
        #expect(result.autocorrection == nil)
        #expect(result.items.map(\.text) == ["gis", "Gistsmith", "gist"])
    }

    @Test func editDistanceCountsTranspositionsOnce() {
        #expect(keyboardEditDistance("teh", "the") == 1)
        #expect(keyboardEditDistance("kitten", "sitting") == 3)
        #expect(keyboardEditDistance("", "abc") == 3)
    }

    @Test func learnedWordsMoveToTheEndAndAreCapped() {
        #expect(keyboardLearnedWordsAdding(word: "Zed", to: ["Ada", "Zed", "Bo"], limit: 3) == ["Ada", "Bo", "Zed"])
        #expect(keyboardLearnedWordsAdding(word: "Cy", to: ["Ada", "Bo"], limit: 2) == ["Bo", "Cy"])
        #expect(keyboardLearnedWordsAdding(word: "x1", to: ["Ada"], limit: 2) == ["Ada"])
    }
}

@Suite struct KeyboardLinkTests {
    @Test func parsesKeyboardLinksOnly() {
        let id: UUID = UUID()
        #expect(keyboardLinkRoute(url: keyboardDictateURL(requestID: id)) == .dictate(requestID: id))
        #expect(keyboardLinkRoute(url: keyboardSetupURL) == .setup)
        #expect(keyboardLinkRoute(url: URL(string: "gistsmith://keyboard/dictate/not-a-uuid")!) == nil)
        #expect(keyboardLinkRoute(url: URL(string: "gistsmith://record")!) == nil)
        #expect(keyboardLinkRoute(url: URL(string: "https://gistsmith.com/open/keyboard/setup")!) == nil)
    }
}

@Suite struct KeyboardHandoffTests {
    private let now: Date = Date(timeIntervalSince1970: 1_000_000)
    private let document: UUID = UUID()
    private let request: UUID = UUID()

    private func command(_ action: KeyboardDictationCommand.Action, age: TimeInterval) -> KeyboardDictationCommand {
        KeyboardDictationCommand(requestID: request, action: action, documentID: document, languageCode: "en", issuedAt: now.addingTimeInterval(-age))
    }

    private func status(phase: KeyboardDictation.Phase?, live: Bool, documentID: UUID?, finalText: String? = nil) -> KeyboardDictationStatus {
        let session: KeyboardSession? =
            live
            ? KeyboardSession(startedAt: now.addingTimeInterval(-30), expiresAt: now.addingTimeInterval(240), heartbeatAt: now.addingTimeInterval(-1)) : nil
        let dictation: KeyboardDictation? = phase.map {
            KeyboardDictation(requestID: request, documentID: documentID, phase: $0, partialText: "hello wor", finalText: finalText, failure: nil)
        }
        return KeyboardDictationStatus(session: session, dictation: dictation)
    }

    private func state(_ status: KeyboardDictationStatus?, _ last: KeyboardDictationCommand?, documentID: UUID? = nil) -> KeyboardMicState {
        keyboardMicState(hasFullAccess: true, status: status, lastCommand: last, documentID: documentID ?? document, now: now)
    }

    @Test func withoutFullAccessVoiceIsUnavailable() {
        #expect(keyboardMicState(hasFullAccess: false, status: nil, lastCommand: nil, documentID: document, now: now) == .needsFullAccess)
    }

    @Test func idleWithAndWithoutSession() {
        #expect(state(nil, nil) == .idle(sessionRemaining: nil))
        #expect(state(status(phase: nil, live: true, documentID: nil), nil) == .idle(sessionRemaining: 240))
    }

    // Nabız eskiyse (uygulama kapandı) dinleme sürüyor sayılmaz.
    @Test func staleHeartbeatEndsTheSession() {
        let stale: KeyboardDictationStatus = KeyboardDictationStatus(
            session: KeyboardSession(startedAt: now.addingTimeInterval(-60), expiresAt: now.addingTimeInterval(200), heartbeatAt: now.addingTimeInterval(-10)),
            dictation: KeyboardDictation(requestID: request, documentID: document, phase: .listening, partialText: "x", finalText: nil, failure: nil)
        )
        #expect(state(stale, command(.start, age: 30)) == .idle(sessionRemaining: nil))
    }

    @Test func freshStartShowsStartingUntilTheAppAnswers() {
        #expect(state(nil, command(.start, age: 2)) == .starting)
        #expect(state(nil, command(.start, age: 60)) == .idle(sessionRemaining: nil))
    }

    @Test func listeningAndFinishingShowLiveText() {
        #expect(state(status(phase: .listening, live: true, documentID: document), command(.start, age: 20)) == .listening(text: "hello wor"))
        #expect(state(status(phase: .finishing, live: true, documentID: document), command(.stop, age: 1)) == .finishing(text: "hello wor"))
    }

    // Bitmiş metin yalnız isteyen alana kendiliğinden eklenir; başka alanda "Ekle" ile sunulur; eklenince şerit kapanır.
    @Test func finishedTextAutoInsertsOnlyIntoTheSameDocument() {
        let finished: KeyboardDictationStatus = status(phase: .finished, live: true, documentID: document, finalText: "Hello world.")
        #expect(state(finished, command(.stop, age: 1)) == .finished(text: "Hello world.", autoInsert: true))
        #expect(state(finished, command(.stop, age: 1), documentID: UUID()) == .finished(text: "Hello world.", autoInsert: false))
        #expect(state(finished, command(.acknowledge, age: 0)) == .idle(sessionRemaining: 240))
    }

    // Oturumu kapanmış (uygulama kapandı) bitmiş metin sunulmaz ve silinecek metin sayılır.
    @Test func finishedTextWithoutLiveSessionIsOrphaned() {
        let orphaned: KeyboardDictationStatus = status(phase: .finished, live: false, documentID: document, finalText: "Hello.")
        #expect(state(orphaned, command(.stop, age: 1)) == .idle(sessionRemaining: nil))
        #expect(keyboardStatusHasOrphanedText(status: orphaned, now: now))
        #expect(!keyboardStatusHasOrphanedText(status: status(phase: .finished, live: true, documentID: document, finalText: "Hi."), now: now))
        #expect(!keyboardStatusHasOrphanedText(status: status(phase: .failed, live: false, documentID: document), now: now))
        // Dinlerken kapanan uygulamanın ara metni de kalmaz.
        for phase: KeyboardDictation.Phase in [.preparing, .listening, .finishing] {
            #expect(keyboardStatusHasOrphanedText(status: status(phase: phase, live: false, documentID: document), now: now))
            #expect(!keyboardStatusHasOrphanedText(status: status(phase: phase, live: true, documentID: document), now: now))
        }
    }

    // Klavye ekleyince ya da bırakınca sonucu kendisi siler; başka diktenin durumuna dokunmaz.
    @Test func clearingRemovesOnlyThatDictation() {
        let finished: KeyboardDictationStatus = status(phase: .finished, live: true, documentID: document, finalText: "Hello.")
        let cleared: KeyboardDictationStatus? = keyboardStatusClearingDictation(status: finished, requestID: request)
        #expect(cleared?.dictation == nil)
        #expect(cleared?.session == finished.session)
        #expect(keyboardStatusClearingDictation(status: finished, requestID: UUID()) == nil)
        #expect(keyboardStatusClearingDictation(status: nil, requestID: request) == nil)
    }

    @Test func failureShowsUntilDismissed() {
        let failed: KeyboardDictationStatus = KeyboardDictationStatus(
            session: nil,
            dictation: KeyboardDictation(requestID: request, documentID: document, phase: .failed, partialText: "", finalText: nil, failure: .recordingMeeting)
        )
        #expect(state(failed, command(.start, age: 40)) == .failed(.recordingMeeting))
        #expect(state(failed, command(.cancel, age: 0)) == .idle(sessionRemaining: nil))
    }

    // Bağlantı yalnız klavyenin az önce bıraktığı aynı başlatma komutuyla mikrofonu açar.
    @Test func linkStartsOnlyForAFreshMatchingCommand() {
        let command: KeyboardDictationCommand = KeyboardDictationCommand(
            requestID: request, action: .start, documentID: document, languageCode: "en", issuedAt: now.addingTimeInterval(-3)
        )
        #expect(keyboardStartCommandIsValid(command: command, requestID: request, now: now))
        #expect(!keyboardStartCommandIsValid(command: command, requestID: UUID(), now: now))
        #expect(!keyboardStartCommandIsValid(command: nil, requestID: request, now: now))
        #expect(!keyboardStartCommandIsValid(command: command, requestID: request, now: now.addingTimeInterval(30)))
        let stop: KeyboardDictationCommand = KeyboardDictationCommand(
            requestID: request, action: .stop, documentID: document, languageCode: "en", issuedAt: now
        )
        #expect(!keyboardStartCommandIsValid(command: stop, requestID: request, now: now))
    }

    @Test func insertionAddsASpaceOnlyAfterAWord() {
        #expect(keyboardDictationInsertion(text: " Hello. ", contextBefore: "Hi") == " Hello.")
        #expect(keyboardDictationInsertion(text: "Hello.", contextBefore: "Hi ") == "Hello.")
        #expect(keyboardDictationInsertion(text: "Hello.", contextBefore: "") == "Hello.")
    }

    @Test func vocabularySharesMeetingTermsOnlyWhenAllowed() {
        let own: [String] = ["Senol", "Gistsmith"]
        let derived: [String] = ["Ayşe Yılmaz", "gistsmith", "Q4 roadmap"]
        #expect(keyboardVocabulary(own: own, meetingDerived: derived, meetingNotesEnabled: false, limit: 100) == ["Senol", "Gistsmith"])
        #expect(keyboardVocabulary(own: own, meetingDerived: derived, meetingNotesEnabled: true, limit: 100) == ["Senol", "Gistsmith", "Ayşe Yılmaz", "Q4 roadmap"])
        #expect(keyboardVocabulary(own: own, meetingDerived: derived, meetingNotesEnabled: true, limit: 3).count == 3)
        #expect(keyboardVocabularyWords(terms: ["Ayşe Yılmaz", "Q4 roadmap", "Ayşe"]) == ["Ayşe", "Yılmaz", "Q4", "roadmap"])
    }

    @Test func meetingTextFormatsTasksAsBullets() {
        let meeting: KeyboardMeetingItem = KeyboardMeetingItem(
            id: "20261109-100000", title: "Weekly", date: now, summary: " Shipped the keyboard. ", actionItems: ["Ship 0.2.3", "Write notes"], myTasks: []
        )
        #expect(keyboardMeetingText(meeting: meeting, part: .summary) == "Shipped the keyboard.")
        #expect(keyboardMeetingText(meeting: meeting, part: .actionItems) == "• Ship 0.2.3\n• Write notes")
        #expect(keyboardMeetingText(meeting: meeting, part: .myTasks) == nil)
    }

    @Test func bridgeRoundTripsFilesInAContainer() throws {
        let container: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let bridge: KeyboardBridge = try KeyboardBridge(containerURL: container)
        #expect(try bridge.read(KeyboardReport.self, file: .report) == nil)
        try bridge.write(KeyboardReport(lastSeenAt: now, hasFullAccess: true), file: .report)
        #expect(try bridge.read(KeyboardReport.self, file: .report) == KeyboardReport(lastSeenAt: now, hasFullAccess: true))
        try bridge.remove(file: .report)
        #expect(try bridge.read(KeyboardReport.self, file: .report) == nil)
        #expect(throws: KeyboardBridgeError.containerUnavailable(group: keyboardAppGroupIdentifier)) {
            try KeyboardBridge(containerURL: nil)
        }
    }
}
