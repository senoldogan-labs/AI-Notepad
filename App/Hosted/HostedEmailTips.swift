import AINotepadCore
import Foundation
import Observation
import os

private let emailLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedEmail")

/// The card after sign-in was closed on this device (shown once per device).
let hostedEmailPromptDismissedKey: String = "hosted.emailPromptDismissed"

/// The opt-in's notice at the point of collection (GDPR Art. 13): what is kept, for how long, and where to read more.
/// Same sentence on Mac and iPhone.
func hostedEmailPrivacyText() -> String {
    String(localized: "Adresi yalnız bu e-postalar için saklarız: onaylamazsan 7 gün içinde, kapatınca hemen, en geç 60 gün sonra sileriz.")
}

/// The opt-in's state in one line (Settings › Account on Mac and iPhone). Pure function.
func hostedEmailStatusText(state: HostedEmailState) -> String {
    switch state.status {
    case .off:
        return String(localized: "Birkaç kısa ipucu ve denemen bitmeden bir hatırlatma; başka bir şey göndermeyiz.")
    case .pending:
        return String(localized: "Onay bağlantısı \(state.pendingAddress ?? "") adresine gönderildi. Bağlantıya tıklayınca e-postalar başlar.")
    case .confirmed:
        if let pending = state.pendingAddress {
            return String(localized: "\(state.address ?? "") adresine gönderiliyor. Yeni adres (\(pending)) onaylanınca ona geçer.")
        }
        return String(localized: "\(state.address ?? "") adresine gönderiliyor.")
    }
}

/// The privacy policy's section on these emails (a fixed, valid literal).
let hostedEmailPrivacyURL: URL = URL(string: "https://gistsmith.com/privacy#messages")!

/// Opt-in tips and reminder emails (rules in `HostedEmail.swift`), shared by the Mac and iPhone apps: the server's state
/// for the signed-in account, opting in (the server sends a confirmation link), switching off, and the one-time card after
/// sign-in. Nothing is shown while the server doesn't offer it (`HostedEmailState.available`) or before the state is read.
@MainActor
@Observable
final class HostedEmailTips {
    static let shared: HostedEmailTips = HostedEmailTips()

    /// The account's state; nil until read (signed out, offline or not loaded yet: the opt-in is hidden).
    private(set) var state: HostedEmailState?
    /// A request is running (buttons are locked).
    private(set) var isWorking: Bool = false
    /// Why the last opt-in or switch-off failed; cleared by the next one.
    private(set) var errorMessage: String?
    /// The card after sign-in was closed on this device.
    private(set) var isPromptDismissed: Bool = UserDefaults.standard.bool(forKey: hostedEmailPromptDismissedKey)

    /// The card after sign-in shows now.
    var isPromptVisible: Bool {
        hostedEmailPromptVisible(state: state, dismissed: isPromptDismissed)
    }

    /// Reads the account's state (Settings › Account and the main screen call it once signed in).
    func refresh() async {
        #if DEBUG
        if isDemoMode {
            if state == nil {
                state = hostedEmailDemoState(arguments: CommandLine.arguments)
            }
            return
        }
        #endif
        do {
            state = try await HostedServices.requireClient().emailState()
        } catch {
            // The opt-in stays hidden (nothing to show without the server's state); Settings tries again next time.
            emailLogger.error("Email tips state couldn't be read, error: \(String(describing: error), privacy: .private)")
            state = nil
        }
    }

    /// Asks the server to send the confirmation link to `address` (in the app's language). True when it was sent.
    func optIn(address: String) async -> Bool {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        let trimmed: String = address.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        if isDemoMode {
            state = HostedEmailState(available: true, status: state?.address == nil ? .pending : .confirmed, address: state?.address, pendingAddress: trimmed)
            return true
        }
        #endif
        do {
            state = try await HostedServices.requireClient().requestEmailOptIn(address: trimmed, locale: hostedEmailLocale(preferredLocalizations: Bundle.main.preferredLocalizations))
            return true
        } catch {
            emailLogger.error("Email tips opt-in failed, error: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            return false
        }
    }

    /// Switches the emails off: the server deletes the address at once.
    func withdraw() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        #if DEBUG
        if isDemoMode {
            state = HostedEmailState(available: true, status: .off, address: nil, pendingAddress: nil)
            return
        }
        #endif
        do {
            state = try await HostedServices.requireClient().withdrawEmail()
        } catch {
            emailLogger.error("Email tips switch-off failed, error: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
        }
    }

    /// Closes the card after sign-in for good on this device (Settings › Account keeps the switch).
    func dismissPrompt() {
        isPromptDismissed = true
        UserDefaults.standard.set(true, forKey: hostedEmailPromptDismissedKey)
    }

    /// Signed out or account deleted: forget the state (the next account reads its own).
    func reset() {
        state = nil
        errorMessage = nil
    }
}

#if DEBUG
/// `--eposta kapali|bekliyor|onayli` (with `--tanitim`): the demo account's email tips state for visual checks. Without it
/// the opt-in stays hidden (nil), so the site's demo screenshots don't show the card.
func hostedEmailDemoState(arguments: [String]) -> HostedEmailState? {
    let value: String? = arguments.firstIndex(of: "--eposta").flatMap { (index: Int) -> String? in index + 1 < arguments.count ? arguments[index + 1] : nil }
    switch value {
    case "kapali":
        return HostedEmailState(available: true, status: .off, address: nil, pendingAddress: nil)
    case "bekliyor":
        return HostedEmailState(available: true, status: .pending, address: nil, pendingAddress: "mia@example.com")
    case "onayli":
        return HostedEmailState(available: true, status: .confirmed, address: "mia@example.com", pendingAddress: nil)
    default:
        return nil
    }
}
#endif
