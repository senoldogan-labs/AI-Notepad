// Hesap sayfasının abonelik metinleri (src/lib/subscribe-copy.ts) ve fiyat yardımcıları (src/lib/plans.ts): tasarruf
// aşağı yuvarlanır ve uygulamalarla aynıdır, düğme ve yenileme koşulları seçili planın tutarını taşır, deneme metinleri
// yalnızca sunucunun deneme sayılarını kullanır. Derleme gerektirmez.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import type { Entitlements } from "../src/client/api.ts";
import { planState } from "../src/lib/plan-status.ts";
import { formatUsdCents, yearlyMonthlyEquivalentCents, yearlySavingsPercent } from "../src/lib/plans.ts";
import { tierPrices } from "../src/lib/tier-prices.ts";
import {
  type SubscribeTemplates,
  checkoutTerms,
  formatRefund,
  subscribeLabel,
  switchTierLabel,
  switchTierNote,
  trialHeadline,
  trialMeetingsUsed,
  winBackText,
  withdrawalDeadline,
} from "../src/lib/subscribe-copy.ts";

const templates: SubscribeTemplates = {
  billedTotal: { monthly: "{price}/month", yearly: "{price}/year" },
  period: { monthly: "month", yearly: "year" },
  subscribeCta: { personal: "Subscribe · {price}", pro: "Subscribe to Pro · {price}" },
  checkoutTerms: { lead: "{price} per {period}, renews automatically until you cancel.", rest: "Charged every {period}." },
  switchTier: { personal: "Switch to Personal · {price}", pro: "Switch to Pro · {price}" },
  switchTierNote: { personal: "Credit, then {price} per {period}.", pro: "Prorated difference today, then {price} per {period}." },
};
const headline = { none: "Every meeting, written up for you.", one: "1 meeting recorded.", other: "{count} meetings recorded." };
const winBack = { one: "You recorded 1 meeting.", other: "You recorded {count} meetings." };
const now: Date = new Date("2026-11-08T12:00:00Z");

function trial(left: number, endsAt: string | null): Entitlements {
  return {
    userId: "user-1",
    plan: "trial",
    trialMeetingsTotal: 3,
    trialDays: 7,
    trialMeetingsLeft: left,
    trialEndsAt: endsAt,
    monthlyHoursUsed: 0,
    monthlyHoursCap: 10,
    monthlyResetsAt: "2026-12-01T00:00:00.000Z",
    accountTokensUsed: 0,
    accountTokensCap: 1,
    accountTokensResetsAt: "2026-12-01T00:00:00.000Z",
    subscription: null,
    tier: null,
    offeredTiers: [],
  };
}

test("the yearly saving is rounded down, the same as in the apps", () => {
  assert.equal(yearlySavingsPercent(tierPrices.personal), 31);
  assert.equal(yearlySavingsPercent(tierPrices.pro), 30);
  assert.equal(yearlySavingsPercent({ monthlyCents: 1000, yearlyCents: 9000 }), 25);
  assert.equal(formatUsdCents(yearlyMonthlyEquivalentCents(tierPrices.personal)), "$4.08");
  assert.equal(formatUsdCents(yearlyMonthlyEquivalentCents(tierPrices.pro)), "$9.08");
  assert.equal(formatUsdCents(599), "$5.99");
  assert.equal(formatUsdCents(10900), "$109");
});

test("the subscribe button and the renewal terms carry the selected plan's billed total", () => {
  assert.equal(subscribeLabel("personal", "yearly", templates), "Subscribe · $49/year");
  assert.equal(subscribeLabel("pro", "monthly", templates), "Subscribe to Pro · $12.99/month");
  assert.deepEqual(checkoutTerms("personal", "monthly", templates), { lead: "$5.99 per month, renews automatically until you cancel.", rest: "Charged every month." });
  assert.equal(switchTierLabel("pro", "yearly", templates), "Switch to Pro · $109/year");
  assert.equal(switchTierNote("pro", "monthly", templates), "Prorated difference today, then $12.99 per month.");
  assert.equal(switchTierNote("personal", "yearly", templates), "Credit, then $49 per year.");
});

test("the trial headline shows a count only when meetings were recorded", () => {
  assert.equal(trialHeadline(trialMeetingsUsed(trial(3, null)), headline), headline.none);
  assert.equal(trialHeadline(trialMeetingsUsed(trial(2, "2026-11-12T00:00:00.000Z")), headline), "1 meeting recorded.");
  assert.equal(trialHeadline(trialMeetingsUsed(trial(1, "2026-11-12T00:00:00.000Z")), headline), "2 meetings recorded.");
});

test("win-back text appears only for an ended trial with recorded meetings and no subscription", () => {
  const usedUp: Entitlements = trial(0, "2026-11-12T00:00:00.000Z");
  assert.equal(winBackText(planState(usedUp, now), trialMeetingsUsed(usedUp), winBack), "You recorded 3 meetings.");
  const expiredAfterOne: Entitlements = trial(2, "2026-11-01T00:00:00.000Z");
  assert.equal(winBackText(planState(expiredAfterOne, now), trialMeetingsUsed(expiredAfterOne), winBack), "You recorded 1 meeting.");
  const expiredUnused: Entitlements = trial(3, "2026-11-01T00:00:00.000Z");
  assert.equal(winBackText(planState(expiredUnused, now), trialMeetingsUsed(expiredUnused), winBack), null);
  const running: Entitlements = trial(1, "2026-11-12T00:00:00.000Z");
  assert.equal(winBackText(planState(running, now), trialMeetingsUsed(running), winBack), null);
});

test("the withdrawal button shows only for a Stripe subscription inside its withdrawal window", () => {
  const subscribed = (source: "stripe" | "app_store", complimentary: boolean, withdrawableUntil: string | null): Entitlements => ({
    ...trial(0, null),
    plan: "subscription",
    tier: "personal",
    subscription: {
      source,
      status: "active",
      plan: "yearly",
      tier: "personal",
      currentPeriodEnd: "2027-11-01T00:00:00.000Z",
      cancelAt: null,
      complimentary,
      withdrawableUntil,
      withdrawalPending: false,
      access: "active",
      graceEndsAt: null,
    },
  });
  const until: string = "2026-11-15T00:00:00.000Z";
  assert.equal(withdrawalDeadline(planState(subscribed("stripe", false, until), now), now), until);
  assert.equal(withdrawalDeadline(planState(subscribed("stripe", false, "2026-11-08T11:00:00.000Z"), now), now), null);
  assert.equal(withdrawalDeadline(planState(subscribed("stripe", false, null), now), now), null);
  assert.equal(withdrawalDeadline(planState(subscribed("stripe", true, until), now), now), null);
  assert.equal(withdrawalDeadline(planState(subscribed("app_store", false, until), now), now), null);
  assert.equal(withdrawalDeadline(planState(trial(2, null), now), now), null);
});

test("refund amounts use the currency's own minor unit", () => {
  assert.equal(formatRefund(4512, "USD", "en-US"), "$45.12");
  assert.equal(formatRefund(500, "JPY", "en-US"), "¥500");
});
