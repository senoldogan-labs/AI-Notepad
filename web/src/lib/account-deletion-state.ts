// Account deletion on the account page (src/client/account.ts). The dialog's confirmation word enables one deletion;
// once it is sent, nothing in the dialog (typing the word again, Enter, reopening it) sends another until it fails, and
// after it succeeds the page only shows the deleted card and leaves. The deletion acts on this tab's session, which
// nothing on the page can replace while the dialog is open. Pure; no DOM (scripts/account-deletion-state.test.ts).

export type AccountDeletionState =
  | { readonly kind: "closed" }
  /** The dialog is open; `wordMatches` is whether the confirmation word is typed. */
  | { readonly kind: "confirming"; readonly wordMatches: boolean }
  /** `DELETE /v1/me` is in flight. */
  | { readonly kind: "deleting" }
  | { readonly kind: "deleted" };

export type AccountDeletionEvent =
  | { readonly kind: "opened" }
  | { readonly kind: "typed"; readonly wordMatches: boolean }
  | { readonly kind: "cancelled" }
  | { readonly kind: "confirmed" }
  /** The request failed: the dialog offers it again; `wordMatches` is whether the word is still typed. */
  | { readonly kind: "failed"; readonly wordMatches: boolean }
  | { readonly kind: "succeeded" };

export type AccountDeletionEffect =
  /** Send `DELETE /v1/me` (once per confirmation). */
  | { readonly kind: "sendDeletion" }
  /** Clear the session, show the deleted card and leave for the home page. */
  | { readonly kind: "finish" };

export interface AccountDeletionTransition {
  readonly state: AccountDeletionState;
  readonly effects: readonly AccountDeletionEffect[];
}

export const initialAccountDeletion: AccountDeletionState = { kind: "closed" };

/** The next state and what the page must do; an event that does not apply leaves the state unchanged. Pure function. */
export function accountDeletionTransition(state: AccountDeletionState, event: AccountDeletionEvent): AccountDeletionTransition {
  const unchanged: AccountDeletionTransition = { state, effects: [] };
  switch (event.kind) {
    case "opened":
      return state.kind === "closed" ? { state: { kind: "confirming", wordMatches: false }, effects: [] } : unchanged;
    case "typed":
      return state.kind === "confirming" ? { state: { kind: "confirming", wordMatches: event.wordMatches }, effects: [] } : unchanged;
    case "cancelled":
      return state.kind === "confirming" ? { state: initialAccountDeletion, effects: [] } : unchanged;
    case "confirmed":
      return state.kind === "confirming" && state.wordMatches ? { state: { kind: "deleting" }, effects: [{ kind: "sendDeletion" }] } : unchanged;
    case "failed":
      return state.kind === "deleting" ? { state: { kind: "confirming", wordMatches: event.wordMatches }, effects: [] } : unchanged;
    case "succeeded":
      return state.kind === "deleting" ? { state: { kind: "deleted" }, effects: [{ kind: "finish" }] } : unchanged;
  }
}

/** Whether the dialog's delete button is enabled. Pure function. */
export function canConfirmDeletion(state: AccountDeletionState): boolean {
  return state.kind === "confirming" && state.wordMatches;
}

/** Whether the dialog may be closed (Escape, Cancel): not while the deletion is in flight. Pure function. */
export function canCloseDeletion(state: AccountDeletionState): boolean {
  return state.kind === "confirming";
}
