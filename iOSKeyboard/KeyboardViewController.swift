import KeyboardCore
import os
import SwiftUI
import UIKit

/// Yalnız hata türü ve dosya adı yazılır; yazılan ya da söylenen metin hiçbir zaman loglanmaz.
private let keyboardLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "Keyboard")

/// Klavyenin kendi kabındaki ayarlar (Tam Erişim gerekmez): öğrenilen kelimeler, son emojiler, seçili dil.
private enum KeyboardLocalKey {
    static let learnedWords: String = "keyboard.learnedWords"
    static let recentEmoji: String = "keyboard.recentEmoji"
    static let languageIndex: String = "keyboard.languageIndex"
    static let skinTone: String = "keyboard.skinTone"
}

private let learnedWordLimit: Int = 500
private let recentEmojiLimit: Int = 32

/// Giriş tıklaması sesi için (`playInputClick`; yalnız Tam Erişim'le duyulur, kullanıcının Klavye Tıklamaları ayarına
/// uyar).
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool {
        true
    }
}

/// Gistsmith Klavye: Latin alfabeli diller için tam yazma klavyesi (Tam Erişim olmadan da çalışır), öneriler ve
/// kendiliğinden düzeltme, emoji; Tam Erişim'le sesle yazma (Gistsmith uygulaması dinler, bkz.
/// `KeyboardDictationCommand`) ve toplantı notlarından ekleme. Ağ kodu yoktur; yazılanlar hiçbir yere gönderilmez.
final class KeyboardViewController: UIInputViewController, KeyboardGridDelegate {
    let model: KeyboardModel = KeyboardModel()
    private let grid: KeyboardGridView = KeyboardGridView()
    private var topBar: UIHostingController<KeyboardTopBar>?
    private var panelHost: UIHostingController<KeyboardPanelView>?
    private var heightConstraint: NSLayoutConstraint?
    private var bridge: KeyboardBridge?
    private var statusObserver: KeyboardSignalObserver?
    private var ticker: Timer?
    private var config: KeyboardSharedConfig?
    private var languages: [KeyboardLanguage] = [.english]
    private var languageIndex: Int = 0
    private var page: KeyboardPage = .letters
    private var shift: KeyboardShiftState = .off
    private var lastShiftTap: Date = .distantPast
    private var lastSpaceTap: Date = .distantPast
    /// Son kendiliğinden düzeltme: hemen ardından silme düzeltmeyi geri alır.
    private var lastCorrection: (original: String, corrected: String, separator: String)?
    /// Bu alanda geri alınan düzeltmeler.
    private var rejectedWords: Set<String> = []
    private var learnedWords: [String] = []
    private var personalWords: [String] = []
    private var shortcuts: [String: String] = [:]
    private var contactNames: [String] = []
    private let checker: UITextChecker = UITextChecker()
    /// Son kaydırmayla yazılan kelime: hemen ardından silme onu bütün siler; başka bir düzenleme unutturur.
    var lastSwipedWord: String?
    /// Kaydırmanın seçenekleri: öneri çubuğunda kalır, birine dokununca kelime onunla değişir.
    var swipeAlternatives: KeyboardSuggestions?
    /// Gistsmith'e son soru ve cevabı (`ask.json`, `ask-answer.json`).
    var askCommand: KeyboardAskCommand?
    var askAnswer: KeyboardAskAnswer?
    var askObserver: KeyboardSignalObserver?
    /// Klavyenin son komutu (`command.json`): klavye yeniden açılınca da okunur.
    private var lastCommand: KeyboardDictationCommand?
    var status: KeyboardDictationStatus?
    /// Eklenen son dikte: aynı metin ikinci kez eklenmez.
    private var insertedRequestID: UUID?
    private var haptics: UIImpactFeedbackGenerator?
    /// Mekanik klavye sesleri (yalnız mod açıkken yüklenir).
    private lazy var mechanicalSounds: KeyboardSoundPack = KeyboardSoundPack(bundle: Bundle(for: KeyboardViewController.self))
    private let defaults: UserDefaults = .standard

    private var language: KeyboardLanguage {
        languages[min(languageIndex, languages.count - 1)]
    }

    /// Cihaz içi dikte (`DictationTranscriber`) iOS 26 ister.
    private var isVoiceSupportedBySystem: Bool {
        if #available(iOS 26, *) {
            true
        } else {
            false
        }
    }

    // MARK: Yaşam döngüsü

    override func loadView() {
        let input: KeyboardInputView = KeyboardInputView(frame: CGRect(x: 0, y: 0, width: 320, height: 260), inputViewStyle: .keyboard)
        input.allowsSelfSizing = true
        inputView = input
        view = input
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Açık/koyu tema klavye göründükten sonra da gelebilir (ilk yerleşimde ya da sistem teması değişince).
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            controller.refreshForField()
        }
        learnedWords = defaults.stringArray(forKey: KeyboardLocalKey.learnedWords) ?? []
        model.recentEmoji = defaults.stringArray(forKey: KeyboardLocalKey.recentEmoji) ?? []
        model.skinTone = KeyboardSkinTone(rawValue: defaults.string(forKey: KeyboardLocalKey.skinTone) ?? "") ?? .none
        let actions: KeyboardActions = makeActions()
        let top: UIHostingController<KeyboardTopBar> = UIHostingController(rootView: KeyboardTopBar(model: model, actions: actions))
        let panel: UIHostingController<KeyboardPanelView> = UIHostingController(rootView: KeyboardPanelView(model: model, actions: actions))
        for host in [top.view, panel.view] {
            host?.backgroundColor = .clear
            host?.translatesAutoresizingMaskIntoConstraints = false
        }
        top.sizingOptions = []
        panel.sizingOptions = []
        addChild(top)
        addChild(panel)
        view.addSubview(top.view)
        view.addSubview(panel.view)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.delegate = self
        view.addSubview(grid)
        top.didMove(toParent: self)
        panel.didMove(toParent: self)
        topBar = top
        panelHost = panel
        let height: NSLayoutConstraint = view.heightAnchor.constraint(equalToConstant: keyboardHeight())
        height.priority = .required - 1
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            top.view.topAnchor.constraint(equalTo: view.topAnchor),
            top.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.view.heightAnchor.constraint(equalToConstant: 44),
            grid.topAnchor.constraint(equalTo: top.view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panel.view.topAnchor.constraint(equalTo: top.view.bottomAnchor),
            panel.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panel.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panel.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Sözlüğün tamamlanışı ana iş parçacığında gelmez: ana kuyruğa geçilir.
        requestSupplementaryLexicon(completion: Self.lexiconHandler { [weak self] (lexicon: UILexicon) in
            self?.apply(lexicon: lexicon)
        })
    }

    /// `requestSupplementaryLexicon` tamamlanışı arka kuyrukta çağırır; sözlük ana kuyrukta işlenir.
    nonisolated private static func lexiconHandler(deliver: @escaping @Sendable @MainActor (UILexicon) -> Void) -> (UILexicon) -> Void {
        { (lexicon: UILexicon) -> Void in
            // UILexicon değişmez bir değer kabıdır; yalnız ana kuyrukta okunur.
            nonisolated(unsafe) let delivered: UILexicon = lexicon
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    deliver(delivered)
                }
            }
        }
    }

    private func apply(lexicon: UILexicon) {
        var shortcuts: [String: String] = [:]
        var names: [String] = []
        for entry in lexicon.entries {
            if entry.userInput == entry.documentText {
                names.append(entry.documentText)
            } else {
                shortcuts[entry.userInput] = entry.documentText
            }
        }
        self.shortcuts = shortcuts
        contactNames = names
        rebuildPersonalWords()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        connectBridge()
        rejectedWords = []
        lastCorrection = nil
        refreshAll()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        statusObserver?.cancel()
        statusObserver = nil
        askObserver?.cancel()
        askObserver = nil
        model.isAsking = false
        ticker?.invalidate()
        ticker = nil
        model.panel = .none
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] (_: any UIViewControllerTransitionCoordinatorContext) in
            self?.refreshLayout(size: size)
        })
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        // Alan değişti ya da metin dışarıdan değişti: yalnız alana bağlı durum yenilenir (sözlük ve ayarlar açılışta).
        refreshForField()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        lastCorrection = nil
        refreshSuggestions()
    }

    // MARK: Paylaşılan durum

    /// Tam Erişim varsa App Group'a bağlanır: ayarlar, sözlük, toplantılar ve sesle yazma durumu okunur, son görülme
    /// yazılır. Tam Erişim yoksa klavye yalnız kendi kabıyla çalışır.
    private func connectBridge() {
        model.hasFullAccess = hasFullAccess
        guard hasFullAccess else {
            bridge = nil
            config = nil
            model.meetings = nil
            languages = defaultKeyboardLanguages(preferredLanguages: Locale.preferredLanguages)
            return
        }
        if bridge == nil {
            do {
                bridge = try KeyboardBridge(containerURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: keyboardAppGroupIdentifier))
            } catch {
                keyboardLogger.error("Keyboard App Group unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        guard let bridge else {
            languages = defaultKeyboardLanguages(preferredLanguages: Locale.preferredLanguages)
            return
        }
        // Okunamayan dosya (cihaz kilitli, ilk kurulum, eski biçim) loglanır; klavye yazmayı sürdürür, o dosyanın
        // özelliği (ayarlar, toplantılar, sesle yazma durumu) bir sonraki açılışta yeniden okunur.
        config = readShared(KeyboardSharedConfig.self, file: .config, bridge: bridge)
        model.meetings = config?.meetingNotesEnabled == true ? (readShared(KeyboardMeetingSnapshot.self, file: .meetings, bridge: bridge)?.meetings ?? []) : nil
        status = readShared(KeyboardDictationStatus.self, file: .status, bridge: bridge)
        lastCommand = readShared(KeyboardDictationCommand.self, file: .command, bridge: bridge)
        askCommand = readShared(KeyboardAskCommand.self, file: .askCommand, bridge: bridge)
        askAnswer = readShared(KeyboardAskAnswer.self, file: .askAnswer, bridge: bridge)
        if askObserver == nil {
            askObserver = KeyboardSignalObserver(signal: .askAnswer) { [weak self] in
                self?.askAnswerChanged()
            }
        }
        languages = config.map { $0.languages.isEmpty ? [.english] : $0.languages } ?? defaultKeyboardLanguages(preferredLanguages: Locale.preferredLanguages)
        do {
            try bridge.write(KeyboardReport(lastSeenAt: Date()), file: .report)
        } catch {
            keyboardLogger.error("Keyboard report write failed: \(String(describing: error), privacy: .public)")
        }
        if statusObserver == nil {
            statusObserver = KeyboardSignalObserver(signal: .status) { [weak self] in
                self?.statusChanged()
            }
        }
        if haptics == nil {
            haptics = UIImpactFeedbackGenerator(style: .rigid)
        }
    }

    private func statusChanged() {
        guard let bridge else {
            return
        }
        status = readShared(KeyboardDictationStatus.self, file: .status, bridge: bridge)
        refreshMicState()
    }

    func readShared<Value: Decodable>(_ type: Value.Type, file: KeyboardSharedFile, bridge: KeyboardBridge) -> Value? {
        do {
            return try bridge.read(type, file: file)
        } catch {
            keyboardLogger.error("Keyboard shared file read failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func rebuildPersonalWords() {
        personalWords = keyboardVocabularyWords(terms: (config?.vocabulary ?? []) + learnedWords + contactNames)
    }

    // MARK: Yenileme

    private func refreshAll() {
        languageIndex = min(defaults.integer(forKey: KeyboardLocalKey.languageIndex), max(0, languages.count - 1))
        model.showsMicrophone = isVoiceSupportedBySystem
        // Sistemin dikte tuşu yalnız kendi sesle yazmamız kullanılabilirken kapatılır. Değer yalnız değişince yazılır:
        // her atama sistemin girişi yeniden eşlemesine ve yeni bir `textDidChange`'e yol açar.
        let wantsOwnDictation: Bool = isVoiceSupportedBySystem && hasFullAccess
        if hasDictationKey != wantsOwnDictation {
            hasDictationKey = wantsOwnDictation
        }
        rebuildPersonalWords()
        refreshAskState()
        refreshMicState()
        refreshForField()
    }

    private func refreshForField() {
        let isDark: Bool = textDocumentProxy.keyboardAppearance == .dark || view.traitCollection.userInterfaceStyle == .dark
        if model.isDark != isDark {
            model.isDark = isDark
        }
        refreshShift()
        refreshSuggestions()
        refreshLayout(size: view.bounds.size)
    }

    func refreshLayout(size: CGSize) {
        heightConstraint?.constant = keyboardHeight()
        let isLandscape: Bool = size.width > size.height && size.width > 500 && traitCollection.verticalSizeClass == .compact
        let showsGlobe: Bool = needsInputModeSwitchKey
        let options: KeyboardLayoutOptions = KeyboardLayoutOptions(
            showsGlobe: showsGlobe, showsMicrophone: model.showsMicrophone, showsLanguage: languages.count > 1, field: fieldKind()
        )
        let rows: [[KeyboardKey]] = keyboardRows(language: language, page: page, options: options)
        let isListening: Bool
        switch model.micState {
        case .listening, .finishing, .starting:
            isListening = true
        default:
            isListening = false
        }
        grid.update(model: KeyboardGridModel(
            rows: rows, language: language, page: page, shift: shift, returnTitle: returnTitle(), returnIsProminent: returnTitle() != nil,
            isDark: model.isDark, isLandscape: isLandscape, isMicrophoneActive: isListening,
            allowsSwipe: page == .letters && !model.isAsking && (config?.swipeTyping ?? true) && textCheckerLanguage(for: language) != nil
        ))
        grid.isHidden = model.panel != .none
        panelHost?.view.isHidden = model.panel == .none
    }

    private func keyboardHeight() -> CGFloat {
        traitCollection.verticalSizeClass == .compact ? 44 + 162 : 44 + 216
    }

    private func fieldKind() -> KeyboardFieldKind {
        switch textDocumentProxy.keyboardType {
        case .emailAddress:
            .email
        case .URL, .webSearch:
            .url
        default:
            .text
        }
    }

    private func returnTitle() -> String? {
        switch textDocumentProxy.returnKeyType {
        case .go: String(localized: "Git")
        case .search, .google, .yahoo: String(localized: "Ara")
        case .send: String(localized: "Gönder")
        case .done: String(localized: "Bitti")
        case .next: String(localized: "Sonraki")
        case .continue: String(localized: "Devam")
        case .join: String(localized: "Katıl")
        default: nil
        }
    }

    private func autocapitalization() -> KeyboardAutocapitalization {
        // Alan türü bildirmiyorsa cümle başı (sistem klavyesinin varsayılanı).
        switch textDocumentProxy.autocapitalizationType ?? .sentences {
        case UITextAutocapitalizationType.none: .none
        case .words: .words
        case .allCharacters: .allCharacters
        default: .sentences
        }
    }

    private func fieldTraits() -> KeyboardFieldTraits {
        let numericTypes: [UIKeyboardType] = [.numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad, .namePhonePad, .numbersAndPunctuation]
        return KeyboardFieldTraits(
            autocorrectionDisabled: textDocumentProxy.autocorrectionType == .no,
            contentType: textDocumentProxy.textContentType?.rawValue,
            isNumeric: numericTypes.contains(textDocumentProxy.keyboardType ?? .default)
        )
    }

    private func refreshShift() {
        guard shift != .locked else {
            return
        }
        let wanted: Bool = page == .letters && keyboardShouldCapitalize(contextBefore: textDocumentProxy.documentContextBeforeInput ?? "", rule: autocapitalization())
        shift = wanted ? .once : .off
    }

    private func refreshMicState() {
        let state: KeyboardMicState = keyboardMicState(
            hasFullAccess: hasFullAccess, status: status, lastCommand: lastCommand, documentID: textDocumentProxy.documentIdentifier, now: Date()
        )
        if model.micState != state {
            model.micState = state
        }
        // Uygulama kapandı ya da oturum bitti ama metin dosyada kaldı: klavye onu siler. Uygulamanın nabzı bir an
        // gecikirse (4 sn) yaşayan bir dikte de silinebilir; uygulamanın sonraki nabzı onu geri yazar.
        if keyboardStatusHasOrphanedText(status: status, now: Date()), let requestID = status?.dictation?.requestID {
            clearResult(requestID: requestID)
        }
        switch state {
        case .finished(let text, true):
            if let requestID = status?.dictation?.requestID, insertedRequestID != requestID {
                insertDictation(text: text, requestID: requestID)
            }
        case .needsFullAccess, .idle, .starting, .listening, .finishing, .finished, .failed:
            break
        }
        // Oturum ya da bekleyen istek varken saniyede bir yeniden hesaplanır (kalan süre, nabız).
        let needsTicker: Bool = state == .starting || model.askState == .answering || keyboardSessionIsLive(session: status?.session, now: Date())
        if needsTicker, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] (_: Timer) in
                MainActor.assumeIsolated {
                    self?.refreshAskState()
                    self?.refreshMicState()
                }
            }
        } else if !needsTicker {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func refreshSuggestions() {
        // Kaydırmanın seçenekleri bir sonraki düzenlemeye dek kalır.
        if let swipeAlternatives {
            if model.suggestions != swipeAlternatives {
                model.suggestions = swipeAlternatives
            }
            return
        }
        guard page == .letters || page == .numbers else {
            if model.suggestions != .empty {
                model.suggestions = .empty
            }
            return
        }
        let word: String = keyboardCurrentWord(contextBefore: textDocumentProxy.documentContextBeforeInput ?? "")
        let updated: KeyboardSuggestions = suggestions(for: word)
        // Gözlenen değer yalnız değişince yazılır (her atama SwiftUI'yi yeniden çizer).
        if model.suggestions != updated {
            model.suggestions = updated
        }
    }

    private func suggestions(for word: String) -> KeyboardSuggestions {
        guard !word.isEmpty else {
            return .empty
        }
        let checkerLanguage: String? = textCheckerLanguage(for: language)
        let range: NSRange = NSRange(location: 0, length: (word as NSString).length)
        let guesses: [String] = checkerLanguage.flatMap { checker.guesses(forWordRange: range, in: word, language: $0) } ?? []
        let completions: [String] = checkerLanguage.flatMap { checker.completions(forPartialWordRange: range, in: word, language: $0) } ?? []
        // Seçili dillerden birinde doğru yazılmış kelime düzeltilmez; dilin sözlüğü yoksa hiç düzeltme yapılmaz.
        let isKnown: Bool =
            checkerLanguage == nil
            || languages.contains { (other: KeyboardLanguage) -> Bool in
                guard let code = textCheckerLanguage(for: other) else {
                    return false
                }
                return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: code).location == NSNotFound
            }
        let allowed: Bool = (config?.autocorrect ?? true) && keyboardAllowsLearning(traits: fieldTraits())
        return keyboardSuggestions(input: KeyboardSuggestionInput(
            typed: word, language: language, isKnownWord: isKnown, guesses: guesses, completions: Array(completions.prefix(6)),
            personalWords: personalWords, shortcuts: shortcuts, rejected: rejectedWords, autocorrectAllowed: allowed
        ))
    }

    /// `UITextChecker`'ın bu dil için sözlüğü (ör. "tr_TR"); yoksa nil.
    private func textCheckerLanguage(for language: KeyboardLanguage) -> String? {
        let available: [String] = UITextChecker.availableLanguages
        let codes: [String] = language == .norwegian ? ["nb", "no"] : [language.rawValue]
        return available.first { (identifier: String) -> Bool in
            codes.contains(String(identifier.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? ""))
        }
    }

    // MARK: Yazma

    func insert(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    /// Kelimeyi ayraçla bitirir: kendiliğinden düzeltme varsa önce uygulanır.
    private func commitWord(separator: String) {
        let word: String = keyboardCurrentWord(contextBefore: textDocumentProxy.documentContextBeforeInput ?? "")
        let result: KeyboardSuggestions = suggestions(for: word)
        if let corrected = result.autocorrection, corrected != word {
            for _ in 0 ..< word.count {
                textDocumentProxy.deleteBackward()
            }
            insert(corrected + separator)
            lastCorrection = (word, corrected, separator)
        } else {
            insert(separator)
            lastCorrection = nil
        }
    }

    func gridInsert(character: String) {
        let output: String = page == .letters && shift != .off ? keyboardUppercased(character, language: language) : character
        if model.isAsking {
            askType(output)
            if shift == .once {
                shift = .off
            }
            refreshLayout(size: view.bounds.size)
            return
        }
        if ".,!?;:".contains(output), output.count == 1 {
            commitWord(separator: output)
        } else {
            lastCorrection = nil
            insert(output)
        }
        if shift == .once {
            shift = .off
        }
        // Rakam sayfasında kesme işareti ya da boşluk sonrası harflere dönülür (sistem klavyesindeki gibi).
        if page != .letters, output == "'" {
            page = .letters
        }
        lastSpaceTap = .distantPast
        afterEdit()
    }

    func gridDeleteBackward(wholeWord: Bool) {
        if model.isAsking {
            askDeleteBackward()
            return
        }
        // Kaydırmayla yazılan kelimenin hemen ardından silme bütün kelimeyi siler (sistem klavyesindeki gibi).
        if let swiped = lastSwipedWord, (textDocumentProxy.documentContextBeforeInput ?? "").hasSuffix(swiped) {
            for _ in 0 ..< swiped.count {
                textDocumentProxy.deleteBackward()
            }
            lastSwipedWord = nil
            afterEdit()
            return
        }
        let before: String = textDocumentProxy.documentContextBeforeInput ?? ""
        if let correction = lastCorrection, before.hasSuffix(correction.corrected + correction.separator) {
            // Düzeltmenin hemen ardından silme: yazılan kelime geri gelir, bu alanda yeniden düzeltilmez ve öğrenilir.
            for _ in 0 ..< (correction.corrected + correction.separator).count {
                textDocumentProxy.deleteBackward()
            }
            insert(correction.original)
            rejectedWords.insert(correction.original)
            learn(word: correction.original)
            lastCorrection = nil
        } else if wholeWord {
            let trailingSpaces: Int = before.reversed().prefix { $0 == " " }.count
            let word: Int = keyboardCurrentWord(contextBefore: String(before.dropLast(trailingSpaces))).count
            for _ in 0 ..< max(1, trailingSpaces + word) {
                textDocumentProxy.deleteBackward()
            }
        } else {
            textDocumentProxy.deleteBackward()
        }
        afterEdit()
    }

    func gridShift() {
        let now: Date = Date()
        switch shift {
        case .locked:
            shift = .off
        case .once where now.timeIntervalSince(lastShiftTap) < 0.35:
            shift = .locked
        case .once:
            shift = .off
        case .off:
            shift = .once
        }
        lastShiftTap = now
        refreshLayout(size: view.bounds.size)
    }

    func gridSpace() {
        if model.isAsking {
            askType(" ")
            return
        }
        let now: Date = Date()
        let before: String = textDocumentProxy.documentContextBeforeInput ?? ""
        if now.timeIntervalSince(lastSpaceTap) < 0.8, keyboardDoubleSpacePeriod(contextBefore: before) != nil {
            textDocumentProxy.deleteBackward()
            insert(". ")
            lastSpaceTap = .distantPast
            lastCorrection = nil
        } else {
            commitWord(separator: " ")
            lastSpaceTap = now
        }
        if page != .letters {
            page = .letters
        }
        afterEdit()
    }

    func gridReturn() {
        if model.isAsking {
            sendQuestion()
            return
        }
        lastCorrection = nil
        insert("\n")
        afterEdit()
    }

    func gridPage(_ page: KeyboardPage) {
        self.page = page
        refreshShift()
        refreshLayout(size: view.bounds.size)
    }

    func gridEmoji() {
        model.panel = .emoji
        refreshLayout(size: view.bounds.size)
    }

    func gridLanguage() {
        languageIndex = (languageIndex + 1) % max(1, languages.count)
        defaults.set(languageIndex, forKey: KeyboardLocalKey.languageIndex)
        refreshSuggestions()
        refreshLayout(size: view.bounds.size)
    }

    func gridMoveCursor(offset: Int) {
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
    }

    /// Tuş sesi: Tam Erişim'le sistemin giriş tıklaması (kullanıcının Klavye Tıklamaları ayarına uyar); mekanik klavye
    /// modu açıksa onun yerine pakete gömülü mekanik ses ve hafif, sert bir titreşim. Tam Erişim olmadan ses ve titreşim
    /// yok (iOS kuralı).
    func gridKeyDown(kind: KeyboardKeyKind) {
        guard hasFullAccess else {
            return
        }
        if config?.mechanicalSounds == true {
            mechanicalSounds.play(kind: kind)
            haptics?.impactOccurred(intensity: 0.55)
        } else {
            UIDevice.current.playInputClick()
        }
    }

    func gridAttachGlobe(button: UIButton) {
        button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
    }

    /// Kaydırma bitti: aday kelimeler cihazın sözlüğünden (`UITextChecker` tamamlamaları, sıklık sırasıyla) ve kişisel
    /// sözlükten gelir, iz bunlarla eşleştirilir (`swipeDecode`). En iyi kelime yazılır (gerekirse önüne boşluk), öbür
    /// ikisi öneri çubuğunda kalır.
    func gridSwipe(points: [CGPoint], frames: [KeyboardKeyFrame]) {
        guard let checkerLanguage = textCheckerLanguage(for: language) else {
            return
        }
        let keyboard: SwipeKeyboard = swipeKeyboard(frames: frames)
        let prefixes: [String] = swipeCandidatePrefixes(points: points, keyboard: keyboard, limit: 48)
        let lists: [(prefix: String, words: [String])] = prefixes.map { (prefix: String) -> (prefix: String, words: [String]) in
            let range: NSRange = NSRange(location: 0, length: (prefix as NSString).length)
            return (prefix, checker.completions(forPartialWordRange: range, in: prefix, language: checkerLanguage) ?? [])
        }
        let matches: [SwipeMatch] = swipeDecode(
            points: points, keyboard: keyboard, candidates: swipeCandidates(prefixLists: lists, personalWords: personalWords), language: language, limit: 3
        )
        guard let best = matches.first else {
            return
        }
        let before: String = textDocumentProxy.documentContextBeforeInput ?? ""
        let casing: (String) -> String = { [shift, language] (word: String) -> String in
            switch shift {
            case .locked: keyboardUppercased(word, language: language)
            case .once: keyboardCapitalizedFirst(word, language: language)
            case .off: word
            }
        }
        let word: String = casing(best.word)
        if let last = before.last, !last.isWhitespace, !"([{\"'“‘".contains(last) {
            insert(" ")
        }
        insert(word)
        if shift == .once {
            shift = .off
        }
        lastCorrection = nil
        afterEdit()
        lastSwipedWord = word
        let alternatives: [KeyboardSuggestion] = matches.dropFirst().map { KeyboardSuggestion(text: casing($0.word), kind: .completion) }
        let shown: KeyboardSuggestions = KeyboardSuggestions(items: alternatives + [KeyboardSuggestion(text: word, kind: .typed)], autocorrection: nil)
        swipeAlternatives = shown
        model.suggestions = shown
    }

    func afterEdit() {
        lastSwipedWord = nil
        swipeAlternatives = nil
        refreshShift()
        refreshSuggestions()
        refreshLayout(size: view.bounds.size)
    }

    private func learn(word: String) {
        guard keyboardAllowsLearning(traits: fieldTraits()) else {
            return
        }
        learnedWords = keyboardLearnedWordsAdding(word: word, to: learnedWords, limit: learnedWordLimit)
        defaults.set(learnedWords, forKey: KeyboardLocalKey.learnedWords)
        rebuildPersonalWords()
    }

    // MARK: Öneriler ve paneller

    private func makeActions() -> KeyboardActions {
        KeyboardActions(
            pickSuggestion: { [weak self] (suggestion: KeyboardSuggestion) in self?.pick(suggestion: suggestion) },
            openGistsmithPanel: { [weak self] in
                self?.model.panel = .gistsmith
                self?.refreshLayout(size: self?.view.bounds.size ?? .zero)
            },
            closePanel: { [weak self] in self?.closePanel() },
            insertEmoji: { [weak self] (emoji: String) in self?.insertEmoji(emoji) },
            deleteBackward: { [weak self] in self?.gridDeleteBackward(wholeWord: false) },
            insertMeetingText: { [weak self] (text: String) in
                guard let self else {
                    return
                }
                self.insert(keyboardDictationInsertion(text: text, contextBefore: self.textDocumentProxy.documentContextBeforeInput ?? ""))
                self.closePanel()
            },
            finishDictation: { [weak self] in self?.send(action: .stop) },
            cancelDictation: { [weak self] in self?.cancelDictation() },
            insertFinishedDictation: { [weak self] in
                guard let self, case .finished(let text, _) = self.model.micState, let requestID = self.status?.dictation?.requestID else {
                    return
                }
                self.insertDictation(text: text, requestID: requestID)
            },
            endSession: { [weak self] in self?.send(action: .endSession) },
            openSettings: { [weak self] in
                guard let url = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                _ = self?.openURL(url)
            },
            openGistsmithSetup: { [weak self] in _ = self?.openURL(keyboardSetupURL) },
            cycleSkinTone: { [weak self] in
                guard let self else {
                    return
                }
                let all: [KeyboardSkinTone] = KeyboardSkinTone.allCases
                let next: KeyboardSkinTone = all[((all.firstIndex(of: self.model.skinTone) ?? 0) + 1) % all.count]
                self.model.skinTone = next
                self.defaults.set(next.rawValue, forKey: KeyboardLocalKey.skinTone)
            },
            startAsking: { [weak self] in self?.startAsking() },
            sendQuestion: { [weak self] in self?.sendQuestion() },
            cancelAsking: { [weak self] in self?.cancelAsking() },
            insertAnswer: { [weak self] in self?.insertAnswer() },
            dismissAnswer: { [weak self] in self?.releaseAnswer() }
        )
    }

    private func pick(suggestion: KeyboardSuggestion) {
        let word: String = keyboardCurrentWord(contextBefore: textDocumentProxy.documentContextBeforeInput ?? "")
        for _ in 0 ..< word.count {
            textDocumentProxy.deleteBackward()
        }
        insert(suggestion.text + " ")
        if suggestion.kind == .typed {
            rejectedWords.insert(suggestion.text)
            learn(word: suggestion.text)
        }
        lastCorrection = nil
        afterEdit()
    }

    private func closePanel() {
        model.panel = .none
        refreshLayout(size: view.bounds.size)
    }

    private func insertEmoji(_ emoji: String) {
        insert(emoji)
        model.recentEmoji = keyboardRecentEmojiAdding(emoji: emoji, to: model.recentEmoji, limit: recentEmojiLimit)
        defaults.set(model.recentEmoji, forKey: KeyboardLocalKey.recentEmoji)
        lastCorrection = nil
    }

    // MARK: Sesle yazma

    func gridMicrophone() {
        switch model.micState {
        case .needsFullAccess:
            showPanel(.voiceInfo(.needsFullAccess))
        case .listening:
            send(action: .stop)
        case .finishing, .starting:
            break
        case .finished(let text, _):
            if let requestID = status?.dictation?.requestID {
                insertDictation(text: text, requestID: requestID)
            }
        case .idle(let remaining):
            startDictation(sessionIsLive: remaining != nil)
        case .failed:
            startDictation(sessionIsLive: keyboardSessionIsLive(session: status?.session, now: Date()))
        }
    }

    func showPanel(_ panel: KeyboardPanel) {
        model.panel = panel
        refreshLayout(size: view.bounds.size)
    }

    /// Dikteyi başlatır: oturum açıksa yalnız komut gider; değilse Gistsmith açılır, mikrofonu o başlatır.
    private func startDictation(sessionIsLive: Bool) {
        let requestID: UUID = UUID()
        let start: KeyboardDictationCommand = KeyboardDictationCommand(
            requestID: requestID, action: .start, documentID: textDocumentProxy.documentIdentifier, languageCode: voiceLanguageCode(), issuedAt: Date()
        )
        if !sessionIsLive {
            #if KEYBOARD_OPENS_APP
            guard write(command: start) else {
                showPanel(.voiceInfo(.needsFullAccess))
                return
            }
            if !openURL(keyboardDictateURL(requestID: requestID)) {
                send(action: .cancel)
                showPanel(.voiceInfo(.openGistsmithManually))
            }
            #else
            showPanel(.voiceInfo(.openGistsmithManually))
            #endif
        } else if !write(command: start) {
            showPanel(.voiceInfo(.needsFullAccess))
            return
        }
        refreshMicState()
    }

    private func voiceLanguageCode() -> String {
        config?.voiceLanguageCode ?? (language == .norwegian ? "nb" : language.rawValue)
    }

    private func cancelDictation() {
        switch model.micState {
        case .finished, .failed:
            send(action: .acknowledge)
            if let requestID = status?.dictation?.requestID {
                clearResult(requestID: requestID)
            }
        default:
            send(action: .cancel)
        }
        refreshMicState()
    }

    /// Sonucu paylaşılan klasörden kendisi siler: uygulama askıya alınmış ya da kapanmış olsa da metin diskte kalmaz.
    private func clearResult(requestID: UUID) {
        guard let bridge, let cleared = keyboardStatusClearingDictation(status: status, requestID: requestID) else {
            return
        }
        do {
            try bridge.write(cleared, file: .status)
            status = cleared
        } catch {
            keyboardLogger.error("Keyboard status clear failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func send(action: KeyboardDictationCommand.Action) {
        let requestID: UUID = lastCommand?.requestID ?? status?.dictation?.requestID ?? UUID()
        _ = write(command: KeyboardDictationCommand(
            requestID: requestID, action: action, documentID: textDocumentProxy.documentIdentifier, languageCode: voiceLanguageCode(), issuedAt: Date()
        ))
    }

    private func write(command: KeyboardDictationCommand) -> Bool {
        guard let bridge else {
            return false
        }
        do {
            try bridge.write(command, file: .command)
        } catch {
            keyboardLogger.error("Keyboard command write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        lastCommand = command
        bridge.post(.command)
        return true
    }

    private func insertDictation(text: String, requestID: UUID) {
        insertedRequestID = requestID
        insert(keyboardDictationInsertion(text: text, contextBefore: textDocumentProxy.documentContextBeforeInput ?? ""))
        // Uygulamaya bildirilir ve sonuç paylaşılan klasörden hemen silinir: metin diskte kalmaz.
        _ = write(command: KeyboardDictationCommand(
            requestID: requestID, action: .acknowledge, documentID: textDocumentProxy.documentIdentifier, languageCode: voiceLanguageCode(), issuedAt: Date()
        ))
        clearResult(requestID: requestID)
        lastCorrection = nil
        afterEdit()
    }

    /// Kapsayan uygulamayı (Gistsmith) ya da Ayarlar'ı açar. Klavye uzantısı `UIApplication.shared`'e erişemez; yanıt
    /// zincirindeki uygulama nesnesine ulaşılır (bkz. spec, "Risks"). Bulunamazsa false.
    func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
