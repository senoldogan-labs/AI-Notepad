import AINotepadCore
import Foundation
import Testing

@Suite struct HostedCheckoutStateTests {
    private let all: [HostedCheckoutState] = [.idle, .opening, .awaitingReturn, .failed(message: "x")]

    // The happy path: Subscribe → page requested → page open (Subscribe locked) → back in the app → a new checkout can
    // start.
    @Test func checkoutOpensAndReturns() {
        let opening: HostedCheckoutState? = hostedCheckoutTransition(state: .idle, event: .begin)
        #expect(opening == .opening)
        #expect(hostedCheckoutTransition(state: .opening, event: .opened) == .awaitingReturn)
        #expect(hostedCheckoutLocked(state: .opening) && hostedCheckoutLocked(state: .awaitingReturn))
        #expect(hostedCheckoutTransition(state: .awaitingReturn, event: .returned) == .idle)
        #expect(!hostedCheckoutLocked(state: .idle))
    }

    // F-1: once the page opened, only the return ends the wait. A later failure (the account refresh right after the
    // page opened) is not an event of this machine, and `openFailed` after the page opened is ignored instead of
    // turning the offer into an error that invites a second checkout.
    @Test func openPageIsNotFailedByLaterErrors() {
        #expect(hostedCheckoutTransition(state: .awaitingReturn, event: .openFailed(message: "network")) == nil)
        #expect(hostedCheckoutTransition(state: .awaitingReturn, event: .dismissed) == nil)
    }

    // F-3: a second Subscribe while the first is opening or its page is open is dropped.
    @Test func secondSubscribeIsDropped() {
        #expect(hostedCheckoutTransition(state: .opening, event: .begin) == nil)
        #expect(hostedCheckoutTransition(state: .awaitingReturn, event: .begin) == nil)
    }

    // The page could not be opened: the offer shows why and Subscribe can try again; closing the offer clears it.
    @Test func failedOpenCanRetryOrDismiss() {
        let failed: HostedCheckoutState? = hostedCheckoutTransition(state: .opening, event: .openFailed(message: "Stripe down"))
        #expect(failed == .failed(message: "Stripe down"))
        #expect(!hostedCheckoutLocked(state: .failed(message: "Stripe down")))
        #expect(hostedCheckoutTransition(state: .failed(message: "Stripe down"), event: .begin) == .opening)
        #expect(hostedCheckoutTransition(state: .failed(message: "Stripe down"), event: .dismissed) == .idle)
    }

    // A rejected invite code or an account that needs no payment ends the attempt without an error.
    @Test func abandonedOpeningGoesIdle() {
        #expect(hostedCheckoutTransition(state: .opening, event: .abandoned) == .idle)
    }

    // Every pair outside the table is ignored (nil), so no event can jump the flow into a state it cannot reach.
    @Test func otherEventsAreIgnored() {
        let valid: Set<String> = [
            "idle/begin", "failed/begin", "opening/abandoned", "opening/opened", "opening/openFailed", "awaitingReturn/returned",
            "failed/dismissed",
        ]
        let events: [HostedCheckoutEvent] = [.begin, .abandoned, .opened, .openFailed(message: "m"), .returned, .dismissed]
        for state in all {
            for event in events {
                let key: String = "\(name(state: state))/\(name(event: event))"
                #expect((hostedCheckoutTransition(state: state, event: event) != nil) == valid.contains(key), "\(key)")
            }
        }
    }

    private func name(state: HostedCheckoutState) -> String {
        switch state {
        case .idle: "idle"
        case .opening: "opening"
        case .awaitingReturn: "awaitingReturn"
        case .failed: "failed"
        }
    }

    private func name(event: HostedCheckoutEvent) -> String {
        switch event {
        case .begin: "begin"
        case .abandoned: "abandoned"
        case .opened: "opened"
        case .openFailed: "openFailed"
        case .returned: "returned"
        case .dismissed: "dismissed"
        }
    }
}
