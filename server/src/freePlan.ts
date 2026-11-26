import { z } from "zod";
import { continueAfterDisconnect } from "./background";
import type { Config, FreePlanConfig } from "./config";
import { randomId } from "./crypto";
import { type ActiveDeviceCheck, type DeviceBits, queryDeviceBits, updateDeviceBits } from "./deviceCheck";
import {
  type AccessConfig,
  type PaidSubscriptions,
  type SubscriptionAccess,
  type TrialState,
  paidAccess,
  paidSubscriptions,
  trialMeetingsLeft,
  userTrialState,
} from "./entitlements";
import { ApiError, FreePlanError } from "./errors";
import type { LLMPurpose } from "./llm/purpose";
import { log } from "./log";
import { trialDeviceClaimResumeMs } from "./meetings";
import type { Platform, RequestContext } from "./platform";
import { type TrialDeviceColumns, type TrialDevicePhase, trialDeviceDecision, trialDevicePhaseOf } from "./trialState";
import { dayKey, monthKey, nextMonthStartMs } from "./usage";

/**
 * The permanent free plan (docs/superpowers/specs/2026-11-23-free-plan.md). After the trial, an account without paid
 * access keeps Gistsmith on a capped plan instead of a paywall: transcripts are written on the device, and the server
 * gives `FREE_NOTES_PER_MONTH` AI notes (meetings up to `FREE_MAX_MEETING_MINUTES`) and `FREE_ASKS_PER_MONTH` Ask
 * answers per UTC month.
 *
 * Who is on it (`isFreePlanAccount`): the plan applies to the account (`FREE_PLAN_POLICY` on, or the user is in
 * `FREE_PLAN_USERS`), the app knows the plan (build ≥ `FREE_PLAN_MIN_BUILD`, `clientVersions.isFreePlanClient`), the
 * account has no paid access, and its trial is over (started, then meetings used or days passed). A new account still
 * starts with the full trial; an account whose trial ended before the plan opened becomes free at once.
 *
 * A free account never gets a meeting session (`startMeeting` keeps refusing with `trial_exhausted`), so
 * transcription, Deepgram, sync, shares and the AI assistant stay refused. What it gets:
 * - a note grant per note (`POST /v1/free/notes`, `createFreeNote`): a token budget (`FREE_NOTE_TOKEN_BUDGET`) that the
 *   LLM proxy reserves against when a call carries `x-free-note: <noteId>`, for the note purposes only
 *   (`freeNotePurposes`). Idempotent per `clientRef`; refunded by the daily cleanup when no call on it settled within
 *   `freeNoteRefundAfterMs`;
 * - account calls (no `x-meeting-id`, no `x-free-note`) for `freeAccountPurposes`, within
 *   `FREE_MONTHLY_ACCOUNT_TOKEN_CAP`; Ask answers (`ask_answer`, the keyboard's `keyboard_ask`) also count toward
 *   `FREE_ASKS_PER_MONTH` once they answer. No web search, no images, at most `FREE_LLM_MAX_INPUT_TOKENS` input.
 *
 * Abuse limits: one free plan per device (DeviceCheck `bit1`, bound at the account's first grant like the trial's
 * `bit0`), `FREE_ACCOUNTS_PER_IP_PER_DAY` new free accounts per IP per day, the identity ledger carrying the month's
 * counters across account deletion (`trialLedger.ts`), and the free spend ceilings (`usage.requireFreeSpendHeadroom`).
 *
 * Refusals keep an error code every app already knows and add `error.reason` (`FreePlanError`, `errors.freePlanRefusals`).
 */

/** Purposes a free note grant pays for. */
export const freeNotePurposes: readonly LLMPurpose[] = ["note", "note_chunk", "note_overview"];

/** Account calls (outside a note grant) a free account may make. */
export const freeAccountPurposes: readonly LLMPurpose[] = ["ask_search_terms", "ask_answer", "note_edit", "follow_up_email", "keyboard_ask"];

/** Account purposes that count as one Ask answer (`FREE_ASKS_PER_MONTH`). */
export const freeAskPurposes: readonly LLMPurpose[] = ["ask_answer", "keyboard_ask"];

/**
 * A grant still without a settled call this long after it was made is refunded (it no longer counts toward the month):
 * the same 24 hours a finished meeting stays open for processing (`MEETING_PROCESSING_HOURS` in production).
 */
export const freeNoteRefundAfterMs: number = 24 * 3_600_000;

/** Free note grants are kept this long (`cleanup.ts`). */
export const freeNoteRetentionMs: number = 400 * 86_400_000;

/** Whether the free plan applies to this user: the policy is on, or the user is on the allowlist. Pure function. */
export function freePlanAppliesTo(config: FreePlanConfig, userId: string): boolean {
  return config.policy === "on" || config.allowedUserIds.includes(userId);
}

/** Whether the account's trial is over: started, and its meetings are used up or its days passed. Pure function. */
export function isTrialOver(trial: TrialState, config: AccessConfig, now: Date): boolean {
  return trial.startedAt !== null && trialMeetingsLeft(trial, config, now) === 0;
}

/**
 * Whether the account is on the free plan now: the plan applies to it, the asking app knows the plan, it has no paid
 * access and its trial is over. Pure function.
 */
export function isFreePlanAccount(
  config: Config,
  userId: string,
  freePlanClient: boolean,
  access: SubscriptionAccess,
  trial: TrialState,
  now: Date,
): boolean {
  return freePlanAppliesTo(config.freePlan, userId) && freePlanClient && access === "none" && isTrialOver(trial, config, now);
}

/**
 * Refuses an account that isn't on the free plan now (`isFreePlanAccount`) with `402 subscription_required`, reason
 * `free_plan_unavailable`; `freePlanClient`: the asking app knows the plan.
 */
export async function requireFreePlanAccount(db: D1Database, config: Config, userId: string, freePlanClient: boolean, now: Date): Promise<void> {
  const [subscriptions, trial]: [PaidSubscriptions, TrialState] = await Promise.all([paidSubscriptions(db, userId), userTrialState(db, userId)]);
  if (!isFreePlanAccount(config, userId, freePlanClient, paidAccess(subscriptions, config, now), trial, now)) {
    throw freePlanUnavailableError();
  }
}

/** The refusal for an account that isn't on the free plan (paid, in trial, plan off, or an app that doesn't know it). */
export function freePlanUnavailableError(): FreePlanError {
  return new FreePlanError("subscription_required", "free_plan_unavailable", "The free plan isn't available for this account; subscribe to continue.");
}

/** A purpose the free plan doesn't pay for. */
function planRequiredError(purpose: LLMPurpose): FreePlanError {
  return new FreePlanError("subscription_required", "plan_required", `This AI feature (${purpose}) needs a subscription.`);
}

/** Refuses a note-grant call whose purpose isn't a note (`freeNotePurposes`). Pure function. */
export function requireFreeNotePurpose(purpose: LLMPurpose): void {
  if (!freeNotePurposes.includes(purpose)) {
    throw planRequiredError(purpose);
  }
}

/** Refuses a free account call whose purpose the free plan doesn't cover (`freeAccountPurposes`). Pure function. */
export function requireFreeAccountPurpose(purpose: LLMPurpose): void {
  if (!freeAccountPurposes.includes(purpose)) {
    throw planRequiredError(purpose);
  }
}

/** The month's free usage: notes (grants not refunded + carried over) and Ask answers (settled + pending). */
export interface FreeUsage {
  readonly notesUsed: number;
  readonly asksUsed: number;
}

/** SQL of the month's counted notes (binds: user, month). */
const notesUsedSql: string = `(SELECT COUNT(*) FROM free_note_grants WHERE user_id = ?1 AND month = ?2 AND refunded_at IS NULL)
  + COALESCE((SELECT free_notes_carried FROM monthly_usage WHERE user_id = ?1 AND month = ?2), 0)`;

/** The account's free usage this UTC month. */
export async function freeUsage(db: D1Database, userId: string, now: Date): Promise<FreeUsage> {
  const row: { notes: number; asks: number } | null = await db
    .prepare(
      `SELECT ${notesUsedSql} AS notes,
         COALESCE((SELECT free_asks FROM monthly_usage WHERE user_id = ?1 AND month = ?2), 0)
           + (SELECT COUNT(*) FROM usage_reservations WHERE user_id = ?1 AND month = ?2 AND free_ask = 1 AND expires_at > ?3) AS asks`,
    )
    .bind(userId, monthKey(now), now.getTime())
    .first<{ notes: number; asks: number }>();
  return { notesUsed: row?.notes ?? 0, asksUsed: row?.asks ?? 0 };
}

/** The free plan's limits and what is left of them (`GET /v1/me`, `POST /v1/free/notes`). */
export interface FreeAllowance {
  readonly freeNotesLeft: number;
  readonly freeNotesTotal: number;
  readonly freeAsksLeft: number;
  readonly freeAsksTotal: number;
  readonly freeMaxMeetingMinutes: number;
  /** When the month's counters reset: the start of the next UTC month (ISO 8601). */
  readonly freeResetsAt: string;
}

/** The allowance from the month's usage. Pure function. */
export function freeAllowance(config: FreePlanConfig, usage: FreeUsage, now: Date): FreeAllowance {
  return {
    freeNotesLeft: Math.max(0, config.notesPerMonth - usage.notesUsed),
    freeNotesTotal: config.notesPerMonth,
    freeAsksLeft: Math.max(0, config.asksPerMonth - usage.asksUsed),
    freeAsksTotal: config.asksPerMonth,
    freeMaxMeetingMinutes: config.maxMeetingMinutes,
    freeResetsAt: new Date(nextMonthStartMs(now)).toISOString(),
  };
}

/** The free plan on the public pricing page (`GET /v1/pricing` → `free`): only while the policy is on. Pure function. */
export function freePlanPricing(config: FreePlanConfig): { readonly notesPerMonth: number; readonly maxMeetingMinutes: number; readonly asksPerMonth: number } | null {
  return config.policy === "on"
    ? { notesPerMonth: config.notesPerMonth, maxMeetingMinutes: config.maxMeetingMinutes, asksPerMonth: config.asksPerMonth }
    : null;
}

/** A free note grant row. */
export interface FreeNoteGrant {
  readonly id: string;
  readonly userId: string;
  readonly month: string;
  readonly clientRef: string;
  readonly tokenBudget: number;
  readonly tokensUsed: number;
  readonly createdAt: number;
}

interface FreeNoteGrantRow {
  readonly id: string;
  readonly user_id: string;
  readonly month: string;
  readonly client_ref: string;
  readonly token_budget: number;
  readonly tokens_used: number;
  readonly created_at: number;
}

/** Row → grant. Pure function. */
function grantOf(row: FreeNoteGrantRow): FreeNoteGrant {
  return {
    id: row.id,
    userId: row.user_id,
    month: row.month,
    clientRef: row.client_ref,
    tokenBudget: row.token_budget,
    tokensUsed: row.tokens_used,
    createdAt: row.created_at,
  };
}

const grantColumns: string = "id, user_id, month, client_ref, token_budget, tokens_used, created_at";

/** The user's live (not refunded) grant for a recording; null when there is none. */
async function grantByClientRef(db: D1Database, userId: string, clientRef: string): Promise<FreeNoteGrant | null> {
  const row: FreeNoteGrantRow | null = await db
    .prepare(`SELECT ${grantColumns} FROM free_note_grants WHERE user_id = ? AND client_ref = ? AND refunded_at IS NULL`)
    .bind(userId, clientRef)
    .first<FreeNoteGrantRow>();
  return row === null ? null : grantOf(row);
}

/** The `x-free-note` header: a note grant ID (UUID); null without the header, `bad_request` when malformed. Pure function. */
export function freeNoteHeader(request: Request): string | null {
  const value: string | null = request.headers.get("x-free-note");
  if (value === null) {
    return null;
  }
  if (!z.uuid().safeParse(value).success) {
    throw new ApiError("bad_request", "The x-free-note header must be a free note ID.");
  }
  return value;
}

/** The user's grant for an `x-free-note` call; another user's, unknown or refunded grant is `404` (`free_note_invalid`). */
export async function requireUsableFreeNote(db: D1Database, userId: string, grantId: string): Promise<FreeNoteGrant> {
  const row: FreeNoteGrantRow | null = await db
    .prepare(`SELECT ${grantColumns} FROM free_note_grants WHERE id = ? AND user_id = ? AND refunded_at IS NULL`)
    .bind(grantId, userId)
    .first<FreeNoteGrantRow>();
  if (row === null) {
    throw new FreePlanError("not_found", "free_note_invalid", "This free note isn't valid any more; start the note again.");
  }
  return grantOf(row);
}

/** `POST /v1/free/notes` body. */
export const freeNoteRequestSchema = z.strictObject({
  /** The app's ID of the recording: a repeated request with the same ID returns the same grant. */
  clientRef: z.string().regex(/^[A-Za-z0-9._-]{1,64}$/),
  /** The recording's length (minutes, rounded up); over `FREE_MAX_MEETING_MINUTES` is refused. */
  meetingMinutes: z.number().int().min(0).max(24 * 60),
  /** Apple DeviceCheck token (base64): needed for the account's first grant while `DEVICECHECK_POLICY` is `required`. */
  deviceCheckToken: z.base64().min(1).max(8192).optional(),
});

/** What `createFreeNote` needs besides the body. */
export interface FreeNoteRequest {
  readonly clientRef: string;
  readonly meetingMinutes: number;
  readonly deviceCheckToken: string | null;
  /** App Attest key the request was asserted with (logs only); null without an assertion. */
  readonly deviceId: string | null;
  /** HMAC of the client IP (`trial-ip:` key, the trial's primitive). */
  readonly clientIpHash: string;
}

/** `POST /v1/free/notes` answer. */
export interface FreeNoteResponse extends FreeAllowance {
  readonly noteId: string;
  readonly tokenBudget: number;
  readonly tokensUsed: number;
  /** False when the same `clientRef` already had a grant (nothing was counted again). */
  readonly created: boolean;
}

/** The answer for a grant. */
async function freeNoteResponse(db: D1Database, config: FreePlanConfig, grant: FreeNoteGrant, created: boolean, now: Date): Promise<FreeNoteResponse> {
  return {
    noteId: grant.id,
    tokenBudget: grant.tokenBudget,
    tokensUsed: grant.tokensUsed,
    created,
    ...freeAllowance(config, await freeUsage(db, grant.userId, now), now),
  };
}

/** Why a grant insert was refused: the month's notes are used, or the IP's new free accounts for today. Pure function. */
export function freeNoteRefusal(notesUsed: number, notesPerMonth: number): "free_notes_used" | "free_ip_limit" {
  return notesUsed >= notesPerMonth ? "free_notes_used" : "free_ip_limit";
}

/** The refusal for a used-up month. Pure function. */
function notesUsedError(config: FreePlanConfig): FreePlanError {
  return new FreePlanError(
    "monthly_cap_reached",
    "free_notes_used",
    `You have used this month's ${config.notesPerMonth} free AI notes; your transcript is saved. Subscribe for notes on every meeting.`,
  );
}

/**
 * Creates the note grant for one recording (the caller checked the account is on the free plan, AI consent and the
 * spend ceilings). In order:
 * 1. the same `clientRef` already has a live grant: it is returned (nothing counted again);
 * 2. a meeting over `FREE_MAX_MEETING_MINUTES` is refused (`free_meeting_too_long`);
 * 3. the month's notes are used (`free_notes_used`);
 * 4. DeviceCheck `bit1` for the account's first grant (`requireFreeDevice`);
 * 5. one batch: the account's first grant records the IP's new free account (`free_starts`, only below
 *    `FREE_ACCOUNTS_PER_IP_PER_DAY`), and the grant is inserted only if the account already had a grant or its IP row
 *    exists, and the month's notes are below the limit. Concurrent requests can't pass either limit.
 */
export async function createFreeNote(
  db: D1Database,
  context: RequestContext,
  config: Config,
  userId: string,
  request: FreeNoteRequest,
  now: Date,
): Promise<FreeNoteResponse> {
  const free: FreePlanConfig = config.freePlan;
  const existing: FreeNoteGrant | null = await grantByClientRef(db, userId, request.clientRef);
  if (existing !== null) {
    return freeNoteResponse(db, free, existing, false, now);
  }
  if (request.meetingMinutes > free.maxMeetingMinutes) {
    throw new FreePlanError(
      "subscription_required",
      "free_meeting_too_long",
      `Free AI notes cover meetings up to ${free.maxMeetingMinutes} minutes; your transcript is saved. Subscribe for longer meetings.`,
    );
  }
  const before: FreeUsage = await freeUsage(db, userId, now);
  if (before.notesUsed >= free.notesPerMonth) {
    throw notesUsedError(free);
  }
  await requireFreeDevice(db, context, config, userId, request.deviceCheckToken, now);
  const grantId: string = randomId();
  const month: string = monthKey(now);
  const day: string = dayKey(now);
  const [, inserted]: D1Result[] = await db.batch([
    db
      .prepare(
        `INSERT OR IGNORE INTO free_starts (user_id, ip_hash, day, created_at)
         SELECT ?1, ?2, ?3, ?4
         WHERE NOT EXISTS (SELECT 1 FROM free_note_grants WHERE user_id = ?1)
           AND (SELECT COUNT(*) FROM free_starts WHERE ip_hash = ?2 AND day = ?3) < ?5`,
      )
      .bind(userId, request.clientIpHash, day, now.getTime(), free.accountsPerIpPerDay),
    db
      .prepare(
        `INSERT OR IGNORE INTO free_note_grants (id, user_id, month, client_ref, token_budget, tokens_used, created_at, device_id, ip_hash)
         SELECT ?3, ?1, ?2, ?4, ?5, 0, ?6, ?7, ?8
         WHERE (EXISTS (SELECT 1 FROM free_note_grants WHERE user_id = ?1) OR EXISTS (SELECT 1 FROM free_starts WHERE user_id = ?1))
           AND ${notesUsedSql} < ?9`,
      )
      .bind(userId, month, grantId, request.clientRef, free.noteTokenBudget, now.getTime(), request.deviceId, request.clientIpHash, free.notesPerMonth),
  ]);
  if (inserted?.meta.changes === 1) {
    log("info", "free_note_granted", { userId, noteId: grantId, attested: request.deviceId !== null });
    const grant: FreeNoteGrant = {
      id: grantId,
      userId,
      month,
      clientRef: request.clientRef,
      tokenBudget: free.noteTokenBudget,
      tokensUsed: 0,
      createdAt: now.getTime(),
    };
    return freeNoteResponse(db, free, grant, true, now);
  }
  // A concurrent request for the same recording won: its grant is the answer.
  const raced: FreeNoteGrant | null = await grantByClientRef(db, userId, request.clientRef);
  if (raced !== null) {
    return freeNoteResponse(db, free, raced, false, now);
  }
  const after: FreeUsage = await freeUsage(db, userId, now);
  const reason: "free_notes_used" | "free_ip_limit" = freeNoteRefusal(after.notesUsed, free.notesPerMonth);
  log("info", "free_note_refused", { userId, reason });
  if (reason === "free_notes_used") {
    throw notesUsedError(free);
  }
  throw new FreePlanError("trial_ip_limit", "free_ip_limit", "Too many new free accounts started on this network today; try again tomorrow or subscribe.");
}

/**
 * One free plan per device (Apple DeviceCheck `bit1` = "this device has a free plan bound to an account"; `bit0` is the
 * trial's). Nothing to do while `DEVICECHECK_POLICY` is `off` or once the account is bound
 * (`users.free_device_verified_at`, carried over by the identity ledger). Otherwise the token is required
 * (`device_check_required`); then the same claim steps as the trial (`trialDeviceDecision` on `bit1`): a free device is
 * bound to this account (pending claim, `bit1` = true with `bit0` kept, verified), this account's own interrupted claim
 * is finished, and a device bound to another account is refused (`403 trial_device_used`, reason `free_device_used`).
 */
async function requireFreeDevice(
  db: D1Database,
  context: RequestContext,
  config: Config,
  userId: string,
  deviceCheckToken: string | null,
  now: Date,
): Promise<void> {
  const deviceCheck: Config["deviceCheck"] = config.deviceCheck;
  if (deviceCheck.policy === "off") {
    return;
  }
  const row: TrialDeviceColumns | null = await db
    .prepare("SELECT free_device_verified_at AS verified_at, free_device_claim_started_at AS claim_started_at FROM users WHERE id = ?")
    .bind(userId)
    .first<TrialDeviceColumns>();
  if (row === null) {
    throw new ApiError("unauthorized", "The account no longer exists.");
  }
  const phase: TrialDevicePhase = trialDevicePhaseOf(row);
  if (phase.kind === "verified") {
    return;
  }
  if (deviceCheckToken === null) {
    throw new ApiError("device_check_required", "The free plan requires this device's Apple DeviceCheck token; update the app.");
  }
  const bits: DeviceBits = await queryDeviceBits(context.platform, deviceCheck, deviceCheckToken, now);
  const decision: "claim" | "resume" | "refuse" = trialDeviceDecision(phase, bits.bit1, now.getTime(), trialDeviceClaimResumeMs);
  if (decision === "resume") {
    await markFreeDeviceVerified(db, userId, now);
    log("warn", "free_device_claim_resumed", { userId, claimStartedAt: row.claim_started_at });
    return;
  }
  if (decision === "refuse") {
    log("info", "free_note_refused", { userId, reason: "free_device_used" });
    throw new FreePlanError(
      "trial_device_used",
      "free_device_used",
      "The free plan is already used on this device with another account. Subscribe to use Gistsmith on this device with this account.",
    );
  }
  await db
    .prepare("UPDATE users SET free_device_claim_started_at = ? WHERE id = ? AND free_device_verified_at IS NULL")
    .bind(now.getTime(), userId)
    .run();
  // The device mark and the binding finish even if the client disconnects: no half-done claim.
  await continueAfterDisconnect(context, claimFreeDevice(db, context.platform, deviceCheck, userId, deviceCheckToken, bits, now), "free_device_claim_failed", {
    userId,
  });
  log("info", "free_device_claimed", { userId });
}

/**
 * Marks the device (`bit1` = true, `bit0` kept) and binds the account. When Apple rejected the token (it surely didn't
 * write) the pending claim is cleared; on other errors Apple may have written, so the claim stays for a resume.
 */
async function claimFreeDevice(
  db: D1Database,
  platform: Platform,
  deviceCheck: ActiveDeviceCheck,
  userId: string,
  deviceCheckToken: string,
  bits: DeviceBits,
  now: Date,
): Promise<void> {
  try {
    await updateDeviceBits(platform, deviceCheck, deviceCheckToken, { bit0: bits.bit0, bit1: true }, now);
  } catch (error: unknown) {
    if (error instanceof ApiError && error.code === "device_check_invalid") {
      await db.prepare("UPDATE users SET free_device_claim_started_at = NULL WHERE id = ?").bind(userId).run();
    }
    throw error;
  }
  await markFreeDeviceVerified(db, userId, now);
}

/** Binds the account's free plan to its device and clears the pending claim. */
async function markFreeDeviceVerified(db: D1Database, userId: string, now: Date): Promise<void> {
  await db
    .prepare("UPDATE users SET free_device_verified_at = ?, free_device_claim_started_at = NULL WHERE id = ? AND free_device_verified_at IS NULL")
    .bind(now.getTime(), userId)
    .run();
}

/**
 * The daily cleanup's refund (spec R10): a grant with no settled call `freeNoteRefundAfterMs` after it was made no
 * longer counts toward its month and can't be used; the same recording may ask again (the `clientRef` is free).
 */
export function freeNoteRefundStatement(db: D1Database, now: Date): D1PreparedStatement {
  const nowMs: number = now.getTime();
  return db
    .prepare("UPDATE free_note_grants SET refunded_at = ? WHERE refunded_at IS NULL AND first_settled_at IS NULL AND created_at < ?")
    .bind(nowMs, nowMs - freeNoteRefundAfterMs);
}
