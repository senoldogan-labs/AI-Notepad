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
    /// Sorulan soru ve cevabın durumu (sayfa gösterir).
    private(set) var question: String?
    private(set) var phase: KeyboardAskAnswer.Phase?
    private(set) var answer: String?
    private(set) var failureReason: String?

    /// Soruyu yüklü hesabın Sor'una sorar, cevabın metnini döndürür (bkz. `PhoneAsk.askForIntent`).
    @ObservationIgnored var askQuestion: @MainActor (String) async throws -> String = { (_: String) async throws -> String in
        throw MeetingIntentError.notReady
    }

    @ObservationIgnored private var bridge: KeyboardBridge?
    @ObservationIgnored private var observer: KeyboardSignalObserver?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var runningRequest: UUID?
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
                self?.removeStaleAnswer()
            }
        }
        removeStaleAnswer()
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

    /// Cevap eklenince ya da bırakılınca (klavye `release` der) ya da sayfa kapanınca silinir.
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
                running?.cancel()
                running = nil
                runningRequest = nil
            }
            removeAnswer()
        }
    }

    private func ask(command: KeyboardAskCommand) {
        guard runningRequest != command.requestID else {
            return
        }
        running?.cancel()
        let requestID: UUID = command.requestID
        let question: String = command.question.trimmingCharacters(in: .whitespacesAndNewlines)
        runningRequest = requestID
        self.question = question
        answer = nil
        failureReason = nil
        write(KeyboardAskAnswer(requestID: requestID, phase: .answering, answer: nil, failureReason: nil, updatedAt: Date()))
        // Kullanıcı hemen klavyeye döner: cevap uygulama arka plandayken de bitsin. iOS'un verdiği süre (~30 sn) dolarsa
        // soru durur, neden klavyede görünür ve görev hemen biter (bitmeyen görev uygulamanın sonlandırılmasına yol açar).
        let backgroundTask: KeyboardAskBackgroundTask = KeyboardAskBackgroundTask()
        backgroundTask.identifier = UIApplication.shared.beginBackgroundTask(withName: "keyboard-ask") { [weak self] in
            MainActor.assumeIsolated {
                keyboardAskLogger.warning("Klavyeden gelen soru arka plan süresinde bitmedi; durduruluyor")
                self?.running?.cancel()
                self?.fail(requestID: requestID, reason: String(localized: "Gistsmith cevabı arka planda bitiremedi. Gistsmith'i açık tutup yeniden sor."))
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

    private func finish(requestID: UUID, answer text: String) {
        guard runningRequest == requestID else {
            return
        }
        runningRequest = nil
        running = nil
        guard !text.isEmpty else {
            fail(requestID: requestID, reason: String(localized: "Cevap boş geldi. Soruyu yeniden sor."))
            return
        }
        answer = text
        write(KeyboardAskAnswer(requestID: requestID, phase: .answered, answer: text, failureReason: nil, updatedAt: Date()))
        // Uygulama o zamana dek çalışıyorsa kullanılmayan cevap 10 dakika dolunca silinir.
        expiry?.cancel()
        expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(keyboardAskAnswerLifetime + 1))
            } catch {
                return
            }
            self?.removeStaleAnswer()
        }
    }

    private func fail(requestID: UUID, reason: String) {
        // Bırakılan ya da yerine yenisi sorulan sorunun geç gelen hatası dosyayı yeniden yazmaz.
        guard runningRequest == requestID else {
            return
        }
        runningRequest = nil
        running = nil
        failureReason = reason
        write(KeyboardAskAnswer(requestID: requestID, phase: .failed, answer: nil, failureReason: reason, updatedAt: Date()))
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

    private func write(_ value: KeyboardAskAnswer) {
        guard let bridge else {
            return
        }
        phase = value.phase
        do {
            try bridge.write(value, file: .askAnswer)
        } catch {
            keyboardAskLogger.error("Soru cevabı yazılamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
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
        running?.cancel()
        running = nil
        runningRequest = nil
        question = nil
        answer = nil
        failureReason = nil
        phase = nil
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
