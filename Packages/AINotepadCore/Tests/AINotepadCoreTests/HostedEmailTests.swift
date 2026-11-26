import Foundation
import Testing
@testable import AINotepadCore

@Suite("Opt-in tips emails")
struct HostedEmailTests {
    @Test func addressCheckAcceptsPlainAddressesOnly() {
        #expect(hostedEmailAddressLooksValid("mia@example.com"))
        #expect(hostedEmailAddressLooksValid("  Mia.Doe+tips@Example.co.uk "))
        for bad in ["", "mia", "mia@", "@example.com", "mia@example", "mia@example.c", "mia @example.com", "a@b@c.com", "mia@example..com"] {
            #expect(!hostedEmailAddressLooksValid(bad), "\(bad)")
        }
    }

    @Test func promptShowsOnlyWhileOfferedAndOff() {
        let off: HostedEmailState = HostedEmailState(available: true, status: .off, address: nil, pendingAddress: nil)
        #expect(hostedEmailPromptVisible(state: off, dismissed: false, onTrial: true))
        #expect(!hostedEmailPromptVisible(state: off, dismissed: false, onTrial: false))
        #expect(!hostedEmailPromptVisible(state: off, dismissed: true, onTrial: true))
        #expect(!hostedEmailPromptVisible(state: nil, dismissed: false, onTrial: true))
        #expect(!hostedEmailPromptVisible(state: HostedEmailState(available: false, status: .off, address: nil, pendingAddress: nil), dismissed: false, onTrial: true))
        #expect(!hostedEmailPromptVisible(state: HostedEmailState(available: true, status: .pending, address: nil, pendingAddress: "a@b.co"), dismissed: false, onTrial: true))
    }

    @Test func localeIsTheAppLanguage() {
        #expect(hostedEmailLocale(preferredLocalizations: ["pt-BR", "en"]) == "pt-BR")
        #expect(hostedEmailLocale(preferredLocalizations: []) == "en")
    }

    @Test func decodesTheServerState() throws {
        let json: Data = Data(#"{"available":true,"status":"confirmed","address":"mia@example.com","pendingAddress":null,"locale":"en","consentVersion":1}"#.utf8)
        let state: HostedEmailState = try JSONDecoder().decode(HostedEmailState.self, from: json)
        #expect(state == HostedEmailState(available: true, status: .confirmed, address: "mia@example.com", pendingAddress: nil))
    }

    @Test func optInIsRetriedOnlyWhenTheRequestNeverLeft() {
        #expect(isRetryableEmailOptIn(failure: .network(.cannotConnectToHost)))
        #expect(!isRetryableEmailOptIn(failure: .network(.timedOut)))
        #expect(!isRetryableEmailOptIn(failure: .server(HostedAPIError(code: .rateLimited, rawCode: "rate_limited", status: 429, serverMessage: "", path: "/v1/me/email"))))
    }
}
