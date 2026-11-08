import type { AccessConfig, TrialState } from "./entitlements";

/**
 * Trial rules shared by the TypeScript decisions and the SQL gate of `startTrialMeeting` (src/meetings.ts), so the two
 * cannot drift; `test/stateGuards.test.ts` checks them against each other row by row. Migration 0059 keeps the stored
 * columns moving forward only: `users.trial_started_at` is never cleared or moved later, `carried_trial_meetings` never
 * shrinks, and a Mac binding (`trial_device_verified_at`) is final and never coexists with a pending claim.
 *
 * Account trial: not started (`trial_started_at` NULL) → running (started, meetings left, not expired) → over (meetings
 * used up or `trialDurationMs` passed). Mac binding (DeviceCheck): unclaimed → claim pending
 * (`trial_device_claim_started_at`) → verified; a claim Apple rejected goes back to unclaimed.
 *
 * Pure module: no database or clock access.
 */

/** A SQL fragment with its positional (`?`) binds in order. */
export interface SqlCondition {
  readonly sql: string;
  readonly binds: readonly (string | number)[];
}

/**
 * The SQL condition that the account still has a trial meeting (`trialMeetingsLeft` > 0, see `entitlements.ts`):
 * used trial meetings (its own plus those carried over from deleted accounts) below `trialMeetings`, and the trial not
 * expired (a trial that has not started does not expire). Pure function.
 */
export function trialMeetingLeftSql(config: AccessConfig, userId: string, nowMs: number): SqlCondition {
  return {
    sql: `(SELECT COUNT(*) FROM meeting_sessions WHERE user_id = ? AND kind = 'trial')
        + (SELECT carried_trial_meetings FROM users WHERE id = ?) < ?
      AND COALESCE((SELECT trial_started_at FROM users WHERE id = ?) + ?, ? + 1) > ?`,
    binds: [userId, userId, config.trialMeetings, userId, config.trialDurationMs, nowMs, nowMs],
  };
}

/** The Mac binding columns of `users`. */
export interface TrialDeviceColumns {
  readonly verified_at: number | null;
  readonly claim_started_at: number | null;
}

export type TrialDevicePhase =
  | { readonly kind: "unclaimed" }
  | { readonly kind: "claim_pending"; readonly startedAt: number }
  | { readonly kind: "verified"; readonly verifiedAt: number };

/** Thrown for a row that is both bound to a Mac and still claiming one. */
export class TrialDeviceStateError extends Error {
  constructor(columns: TrialDeviceColumns) {
    super(`Contradictory trial device columns: verified_at=${columns.verified_at} claim_started_at=${columns.claim_started_at}`);
    this.name = "TrialDeviceStateError";
  }
}

/** Decodes the Mac binding; a contradictory row throws `TrialDeviceStateError`. Pure function. */
export function trialDevicePhaseOf(columns: TrialDeviceColumns): TrialDevicePhase {
  if (columns.verified_at !== null) {
    if (columns.claim_started_at !== null) {
      throw new TrialDeviceStateError(columns);
    }
    return { kind: "verified", verifiedAt: columns.verified_at };
  }
  return columns.claim_started_at === null ? { kind: "unclaimed" } : { kind: "claim_pending", startedAt: columns.claim_started_at };
}

/**
 * What to do for an unbound account given this Mac's DeviceCheck `bit0` ("this Mac gave a trial to an account"):
 * - `claim`: the Mac is free; bind it to this account;
 * - `resume`: the Mac is marked and this account's own claim started within `resumeMs`, so the mark is most likely this
 *   account's interrupted request (Apple wrote, the answer or the verification write was lost); finish the binding;
 * - `refuse`: the Mac gave a trial to another account (an old pending claim cannot open the trial with another Mac).
 * Pure function.
 */
export function trialDeviceDecision(phase: Exclude<TrialDevicePhase, { readonly kind: "verified" }>, bit0: boolean, nowMs: number, resumeMs: number): "claim" | "resume" | "refuse" {
  if (!bit0) {
    return "claim";
  }
  return phase.kind === "claim_pending" && nowMs - phase.startedAt <= resumeMs ? "resume" : "refuse";
}

/** Trial meetings left, also counting the device's own (`deviceUsed`, null for an unregistered device). Pure function. */
export function trialMeetingsLeftOnDevice(config: AccessConfig, trial: TrialState, deviceUsed: number | null): number {
  return Math.max(0, config.trialMeetings - Math.max(trial.used, deviceUsed ?? 0));
}
