import { z } from "zod";
import type { Config, PhoneCallLimits, PhoneCallsConfig } from "../config";
import { randomId } from "../crypto";
import { type AccessConfig, type PaidSubscriptions, paidSubscriptions, subscriptionAccess } from "../entitlements";
import { appStoreAccess } from "../appStore";
import { ApiError } from "../errors";
import { jsonResponse, readBodyBytes, readJsonBody } from "../http";
import { log } from "../log";
import type { OutboundPlatform } from "../platform";
import { type ReservationLimit, dailySpendLimit, remainingOf } from "../reservations";
import { dayKey, monthKey, monthlyUsage } from "../usage";
import { type NumberClass, type PhoneCountry, callerIdBlockedInto, classifyNumber, isPhoneCountry, maskedNumber } from "./numbers";
import {
  type PhoneCallEvent,
  type PhoneCallStatus,
  type RecordingDecision,
  type RecordingEvent,
  callSourceSql,
  callStatusAfter,
  nextCallStatus,
  orphanRecordingDecision,
  recordingSourceSql,
  recordingStateOf,
  recordingTransition,
  unsettledCallCountsSql,
} from "./lifecycle";
import { CallerIdAlreadyRegisteredError, type CallerIdVerificationStart, type VoiceProvider } from "./provider";
import { type TwilioCredentials, twilioProvider } from "./twilio";
import { announcementTwiml, dialTwiml, emptyTwiml, hangupTwiml, ringTimeoutSeconds, twimlResponse } from "./twiml";

/**
 * The in-app dialer pilot (design, provider choice, costs and App Review checklist:
 * docs/superpowers/specs/2026-11-08-iphone-call-recording.md, phase 2).
 *
 * The iPhone app places an outgoing call over VoIP (Twilio Voice SDK + CallKit); Twilio asks `/v1/phone/webhooks/voice`
 * what to do and this server answers with a `<Dial>` to the destination stored when the call was reserved, with the
 * user's own verified number as caller ID, a time limit, dual-channel recording and a spoken recording notice to the
 * person called. After the call the app fetches the recording through this server, imports it as an ordinary meeting
 * (transcription, speakers, note, tasks and sync run as for any imported recording) and deletes it at Twilio.
 *
 * Everything is off unless `PHONE_CALLS_POLICY=on` (production keeps it off). Guards:
 * - subscribers only; calls only after an explicit opt-in to the recording terms (`phone_consents`, `phoneConsentVersion`);
 * - caller ID is only the user's own number, verified by Twilio calling it (no spoofing); one account per number;
 * - destinations: E.164, a country in `PHONE_CALLS_COUNTRIES`, no premium-rate or special ranges (`numbers.ts`);
 *   emergency and short numbers are opened in the Phone app by the app and never reach the server;
 * - spend: each call reserves its worst case (longest duration × the country's price) in `phone_calls`; the reservation
 *   counts toward the global daily ceiling (`todaySpendSql`) and the dialer's own `PHONE_DAILY_SPEND_CEILING_USD`, and
 *   is replaced by the real cost when the call ends; a user has one call at a time, `phoneCallsPerDay` calls a day,
 *   `PHONE_MONTHLY_MINUTES` and `PHONE_USER_MONTHLY_SPEND_USD` a month (a pricier country uses the spend up in fewer
 *   minutes); a call never runs past the plan's remaining monthly minutes; no country priced above
 *   `PHONE_MAX_USD_PER_MINUTE` can be enabled (`config.ts`);
 * - every webhook must carry Twilio's signature and our account id; the destination comes from our row, never from
 *   the webhook.
 * Numbers are personal data: the destination and caller ID of a call are cleared when it settles, logs mask numbers.
 */

/**
 * Version of the recording terms the user accepts in the app (after verifying their number); raising it asks every user
 * again. 2: the per-country consent notes of the step-by-step setup.
 */
export const phoneConsentVersion: number = 2;
/** Verification calls per user per day (each one rings a phone and costs money). */
export const phoneVerificationsPerDay: number = 5;
/** Verification calls per user per month (they ring other people's phones too, so they are capped beyond the day). */
export const phoneVerificationsPerMonth: number = 10;
/** Calls per user per day. */
export const phoneCallsPerDay: number = 30;
/** How long a pending verification waits for its result. */
const verificationWindowMs: number = 10 * 60_000;
/** The access token's life: the app connects right after reserving. */
const accessTokenTtlSeconds: number = 120;
/** A reserved call that has not reached the voice webhook in this time is released at no cost. */
const connectWindowMs: number = 2 * 60_000;
/** Allowance after the longest call for the provider's callbacks before the scheduled cleanup settles the worst case. */
const settleSlackMs: number = 15 * 60_000;
/** Shortest call worth placing. */
const minimumCallSeconds: number = 60;
/** A recording the app has not fetched is deleted at the provider after this. */
export const phoneRecordingRetentionMs: number = 24 * 3_600_000;
/** Settled call rows are kept this long (monthly minutes, support), then deleted. */
const settledCallRetentionMs: number = 90 * 86_400_000;
/** Webhook form bodies are small. */
const webhookBodyBytes: number = 16 * 1024;
const smallBodyBytes: number = 4 * 1024;

/** The dialer as the app sees it (`GET /v1/phone`). */
export interface PhoneStatus {
  readonly available: boolean;
  /** Why the dialer is hidden; `null` when available. */
  readonly reason: "policy_off" | "country_not_allowed" | "subscription_required" | null;
  /** Countries the user may call. */
  readonly countries: readonly PhoneCountry[];
  /** Countries whose numbers may be verified as the caller ID. */
  readonly callerCountries: readonly PhoneCountry[];
  /** The voice provider named in the disclosure; `null` while off. */
  readonly provider: string | null;
  readonly consentVersion: number;
  readonly consentAccepted: boolean;
  readonly number: PhoneNumberState | null;
  readonly maxCallMinutes: number;
  readonly monthlyMinutes: number;
  readonly usedMinutes: number;
  /**
   * Minutes the user can still talk this month per allowed country: the remaining call minutes, or fewer where the
   * country's price would use up the monthly spend first. Empty while off.
   */
  readonly minutesByCountry: Readonly<Partial<Record<PhoneCountry, number>>>;
}

/** The user's caller ID number. */
export interface PhoneNumberState {
  readonly e164: string;
  readonly status: "pending" | "verified" | "failed";
}

/** `POST /v1/phone/number` answer: the code the user types when the verification call comes. */
export interface PhoneVerificationStarted extends PhoneNumberState {
  readonly validationCode: string;
  readonly expiresAt: number;
}

/** `POST /v1/phone/calls` answer: what the app's Voice SDK connects with. */
export interface PhoneCallReserved {
  readonly callId: string;
  /** Voice SDK access token; the app passes `callId` as a connect parameter and the voice webhook matches it. */
  readonly accessToken: string;
  readonly maxSeconds: number;
  readonly country: PhoneCountry;
  readonly provider: string;
}

/** `GET /v1/phone/calls/:id` answer. */
export interface PhoneCallState {
  readonly callId: string;
  readonly status: PhoneCallRow["status"];
  readonly billedSeconds: number | null;
  readonly recording: "pending" | "ready" | "absent" | "deleted";
}

interface PhoneNumberRow {
  readonly user_id: string;
  readonly e164: string;
  readonly country: string;
  readonly status: "pending" | "verified" | "failed";
  readonly validation_call_sid: string | null;
  readonly provider_sid: string | null;
  readonly pending_until: number | null;
}

export interface PhoneCallRow {
  readonly id: string;
  readonly user_id: string;
  readonly status: PhoneCallStatus;
  readonly destination: string | null;
  readonly caller_id: string | null;
  readonly country: string;
  readonly max_seconds: number;
  readonly micro_usd_per_minute: number;
  readonly estimated_micro_usd: number;
  readonly day: string;
  readonly provider_call_sid: string | null;
  readonly billed_seconds: number | null;
  readonly recording_status: "ready" | "absent" | null;
  readonly recording_sid: string | null;
  readonly recording_deleted_at: number | null;
  readonly reserved_until: number;
  readonly settled_at: number | null;
}

/** The dialer while it is on: limits and the provider. */
interface ActivePhone {
  readonly config: Extract<PhoneCallsConfig, { policy: "on" }>;
  readonly provider: VoiceProvider;
}

/** The provider for an on dialer; `null` while off. */
export function phoneProviderOf(platform: OutboundPlatform, phone: PhoneCallsConfig): VoiceProvider | null {
  return phone.policy === "on" ? twilioProvider(platform, phone.twilio) : null;
}

/** The dialer's settings and provider; `503 phone_unavailable` while off. */
function requireActivePhone(platform: OutboundPlatform, config: Config): ActivePhone {
  const phone: PhoneCallsConfig = config.phoneCalls;
  if (phone.policy === "off") {
    throw new ApiError("phone_unavailable", "Calling from Gistsmith is not available.");
  }
  const credentials: TwilioCredentials = phone.twilio;
  return { config: phone, provider: twilioProvider(platform, credentials) };
}

/** The Voice SDK identity of a call (Twilio allows letters, digits and underscores). Pure function. */
export function callIdentity(callId: string): string {
  return `gs_${callId.replaceAll("-", "")}`;
}

/** Whether a country is one of the allowed ones. Pure function. */
function allowedCountry(countries: readonly PhoneCountry[], value: string | null): value is PhoneCountry {
  return value !== null && isPhoneCountry(value) && countries.includes(value);
}

async function numberRow(db: D1Database, userId: string): Promise<PhoneNumberRow | null> {
  return db.prepare("SELECT * FROM phone_numbers WHERE user_id = ?").bind(userId).first<PhoneNumberRow>();
}

async function consentAccepted(db: D1Database, userId: string): Promise<boolean> {
  const row: { version: number } | null = await db.prepare("SELECT version FROM phone_consents WHERE user_id = ?").bind(userId).first<{ version: number }>();
  return row !== null && row.version >= phoneConsentVersion;
}

/** The user's billed and running call seconds this month (running calls count at their longest, `unsettledCallCountsSql`). */
function monthlyPhoneSecondsSql(): string {
  return `(SELECT COALESCE(SUM(CASE WHEN settled_at IS NOT NULL THEN COALESCE(billed_seconds, 0) WHEN ${unsettledCallCountsSql()} THEN max_seconds ELSE 0 END), 0)
    FROM phone_calls WHERE user_id = ? AND month = ?)`;
}

async function usedPhoneSeconds(db: D1Database, userId: string, now: Date): Promise<number> {
  const row: { used: number } | null = await db
    .prepare(`SELECT ${monthlyPhoneSecondsSql()} AS used`)
    .bind(now.getTime(), userId, monthKey(now))
    .first<{ used: number }>();
  return row?.used ?? 0;
}

/** `GET /v1/phone`: whether the app shows the dialer, and the user's setup. */
export async function phoneStatus(db: D1Database, config: Config, userId: string, clientCountry: string | null, now: Date): Promise<PhoneStatus> {
  const phone: PhoneCallsConfig = config.phoneCalls;
  if (phone.policy === "off") {
    return {
      available: false,
      reason: "policy_off",
      countries: [],
      callerCountries: [],
      provider: null,
      consentVersion: phoneConsentVersion,
      consentAccepted: false,
      number: null,
      maxCallMinutes: 0,
      monthlyMinutes: 0,
      usedMinutes: 0,
      minutesByCountry: {},
    };
  }
  const [row, accepted, paid, used, spent]: [PhoneNumberRow | null, boolean, boolean, number, number] = await Promise.all([
    numberRow(db, userId),
    consentAccepted(db, userId),
    phonePaid(db, config, userId, now),
    usedPhoneSeconds(db, userId, now),
    spentPhoneMicroUsd(db, userId, now),
  ]);
  // The user's country: their verified number's, otherwise where they connect from (Cloudflare's IP country).
  const country: string | null = row?.status === "verified" ? row.country : clientCountry;
  const reason: PhoneStatus["reason"] = !allowedCountry(phone.callerCountries, country) ? "country_not_allowed" : paid ? null : "subscription_required";
  return {
    available: reason === null,
    reason,
    countries: phone.countries,
    callerCountries: phone.callerCountries,
    provider: "Twilio",
    consentVersion: phoneConsentVersion,
    consentAccepted: accepted,
    number: row === null ? null : { e164: row.e164, status: numberStatusOf(row, now) },
    maxCallMinutes: Math.floor(phone.maxCallSeconds / 60),
    monthlyMinutes: Math.floor(phone.monthlySeconds / 60),
    usedMinutes: Math.ceil(used / 60),
    minutesByCountry: Object.fromEntries(
      phone.countries.map((code: PhoneCountry): [PhoneCountry, number] => [
        code,
        // A call into the caller's own country that its carriers would block has no minutes.
        allowedCountry(phone.callerCountries, country) && callerIdBlockedInto(country, code)
          ? 0
          : Math.floor(callableSeconds(phone.monthlySeconds - used, phone.userMonthlySpendMicroUsd - spent, phone.microUsdPerMinute[code] ?? Number.MAX_SAFE_INTEGER) / 60),
      ]),
    ),
  };
}

/**
 * The longest call (whole minutes, in seconds) that fits `remainingSeconds` of call time and `remainingMicroUsd` of
 * spend at `microUsdPerMinute`, with the extra minute of ringing and notice every reservation carries
 * (`callEstimateMicroUsd`). Pure function.
 */
export function callableSeconds(remainingSeconds: number, remainingMicroUsd: number, microUsdPerMinute: number): number {
  const bySpend: number = Math.floor(remainingMicroUsd / microUsdPerMinute) - 1;
  return Math.max(0, Math.min(Math.floor(remainingSeconds / 60), bySpend)) * 60;
}

/** The user's settled and running phone spend this month (running calls count at their worst case). */
function monthlyPhoneSpendSql(): string {
  return `(SELECT COALESCE(SUM(CASE WHEN settled_at IS NOT NULL THEN COALESCE(cost_micro_usd, 0) WHEN ${unsettledCallCountsSql()} THEN estimated_micro_usd ELSE 0 END), 0)
    FROM phone_calls WHERE user_id = ? AND month = ?)`;
}

async function spentPhoneMicroUsd(db: D1Database, userId: string, now: Date): Promise<number> {
  const row: { spent: number } | null = await db
    .prepare(`SELECT ${monthlyPhoneSpendSql()} AS spent`)
    .bind(now.getTime(), userId, monthKey(now))
    .first<{ spent: number }>();
  return row?.spent ?? 0;
}

/** A pending verification past its window counts as failed. Pure function. */
function numberStatusOf(row: PhoneNumberRow, now: Date): PhoneNumberState["status"] {
  return row.status === "pending" && (row.pending_until ?? 0) <= now.getTime() ? "failed" : row.status;
}

/**
 * Whether the account pays for calls: a Stripe subscription that is `active` (not trialing, not past due in its grace
 * period) or an App Store subscription with access in a normal or prepaid period (not a free trial, intro or promotional
 * offer). Calls cost real money per minute, so an account that hasn't paid yet (a throwaway card in a trial) gets no
 * minutes. Pure function.
 */
export function phonePaidAccess(subscriptions: PaidSubscriptions, config: AccessConfig, now: Date): boolean {
  const stripe: boolean = subscriptions.stripe !== null && subscriptions.stripe.status === "active" && subscriptionAccess(subscriptions.stripe, now, config.pastDueGraceMs) === "active";
  const appStore: boolean =
    subscriptions.appStore !== null &&
    ["normal", "prepaid"].includes(subscriptions.appStore.periodType.toLowerCase()) &&
    appStoreAccess(subscriptions.appStore, config.appStore.acceptSandbox, now) === "active";
  return stripe || appStore;
}

async function phonePaid(db: D1Database, config: Config, userId: string, now: Date): Promise<boolean> {
  return phonePaidAccess(await paidSubscriptions(db, userId), config, now);
}

async function requireSubscriber(db: D1Database, config: Config, userId: string, now: Date): Promise<void> {
  if (!(await phonePaid(db, config, userId, now))) {
    throw new ApiError("subscription_required", "Calling from Gistsmith needs a subscription.");
  }
}

async function requireConsent(db: D1Database, userId: string): Promise<void> {
  if (!(await consentAccepted(db, userId))) {
    throw new ApiError("phone_consent_required", "Accept the call recording terms in the app first.");
  }
}

/** A callable number in an allowed country; otherwise `phone_number_invalid` or `phone_number_blocked`. Pure function. */
export function requireCallableNumber(countries: readonly PhoneCountry[], value: string): { readonly e164: string; readonly country: PhoneCountry } {
  const classified: NumberClass = classifyNumber(value);
  if (classified.kind === "invalid") {
    throw new ApiError("phone_number_invalid", "Enter the number in international format, for example +1 415 555 0100.");
  }
  if (classified.kind === "blocked") {
    throw new ApiError("phone_number_blocked", "Premium-rate, special and foreign numbers can't be called from Gistsmith.");
  }
  if (!countries.includes(classified.country)) {
    throw new ApiError("phone_number_blocked", "Numbers in this country can't be called from Gistsmith yet.");
  }
  return { e164: classified.e164, country: classified.country };
}

const consentSchema = z.strictObject({ version: z.number().int().positive() });
const numberSchema = z.strictObject({ number: z.string().min(2).max(20) });
const callSchema = z.strictObject({ to: z.string().min(2).max(20) });

/** `POST /v1/phone/consent`: records the opt-in to the current disclosure. */
async function acceptConsent(db: D1Database, request: Request, userId: string, now: Date): Promise<PhoneStatusConsent> {
  const body = await readJsonBody(request, consentSchema, smallBodyBytes);
  if (body.version !== phoneConsentVersion) {
    throw new ApiError("bad_request", `The current disclosure version is ${phoneConsentVersion}; update the app.`);
  }
  await db
    .prepare(
      `INSERT INTO phone_consents (user_id, version, accepted_at) VALUES (?, ?, ?)
       ON CONFLICT(user_id) DO UPDATE SET version = excluded.version, accepted_at = excluded.accepted_at`,
    )
    .bind(userId, body.version, now.getTime())
    .run();
  log("info", "phone_consent_accepted", { userId, version: body.version });
  return { consentVersion: phoneConsentVersion, consentAccepted: true };
}

/** `POST /v1/phone/consent` answer. */
interface PhoneStatusConsent {
  readonly consentVersion: number;
  readonly consentAccepted: boolean;
}

/** Queues a provider object for deletion by the scheduled cleanup. */
function purgeStatement(db: D1Database, kind: "caller_id" | "recording", sid: string, now: Date): D1PreparedStatement {
  return db.prepare("INSERT INTO phone_provider_purges (kind, provider_sid, created_at) VALUES (?, ?, ?)").bind(kind, sid, now.getTime());
}

/**
 * Starts the verification call, freeing the number first when it is a leftover caller ID of the provider account that
 * no account here holds (a deleted account, a failed cleanup): the new call proves ownership again.
 */
async function startVerificationCall(provider: VoiceProvider, e164: string, callbackUrl: string): Promise<CallerIdVerificationStart> {
  try {
    return await provider.startCallerIdVerification(e164, callbackUrl);
  } catch (error: unknown) {
    if (!(error instanceof CallerIdAlreadyRegisteredError)) {
      throw error;
    }
    const sid: string | null = await provider.callerIdSid(e164);
    if (sid !== null) {
      await provider.deleteCallerId(sid);
    }
    log("warn", "phone_caller_id_reclaimed", { number: maskedNumber(e164), found: sid !== null });
    return provider.startCallerIdVerification(e164, callbackUrl);
  }
}

/** Least charged for one verification call (a short outbound call to the user's number, about $0.02 to US/CA numbers). */
export const verificationCallMicroUsd: number = 50_000;
/** Minutes a verification call is charged for at the number's country price (Twilio calls from its US number). */
const verificationCallMinutes: number = 2;

/**
 * Worst-case cost of a verification call to a number of a country priced `microUsdPerMinute`: two minutes at that price,
 * at least `verificationCallMicroUsd` (a Finnish mobile called from Twilio's US number costs about $0.52 a minute).
 * Pure function.
 */
export function verificationCostMicroUsd(microUsdPerMinute: number): number {
  return Math.max(verificationCallMicroUsd, verificationCallMinutes * microUsdPerMinute);
}

/**
 * Claims one of the user's verification calls for today and charges its worst case to the day's spend, or refuses:
 * `phone_verification_limit` past `phoneVerificationsPerDay` (counted per account and day in
 * `phone_verification_days`, so removing the number doesn't reset it), `phone_capacity_reached` or
 * `spend_ceiling_reached` when the ceilings can't take the call. One statement claims the slot only while all three
 * hold. Returns the attempt number.
 */
async function claimVerificationCall(db: D1Database, phone: PhoneCallLimits, config: Config, userId: string, cost: number, now: Date): Promise<number> {
  const limits: readonly ReservationLimit[] = [phoneDailySpendLimit(phone.dailySpendCeilingMicroUsd, now), dailySpendLimit(config, "total", now)];
  const conditions: string = limits.map((limit: ReservationLimit): string => `(${limit.remainingSql}) >= ?`).join(" AND ");
  const day: string = dayKey(now);
  const claimed: { attempts: number } | null = await db
    .prepare(
      `INSERT INTO phone_verification_days (user_id, day, attempts) SELECT ?, ?, 1 WHERE ${conditions}
         AND (SELECT COALESCE(SUM(attempts), 0) FROM phone_verification_days WHERE user_id = ? AND day LIKE ?) < ?
       ON CONFLICT(user_id, day) DO UPDATE SET attempts = attempts + 1 WHERE attempts < ?
       RETURNING attempts`,
    )
    .bind(
      userId,
      day,
      ...limits.flatMap((limit: ReservationLimit) => [...limit.binds, cost]),
      userId,
      `${monthKey(now)}-%`,
      phoneVerificationsPerMonth,
      phoneVerificationsPerDay,
    )
    .first<{ attempts: number }>();
  if (claimed === null) {
    const remaining: number[] = await remainingOf(db, limits);
    const short: ReservationLimit | undefined = limits.find((_: ReservationLimit, index: number): boolean => (remaining[index] ?? 0) < cost);
    throw short?.error ?? new ApiError("phone_verification_limit", "Too many verification calls; try again tomorrow or next month.");
  }
  await db
    .prepare(
      `INSERT INTO daily_spend (day, micro_usd, phone_micro_usd) VALUES (?1, ?2, ?2)
       ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, phone_micro_usd = phone_micro_usd + excluded.phone_micro_usd`,
    )
    .bind(day, cost)
    .run();
  return claimed.attempts;
}

/**
 * `POST /v1/phone/number`: starts verifying the user's own number (the provider calls it; the user types the code). The
 * app's introduction names the provider before this step sends the number to it.
 * The number must be callable in an allowed country and not held by another account; at most
 * `phoneVerificationsPerDay` calls a day. A number already verified for this user answers without a call.
 */
async function startVerification(db: D1Database, active: ActivePhone, config: Config, request: Request, userId: string, now: Date): Promise<PhoneVerificationStarted | PhoneNumberState> {
  // The recording terms come after this step in the app; verifying places no call of the user's and records nothing.
  await requireSubscriber(db, config, userId, now);
  const body = await readJsonBody(request, numberSchema, smallBodyBytes);
  const number = requireCallableNumber(active.config.callerCountries, body.number);
  const existing: PhoneNumberRow | null = await numberRow(db, userId);
  if (existing !== null && existing.e164 === number.e164 && existing.status === "verified") {
    return { e164: existing.e164, status: "verified" };
  }
  const holder: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM phone_numbers WHERE e164 = ? AND user_id != ? AND (status = 'verified' OR (status = 'pending' AND pending_until > ?)) LIMIT 1")
    .bind(number.e164, userId, now.getTime())
    .first<{ user_id: string }>();
  if (holder !== null) {
    throw new ApiError("phone_number_in_use", "This number is already used by another Gistsmith account.");
  }
  const rate: number | undefined = active.config.microUsdPerMinute[number.country];
  if (rate === undefined) {
    throw new ApiError("phone_number_blocked", "Numbers in this country can't be verified yet.");
  }
  const attempt: number = await claimVerificationCall(db, active.config, config, userId, verificationCostMicroUsd(rate), now);
  const callbackUrl: string = `${new URL(request.url).origin}/v1/phone/webhooks/verification`;
  const started: CallerIdVerificationStart = await startVerificationCall(active.provider, number.e164, callbackUrl);
  const pendingUntil: number = now.getTime() + verificationWindowMs;
  // A replaced verified number stops being a caller ID of the provider account.
  const replaced: D1PreparedStatement[] =
    existing?.provider_sid !== null && existing?.provider_sid !== undefined ? [purgeStatement(db, "caller_id", existing.provider_sid, now)] : [];
  await db.batch([
    ...replaced,
    db
      .prepare(
        `INSERT INTO phone_numbers (user_id, e164, country, status, validation_call_sid, provider_sid, created_at, pending_until, verified_at)
         VALUES (?1, ?2, ?3, 'pending', ?4, NULL, ?5, ?6, NULL)
         ON CONFLICT(user_id) DO UPDATE SET e164 = excluded.e164, country = excluded.country, status = 'pending',
           validation_call_sid = excluded.validation_call_sid, provider_sid = NULL, created_at = excluded.created_at,
           pending_until = excluded.pending_until, verified_at = NULL`,
      )
      .bind(userId, number.e164, number.country, started.callSid, now.getTime(), pendingUntil),
  ]);
  log("info", "phone_verification_started", { userId, number: maskedNumber(number.e164), country: number.country, attempt });
  return { e164: number.e164, status: "pending", validationCode: started.validationCode, expiresAt: pendingUntil };
}

/**
 * `GET /v1/phone/number`: the verification state. A pending verification past its window without a result webhook is
 * settled by asking the provider whether the number became a caller ID.
 */
async function verificationState(db: D1Database, active: ActivePhone, userId: string, now: Date): Promise<PhoneNumberState | null> {
  const row: PhoneNumberRow | null = await numberRow(db, userId);
  if (row === null) {
    return null;
  }
  if (row.status !== "pending" || (row.pending_until ?? 0) > now.getTime()) {
    return { e164: row.e164, status: row.status };
  }
  const sid: string | null = await active.provider.callerIdSid(row.e164);
  const verified: boolean = sid !== null && (await markVerified(db, row, sid, now));
  if (!verified) {
    await db.prepare("UPDATE phone_numbers SET status = 'failed', pending_until = NULL WHERE user_id = ? AND status = 'pending'").bind(userId).run();
  }
  log("info", "phone_verification_settled_late", { userId, verified });
  return { e164: row.e164, status: verified ? "verified" : "failed" };
}

/** Marks a pending number verified unless another account verified it meanwhile (then the caller ID is purged). */
async function markVerified(db: D1Database, row: PhoneNumberRow, providerSid: string, now: Date): Promise<boolean> {
  const result: D1Result = await db
    .prepare(
      `UPDATE phone_numbers SET status = 'verified', provider_sid = ?, verified_at = ?, pending_until = NULL
       WHERE user_id = ? AND status = 'pending' AND e164 = ?
         AND NOT EXISTS (SELECT 1 FROM phone_numbers other WHERE other.e164 = ? AND other.status = 'verified' AND other.user_id != ?)`,
    )
    .bind(providerSid, now.getTime(), row.user_id, row.e164, row.e164, row.user_id)
    .run();
  if (result.meta.changes === 1) {
    log("info", "phone_number_verified", { userId: row.user_id, number: maskedNumber(row.e164) });
    return true;
  }
  return false;
}

/** `DELETE /v1/phone/number`: forgets the number; its caller ID is deleted at the provider by the cleanup. */
async function removeNumber(db: D1Database, userId: string, now: Date): Promise<{ readonly removed: boolean }> {
  const row: PhoneNumberRow | null = await numberRow(db, userId);
  if (row === null) {
    return { removed: false };
  }
  await db.batch([
    ...(row.provider_sid === null ? [] : [purgeStatement(db, "caller_id", row.provider_sid, now)]),
    db.prepare("DELETE FROM phone_numbers WHERE user_id = ?").bind(userId),
  ]);
  log("info", "phone_number_removed", { userId });
  return { removed: true };
}

/** The dialer's remaining spend today (micro USD): its ceiling − settled phone spend − running calls (`unsettledCallCountsSql`). */
function phoneDailySpendLimit(ceilingMicroUsd: number, now: Date): ReservationLimit {
  return {
    remainingSql: `? - (COALESCE((SELECT phone_micro_usd FROM daily_spend WHERE day = ?), 0)
      + (SELECT COALESCE(SUM(estimated_micro_usd), 0) FROM phone_calls WHERE day = ? AND settled_at IS NULL AND ${unsettledCallCountsSql()}))`,
    binds: [ceilingMicroUsd, dayKey(now), dayKey(now), now.getTime()],
    error: new ApiError("phone_capacity_reached", "Calling is busy today; try again tomorrow."),
  };
}

function monthlyPhoneSpendLimit(monthlyMicroUsd: number, userId: string, now: Date): ReservationLimit {
  return {
    remainingSql: `? - ${monthlyPhoneSpendSql()}`,
    binds: [monthlyMicroUsd, now.getTime(), userId, monthKey(now)],
    error: new ApiError("phone_minutes_exhausted", "You have used this month's calling allowance; it resets at the start of the month."),
  };
}

function monthlyPhoneLimit(monthlySeconds: number, userId: string, now: Date): ReservationLimit {
  return {
    remainingSql: `? - ${monthlyPhoneSecondsSql()}`,
    binds: [monthlySeconds, now.getTime(), userId, monthKey(now)],
    error: new ApiError("phone_minutes_exhausted", "You have used this month's call minutes; they reset at the start of the month."),
  };
}

function oneCallAtATimeLimit(userId: string, now: Date): ReservationLimit {
  return {
    remainingSql: "CASE WHEN EXISTS (SELECT 1 FROM phone_calls WHERE user_id = ? AND settled_at IS NULL AND reserved_until > ?) THEN 0 ELSE 1 END",
    binds: [userId, now.getTime()],
    error: new ApiError("phone_call_active", "Another call is still running on this account."),
  };
}

function dailyCallsLimit(userId: string, now: Date): ReservationLimit {
  return {
    remainingSql: "? - (SELECT COUNT(*) FROM phone_calls WHERE user_id = ? AND day = ?)",
    binds: [phoneCallsPerDay, userId, dayKey(now)],
    error: new ApiError("rate_limited", "Too many calls today; try again tomorrow."),
  };
}

/** A call's worst-case cost: its longest duration plus a minute of ringing and notice, at the country's price. Pure function. */
export function callEstimateMicroUsd(maxSeconds: number, microUsdPerMinute: number): number {
  return (Math.ceil(maxSeconds / 60) + 1) * microUsdPerMinute;
}

/** A finished call's cost: talk minutes (rounded up) plus a minute of ringing and notice, never above its estimate. Pure function. */
export function callCostMicroUsd(billedSeconds: number, microUsdPerMinute: number, estimatedMicroUsd: number): number {
  return Math.min(estimatedMicroUsd, (Math.ceil(billedSeconds / 60) + 1) * microUsdPerMinute);
}

/**
 * `POST /v1/phone/calls`: reserves a call to `to` and returns the Voice SDK token. The call's longest duration is the
 * smallest of `PHONE_CALL_MAX_MINUTES`, the user's remaining call minutes and the plan's remaining monthly minutes
 * (the recording becomes a meeting). One conditional insert checks the spend ceilings, the monthly minutes, one call
 * at a time and the daily call count together, so concurrent requests cannot pass them.
 */
async function reserveCall(db: D1Database, active: ActivePhone, config: Config, request: Request, userId: string, now: Date): Promise<PhoneCallReserved> {
  await requireSubscriber(db, config, userId, now);
  await requireConsent(db, userId);
  const body = await readJsonBody(request, callSchema, smallBodyBytes);
  const caller: PhoneNumberRow | null = await numberRow(db, userId);
  if (caller === null || caller.status !== "verified" || !allowedCountry(active.config.callerCountries, caller.country)) {
    throw new ApiError("phone_number_required", "Verify your own phone number before calling.");
  }
  const destination = requireCallableNumber(active.config.countries, body.to);
  if (destination.e164 === caller.e164) {
    throw new ApiError("phone_number_invalid", "You can't call your own number.");
  }
  if (callerIdBlockedInto(caller.country, destination.country)) {
    throw new ApiError("phone_number_blocked", "Carriers in this country block calls from abroad that show a number of the same country, so your number can't be the caller ID here.");
  }
  const rate: number | undefined = active.config.microUsdPerMinute[destination.country];
  if (rate === undefined) {
    throw new ApiError("phone_number_blocked", "Numbers in this country can't be called from Gistsmith yet.");
  }
  const [phoneUsed, phoneSpent, usage] = await Promise.all([usedPhoneSeconds(db, userId, now), spentPhoneMicroUsd(db, userId, now), monthlyUsage(db, userId, now)]);
  const planRemaining: number = config.monthlyCapSeconds - usage.usedSeconds;
  // The call minutes left, fewer where this country's price would use up the user's monthly spend first.
  const phoneRemaining: number = callableSeconds(active.config.monthlySeconds - phoneUsed, active.config.userMonthlySpendMicroUsd - phoneSpent, rate);
  const maxSeconds: number = Math.floor(Math.min(active.config.maxCallSeconds, phoneRemaining, planRemaining) / 60) * 60;
  if (maxSeconds < minimumCallSeconds) {
    throw planRemaining < phoneRemaining
      ? new ApiError("monthly_cap_reached", "This month's recording minutes are used up; they reset at the start of the month.")
      : new ApiError("phone_minutes_exhausted", "You have used this month's call minutes; they reset at the start of the month.");
  }
  const estimate: number = callEstimateMicroUsd(maxSeconds, rate);
  const checks: ReadonlyArray<{ readonly limit: ReservationLimit; readonly amount: number }> = [
    { limit: oneCallAtATimeLimit(userId, now), amount: 1 },
    { limit: dailyCallsLimit(userId, now), amount: 1 },
    { limit: monthlyPhoneLimit(active.config.monthlySeconds, userId, now), amount: maxSeconds },
    { limit: monthlyPhoneSpendLimit(active.config.userMonthlySpendMicroUsd, userId, now), amount: estimate },
    { limit: phoneDailySpendLimit(active.config.dailySpendCeilingMicroUsd, now), amount: estimate },
    { limit: dailySpendLimit(config, "total", now), amount: estimate },
  ];
  const callId: string = randomId();
  const conditions: string = checks.map((check): string => `(${check.limit.remainingSql}) >= ?`).join(" AND ");
  const inserted: D1Result = await db
    .prepare(
      `INSERT INTO phone_calls (id, user_id, status, destination, caller_id, country, max_seconds, micro_usd_per_minute, estimated_micro_usd,
         month, day, created_at, reserved_until)
       SELECT ?, ?, 'reserved', ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE ${conditions}`,
    )
    .bind(
      callId,
      userId,
      destination.e164,
      caller.e164,
      destination.country,
      maxSeconds,
      rate,
      estimate,
      monthKey(now),
      dayKey(now),
      now.getTime(),
      now.getTime() + connectWindowMs,
      ...checks.flatMap((check) => [...check.limit.binds, check.amount]),
    )
    .run();
  if (inserted.meta.changes !== 1) {
    const remaining: number[] = await remainingOf(db, checks.map((check) => check.limit));
    const failed = checks.find((check, index: number): boolean => (remaining[index] ?? 0) < check.amount);
    const error: ApiError = (failed ?? checks[0])?.limit.error ?? new ApiError("internal_error", "The call could not be reserved.");
    log("info", "phone_call_refused", { userId, code: error.code });
    throw error;
  }
  const accessToken: string = await active.provider.accessToken(callIdentity(callId), accessTokenTtlSeconds, now);
  log("info", "phone_call_reserved", { userId, callId, country: destination.country, maxSeconds, estimateMicroUsd: estimate });
  return { callId, accessToken, maxSeconds, country: destination.country, provider: active.provider.displayName };
}

async function callRow(db: D1Database, userId: string, callId: string): Promise<PhoneCallRow> {
  const row: PhoneCallRow | null = await db.prepare("SELECT * FROM phone_calls WHERE id = ? AND user_id = ?").bind(callId, userId).first<PhoneCallRow>();
  if (row === null) {
    throw new ApiError("not_found", "No such call.");
  }
  return row;
}

/** How long after a call settles its recording may still arrive (Twilio sends it within seconds). */
const recordingArrivalMs: number = 10 * 60_000;

/**
 * A call row as the app sees it. A call that never connected or ended unanswered (`failed`) has no recording (it starts
 * on answer); one whose recording hasn't come `recordingArrivalMs` after it settled has none either, so the app stops
 * waiting. Pure function.
 */
export function callStateOf(row: PhoneCallRow, now: Date): PhoneCallState {
  const neverConnected: boolean = row.status === "reserved" && row.reserved_until <= now.getTime();
  const overdue: boolean = neverConnected || (row.settled_at !== null && (row.status === "failed" || now.getTime() - row.settled_at > recordingArrivalMs));
  const recording: PhoneCallState["recording"] =
    row.recording_deleted_at !== null
      ? "deleted"
      : row.recording_status === "ready"
        ? "ready"
        : row.recording_status === "absent" || overdue
          ? "absent"
          : "pending";
  return { callId: row.id, status: row.status, billedSeconds: row.billed_seconds, recording };
}

/** `GET /v1/phone/calls/:id/recording`: the call's two-channel MP3, streamed from the provider. */
async function recordingResponse(db: D1Database, active: ActivePhone, userId: string, callId: string): Promise<Response> {
  const row: PhoneCallRow = await callRow(db, userId, callId);
  if (row.recording_status !== "ready" || row.recording_sid === null || row.recording_deleted_at !== null) {
    throw new ApiError("phone_recording_unavailable", "The call's recording isn't available.");
  }
  const upstream: Response = await active.provider.recording(row.recording_sid);
  log("info", "phone_recording_fetched", { userId, callId });
  return new Response(upstream.body, {
    status: 200,
    headers: { "content-type": "audio/mpeg", "content-disposition": `attachment; filename="call-${callId}.mp3"` },
  });
}

/** `DELETE /v1/phone/calls/:id/recording`: deletes the recording at the provider (repeating it is harmless). */
async function deleteRecording(db: D1Database, active: ActivePhone, userId: string, callId: string, now: Date): Promise<PhoneCallState> {
  const row: PhoneCallRow = await callRow(db, userId, callId);
  if (row.recording_sid !== null && row.recording_deleted_at === null) {
    await active.provider.deleteRecording(row.recording_sid);
    await recordingDeletedStatement(db, callId, row.recording_sid, now.getTime()).run();
    log("info", "phone_recording_deleted", { userId, callId });
  }
  return callStateOf(await callRow(db, userId, callId), now);
}

/** Marks the stored recording deleted at the provider (only that sid, once). */
function recordingDeletedStatement(db: D1Database, callId: string, recordingSid: string, nowMs: number): D1PreparedStatement {
  return db
    .prepare("UPDATE phone_calls SET recording_deleted_at = ? WHERE id = ? AND recording_sid = ? AND recording_deleted_at IS NULL")
    .bind(nowMs, callId, recordingSid);
}

const callPath: RegExp = /^\/v1\/phone\/calls\/([0-9a-f-]{36})$/;
const recordingPath: RegExp = /^\/v1\/phone\/calls\/([0-9a-f-]{36})\/recording$/;

/** The app's phone endpoints (signed-in user). */
export async function routePhone(request: Request, db: D1Database, platform: OutboundPlatform, config: Config, path: string, userId: string, clientCountry: string | null, now: Date): Promise<Response> {
  const method: string = request.method;
  if (path === "/v1/phone" && method === "GET") {
    return jsonResponse(200, await phoneStatus(db, config, userId, clientCountry, now));
  }
  const active: ActivePhone = requireActivePhone(platform, config);
  if (path === "/v1/phone/consent" && method === "POST") {
    return jsonResponse(200, await acceptConsent(db, request, userId, now));
  }
  if (path === "/v1/phone/number" && method === "POST") {
    return jsonResponse(200, await startVerification(db, active, config, request, userId, now));
  }
  if (path === "/v1/phone/number" && method === "GET") {
    return jsonResponse(200, { number: await verificationState(db, active, userId, now) });
  }
  if (path === "/v1/phone/number" && method === "DELETE") {
    return jsonResponse(200, await removeNumber(db, userId, now));
  }
  if (path === "/v1/phone/calls" && method === "POST") {
    return jsonResponse(201, await reserveCall(db, active, config, request, userId, now));
  }
  const call: RegExpExecArray | null = callPath.exec(path);
  if (call?.[1] !== undefined && method === "GET") {
    return jsonResponse(200, callStateOf(await callRow(db, userId, call[1]), now));
  }
  const recording: RegExpExecArray | null = recordingPath.exec(path);
  if (recording?.[1] !== undefined && method === "GET") {
    return recordingResponse(db, active, userId, recording[1]);
  }
  if (recording?.[1] !== undefined && method === "DELETE") {
    return jsonResponse(200, await deleteRecording(db, active, userId, recording[1], now));
  }
  throw new ApiError("not_found", "No such endpoint.");
}

// MARK: Webhooks (called by the provider, signed)

/** The webhook path prefix; these requests carry no bearer token. */
export const phoneWebhookPrefix: string = "/v1/phone/webhooks/";

/** A verified webhook: its form fields and the call id from the query (when the URL has one). */
interface Webhook {
  readonly fields: ReadonlyMap<string, string>;
  readonly callId: string | null;
}

/** Reads the form body and checks the provider's signature and account id; otherwise `403 forbidden`. */
async function verifiedWebhook(request: Request, provider: VoiceProvider): Promise<Webhook> {
  const body: string = new TextDecoder().decode(await readBodyBytes(request, webhookBodyBytes));
  const fields: Map<string, string> = new Map(new URLSearchParams(body));
  const valid: boolean = await provider.verifyWebhook(request.url, fields, request.headers.get("x-twilio-signature"));
  if (!valid || fields.get("AccountSid") !== provider.accountId) {
    log("warn", "phone_webhook_rejected", { path: new URL(request.url).pathname, signature: valid });
    throw new ApiError("forbidden", "Invalid webhook signature.");
  }
  const callId: string | null = new URL(request.url).searchParams.get("call");
  return { fields, callId: callId !== null && z.uuid().safeParse(callId).success ? callId : null };
}

/** Non-negative whole seconds from a webhook field; 0 when absent or malformed. Pure function. */
function secondsField(value: string | undefined): number {
  const parsed: number = Number(value ?? "");
  return Number.isFinite(parsed) && parsed > 0 ? Math.floor(parsed) : 0;
}

/**
 * Voice URL of the TwiML App: the app's leg asks what to do. Only a reserved, unexpired call whose SDK identity matches
 * is bridged, and only once; the destination and caller ID come from the reservation.
 */
async function voiceWebhook(db: D1Database, request: Request, provider: VoiceProvider, now: Date): Promise<Response> {
  const webhook: Webhook = await verifiedWebhook(request, provider);
  const callId: string = webhook.fields.get("callId") ?? "";
  const callSid: string = webhook.fields.get("CallSid") ?? "";
  if (!z.uuid().safeParse(callId).success || webhook.fields.get("From") !== `client:${callIdentity(callId)}` || callSid === "") {
    log("warn", "phone_voice_refused", { reason: "identity" });
    return twimlResponse(hangupTwiml());
  }
  const claimed: PhoneCallRow | null = await db
    .prepare(
      `UPDATE phone_calls SET status = '${callStatusAfter("connect")}', provider_call_sid = ?, reserved_until = ? + (max_seconds + ?) * 1000 + ?
       WHERE id = ? AND ${callSourceSql("connect")} AND reserved_until > ? RETURNING *`,
    )
    .bind(callSid, now.getTime(), ringTimeoutSeconds, settleSlackMs, callId, now.getTime())
    .first<PhoneCallRow>();
  if (claimed === null || claimed.destination === null || claimed.caller_id === null || !isPhoneCountry(claimed.country)) {
    log("warn", "phone_voice_refused", { reason: "not_reserved", callId });
    return twimlResponse(hangupTwiml());
  }
  const origin: string = new URL(request.url).origin;
  const query: string = `?call=${claimed.id}`;
  log("info", "phone_call_dialing", { userId: claimed.user_id, callId: claimed.id, country: claimed.country });
  return twimlResponse(
    dialTwiml({
      destination: claimed.destination,
      destinationCountry: claimed.country,
      callerId: claimed.caller_id,
      timeLimitSeconds: claimed.max_seconds,
      announcementUrl: `${origin}${phoneWebhookPrefix}announcement${query}`,
      recordingCallbackUrl: `${origin}${phoneWebhookPrefix}recording${query}`,
      dialActionUrl: `${origin}${phoneWebhookPrefix}dial-done${query}`,
    }),
  );
}

/** The callee's leg after answering: the recording notice, or a hang-up when the call isn't ours (fails closed). */
async function announcementWebhook(db: D1Database, request: Request, provider: VoiceProvider): Promise<Response> {
  const webhook: Webhook = await verifiedWebhook(request, provider);
  const row: { country: string } | null =
    webhook.callId === null
      ? null
      : await db.prepare("SELECT country FROM phone_calls WHERE id = ? AND status = 'dialing'").bind(webhook.callId).first<{ country: string }>();
  if (row === null || !isPhoneCountry(row.country)) {
    log("warn", "phone_announcement_refused", { callId: webhook.callId });
    return twimlResponse(hangupTwiml());
  }
  return twimlResponse(announcementTwiml(row.country));
}

/**
 * Settles a call once: the real cost goes to the day's spend (and the dialer's share), the row gets its billed seconds
 * and loses its numbers. Only a connected (`dialing`) call settles, and the spend is written only while the row is still
 * in that state (the update runs last and its row count says whether this callback settled it).
 */
async function settleCall(db: D1Database, callId: string, providerCallSid: string, event: Extract<PhoneCallEvent, "end_answered" | "end_unanswered">, billedSeconds: number, now: Date): Promise<boolean> {
  const row: PhoneCallRow | null = await db
    .prepare("SELECT * FROM phone_calls WHERE id = ? AND provider_call_sid = ?")
    .bind(callId, providerCallSid)
    .first<PhoneCallRow>();
  const status: PhoneCallStatus | null = row === null ? null : nextCallStatus(row.status, event);
  if (row === null || status === null || row.settled_at !== null) {
    return false;
  }
  const cost: number = callCostMicroUsd(billedSeconds, row.micro_usd_per_minute, row.estimated_micro_usd);
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `INSERT INTO daily_spend (day, micro_usd, phone_micro_usd)
         SELECT ?1, ?2, ?2 WHERE EXISTS (SELECT 1 FROM phone_calls WHERE id = ?3 AND ${callSourceSql(event)})
         ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, phone_micro_usd = phone_micro_usd + excluded.phone_micro_usd`,
      )
      .bind(row.day, cost, callId),
    db
      .prepare(
        `UPDATE phone_calls SET status = ?, billed_seconds = ?, cost_micro_usd = ?, settled_at = ?, destination = NULL, caller_id = NULL
         WHERE id = ? AND ${callSourceSql(event)}`,
      )
      .bind(status, billedSeconds, cost, now.getTime(), callId),
  ]);
  const settled: boolean = results[1]?.meta.changes === 1;
  if (settled) {
    log("info", "phone_call_settled", { userId: row.user_id, callId, status, billedSeconds, costMicroUsd: cost });
  }
  return settled;
}

/** `<Dial action>`: the bridged call ended; settles it with the callee leg's duration and ends the app's leg. */
async function dialDoneWebhook(db: D1Database, request: Request, provider: VoiceProvider, now: Date): Promise<Response> {
  const webhook: Webhook = await verifiedWebhook(request, provider);
  if (webhook.callId !== null) {
    const answered: boolean = webhook.fields.get("DialCallStatus") === "completed";
    const seconds: number = answered ? secondsField(webhook.fields.get("DialCallDuration")) : 0;
    await settleCall(db, webhook.callId, webhook.fields.get("CallSid") ?? "", answered ? "end_answered" : "end_unanswered", seconds, now);
  }
  return twimlResponse(hangupTwiml());
}

const terminalCallStatuses: ReadonlySet<string> = new Set(["completed", "busy", "failed", "no-answer", "canceled"]);

/**
 * Status callback of the TwiML App (the app's leg): settles a call the `<Dial action>` didn't (the app hung up first),
 * with the app leg's duration.
 */
async function callStatusWebhook(db: D1Database, request: Request, provider: VoiceProvider, now: Date): Promise<Response> {
  const webhook: Webhook = await verifiedWebhook(request, provider);
  const callSid: string = webhook.fields.get("CallSid") ?? "";
  const status: string = webhook.fields.get("CallStatus") ?? "";
  if (callSid !== "" && terminalCallStatuses.has(status)) {
    const row: { id: string } | null = await db.prepare("SELECT id FROM phone_calls WHERE provider_call_sid = ? AND settled_at IS NULL").bind(callSid).first<{ id: string }>();
    if (row !== null) {
      await settleCall(db, row.id, callSid, status === "completed" ? "end_answered" : "end_unanswered", secondsField(webhook.fields.get("CallDuration")), now);
    }
  }
  return twimlResponse(emptyTwiml());
}

/** The recording callback as an event of the recording state machine. Pure function. */
function recordingEventOf(fields: ReadonlyMap<string, string>): RecordingEvent {
  const raw: string = fields.get("RecordingSid") ?? "";
  const sid: string | null = /^RE[0-9a-f]{32}$/.test(raw) ? raw : null;
  return fields.get("RecordingStatus") === "completed" && sid !== null ? { kind: "ready", sid } : { kind: "absent", sid };
}

/** A recording callback stays unapplied after this many lost races (each one means another callback moved the row). */
const recordingWebhookAttempts: number = 3;

/**
 * Recording status callback: the recording is ready (or there is none). The transition comes from `recordingTransition`
 * and is stored only while the row is still in its source state; a lost race decides again on the new state. A known
 * recording is never replaced or cleared, and any other recording (a duplicate, a late one, one of a deleted call) is
 * queued for deletion at the provider.
 */
async function recordingWebhook(db: D1Database, request: Request, provider: VoiceProvider, now: Date): Promise<Response> {
  const webhook: Webhook = await verifiedWebhook(request, provider);
  const event: RecordingEvent = recordingEventOf(webhook.fields);
  const callSid: string = webhook.fields.get("CallSid") ?? "";
  const seconds: number = secondsField(webhook.fields.get("RecordingDuration"));
  const decision: RecordingDecision =
    webhook.callId === null ? orphanRecordingDecision(event) : await applyRecordingEvent(db, webhook.callId, callSid, event, seconds, recordingWebhookAttempts);
  if (decision.purge !== null) {
    await purgeStatement(db, "recording", decision.purge, now).run();
    log("warn", "phone_recording_purged", { callId: webhook.callId, stored: decision.store });
  }
  return twimlResponse(emptyTwiml());
}

/** Applies a recording event to the call's row with a conditional update; returns the decision that took effect. */
async function applyRecordingEvent(db: D1Database, callId: string, callSid: string, event: RecordingEvent, seconds: number, attempts: number): Promise<RecordingDecision> {
  const row: PhoneCallRow | null = await db.prepare("SELECT * FROM phone_calls WHERE id = ? AND provider_call_sid = ?").bind(callId, callSid).first<PhoneCallRow>();
  if (row === null) {
    return orphanRecordingDecision(event);
  }
  const decision: RecordingDecision = recordingTransition(recordingStateOf(row), event);
  if (decision.store === null) {
    return decision;
  }
  const result: D1Result = await db
    .prepare(`UPDATE phone_calls SET recording_status = ?, recording_sid = ?, recording_seconds = ? WHERE id = ? AND provider_call_sid = ? AND ${recordingSourceSql(decision.store)}`)
    .bind(decision.store, event.kind === "ready" ? event.sid : null, seconds, callId, callSid)
    .run();
  if (result.meta.changes === 1) {
    log("info", "phone_recording_stored", { userId: row.user_id, callId, recording: decision.store });
    return decision;
  }
  if (attempts <= 1) {
    throw new Error(`Phone recording callback for call ${callId} lost ${recordingWebhookAttempts} races; the provider retries it.`);
  }
  return applyRecordingEvent(db, callId, callSid, event, seconds, attempts - 1);
}

/** Caller ID verification result. A success for a number no pending row expects is purged (account deleted meanwhile). */
async function verificationWebhook(db: D1Database, request: Request, provider: VoiceProvider, now: Date): Promise<Response> {
  const webhook: Webhook = await verifiedWebhook(request, provider);
  const callSid: string = webhook.fields.get("CallSid") ?? "";
  const providerSid: string = webhook.fields.get("OutgoingCallerIdSid") ?? "";
  const success: boolean = webhook.fields.get("VerificationStatus") === "success";
  const row: PhoneNumberRow | null =
    callSid === "" ? null : await db.prepare("SELECT * FROM phone_numbers WHERE validation_call_sid = ? AND status = 'pending'").bind(callSid).first<PhoneNumberRow>();
  const verified: boolean = row !== null && success && /^PN[0-9a-f]{32}$/.test(providerSid) && (await markVerified(db, row, providerSid, now));
  if (row !== null && !verified) {
    await db.prepare("UPDATE phone_numbers SET status = 'failed', pending_until = NULL WHERE user_id = ? AND status = 'pending'").bind(row.user_id).run();
    log("info", "phone_verification_failed", { userId: row.user_id });
  }
  if (!verified && success && /^PN[0-9a-f]{32}$/.test(providerSid)) {
    await purgeStatement(db, "caller_id", providerSid, now).run();
  }
  return twimlResponse(emptyTwiml());
}

/** The provider's webhooks; `503 phone_unavailable` while the dialer is off. */
export async function routePhoneWebhook(request: Request, db: D1Database, platform: OutboundPlatform, config: Config, path: string, now: Date): Promise<Response> {
  const active: ActivePhone = requireActivePhone(platform, config);
  if (request.method !== "POST") {
    throw new ApiError("method_not_allowed", "Webhooks are POST requests.");
  }
  const name: string = path.slice(phoneWebhookPrefix.length);
  switch (name) {
    case "voice":
      return voiceWebhook(db, request, active.provider, now);
    case "announcement":
      return announcementWebhook(db, request, active.provider);
    case "dial-done":
      return dialDoneWebhook(db, request, active.provider, now);
    case "call-status":
      return callStatusWebhook(db, request, active.provider, now);
    case "recording":
      return recordingWebhook(db, request, active.provider, now);
    case "verification":
      return verificationWebhook(db, request, active.provider, now);
    default:
      throw new ApiError("not_found", "No such endpoint.");
  }
}

// MARK: Account deletion and scheduled cleanup

/**
 * Account deletion (same batch as the account's other rows, before `users`): a running call's worst case goes to its
 * day's spend (as for expired reservations), the account's recordings and caller ID are queued for deletion at the
 * provider, and the phone rows are deleted.
 */
export function phoneDeletionStatements(db: D1Database, userId: string, now: Date): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `INSERT INTO daily_spend (day, micro_usd, phone_micro_usd)
         SELECT day, SUM(estimated_micro_usd), SUM(estimated_micro_usd) FROM phone_calls WHERE user_id = ? AND settled_at IS NULL AND status = 'dialing' GROUP BY day
         ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, phone_micro_usd = phone_micro_usd + excluded.phone_micro_usd`,
      )
      .bind(userId),
    db
      .prepare(
        `INSERT INTO phone_provider_purges (kind, provider_sid, created_at)
         SELECT 'recording', recording_sid, ? FROM phone_calls WHERE user_id = ? AND recording_sid IS NOT NULL AND recording_deleted_at IS NULL`,
      )
      .bind(now.getTime(), userId),
    db
      .prepare("INSERT INTO phone_provider_purges (kind, provider_sid, created_at) SELECT 'caller_id', provider_sid, ? FROM phone_numbers WHERE user_id = ? AND provider_sid IS NOT NULL")
      .bind(now.getTime(), userId),
    db.prepare("DELETE FROM phone_calls WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM phone_numbers WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM phone_consents WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM phone_verification_days WHERE user_id = ?").bind(userId),
  ];
}

/** What the scheduled phone cleanup did. */
export interface PhoneCleanupReport {
  readonly expiredCalls: number;
  readonly recordingsDeleted: number;
  readonly purged: number;
  readonly oldCallsDeleted: number;
}

/** Provider deletions per scheduled run (each is one REST call). */
const purgeBatch: number = 100;

/**
 * Daily phone cleanup:
 * 1. calls whose reservation ran out unsettled: never connected ones are released at no cost; connected ones are
 *    charged their worst case (the provider's callbacks never came) and counted at their longest duration;
 * 2. recordings the app hasn't fetched within `phoneRecordingRetentionMs` and queued provider objects are deleted at the
 *    provider (only while the dialer is on, since the provider's secrets exist only then; the queue waits otherwise);
 * 3. settled calls older than `settledCallRetentionMs` are deleted.
 */
export async function phoneCleanup(db: D1Database, platform: OutboundPlatform, config: Config, now: Date): Promise<PhoneCleanupReport> {
  const nowMs: number = now.getTime();
  const expired: D1Result[] = await db.batch([
    db
      .prepare(
        `INSERT INTO daily_spend (day, micro_usd, phone_micro_usd)
         SELECT day, SUM(estimated_micro_usd), SUM(estimated_micro_usd) FROM phone_calls WHERE settled_at IS NULL AND reserved_until <= ? AND status = 'dialing' GROUP BY day
         ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + excluded.micro_usd, phone_micro_usd = phone_micro_usd + excluded.phone_micro_usd`,
      )
      .bind(nowMs),
    db
      .prepare(
        `UPDATE phone_calls SET
           cost_micro_usd = CASE WHEN status = 'dialing' THEN estimated_micro_usd ELSE 0 END,
           billed_seconds = CASE WHEN status = 'dialing' THEN max_seconds ELSE 0 END,
           status = '${callStatusAfter("expire")}', settled_at = ?, destination = NULL, caller_id = NULL
         WHERE ${callSourceSql("expire")} AND reserved_until <= ?`,
      )
      .bind(nowMs, nowMs),
  ]);
  const provider: VoiceProvider | null = phoneProviderOf(platform, config.phoneCalls);
  let recordingsDeleted: number = 0;
  let purged: number = 0;
  if (provider === null) {
    log("info", "phone_provider_cleanup_skipped", { reason: "phone_policy_off" });
  } else {
    const stale = await db
      .prepare(`SELECT id, recording_sid FROM phone_calls WHERE recording_sid IS NOT NULL AND recording_deleted_at IS NULL AND created_at <= ? LIMIT ${purgeBatch}`)
      .bind(nowMs - phoneRecordingRetentionMs)
      .all<{ id: string; recording_sid: string }>();
    for (const row of stale.results) {
      await provider.deleteRecording(row.recording_sid);
      await recordingDeletedStatement(db, row.id, row.recording_sid, nowMs).run();
      recordingsDeleted += 1;
    }
    const queue = await db
      .prepare(`SELECT id, kind, provider_sid FROM phone_provider_purges ORDER BY id LIMIT ${purgeBatch}`)
      .all<{ id: number; kind: "caller_id" | "recording"; provider_sid: string }>();
    for (const row of queue.results) {
      await (row.kind === "recording" ? provider.deleteRecording(row.provider_sid) : provider.deleteCallerId(row.provider_sid));
      await db.prepare("DELETE FROM phone_provider_purges WHERE id = ?").bind(row.id).run();
      purged += 1;
    }
  }
  const old: D1Result = await db
    .prepare("DELETE FROM phone_calls WHERE settled_at IS NOT NULL AND created_at <= ? AND (recording_sid IS NULL OR recording_deleted_at IS NOT NULL)")
    .bind(nowMs - settledCallRetentionMs)
    .run();
  // Verification counters only matter for their own day.
  await db.prepare("DELETE FROM phone_verification_days WHERE day < ?").bind(dayKey(now)).run();
  const report: PhoneCleanupReport = { expiredCalls: expired[1]?.meta.changes ?? 0, recordingsDeleted, purged, oldCallsDeleted: old.meta.changes };
  log("info", "phone_cleanup", { ...report });
  return report;
}
