import { z } from "zod";
import type { Config, EmailConfig } from "../config";
import { randomId, randomToken, sha256Hex } from "../crypto";
import { ApiError, ProviderApiError } from "../errors";
import { readJsonBody } from "../http";
import { log } from "../log";
import type { Platform } from "../platform";
import { dayKey } from "../usage";
import { normalizedEmailAddress, sameEmailAddress } from "./address";
import { type EmailLocale, emailLocaleOf, emailLocales } from "./copy";
import { countEmailMetric, emailMetricStatement } from "./counts";
import { type EmailFacts, confirmationEmail } from "./messages";
import { type DeliveryOutcome, deliverEmail } from "./send";
import { accountLimitKey, recipientLimitKey, verifiedUnsubscribeId } from "./signing";

/**
 * Opt-in lifecycle email: the account's subscription (spec docs/superpowers/specs/2026-11-26-lifecycle-email.md).
 * The server holds an address only for an account whose user typed it in the app and asked for these emails, and only
 * sends to it after the user clicked the confirmation link (double opt-in):
 * - `GET /v1/me/email`: whether the feature is offered to this account and the subscription's state;
 * - `PUT /v1/me/email {address, locale, consentVersion}`: stores the address as pending and sends the confirmation;
 *   the same pending address again resends it; a confirmed address keeps getting mail until a new one is confirmed;
 * - `DELETE /v1/me/email`: deletes the address at once (the app's switch);
 * - `POST /v1/email/confirm {token}` and `POST /v1/email/not-me {token}`: the site's click-through pages for the two
 *   links in the confirmation email;
 * - `POST /v1/email/unsubscribe?s=<id>.<signature>`: RFC 8058 one-click (from the mail provider) and the site's page.
 * Confirmation emails are limited per recipient (`recipientConfirmLimits`, across accounts, by an HMAC of the address)
 * and per account (`accountConfirmLimits`), and take their own share of the hard cap (`quota.ts`). Logs never carry an
 * address or a token.
 */

/** Version of the opt-in wording the apps show; raising it makes older apps' opt-ins fail with "update the app". */
export const emailConsentVersion: number = 1;

/** A confirmation link works this long; an unconfirmed address is deleted after it. */
export const emailConfirmWindowMs: number = 7 * 86_400_000;

const dayMs: number = 86_400_000;
const weekMs: number = 7 * dayMs;

/** Confirmation emails per window. */
export interface ConfirmLimits {
  readonly perDay: number;
  readonly perWeek: number;
}

/** One address gets at most one confirmation email a day and three a week, whoever asks. */
export const recipientConfirmLimits: ConfirmLimits = { perDay: 1, perWeek: 3 };

/** One account may ask for at most three confirmation emails a day and ten a week. */
export const accountConfirmLimits: ConfirmLimits = { perDay: 3, perWeek: 10 };

/** The subscription as `GET /v1/me/email` returns it. */
export interface EmailSubscriptionState {
  /** The opt-in is offered to this account (`EMAIL_SENDING.policy`, or the account is on its allowlist). */
  readonly available: boolean;
  readonly status: "off" | "pending" | "confirmed";
  /** The confirmed address; null until one is confirmed. */
  readonly address: string | null;
  /** An address waiting for its confirmation link; null otherwise. */
  readonly pendingAddress: string | null;
  readonly locale: EmailLocale | null;
  /** The opt-in wording version this server expects (`emailConsentVersion`). */
  readonly consentVersion: number;
}

/** A row of `email_subscriptions`. */
export interface SubscriptionRow {
  readonly user_id: string;
  readonly id: string;
  readonly email: string | null;
  readonly pending_email: string | null;
  readonly confirm_token_hash: string | null;
  readonly confirm_expires_at: number | null;
  readonly locale: string;
  readonly consent_version: number;
  readonly created_at: number;
  readonly pending_at: number | null;
  readonly confirmed_at: number | null;
}

interface LimitRow {
  readonly day_start: number;
  readonly day_sends: number;
  readonly week_start: number;
  readonly week_sends: number;
  readonly blocked_at: number | null;
}

/** Whether the opt-in is offered to (and lifecycle email sent to) this account. Pure function. */
export function emailAvailableTo(config: EmailConfig, userId: string): boolean {
  return config.policy === "on" || config.allowedUserIds.includes(userId);
}

/** Facts the emails state, from the configuration. Pure function. */
export function emailFactsOf(config: Config): EmailFacts {
  return {
    siteOrigin: config.siteOrigin,
    privacyContact: config.email.privacyContact,
    trial: { meetings: config.trialMeetings, days: Math.round(config.trialDurationMs / dayMs) },
    free: {
      notesPerMonth: config.freePlan.notesPerMonth,
      maxMeetingMinutes: config.freePlan.maxMeetingMinutes,
      asksPerMonth: config.freePlan.asksPerMonth,
    },
  };
}

/** The stored locale as a supported one (rows only ever hold supported values). Pure function. */
export function storedLocale(value: string): EmailLocale {
  const locale: EmailLocale | undefined = emailLocales.find((candidate: EmailLocale): boolean => candidate === value);
  if (locale === undefined) {
    throw new Error(`Unsupported stored email locale: ${value}`);
  }
  return locale;
}

/** The API view of a row. Pure function. */
export function emailStateOf(row: SubscriptionRow | null, available: boolean): EmailSubscriptionState {
  if (row === null) {
    return { available, status: "off", address: null, pendingAddress: null, locale: null, consentVersion: emailConsentVersion };
  }
  return {
    available,
    status: row.email !== null ? "confirmed" : "pending",
    address: row.email,
    pendingAddress: row.pending_email,
    locale: storedLocale(row.locale),
    consentVersion: emailConsentVersion,
  };
}

/** Whether one more confirmation email would break `limits` given the key's row. Pure function. */
export function confirmLimitReached(row: LimitRow | null, limits: ConfirmLimits, nowMs: number): boolean {
  if (row === null) {
    return false;
  }
  const daySends: number = row.day_start > nowMs - dayMs ? row.day_sends : 0;
  const weekSends: number = row.week_start > nowMs - weekMs ? row.week_sends : 0;
  return daySends >= limits.perDay || weekSends >= limits.perWeek;
}

async function subscriptionOf(db: D1Database, userId: string): Promise<SubscriptionRow | null> {
  return db.prepare("SELECT * FROM email_subscriptions WHERE user_id = ?").bind(userId).first<SubscriptionRow>();
}

async function limitRowOf(db: D1Database, key: string): Promise<LimitRow | null> {
  return db
    .prepare("SELECT day_start, day_sends, week_start, week_sends, blocked_at FROM email_recipient_limits WHERE key_hash = ?")
    .bind(key)
    .first<LimitRow>();
}

/** Counts one confirmation email against a limit key (fixed 24-hour and 7-day windows from their first send). */
function limitBumpStatement(db: D1Database, key: string, nowMs: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO email_recipient_limits (key_hash, day_start, day_sends, week_start, week_sends, last_sent_at) VALUES (?1, ?2, 1, ?2, 1, ?2)
       ON CONFLICT(key_hash) DO UPDATE SET
         day_sends = CASE WHEN day_start > ?2 - ?3 THEN day_sends + 1 ELSE 1 END,
         day_start = CASE WHEN day_start > ?2 - ?3 THEN day_start ELSE ?2 END,
         week_sends = CASE WHEN week_start > ?2 - ?4 THEN week_sends + 1 ELSE 1 END,
         week_start = CASE WHEN week_start > ?2 - ?4 THEN week_start ELSE ?2 END,
         last_sent_at = ?2`,
    )
    .bind(key, nowMs, dayMs, weekMs);
}

/** `GET /v1/me/email`. */
export async function readEmailSubscription(db: D1Database, config: EmailConfig, userId: string): Promise<EmailSubscriptionState> {
  return emailStateOf(await subscriptionOf(db, userId), emailAvailableTo(config, userId));
}

const optInBodySchema = z.strictObject({
  address: z.string().max(320),
  /** The app's language tag (`Bundle.preferredLocalizations.first`); unsupported ones get English. */
  locale: z.string().max(35),
  consentVersion: z.number().int().positive(),
});

/** Body limit of `PUT /v1/me/email`. */
const optInBodyMaxBytes: number = 1024;

/**
 * Puts the row back as it was before a confirmation email that didn't go out: no row → none; otherwise its earlier pending
 * address and still valid confirmation link come back (the confirmed address was never touched).
 */
function revertStatement(db: D1Database, userId: string, previous: SubscriptionRow | null): D1PreparedStatement {
  if (previous === null) {
    return db.prepare("DELETE FROM email_subscriptions WHERE user_id = ?").bind(userId);
  }
  return db
    .prepare(
      `UPDATE email_subscriptions SET pending_email = ?, confirm_token_hash = ?, confirm_expires_at = ?, pending_at = ?, locale = ?, consent_version = ?
       WHERE user_id = ?`,
    )
    .bind(previous.pending_email, previous.confirm_token_hash, previous.confirm_expires_at, previous.pending_at, previous.locale, previous.consent_version, userId);
}

/** The error for a confirmation email that didn't go out. Pure function. */
function confirmationFailure(outcome: Exclude<DeliveryOutcome, { kind: "sent" }>): ApiError {
  switch (outcome.kind) {
    case "cap":
      return new ApiError("email_quota_reached", "We can't send emails right now; try again later.");
    case "undeliverable":
      return new ApiError("email_undeliverable", "We couldn't deliver an email to this address; check it and try again.");
    case "failed":
    case "halted":
      return new ProviderApiError("email", "upstream_unavailable", "Sending the confirmation email failed; try again later.");
  }
}

/**
 * `PUT /v1/me/email`: stores the typed address as pending and sends the confirmation email. Nothing is sent and nothing
 * new is kept when the address is the confirmed one already (only the language is updated), when the feature is off for
 * the account (`email_unavailable`), when the recipient chose "This wasn't me" (`email_blocked`), over the per-recipient
 * or per-account limits (`rate_limited`), at the cap (`email_quota_reached`), or when the email couldn't go out.
 */
export async function requestEmailOptIn(
  db: D1Database,
  sender: SendEmail,
  platform: Platform,
  config: Config,
  request: Request,
  userId: string,
  now: Date,
): Promise<EmailSubscriptionState> {
  const body = await readJsonBody(request, optInBodySchema, optInBodyMaxBytes);
  if (!emailAvailableTo(config.email, userId)) {
    throw new ApiError("email_unavailable", "Email tips aren't available for this account.");
  }
  if (body.consentVersion !== emailConsentVersion) {
    throw new ApiError("bad_request", `The current email opt-in version is ${emailConsentVersion}; update the app.`);
  }
  const address: string | null = normalizedEmailAddress(body.address);
  if (address === null) {
    throw new ApiError("bad_request", "Enter a valid email address.");
  }
  const locale: EmailLocale = emailLocaleOf(body.locale);
  const previous: SubscriptionRow | null = await subscriptionOf(db, userId);
  if (previous?.email !== null && previous?.email !== undefined && sameEmailAddress(previous.email, address)) {
    // The confirmed address again: drop a pending change, keep the language up to date, send nothing.
    await db
      .prepare(
        `UPDATE email_subscriptions SET locale = ?, pending_email = NULL, confirm_token_hash = NULL, confirm_expires_at = NULL, pending_at = NULL
         WHERE user_id = ?`,
      )
      .bind(locale, userId)
      .run();
    return readEmailSubscription(db, config.email, userId);
  }
  const nowMs: number = now.getTime();
  const [recipientKey, accountKey]: [string, string] = await Promise.all([
    recipientLimitKey(config.secrets.trialHash, address),
    accountLimitKey(config.secrets.trialHash, userId),
  ]);
  const [recipientRow, accountRow]: [LimitRow | null, LimitRow | null] = await Promise.all([limitRowOf(db, recipientKey), limitRowOf(db, accountKey)]);
  if (recipientRow?.blocked_at !== null && recipientRow?.blocked_at !== undefined) {
    throw new ApiError("email_blocked", "This address asked us not to send it confirmation emails. Write to support to undo it.");
  }
  if (confirmLimitReached(recipientRow, recipientConfirmLimits, nowMs) || confirmLimitReached(accountRow, accountConfirmLimits, nowMs)) {
    throw new ApiError("rate_limited", "A confirmation email was sent recently; check your inbox or try again later.");
  }
  const token: string = randomToken(32);
  const tokenHash: string = await sha256Hex(token);
  const expiresAt: number = nowMs + emailConfirmWindowMs;
  await db
    .prepare(
      `INSERT INTO email_subscriptions (user_id, id, email, pending_email, confirm_token_hash, confirm_expires_at, locale, consent_version, created_at, pending_at)
       VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, ?8, ?8)
       ON CONFLICT(user_id) DO UPDATE SET pending_email = ?3, confirm_token_hash = ?4, confirm_expires_at = ?5, locale = ?6, consent_version = ?7, pending_at = ?8`,
    )
    .bind(userId, randomId(), address, tokenHash, expiresAt, locale, emailConsentVersion, nowMs)
    .run();
  let outcome: DeliveryOutcome;
  try {
    outcome = await deliverEmail(db, sender, config.email, platform, address, "confirm", confirmationEmail(locale, emailFactsOf(config), token), now);
  } catch (error: unknown) {
    await revertStatement(db, userId, previous).run();
    throw error;
  }
  if (outcome.kind !== "cap") {
    await db.batch([limitBumpStatement(db, recipientKey, nowMs), limitBumpStatement(db, accountKey, nowMs)]);
  }
  if (outcome.kind !== "sent") {
    await revertStatement(db, userId, previous).run();
    log("info", "email_opt_in_failed", { userId, outcome: outcome.kind });
    throw confirmationFailure(outcome);
  }
  await db.batch([emailMetricStatement(db, "opt_in", 1, now), emailMetricStatement(db, "sent_confirm", 1, now)]);
  log("info", "email_opt_in_pending", { userId, locale });
  return readEmailSubscription(db, config.email, userId);
}

/** `DELETE /v1/me/email`: deletes the address (and any pending one) at once. Works with the feature off too. */
export async function withdrawEmail(db: D1Database, config: EmailConfig, userId: string, now: Date): Promise<EmailSubscriptionState> {
  const result: D1Result = await db.prepare("DELETE FROM email_subscriptions WHERE user_id = ?").bind(userId).run();
  if (result.meta.changes > 0) {
    await countEmailMetric(db, "withdrawn", 1, now);
    log("info", "email_withdrawn", { userId });
  }
  return emailStateOf(null, emailAvailableTo(config, userId));
}

const tokenBodySchema = z.strictObject({ token: z.string().max(64) });
const tokenBodyMaxBytes: number = 256;
const tokenPattern: RegExp = /^[A-Za-z0-9_-]{43}$/;

const unknownTokenError = (): ApiError => new ApiError("not_found", "This link is no longer valid. Turn the emails on again in the app.");

async function tokenHashOf(request: Request): Promise<string> {
  const body = await readJsonBody(request, tokenBodySchema, tokenBodyMaxBytes);
  if (!tokenPattern.test(body.token)) {
    throw unknownTokenError();
  }
  return sha256Hex(body.token);
}

/**
 * `POST /v1/email/confirm {token}`: the pending address becomes the confirmed one; the token is used up. Unknown, used
 * and expired tokens get the same `not_found`. Returns the account (the caller sends the welcome email).
 */
export async function confirmEmail(db: D1Database, request: Request, now: Date): Promise<{ readonly userId: string }> {
  const tokenHash: string = await tokenHashOf(request);
  const nowMs: number = now.getTime();
  const row: { user_id: string } | null = await db
    .prepare(
      `UPDATE email_subscriptions
       SET email = pending_email, pending_email = NULL, confirm_token_hash = NULL, confirm_expires_at = NULL, pending_at = NULL, confirmed_at = ?1, checked_at = NULL
       WHERE confirm_token_hash = ?2 AND confirm_expires_at > ?1
       RETURNING user_id`,
    )
    .bind(nowMs, tokenHash)
    .first<{ user_id: string }>();
  if (row === null) {
    throw unknownTokenError();
  }
  await countEmailMetric(db, "confirmed", 1, now);
  log("info", "email_confirmed", { userId: row.user_id });
  return { userId: row.user_id };
}

/**
 * `POST /v1/email/not-me {token}`: the recipient of a confirmation email says they didn't ask. The pending address is
 * deleted and the recipient (by address HMAC) gets no more confirmation emails from any account (`email_blocked`).
 */
export async function rejectEmail(db: D1Database, config: Config, request: Request, now: Date): Promise<void> {
  const tokenHash: string = await tokenHashOf(request);
  const row: SubscriptionRow | null = await db
    .prepare("SELECT * FROM email_subscriptions WHERE confirm_token_hash = ?")
    .bind(tokenHash)
    .first<SubscriptionRow>();
  if (row === null || row.pending_email === null) {
    throw unknownTokenError();
  }
  const nowMs: number = now.getTime();
  const key: string = await recipientLimitKey(config.secrets.trialHash, row.pending_email);
  await db.batch([
    db
      .prepare(
        `INSERT INTO email_recipient_limits (key_hash, day_start, day_sends, week_start, week_sends, last_sent_at, blocked_at) VALUES (?1, ?2, 0, ?2, 0, ?2, ?2)
         ON CONFLICT(key_hash) DO UPDATE SET blocked_at = ?2`,
      )
      .bind(key, nowMs),
    row.email === null
      ? db.prepare("DELETE FROM email_subscriptions WHERE user_id = ?").bind(row.user_id)
      : db
          .prepare("UPDATE email_subscriptions SET pending_email = NULL, confirm_token_hash = NULL, confirm_expires_at = NULL, pending_at = NULL WHERE user_id = ?")
          .bind(row.user_id),
    emailMetricStatement(db, "not_me", 1, now),
  ]);
  log("info", "email_not_me", { userId: row.user_id });
}

/**
 * `POST /v1/email/unsubscribe?s=<id>.<signature>`: deletes the subscription the signed id names. Answers the same for a
 * subscription that is already gone (idempotent; one-click clients may retry). A badly signed link is `not_found`.
 */
export async function unsubscribeEmail(db: D1Database, config: Config, url: URL, now: Date): Promise<void> {
  const token: string = url.searchParams.get("s") ?? "";
  const id: string | null = await verifiedUnsubscribeId(config.secrets.trialHash, token);
  if (id === null) {
    throw new ApiError("not_found", "This unsubscribe link isn't valid. Turn the emails off in Gistsmith › Settings › Account.");
  }
  const result: D1Result = await db.prepare("DELETE FROM email_subscriptions WHERE id = ?").bind(id).run();
  if (result.meta.changes > 0) {
    await countEmailMetric(db, "unsubscribed", 1, now);
    log("info", "email_unsubscribed", { via: "link" });
  }
}

/**
 * `GET /v1/email/unsubscribe?s=…`: mail clients without RFC 8058 open the `List-Unsubscribe` address in a browser. A GET
 * never unsubscribes (link scanners open links too); it forwards to the site's page, which asks for one click. Only a
 * well-formed `s` is carried over. Pure function.
 */
export function unsubscribePageRedirect(siteOrigin: string, url: URL): Response {
  const token: string = url.searchParams.get("s") ?? "";
  const fragment: string = /^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/.test(token) ? `#${token}` : "";
  return new Response(null, { status: 303, headers: { location: `${siteOrigin}/email/unsubscribe${fragment}` } });
}

/** Account deletion: today's count and the deletion of the account's address and email history (before `users`). */
export function emailAccountDeletionStatements(db: D1Database, userId: string, now: Date): D1PreparedStatement[] {
  return [
    db
      .prepare(
        `INSERT INTO email_daily_counts (day, metric, count)
         SELECT ?1, 'account_deleted', 1 WHERE EXISTS (SELECT 1 FROM email_subscriptions WHERE user_id = ?2)
         ON CONFLICT(day, metric) DO UPDATE SET count = count + 1`,
      )
      .bind(dayKey(now), userId),
    db.prepare("DELETE FROM email_subscriptions WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM email_sends WHERE user_id = ?").bind(userId),
  ];
}
