import AINotepadCore
import Foundation
import Testing

@Suite struct HostedSessionTests {
    // Launch: a stored session is active, none is signed out; the derived values agree with the state.
    @Test func launchReadsStoredSession() {
        let active: HostedSessionState = hostedSessionTransition(state: .unknown, event: .storedSessionRead(userID: "u1"))
        #expect(active == .active(userID: "u1"))
        #expect(active.activeUserID == "u1" && active.lastUserID == "u1" && active.hasSession == true)
        let none: HostedSessionState = hostedSessionTransition(state: .unknown, event: .storedSessionRead(userID: nil))
        #expect(none == .signedOut)
        #expect(none.activeUserID == nil && none.lastUserID == nil && none.hasSession == false)
        #expect(HostedSessionState.unknown.hasSession == nil)
    }

    // Bad ordering (I3): the server ends the session while a recording runs. The signed-in user is gone (nothing may use
    // the old account's identity for server work), but the account the recording belongs to is remembered, and the
    // next account read (tokens now missing) keeps it that way instead of forgetting it.
    @Test func rejectedSessionEndsButRemembersItsAccount() {
        let ended: HostedSessionState = hostedSessionTransition(state: .active(userID: "u1"), event: .sessionRejected)
        #expect(ended == .ended(userID: "u1"))
        #expect(ended.activeUserID == nil)
        #expect(ended.lastUserID == "u1")
        #expect(ended.hasSession == false)
        #expect(hostedSessionTransition(state: ended, event: .storedSessionRead(userID: nil)) == .ended(userID: "u1"))
        #expect(hostedSessionTransition(state: .active(userID: "u1"), event: .storedSessionRead(userID: nil)) == .ended(userID: "u1"))
        // Signing in again (same or another account) makes that account active.
        #expect(hostedSessionTransition(state: ended, event: .storedSessionRead(userID: "u2")) == .active(userID: "u2"))
        #expect(hostedSessionTransition(state: ended, event: .signedIn(userID: "u1")) == .active(userID: "u1"))
    }

    // Only an explicit sign-out (or account deletion) forgets the account; a rejection when nobody is signed in stays
    // signed out.
    @Test func explicitSignOutForgetsTheAccount() {
        #expect(hostedSessionTransition(state: .active(userID: "u1"), event: .signedOut) == .signedOut)
        #expect(hostedSessionTransition(state: .ended(userID: "u1"), event: .signedOut) == .signedOut)
        #expect(hostedSessionTransition(state: .signedOut, event: .sessionRejected) == .signedOut)
        #expect(hostedSessionTransition(state: .signedOut, event: .storedSessionRead(userID: nil)) == .signedOut)
    }

    // Bad ordering (#335 leftover): turning sync or assistant access off waits for running work first; during the wait
    // the account switches, or the session ends. The request must not go out with the new (or no) session.
    @Test func accountActionStopsWhenTheAccountChangesDuringItsWait() {
        let stamp: HostedScopeStamp = HostedScopeStamp(generation: 3, accountKey: "acct-u1", userID: "u1")
        #expect(hostedAccountActionIsCurrent(stamp: stamp, generation: 3, accountKey: "acct-u1", userID: "u1", sessionUserID: "u1"))
        // Another account was signed in before the center rebound its scope: the session already belongs to u2.
        #expect(!hostedAccountActionIsCurrent(stamp: stamp, generation: 3, accountKey: "acct-u1", userID: "u1", sessionUserID: "u2"))
        // The session ended.
        #expect(!hostedAccountActionIsCurrent(stamp: stamp, generation: 3, accountKey: "acct-u1", userID: "u1", sessionUserID: nil))
        // The center rebound to the new account (generation bumped, scope changed).
        #expect(!hostedAccountActionIsCurrent(stamp: stamp, generation: 4, accountKey: "acct-u2", userID: "u2", sessionUserID: "u2"))
        // The feature restarted for the same account.
        #expect(!hostedAccountActionIsCurrent(stamp: stamp, generation: 4, accountKey: "acct-u1", userID: "u1", sessionUserID: "u1"))
    }

    // A late 401 for a token that another request already refreshed in the same session uses the current token instead
    // of rotating again.
    @Test func staleRejectionUsesTheCurrentToken() {
        let tokens: HostedTokens = HostedTokens(accessToken: "a2", refreshToken: "r2", accessExpiresAt: Date(timeIntervalSince1970: 2_000), userId: "u1")
        let session: Set<String> = ["a1", "a2"]
        #expect(hostedTokenActionAfterRejection(tokens: tokens, rejectedAccessToken: "a1", sessionAccessTokens: session) == .use(accessToken: "a2"))
        #expect(hostedTokenActionAfterRejection(tokens: tokens, rejectedAccessToken: "a2", sessionAccessTokens: session) == .refresh)
        #expect(hostedTokenActionAfterRejection(tokens: nil, rejectedAccessToken: "a1", sessionAccessTokens: session) == .signedOut)
    }

    // Bad ordering: account A's request is in flight, the user signs in as B, then A's token gets 401. The request must
    // not be repeated with B's token (A's data would be written to B's account).
    @Test func rejectionFromAnEarlierSessionIsNotRepeated() {
        let accountB: HostedTokens = HostedTokens(accessToken: "b1", refreshToken: "rb1", accessExpiresAt: Date(timeIntervalSince1970: 2_000), userId: "uB")
        #expect(hostedTokenActionAfterRejection(tokens: accountB, rejectedAccessToken: "a1", sessionAccessTokens: ["b1"]) == .sessionChanged)
        // Signed in again as the same account: still a new session, the old request is not repeated either.
        #expect(hostedTokenActionAfterRejection(tokens: accountB, rejectedAccessToken: "a1", sessionAccessTokens: []) == .sessionChanged)
    }
}
