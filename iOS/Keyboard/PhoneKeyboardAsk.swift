import AINotepadCore
import Foundation
import KeyboardCore
import Observation
import os
import UIKit

private let keyboardAskLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "KeyboardAsk")

/// Klavyeden Gistsmith'e sorunun uygulama tarafı. Klavye hesabın jetonunu hiç görmez ve ağa çıkmaz: soruyu App Group'a
/// yazar, uygulamayı `gistsmith://keyboard/ask/<istek>` ile açar (mikrofon oturumu açıksa açmadan bildirir); uygulama
/// soruyu kendi oturumuyla Sor'a (bütün toplantılar, örnek toplantı hariç; Siri ile aynı yol `PhoneAsk.askForIntent`)
/// sorar ve yalnız cevabın düz metnini `ask-answer.json`'a yazar. Cevap eklenince ya da bırakılınca hemen silinir;
/// kullanılmayan cevap 10 dakikadan sonra gösterilmez ve uygulama çalışıyorsa o an, değilse klavye ya da uygulama bir
/// sonraki açılışta (öne gelişte) silinir. Soru, uygulamadaki Sor gibi hesabın payından düşer ve Sor geçmişinde kalır.
@MainActor
@Observable
final class PhoneKeyboardAskHost {
    static let shared: PhoneKeyboardAskHost = PhoneKeyboardAskHost()

    /// Bağlantıyla açılan "cevaplanıyor, uygulamana dön" sayfası.
    var isShowingSheet: Bool = false
    /// The question and how far its answer got (the sheet shows it; see `keyboardAskSheetTransition`). It drops an
    /// answer the keyboard inserted or dismissed, and one that expired.
    private(set) var sheet: KeyboardAskSheetState = .idle

    /// Sor'daki süren soruyu hemen durdurur (iptal, Sor alanını bir sonraki soruya hazır bırakır).
    @ObservationIgnored var stopQuestion: @MainActor () -> Void = {}
    /// Soruyu yüklü hesabın Sor'una sorar, cevabın metnini döndürür (bkz. `PhoneAsk.askForIntent`).
    @ObservationIgnored var askQuestion: @MainActor (String) async throws -> String = { (_: String) async throws -> String in
        throw MeetingIntentError.notReady
    }

    @ObservationIgnored private var bridge: KeyboardBridge?
    @ObservationIgnored private var observer: KeyboardSignalObserver?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var runningRequest: UUID?
    /// The last question this run started asking (running or done): never asked again when the app comes to the front.
    @ObservationIgnored private var askedRequest: UUID?
    @ObservationIgnored private var activeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    private init() {}

    /// App Group'a bağlanır, eski cevabı siler ve klavyenin sorularını dinler (açılışta).
    func start() {
        guard bridge == nil else {
            return
        }
        do {
            bridge = try KeyboardBridge(containerURL: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: keyboardAppGroupIdentifier))
        } catch {
            keyboardAskLogger.error("Klavyenin App Group kabı açılamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        observer = KeyboardSignalObserver(signal: .ask) { [weak self] in
            self?.commandArrived()
        }
        // Her öne gelişte süresi geçen cevap silinir (uygulama askıdayken zamanlayıcı çalışmaz).
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) in
            MainActor.assumeIsolated {
                self?.becameActive()
            }
        }
        removeStaleAnswer()
    }

    /// Coming to the front: the expired answer goes, a release the keyboard wrote while Gistsmith was suspended (Darwin
    /// signals are not delivered then) is applied, and a question waiting for Gistsmith (its link could not open the app,
    /// so the user opened it by hand) is asked.
    private func becameActive() {
        removeStaleAnswer()
        apply(.tick(now: Date()))
        let command: KeyboardAskCommand? = readCommand()
        if let command, command.action == .release {
            apply(.released(requestID: command.requestID))
        }
        guard keyboardAskHostShouldAdopt(command: command, answer: readAnswer(), askedRequest: askedRequest, now: Date()), let command else {
            return
        }
        keyboardAskLogger.info("Klavyenin bekleyen sorusu uygulama açılınca soruluyor")
        isShowingSheet = true
        ask(command: command)
    }

    /// `gistsmith://keyboard/ask/<istek>`: yalnız App Group'ta aynı istek için az önce yazılmış soru sorulur.
    func open(requestID: UUID) {
        start()
        guard let command = readCommand(), keyboardAskCommandIsValid(command: command, requestID: requestID, now: Date()) else {
            keyboardAskLogger.warning("Klavye soru bağlantısı geçerli bir soru olmadan geldi; yok sayıldı")
            return
        }
        isShowingSheet = true
        ask(command: command)
    }

    /// Sayfayı kapatır; soru sürer, cevap klavyeye yine yazılır (dosyayı klavyenin `release`'i ya da süre siler).
    func dismiss() {
        isShowingSheet = false
    }

    // MARK: Klavyeden gelenler

    private func commandArrived() {
        guard let command = readCommand() else {
            return
        }
        switch command.action {
        case .ask:
            // Mikrofon oturumu açıkken uygulama arka planda çalışır: klavye uygulamayı açmadan sorar.
            guard keyboardAskCommandIsValid(command: command, requestID: command.requestID, now: Date()) else {
                return
            }
            ask(command: command)
        case .release:
            if runningRequest == command.requestID {
                stopRunningQuestion()
            }
            apply(.released(requestID: command.requestID))
            removeAnswer()
        }
    }

    /// Moves the sheet to its next state; a sheet left with nothing to show closes.
    private func apply(_ event: KeyboardAskSheetEvent) {
        sheet = keyboardAskSheetTransition(state: sheet, event: event)
        if sheet == .idle {
            isShowingSheet = false
        }
    }

    private func ask(command: KeyboardAskCommand) {
        // The same question is asked once, however often it arrives (link and signal, or coming to the front).
        guard askedRequest != command.requestID else {
            return
        }
        // Yerine yeni soru gelen eski soru Sor'da da hemen durur.
        if runningRequest != nil {
            stopRunningQuestion()
        }
        let requestID: UUID = command.requestID
        let question: String = command.question.trimmingCharacters(in: .whitespacesAndNewlines)
        askedRequest = requestID
        sheet = keyboardAskSheetTransition(state: sheet, event: .asked(requestID: requestID, question: question, issuedAt: command.issuedAt))
        // Written at once: the keyboard knows the question reached Gistsmith (`keyboardAskState`). If it cannot be
        // written, the answer could not reach the keyboard either: the question is not asked (and not charged).
        do {
            try write(KeyboardAskAnswer(requestID: requestID, phase: .answering, answer: nil, failureReason: nil, updatedAt: Date()))
        } catch {
            keyboardAskLogger.error("Soru cevabı yazılamadı, hata: \(String(describing: error), privacy: .public)")
            apply(.failed(requestID: requestID, reason: userFacingMessage(error: error)))
            return
        }
        runningRequest = requestID
        // Kullanıcı hemen klavyeye döner: cevap uygulama arka plandayken de bitsin. iOS'un verdiği süre (~30 sn) dolarsa
        // soru durur, neden klavyede görünür ve görev hemen biter (bitmeyen görev uygulamanın sonlandırılmasına yol açar).
        let backgroundTask: KeyboardAskBackgroundTask = KeyboardAskBackgroundTask()
        backgroundTask.identifier = UIApplication.shared.beginBackgroundTask(withName: "keyboard-ask") { [weak self] in
            MainActor.assumeIsolated {
                keyboardAskLogger.warning("Klavyeden gelen soru arka plan süresinde bitmedi; durduruluyor")
                // Yalnız bu soru sürüyorsa: önce iş iptal edilir, sonra neden yazılır, en son Sor'daki soru durur.
                guard let self, self.runningRequest == requestID else {
                    backgroundTask.end()
                    return
                }
                self.running?.cancel()
                self.fail(requestID: requestID, reason: String(localized: "Gistsmith cevabı arka planda bitiremedi. Gistsmith'i açık tutup yeniden sor."))
                self.stopQuestion()
                backgroundTask.end()
            }
        }
        let askQuestion: @MainActor (String) async throws -> String = askQuestion
        running = Task { [weak self] in
            defer {
                backgroundTask.end()
            }
            do {
                let raw: String = try await askQuestion(question)
                try Task.checkCancellation()
                self?.finish(requestID: requestID, answer: plainAnswerText(text: raw))
            } catch is CancellationError {
                return
            } catch MeetingIntentError.askFailed(let reason) {
                self?.fail(requestID: requestID, reason: reason)
            } catch {
                keyboardAskLogger.error("Klavyeden gelen soru cevaplanamadı, hata: \(String(describing: error), privacy: .private)")
                self?.fail(requestID: requestID, reason: userFacingMessage(error: error))
            }
        }
    }

    /// Süren soruyu durdurur: bekleyen iş iptal edilir ve Sor'daki soru eşzamanlı durur (sonraki soru "meşgul" diye
    /// geri çevrilmesin).
    private func stopRunningQuestion() {
        running?.cancel()
        running = nil
        runningRequest = nil
        stopQuestion()
    }

    private func finish(requestID: UUID, answer text: String) {
        guard runningRequest == requestID else {
            return
        }
        // Boş cevap başarısızlıktır: `fail` istek hâlâ sürüyorken çağrılmalı (geç gelen hatayı ayıran koşul).
        guard !text.isEmpty else {
            fail(requestID: requestID, reason: String(localized: "Cevap boş geldi. Soruyu yeniden sor."))
            return
        }
        do {
            try write(KeyboardAskAnswer(requestID: requestID, phase: .answered, answer: text, failureReason: nil, updatedAt: Date()))
        } catch {
            // The keyboard never gets this answer: the sheet must not show it as delivered either.
            keyboardAskLogger.error("Soru cevabı yazılamadı, hata: \(String(describing: error), privacy: .public)")
            fail(requestID: requestID, reason: userFacingMessage(error: error))
            return
        }
        runningRequest = nil
        running = nil
        apply(.answered(requestID: requestID, answer: text))
        scheduleExpiry()
    }

    /// Uygulama o zamana dek çalışıyorsa kullanılmayan cevap (ya da neden) süre dolunca silinir; sayfa da onu bırakır.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(keyboardAskAnswerLifetime + 1))
            } catch {
                return
            }
            self?.removeStaleAnswer()
            self?.apply(.tick(now: Date()))
        }
    }

    private func fail(requestID: UUID, reason: String) {
        // Bırakılan ya da yerine yenisi sorulan sorunun geç gelen hatası dosyayı yeniden yazmaz.
        guard runningRequest == requestID else {
            return
        }
        runningRequest = nil
        running = nil
        do {
            try write(KeyboardAskAnswer(requestID: requestID, phase: .failed, answer: nil, failureReason: reason, updatedAt: Date()))
        } catch {
            // The keyboard then times the question out on its own (`keyboardAskAnsweringTimeout`).
            keyboardAskLogger.error("Soru cevabı yazılamadı, hata: \(String(describing: error), privacy: .public)")
        }
        apply(.failed(requestID: requestID, reason: reason))
        scheduleExpiry()
    }

    // MARK: Dosyalar

    private func readCommand() -> KeyboardAskCommand? {
        guard let bridge else {
            return nil
        }
        do {
            return try bridge.read(KeyboardAskCommand.self, file: .askCommand)
        } catch {
            keyboardAskLogger.error("Klavyenin sorusu okunamadı, hata: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func readAnswer() -> KeyboardAskAnswer? {
        guard let bridge else {
            return nil
        }
        do {
            return try bridge.read(KeyboardAskAnswer.self, file: .askAnswer)
        } catch {
            keyboardAskLogger.error("Soru cevabı okunamadı, hata: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Writes the answer state for the keyboard and signals it; throws when the file cannot be written.
    private func write(_ value: KeyboardAskAnswer) throws {
        guard let bridge else {
            throw KeyboardAskHostError.bridgeUnavailable
        }
        try bridge.write(value, file: .askAnswer)
        bridge.post(.askAnswer)
    }

    private func removeAnswer() {
        guard let bridge else {
            return
        }
        do {
            try bridge.remove(file: .askAnswer)
        } catch {
            keyboardAskLogger.error("Soru cevabı silinemedi, hata: \(String(describing: error), privacy: .public)")
        }
        bridge.post(.askAnswer)
    }

    /// Açılışta: süresi geçen ya da artık son soruya ait olmayan cevap silinir.
    private func removeStaleAnswer() {
        guard let bridge else {
            return
        }
        do {
            let command: KeyboardAskCommand? = readCommand()
            let answer: KeyboardAskAnswer? = try bridge.read(KeyboardAskAnswer.self, file: .askAnswer)
            if keyboardAskAnswerIsStale(answer: answer, command: command, now: Date()) {
                try bridge.remove(file: .askAnswer)
            }
            // Kullanılmayan sorunun metni de cevabın süresinden uzun kalmaz.
            if let command, Date().timeIntervalSince(command.issuedAt) > keyboardAskAnswerLifetime {
                try bridge.remove(file: .askCommand)
            }
        } catch {
            keyboardAskLogger.error("Eski soru cevabı silinemedi, hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Çıkış ya da hesap silme: süren soru durur, cevap silinir.
    func clearAccountData() {
        stopRunningQuestion()
        expiry?.cancel()
        expiry = nil
        askedRequest = nil
        apply(.cleared)
        removeAnswer()
        guard let bridge else {
            return
        }
        do {
            try bridge.remove(file: .askCommand)
        } catch {
            keyboardAskLogger.error("Klavyenin sorusu silinemedi, hata: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Why the app could not hand an answer to the keyboard.
enum KeyboardAskHostError: Error {
    /// The App Group container could not be opened (see `start`).
    case bridgeUnavailable
}

/// Arka plan görevinin kimliği: hem süre dolunca hem iş bitince bir kez bitirilir.
@MainActor
private final class KeyboardAskBackgroundTask {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
