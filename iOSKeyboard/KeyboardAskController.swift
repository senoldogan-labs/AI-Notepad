import KeyboardCore
import os
import UIKit

/// Yalnız hata türü ve dosya adı yazılır; soru ve cevap hiçbir zaman loglanmaz.
private let askLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "KeyboardAsk")

/// Klavyeden Gistsmith'e soru. Tuşlar soru alanına yazar (belgeye değil); "Sor" soruyu App Group'a yazar ve Gistsmith'i
/// açar (mikrofon oturumu açıksa açmadan bildirir). Klavye ağa çıkmaz, hesabın jetonunu görmez: cevabı uygulama yazar,
/// klavye "Ekle" ile ekler ve dosyayı siler (bkz. `PhoneKeyboardAskHost`).
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
        guard !question.isEmpty, let bridge = askBridge() else {
            return
        }
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
        model.isAsking = false
        model.askQuestion = ""
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
