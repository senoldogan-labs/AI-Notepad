// Social proof on the home pages: quotes from real users and the App Store rating. Both are curated by hand and start
// empty, and an empty list (or a null rating) renders nothing (components/SocialProof.astro). Nothing here is ever
// written automatically, and nothing may be invented: every entry must come from a real person who agreed to it.
//
// Adding a quote
// 1. In the app's feedback form (Mac and iPhone) the user ticks "You may quote this on gistsmith.com with my first name"
//    and types a first name; the server stores that consent with the feedback (`reports.quote_first_name`).
// 2. Admin → Inbox → Feedback → "Quotable only" lists those reports. Open one and press "Copy as site quote": it copies
//    an entry for the list below (`testimonialSnippet`), with the text cut before any attached diagnostics.
// 3. Paste it into `testimonials`, set `language` to the page it belongs on ("en" for gistsmith.com, "fi" for /fi), and
//    only shorten the quote with "…" where words are left out; never reword it. Open a PR; the site deploys on merge.
//    Feedback rows are deleted after 180 days, so keep `reportId` and `consentedOn` as the record of consent. If the
//    person asks for removal, delete the entry.
//
// Updating the App Store rating
// Read the average and count from App Store Connect (App Analytics or Ratings and Reviews, all countries) and set
// `appStoreRating` with today's date. Leave it null until there are enough ratings to show.
import type { BadgeLanguage } from "./copy";

/** A quote from a user who gave consent in the app's feedback form. */
export interface Testimonial {
  /** The user's own words, as sent (shortened only with "…"). */
  readonly quote: string;
  /** The first name the user typed next to the consent box. */
  readonly firstName: string;
  /** The page the quote is shown on. */
  readonly language: BadgeLanguage;
  /** The feedback report the consent came with (admin inbox). */
  readonly reportId: string;
  /** The day the feedback with the consent was received (YYYY-MM-DD). */
  readonly consentedOn: string;
}

/** The App Store rating as last read from App Store Connect. */
export interface AppStoreRating {
  /** Average stars, 1–5. */
  readonly average: number;
  /** Number of ratings the average is based on. */
  readonly count: number;
  /** The day it was read (YYYY-MM-DD). */
  readonly asOf: string;
}

/** Owner-approved quotes. Starts empty: the strip is not shown until there is at least one for the page's language. */
export const testimonials: readonly Testimonial[] = [];

/** Owner-entered App Store rating; null shows nothing. */
export const appStoreRating: AppStoreRating | null = null;

/** Longest quote the strip shows (characters); longer ones must be shortened with "…". */
export const testimonialMaxChars: number = 280;

const firstNamePattern: RegExp = /^\p{L}[\p{L}\p{M}' .-]*$/u;
const dayPattern: RegExp = /^\d{4}-\d{2}-\d{2}$/;

/** Problems with one entry (empty when it is fine). Pure function. */
export function testimonialProblems(entry: Testimonial): readonly string[] {
  const problems: readonly (string | null)[] = [
    entry.quote.trim() === "" ? "quote is empty" : null,
    Array.from(entry.quote).length > testimonialMaxChars ? `quote is longer than ${testimonialMaxChars} characters` : null,
    firstNamePattern.test(entry.firstName) && Array.from(entry.firstName).length <= 40 ? null : "firstName is not a plain first name",
    entry.reportId.trim() === "" ? "reportId is empty" : null,
    dayPattern.test(entry.consentedOn) ? null : "consentedOn is not YYYY-MM-DD",
  ];
  return problems.filter((problem: string | null): problem is string => problem !== null);
}

/** Problems with the rating (empty when it is fine or null). Pure function. */
export function ratingProblems(rating: AppStoreRating | null): readonly string[] {
  if (rating === null) {
    return [];
  }
  const problems: readonly (string | null)[] = [
    rating.average >= 1 && rating.average <= 5 ? null : "average is not between 1 and 5",
    Number.isInteger(rating.count) && rating.count > 0 ? null : "count is not a positive whole number",
    dayPattern.test(rating.asOf) ? null : "asOf is not YYYY-MM-DD",
  ];
  return problems.filter((problem: string | null): problem is string => problem !== null);
}

/** The quotes for one page, in list order. Pure function. */
export function testimonialsFor(language: BadgeLanguage, list: readonly Testimonial[]): readonly Testimonial[] {
  return list.filter((entry: Testimonial): boolean => entry.language === language);
}

/** The rating as a line of text, e.g. "4.8 out of 5 on the App Store · 120 ratings". Pure function. */
export function ratingText(rating: AppStoreRating, language: BadgeLanguage): string {
  const locale: string = language === "fi" ? "fi-FI" : "en-US";
  const average: string = rating.average.toLocaleString(locale, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  const count: string = rating.count.toLocaleString(locale);
  return language === "fi"
    ? `${average}/5 App Storessa · ${count} arviota`
    : `${average} out of 5 on the App Store · ${count} rating${rating.count === 1 ? "" : "s"}`;
}

/**
 * The entry the admin inbox copies for a quotable report, ready to paste into `testimonials` (the owner still checks
 * the language and the text). Pure function.
 */
export function testimonialSnippet(reportId: string, firstName: string, quote: string, receivedAtMs: number): string {
  const entry: Testimonial = {
    quote,
    firstName,
    language: "en",
    reportId,
    consentedOn: new Date(receivedAtMs).toISOString().slice(0, 10),
  };
  return `${JSON.stringify(entry, null, 2).replace(/"(\w+)":/g, "$1:")},`;
}
