import Foundation

/// The Mac's "Subscribe" flow (Stripe Checkout in the browser), the counterpart of the website's `CheckoutState`. One
/// value replaces reading the result from the account's shared error message: a failed account refresh after the
/// payment page opened is not a failed checkout, and the offer cannot start a second checkout while one is open.
public enum HostedCheckoutState: Sendable, Equatable {
    /// Nothing in progress: "Subscribe" can start a checkout.
    case idle
    /// "Subscribe" was pressed: a typed invite code is being checked, then the payment page is requested.
    case opening
    /// The payment page (or the Customer Portal for an unfinished subscription) opened in the browser; the app waits for
    /// the subscription to show up or for the user to come back.
    case awaitingReturn
    /// The payment page could not be opened; the offer stays open and shows `message`. "Subscribe" can try again.
    case failed(message: String)
}

/// What happened in the checkout flow.
public enum HostedCheckoutEvent: Sendable, Equatable {
    /// "Subscribe" was pressed.
    case begin
    /// The checkout ended before a page opened without an error to show: the typed invite code was rejected (its reason
    /// shows at the code field) or the account needs no payment (complimentary access).
    case abandoned
    /// The payment page or the Customer Portal opened in the browser.
    case opened
    /// The payment page could not be opened.
    case openFailed(message: String)
    /// The wait ended: the subscription appeared, the user came back to the app, or the watch gave up.
    case returned
    /// The offer was closed.
    case dismissed
}

/// The checkout state after `event`, or nil when `event` does not apply in `state` (the action must not run: a second
/// "Subscribe" while a checkout is opening or open is dropped). Pure function.
public func hostedCheckoutTransition(state: HostedCheckoutState, event: HostedCheckoutEvent) -> HostedCheckoutState? {
    switch (state, event) {
    case (.idle, .begin), (.failed, .begin):
        .opening
    case (.opening, .abandoned):
        .idle
    case (.opening, .opened):
        .awaitingReturn
    case (.opening, .openFailed(let message)):
        .failed(message: message)
    case (.awaitingReturn, .returned):
        .idle
    case (.failed, .dismissed):
        .idle
    case (.idle, _), (.opening, _), (.awaitingReturn, _), (.failed, _):
        nil
    }
}

/// Whether "Subscribe" is locked: a checkout is opening or its page is open. Pure function.
public func hostedCheckoutLocked(state: HostedCheckoutState) -> Bool {
    switch state {
    case .opening, .awaitingReturn: true
    case .idle, .failed: false
    }
}
