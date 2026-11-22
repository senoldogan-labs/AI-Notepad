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
        guard hasFullAccess else {
            showAskPanel()
            return
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
        let token: KeyboardAskToken? = readAskToken()
        let meetings: [KeyboardMeetingItem] = model.meetings ?? []
        let route: KeyboardAskRoute = keyboardAskRoute(
            sessionIsLive: keyboardSessionIsLive(session: status?.session, now: Date()), hasFullAccess: hasFullAccess, token: token,
            hasLocalContext: !meetings.isEmpty, now: Date()
        )
        model.isAsking = false
        model.askQuestion = ""
        if route == .direct, let token {
            let context: [KeyboardAskMeeting] = token.serverContext ? [] : keyboardAskContext(
                meetings: meetings, budgetBytes: keyboardAskContextBudgetBytes, summaryMaxChars: keyboardAskSummaryMaxChars, maxMeetings: keyboardAskMaxMeetings
            )
            askDirectly(question: question, token: token, meetings: context)
        } else {
            askThroughGistsmith(question: question)
        }
    }

    /// The question goes to Gistsmith through the App Group: a live session answers in place, otherwise Gistsmith opens.
    private func askThroughGistsmith(question: String) {
        guard let bridge = askBridge() else {
            return
        }
        clearDirectAsk()
        let command: KeyboardAskCommand = KeyboardAskCommand(
            requestID: UUID(), action: .ask, question: question, documentID: currentDocumentID(), issuedAt: Date()
        )
        do {
            try bridge.write(command, file: .askCommand)
            try bridge.remove(file: .askAnswer)
        } catch {
            askLogger.error("Keyboard question write failed: \(String(describing: error), privacy: .public)")
            return
        }
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
            if model.askState != directAskState {
                model.askState = directAskState
            }
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
        let state: KeyboardAskState = keyboardAskState(command: askCommand, answer: askAnswer, now: now)
        if model.askState != state {
            model.askState = state
        }
    }

    /// Cevabı imlecin yerine ekler; sonra cevap dosyası silinir.
    func insertAnswer() {
        guard case .answered(let text) = model.askState else {
            return
        }
        insert(keyboardDictationInsertion(text: text, contextBefore: textDocumentProxy.documentContextBeforeInput ?? ""))
        releaseAnswer()
        afterEdit()
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
        showDirect(state: .answering)
        let body: KeyboardAskRequestBody = KeyboardAskRequestBody(question: question, meetings: meetings)
        directAsk = Task { [weak self] in
            let result: Result<String, KeyboardAskAttemptFailure> = await keyboardAskSend(token: token, body: body)
            guard !Task.isCancelled, let self else {
                return
            }
            switch result {
            case .success(let answer) where !answer.isEmpty:
                self.showDirect(state: .answered(answer))
            case .success:
                self.showDirect(state: .failed(nil))
            case .failure(let failure):
                if failure == .status(401) {
                    // Revoked or expired: the next question opens Gistsmith, which mints a new token.
                    self.deleteAskToken()
                }
                self.showDirect(state: .failed(nil))
            }
        }
    }

    private func showDirect(state: KeyboardAskState) {
        directAskState = state
        model.askCanOpenInGistsmith = state != .answering && directQuestion != nil
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

    private func showAskPanel() {
        model.panel = .voiceInfo(.needsFullAccess)
        refreshLayout(size: view.bounds.size)
    }
}
