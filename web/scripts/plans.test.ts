// Abonelik katmanlarının saf yardımcıları (src/lib/plans.ts): katman adının okunması, saat ve toplantı süresi metinleri
// ve fiyat sayfasının Pro kartını yalnızca sunucu Pro'yu (ve Personal'i) sunduğunda açan satırlar. Derleme gerektirmez.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { type TierLimitsTemplates, type TierOffer, formatHourCount, meetingLengthText, pricingTierLines, subscriptionTierOf } from "../src/lib/plans.ts";

const templates: TierLimitsTemplates = {
  limits: "{hours} meeting hours a month, up to {meetingLength} per meeting",
  meetingLength: { hours: "{count} hours", minutes: "{count} minutes" },
};
const personal: TierOffer = { tier: "personal", monthlyHours: 10, meetingMaxMinutes: 240 };
const pro: TierOffer = { tier: "pro", monthlyHours: 30, meetingMaxMinutes: 240 };

test("only known tier names are read", () => {
  assert.equal(subscriptionTierOf("personal"), "personal");
  assert.equal(subscriptionTierOf("pro"), "pro");
  for (const value of [null, "", "Pro", "team", "monthly"]) {
    assert.equal(subscriptionTierOf(value), null, String(value));
  }
});

test("hours and meeting lengths are written from the server's numbers", () => {
  assert.equal(formatHourCount(30, "en-GB"), "30");
  assert.equal(formatHourCount(7.5, "en-GB"), "7.5");
  assert.equal(meetingLengthText(240, "en-GB", templates.meetingLength), "4 hours");
  assert.equal(meetingLengthText(90, "en-GB", templates.meetingLength), "90 minutes");
});

test("the pricing page shows Pro only when the server offers it", () => {
  assert.deepEqual(pricingTierLines([personal, pro], "en-GB", templates), {
    personal: "10 meeting hours a month, up to 4 hours per meeting",
    pro: "30 meeting hours a month, up to 4 hours per meeting",
  });
  assert.equal(pricingTierLines([personal], "en-GB", templates), null);
  assert.equal(pricingTierLines([], "en-GB", templates), null);
  // A response with Pro but without Personal is incomplete: Pro stays hidden.
  assert.equal(pricingTierLines([pro], "en-GB", templates), null);
});
