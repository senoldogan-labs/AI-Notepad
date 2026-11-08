/**
 * Stripe aboneliğinin (`subscriptions` satırı, ücretsiz erişim dahil) yaşam döngüsü: tek kaynak. Durum saklanmaz, satırdan
 * ve andan türetilir; TS kararları (`subscriptionLifecycle`) ve SQL koşulları (`…Sql`) aynı kurallardan üretilir ve
 * `test/subscriptionLifecycle.test.ts` ikisinin aynı sonucu verdiğini satır tablosuyla denetler.
 *
 * Durumlar:
 * - `active`: `active`/`trialing`, dönem sonuna dek; yenilenecekse (`cancel_at` yok ya da dönem sonundan sonra) yenileme
 *   webhook'u gecikebileceği için `subscriptionRenewalGraceMs` daha.
 * - `grace`: `past_due`, ödemenin başarısız olduğu andan (`past_due_since`) ek süre boyunca (Stripe yeniden denerken).
 * - `ended`: bitmiş (terminal): `canceled`, `incomplete_expired` ya da dönemi geçmiş `unpaid`; ücretsiz erişimde dönem
 *   sonu geçmiş satır (Stripe'ta yaşamaz). Yeni Checkout ya da ücretsiz erişim yalnızca bunun üzerine yazılabilir.
 * - `lapsed`: erişimi yok ama Stripe'ta yaşıyor (`unpaid`, `incomplete`, `paused`, ek süresi geçmiş `past_due`, dönemi
 *   geçmiş `active`): Portal'dan yönetilir, başka bir aboneliğin olayı onu ezmez.
 *
 * Saf modüldür: veritabanına ve saate dokunmaz.
 */

/** Stripe'ta bitmiş abonelik durumları. */
export const terminalStripeStatuses: readonly ["canceled", "incomplete_expired"] = ["canceled", "incomplete_expired"];

/** Ödenmiş dönemi süren abonelik durumları. */
export const paidStripeStatuses: readonly ["active", "trialing"] = ["active", "trialing"];

/**
 * Yenilenecek `active`/`trialing` aboneliğin dönem sonundan sonra erişimi koruduğu süre: Stripe yenileme faturasını dönem
 * sonunda keser ve ödemeyi alır; yeni dönem sonunu taşıyan webhook birkaç dakika ile saatler arasında gecikebilir. Bu
 * sürede abone denemeye düşmez (`/v1/me` planı, toplantı başlatma deneme yoluna ve DeviceCheck'e girmez).
 */
export const subscriptionRenewalGraceMs: number = 48 * 3_600_000;

/** Yaşam döngüsünün okuduğu abonelik sütunları (webhook'un ya da yöneticinin yazdığı). */
export interface SubscriptionLifecycleColumns {
  readonly status: string;
  readonly currentPeriodEnd: number;
  /** İptal edilmiş aboneliğin biteceği an (ms); yenilenecekse null. */
  readonly cancelAt: number | null;
  /** Aboneliğin `past_due` durumuna geçtiği an (ms); `past_due` değilse null. */
  readonly pastDueSince: number | null;
  /** Yöneticinin verdiği ücretsiz erişim mi. */
  readonly complimentary: boolean;
}

/** Aboneliğin türetilmiş durumu (bkz. modül belgesi). */
export type SubscriptionLifecycle = "active" | "grace" | "lapsed" | "ended";

/** Tuple'ı SQL `IN (…)` listesine çevirir (sabit metinler; kullanıcı girdisi değil). */
function sqlList(values: readonly string[]): string {
  return values.map((value: string): string => `'${value}'`).join(", ");
}

/**
 * `active`/`trialing` aboneliğin erişiminin bittiği an (ms): yenilenecekse dönem sonu + `subscriptionRenewalGraceMs`,
 * dönem sonunda bitecekse dönem sonu. Saf fonksiyondur (`paidAccessEndsAtSql`'in eşi).
 */
export function paidAccessEndsAtMs(subscription: SubscriptionLifecycleColumns): number {
  const renews: boolean = subscription.cancelAt === null || subscription.cancelAt > subscription.currentPeriodEnd;
  return renews ? subscription.currentPeriodEnd + subscriptionRenewalGraceMs : subscription.currentPeriodEnd;
}

/** `paidAccessEndsAtMs`'in SQL eşi; `p` tablo öneki (ör. `"s."`). */
function paidAccessEndsAtSql(p: string): string {
  return `(CASE WHEN ${p}cancel_at IS NULL OR ${p}cancel_at > ${p}current_period_end
    THEN ${p}current_period_end + ${subscriptionRenewalGraceMs} ELSE ${p}current_period_end END)`;
}

/** `past_due` ek süresinin bittiği an (ms); `past_due` değilse ya da geçiş anı bilinmiyorsa null. Saf fonksiyondur. */
export function graceEndsAtMs(subscription: SubscriptionLifecycleColumns, pastDueGraceMs: number): number | null {
  return subscription.status === "past_due" && subscription.pastDueSince !== null ? subscription.pastDueSince + pastDueGraceMs : null;
}

/** Ödenmiş dönem erişimi sürüyor mu. Saf fonksiyondur (`subscriptionActiveSql`'in eşi). */
function isPaidActive(subscription: SubscriptionLifecycleColumns, nowMs: number): boolean {
  return (paidStripeStatuses as readonly string[]).includes(subscription.status) && paidAccessEndsAtMs(subscription) > nowMs;
}

/** `past_due` ek süresi sürüyor mu. Saf fonksiyondur (`subscriptionGraceSql`'in eşi). */
function isPastDueGrace(subscription: SubscriptionLifecycleColumns, nowMs: number, pastDueGraceMs: number): boolean {
  const graceEnd: number | null = graceEndsAtMs(subscription, pastDueGraceMs);
  return graceEnd !== null && graceEnd > nowMs;
}

/** Abonelik bitmiş mi (`ended`). Saf fonksiyondur (`subscriptionTerminalSql`'in eşi). */
function isEnded(subscription: SubscriptionLifecycleColumns, nowMs: number): boolean {
  if (subscription.complimentary) {
    return subscription.currentPeriodEnd <= nowMs;
  }
  if ((terminalStripeStatuses as readonly string[]).includes(subscription.status)) {
    return true;
  }
  return subscription.status === "unpaid" && subscription.currentPeriodEnd <= nowMs;
}

/**
 * Aboneliğin `nowMs` anındaki durumu. Erişim önce gelir: erişimi süren satır `active` ya da `grace`'tir; erişimsiz satır
 * bitmişse `ended`, değilse `lapsed`. Saf fonksiyondur.
 */
export function subscriptionLifecycle(subscription: SubscriptionLifecycleColumns, nowMs: number, pastDueGraceMs: number): SubscriptionLifecycle {
  if (isPaidActive(subscription, nowMs)) {
    return "active";
  }
  if (isPastDueGrace(subscription, nowMs, pastDueGraceMs)) {
    return "grace";
  }
  return isEnded(subscription, nowMs) ? "ended" : "lapsed";
}

/** Abonelik erişim veriyor mu (`active` ya da `grace`). Saf fonksiyondur. */
export function hasActiveAccess(subscription: SubscriptionLifecycleColumns | null, nowMs: number, pastDueGraceMs: number): boolean {
  if (subscription === null) {
    return false;
  }
  const state: SubscriptionLifecycle = subscriptionLifecycle(subscription, nowMs, pastDueGraceMs);
  return state === "active" || state === "grace";
}

/**
 * Abonelik bitmiş mi (`ended`). Erişimi süren satır bitmiş sayılmaz. Bitmemiş abonelik ek süresi geçmiş olsa da Stripe'ta
 * yaşar: yeni Checkout açılmaz ve başka bir aboneliğin olayı onu ezmez. Saf fonksiyondur.
 */
export function isEndedSubscription(subscription: SubscriptionLifecycleColumns, nowMs: number): boolean {
  return !isPaidActive(subscription, nowMs) && isEnded(subscription, nowMs);
}

/** Ücretsiz erişim süren satır mı (Stripe olayı onu ezmez, Checkout ve Portal Stripe'a gitmez). Saf fonksiyondur. */
export function isRunningComplimentary(subscription: SubscriptionLifecycleColumns, nowMs: number): boolean {
  return subscription.complimentary && !isEndedSubscription(subscription, nowMs);
}

/** Stripe aboneliği yaşıyor mu (bitmiş durumda değil; Stripe'ın kendi durum metni). Saf fonksiyondur. */
export function isLiveStripeStatus(status: string): boolean {
  return !(terminalStripeStatuses as readonly string[]).includes(status);
}

/** `isLiveStripeStatus`'un SQL eşi; `p` tablo öneki. */
export function liveStripeStatusSql(p: string): string {
  return `(${p}status NOT IN (${sqlList(terminalStripeStatuses)}))`;
}

/** Ödenmiş dönem erişimi (SQL, `active` durumu); `p` tablo öneki, `now` şimdinin bağı (ms). */
export function subscriptionActiveSql(p: string, now: string): string {
  return `(${p}status IN (${sqlList(paidStripeStatuses)}) AND ${paidAccessEndsAtSql(p)} > ${now})`;
}

/** `past_due` ek süresi (SQL, `grace` durumu); `grace` ek sürenin bağı (ms). NULL `past_due_since` yanlış verir. */
export function subscriptionGraceSql(p: string, now: string, grace: string): string {
  return `(${p}status = 'past_due' AND ${p}past_due_since + ${grace} > ${now})`;
}

/** Erişim var mı (SQL; `hasActiveAccess`'in eşi). Satır yoksa (LEFT JOIN) NULL verir: çağıran `COALESCE` eder. */
export function subscriptionAccessSql(p: string, now: string, grace: string): string {
  return `(${subscriptionActiveSql(p, now)} OR ${subscriptionGraceSql(p, now, grace)})`;
}

/** Abonelik bitmiş mi (SQL; `isEndedSubscription`'ın eşi). */
export function subscriptionEndedSql(p: string, now: string): string {
  const ended: string = `(CASE WHEN ${p}complimentary = 1 THEN ${p}current_period_end <= ${now}
    ELSE ${p}status IN (${sqlList(terminalStripeStatuses)}) OR (${p}status = 'unpaid' AND ${p}current_period_end <= ${now}) END)`;
  return `(NOT ${subscriptionActiveSql(p, now)} AND ${ended})`;
}

/** Ücretsiz erişim süren satır mı (SQL; `isRunningComplimentary`'nin eşi). */
export function runningComplimentarySql(p: string, now: string): string {
  return `(${p}complimentary = 1 AND NOT ${subscriptionEndedSql(p, now)})`;
}
