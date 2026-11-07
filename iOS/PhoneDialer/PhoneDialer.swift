#if PHONE_DIALER
import AINotepadCore
import Foundation
import Observation
import os

/// Verification of the user's own number (caller ID).
enum PhoneVerificationPhase: Equatable {
    case idle
    case starting
    /// The provider is calling `e164`; the user types `code` on that call's keypad.
    case waiting(code: String, e164: String)
    case verified
    case failed(String)
}

/// A call's progress as the in-call screen shows it.
enum PhoneCallPhase: Equatable {
    case connecting
    case ringing
    case connected(since: Date)
    case reconnecting(since: Date)
    case ended
}

/// The call on screen (one at a time).
struct PhoneActiveCall: Identifiable, Equatable {
    /// The server's call id.
    let id: String
    let uuid: UUID
    let e164: String
    let maxSeconds: Int
    var phase: PhoneCallPhase
    var isMuted: Bool
    var isSpeaker: Bool
    /// Why the call ended early (failed to connect, dropped); `nil` for a normal end.
    var endMessage: String?
}

/// The finished call's recording on its way to a meeting.
enum PhoneRecordingPhase: Equatable {
    case idle
    case waiting
    case importing
    case imported
    case failed(String)
}

/// What tapping the call button did.
enum PhoneDialAction: Equatable {
    /// Emergency and short numbers: open in the Phone app.
    case openPhoneApp(URL)
    case started
    case refused(String)
}

/// Debug screenshots of the dialer's steps (`--arama izin|dogrula|kod|tus|gorusme`); the screens run without a server.
enum PhoneDialerPreview: String {
    case consent = "izin"
    case verify = "dogrula"
    case code = "kod"
    case keypad = "tus"
    case inCall = "gorusme"
}

/// The dialer for this launch: in Debug, `--arama <step>` shows that step with sample data (no server). Pure apart from
/// creating the dialer.
@MainActor
func makePhoneDialer(arguments: [String]) -> PhoneDialer {
    #if DEBUG
    if let index = arguments.firstIndex(of: "--arama"), arguments.indices.contains(index + 1),
       let preview = PhoneDialerPreview(rawValue: arguments[index + 1]) {
        return PhoneDialer(preview: preview)
    }
    #endif
    return PhoneDialer()
}

/// `--arama <step>`: the phone call guide opens with the dialer pushed (visual check). Pure function.
func launchOpensDialer(arguments: [String]) -> Bool {
    arguments.contains("--arama")
}

/// The in-app dialer (pilot; design in docs/superpowers/specs/2026-11-08-iphone-call-recording.md, phase 2): the
/// server's switch and the user's setup (`HostedPhoneClient`), the disclosure opt-in, verifying the user's own number,
/// placing a call through CallKit and the Twilio Voice SDK (`PhoneCallController`), and after the call importing the
/// provider's two-channel recording as an ordinary meeting (the existing import: transcription, speakers, note, tasks,
/// sync) and deleting it at the provider. Calls waiting for their recording survive an app restart
/// (`pendingRecordingsKey()`, per account). Numbers are not logged.
@MainActor
@Observable
final class PhoneDialer {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneDialer")
    /// Calls whose recording hasn't been imported yet: call id → number (E.164).
    private static let pendingRecordingsPrefix: String = "phoneDialer.pendingRecordings"
    /// Recording polls after a call (every `pollSeconds`); the provider sends it within seconds.
    private static let recordingPolls: Int = 40
    private static let pollSeconds: UInt64 = 3

    private(set) var status: HostedPhoneStatus?
    private(set) var statusError: String?
    private(set) var verification: PhoneVerificationPhase = .idle
    var activeCall: PhoneActiveCall?
    private(set) var recording: PhoneRecordingPhase = .idle
    /// The keypad's inline error (refused number, server refusal).
    var keypadMessage: String?
    @ObservationIgnored private let controller: PhoneCallController
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private var verificationTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    /// Calls whose recording is being imported now (`importRecording`).
    @ObservationIgnored private var importingCalls: Set<String> = []

    init() {
        controller = PhoneCallController()
        isPreview = false
        controller.onEvent = { [weak self] (event: PhoneCallEvent) -> Void in self?.handle(event: event) }
    }

    #if DEBUG
    /// A dialer showing `preview` with sample data and no server.
    init(preview: PhoneDialerPreview) {
        controller = PhoneCallController()
        isPreview = true
        let verified: Bool = preview == .keypad || preview == .inCall
        status = HostedPhoneStatus(
            available: true, reason: nil, countries: [.us, .ca], provider: "Twilio", consentVersion: phoneDialerConsentVersion,
            consentAccepted: preview != .consent, number: verified ? HostedPhoneNumber(e164: "+14155550142", status: .verified) : nil,
            maxCallMinutes: 60, monthlyMinutes: 120, usedMinutes: 34
        )
        if preview == .code {
            verification = .waiting(code: "482913", e164: "+14155550142")
        }
        if preview == .inCall {
            activeCall = PhoneActiveCall(
                id: "preview", uuid: UUID(), e164: "+12125550199", maxSeconds: 3600, phase: .connected(since: Date().addingTimeInterval(-125)),
                isMuted: false, isSpeaker: true, endMessage: nil
            )
        }
    }
    #endif

    /// Whether the dialer is available to this account (the server's switch, country and plan).
    var isAvailable: Bool {
        status?.available == true
    }

    private func client() throws -> HostedPhoneClient {
        let client: HostedClient = try HostedServices.requireClient()
        return HostedPhoneClient(baseURL: client.baseURL, credentials: client)
    }

    /// Reads the switch and the user's setup; then picks up recordings left from an earlier launch.
    func refresh(recorder: PhoneRecorder) async {
        guard !isPreview else {
            return
        }
        do {
            status = try await client().status()
            statusError = nil
            if status?.number?.status == .verified {
                verification = .verified
            }
            resumePendingRecordings(recorder: recorder)
        } catch {
            Self.logger.error("Dialer status failed, error: \(String(describing: error), privacy: .private)")
            statusError = userFacingMessage(error: error)
        }
    }

    /// Records the opt-in to the disclosure.
    func acceptConsent(recorder: PhoneRecorder) async {
        guard !isPreview else {
            return
        }
        do {
            try await client().acceptConsent(version: phoneDialerConsentVersion)
            await refresh(recorder: recorder)
        } catch {
            statusError = userFacingMessage(error: error)
        }
    }

    /// Starts verifying `input` as the user's own number: the provider calls it and the screen shows the code.
    func startVerification(input: String, recorder: PhoneRecorder) async {
        guard let status else {
            return
        }
        guard case .call(let e164, _) = phoneDialTarget(input: input, allowed: status.countries) else {
            verification = .failed(String(localized: "Kendi numaranı ülke koduyla yaz, ör. +1 415 555 0100."))
            return
        }
        verification = .starting
        do {
            let started: HostedPhoneVerification = try await client().startVerification(e164: e164)
            guard let code = started.validationCode, started.status == .pending else {
                verification = .verified
                await refresh(recorder: recorder)
                return
            }
            verification = .waiting(code: code, e164: e164)
            verificationTask?.cancel()
            verificationTask = Task { await self.awaitVerification(recorder: recorder) }
        } catch {
            verification = .failed(userFacingMessage(error: error))
        }
    }

    /// Polls the verification until the provider reports it (at most the server's 10-minute window).
    private func awaitVerification(recorder: PhoneRecorder) async {
        for _ in 0..<220 {
            do {
                try await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
                let number: HostedPhoneNumber? = try await client().number()
                switch number?.status {
                case .verified:
                    verification = .verified
                    await refresh(recorder: recorder)
                    return
                case .failed, nil:
                    verification = .failed(String(localized: "Numara doğrulanamadı. Aramayı açıp kodu tuşladığından emin ol ve yeniden dene."))
                    return
                case .pending:
                    continue
                }
            } catch is CancellationError {
                return
            } catch {
                Self.logger.warning("Verification poll failed, error: \(String(describing: error), privacy: .private)")
            }
        }
        verification = .failed(String(localized: "Doğrulama zaman aşımına uğradı; yeniden dene."))
    }

    /// Back to entering a number after a failed verification (or to replace the number).
    func resetVerification() {
        verificationTask?.cancel()
        verification = .idle
    }

    /// Dials `input`: emergency and short numbers go to the Phone app; other numbers are checked like the server checks
    /// them, reserved on the server and placed through CallKit.
    func call(input: String, recorder: PhoneRecorder) async -> PhoneDialAction {
        guard let status, activeCall == nil else {
            return .refused(String(localized: "Süren bir arama var."))
        }
        switch phoneDialTarget(input: input, allowed: status.countries) {
        case .phoneApp(let number):
            guard let url = phoneTelURL(number: number) else {
                return .refused(String(localized: "Numara geçersiz. Ülke koduyla yaz, ör. +1 415 555 0100."))
            }
            return .openPhoneApp(url)
        case .invalid:
            return .refused(String(localized: "Numara geçersiz. Ülke koduyla yaz, ör. +1 415 555 0100."))
        case .blocked(.notAllowed):
            return .refused(String(localized: "Bu ülkedeki numaralar henüz aranamıyor."))
        case .blocked:
            return .refused(String(localized: "Bu numara Gistsmith'ten aranamaz: ücretli, özel ya da desteklenmeyen bir ülkedeki numaralar engelli."))
        case .call(let e164, _):
            do {
                let reservation: HostedPhoneCallReservation = try await client().reserveCall(to: e164)
                let uuid: UUID = UUID()
                activeCall = PhoneActiveCall(
                    id: reservation.callId, uuid: uuid, e164: e164, maxSeconds: reservation.maxSeconds, phase: .connecting, isMuted: false, isSpeaker: false,
                    endMessage: nil
                )
                rememberPending(callID: reservation.callId, e164: e164)
                Self.logger.info("Call reserved, call: \(reservation.callId, privacy: .public), max seconds: \(reservation.maxSeconds, privacy: .public)")
                try await controller.start(uuid: uuid, e164: e164, accessToken: reservation.accessToken, callID: reservation.callId)
                watchRecording(callID: reservation.callId, e164: e164, recorder: recorder)
                return .started
            } catch {
                Self.logger.error("Call could not start, error: \(String(describing: error), privacy: .private)")
                // A reservation that never connected has nothing to import (the server releases it).
                if let reserved = activeCall?.id {
                    forgetPending(callID: reserved)
                }
                activeCall = nil
                return .refused(userFacingMessage(error: error))
            }
        }
    }

    /// Hangs up the call on screen.
    func hangUp() async {
        guard let call = activeCall, call.phase != .ended else {
            return
        }
        do {
            try await controller.end(uuid: call.uuid)
        } catch {
            Self.logger.error("Hang up request failed, error: \(String(describing: error), privacy: .private)")
            activeCall?.endMessage = userFacingMessage(error: error)
        }
    }

    func setMuted(_ muted: Bool) async {
        guard let call = activeCall else {
            return
        }
        do {
            try await controller.setMuted(uuid: call.uuid, muted: muted)
            activeCall?.isMuted = muted
        } catch {
            Self.logger.error("Mute request failed, error: \(String(describing: error), privacy: .private)")
        }
    }

    func setSpeaker(_ on: Bool) {
        controller.setSpeaker(on)
        activeCall?.isSpeaker = on
    }

    /// Closes the in-call screen after the call ended.
    func dismissEndedCall() {
        if activeCall?.phase == .ended {
            activeCall = nil
        }
    }

    private func handle(event: PhoneCallEvent) {
        switch event {
        case .ringing:
            activeCall?.phase = .ringing
        case .connected:
            activeCall?.phase = .connected(since: Date())
        case .reconnecting:
            if case .connected(let since) = activeCall?.phase {
                activeCall?.phase = .reconnecting(since: since)
            }
        case .reconnected:
            if case .reconnecting(let since) = activeCall?.phase {
                activeCall?.phase = .connected(since: since)
            }
        case .ended(let message):
            activeCall?.phase = .ended
            activeCall?.endMessage = message
        }
    }

    // MARK: Recording

    /// Waits for the call's recording after the call ends, imports it as a meeting and deletes it at the provider.
    private func watchRecording(callID: String, e164: String, recorder: PhoneRecorder) {
        recordingTask = Task {
            while self.activeCall?.id == callID, self.activeCall?.phase != .ended {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    // Cancelled: the recording waits in the pending list for the next launch.
                    return
                }
            }
            await self.importRecording(callID: callID, e164: e164, recorder: recorder)
            self.recordingTask = nil
        }
    }

    private func importRecording(callID: String, e164: String, recorder: PhoneRecorder) async {
        // One import per call at a time: the call's own watcher and a resume after a refresh may both reach it.
        guard !importingCalls.contains(callID) else {
            Self.logger.info("Call recording import already running, call: \(callID, privacy: .public)")
            return
        }
        // A call forgotten meanwhile was imported already (or isn't this account's): a resume working from an older
        // snapshot of the list must not import it again.
        guard pendingRecordings()[callID] != nil else {
            Self.logger.info("Call no longer pending, skipped, call: \(callID, privacy: .public)")
            return
        }
        importingCalls.insert(callID)
        defer { importingCalls.remove(callID) }
        recording = .waiting
        do {
            let client: HostedPhoneClient = try client()
            for _ in 0..<Self.recordingPolls {
                let state: HostedPhoneCallState = try await client.callState(callID: callID)
                switch phoneRecordingStep(state: state) {
                case .none:
                    Self.logger.info("Call has no recording, call: \(callID, privacy: .public), status: \(state.status.rawValue, privacy: .public)")
                    forgetPending(callID: callID)
                    recording = .idle
                    return
                case .wait:
                    try await Task.sleep(nanoseconds: Self.pollSeconds * 1_000_000_000)
                case .download:
                    recording = .importing
                    let file: URL = try recordingFileURL(callID: callID, e164: e164)
                    try await client.downloadRecording(callID: callID, destination: file)
                    let failure: String? = await recorder.importCallRecording(url: file)
                    // The import copied the audio into the meeting (or failed); the download is not needed either way. A
                    // leftover temporary file doesn't stop the provider copy's deletion (a retry would import it twice).
                    do {
                        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    } catch {
                        Self.logger.error("Downloaded call recording could not be removed, error: \(String(describing: error), privacy: .private)")
                    }
                    if let failure {
                        // The recording stays at the provider and in the pending list: the next launch retries until the
                        // server deletes it (a day).
                        Self.logger.error("Call recording import failed, kept at the provider, call: \(callID, privacy: .public)")
                        recording = .failed(failure)
                        return
                    }
                    // The meeting exists: forget the call first, so a failed provider deletion can't import it twice
                    // (the server deletes the copy after a day anyway).
                    forgetPending(callID: callID)
                    recording = .imported
                    Self.logger.info("Call recording imported, call: \(callID, privacy: .public)")
                    do {
                        _ = try await client.deleteRecording(callID: callID)
                    } catch {
                        Self.logger.warning("Imported call recording not deleted at the provider yet; the server deletes it within a day, error: \(String(describing: error), privacy: .private)")
                    }
                    return
                }
            }
            recording = .failed(String(localized: "Aramanın kaydı henüz gelmedi; uygulama bir sonraki açılışta yeniden dener."))
        } catch let error as HostedAPIError where error.code == .notFound {
            // Not this account's call (signed in with another account since) or already deleted: nothing to import here.
            Self.logger.warning("Pending call not found on the server, forgotten, call: \(callID, privacy: .public)")
            forgetPending(callID: callID)
            recording = .idle
        } catch {
            Self.logger.error("Call recording import failed, call: \(callID, privacy: .public), error: \(String(describing: error), privacy: .private)")
            recording = .failed(userFacingMessage(error: error))
        }
    }

    /// The downloaded recording's place: its own temporary folder, named after the call (the file name becomes the
    /// meeting's title).
    private func recordingFileURL(callID: String, e164: String) throws -> URL {
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "phone-call-\(callID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let title: String = String(localized: "\(phoneNumberDisplay(e164: e164)) ile arama")
        return folder.appending(path: "\(title).mp3")
    }

    /// The signed-in account's list (a call belongs to the account that placed it); `nil` without an account.
    private func pendingRecordingsKey() -> String? {
        phoneSignedInAccountKey().map { (account: String) -> String in "\(Self.pendingRecordingsPrefix).\(account)" }
    }

    private func pendingRecordings() -> [String: String] {
        guard let key = pendingRecordingsKey() else {
            return [:]
        }
        return UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private func rememberPending(callID: String, e164: String) {
        guard let key = pendingRecordingsKey() else {
            Self.logger.warning("No signed-in account; the call's recording isn't kept for a later launch")
            return
        }
        var pending: [String: String] = pendingRecordings()
        pending[callID] = e164
        UserDefaults.standard.set(pending, forKey: key)
    }

    private func forgetPending(callID: String) {
        guard let key = pendingRecordingsKey() else {
            return
        }
        var pending: [String: String] = pendingRecordings()
        pending.removeValue(forKey: callID)
        UserDefaults.standard.set(pending, forKey: key)
    }

    /// Imports recordings of calls that ended while the app was closed (one at a time; the server deletes unfetched
    /// recordings after a day).
    private func resumePendingRecordings(recorder: PhoneRecorder) {
        let pending: [(key: String, value: String)] = pendingRecordings().sorted { $0.key < $1.key }
        guard recordingTask == nil, activeCall == nil, !pending.isEmpty else {
            return
        }
        // Every pending call in turn: one that can't import yet doesn't hold back the others.
        recordingTask = Task {
            for (callID, e164) in pending {
                await self.importRecording(callID: callID, e164: e164, recorder: recorder)
            }
            self.recordingTask = nil
        }
    }
}
#endif
