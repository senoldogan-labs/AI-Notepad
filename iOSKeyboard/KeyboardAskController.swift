import KeyboardCore
import os
import UIKit

/// Yalnız hata türü ve dosya adı yazılır; soru ve cevap hiçbir zaman loglanmaz.
private let askLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "KeyboardAsk")

/// Klavyeden Gistsmith'e soru. Tuşlar soru alanına yazar (belgeye değil). "Sor" picks a route (`keyboardAskRoute`):
/// with Gistsmith's microphone session live the question goes to the app through the App Group without opening it;
/// otherwise, with Full Access, the keyboard's own token (`KeyboardAskToken`, never the account's session) and notes to
/// answer from, the keyboard asks the server directly (`keyboardAskSend`); otherwise Gistsmith opens and answers. The
/// answer is inserted ("Ekle") or copied ("Kopyala").
extension KeyboardViewController {
    /// Seçili metin varsa soru alanına önceden konur.
    func startAsking() {
        // Bir soru cevaplanırken ikincisi sorulmaz (Sor tek soruyu cevaplar). A question still waiting for Gistsmith,
        // or one that never reached it, is replaced by the new one.
        guard !model.askState.locksAsking else {
            return
        }
        // Ask calls Gistsmith's server, so it needs an account (typing and voice typing do not): nothing is asked or sent
        // without one, the panel says so and opens the sign-in.
        switch keyboardAskGate(hasFullAccess: hasFullAccess, accountSignedIn: model.accountSignedIn) {
        case .needsFullAccess:
            showAskPanel(info: .needsFullAccess)
            return
        case .needsAccount:
            showAskPanel(info: .needsAccount)
            return
        case .available:
            break
        }
        let selected: String = (textDocumentProxy.selectedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        model.askQuestion = keyboardAskQuestionAppending(question: "", text: selected)
        model.isAsking = true
        model.panel = .none
        refreshLayout(size: view.bounds.size)
    }

    func cancelAsking() {
        model.isAsking = false
        model.askQuestion = ""
        refreshLayout(size: view.bounds.size)
    }

    func askType(_ text: String) {
        model.askQuestion = keyboardAskQuestionAppending(question: model.askQuestion, text: text)
    }

    func askDeleteBackward() {
        if !model.askQuestion.isEmpty {
            model.askQuestion.removeLast()
        }
    }

    func sendQuestion() {
        let question: String = model.askQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, hasFullAccess else {
            return
        }
        #if DEBUG
        if askDemoIsOn() {
            askDemo(question: question)
            return
        }
        #endif
        let token: KeyboardAskToken? = readAskToken()
        let meetings: [KeyboardMeetingItem] = model.meetings ?? []
        let route: KeyboardAskRoute = keyboardAskRoute(
            sessionIsLive: keyboardSessionIsLive(session: status?.session, now: Date()), hasFullAccess: hasFullAccess, token: token,
            hasLocalContext: !meetings.isEmpty, now: Date()
        )
        if route == .direct, let token {
            // Sent even when the server has the assistant copy: that access may have been turned off since the token.
            let context: [KeyboardAskMeeting] = keyboardAskContext(
                meetings: meetings, budgetBytes: keyboardAskContextBudgetBytes, summaryMaxChars: keyboardAskSummaryMaxChars, maxMeetings: keyboardAskMaxMeetings
            )
            model.isAsking = false
            model.askQuestion = ""
            model.askedQuestion = question
            askDirectly(question: question, token: token, meetings: context)
        } else if askThroughGistsmith(question: question) {
            // Only once the question is written: a failed write keeps it in the field.
            model.isAsking = false
            model.askQuestion = ""
            model.askedQuestion = question
            refreshLayout(size: view.bounds.size)
        }
    }

    /// The question goes to Gistsmith through the App Group: a live session answers in place, otherwise Gistsmith opens.
    /// False when it could not be written (nothing was sent).
    @discardableResult
    private func askThroughGistsmith(question: String) -> Bool {
        guard let bridge = askBridge() else {
            return false
        }
        let command: KeyboardAskCommand = KeyboardAskCommand(
            requestID: UUID(), action: .ask, question: question, documentID: currentDocumentID(), issuedAt: Date()
        )
        do {
            try bridge.write(command, file: .askCommand)
            try bridge.remove(file: .askAnswer)
        } catch {
            askLogger.error("Keyboard question write failed: \(String(describing: error), privacy: .public)")
            return false
        }
        clearDirectAsk()
        askCommand = command
        askAnswer = nil
        bridge.post(.ask)
        // Mikrofon oturumu açıksa uygulama arka planda çalışıyor: bildirim yeter. Değilse Gistsmith açılır.
        if !keyboardSessionIsLive(session: status?.session, now: Date()) {
            #if KEYBOARD_OPENS_APP
            if !openURL(keyboardAskURL(requestID: command.requestID)) {
                showPanel(.voiceInfo(.openGistsmithManually))
            }
            #else
            showPanel(.voiceInfo(.openGistsmithManually))
            #endif
        }
        refreshAskState()
        refreshLayout(size: view.bounds.size)
        return true
    }

    func askAnswerChanged() {
        guard let bridge = askBridge() else {
            return
        }
        askAnswer = readShared(KeyboardAskAnswer.self, file: .askAnswer, bridge: bridge)
        refreshAskState()
    }

    /// Şerit durumu; süresi geçmiş ya da artık son soruya ait olmayan cevap silinir (the state does not depend on
    /// which side deleted it first: an expired question shows nothing).
    func refreshAskState() {
        if let directAskState {
            show(askState: directAskState)
            return
        }
        let now: Date = Date()
        if keyboardAskAnswerIsStale(answer: askAnswer, command: askCommand, now: now), let bridge = askBridge() {
            do {
                try bridge.remove(file: .askAnswer)
                askAnswer = nil
            } catch {
                askLogger.error("Keyboard stale answer removal failed: \(String(describing: error), privacy: .public)")
            }
        }
        show(askState: keyboardAskState(command: askCommand, answer: askAnswer, now: now))
    }

    /// The card writes a new answer out from the moment it arrives. The keys come back as soon as there is no question
    /// (also when an unused answer expires).
    private func show(askState state: KeyboardAskState) {
        guard model.askState != state else {
            return
        }
        let wasIdle: Bool = model.askState == .idle
        if case .answered = state {
            model.askAnswerArrivedAt = Date()
        } else {
            model.askAnswerArrivedAt = nil
        }
        model.askState = state
        if wasIdle != (state == .idle) {
            refreshLayout(size: view.bounds.size)
        } else {
            // Waiting → answered, or a late answer after a timeout: the card starts (or finishes) writing it out.
            refreshFrameLink()
        }
    }

    /// Cevabı imlecin yerine ekler; sonra cevap dosyası silinir. "Added · Undo" stays for `keyboardAnswerUndoWindow`.
    func insertAnswer() {
        guard case .answered(let text) = model.askState else {
            return
        }
        let insertion: String = keyboardDictationInsertion(text: text, contextBefore: textDocumentProxy.documentContextBeforeInput ?? "")
        insert(insertion)
        releaseAnswer()
        afterEdit()
        model.askInsertedAnswer = insertion
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(keyboardAnswerUndoWindow))
            } catch {
                return
            }
            if self?.model.askInsertedAnswer == insertion {
                self?.model.askInsertedAnswer = nil
            }
        }
    }

    /// Takes the answer just added back out, only while the text before the cursor still ends with it.
    func undoInsertedAnswer() {
        guard let inserted = model.askInsertedAnswer else {
            return
        }
        if keyboardCanUndoInsertion(inserted: inserted, contextBefore: textDocumentProxy.documentContextBeforeInput ?? "") {
            for _ in 0..<inserted.count {
                textDocumentProxy.deleteBackward()
            }
        }
        afterEdit()
    }

    /// The question field opens again with the last question in it; nothing is sent until Ask.
    func askAgain() {
        let question: String = model.askedQuestion
        releaseAnswer()
        startAsking()
        if model.isAsking {
            model.askQuestion = question
        }
    }

    /// Cevap eklendi ya da bırakıldı: uygulamaya bildirilir ve dosya hemen silinir (uygulama askıda olsa da).
    func releaseAnswer() {
        if directAskState != nil {
            clearDirectAsk()
            refreshAskState()
            refreshLayout(size: view.bounds.size)
            return
        }
        guard let bridge = askBridge(), let command = askCommand else {
            model.askState = .idle
            return
        }
        let release: KeyboardAskCommand = KeyboardAskCommand(
            requestID: command.requestID, action: .release, question: "", documentID: command.documentID, issuedAt: Date()
        )
        do {
            try bridge.write(release, file: .askCommand)
            try bridge.remove(file: .askAnswer)
        } catch {
            askLogger.error("Keyboard answer release failed: \(String(describing: error), privacy: .public)")
        }
        bridge.post(.ask)
        askCommand = release
        askAnswer = nil
        refreshAskState()
    }

    /// Copies the answer to the clipboard (Full Access) and says so for a moment.
    func copyAnswer() {
        guard case .answered(let text) = model.askState else {
            return
        }
        UIPasteboard.general.string = text
        model.askAnswerCopied = true
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            self?.model.askAnswerCopied = false
        }
    }

    /// After a direct question failed: Gistsmith opens and asks it there.
    func openAskInGistsmith() {
        guard let question = directQuestion else {
            return
        }
        askThroughGistsmith(question: question)
    }

    /// Asks the server directly; the strip shows "answering", then the answer or a failure with "Open in Gistsmith".
    private func askDirectly(question: String, token: KeyboardAskToken, meetings: [KeyboardAskMeeting]) {
        clearDirectAsk()
        directQuestion = question
        showDirect(state: .answering, canOpenInGistsmith: false)
        let body: KeyboardAskRequestBody = KeyboardAskRequestBody(question: question, meetings: meetings)
        directAsk = Task { [weak self] in
            let result: Result<String, KeyboardAskAttemptFailure> = await keyboardAskSend(token: token, body: body)
            guard !Task.isCancelled, let self else {
                return
            }
            switch result {
            case .success(let answer) where !answer.isEmpty:
                self.showDirect(state: .answered(answer), canOpenInGistsmith: false)
            case .success:
                // An empty answer was still charged: asking again is the user's own new question, not a button.
                self.showDirect(state: .failed(nil), canOpenInGistsmith: false)
            case .failure(let failure):
                let problem: KeyboardAskDirectProblem = keyboardAskDirectProblem(failure: failure)
                if problem == .renewToken {
                    // Revoked or expired: the next question opens Gistsmith, which mints a new token.
                    self.deleteAskToken()
                }
                // A question the server may already have charged gets no button that would ask (and charge) it again.
                self.showDirect(state: .failed(keyboardAskProblemText(problem)), canOpenInGistsmith: keyboardAskCanAskAgain(failure: failure))
            }
        }
    }

    private func showDirect(state: KeyboardAskState, canOpenInGistsmith: Bool) {
        directAskState = state
        model.askCanOpenInGistsmith = canOpenInGistsmith && directQuestion != nil
        model.askAnswerCopied = false
        refreshAskState()
        refreshLayout(size: view.bounds.size)
    }

    /// Drops a direct question (its request stops).
    func clearDirectAsk() {
        directAsk?.cancel()
        directAsk = nil
        directAskState = nil
        directQuestion = nil
        model.askCanOpenInGistsmith = false
        model.askAnswerCopied = false
    }

    private func readAskToken() -> KeyboardAskToken? {
        guard hasFullAccess else {
            return nil
        }
        do {
            return try KeyboardAskTokenKeychain(accessGroup: keyboardAppGroupIdentifier).read()
        } catch {
            askLogger.error("Keyboard Ask token unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func deleteAskToken() {
        do {
            try KeyboardAskTokenKeychain(accessGroup: keyboardAppGroupIdentifier).delete()
        } catch {
            askLogger.error("Keyboard Ask token removal failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func askBridge() -> KeyboardBridge? {
        guard hasFullAccess else {
            return nil
        }
        do {
            return try KeyboardBridge(containerURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: keyboardAppGroupIdentifier))
        } catch {
            askLogger.error("Keyboard App Group unavailable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    #if DEBUG
    /// `--klavye-sor-ornek` (Debug only, visual check): Gistsmith leaves this file in the App Group and the keyboard
    /// answers every question with a sample answer, as a direct question would, without the network.
    private func askDemoIsOn() -> Bool {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: keyboardAppGroupIdentifier) else {
            return false
        }
        return FileManager.default.fileExists(atPath: container.appendingPathComponent(keyboardAskDemoFileName).path)
    }

    private func askDemo(question: String) {
        model.isAsking = false
        model.askQuestion = ""
        model.askedQuestion = question
        clearDirectAsk()
        directQuestion = question
        showDirect(state: .answering, canOpenInGistsmith: false)
        let answer: String = Locale.current.language.languageCode?.identifier == "tr"
            ? "Pro plan aylık 14 $ olarak kalıyor. Yıllık planda %20 indirim denenecek, dönüşüme Aralık sonunda bakılacak. Ekip planının teklifini Mert Cuma'ya hazırlıyor."
            : "Pro stays at $14 a month. A 20% discount on the yearly plan will be tried, and conversion checked at the end of December. Mert prepares the team plan offer by Friday."
        directAsk = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2.6))
            } catch {
                return
            }
            self?.showDirect(state: .answered(answer), canOpenInGistsmith: false)
        }
    }
    #endif

    private func showAskPanel(info: KeyboardVoiceInfo) {
        model.panel = .voiceInfo(info)
        refreshLayout(size: view.bounds.size)
    }
}

/// What the strip says after a direct question failed; nil keeps the general "ask again" text.
private func keyboardAskProblemText(_ problem: KeyboardAskDirectProblem) -> String? {
    switch problem {
    case .unreachable:
        return String(localized: "Gistsmith'e ulaşılamadı. İnternet bağlantını kontrol et.")
    case .slow:
        return String(localized: "Cevap zamanında gelmedi.")
    case .renewToken:
        return String(localized: "Klavyeden sormak için Gistsmith'i bir kez aç.")
    case .notAvailable:
        return String(localized: "Bu soru şu an klavyeden sorulamıyor.")
    case .failed:
        return nil
    }
}
