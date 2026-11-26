// Ücretsiz planın saf yardımcıları (src/lib/free-copy.ts, src/lib/plans.ts): sunucunun sayılarından metin değerleri,
// kalıpların doldurulması ve `data-free-slot` adlarının okunması. Derleme gerektirmez.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import { type FreeValues, fillFree, freeCard, freeTexts, freeValues } from "../src/lib/free-copy.ts";
import { type FreePlanOffer, freeSlotAttributes, freeTextSlotOf } from "../src/lib/plans.ts";

const offer: FreePlanOffer = { notesPerMonth: 4, maxMeetingMinutes: 45, asksPerMonth: 5 };

test("the free plan's numbers come from the server's offer", () => {
  const values: FreeValues = freeValues(offer, "en-GB");
  assert.deepEqual(values, { notes: "4 AI notes", length: "45 minutes", asks: "5 Ask questions" });
  assert.deepEqual(freeValues({ notesPerMonth: 1, maxMeetingMinutes: 60, asksPerMonth: 1 }, "en-GB"), { notes: "1 AI note", length: "1 hour", asks: "1 Ask question" });
});

test("every template is filled and none keeps a placeholder or a hard-coded limit", () => {
  const values: FreeValues = freeValues({ notesPerMonth: 7, maxMeetingMinutes: 30, asksPerMonth: 9 }, "en-GB");
  const texts: string[] = [...Object.values(freeTexts), ...freeCard.features, freeCard.upgrade, freeCard.requirements, freeCard.detail];
  for (const template of texts) {
    const text: string = fillFree(template, values);
    assert.doesNotMatch(text, /\{(notes|length|asks)\}/, text);
    assert.doesNotMatch(text, /\b(4 AI notes|45 minutes|5 Ask questions)\b/, `sabit sayı: ${text}`);
  }
  assert.match(fillFree(freeCard.features[1] ?? "", values), /^7 AI notes a month, for meetings up to 30 minutes$/);
});

test("the free plan is never called a trial", () => {
  const texts: string[] = [freeCard.name, freeCard.detail, freeCard.upgrade, ...freeCard.features];
  for (const text of texts) {
    assert.doesNotMatch(text.replace("free trial", ""), /trial/i, text);
  }
});

test("only known free slots are read", () => {
  assert.equal(freeTextSlotOf("homeTrial"), "homeTrial");
  assert.equal(freeTextSlotOf("compareFree"), "compareFree");
  for (const value of [undefined, "", "hoursText", "Free"]) {
    assert.equal(freeTextSlotOf(value), null, String(value));
  }
  assert.deepEqual(freeSlotAttributes("pricingTrialEnd"), { "data-free-slot": "pricingTrialEnd" });
  assert.deepEqual(freeSlotAttributes(null), {});
});
