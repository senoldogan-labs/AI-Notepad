import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import {
  type SubscriptionLifecycle,
  type SubscriptionLifecycleColumns,
  hasActiveAccess,
  isEndedSubscription,
  isLiveStripeStatus,
  isRunningComplimentary,
  liveStripeStatusSql,
  runningComplimentarySql,
  subscriptionAccessSql,
  subscriptionEndedSql,
  subscriptionLifecycle,
  subscriptionRenewalGraceMs,
} from "../src/subscriptionLifecycle";

const nowMs: number = 1_800_000_000_000;
const hour: number = 3_600_000;
const graceMs: number = 7 * 24 * hour;

/** Bir satır ve beklenen durumu. */
interface Case {
  readonly name: string;
  readonly row: SubscriptionLifecycleColumns;
  readonly expected: SubscriptionLifecycle;
}

function row(status: string, currentPeriodEnd: number, cancelAt: number | null, pastDueSince: number | null, complimentary: boolean): SubscriptionLifecycleColumns {
  return { status, currentPeriodEnd, cancelAt, pastDueSince, complimentary };
}

const cases: readonly Case[] = [
  { name: "active, renewing, in period", row: row("active", nowMs + hour, null, null, false), expected: "active" },
  { name: "active, renewing, webhook late", row: row("active", nowMs - hour, null, null, false), expected: "active" },
  { name: "active, renewing, past renewal grace", row: row("active", nowMs - subscriptionRenewalGraceMs - 1, null, null, false), expected: "lapsed" },
  { name: "active, cancels at period end, ended", row: row("active", nowMs - hour, nowMs - hour, null, false), expected: "lapsed" },
  { name: "trialing in period", row: row("trialing", nowMs + hour, null, null, false), expected: "active" },
  { name: "past_due in grace", row: row("past_due", nowMs + hour, null, nowMs - hour, false), expected: "grace" },
  { name: "past_due past grace", row: row("past_due", nowMs + hour, null, nowMs - graceMs - 1, false), expected: "lapsed" },
  { name: "past_due without since", row: row("past_due", nowMs + hour, null, null, false), expected: "lapsed" },
  { name: "unpaid in period", row: row("unpaid", nowMs + hour, null, null, false), expected: "lapsed" },
  { name: "unpaid after period", row: row("unpaid", nowMs - hour, null, null, false), expected: "ended" },
  { name: "incomplete", row: row("incomplete", nowMs + hour, null, null, false), expected: "lapsed" },
  { name: "paused", row: row("paused", nowMs + hour, null, null, false), expected: "lapsed" },
  { name: "canceled", row: row("canceled", nowMs + hour, nowMs - hour, null, false), expected: "ended" },
  { name: "incomplete_expired", row: row("incomplete_expired", nowMs + hour, null, null, false), expected: "ended" },
  { name: "complimentary until later", row: row("active", nowMs + hour, nowMs + hour, null, true), expected: "active" },
  { name: "complimentary forever", row: row("active", nowMs + 1000 * hour, null, null, true), expected: "active" },
  { name: "complimentary revoked", row: row("active", nowMs, nowMs, null, true), expected: "ended" },
  { name: "complimentary expired", row: row("active", nowMs - hour, nowMs - hour, null, true), expected: "ended" },
];

/** Satırın SQL kararları (`subscriptionLifecycle.ts`'in SQL eşleri; tablo `s`, bağ ?6 = şimdi, ?7 = ek süre). */
interface SqlVerdict {
  readonly access: number;
  readonly ended: number;
  readonly live: number;
  readonly complimentary: number;
}

async function sqlVerdict(subscription: SubscriptionLifecycleColumns): Promise<SqlVerdict> {
  const verdict: SqlVerdict | null = await env.DB.prepare(
    `WITH s(status, current_period_end, cancel_at, past_due_since, complimentary) AS (VALUES (?1, ?2, ?3, ?4, ?5))
     SELECT COALESCE(${subscriptionAccessSql("s.", "?6", "?7")}, 0) AS access, ${subscriptionEndedSql("s.", "?6")} AS ended,
       ${liveStripeStatusSql("s.")} AS live, ${runningComplimentarySql("s.", "?6")} AS complimentary FROM s`,
  )
    .bind(
      subscription.status,
      subscription.currentPeriodEnd,
      subscription.cancelAt,
      subscription.pastDueSince,
      subscription.complimentary ? 1 : 0,
      nowMs,
      graceMs,
    )
    .first<SqlVerdict>();
  if (verdict === null) {
    throw new Error("The verdict query returned no row.");
  }
  return verdict;
}

describe("subscription lifecycle", () => {
  it.each(cases)("$name derives $expected in TS and the same verdicts in SQL", async ({ row: subscription, expected }: Case) => {
    expect(subscriptionLifecycle(subscription, nowMs, graceMs)).toBe(expected);
    const verdict: SqlVerdict = await sqlVerdict(subscription);
    expect(verdict.access === 1).toBe(hasActiveAccess(subscription, nowMs, graceMs));
    expect(verdict.ended === 1).toBe(isEndedSubscription(subscription, nowMs));
    expect(verdict.live === 1).toBe(isLiveStripeStatus(subscription.status));
    expect(verdict.complimentary === 1).toBe(isRunningComplimentary(subscription, nowMs));
  });

  it("never reports a row as both having access and ended", () => {
    for (const { row: subscription } of cases) {
      expect(hasActiveAccess(subscription, nowMs, graceMs) && isEndedSubscription(subscription, nowMs)).toBe(false);
    }
  });
});
