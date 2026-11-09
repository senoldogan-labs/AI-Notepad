// Social proof list (src/testimonials.ts): every hand-added quote and the rating are well-formed, the admin inbox's
// copied entry pastes back as a valid entry, and the page filter and rating line behave. Needs no build.
import { strict as assert } from "node:assert";
import { test } from "node:test";
import {
  type Testimonial,
  appStoreRating,
  ratingProblems,
  ratingText,
  testimonialProblems,
  testimonialSnippet,
  testimonials,
  testimonialsFor,
} from "../src/testimonials.ts";

test("every listed quote and the rating are well-formed", () => {
  for (const entry of testimonials) {
    assert.deepEqual(testimonialProblems(entry), [], `${entry.reportId}: ${testimonialProblems(entry).join(", ")}`);
  }
  assert.deepEqual(ratingProblems(appStoreRating), []);
});

test("the copied admin entry is a valid entry once pasted", () => {
  const snippet: string = testimonialSnippet("r-1", "Aino", 'Notes are "spot on".', Date.UTC(2026, 10, 8, 12));
  assert.match(snippet, /^\{\n {2}quote: "Notes are \\"spot on\\"\.",\n {2}firstName: "Aino",\n {2}language: "en",\n {2}reportId: "r-1",\n {2}consentedOn: "2026-11-08"\n\},$/);
  const pasted: Testimonial = { quote: 'Notes are "spot on".', firstName: "Aino", language: "en", reportId: "r-1", consentedOn: "2026-11-08" };
  assert.deepEqual(testimonialProblems(pasted), []);
});

test("bad entries are reported; quotes are filtered by page language", () => {
  const bad: Testimonial = { quote: " ", firstName: "Aino <b>", language: "en", reportId: "", consentedOn: "8.11.2026" };
  assert.equal(testimonialProblems(bad).length, 4);
  assert.deepEqual(testimonialProblems({ ...bad, quote: "x".repeat(281), firstName: "Aino", reportId: "r", consentedOn: "2026-11-08" }), [
    "quote is longer than 280 characters",
  ]);
  const fi: Testimonial = { quote: "Hyvä", firstName: "Aino", language: "fi", reportId: "r", consentedOn: "2026-11-08" };
  assert.deepEqual(testimonialsFor("fi", [fi, { ...fi, language: "en" }]), [fi]);
  assert.deepEqual(testimonialsFor("en", []), []);
});

test("rating line in English and Finnish; bad ratings are reported", () => {
  assert.equal(ratingText({ average: 4.8, count: 1200, asOf: "2026-11-08" }, "en"), "4.8 out of 5 on the App Store · 1,200 ratings");
  assert.equal(ratingText({ average: 5, count: 1, asOf: "2026-11-08" }, "en"), "5.0 out of 5 on the App Store · 1 rating");
  assert.equal(ratingText({ average: 4.8, count: 12, asOf: "2026-11-08" }, "fi"), "4,8/5 App Storessa · 12 arviota");
  assert.equal(ratingProblems({ average: 6, count: 0, asOf: "today" }).length, 3);
  assert.deepEqual(ratingProblems(null), []);
});
