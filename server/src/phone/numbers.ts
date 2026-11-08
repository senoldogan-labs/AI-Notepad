/**
 * Phone number rules of the in-app dialer (design: docs/superpowers/specs/2026-11-08-iphone-call-recording.md, phase 2).
 *
 * The server only accepts E.164 numbers (`+` and 7–15 digits). A destination is callable when it is a regular number of
 * a country in `PHONE_CALLS_COUNTRIES`; premium-rate and special-service ranges are refused, and anything this file
 * cannot place in a supported country is refused too. Emergency and short service numbers never reach the server: the
 * app opens them in the Phone app with `tel:` (Swift `phoneDialTarget`). The provider's geo permissions are the second
 * guard (see the spec's console steps).
 *
 * Outside NANP a national number is callable only when it starts with one of its country's regular (mobile or
 * geographic) prefixes and none of its blocked ones: an allow-list, so a range nobody listed (new premium or
 * machine-to-machine ranges, international revenue share fraud targets) is refused by default. Adding a country takes
 * its regulator's numbering plan, its rule on caller IDs from abroad (`domesticCallerIdBlocked`), a recording notice
 * (`twiml.ts`) and a price (`PHONE_USD_PER_MINUTE`); the spec's country table records the sources.
 *
 * The lists are mirrored by the Swift client (`PhoneDialNumber.swift`, checked by `PhoneDialerParityTests`).
 */

/** Countries the dialer knows how to classify; `PHONE_CALLS_COUNTRIES` and `PHONE_CALLER_COUNTRIES` are subsets. */
export const phoneCountries = ["US", "CA", "FI", "GB", "TR"] as const;
export type PhoneCountry = (typeof phoneCountries)[number];

/** Canadian geographic NANP area codes. Everything else under +1 is not Canada. */
export const canadianAreaCodes: readonly string[] = [
  "204", "226", "236", "249", "250", "257", "263", "289", "306", "343", "354", "365", "367", "368", "382", "403", "416",
  "418", "428", "431", "437", "438", "450", "460", "468", "474", "506", "514", "519", "548", "579", "581", "584", "587",
  "604", "613", "639", "647", "672", "683", "705", "709", "742", "753", "778", "780", "782", "807", "819",
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

/**
 * NANP premium-rate and special-service area codes (900, personal communications 5XX, 700, 710 government) and Canada's
 * non-geographic 600/622 (machine and satellite services with unknown rates).
 */
export const nanpBlockedAreaCodes: readonly string[] = [
  "500", "521", "522", "523", "524", "525", "526", "527", "528", "529", "532", "533", "535", "538", "542", "543", "544",
  "545", "546", "547", "549", "550", "552", "553", "554", "556", "558", "566", "569", "577", "578", "588", "589", "600",
  "622", "700", "710", "900",
];

/** NANP exchange codes that are premium-rate in every area code. */
export const nanpBlockedExchanges: readonly string[] = ["976"];

/** A non-NANP country's numbering: calling code, national number lengths, regular prefixes and blocked ones within them. */
export interface NationalPlan {
  readonly country: Exclude<PhoneCountry, "US" | "CA">;
  readonly code: string;
  readonly minLength: number;
  readonly maxLength: number;
  /** Callable national prefixes (mobile and geographic); `""` allows every prefix (only for a country with a full block list). */
  readonly allowed: readonly string[];
  /** Refused national prefixes inside the allowed ones: premium rate, paid services, service-wide numbers. */
  readonly blocked: readonly string[];
}

/**
 * Non-NANP numbering plans. One line per country (the Swift parity test reads them).
 * - FI: Traficom regulation 32 V/2025 M: mobile 040–048 and 050 (049 is machine-to-machine; `5` covers 050), geographic 02, 03, 05, 06,
 *   08, 09 and 013–019; refused inside them: 0200/0202x–0209 service and nationwide numbers, 0300, 0600–0602 premium,
 *   0900; 071/073/075 nationwide and 0700 premium stay out with all of 07, 0100/0106/0118 with 010–012.
 * - GB: Ofcom National Telephone Numbering Plan: geographic 01 and 02, 03 (charged as geographic), mobile 071–075 and
 *   077–079; refused: 070 personal numbers, 076 pagers, 08 and 09 by not being listed, and the Crown Dependencies'
 *   ranges under +44 (Jersey, Guernsey, Isle of Man: landline 01481/01534/01624, mobile 07509, 07524, 07624, 07700,
 *   07781, 07797, 07829, 07839, 07911, 07924, 07937), which carriers price as separate, dearer destinations.
 * - TR: the earlier block list (BTK: 444 shared cost, 800/822/888 special, 900 premium); no allow-list yet, and Turkish
 *   carriers block Turkish caller IDs from abroad.
 */
export const nationalPlans: readonly NationalPlan[] = [
  { country: "FI", code: "358", minLength: 5, maxLength: 12, allowed: ["13", "14", "15", "16", "17", "18", "19", "2", "3", "40", "41", "42", "43", "44", "45", "46", "47", "48", "5", "6", "8", "9"], blocked: ["200", "202", "203", "204", "209", "300", "600", "601", "602", "900"] },
  { country: "GB", code: "44", minLength: 9, maxLength: 10, allowed: ["1", "2", "3", "71", "72", "73", "74", "75", "77", "78", "79"], blocked: ["1481", "1534", "1624", "7509", "7524", "7624", "7700", "7781", "7797", "7829", "7839", "7911", "7924", "7937"] },
  { country: "TR", code: "90", minLength: 10, maxLength: 10, allowed: [""], blocked: ["444", "800", "822", "888", "900"] },
];

/**
 * Countries whose carriers block (or strip) calls arriving from abroad that show a number of their own country, so a
 * verified number of that country can't be the caller ID for a call into it through a provider abroad:
 * FI (Traficom M28, fixed 2022, mobile 2023; Twilio: Finnish verified caller IDs are blocked), GB (Ofcom: UK landline
 * caller IDs from abroad blocked, UK mobile ones withheld), TR (Twilio: calls to Turkey can't carry a Turkish caller ID).
 * US and Canada deliver them (STIR/SHAKEN attestation B).
 */
export const domesticCallerIdBlocked: readonly PhoneCountry[] = ["FI", "GB", "TR"];

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
  const plan: NationalPlan | undefined = nationalPlans.find((candidate: NationalPlan): boolean => digits.startsWith(candidate.code));
  if (plan === undefined) {
    return { kind: "blocked", reason: "unsupported" };
  }
  const national: string = digits.slice(plan.code.length);
  if (national.length < plan.minLength || national.length > plan.maxLength || national.startsWith("0")) {
    return { kind: "invalid" };
  }
  const regular: boolean = plan.allowed.some((prefix: string): boolean => national.startsWith(prefix));
  if (!regular || plan.blocked.some((prefix: string): boolean => national.startsWith(prefix))) {
    return { kind: "blocked", reason: "premium" };
  }
  return { kind: "callable", e164: value, country: plan.country };
}

/**
 * Whether a call from a caller ID of `callerCountry` into `destinationCountry` would be blocked by the destination's
 * carriers (`domesticCallerIdBlocked`). Pure function.
 */
export function callerIdBlockedInto(callerCountry: PhoneCountry, destinationCountry: PhoneCountry): boolean {
  return callerCountry === destinationCountry && domesticCallerIdBlocked.includes(destinationCountry);
}

/** Whether calls into `country` are limited to an allow-list of regular prefixes (NANP: by area code rules). Pure function. */
export function hasRegularNumberList(country: PhoneCountry): boolean {
  const plan: NationalPlan | undefined = nationalPlans.find((candidate: NationalPlan): boolean => candidate.country === country);
  return plan === undefined || !plan.allowed.includes("");
}

/** Whether `value` is one of the supported country codes. Pure function. */
export function isPhoneCountry(value: string): value is PhoneCountry {
  return (phoneCountries as readonly string[]).includes(value);
}

/** The number with all but its first and last two characters masked, for logs (`+1…42`). Pure function. */
export function maskedNumber(e164: string): string {
  return `${e164.slice(0, 2)}…${e164.slice(-2)}`;
}
