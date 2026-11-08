// Abonelik katmanlarının saf yardımcıları (src/lib/plans.ts): katman adının okunması, saat ve toplantı süresi metinleri
// ve fiyat sayfasının Pro kartını yalnızca sunucu Pro'yu (ve Personal'i) sunduğunda açan satırlar. Derleme gerektirmez.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  type ProTextTemplates,
  type ProTextValues,
  type TierLimitsTemplates,
  type TierOffer,
  formatHourCount,
  meetingLengthText,
  pricingTierLines,
  proText,
  proTextAttributes,
  proTextValues,
  subscriptionTierOf,
} from "../src/lib/plans.ts";

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

test("page texts switch to their Pro variant only when the server offers Pro", () => {
  const variant: ProTextTemplates = {
    always: "10 or {proHours} hours a month ({proHours} on Pro)",
    meetingLengthDiffers: "{proHours} hours, {proMeetingLength} per meeting on Pro",
  };
  assert.equal(proTextValues([personal], "en-GB", templates.meetingLength), null);
  assert.equal(proTextValues([pro], "en-GB", templates.meetingLength), null);
  // Same meeting length as Personal: the plain variant, with every placeholder filled from the server's hours.
  const sameLength: ProTextValues | null = proTextValues([personal, { ...pro, monthlyHours: 20 }], "en-GB", templates.meetingLength);
  assert.ok(sameLength !== null);
  assert.equal(proText(variant, sameLength), "10 or 20 hours a month (20 on Pro)");
  // A text whose only variant is about meeting length stays as it is.
  assert.equal(proText({ always: null, meetingLengthDiffers: variant.meetingLengthDiffers }, sameLength), null);
  // A longer Pro meeting: the meeting-length variant wins, or the plain one when the text has none.
  const longer: ProTextValues | null = proTextValues([personal, { ...pro, meetingMaxMinutes: 360 }], "en-GB", templates.meetingLength);
  assert.ok(longer !== null);
  assert.equal(proText(variant, longer), "30 hours, 6 hours per meeting on Pro");
  assert.equal(proText({ always: variant.always, meetingLengthDiffers: null }, longer), "10 or 30 hours a month (30 on Pro)");
});

test("Pro templates become data attributes only when they exist", () => {
  assert.deepEqual(proTextAttributes(null), {});
  assert.deepEqual(proTextAttributes({ always: null, meetingLengthDiffers: null }), {});
  assert.deepEqual(proTextAttributes({ always: "a {proHours}", meetingLengthDiffers: null }), { "data-pro-text": "a {proHours}" });
  assert.deepEqual(proTextAttributes({ always: "a", meetingLengthDiffers: "b" }), { "data-pro-text": "a", "data-pro-meeting-text": "b" });
});
