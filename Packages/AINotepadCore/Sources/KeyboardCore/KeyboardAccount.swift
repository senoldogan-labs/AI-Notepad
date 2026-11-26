import Foundation

/// What the keyboard may do for this iPhone's account. Typing and on-device voice typing cost Gistsmith nothing and need
/// no account (nor a live subscription: a trial that ended or a lapsed plan changes nothing here); only the features
/// that call Gistsmith's server do.
public enum KeyboardAskGate: Sendable, Hashable {
    /// Ask runs (the routes of `keyboardAskRoute`).
    case available
    /// The keyboard has no Full Access: it cannot read the shared folder, so it cannot ask.
    case needsFullAccess
    /// No account is signed in on this iPhone: Ask says so and opens Gistsmith's sign-in. No question is sent anywhere.
    case needsAccount
}

/// Whether "Ask Gistsmith" may start. `accountSignedIn` is the config's value: nil (an app from before the field) means
/// signed in. Pure function.
public func keyboardAskGate(hasFullAccess: Bool, accountSignedIn: Bool?) -> KeyboardAskGate {
    guard hasFullAccess else {
        return .needsFullAccess
    }
    return accountSignedIn ?? true ? .available : .needsAccount
}

/// Whether the keyboard offers "add from Gistsmith" (meeting notes): only for a signed-in account that turned the list
/// on; the list itself is withheld from the shared folder otherwise. Pure function.
public func keyboardOffersMeetingNotes(accountSignedIn: Bool?, meetingNotesEnabled: Bool) -> Bool {
    (accountSignedIn ?? true) && meetingNotesEnabled
}

/// The account flag the app writes to the keyboard's config. While the app has not read the account yet (it starts with
/// the status unknown) the flag stays what it was: a signed-in account is never shown as signed out for a moment.
/// Pure function.
public func keyboardAccountFlag(signedIn: Bool, statusKnown: Bool, previous: Bool?) -> Bool? {
    if signedIn {
        return true
    }
    return statusKnown ? false : previous
}

/// Gistsmith's microphone permission as the setup sees it.
public enum KeyboardMicrophonePermission: Sendable, Hashable {
    case notAsked
    case denied
    case granted
}

/// What the setup's voice page does about the microphone permission the keyboard's in-place dictation runs under.
public enum KeyboardMicrophoneSetupAction: Sendable, Hashable {
    /// iOS asks now ("Allow microphone").
    case request
    /// It was refused: only iOS Settings can change it.
    case openSettings
    /// Allowed; nothing to do.
    case none
}

/// The microphone step of the setup. Pure function.
public func keyboardMicrophoneSetupAction(permission: KeyboardMicrophonePermission) -> KeyboardMicrophoneSetupAction {
    switch permission {
    case .notAsked: .request
    case .denied: .openSettings
    case .granted: .none
    }
}
