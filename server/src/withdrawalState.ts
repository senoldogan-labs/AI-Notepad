/**
 * State machine of an EU withdrawal (`subscription_withdrawals` row, one per Stripe subscription; migration
 * `0065_subscription_withdrawals.sql`). Single source: `src/billing.ts` writes every change through
 * `nextWithdrawalState` with a compare-and-set UPDATE on `state`, and the migration's trigger enforces the same changes
 * (`allowedWithdrawalStateChanges`); `test/withdrawalState.test.ts` checks that the three agree.
 *
 * States:
 * - `requested`: the subscriber withdrew; the refund isn't confirmed yet (not started, a Stripe call failed, or a refund
 *   is still pending at Stripe). The subscriber's retry and the daily job (`retryPendingWithdrawals`) run it again.
 * - `settled`: every refund succeeded and together they reach the computed amount (final).
 * - `short`: every refund succeeded but they stay below the computed amount (a payment Stripe can't refund, or less was
 *   still refundable): alerted, the owner pays the rest by hand and may then mark it `settled`.
 * - `blocked`: Stripe refuses the refund for good (the payment is disputed or already refunded, or refunds to it keep
 *   failing): alerted, never retried automatically; the owner resolves it (`requested` again or `settled`).
 *
 * The row is the withdrawal's own record: re-subscribing, complimentary access, the subscription row's deletion
 * (`customer.deleted`) and account deletion don't remove it. Pure module: no database, no clock.
 */

/** A withdrawal's state (see the module documentation). */
export type WithdrawalState = "requested" | "settled" | "short" | "blocked";

/** Every state, for tests and the migration's CHECK constraint. */
export const withdrawalStates: readonly WithdrawalState[] = ["requested", "settled", "short", "blocked"];

/** What happens to a withdrawal. */
export type WithdrawalEvent =
  /** The subscriber confirms the withdrawal (no row yet). */
  | { readonly kind: "requested" }
  /** A run refunded what it could and at least one refund is still pending at Stripe. */
  | { readonly kind: "refundsPending" }
  /** A run failed with an error worth retrying (Stripe unreachable, a refund failed). */
  | { readonly kind: "attemptFailed" }
  /** Every withdrawal refund succeeded: `refundedCents` of the computed `targetCents`. */
  | { readonly kind: "refundsSucceeded"; readonly refundedCents: number; readonly targetCents: number }
  /** Stripe refuses the refund for good. */
  | { readonly kind: "refundRefused" }
  /** The owner retries a blocked withdrawal by hand (after fixing its cause). */
  | { readonly kind: "manualRetry" }
  /** The owner settled the rest by hand (a short or blocked withdrawal). */
  | { readonly kind: "manualSettle" };

/** State changes the database allows (staying in the same state is always allowed). */
export const allowedWithdrawalStateChanges: readonly (readonly [WithdrawalState, WithdrawalState])[] = [
  ["requested", "settled"],
  ["requested", "short"],
  ["requested", "blocked"],
  ["blocked", "requested"],
  ["blocked", "settled"],
  ["short", "settled"],
];

/**
 * The state after `event`; null when the event isn't valid in `current` (`null` current: no row yet). Pure function.
 */
export function nextWithdrawalState(current: WithdrawalState | null, event: WithdrawalEvent): WithdrawalState | null {
  switch (event.kind) {
    case "requested":
      return current === null ? "requested" : null;
    case "refundsPending":
    case "attemptFailed":
      return current === "requested" ? "requested" : null;
    case "refundsSucceeded":
      if (current !== "requested") {
        return null;
      }
      return event.refundedCents >= event.targetCents ? "settled" : "short";
    case "refundRefused":
      return current === "requested" ? "blocked" : null;
    case "manualRetry":
      return current === "blocked" ? "requested" : null;
    case "manualSettle":
      return current === "short" || current === "blocked" ? "settled" : null;
  }
}

/** Whether the state is final for the automatic flow (only the owner moves it on). Pure function. */
export function isFinalWithdrawalState(state: WithdrawalState): boolean {
  return state !== "requested";
}

/** Whether a state records a finished refund run (`settled_at` set). Pure function. */
export function isSettledWithdrawalState(state: WithdrawalState): boolean {
  return state === "settled" || state === "short";
}

/** A stored state value; throws on anything else (the CHECK constraint makes it impossible). */
export function withdrawalStateOf(value: string): WithdrawalState {
  const state: WithdrawalState | undefined = withdrawalStates.find((candidate: WithdrawalState): boolean => candidate === value);
  if (state === undefined) {
    throw new Error(`Unknown withdrawal state "${value}".`);
  }
  return state;
}
