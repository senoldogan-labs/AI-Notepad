/**
 * Phone number rules of the in-app dialer (design: docs/superpowers/specs/2026-11-08-iphone-call-recording.md, phase 2).
 *
 * The server only accepts E.164 numbers (`+` and 7–15 digits). A destination is callable when it is a regular number of
 * a country in `PHONE_CALLS_COUNTRIES`; premium-rate and special-service ranges are refused, and anything this file
 * cannot place in a supported country is refused too. Emergency and short service numbers never reach the server: the
 * app opens them in the Phone app with `tel:` (Swift `phoneDialTarget`). The provider's geo permissions are the second
 * guard (see the spec's console steps).
 *
 * The lists are mirrored by the Swift client (`PhoneDialNumber.swift`, checked by `PhoneDialerParityTests`).
 */

/** Countries the dialer knows how to classify; `PHONE_CALLS_COUNTRIES` is a subset. */
export const phoneCountries = ["US", "CA", "FI", "TR"] as const;
export type PhoneCountry = (typeof phoneCountries)[number];

/** Canadian NANP area codes (geographic and Canada's non-geographic 600/622). Everything else under +1 is not Canada. */
export const canadianAreaCodes: readonly string[] = [
  "204", "226", "236", "249", "250", "257", "263", "289", "306", "343", "354", "365", "367", "368", "382", "403", "416",
  "418", "428", "431", "437", "438", "450", "460", "468", "474", "506", "514", "519", "548", "579", "581", "584", "587",
  "600", "604", "613", "622", "639", "647", "672", "683", "705", "709", "742", "753", "778", "780", "782", "807", "819",
  "825", "867", "873", "879", "902", "905", "942",
];

/**
 * NANP area codes outside the US 50 states and Canada (Caribbean countries and US territories): priced and regulated
 * separately and a classic toll-fraud target ("one ring" scams), so they are never callable.
 */
export const otherNanpAreaCodes: readonly string[] = [
  "242", "246", "264", "268", "284", "340", "345", "441", "473", "649", "658", "664", "670", "671", "684", "721", "758",
  "767", "784", "787", "809", "829", "849", "868", "869", "876", "939",
];

/** NANP premium-rate and special-service area codes (900, personal communications 5XX, 700, 710 government). */
export const nanpBlockedAreaCodes: readonly string[] = [
  "500", "521", "522", "523", "524", "525", "526", "527", "528", "529", "532", "533", "535", "538", "542", "543", "544",
  "545", "546", "547", "549", "550", "552", "553", "554", "556", "558", "566", "569", "577", "578", "588", "589", "700",
  "710", "900",
];

/** NANP exchange codes that are premium-rate in every area code. */
export const nanpBlockedExchanges: readonly string[] = ["976"];

/** National number prefixes (after the country code) refused outside NANP: premium rate and paid service numbers. */
export const blockedNationalPrefixes: Readonly<Record<Exclude<PhoneCountry, "US" | "CA">, readonly string[]>> = {
  FI: ["100", "106", "118", "200", "202", "203", "204", "209", "600", "700"],
  TR: ["444", "800", "822", "888", "900"],
};

/** Country calling codes and national number lengths of the non-NANP countries. */
const nationalNumbers: ReadonlyArray<{ readonly country: Exclude<PhoneCountry, "US" | "CA">; readonly code: string; readonly minLength: number; readonly maxLength: number }> = [
  { country: "FI", code: "358", minLength: 5, maxLength: 12 },
  { country: "TR", code: "90", minLength: 10, maxLength: 10 },
];

/** Result of classifying an E.164 number. */
export type NumberClass =
  | { readonly kind: "callable"; readonly e164: string; readonly country: PhoneCountry }
  | { readonly kind: "blocked"; readonly reason: "premium" | "unsupported" }
  | { readonly kind: "invalid" };

const e164Pattern: RegExp = /^\+[1-9][0-9]{6,14}$/;

/** Whether `value` is an E.164 number (`+` and 7–15 digits, no leading zero). Pure function. */
export function isE164(value: string): boolean {
  return e164Pattern.test(value);
}

/** Classifies a +1 number (10 national digits). Pure function. */
function classifyNanp(e164: string, national: string): NumberClass {
  const match: RegExpExecArray | null = /^([2-9][0-9]{2})([2-9][0-9]{2})([0-9]{4})$/.exec(national);
  const areaCode: string | undefined = match?.[1];
  const exchange: string | undefined = match?.[2];
  if (areaCode === undefined || exchange === undefined || areaCode.endsWith("11") || exchange.endsWith("11")) {
    return { kind: "invalid" };
  }
  if (nanpBlockedAreaCodes.includes(areaCode) || nanpBlockedExchanges.includes(exchange)) {
    return { kind: "blocked", reason: "premium" };
  }
  if (otherNanpAreaCodes.includes(areaCode)) {
    return { kind: "blocked", reason: "unsupported" };
  }
  return { kind: "callable", e164, country: canadianAreaCodes.includes(areaCode) ? "CA" : "US" };
}

/**
 * Classifies an E.164 number: a callable number with its country, a blocked one (premium-rate, special service, or a
 * country this dialer does not support) or an invalid one. US toll-free numbers (8XX) count as US. Pure function.
 */
export function classifyNumber(value: string): NumberClass {
  if (!isE164(value)) {
    return { kind: "invalid" };
  }
  const digits: string = value.slice(1);
  if (digits.startsWith("1")) {
    return digits.length === 11 ? classifyNanp(value, digits.slice(1)) : { kind: "invalid" };
  }
  const plan = nationalNumbers.find((candidate): boolean => digits.startsWith(candidate.code));
  if (plan === undefined) {
    return { kind: "blocked", reason: "unsupported" };
  }
  const national: string = digits.slice(plan.code.length);
  if (national.length < plan.minLength || national.length > plan.maxLength || national.startsWith("0")) {
    return { kind: "invalid" };
  }
  if (blockedNationalPrefixes[plan.country].some((prefix: string): boolean => national.startsWith(prefix))) {
    return { kind: "blocked", reason: "premium" };
  }
  return { kind: "callable", e164: value, country: plan.country };
}

/** Whether `value` is one of the supported country codes. Pure function. */
export function isPhoneCountry(value: string): value is PhoneCountry {
  return (phoneCountries as readonly string[]).includes(value);
}

/** The number with all but its first and last two characters masked, for logs (`+1…42`). Pure function. */
export function maskedNumber(e164: string): string {
  return `${e164.slice(0, 2)}…${e164.slice(-2)}`;
}
