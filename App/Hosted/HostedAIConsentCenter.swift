import AINotepadCore
import Foundation
import Observation
import os

private let consentLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAIConsent")

/// The account's answer to the third-party AI disclosure, in the account's own defaults (`hostedAccountDefaults`; JSON
/// `HostedAIConsentRecord`). Removed with the account.
let hostedAIConsentRecordKey: String = "hosted.aiConsent"

/// The answer to the third-party AI disclosure (App Review 5.1.1(i) / 5.1.2(i); rules in `HostedAIConsent.swift`), shared
/// by the Mac and iPhone apps. Per account and device: loaded when the signed-in account's data is synced, mirrored into
/// `HostedClient`'s gate (no AI request without it) and recorded on the server. The disclosure comes before the app while
/// the account has not answered (`needsPrompt`); after "Not now" an AI feature (Record, Ask, a waiting meeting) asks for it
/// again through `requestPrompt` and the app presents it (`isPromptRequested`). Settings shows the state and withdraws.
@MainActor
@Observable
final class HostedAIConsentCenter {
    static let shared: HostedAIConsentCenter = HostedAIConsentCenter()

    /// The loaded account's answer; nil when it never answered (or nothing is loaded).
    private(set) var record: HostedAIConsentRecord?
    /// The account whose answer is loaded; nil while signed out.
    private(set) var loadedUserID: String?
    /// An AI feature asked for the disclosure: the app presents it once (Mac: the main window, iPhone: a sheet).
    var isPromptRequested: Bool = false
    /// Why the answer could not be stored on this device; nil when it was.
    private(set) var errorMessage: String?

    private init() {}

    /// AI features may send data (the user agreed to the current disclosure).
    var isGranted: Bool {
        hostedAIConsentAllows(record: record)
    }

    /// The disclosure comes before the app (signed in, never answered or agreed only to an older text).
    var needsPrompt: Bool {
        loadedUserID != nil && hostedAIConsentNeedsPrompt(record: record)
    }

    /// Loads the signed-in account's answer (nil: signed out) and applies it to the client's gate. Debug demo launches
    /// (`--tanitim`) have no account: they count as agreed unless `--aciklama` shows the disclosure.
    func load(userID: String?) {
        #if DEBUG
        if isDemoMode {
            loadedUserID = "demo"
            if record == nil, !CommandLine.arguments.contains("--aciklama") {
                record = HostedAIConsentRecord(status: .granted, version: hostedAIConsentVersion, decidedAt: Date(), syncedToServer: true, serverDecidedAt: nil)
            }
            applyToClient()
            return
        }
        #endif
        guard userID != loadedUserID || userID == nil else {
            // Same account, e.g. signed in again: the client closed its gate at the session change, so it gets this
            // account's consent again.
            applyToClient()
            return
        }
        loadedUserID = userID
        record = nil
        isPromptRequested = false
        if let userID {
            do {
                record = try readRecord(defaults: try hostedAccountDefaults(accountKey: accountDataKey(userId: userID)))
            } catch {
                consentLogger.error("AI consent could not be read, treated as unanswered, error: \(String(describing: error), privacy: .private)")
            }
        }
        applyToClient()
    }

    /// "Agree": stored on this device, AI requests allowed at once, then recorded on the server.
    func grant() async {
        store(HostedAIConsentRecord(status: .granted, version: hostedAIConsentVersion, decidedAt: Date(), syncedToServer: false, serverDecidedAt: nil))
        isPromptRequested = false
        await upload()
        // Meetings that waited for consent are processed at once (after the server has the answer, when reachable).
        HostedAccount.shared.aiConsentGranted()
    }

    /// "Not now" on the disclosure: AI features stay off, nothing is sent (an agreement given on another device is kept).
    func decline() {
        // A user who already agreed and only reopened the disclosure keeps the agreement; a withdrawal (perhaps not sent
        // yet) stays a withdrawal, so it still reaches the server.
        if !isGranted, record?.status != .withdrawn {
            store(HostedAIConsentRecord(status: .declined, version: hostedAIConsentVersion, decidedAt: Date(), syncedToServer: false, serverDecidedAt: nil))
        }
        isPromptRequested = false
    }

    /// Settings › "Withdraw": AI requests stop at once (running ones fail at their next request), then the server records it.
    func withdraw() async {
        store(HostedAIConsentRecord(status: .withdrawn, version: hostedAIConsentVersion, decidedAt: Date(), syncedToServer: false, serverDecidedAt: nil))
        await upload()
    }

    /// An AI feature was used without consent: the app presents the disclosure.
    func requestPrompt() {
        isPromptRequested = true
    }

    /// After the account's entitlements were read: sends an unsent answer, or follows a withdrawal made on another device.
    func reconcile(server: HostedAIConsentServerState?) async {
        switch hostedAIConsentSync(local: record, server: server) {
        case .none:
            return
        case .upload:
            await upload()
        case .adoptWithdrawal:
            consentLogger.info("AI consent was withdrawn on another device; AI features turn off here too")
            store(HostedAIConsentRecord(status: .withdrawn, version: hostedAIConsentVersion, decidedAt: Date(), syncedToServer: true, serverDecidedAt: nil))
        }
    }

    /// Forgets a deleted account's answer on this device.
    func forgetAfterAccountDeletion(userID: String) {
        do {
            try hostedAccountDefaults(accountKey: accountDataKey(userId: userID)).removeObject(forKey: hostedAIConsentRecordKey)
        } catch {
            consentLogger.error("A deleted account's AI consent could not be removed, error: \(String(describing: error), privacy: .private)")
        }
        if loadedUserID == userID {
            loadedUserID = nil
            record = nil
            applyToClient()
        }
    }

    /// Before a meeting opens or a waiting one is prepared on the server: an agreement the server has not recorded yet
    /// (the request after "Agree" failed or is still running) is sent first, so the server does not refuse the meeting
    /// with `ai_consent_required` while this device shows AI as on. Throws the request's error (the caller treats a
    /// network error as offline).
    func recordPendingAgreement() async throws {
        guard let current = record, current.status == .granted, !current.syncedToServer else {
            return
        }
        try await send(current)
    }

    /// Sends the stored answer to the server; marks it sent when the server recorded it. A failure (offline, older
    /// server) is logged and retried at the next entitlements read (`reconcile`) or before the next meeting
    /// (`recordPendingAgreement`); the answer on this device holds meanwhile.
    private func upload() async {
        guard let current = record, current.status != .declined else {
            return
        }
        do {
            try await send(current)
        } catch {
            consentLogger.warning("AI consent not recorded on the server yet, retried later, error: \(String(describing: error), privacy: .private)")
        }
    }

    /// `PUT /v1/me/ai-consent` with `current`; marks it sent unless the answer changed while the request ran.
    private func send(_ current: HostedAIConsentRecord) async throws {
        #if DEBUG
        if isDemoMode {
            return
        }
        #endif
        guard let userID = loadedUserID else {
            return
        }
        let client: HostedClient = try HostedServices.requireClient()
        let recorded: HostedAIConsentServerState = try await client.recordAIConsent(granted: current.status == .granted, version: current.version)
        guard loadedUserID == userID, record == current else {
            return
        }
        store(HostedAIConsentRecord(
            status: current.status, version: current.version, decidedAt: current.decidedAt, syncedToServer: true, serverDecidedAt: recorded.decidedAt
        ))
    }

    /// Keeps `record` and the account's defaults in step and applies it to the client's gate.
    private func store(_ next: HostedAIConsentRecord) {
        record = next
        applyToClient()
        #if DEBUG
        if isDemoMode {
            return
        }
        #endif
        guard let userID = loadedUserID else {
            return
        }
        do {
            let data: Data = try JSONEncoder().encode(next)
            try hostedAccountDefaults(accountKey: accountDataKey(userId: userID)).set(data, forKey: hostedAIConsentRecordKey)
            errorMessage = nil
        } catch {
            consentLogger.error("AI consent could not be stored, error: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func readRecord(defaults: UserDefaults) throws -> HostedAIConsentRecord? {
        guard let data = defaults.data(forKey: hostedAIConsentRecordKey) else {
            return nil
        }
        return try JSONDecoder().decode(HostedAIConsentRecord.self, from: data)
    }

    private func applyToClient() {
        do {
            try HostedServices.requireClient().setAIConsent(granted: isGranted)
        } catch {
            consentLogger.error("AI consent could not reach the server client, error: \(String(describing: error), privacy: .private)")
        }
    }
}
