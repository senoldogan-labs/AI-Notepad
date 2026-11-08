/**
 * The state machine of one refresh token (`refresh_tokens`), as pure functions. The columns are `used_at` and
 * `replaced_by` (the successor's hash, or `supersededMarker`); migration 0059 keeps them moving forward only.
 *
 * - `unused`: never presented (`used_at` NULL, `replaced_by` NULL);
 * - `rotated`: presented once and replaced by `successor` (both set);
 * - `superseded`: an unused successor that a retried rotation replaced (`replaced_by` = `supersededMarker`); if it is
 *   presented later, the old token was in two hands and the family is signed out;
 * - `used_without_successor`: used before the successor column existed (migration 0013); presenting it again is reuse.
 *
 * Moves: `unused` → `rotated` (rotation), `rotated` → `rotated` with a new successor (a retry within
 * `refreshRetryWindowMs` while the successor is unused), `unused` → `superseded` (the successor a retry replaced).
 */

/** `replaced_by` of a successor a retried rotation replaced. */
export const supersededMarker: "superseded" = "superseded";

export type RefreshTokenState =
  | { readonly kind: "unused" }
  | { readonly kind: "rotated"; readonly usedAt: number; readonly successor: string }
  | { readonly kind: "superseded"; readonly usedAt: number }
  | { readonly kind: "used_without_successor"; readonly usedAt: number };

/** The state columns of a `refresh_tokens` row. */
export interface RefreshTokenColumns {
  readonly used_at: number | null;
  readonly replaced_by: string | null;
}

/** Thrown for a row whose state columns contradict each other (a successor without a use). */
export class RefreshTokenStateError extends Error {
  constructor(columns: RefreshTokenColumns) {
    super(`Contradictory refresh token columns: used_at=${columns.used_at} replaced_by=${columns.replaced_by === null ? "null" : "set"}`);
    this.name = "RefreshTokenStateError";
  }
}

/** Decodes the state columns; a contradictory row throws `RefreshTokenStateError`. Pure function. */
export function refreshTokenStateOf(columns: RefreshTokenColumns): RefreshTokenState {
  if (columns.used_at === null) {
    if (columns.replaced_by !== null) {
      throw new RefreshTokenStateError(columns);
    }
    return { kind: "unused" };
  }
  if (columns.replaced_by === null) {
    return { kind: "used_without_successor", usedAt: columns.used_at };
  }
  return columns.replaced_by === supersededMarker
    ? { kind: "superseded", usedAt: columns.used_at }
    : { kind: "rotated", usedAt: columns.used_at, successor: columns.replaced_by };
}

/**
 * What a presented token that could not be claimed (already used) leads to: a superseded successor signs the family
 * out at once; a rotated token used within `retryWindowMs` may be a retry whose answer was lost (the caller still has
 * to check, atomically, that the successor is unused); anything else is reuse. Pure function.
 */
export function usedTokenOutcome(state: RefreshTokenState, nowMs: number, retryWindowMs: number): "superseded_reuse" | "retry" | "reuse" {
  switch (state.kind) {
    case "superseded":
      return "superseded_reuse";
    case "rotated":
      return nowMs - state.usedAt <= retryWindowMs ? "retry" : "reuse";
    case "unused":
    case "used_without_successor":
      return "reuse";
  }
}
