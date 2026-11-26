import type { EmailConfig } from "../config";
import { log } from "../log";
import { dayKey, monthKey } from "../usage";
import { countEmailMetric } from "./counts";

/**
 * The hard sending cap (owner rule: never pay for email). Every email takes one unit of `email_quota` before it is
 * handed to the provider, counted whether the provider accepts it or not: at most `monthlyCap` per UTC month and
 * `dailyCap` per UTC day for all emails together, and of those at most `confirmMonthlyCap`/`confirmDailyCap` for
 * confirmation emails (so confirmations can't use up the lifecycle emails). One statement checks and takes the unit, so
 * concurrent senders can't overshoot. The first refusal of a day or a month logs `alert` once.
 */

/** Which emails a unit is for. */
export type EmailClass = "confirm" | "lifecycle";

/** Why a unit was refused. */
export type EmailCapRefusal = "day" | "month";

interface QuotaRow {
  readonly sent: number;
  readonly confirm_sent: number;
  readonly day: string;
  readonly day_sent: number;
  readonly day_confirm_sent: number;
}

/** The cap that refuses one more unit of `emailClass` given the row; null when one more fits. Pure function. */
export function emailCapRefusal(config: EmailConfig, row: QuotaRow | null, emailClass: EmailClass, day: string): EmailCapRefusal | null {
  const sent: number = row?.sent ?? 0;
  const confirmSent: number = row?.confirm_sent ?? 0;
  const daySent: number = row !== null && row.day === day ? row.day_sent : 0;
  const dayConfirmSent: number = row !== null && row.day === day ? row.day_confirm_sent : 0;
  if (sent >= config.monthlyCap || (emailClass === "confirm" && confirmSent >= config.confirmMonthlyCap)) {
    return "month";
  }
  if (daySent >= config.dailyCap || (emailClass === "confirm" && dayConfirmSent >= config.confirmDailyCap)) {
    return "day";
  }
  return null;
}

/** Takes one unit for an email of `emailClass`; the refusing cap when none is left (nothing is taken then). */
export async function takeEmailUnit(db: D1Database, config: EmailConfig, emailClass: EmailClass, now: Date): Promise<EmailCapRefusal | null> {
  const month: string = monthKey(now);
  const day: string = dayKey(now);
  const confirm: number = emailClass === "confirm" ? 1 : 0;
  // On conflict the SET and WHERE expressions read the stored row; `day` there is the stored day before this update.
  const result: D1Result = await db
    .prepare(
      `INSERT INTO email_quota (month, sent, confirm_sent, day, day_sent, day_confirm_sent) VALUES (?1, 1, ?3, ?2, 1, ?3)
       ON CONFLICT(month) DO UPDATE SET
         sent = sent + 1,
         confirm_sent = confirm_sent + ?3,
         day_sent = CASE WHEN day = ?2 THEN day_sent + 1 ELSE 1 END,
         day_confirm_sent = CASE WHEN day = ?2 THEN day_confirm_sent + ?3 ELSE ?3 END,
         day = ?2
       WHERE sent < ?4
         AND (day <> ?2 OR day_sent < ?5)
         AND (?3 = 0 OR (confirm_sent < ?6 AND (day <> ?2 OR day_confirm_sent < ?7)))`,
    )
    .bind(month, day, confirm, config.monthlyCap, config.dailyCap, config.confirmMonthlyCap, config.confirmDailyCap)
    .run();
  if (result.meta.changes === 1) {
    return null;
  }
  const row: QuotaRow | null = await db
    .prepare("SELECT sent, confirm_sent, day, day_sent, day_confirm_sent FROM email_quota WHERE month = ?")
    .bind(month)
    .first<QuotaRow>();
  const refusal: EmailCapRefusal | null = emailCapRefusal(config, row, emailClass, day);
  if (refusal === null) {
    // The statement refused, yet the row shows room: the row changed in between (a new day or a concurrent sender).
    // Refusing this one is safe; the next attempt reads the new row.
    log("warn", "email_cap_race", { emailClass });
    return "day";
  }
  await countEmailMetric(db, "cap_refused", 1, now);
  const marked: D1Result =
    refusal === "month"
      ? await db.prepare("UPDATE email_quota SET month_alerted = 1 WHERE month = ? AND month_alerted = 0").bind(month).run()
      : await db.prepare("UPDATE email_quota SET day_alerted = ?2 WHERE month = ?1 AND day_alerted IS NOT ?2").bind(month, day).run();
  if (marked.meta.changes === 1) {
    log("alert", "email_cap_reached", { cap: refusal, emailClass, month, day, monthlyCap: config.monthlyCap, dailyCap: config.dailyCap });
  }
  return refusal;
}
