import AINotepadCore
import Foundation
import KeyboardCore
import os

private let askTokenLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.hosted", category: "KeyboardAskToken")

/// Keeps Gistsmith Keyboard's Ask token (`KeyboardAskToken`) in the App Group keychain item the keyboard reads: minted
/// with this app's session when the keyboard has Full Access, the account is signed in and has agreed to the AI
/// disclosure; renewed when it is a day old (`keyboardAskTokenNeedsRenewal`); deleted on sign-out, account deletion or
/// switch, a withdrawn consent and Full Access off. The account's own session never leaves this app.
@MainActor
final class PhoneKeyboardAskTokens {
    static let shared: PhoneKeyboardAskTokens = PhoneKeyboardAskTokens()

    private let keychain: KeyboardAskTokenKeychain = KeyboardAskTokenKeychain(accessGroup: keyboardAppGroupIdentifier)
    private var renewal: Task<Void, Never>?

    private init() {}

    /// Mints, renews or deletes the token for the current facts (called with every keyboard sync and when the app comes
    /// to the front).
    func refresh(isSignedIn: Bool, hasFullAccess: Bool) {
        guard isSignedIn, hasFullAccess, let client = consentedClient() else {
            delete()
            return
        }
        let current: KeyboardAskToken?
        do {
            current = try keychain.read()
        } catch {
            askTokenLogger.error("Keyboard Ask token unreadable, error: \(String(describing: error), privacy: .public)")
            current = nil
        }
        guard renewal == nil, keyboardAskTokenNeedsRenewal(token: current, now: Date()) else {
            return
        }
        renewal = Task { [weak self] in
            await self?.mint(client: client)
            // A cancelled renewal was already replaced (or dropped) by `delete`.
            if !Task.isCancelled {
                self?.renewal = nil
            }
        }
    }

    /// Deletes the token: the keyboard then opens Gistsmith to ask.
    func delete() {
        renewal?.cancel()
        renewal = nil
        do {
            try keychain.delete()
        } catch {
            askTokenLogger.error("Keyboard Ask token removal failed, error: \(String(describing: error), privacy: .public)")
        }
    }

    /// The server connection when the account has the current AI consent on this device; nil (and logged) otherwise.
    private func consentedClient() -> HostedClient? {
        do {
            let client: HostedClient = try HostedServices.requireClient()
            try client.requireAIConsent()
            return client
        } catch {
            askTokenLogger.info("Keyboard Ask token not kept, reason: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func mint(client: HostedClient) async {
        do {
            let minted: HostedKeyboardToken = try await client.keyboardAskToken()
            guard !Task.isCancelled else {
                return
            }
            try keychain.save(KeyboardAskToken(token: minted.token, expiresAt: minted.expiresAt, serverContext: minted.serverContext, baseURL: client.baseURL))
        } catch {
            // The keyboard keeps opening Gistsmith to ask until the next refresh succeeds.
            askTokenLogger.warning("Keyboard Ask token not minted, error: \(String(describing: error), privacy: .public)")
        }
    }
}
