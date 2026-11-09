import Foundation

/// The sign-in session on this device, as the app sees it. One value replaces the parallel "is there a stored session"
/// flag and "who is signed in" cache, so the two can never disagree.
public enum HostedSessionState: Sendable, Equatable {
    /// The stored session hasn't been read yet, or reading it failed (the sign-in gate stays closed).
    case unknown
    /// No session: never signed in, signed out, or the account was deleted.
    case signedOut
    /// Signed in as `userID`; requests carry its tokens.
    case active(userID: String)
    /// The server ended `userID`'s session (refresh rejected) without the user signing out. Requests fail until the user
    /// signs in again, but the device still holds that account's data and may still be recording into it: per-account
    /// settings shown while the recording finishes (the AI consent) still belong to `userID`.
    case ended(userID: String)

    /// The account whose tokens requests use; nil unless the session is active. Anything that talks to the server or
    /// decides which account's data is current (offline permit, sync and assistant scope, account switch, purchases)
    /// reads this.
    public var activeUserID: String? {
        switch self {
        case .active(let userID): userID
        case .unknown, .signedOut, .ended: nil
        }
    }

    /// The account the device was last signed in as during this run (active or ended); nil when signed out or unknown.
    public var lastUserID: String? {
        switch self {
        case .active(let userID), .ended(let userID): userID
        case .unknown, .signedOut: nil
        }
    }

    /// Whether a usable session exists: nil while unknown, false when signed out or ended.
    public var hasSession: Bool? {
        switch self {
        case .unknown: nil
        case .active: true
        case .signedOut, .ended: false
        }
    }
}

/// What happened to the session.
public enum HostedSessionEvent: Sendable, Equatable {
    /// The stored tokens were read (at launch and on every account read): their user, or nil when none are stored.
    case storedSessionRead(userID: String?)
    /// A sign-in finished and stored `userID`'s tokens.
    case signedIn(userID: String)
    /// The server rejected the session (refresh revoked, 401 on the account read).
    case sessionRejected
    /// The user signed out, or the account was deleted.
    case signedOut
}

/// The session after `event`. Only an explicit sign-out (or deletion) leads to `signedOut` from a known account; a
/// session that disappears on its own (rejected, or its tokens gone on the next read) becomes `ended` for the same user,
/// so a recording that outlives it keeps its account's settings. Pure function.
public func hostedSessionTransition(state: HostedSessionState, event: HostedSessionEvent) -> HostedSessionState {
    switch event {
    case .storedSessionRead(.some(let userID)), .signedIn(let userID):
        return .active(userID: userID)
    case .storedSessionRead(.none), .sessionRejected:
        switch state {
        case .active(let userID), .ended(let userID):
            return .ended(userID: userID)
        case .unknown, .signedOut:
            return .signedOut
        }
    case .signedOut:
        return .signedOut
    }
}

/// Whether an account action (turning sync or assistant access off, removing this device from the assistant copy) that
/// waited for running work to stop may still send its server request or apply its result: the feature's run (`stamp`)
/// must still be current and the signed-in user must still be the stamp's user. The server request goes out with
/// whatever session is active, so after an account switch or a session end it would act on the wrong account (or
/// fail). Pure function.
public func hostedAccountActionIsCurrent(stamp: HostedScopeStamp, generation: Int, accountKey: String?, userID: String?, sessionUserID: String?) -> Bool {
    hostedStampIsCurrent(stamp: stamp, generation: generation, accountKey: accountKey, userID: userID) && sessionUserID == stamp.userID
}
