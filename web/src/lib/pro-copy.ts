// Pro katmanının metinleri. Bugün yalnızca Personal satılır (sunucuda `PRO_TIER_POLICY` kapalı): sitenin durağan
// HTML'i, JSON-LD'si, llms.txt'i ve kullanım koşulları (`pages/terms.astro`) tek planı anlatır ve Pro'dan hiç söz etmez;
// Pro açılırken koşullara geri eklenir (server/README.md, "Açmak"). Bu dosyayı hiçbir .astro sayfası
// içe aktarmaz; yalnızca tarayıcı betikleri kullanır: fiyat sayfası ve ana sayfa onu `GET /v1/pricing` Pro'yu
// sunduğunda ayrı bir parça olarak yükler (`src/client/pro-offer.ts`, dinamik içe aktarma), hesap sayfası katman
// seçimini çizerken. Saatler sunucudan gelir (`{proHours}`, `{proMeetingLength}`); fiyatlar `tierPrices`'tan.
import type { PlanOptionCopy } from "../copy";
import { type ProTextTemplates, type TierTextSlot, formatUsdCents, yearlyMonthlyEquivalentCents, yearlySavingsPercent } from "./plans";
import { tierPrices } from "./tier-prices";

/**
 * Pro katmanı: fiyat sayfasında Pro sunulunca eklenen kartlar, hesap sayfasında plan seçimindeki Pro fiyatları.
 * `limits` katman satırıdır (`{hours}`, `{meetingLength}`); `meetingLength` süre sınırının saat ya da dakika kalıbıdır
 * (`{count}`). `personalName` Pro görününce Personal kartlarının katman satırındaki addır.
 */
export interface ProTierCopy {
  readonly name: string;
  readonly limits: string;
  readonly meetingLength: { readonly hours: string; readonly minutes: string };
  readonly plans: readonly PlanOptionCopy[];
  readonly personalName: string;
}

/** Pro katmanının metinleri (yalnızca İngilizce; Fince sayfa Pro'yu anlatmaz). */
export const proTier: ProTierCopy = {
  name: "Pro",
  limits: "{hours} meeting hours a month, up to {meetingLength} per meeting",
  meetingLength: { hours: "{count} hours", minutes: "{count} minutes" },
  plans: [
    {
      plan: "yearly",
      name: "Yearly",
      price: formatUsdCents(tierPrices.pro.yearlyCents),
      per: "/ year",
      detail: `About ${formatUsdCents(yearlyMonthlyEquivalentCents(tierPrices.pro))} a month, billed yearly. Taxes included.`,
      badge: `Save ${String(yearlySavingsPercent(tierPrices.pro))}% vs monthly`,
      cta: `Subscribe to Pro · ${formatUsdCents(tierPrices.pro.yearlyCents)}/year`,
    },
    {
      plan: "monthly",
      name: "Monthly",
      price: formatUsdCents(tierPrices.pro.monthlyCents),
      per: "/ month",
      detail: "Billed every month. Taxes included.",
      badge: null,
      cta: `Subscribe to Pro · ${formatUsdCents(tierPrices.pro.monthlyCents)}/month`,
    },
  ],
  personalName: "Personal",
};

/**
 * Pro sunulunca sayfadaki metinlerin yerine geçen kalıplar, öğenin `data-tier-slot` değerine göre. Pro'suz metinler
 * copy.ts'tedir; buradakiler aynı cümlelerin Pro'lu hâlidir (biri değişince öbürü de değişmeli).
 */
export const proTexts: Readonly<Record<TierTextSlot, ProTextTemplates>> = {
  homeLead: {
    always: "Every plan has everything in it; Pro adds more meeting hours. Try it on your own meetings before you pay.",
    meetingLengthDiffers: null,
  },
  homeLimits: {
    always: "Up to 10 meeting hours a month and 4 hours per meeting, or {proHours} hours a month with Pro. Voice typing runs on your Mac and doesn't count.",
    meetingLengthDiffers:
      "Up to 10 meeting hours a month and 4 hours per meeting, or {proHours} hours a month and {proMeetingLength} per meeting with Pro. Voice typing runs on your Mac and doesn't count.",
  },
  hoursTitle: { always: "10 or {proHours} hours a month", meetingLengthDiffers: null },
  hoursText: {
    always:
      "A fair-use limit on meeting time: 10 hours a month on Personal, {proHours} on Pro. It resets on the first day of each month (UTC). At the limit you can't start new meetings until the month resets; the app tells you clearly. AI outside meetings, such as Ask, has its own monthly allowance.",
    meetingLengthDiffers: null,
  },
  lengthTitle: { always: null, meetingLengthDiffers: "4 hours per meeting, {proMeetingLength} on Pro" },
  lengthText: {
    always: null,
    meetingLengthDiffers: "Enough for long workshops and lectures; longer meetings close at 4 hours on Personal and at {proMeetingLength} on Pro.",
  },
  paymentAnswer: {
    always: `Checkout is hosted by Stripe, and your purchase is sold through Link, Stripe's payment service, as the merchant of record. Every price includes sales tax, VAT or GST: ${formatUsdCents(tierPrices.personal.monthlyCents)} a month or ${formatUsdCents(tierPrices.personal.yearlyCents)} a year for Personal, and ${formatUsdCents(tierPrices.pro.monthlyCents)} a month or ${formatUsdCents(tierPrices.pro.yearlyCents)} a year for Pro. Link calculates and remits the tax for your location, and checkout shows the included tax before you pay. You may see the price in your local currency. Your card details stay with Stripe and Link and never reach us. Purchases aren't available in some countries where Stripe can't sell, such as China, Cuba, Iran, North Korea, Russia and Syria. In the iPhone app you can also subscribe through the App Store: Apple handles that payment, the app shows the price for your country before you buy, and your Apple Account is charged.`,
    meetingLengthDiffers: null,
  },
  allowancesAnswer: {
    always:
      "There are two monthly allowances, and the app and your account page show how much of each you've used. Meeting hours: up to 10 hours of meetings a month on Personal, or {proHours} on Pro. The AI that works during and right after a meeting, such as live translation, “What did I miss?” and the note, comes with the meeting and doesn't use the second allowance. AI outside meetings: Ask, rewriting a note, translating a note to share and the task tools share a separate monthly allowance; when it's used up, they pause until the month resets. Web search in Ask has its own limit of 100 searches a month; after that, Ask answers from your meetings only. All of them reset on the first day of each month (UTC). During the free trial, AI outside meetings has a daily allowance instead.",
    meetingLengthDiffers: null,
  },
  switchAnswer: {
    always:
      "Not with a single click yet. Cancel your current plan with “Manage subscription” on your account page; you keep access until the end of the period you paid for. When it has ended, subscribe again from your account page and choose the other plan. Switching between Personal and Pro is quicker: on your account page, choose “Switch to Pro” or “Switch to Personal”, and confirm on a Stripe page that shows the amount before anything is charged. Your monthly or yearly billing stays the same. If you subscribed in the iPhone app, switch on your iPhone in Settings › your name › Subscriptions.",
    meetingLengthDiffers: null,
  },
};
