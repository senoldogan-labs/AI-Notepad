import Foundation
import Testing
@testable import AINotepadCore

struct HostedAIConsentTests {
    private let then: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ status: HostedAIConsentStatus, version: Int, synced: Bool) -> HostedAIConsentRecord {
        HostedAIConsentRecord(status: status, version: version, decidedAt: then, syncedToServer: synced)
    }

    @Test func onlyAgreeingToTheCurrentDisclosureAllowsAI() {
        #expect(hostedAIConsentAllows(record: record(.granted, version: hostedAIConsentVersion, synced: false)))
        #expect(!hostedAIConsentAllows(record: nil))
        #expect(!hostedAIConsentAllows(record: record(.granted, version: hostedAIConsentVersion - 1, synced: true)))
        #expect(!hostedAIConsentAllows(record: record(.declined, version: hostedAIConsentVersion, synced: false)))
        #expect(!hostedAIConsentAllows(record: record(.withdrawn, version: hostedAIConsentVersion, synced: true)))
    }

    @Test func promptsWhenUnansweredOrAgreedToAnOlderDisclosureOnly() {
        #expect(hostedAIConsentNeedsPrompt(record: nil))
        #expect(hostedAIConsentNeedsPrompt(record: record(.granted, version: hostedAIConsentVersion - 1, synced: true)))
        #expect(!hostedAIConsentNeedsPrompt(record: record(.granted, version: hostedAIConsentVersion, synced: true)))
        // "Not now" and a withdrawal are respected: the disclosure comes back only when the user reaches for AI.
        #expect(!hostedAIConsentNeedsPrompt(record: record(.declined, version: hostedAIConsentVersion, synced: false)))
        #expect(!hostedAIConsentNeedsPrompt(record: record(.withdrawn, version: hostedAIConsentVersion, synced: true)))
    }

    @Test func syncSendsUnsentAnswersAndFollowsAWithdrawalElsewhere() {
        let agreed: HostedAIConsentServerState = HostedAIConsentServerState(version: hostedAIConsentVersion, decidedAt: then)
        let withdrawn: HostedAIConsentServerState = HostedAIConsentServerState(version: nil, decidedAt: then.addingTimeInterval(60))
        let staleWithdrawal: HostedAIConsentServerState = HostedAIConsentServerState(version: nil, decidedAt: then.addingTimeInterval(-60))
        let never: HostedAIConsentServerState = HostedAIConsentServerState(version: nil, decidedAt: nil)
        let current: Int = hostedAIConsentVersion
        #expect(hostedAIConsentSync(local: nil, server: agreed) == .none)
        #expect(hostedAIConsentSync(local: record(.granted, version: current, synced: false), server: never) == .upload(granted: true))
        #expect(hostedAIConsentSync(local: record(.withdrawn, version: current, synced: false), server: agreed) == .upload(granted: false))
        // A declined answer never withdraws an agreement given on another device.
        #expect(hostedAIConsentSync(local: record(.declined, version: current, synced: false), server: agreed) == .none)
        #expect(hostedAIConsentSync(local: record(.granted, version: current, synced: true), server: agreed) == .none)
        #expect(hostedAIConsentSync(local: record(.granted, version: current, synced: true), server: withdrawn) == .adoptWithdrawal)
        // A read that crossed a new agreement still shows the earlier withdrawal: ignored.
        #expect(hostedAIConsentSync(local: record(.granted, version: current, synced: true), server: staleWithdrawal) == .none)
        #expect(hostedAIConsentSync(local: record(.granted, version: current, synced: true), server: never) == .upload(granted: true))
        // An older server without the field gets only unsent answers.
        #expect(hostedAIConsentSync(local: record(.granted, version: current, synced: true), server: nil) == .none)
        #expect(hostedAIConsentSync(local: record(.granted, version: current, synced: false), server: nil) == .upload(granted: true))
    }
}
