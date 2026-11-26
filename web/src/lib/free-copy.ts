// Ücretsiz planın metinleri. Kalıcı ücretsiz plan (docs/superpowers/specs/2026-11-23-free-plan.md, bölüm 2.1) sunucuda
// `FREE_PLAN` politikası açıkken vardır (üretimde açık). Durağan HTML'deki "deneme bitince" SSS yanıtları (`src/copy.ts`) ve
// llms.txt (`src/lib/llms.ts`) ücretsiz planı sabit sayılarla anlatır; bu dosyadaki kalıplar da sayfaları sunucunun sayılarıyla
// yeniler. Bu dosyayı hiçbir .astro sayfası içe aktarmaz: fiyat sayfası, ana sayfa ve karşılaştırma sayfaları onu
// `GET /v1/pricing` `free` döndürünce ayrı bir parça olarak yükler (`src/client/free-offer.ts`, dinamik içe aktarma); llms.ts
// yalnızca `freeCard` ile `freeValues`'u derlemede kullanır. Plan kapatılırsa durağan metinler de güncellenmelidir. Sayılar sunucudan gelir (`{notes}`, `{length}`, `{asks}`);
// metinde sabit sayı yoktur. Ücretsiz plana "deneme" denmez: deneme (3 toplantı ya da 7 gün) her zaman önce gelir.
import { productName } from "../config.ts";
import { type FreePlanOffer, type FreeTextSlot, formatUsdCents } from "./plans.ts";
import { tierPrices } from "./tier-prices.ts";

/** Fiyat sayfasındaki Ücretsiz kartı. `features` kalıplarında `{notes}`, `{length}`, `{asks}` sunucunun sayılarıyla değişir. */
export interface FreeCardCopy {
  readonly name: string;
  readonly price: string;
  readonly per: string;
  readonly detail: string;
  readonly features: readonly string[];
  /** Personal'in ne eklediği. */
  readonly upgrade: string;
  /** Platform koşulu (iPhone'da iOS 26 ve cihazda desteklenen dil). */
  readonly requirements: string;
  readonly cta: string;
}

/** Ana sayfanın fiyat bandındaki Ücretsiz bloğu ve Personal'in etiketi. */
export interface FreeHomeCopy {
  readonly name: string;
  readonly price: string;
  readonly text: string;
  readonly personalName: string;
}

/** Ücretsiz plan metinlerinin sunucunun sayılarıyla doldurulacak değerleri. */
export interface FreeValues {
  /** "4 AI notes" */
  readonly notes: string;
  /** "45 minutes" */
  readonly length: string;
  /** "5 Ask questions" */
  readonly asks: string;
}

/** Sayı ve tekil/çoğul addan "4 AI notes" gibi bir ifade yazar. Saf fonksiyondur. */
function countedPhrase(count: number, locale: string, one: string, many: string): string {
  return `${new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(count)} ${count === 1 ? one : many}`;
}

/** Toplantı süresi: tam saatse "1 hour" / "2 hours", değilse "45 minutes" ("1 minute"). Saf fonksiyondur. */
function meetingLengthPhrase(minutes: number, locale: string): string {
  return minutes % 60 === 0 ? countedPhrase(minutes / 60, locale, "hour", "hours") : countedPhrase(minutes, locale, "minute", "minutes");
}

/** Sunucunun ücretsiz plan sınırlarından metin değerleri. Saf fonksiyondur. */
export function freeValues(offer: FreePlanOffer, locale: string): FreeValues {
  return {
    notes: countedPhrase(offer.notesPerMonth, locale, "AI note", "AI notes"),
    length: meetingLengthPhrase(offer.maxMeetingMinutes, locale),
    asks: countedPhrase(offer.asksPerMonth, locale, "Ask question", "Ask questions"),
  };
}

/** Kalıptaki `{notes}`, `{length}` ve `{asks}`'i değerlerle değiştirir. Saf fonksiyondur. */
export function fillFree(template: string, values: FreeValues): string {
  return template.replaceAll("{notes}", values.notes).replaceAll("{length}", values.length).replaceAll("{asks}", values.asks);
}

/** Fiyat sayfasının Ücretsiz kartı (yalnızca İngilizce; Fince sayfa ücretsiz planı anlatmaz). */
export const freeCard: FreeCardCopy = {
  name: "Free",
  price: formatUsdCents(0),
  per: "/ month",
  detail: "Yours after the free trial, or when a subscription ends. No card needed.",
  features: [
    "Transcripts written on your device, for meetings of any length",
    "{notes} a month, for meetings up to {length}",
    "{asks} a month",
    "Your notes stay on your device, with no sync between Mac and iPhone",
  ],
  upgrade: "Personal adds speaker labels and name hints, live translation, sync between your Mac and iPhone, longer meetings and the AI assistant connector.",
  requirements: "On iPhone, Free needs iOS 26 or later and a language Apple can transcribe on the device.",
  cta: "Start with the free trial",
};

/** Ana sayfanın fiyat bandı. */
export const freeHome: FreeHomeCopy = {
  name: "Free",
  price: formatUsdCents(0),
  text: "After your trial: {notes} a month for meetings up to {length}, {asks} a month, and transcripts written on your device.",
  personalName: "Personal",
};

/** Personal'in fiyat cümlesi (vergiler dahil), SSS yanıtlarında. */
const personalPrice: string = `${formatUsdCents(tierPrices.personal.monthlyCents)} a month or ${formatUsdCents(tierPrices.personal.yearlyCents)} a year, taxes included`;

/**
 * Ücretsiz plan açılınca sayfadaki metinlerin yerine geçen kalıplar, öğenin `data-free-slot` değerine göre. Ücretsiz plansız
 * metinler copy.ts'tedir; buradakiler aynı cümlelerin ücretsiz plan açıkken geçerli hâlidir (biri değişince öbürü de değişmeli).
 */
export const freeTexts: Readonly<Record<FreeTextSlot, string>> = {
  homeTrial: `The trial is free and needs no card: 3 meetings or 7 days from your first meeting, whichever comes first. Meetings you haven't used by then expire. Trial meetings can be up to 90 minutes long. After that you can keep using ${productName} on the Free plan ({notes} a month for meetings up to {length}, {asks} a month, and transcripts written on your device), or subscribe to ${productName} Personal for ${personalPrice}.`,
  pricingTrialEnd: `The app lets you know, and you can keep using ${productName} on the Free plan: transcripts written on your device, {notes} a month for meetings up to {length}, and {asks} a month, with no sync between your devices. On iPhone, Free needs iOS 26 or later. Subscribe to Personal for speaker labels, live translation, sync between your devices and longer meetings. Your existing notes and recordings stay on your device and remain readable.`,
  homeLead: `${productName} Personal has everything in it. Try it on your own meetings before you pay; after the trial you can keep going on Free.`,
  pricingPlansNote: "Personal includes everything below, on Mac and iPhone. Got an invite from a friend? ",
  pricingIncludedTagline: "Everything in Personal, from live transcript to tasks.",
  compareFree: "Free trial: 3 meetings or 7 days, whichever comes first; no card needed. After the trial, a free plan: {notes} a month for meetings up to {length}, with transcripts written on your device",
  compareGlanceFree: "3 meetings or 7 days free, no card; then a free plan with {notes} a month",
};
