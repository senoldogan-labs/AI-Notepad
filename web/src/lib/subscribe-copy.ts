// Hesap sayfasının abonelik metinleri (saf; DOM'a dokunmaz, scripts/subscribe-copy.test.ts sınar): Abone ol düğmesi ve
// altındaki yenileme koşulları seçili katman ve planın tutarıyla, Stripe abonesinin katman değiştirme notu, süren
// denemenin başlığı ve hiç abone olmamış hesapta deneme bitince "kaldığın yerden devam et" metni. Kalıplar
// `clientCopy`'dedir (src/client/copy.ts); tutarlar `tierPrices`'tan (src/lib/tier-prices.ts). Web'de görev sayısı yoktur
// (eşitleme uçtan uca şifreli): deneme metinleri yalnızca sunucunun deneme sayılarını kullanır.
import type { Entitlements } from "../client/api";
import type { PlanState } from "./plan-status";
import { type BillingPlan, type BilledTotalTemplates, type SubscriptionTier, formatUsdCents, planPriceCents } from "./plans.ts";
import { tierPrices } from "./tier-prices.ts";

/** Katman başına kalıp. */
export interface TierTemplates {
  readonly personal: string;
  readonly pro: string;
}

/** Tekil ve çoğul sayı kalıbı (`{count}`). */
export interface CountTemplates {
  readonly one: string;
  readonly other: string;
}

/** Abonelik metinlerinin kalıpları (`clientCopy`'nin parçaları). */
export interface SubscribeTemplates {
  readonly billedTotal: BilledTotalTemplates;
  readonly period: { readonly monthly: string; readonly yearly: string };
  readonly subscribeCta: TierTemplates;
  readonly checkoutTerms: { readonly lead: string; readonly rest: string };
  readonly switchTier: TierTemplates;
  readonly switchTierNote: TierTemplates;
}

/** Abone ol düğmesinin altındaki yenileme koşulları: kalın satır ve geri kalanı. */
export interface CheckoutTerms {
  readonly lead: string;
  readonly rest: string;
}

/** `{ad}` yer tutucularını değerlerle doldurur (src/client/copy.ts `fill` ile aynı). Saf fonksiyondur. */
function fillTemplate(template: string, values: Readonly<Record<string, string>>): string {
  return template.replace(/\{(\w+)\}/g, (match: string, key: string): string => values[key] ?? match);
}

/** Katmanın planının faturalanan tutar metni ("$49/year"). Saf fonksiyondur. */
function billedTotal(tier: SubscriptionTier, plan: BillingPlan, templates: SubscribeTemplates): string {
  return fillTemplate(templates.billedTotal[plan], { price: formatUsdCents(planPriceCents(tierPrices[tier], plan)) });
}

/** Abone ol düğmesi: katmana göre ve seçili planın tutarıyla ("Subscribe · $49/year"). Saf fonksiyondur. */
export function subscribeLabel(tier: SubscriptionTier, plan: BillingPlan, templates: SubscribeTemplates): string {
  return fillTemplate(templates.subscribeCta[tier], { price: billedTotal(tier, plan, templates) });
}

/** Abone ol düğmesinin altındaki yenileme koşulları, seçili katmanın planının tutarı ve dönemiyle. Saf fonksiyondur. */
export function checkoutTerms(tier: SubscriptionTier, plan: BillingPlan, templates: SubscribeTemplates): CheckoutTerms {
  const values: Readonly<Record<string, string>> = { price: formatUsdCents(planPriceCents(tierPrices[tier], plan)), period: templates.period[plan] };
  return { lead: fillTemplate(templates.checkoutTerms.lead, values), rest: fillTemplate(templates.checkoutTerms.rest, values) };
}

/** Katman değiştirme düğmesi: hedef katman ve korunan planın tutarıyla ("Switch to Pro · $12.99/month"). Saf fonksiyondur. */
export function switchTierLabel(tier: SubscriptionTier, plan: BillingPlan, templates: SubscribeTemplates): string {
  return fillTemplate(templates.switchTier[tier], { price: billedTotal(tier, plan, templates) });
}

/**
 * Katman değiştirme notu: Pro'ya geçişte bugün ödenecek orantılı fark, Personal'a geçişte kullanılmayan sürenin alacağı;
 * ikisinde de yeni katmanın tutarı ve dönemi. Saf fonksiyondur.
 */
export function switchTierNote(tier: SubscriptionTier, plan: BillingPlan, templates: SubscribeTemplates): string {
  return fillTemplate(templates.switchTierNote[tier], { price: formatUsdCents(planPriceCents(tierPrices[tier], plan)), period: templates.period[plan] });
}

/** Denemede kullanılan toplantı: toplam eksi kalan (en az 0). Saf fonksiyondur. */
export function trialMeetingsUsed(me: Entitlements): number {
  return Math.max(me.trialMeetingsTotal - me.trialMeetingsLeft, 0);
}

/** Sayıya göre tekil ya da çoğul kalıp, sayıyla doldurulmuş. Saf fonksiyondur. */
function countText(count: number, templates: CountTemplates): string {
  return count === 1 ? templates.one : fillTemplate(templates.other, { count: String(count) });
}

/**
 * Süren (ya da başlamamış) denemenin başlığı: toplantı kaydedildiyse sayısıyla, yoksa yalnızca sonuç cümlesi (sıfır
 * sayı olumlu bir iddianın yanında yazılmaz). Saf fonksiyondur.
 */
export function trialHeadline(used: number, templates: CountTemplates & { readonly none: string }): string {
  return used > 0 ? countText(used, templates) : templates.none;
}

/**
 * Hiç abone olmamış hesapta deneme bittiyse "kaldığın yerden devam et" metni (kaydedilen toplantı sayısıyla); hiç
 * toplantı yoksa, deneme bitmediyse ya da hesabın bir aboneliği olduysa (eski abone kendi iletisini görür) null.
 * Saf fonksiyondur.
 */
export function winBackText(state: PlanState, used: number, templates: CountTemplates): string | null {
  if (state.kind !== "trial" || state.trial.kind !== "ended" || used === 0) {
    return null;
  }
  return countText(used, templates);
}

/**
 * Cayma işlevinin (AB CRD Art. 11a) son anı: yalnızca erişimi süren, ücretsiz erişim olmayan Stripe aboneliğinde ve
 * sunucunun bildirdiği son an henüz gelmediyse; yoksa null (düğme görünmez). Saf fonksiyondur.
 */
export function withdrawalDeadline(state: PlanState, now: Date): string | null {
  if (state.kind !== "subscribed" && state.kind !== "ending" && state.kind !== "grace") {
    return null;
  }
  const until: string | null = state.subscription.withdrawableUntil;
  if (state.subscription.source !== "stripe" || state.subscription.complimentary || until === null) {
    return null;
  }
  return new Date(until).getTime() > now.getTime() ? until : null;
}

/**
 * İade tutarını (para biriminin en küçük biriminde, Stripe gibi) yerel ayarda yazar ("$5.20", "€4.10", "¥500"): ondalık
 * basamak sayısı para biriminden gelir. Saf fonksiyondur.
 */
export function formatRefund(minorUnits: number, currency: string, locale: string): string {
  const format: Intl.NumberFormat = new Intl.NumberFormat(locale, { style: "currency", currency });
  const digits: number = format.resolvedOptions().maximumFractionDigits ?? 2;
  return format.format(minorUnits / 10 ** digits);
}
