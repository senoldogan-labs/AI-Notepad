import Foundation
import Testing
@testable import KeyboardCore

/// The keyboard without an account: what stays free, what asks to sign in.
@Suite struct KeyboardAccountTests {
    // Ask needs Full Access first (no shared folder, no config), then an account; configs from older apps count as signed in.
    @Test func askNeedsFullAccessThenAnAccount() {
        #expect(keyboardAskGate(hasFullAccess: false, accountSignedIn: false) == .needsFullAccess)
        #expect(keyboardAskGate(hasFullAccess: true, accountSignedIn: false) == .needsAccount)
        #expect(keyboardAskGate(hasFullAccess: true, accountSignedIn: true) == .available)
        #expect(keyboardAskGate(hasFullAccess: true, accountSignedIn: nil) == .available)
    }

    // While the app has not read the account, the flag keeps its last value instead of flipping to signed out.
    @Test func unknownStatusKeepsThePreviousFlag() {
        #expect(keyboardAccountFlag(signedIn: true, statusKnown: true, previous: false) == true)
        #expect(keyboardAccountFlag(signedIn: false, statusKnown: true, previous: true) == false)
        #expect(keyboardAccountFlag(signedIn: false, statusKnown: false, previous: true) == true)
        #expect(keyboardAccountFlag(signedIn: false, statusKnown: false, previous: nil) == nil)
    }

    // Voice typing in place is never gated by the account: the dictation route and readiness take no account input.
    @Test func dictationDoesNotDependOnTheAccount() {
        #expect(keyboardDictationRoute(sessionIsLive: false, sessionMayBeAlive: false, inPlaceIsReady: true) == .inPlace)
        #expect(keyboardInPlaceIsReady(hasFullAccess: true, microphoneAllowed: true, installedLocale: "tr_TR", headroomBytes: 0))
    }

    @Test func signInLinkRoutes() {
        #expect(keyboardLinkRoute(url: keyboardSignInURL) == .signIn)
        #expect(keyboardLinkRoute(url: URL(string: "gistsmith://keyboard/sign-in/extra")!) == nil)
    }

    @Test func microphoneSetupActions() {
        #expect(keyboardMicrophoneSetupAction(permission: .notAsked) == .request)
        #expect(keyboardMicrophoneSetupAction(permission: .denied) == .openSettings)
        #expect(keyboardMicrophoneSetupAction(permission: .granted) == .none)
    }
}
