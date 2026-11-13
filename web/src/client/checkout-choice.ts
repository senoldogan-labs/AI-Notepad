// Abone olmadan önceki seçimlerin tarayıcıdaki kaydı: davet sayfasından ya da davet bağlantısından gelen kod ve fiyat
// sayfasında seçilen plan ve katman (localStorage: kullanıcı önce uygulamayı indirip sonra abone olabilir, giriş başka
// bir sekmede ya da daha sonraki bir ziyarette bitebilir; seçim girişten sonra kaybolmaz) ve "ödemeye devam et" niyeti
// (sessionStorage: yalnızca seçimin yapıldığı sekmede, giriş yönlendirmesi aynı sekmede kalır; başka sekmede hesabı
// açan kullanıcı kendiliğinden ödeme sayfasına gitmez). Depolama kapalıysa uyarı yazılır, seçim yalnızca o sayfada
// kalır (temanın davranışıyla aynı).
import { type BillingPlan, type SubscriptionTier, billingPlanOf, normalizedInviteCode, subscriptionTierOf } from "../lib/plans";

/** Davet kodunun anahtarı (localStorage). */
const inviteKey: string = "gistsmith.invite";
/** Seçilen planın anahtarı (localStorage). */
const planKey: string = "gistsmith.plan";
/** Seçilen katmanın anahtarı (localStorage; fiyat sayfasında Pro seçilince yazılır). */
const tierKey: string = "gistsmith.tier";
/** "Seçilen planla ödemeye devam et" niyetinin anahtarı (sessionStorage). */
const checkoutKey: string = "gistsmith.checkout";

/** Depolama işlemini yapar; tarayıcı depolamayı engellediyse uyarı yazar ve null döndürür. */
function withStorage<T>(operation: string, action: () => T): T | null {
  try {
    return action();
  } catch (error: unknown) {
    console.warn("checkout_choice_storage_unavailable", { operation, error: error instanceof Error ? error.message : String(error) });
    return null;
  }
}

/** Kayıtlı davet kodu; yoksa ya da biçimsizse null. */
export function storedInviteCode(): string | null {
  const value: string | null = withStorage("read_invite", (): string | null => window.localStorage.getItem(inviteKey));
  return value === null ? null : normalizedInviteCode(value);
}

/** Davet kodunu kaydeder. */
export function storeInviteCode(code: string): void {
  withStorage("write_invite", (): void => window.localStorage.setItem(inviteKey, code));
}

/** Kayıtlı davet kodunu siler (abone olunca ya da kullanıcı kaldırınca). */
export function forgetInviteCode(): void {
  withStorage("remove_invite", (): void => window.localStorage.removeItem(inviteKey));
}

/** Seçilen plan; yoksa null. Girişten ve sekme kapanmasından sonra da durur. */
export function storedPlan(): BillingPlan | null {
  return billingPlanOf(withStorage("read_plan", (): string | null => window.localStorage.getItem(planKey)));
}

/** Seçilen planı kaydeder. */
export function storePlan(plan: BillingPlan): void {
  withStorage("write_plan", (): void => window.localStorage.setItem(planKey, plan));
}

/** Kayıtlı planı siler (abonelik başlayınca seçim anlamını yitirir). */
export function forgetPlan(): void {
  withStorage("remove_plan", (): void => window.localStorage.removeItem(planKey));
}

/** Seçilen katman; yoksa null. Plan gibi girişten ve sekme kapanmasından sonra da durur. */
export function storedTier(): SubscriptionTier | null {
  return subscriptionTierOf(withStorage("read_tier", (): string | null => window.localStorage.getItem(tierKey)));
}

/** Seçilen katmanı kaydeder. */
export function storeTier(tier: SubscriptionTier): void {
  withStorage("write_tier", (): void => window.localStorage.setItem(tierKey, tier));
}

/** Kayıtlı katmanı siler (abonelik başlayınca seçim anlamını yitirir). */
export function forgetTier(): void {
  withStorage("remove_tier", (): void => window.localStorage.removeItem(tierKey));
}

/** Bu sekmede ödemeye devam etme niyeti var mı. */
export function checkoutIntended(): boolean {
  return withStorage("read_checkout", (): boolean => window.sessionStorage.getItem(checkoutKey) === "1") === true;
}

/** Ödemeye devam etme niyetini bu sekme için kaydeder. */
export function storeCheckoutIntent(): void {
  withStorage("write_checkout", (): void => window.sessionStorage.setItem(checkoutKey, "1"));
}

/** Niyeti siler (kullanıldı, abonelik var ya da kullanıcı vazgeçti). */
export function forgetCheckoutIntent(): void {
  withStorage("remove_checkout", (): void => window.sessionStorage.removeItem(checkoutKey));
}

/** Kampanya adı ve kaynağının anahtarı (sessionStorage; yalnızca bu sekmede, sekme kapanınca silinir). */
const campaignKey: string = "gistsmith.campaign";

/** Kampanya değerinin biçimi: sunucunun kabul ettiği en geniş küme (küçük harf, rakam, `-`, en çok 32 karakter). */
const campaignValuePattern: RegExp = /^[a-z0-9-]{1,32}$/;

/** Sayfaya gelirken adreste olan kampanya; yoksa alanlar null. */
export interface StoredCampaign {
  readonly source: string | null;
  readonly campaign: string | null;
}

/** Adres parametresinin kampanya değeri: yoksa ya da biçimi geçmiyorsa null. Saf fonksiyondur. */
function campaignValueOf(raw: string | null): string | null {
  if (raw === null) {
    return null;
  }
  const value: string = raw.trim().toLowerCase();
  return campaignValuePattern.test(value) ? value : null;
}

/**
 * Adreste `utm_source` ya da `utm_campaign` varsa bu sekme için kaydeder (ödeme sayfasının sayısı kampanyaya yazılsın;
 * giriş yönlendirmesi ve `?plan=` temizliği adresi düşürür). Yalnızca sunucuya, kampanya sayacı için gider; başka yere
 * gönderilmez. Adreste kampanya yoksa önceki kayda dokunmaz.
 */
export function rememberCampaign(params: URLSearchParams): void {
  const source: string | null = campaignValueOf(params.get("utm_source"));
  const campaign: string | null = campaignValueOf(params.get("utm_campaign"));
  if (source === null && campaign === null) {
    return;
  }
  withStorage("write_campaign", (): void => window.sessionStorage.setItem(campaignKey, JSON.stringify({ source, campaign })));
}

/** Bu sekmede kayıtlı kampanya; yoksa ya da biçimsizse iki alan da null. */
export function storedCampaign(): StoredCampaign {
  const raw: string | null = withStorage("read_campaign", (): string | null => window.sessionStorage.getItem(campaignKey));
  if (raw === null) {
    return { source: null, campaign: null };
  }
  const parsed: unknown = withStorage("parse_campaign", (): unknown => JSON.parse(raw) as unknown);
  if (typeof parsed !== "object" || parsed === null) {
    return { source: null, campaign: null };
  }
  const record: Readonly<Record<string, unknown>> = parsed as Readonly<Record<string, unknown>>;
  const source: unknown = record["source"];
  const campaign: unknown = record["campaign"];
  return {
    source: typeof source === "string" ? campaignValueOf(source) : null,
    campaign: typeof campaign === "string" ? campaignValueOf(campaign) : null,
  };
}

/** Kayıtlı kampanyayı siler (ödeme tamamlandı). */
export function forgetCampaign(): void {
  withStorage("remove_campaign", (): void => window.sessionStorage.removeItem(campaignKey));
}
