// Hesap sayfasının plan durumu (src/lib/plan-status.ts). Süresi dolan deneme toplantı kalmış olsa da biter; ödemesi
// alınamamış abonelik deneme kalmış olsa da anlatılır; erişimi kapanmış başka abonelik yalnızca deneme bittiyse.
// Derleme gerektirmez.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import type { Entitlements, SubscriptionInfo } from "../src/client/api.ts";
import { type PlanState, hasSubscriptionAccess, planState, trialState } from "../src/lib/plan-status.ts";

const now: Date = new Date("2026-11-08T12:00:00Z");
const future: string = "2026-11-20T00:00:00.000Z";
const past: string = "2026-11-01T00:00:00.000Z";

function entitlements(trialMeetingsLeft: number, trialEndsAt: string | null, subscription: SubscriptionInfo | null): Entitlements {
  return {
    userId: "user-1",
    plan: subscription === null || subscription.access === "none" ? "trial" : "subscription",
    trialMeetingsTotal: 3,
    trialDays: 14,
    trialMeetingsLeft,
    trialEndsAt,
    monthlyHoursUsed: 0,
    monthlyHoursCap: 30,
    monthlyResetsAt: "2026-12-01T00:00:00.000Z",
    accountTokensUsed: 0,
    accountTokensCap: 1000,
    accountTokensResetsAt: "2026-12-01T00:00:00.000Z",
    subscription,
    tier: subscription === null || subscription.access === "none" ? null : subscription.tier,
    offeredTiers: [],
  };
}

interface SubscriptionFields {
  readonly access: "active" | "none";
  readonly status: string;
  readonly cancelAt: string | null;
  readonly complimentary: boolean;
}

function subscription(fields: SubscriptionFields): SubscriptionInfo {
  return { source: "stripe", plan: "yearly", tier: "personal", currentPeriodEnd: future, graceEndsAt: null, withdrawableUntil: null, ...fields };
}

const grace: SubscriptionInfo = {
  source: "stripe",
  status: "past_due",
  plan: "monthly",
  tier: "personal",
  withdrawableUntil: null,
  currentPeriodEnd: future,
  cancelAt: null,
  complimentary: false,
  access: "grace",
  graceEndsAt: future,
};

test("the trial is read against now", () => {
  assert.deepEqual(trialState(entitlements(3, null, null), now), { kind: "notStarted", left: 3, total: 3 });
  // Inherited trial meetings: not started yet, fewer than the total left.
  assert.deepEqual(trialState(entitlements(1, null, null), now), { kind: "notStarted", left: 1, total: 3 });
  assert.deepEqual(trialState(entitlements(2, future, null), now), { kind: "running", left: 2, total: 3, endsAt: future });
  assert.deepEqual(trialState(entitlements(2, past, null), now), { kind: "ended", reason: "timeExpired", total: 3 });
  assert.deepEqual(trialState(entitlements(0, future, null), now), { kind: "ended", reason: "meetingsUsed", total: 3 });
  assert.deepEqual(trialState(entitlements(0, null, null), now), { kind: "ended", reason: "meetingsUsed", total: 3 });
});

test("subscriptions with access come before the trial", () => {
  const active: SubscriptionInfo = subscription({ access: "active", status: "active", cancelAt: null, complimentary: false });
  const cases: readonly [SubscriptionInfo, PlanState["kind"]][] = [
    [active, "subscribed"],
    [subscription({ access: "active", status: "active", cancelAt: future, complimentary: false }), "ending"],
    [subscription({ access: "active", status: "active", cancelAt: future, complimentary: true }), "complimentary"],
    [grace, "grace"],
  ];
  for (const [info, kind] of cases) {
    const state: PlanState = planState(entitlements(3, null, info), now);
    assert.equal(state.kind, kind);
    assert.equal(hasSubscriptionAccess(state), true, kind);
  }
});

test("a lapsed subscription is described only once the trial has ended", () => {
  const lapsed: SubscriptionInfo = subscription({ access: "none", status: "canceled", cancelAt: past, complimentary: false });
  assert.deepEqual(planState(entitlements(2, future, lapsed), now), { kind: "trial", trial: { kind: "running", left: 2, total: 3, endsAt: future } });
  assert.equal(planState(entitlements(2, past, lapsed), now).kind, "expired");
  assert.equal(planState(entitlements(0, future, lapsed), now).kind, "expired");
  const unpaid: SubscriptionInfo = subscription({ access: "none", status: "unpaid", cancelAt: null, complimentary: false });
  assert.equal(planState(entitlements(0, past, unpaid), now).kind, "paymentOverdue");
  // Subscribed without using the trial: the trial is still unused, but the overdue payment is what the user must see.
  assert.deepEqual(planState(entitlements(3, null, unpaid), now), { kind: "paymentOverdue", subscription: unpaid, trial: { kind: "notStarted", left: 3, total: 3 } });
  const comp: SubscriptionInfo = subscription({ access: "none", status: "canceled", cancelAt: past, complimentary: true });
  assert.equal(planState(entitlements(0, past, comp), now).kind, "complimentaryEnded");
  for (const info of [lapsed, unpaid, comp]) {
    assert.equal(hasSubscriptionAccess(planState(entitlements(0, past, info), now)), false);
  }
});

test("a trial that ran out of time is ended even when the server still counted meetings", () => {
  assert.deepEqual(planState(entitlements(2, past, null), now), { kind: "trial", trial: { kind: "ended", reason: "timeExpired", total: 3 } });
});
