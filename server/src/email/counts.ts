import { dayKey } from "../usage";

/**
 * Daily email totals for the admin page (`email_daily_counts`; not linked to anyone, kept 400 days). Metrics:
 * `opt_in` (an address stored as pending), `confirmed`, `withdrawn` (switched off in the app), `unsubscribed` (email link
 * or one-click), `not_me`, `expired` (unconfirmed for 7 days), `retired` (deleted by retention: nothing more to send or 60
 * days), `account_deleted`, `suppressed`/`undeliverable` (the provider refused the recipient), `failed` (provider error
 * after retries), `cap_refused`, `sent_<kind>` per email kind.
 */
export type EmailMetric =
  | "opt_in"
  | "confirmed"
  | "withdrawn"
  | "unsubscribed"
  | "not_me"
  | "expired"
  | "retired"
  | "account_deleted"
  | "suppressed"
  | "undeliverable"
  | "failed"
  | "cap_refused"
  | "sent_confirm"
  | "sent_welcome"
  | "sent_activation"
  | "sent_trial_ending"
  | "sent_free_plan";

/** Adds `amount` to today's count of `metric`. */
export function emailMetricStatement(db: D1Database, metric: EmailMetric, amount: number, now: Date): D1PreparedStatement {
  return db
    .prepare("INSERT INTO email_daily_counts (day, metric, count) VALUES (?, ?, ?) ON CONFLICT(day, metric) DO UPDATE SET count = count + excluded.count")
    .bind(dayKey(now), metric, amount);
}

/** Adds `amount` to today's count of `metric` (no-op for 0). */
export async function countEmailMetric(db: D1Database, metric: EmailMetric, amount: number, now: Date): Promise<void> {
  if (amount > 0) {
    await emailMetricStatement(db, metric, amount, now).run();
  }
}
