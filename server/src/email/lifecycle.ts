import { type ClientVersions, isFreePlanClient } from "../clientVersions";
import type { Config } from "../config";
import { type PaidSubscriptions, type TrialState, paidAccess, paidSubscriptions, trialMeetingsLeft, userTrialState } from "../entitlements";
import { freePlanAppliesTo, isFreePlanAccount } from "../freePlan";
import { log } from "../log";
import type { Platform } from "../platform";
import { dayKey, monthKey } from "../usage";
import type { EmailLocale } from "./copy";
import { type EmailMetric, countEmailMetric, emailMetricStatement } from "./counts";
import {
  type ComposedEmail,
  type EmailFacts,
  type LifecycleKind,
  type TrialEndingVariant,
  type UnsubscribeLinks,
  activationEmail,
  freePlanEmail,
  trialEndingEmail,
  welcomeEmail,
} from "./messages";
import { type DeliveryOutcome, deliverEmail } from "./send";
import { unsubscribeToken } from "./signing";
import { emailAvailableTo, emailConfirmWindowMs, emailFactsOf, storedLocale } from "./subscriptions";

/**
 * The lifecycle emails and the addresses' retention (hourly cron, `index.ts`; the welcome email also right after a
 * confirmation). Each kind goes at most once per account (`email_sends`, claimed before sending, so a run that dies
 * after handing an email over never repeats it); at most one per account per run, `welcome` first. What is due is
 * decided by `dueLifecycleEmail` from facts read just before sending:
 * - `welcome`: confirmed and not sent yet;
 * - nothing else to an account with paid access (and its address is deleted once the welcome is out);
 * - `free_plan`: the account is on the free plan now (`freePlan.isFreePlanAccount` with the last app build seen), not
 *   within 24 hours of `trial_ending`; after it, nothing more is due and the address is deleted;
 * - `trial_ending`: the trial runs and has one meeting or under 24 hours left;
 * - `activation`: no meeting at all, 48 hours to 7 days after confirming.
 * A moment that passed before the opt-in is not sent late (no `trial_ending` once the trial ended).
 *
 * Retention runs even with `EMAIL_SENDING.policy` off: unconfirmed addresses 7 days after they were stored, confirmed
 * ones 60 days after confirmation; limit rows, daily totals and quota months after their periods.
 */

/** The hourly Cron Trigger (wrangler.jsonc `triggers.crons`); `index.ts` runs only this step for it. */
export const lifecycleEmailCron: string = "41 * * * *";

const hourMs: number = 3_600_000;
const dayMs: number = 24 * hourMs;

/** A confirmed address is kept at most this long. */
export const confirmedAddressRetentionMs: number = 60 * dayMs;

/** Accounts looked at per run (round robin by `checked_at`): bounds the run's D1 queries. */
export const lifecycleVisitsPerRun: number = 50;

/** `activation` goes out in this window after confirmation, to an account without any meeting. */
export const activationWindow: { readonly fromMs: number; readonly untilMs: number } = { fromMs: 48 * hourMs, untilMs: 7 * dayMs };

/** "Under a day left" for `trial_ending`, and the quiet time between `trial_ending` and `free_plan`. */
const trialEndingLeadMs: number = dayMs;

/** What one account's state says about its lifecycle emails. */
export interface AccountEmailFacts {
  /** Kinds already claimed → when the provider accepted them (null while claimed only). */
  readonly sent: ReadonlyMap<LifecycleKind, number | null>;
  readonly confirmedAtMs: number;
  readonly paid: boolean;
  readonly trialStartedAtMs: number | null;
  readonly trialMeetingsLeft: number;
  /** Any meeting or free note ever (also before an earlier account of the same identity was deleted). */
  readonly hasMeeting: boolean;
  /** On the free plan now (`isFreePlanAccount`). */
  readonly freePlanAccount: boolean;
  /** Would move to the free plan when the trial ends (the plan applies and the last app knows it). */
  readonly freePlanNext: boolean;
}

/** The email due now. */
export type DueEmail =
  | { readonly kind: "welcome" | "activation" | "free_plan" }
  | { readonly kind: "trial_ending"; readonly variant: TrialEndingVariant };

/** The lifecycle email due for an account now, or null. Pure function. */
export function dueLifecycleEmail(facts: AccountEmailFacts, nowMs: number, trialDurationMs: number): DueEmail | null {
  if (!facts.sent.has("welcome")) {
    return { kind: "welcome" };
  }
  if (facts.paid) {
    return null;
  }
  if (facts.freePlanAccount) {
    if (facts.sent.has("free_plan")) {
      return null;
    }
    const trialEndingAt: number | null | undefined = facts.sent.get("trial_ending");
    if (trialEndingAt !== undefined && (trialEndingAt === null || nowMs - trialEndingAt < trialEndingLeadMs)) {
      return null;
    }
    return { kind: "free_plan" };
  }
  if (facts.trialStartedAtMs !== null && facts.trialMeetingsLeft > 0 && !facts.sent.has("trial_ending")) {
    const next: TrialEndingVariant["next"] = facts.freePlanNext ? "free" : "subscribe";
    if (facts.trialMeetingsLeft === 1) {
      return { kind: "trial_ending", variant: { reason: "one_meeting_left", next } };
    }
    if (facts.trialStartedAtMs + trialDurationMs - nowMs <= trialEndingLeadMs) {
      return { kind: "trial_ending", variant: { reason: "ends_within_day", next } };
    }
  }
  const sinceConfirmed: number = nowMs - facts.confirmedAtMs;
  if (!facts.hasMeeting && !facts.sent.has("activation") && sinceConfirmed >= activationWindow.fromMs && sinceConfirmed <= activationWindow.untilMs) {
    return { kind: "activation" };
  }
  return null;
}

/** Whether nothing more can be sent to the account, so its address can go: the welcome is out and it pays or got `free_plan`. Pure function. */
export function lifecycleFinished(facts: AccountEmailFacts): boolean {
  return facts.sent.get("welcome") !== undefined && facts.sent.get("welcome") !== null && (facts.paid || facts.sent.has("free_plan"));
}

/** A confirmed subscription the run may send to. */
interface Candidate {
  readonly user_id: string;
  readonly id: string;
  readonly email: string;
  readonly locale: string;
  readonly confirmed_at: number;
  readonly last_app_version: string | null;
  readonly last_os_version: string | null;
}

/** What the run should do after one account. */
type VisitResult = "sent" | "none" | "stop";

async function accountEmailFacts(db: D1Database, config: Config, candidate: Candidate, now: Date): Promise<AccountEmailFacts> {
  const [subscriptions, trial, sends, meeting]: [PaidSubscriptions, TrialState, D1Result<{ kind: LifecycleKind; sent_at: number | null }>, { has: number } | null] =
    await Promise.all([
      paidSubscriptions(db, candidate.user_id),
      userTrialState(db, candidate.user_id),
      db.prepare("SELECT kind, sent_at FROM email_sends WHERE user_id = ?").bind(candidate.user_id).all<{ kind: LifecycleKind; sent_at: number | null }>(),
      db
        .prepare("SELECT EXISTS (SELECT 1 FROM meeting_sessions WHERE user_id = ?1) OR EXISTS (SELECT 1 FROM free_note_grants WHERE user_id = ?1) AS has")
        .bind(candidate.user_id)
        .first<{ has: number }>(),
    ]);
  const access = paidAccess(subscriptions, config, now);
  const versions: ClientVersions | null =
    candidate.last_app_version === null ? null : { appVersion: candidate.last_app_version, osVersion: candidate.last_os_version ?? "" };
  const freePlanClient: boolean = isFreePlanClient(versions, config.freePlan.minBuild);
  return {
    sent: new Map(sends.results.map((row: { kind: LifecycleKind; sent_at: number | null }): [LifecycleKind, number | null] => [row.kind, row.sent_at])),
    confirmedAtMs: candidate.confirmed_at,
    paid: access !== "none",
    trialStartedAtMs: trial.startedAt,
    trialMeetingsLeft: trialMeetingsLeft(trial, config, now),
    hasMeeting: trial.used > 0 || (meeting?.has ?? 0) === 1,
    freePlanAccount: isFreePlanAccount(config, candidate.user_id, freePlanClient, access, trial, now),
    freePlanNext: freePlanAppliesTo(config.freePlan, candidate.user_id) && freePlanClient,
  };
}

/** The email for a due kind. Pure function. */
function composeDue(due: DueEmail, locale: EmailLocale, facts: EmailFacts, links: UnsubscribeLinks): ComposedEmail {
  switch (due.kind) {
    case "welcome":
      return welcomeEmail(locale, facts, links);
    case "activation":
      return activationEmail(locale, facts, links);
    case "trial_ending":
      return trialEndingEmail(locale, facts, links, due.variant);
    case "free_plan":
      return freePlanEmail(locale, facts, links);
  }
}

const sentMetric: Readonly<Record<LifecycleKind, EmailMetric>> = {
  welcome: "sent_welcome",
  activation: "sent_activation",
  trial_ending: "sent_trial_ending",
  free_plan: "sent_free_plan",
};

/** Sends the email due for one account, if any; deletes the address once nothing more can be sent. */
async function visitAccount(db: D1Database, sender: SendEmail, platform: Platform, config: Config, candidate: Candidate, now: Date): Promise<VisitResult> {
  const nowMs: number = now.getTime();
  await db.prepare("UPDATE email_subscriptions SET checked_at = ? WHERE user_id = ?").bind(nowMs, candidate.user_id).run();
  const facts: AccountEmailFacts = await accountEmailFacts(db, config, candidate, now);
  const due: DueEmail | null = dueLifecycleEmail(facts, nowMs, config.trialDurationMs);
  if (due === null) {
    if (lifecycleFinished(facts)) {
      await db.batch([
        db.prepare("DELETE FROM email_subscriptions WHERE user_id = ? AND id = ?").bind(candidate.user_id, candidate.id),
        emailMetricStatement(db, "retired", 1, now),
      ]);
      log("info", "email_retired", { userId: candidate.user_id, reason: "finished" });
    }
    return "none";
  }
  const claim: D1Result = await db
    .prepare("INSERT INTO email_sends (user_id, kind, claimed_at) VALUES (?, ?, ?) ON CONFLICT(user_id, kind) DO NOTHING")
    .bind(candidate.user_id, due.kind, nowMs)
    .run();
  if (claim.meta.changes === 0) {
    return "none";
  }
  const releaseClaim = (): D1PreparedStatement =>
    db.prepare("DELETE FROM email_sends WHERE user_id = ? AND kind = ? AND sent_at IS NULL").bind(candidate.user_id, due.kind);
  const oneClick: string = await unsubscribeToken(config.secrets.trialHash, candidate.id);
  const links: UnsubscribeLinks = {
    oneClickUrl: `${config.email.apiOrigin}/v1/email/unsubscribe?s=${oneClick}`,
    pageUrl: `${config.siteOrigin}/email/unsubscribe#${oneClick}`,
  };
  let outcome: DeliveryOutcome;
  try {
    const message: ComposedEmail = composeDue(due, storedLocale(candidate.locale), emailFactsOf(config), links);
    outcome = await deliverEmail(db, sender, config.email, platform, candidate.email, due.kind, message, now);
  } catch (error: unknown) {
    await releaseClaim().run();
    throw error;
  }
  switch (outcome.kind) {
    case "sent":
      await db.batch([
        db.prepare("UPDATE email_sends SET sent_at = ? WHERE user_id = ? AND kind = ?").bind(nowMs, candidate.user_id, due.kind),
        emailMetricStatement(db, sentMetric[due.kind], 1, now),
      ]);
      log("info", "email_lifecycle_sent", { userId: candidate.user_id, kind: due.kind });
      return "sent";
    case "undeliverable":
      // Bounced, complained or invalid: the address goes; the claim too, so a corrected opt-in gets this email.
      await db.batch([
        releaseClaim(),
        db.prepare("DELETE FROM email_subscriptions WHERE user_id = ? AND id = ?").bind(candidate.user_id, candidate.id),
        emailMetricStatement(db, outcome.code === "E_RECIPIENT_SUPPRESSED" ? "suppressed" : "undeliverable", 1, now),
      ]);
      return "none";
    case "failed":
      await db.batch([releaseClaim(), emailMetricStatement(db, "failed", 1, now)]);
      return "stop";
    case "cap":
    case "halted":
      await releaseClaim().run();
      return "stop";
  }
}

/** The candidate columns for an account. */
const candidateSelect: string = `SELECT s.user_id, s.id, s.email, s.locale, s.confirmed_at, u.last_app_version, u.last_os_version
  FROM email_subscriptions s JOIN users u ON u.id = s.user_id`;

/** Sends the welcome email to an account that just confirmed (the confirm endpoint, in the background). */
export async function sendWelcomeEmail(db: D1Database, sender: SendEmail, platform: Platform, config: Config, userId: string, now: Date): Promise<void> {
  if (!emailAvailableTo(config.email, userId)) {
    log("info", "email_welcome_skipped", { userId, reason: "email_policy_off" });
    return;
  }
  const candidate: Candidate | null = await db.prepare(`${candidateSelect} WHERE s.user_id = ? AND s.email IS NOT NULL`).bind(userId).first<Candidate>();
  if (candidate === null) {
    return;
  }
  await visitAccount(db, sender, platform, config, candidate, now);
}

/** Rows each retention step removed. */
export type EmailRetentionReport = Readonly<Record<"expired" | "expiredChange" | "retired" | "limits" | "blocks" | "dailyCounts" | "quotaMonths", number>>;

/** Deletes what the email feature may no longer keep. Runs with the feature off too. */
export async function emailRetention(db: D1Database, now: Date): Promise<EmailRetentionReport> {
  const nowMs: number = now.getTime();
  const pendingCutoff: number = nowMs - emailConfirmWindowMs;
  const results: D1Result[] = await db.batch([
    db.prepare("DELETE FROM email_subscriptions WHERE email IS NULL AND pending_at < ?").bind(pendingCutoff),
    db
      .prepare(
        `UPDATE email_subscriptions SET pending_email = NULL, confirm_token_hash = NULL, confirm_expires_at = NULL, pending_at = NULL
         WHERE email IS NOT NULL AND pending_at < ?`,
      )
      .bind(pendingCutoff),
    db.prepare("DELETE FROM email_subscriptions WHERE email IS NOT NULL AND confirmed_at < ?").bind(nowMs - confirmedAddressRetentionMs),
    db.prepare("DELETE FROM email_recipient_limits WHERE blocked_at IS NULL AND last_sent_at < ?").bind(nowMs - 7 * dayMs),
    db.prepare("DELETE FROM email_recipient_limits WHERE blocked_at < ?").bind(nowMs - 730 * dayMs),
    db.prepare("DELETE FROM email_daily_counts WHERE day < ?").bind(dayKey(new Date(nowMs - 400 * dayMs))),
    db.prepare("DELETE FROM email_quota WHERE month < ?").bind(monthKey(new Date(nowMs - 400 * dayMs))),
  ]);
  const changes = (index: number): number => results[index]?.meta.changes ?? 0;
  const report: EmailRetentionReport = {
    expired: changes(0),
    expiredChange: changes(1),
    retired: changes(2),
    limits: changes(3),
    blocks: changes(4),
    dailyCounts: changes(5),
    quotaMonths: changes(6),
  };
  await countEmailMetric(db, "expired", report.expired + report.expiredChange, now);
  await countEmailMetric(db, "retired", report.retired, now);
  return report;
}

/** What one hourly run did. */
export interface LifecycleRunReport {
  readonly retention: EmailRetentionReport;
  readonly visited: number;
  readonly sent: number;
  readonly stopped: boolean;
}

/**
 * The hourly email step: retention, then up to `EMAIL_SENDING.perRunCap` lifecycle emails over at most
 * `lifecycleVisitsPerRun` accounts (least recently checked first). Stops early at a cap or a provider problem.
 */
export async function runLifecycleEmail(db: D1Database, sender: SendEmail, platform: Platform, config: Config, now: Date): Promise<LifecycleRunReport> {
  const retention: EmailRetentionReport = await emailRetention(db, now);
  if (config.email.policy === "off" && config.email.allowedUserIds.length === 0) {
    log("info", "email_lifecycle_skipped", { reason: "email_policy_off" });
    return { retention, visited: 0, sent: 0, stopped: false };
  }
  // With the switch off only the allowlist is looked at, so other rows can't crowd it out of the run.
  const allowlist: readonly string[] = config.email.policy === "on" ? [] : config.email.allowedUserIds;
  const allowlistFilter: string = allowlist.length === 0 ? "" : ` AND s.user_id IN (${allowlist.map((): string => "?").join(", ")})`;
  const candidates: D1Result<Candidate> = await db
    .prepare(`${candidateSelect} WHERE s.email IS NOT NULL${allowlistFilter} ORDER BY s.checked_at IS NOT NULL, s.checked_at LIMIT ?`)
    .bind(...allowlist, lifecycleVisitsPerRun)
    .all<Candidate>();
  let visited: number = 0;
  let sent: number = 0;
  let stopped: boolean = false;
  for (const candidate of candidates.results) {
    if (sent >= config.email.perRunCap) {
      break;
    }
    if (!emailAvailableTo(config.email, candidate.user_id)) {
      continue;
    }
    visited += 1;
    const result: VisitResult = await visitAccount(db, sender, platform, config, candidate, now);
    if (result === "sent") {
      sent += 1;
    } else if (result === "stop") {
      stopped = true;
      break;
    }
  }
  log("info", "email_lifecycle_run", { visited, sent, stopped, expired: retention.expired, retired: retention.retired });
  return { retention, visited, sent, stopped };
}
