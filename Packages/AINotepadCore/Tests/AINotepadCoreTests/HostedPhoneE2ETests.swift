import Foundation
import Testing
@testable import AINotepadCore

// Local server (`wrangler dev`) only, like the rest of `HostedE2ETests` (enable with `AINOTEPAD_HOSTED_E2E=1` and
// `AINOTEPAD_HOSTED_BASE`). The development `vars` keep the dialer off (`PHONE_CALLS_POLICY`), so no Twilio call is
// possible; the switched-on flow is covered by `server/test/phone.test.ts` against a fake Twilio.
#if os(macOS)

extension HostedE2ETests {
    // The app reads the dialer's status from the real server (wire format), the dialer stays hidden while the switch is
    // off, and every other phone endpoint refuses with `phone_unavailable`.
    @Test func phoneDialerIsOffAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let refresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: refresh)
        let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(accessToken: "gecersiz", refreshToken: refresh, accessExpiresAt: Date.distantPast, userId: userID))
        let session: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
        // The app agrees to the AI disclosure before any AI request (see `HostedAIConsent.swift`).
        session.setAIConsent(granted: true)
        _ = try await awaitingAuthLimit { try await session.validAccessToken() }
        let phone: HostedPhoneClient = HostedPhoneClient(baseURL: baseURL, credentials: session)

        let status: HostedPhoneStatus = try await phone.status()
        #expect(status.available == false)
        #expect(status.reason == .policyOff)
        #expect(status.consentVersion == phoneDialerConsentVersion)
        #expect(status.number == nil)
        await #expect(throws: HostedAPIError.self) { try await phone.reserveCall(to: "+12125550199") }
        do {
            try await phone.acceptConsent(version: phoneDialerConsentVersion)
            Issue.record("consent accepted while the dialer is off")
        } catch let error as HostedAPIError {
            #expect(error.code == .phoneUnavailable)
        }
    }
}
#endif
