// Contact form submission and its single-use Turnstile token (src/client/contact.ts). A token is consumed by exactly one
// submission; while that submission runs no token enables another one (a widget drawn again meanwhile, e.g. on a theme
// change, still issues tokens); when it finishes the widget is reset and every token issued before the reset is dropped,
// so the next submission waits for a fresh one. Pure; no DOM (scripts/contact-state.test.ts).

/** The usable token, if any, and whether a submission is running. */
export interface ContactState {
  readonly token: string | null;
  readonly submitting: boolean;
}

export type ContactEvent =
  /** The widget issued a token. */
  | { readonly kind: "tokenIssued"; readonly token: string }
  /** The token can no longer be used: it expired, the widget failed or was drawn again. */
  | { readonly kind: "tokenLost" }
  /** The visitor submitted a valid form. */
  | { readonly kind: "submitRequested" }
  /** The submission finished, sent or failed. */
  | { readonly kind: "submitFinished" };

export type ContactEffect =
  /** Send the message with this token. */
  | { readonly kind: "send"; readonly token: string }
  /** Reset the widget: it issues a new token later. */
  | { readonly kind: "resetWidget" };

export interface ContactTransition {
  readonly state: ContactState;
  readonly effects: readonly ContactEffect[];
}

/** No token yet, nothing running. */
export const initialContact: ContactState = { token: null, submitting: false };

/** The next state and what the form must do. Pure function. */
export function contactTransition(state: ContactState, event: ContactEvent): ContactTransition {
  switch (event.kind) {
    case "tokenIssued":
      return { state: { ...state, token: event.token }, effects: [] };
    case "tokenLost":
      return { state: { ...state, token: null }, effects: [] };
    case "submitRequested":
      return state.submitting || state.token === null
        ? { state, effects: [] }
        : { state: { token: null, submitting: true }, effects: [{ kind: "send", token: state.token }] };
    case "submitFinished":
      return { state: { token: null, submitting: false }, effects: [{ kind: "resetWidget" }] };
  }
}

/** Whether the submit button is enabled. Pure function. */
export function canSubmit(state: ContactState): boolean {
  return state.token !== null && !state.submitting;
}
