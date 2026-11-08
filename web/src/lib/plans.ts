// Abonelik planları ve katmanları. Plan (sunucunun `POST /v1/billing/checkout` gövdesindeki `plan`) faturalama
// aralığıdır: aylık ya da yıllık. Katman (`tier`) planın kapsamıdır: Personal (5,99 $ / 49 $) ya da Pro (12,99 $ /
// 109 $), vergiler dahil. Fiyat metinleri copy.ts'tedir; katmanların saatleri sunucu yapılandırmasıdır ve yalnızca
// sunucudan okunur (`GET /v1/pricing`, `GET /v1/me` `offeredTiers`). Pro yalnızca sunucu sunduğunda görünür.

/** Abonelik planı. */
export type BillingPlan = "monthly" | "yearly";

/** Planların gösterim sırası (fiyat sayfası ve hesap sayfasındaki seçim). */
export const billingPlans: readonly BillingPlan[] = ["monthly", "yearly"];

/** Abone olurken önceden seçili plan (sahibin kararı: yıllık). */
export const recommendedPlan: BillingPlan = "yearly";

/** Metin geçerli bir plan adıysa planı, değilse null döndürür (adres sorgusu ve depolama okunurken). Saf fonksiyondur. */
export function billingPlanOf(value: string | null): BillingPlan | null {
  return value === "monthly" || value === "yearly" ? value : null;
}

/** Abonelik katmanı (sunucunun `tier` değeri). */
export type SubscriptionTier = "personal" | "pro";

/** Katmanların gösterim sırası. */
export const subscriptionTiers: readonly SubscriptionTier[] = ["personal", "pro"];

/** Metin geçerli bir katman adıysa katmanı, değilse null döndürür (adres sorgusu ve depolama okunurken). Saf fonksiyondur. */
export function subscriptionTierOf(value: string | null): SubscriptionTier | null {
  return value === "personal" || value === "pro" ? value : null;
}

/** Sunucunun şu an satılan bir katmanı ve sınırları (`offeredTiers` / `GET /v1/pricing` `tiers` öğesi). */
export interface TierOffer {
  readonly tier: SubscriptionTier;
  /** Aylık toplantı saati sınırı. */
  readonly monthlyHours: number;
  /** Tek toplantının en uzun süresi (dakika). */
  readonly meetingMaxMinutes: number;
}

/** Sunulan katmanlardan istenen katman; sunulmuyorsa null. Saf fonksiyondur. */
export function tierOffer(offers: readonly TierOffer[], tier: SubscriptionTier): TierOffer | null {
  return offers.find((offer: TierOffer): boolean => offer.tier === tier) ?? null;
}

/** Saat sayısını yerel ayarda yazar: tam sayı ondalıksız, değilse bir ondalıkla ("10", "7.5"). Saf fonksiyondur. */
export function formatHourCount(hours: number, locale: string): string {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 1 }).format(hours);
}

/**
 * Toplantı süresi sınırı metni: tam saatse `hours` kalıbıyla ("4 hours"), değilse `minutes` kalıbıyla ("90 minutes");
 * kalıplardaki `{count}` sayıyla değişir. Saf fonksiyondur.
 */
export function meetingLengthText(minutes: number, locale: string, templates: { readonly hours: string; readonly minutes: string }): string {
  const template: string = minutes % 60 === 0 ? templates.hours : templates.minutes;
  const count: number = minutes % 60 === 0 ? minutes / 60 : minutes;
  return template.replace("{count}", new Intl.NumberFormat(locale, { maximumFractionDigits: 0 }).format(count));
}

/** Katman saat satırının kalıpları: `limits` (`{hours}`, `{meetingLength}`) ve süre sınırının saat/dakika kalıpları. */
export interface TierLimitsTemplates {
  readonly limits: string;
  readonly meetingLength: { readonly hours: string; readonly minutes: string };
}

/** Katmanın saat satırı (ör. "30 meeting hours a month, up to 4 hours per meeting"). Saf fonksiyondur. */
export function tierLimitsText(offer: TierOffer, locale: string, templates: TierLimitsTemplates): string {
  return templates.limits
    .replace("{hours}", formatHourCount(offer.monthlyHours, locale))
    .replace("{meetingLength}", meetingLengthText(offer.meetingMaxMinutes, locale, templates.meetingLength));
}

/** Fiyat sayfasında Pro görününce yazılacak saat satırları: Personal kartları ve Pro kartı. */
export interface PricingTierLines {
  readonly personal: string;
  readonly pro: string;
}

/**
 * Fiyat sayfasının katman satırları: sunucu Pro'yu ve Personal'i sunuyorsa ikisinin saat satırı, değilse null (Pro
 * kartı gizli kalır; sunucu her zaman Personal'i de sunar, yalnızca Pro'lu yanıt eksik sayılır). Saf fonksiyondur.
 */
export function pricingTierLines(offers: readonly TierOffer[], locale: string, templates: TierLimitsTemplates): PricingTierLines | null {
  const personal: TierOffer | null = tierOffer(offers, "personal");
  const pro: TierOffer | null = tierOffer(offers, "pro");
  if (personal === null || pro === null) {
    return null;
  }
  return { personal: tierLimitsText(personal, locale, templates), pro: tierLimitsText(pro, locale, templates) };
}

/**
 * Pro sunulunca sayfa metinlerinin (sınırlar, SSS, ana sayfanın sınır satırı) Pro'lu kalıpları. `always`: Pro sunulunca
 * yazılır; `meetingLengthDiffers`: Pro'nun toplantı süresi sınırı Personal'inkinden farklıysa `always`'un yerine yazılır.
 * İkisi de null ya da koşul tutmuyorsa sayfadaki metin olduğu gibi kalır. Kalıplarda `{proHours}` ve
 * `{proMeetingLength}` sunucunun Pro sınırlarıyla değişir (Personal'in saatleri metinde sabittir).
 */
export interface ProTextTemplates {
  readonly always: string | null;
  readonly meetingLengthDiffers: string | null;
}

/** Pro'lu kalıpların doldurulacağı değerler (sunucunun sınırlarından). */
export interface ProTextValues {
  readonly proHours: string;
  readonly proMeetingLength: string;
  /** Pro'nun toplantı süresi sınırı Personal'inkinden farklı mı. */
  readonly meetingLengthDiffers: boolean;
}

/**
 * Sunucu Pro'yu ve Personal'i sunuyorsa kalıpların değerleri, değilse null (sayfa bugünkü metinleriyle kalır). Saf
 * fonksiyondur.
 */
export function proTextValues(
  offers: readonly TierOffer[],
  locale: string,
  meetingLength: { readonly hours: string; readonly minutes: string },
): ProTextValues | null {
  const personal: TierOffer | null = tierOffer(offers, "personal");
  const pro: TierOffer | null = tierOffer(offers, "pro");
  if (personal === null || pro === null) {
    return null;
  }
  return {
    proHours: formatHourCount(pro.monthlyHours, locale),
    proMeetingLength: meetingLengthText(pro.meetingMaxMinutes, locale, meetingLength),
    meetingLengthDiffers: pro.meetingMaxMinutes !== personal.meetingMaxMinutes,
  };
}

/** Pro sunulunca yazılacak metin; kalıp yoksa ya da koşulu tutmuyorsa null (metin değişmez). Saf fonksiyondur. */
export function proText(templates: ProTextTemplates, values: ProTextValues): string | null {
  const template: string | null =
    values.meetingLengthDiffers && templates.meetingLengthDiffers !== null ? templates.meetingLengthDiffers : templates.always;
  return template === null ? null : template.replaceAll("{proHours}", values.proHours).replaceAll("{proMeetingLength}", values.proMeetingLength);
}

/**
 * Pro'lu kalıpların sayfadaki öğeye yazıldığı `data-*` öznitelikleri (`data-pro-text`, `data-pro-meeting-text`; boş
 * kalıp yazılmaz). Tarayıcı betiği (`src/client/pro-text.ts`) bunları okuyup `proText` ile metni değiştirir. Saf
 * fonksiyondur.
 */
export function proTextAttributes(templates: ProTextTemplates | null): Readonly<Record<string, string>> {
  if (templates === null) {
    return {};
  }
  return {
    ...(templates.always === null ? {} : { "data-pro-text": templates.always }),
    ...(templates.meetingLengthDiffers === null ? {} : { "data-pro-meeting-text": templates.meetingLengthDiffers }),
  };
}

/** Davet kodunun biçimi (sunucu büyük harfe çevirir, boşluk ve tireyi atar; burada yalnızca kaba denetim). */
const inviteCodePattern: RegExp = /^[A-Z0-9]{6,16}$/;

/**
 * Kullanıcının yazdığı ya da adresten gelen davet kodunu sunucunun beklediği biçime yaklaştırır: büyük harf, boşluk ve
 * tire yok. Biçimi tutmayan metin null (sunucuya hiç gönderilmez). Saf fonksiyondur.
 */
export function normalizedInviteCode(value: string): string | null {
  const code: string = value.toUpperCase().replace(/[\s-]+/g, "");
  return inviteCodePattern.test(code) ? code : null;
}
