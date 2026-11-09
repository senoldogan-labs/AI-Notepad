// Web'deki durum makinelerinin geçiş kuralları (saf fonksiyonlar): oturum kuşağı ve yenileme (src/lib/session-state.ts),
// paylaşım sayfasının istek sırası (src/lib/share-view.ts), hesap sayfasında tek ödeme eylemi (src/lib/checkout-state.ts).
import { strict as assert } from "node:assert";
import { describe, test } from "node:test";
import { type CheckoutState, checkoutControlsLocked, checkoutTransition, idleCheckout } from "../src/lib/checkout-state.ts";
import {
  type SessionState,
  type StoredSession,
  freshTokenAction,
  initialSessionState,
  isSignedIn,
  persistedTokens,
  refreshMarginMs,
  sessionTransition,
  unauthorizedTokenAction,
} from "../src/lib/session-state.ts";
import {
  type ShareFailureKind,
  type ShareView,
  initialShareView,
  shareDocumentTitle,
  shareFailureRetries,
  shareSections,
  shareViewOpening,
  shareViewSettled,
} from "../src/lib/share-view.ts";

const nowMs: number = 1_800_000_000_000;
const first: StoredSession = { accessToken: "a1", refreshToken: "r1", accessExpiresAt: nowMs + 600_000 };
const second: StoredSession = { accessToken: "a2", refreshToken: "r2", accessExpiresAt: nowMs + 600_000 };

/** Geçişin geçerli olmasını bekler. */
function step(state: SessionState, event: Parameters<typeof sessionTransition>[1]): SessionState {
  const next: SessionState | null = sessionTransition(state, event);
  assert.notEqual(next, null, `${event.type} ${state.kind} durumunda reddedildi`);
  return next as SessionState;
}

describe("session state", () => {
  test("saved tokens open signed in, none open signed out", () => {
    assert.deepEqual(initialSessionState(first), { kind: "signedIn", generation: 0, tokens: first });
    assert.deepEqual(initialSessionState(null), { kind: "signedOut", generation: 0 });
  });

  test("a refresh that answers after sign-out is dropped and does not resurrect the session", () => {
    const refreshing: SessionState = step(initialSessionState(first), { type: "refreshStarted", generation: 0 });
    const signingOut: SessionState = step(refreshing, { type: "signOutStarted" });
    assert.equal(persistedTokens(signingOut), null);
    assert.equal(sessionTransition(signingOut, { type: "refreshSucceeded", generation: 0, tokens: second }), null);
    assert.equal(sessionTransition(signingOut, { type: "refreshFailed", generation: 0 }), null);
    assert.deepEqual(step(signingOut, { type: "signOutFinished", generation: 1 }), { kind: "signedOut", generation: 1 });
  });

  test("a refresh from before a new sign-in cannot overwrite the new session", () => {
    const refreshing: SessionState = step(initialSessionState(first), { type: "refreshStarted", generation: 0 });
    const signedIn: SessionState = step(refreshing, { type: "signedIn", tokens: second });
    assert.equal(signedIn.generation, 1);
    assert.equal(sessionTransition(signedIn, { type: "refreshSucceeded", generation: 0, tokens: first }), null);
    assert.equal(sessionTransition(signedIn, { type: "refreshRejected", generation: 0 }), null);
  });

  test("a sign-out finishing after a new sign-in does not sign the new session out", () => {
    const signingOut: SessionState = step(initialSessionState(first), { type: "signOutStarted" });
    const signedIn: SessionState = step(signingOut, { type: "signedIn", tokens: second });
    assert.equal(sessionTransition(signedIn, { type: "signOutFinished", generation: signingOut.generation }), null);
  });

  test("refresh keeps the generation; rejection ends the session; failure keeps the old tokens", () => {
    const refreshing: SessionState = step(initialSessionState(first), { type: "refreshStarted", generation: 0 });
    assert.deepEqual(step(refreshing, { type: "refreshSucceeded", generation: 0, tokens: second }), { kind: "signedIn", generation: 0, tokens: second });
    assert.deepEqual(step(refreshing, { type: "refreshFailed", generation: 0 }), { kind: "signedIn", generation: 0, tokens: first });
    const rejected: SessionState = step(refreshing, { type: "refreshRejected", generation: 0 });
    assert.equal(isSignedIn(rejected), false);
    assert.equal(rejected.generation, 1);
  });

  test("refresh is single-flight: a second start while refreshing is refused", () => {
    const refreshing: SessionState = step(initialSessionState(first), { type: "refreshStarted", generation: 0 });
    assert.equal(sessionTransition(refreshing, { type: "refreshStarted", generation: 0 }), null);
    assert.deepEqual(freshTokenAction(refreshing, nowMs), { kind: "refresh", generation: 0 });
  });

  test("sign-out without a session is refused; clearing always starts a new generation", () => {
    assert.equal(sessionTransition(initialSessionState(null), { type: "signOutStarted" }), null);
    assert.deepEqual(step(initialSessionState(first), { type: "cleared" }), { kind: "signedOut", generation: 1 });
  });

  test("tokens near expiry are refreshed before use", () => {
    const state: SessionState = initialSessionState(first);
    assert.deepEqual(freshTokenAction(state, nowMs), { kind: "use", tokens: first });
    assert.deepEqual(freshTokenAction(state, first.accessExpiresAt - refreshMarginMs), { kind: "refresh", generation: 0 });
    assert.deepEqual(freshTokenAction(initialSessionState(null), nowMs), { kind: "signedOut" });
  });

  test("a 401 for an access token that was already refreshed retries with the current token instead of refreshing again", () => {
    const refreshed: SessionState = step(step(initialSessionState(first), { type: "refreshStarted", generation: 0 }), {
      type: "refreshSucceeded",
      generation: 0,
      tokens: second,
    });
    assert.deepEqual(unauthorizedTokenAction(refreshed, "a1"), { kind: "use", tokens: second });
    assert.deepEqual(unauthorizedTokenAction(refreshed, "a2"), { kind: "refresh", generation: 0 });
    const signingOut: SessionState = step(refreshed, { type: "signOutStarted" });
    assert.deepEqual(unauthorizedTokenAction(signingOut, "a2"), { kind: "signedOut" });
  });
});

describe("share view", () => {
  type View = ShareView<string, string>;

  test("an older open that answers last is dropped", () => {
    const openedA: View = shareViewOpening(initialShareView());
    const openedB: View = shareViewOpening(openedA);
    assert.equal(shareViewSettled(openedB, { kind: "note", request: openedA.request, note: "A" }), null);
    assert.deepEqual(shareViewSettled(openedB, { kind: "note", request: openedB.request, note: "B" }), { kind: "note", request: openedB.request, note: "B" });
  });

  test("a settled open is not settled twice", () => {
    const opened: View = shareViewOpening(initialShareView());
    const shown: View | null = shareViewSettled(opened, { kind: "error", request: opened.request, failure: "gone" });
    assert.notEqual(shown, null);
    assert.equal(shareViewSettled(shown as View, { kind: "note", request: opened.request, note: "A" }), null);
  });

  test("exactly one section is visible", () => {
    assert.deepEqual(shareSections<string, string>({ kind: "loading", request: 1 }), { loading: true, note: false, error: false });
    assert.deepEqual(shareSections<string, string>({ kind: "note", request: 1, note: "A" }), { loading: false, note: true, error: false });
    assert.deepEqual(shareSections<string, string>({ kind: "error", request: 1, failure: "gone" }), { loading: false, note: false, error: true });
  });

  test("an unexpected failure is a final error state with a retry, like the network", () => {
    const opened: ShareView<string, ShareFailureKind> = shareViewOpening(initialShareView());
    const shown = shareViewSettled<string, ShareFailureKind>(opened, { kind: "error", request: opened.request, failure: "unexpected" });
    assert.deepEqual(shown, { kind: "error", request: opened.request, failure: "unexpected" });
    assert.deepEqual(shareSections(shown ?? opened), { loading: false, note: false, error: true });
    const kinds: readonly ShareFailureKind[] = ["incomplete", "gone", "wrongKey", "unreadable", "rateLimited", "network", "unexpected"];
    assert.deepEqual(kinds.map(shareFailureRetries), [false, false, false, false, true, true, true]);
  });

  test("the document title is rebuilt from the page title, not stacked", () => {
    assert.equal(shareDocumentTitle("Weekly sync", "Shared note"), "Weekly sync — Shared note");
    assert.equal(shareDocumentTitle(null, "Shared note"), "Shared note");
  });
});

describe("checkout state", () => {
  test("a second checkout cannot start while one is opening or redirecting", () => {
    const opening: CheckoutState | null = checkoutTransition(idleCheckout, { type: "openBilling" });
    assert.deepEqual(opening, { kind: "openingBilling" });
    assert.equal(checkoutTransition(opening as CheckoutState, { type: "openBilling" }), null);
    const redirecting: CheckoutState | null = checkoutTransition(opening as CheckoutState, { type: "redirect" });
    assert.deepEqual(redirecting, { kind: "redirecting" });
    assert.equal(checkoutTransition(redirecting as CheckoutState, { type: "openBilling" }), null);
    assert.equal(checkoutTransition(redirecting as CheckoutState, { type: "settled" }), null);
    assert.equal(checkoutControlsLocked(redirecting as CheckoutState), true);
  });

  test("checkout cannot start while an invite code is being validated", () => {
    const validating: CheckoutState | null = checkoutTransition(idleCheckout, { type: "validateInvite" });
    assert.deepEqual(validating, { kind: "validatingInvite" });
    assert.equal(checkoutTransition(validating as CheckoutState, { type: "openBilling" }), null);
    assert.equal(checkoutTransition(validating as CheckoutState, { type: "redirect" }), null);
    assert.deepEqual(checkoutTransition(validating as CheckoutState, { type: "settled" }), idleCheckout);
  });

  test("a withdrawal and a billing action never run together", () => {
    const withdrawing: CheckoutState | null = checkoutTransition(idleCheckout, { type: "withdraw" });
    assert.deepEqual(withdrawing, { kind: "withdrawing" });
    assert.equal(checkoutControlsLocked(withdrawing as CheckoutState), true);
    assert.equal(checkoutTransition(withdrawing as CheckoutState, { type: "openBilling" }), null);
    assert.equal(checkoutTransition(withdrawing as CheckoutState, { type: "validateInvite" }), null);
    assert.equal(checkoutTransition(withdrawing as CheckoutState, { type: "withdraw" }), null);
    assert.equal(checkoutTransition(withdrawing as CheckoutState, { type: "redirect" }), null);
    assert.deepEqual(checkoutTransition(withdrawing as CheckoutState, { type: "settled" }), idleCheckout);
    assert.equal(checkoutTransition({ kind: "openingBilling" }, { type: "withdraw" }), null);
    assert.equal(checkoutTransition({ kind: "redirecting" }, { type: "withdraw" }), null);
  });

  test("a failed checkout unlocks; a page restored from the back-forward cache unlocks", () => {
    assert.deepEqual(checkoutTransition({ kind: "openingBilling" }, { type: "settled" }), idleCheckout);
    assert.deepEqual(checkoutTransition({ kind: "redirecting" }, { type: "pageRestored" }), idleCheckout);
    assert.equal(checkoutControlsLocked(idleCheckout), false);
    assert.equal(checkoutTransition(idleCheckout, { type: "settled" }), null);
  });
});
