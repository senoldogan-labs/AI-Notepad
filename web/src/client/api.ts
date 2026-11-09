// Abonelik sunucusunun (server/src/app.ts) sitenin kullandığı uçları: giriş, oturum yenileme, hesap, ödeme, hesap
// silme ve iletişim formu. Yanıtlar elle doğrulanır (bağımlılık yok); beklenmeyen biçim `ApiResponseError` verir.
// Alan okuyucuları yönetim paneli istemcisi (admin-api.ts) de kullanır.
import { type BillingPlan, type SubscriptionTier, type TierOffer, billingPlanOf, subscriptionTierOf } from "../lib/plans";
import type { SiteConfig } from "../config";
import { siteConfig } from "../site";

/** Sunucunun döndürdüğü oturum (`sessionBody`). */
export interface SessionTokens {
  readonly accessToken: string;
  readonly refreshToken: string;
  /** Erişim jetonunun ömrü (saniye). */
  readonly expiresIn: number;
  readonly userId: string;
}

/** Aboneliğin erişim durumu (server/src/entitlements.ts). */
export type SubscriptionAccess = "active" | "grace" | "none";

/** Aboneliğin her durumda ortak alanları. `plan`: aylık ya da yıllık; sunucu fiyatı tanımıyorsa (eski fiyat) null. */
/** Aboneliğin ödeme kaynağı: Stripe (site ve Mac) ya da App Store (iPhone; yalnızca Apple'da yönetilir). */
export type SubscriptionSource = "stripe" | "app_store";

interface SubscriptionBase {
  /** Alanı bilmeyen eski sunucuda `stripe`. */
  readonly source: SubscriptionSource;
  readonly status: string;
  readonly plan: BillingPlan | null;
  /** Aboneliğin katmanı (ücretsiz erişimde `personal`); alanı bilmeyen eski sunucuda `personal`. */
  readonly tier: SubscriptionTier;
  readonly currentPeriodEnd: string;
  readonly cancelAt: string | null;
  readonly complimentary: boolean;
  /**
   * Cayma hakkının (AB CRD Art. 11a) son anı (ISO 8601): Stripe aboneliğinin başlangıcından 14 gün; cayılamıyorsa (App
   * Store, ücretsiz erişim, süre geçti) ya da alanı bilmeyen eski sunucuda null.
   */
  readonly withdrawableUntil: string | null;
  /**
   * Abone caydı ama iadesi henüz doğrulanmadı (biri başarısız oldu ya da Stripe'ta bekliyor): kart yeniden denemeyi
   * gösterir; sunucu her gün yeniden dener. Alanı bilmeyen eski sunucuda false.
   */
  readonly withdrawalPending: boolean;
}

/**
 * `POST /v1/billing/withdraw` yanıtı: iade edilen tutar (en küçük birimde), para birimi (ISO 4217, küçük harf olabilir)
 * ve iadenin Stripe'ta hâlâ bekleyip beklemediği (alanı bilmeyen eski sunucuda false).
 */
export interface WithdrawalResult {
  readonly refundedCents: number;
  readonly currency: string;
  readonly pending: boolean;
}

/**
 * `GET /v1/me` yanıtındaki abonelik: ek sürenin bitişi yalnızca `grace` durumunda vardır. `cancelAt` iptal edilmiş
 * aboneliğin biteceği andır; yenilenecekse null. `complimentary`: yöneticinin verdiği ücretsiz erişim (ödeme yok,
 * Stripe'ta yönetilecek bir şey yok).
 */
export type SubscriptionInfo =
  | (SubscriptionBase & { readonly access: "grace"; readonly graceEndsAt: string })
  | (SubscriptionBase & { readonly access: "active" | "none"; readonly graceEndsAt: null });

/**
 * `GET /v1/referral` yanıtı: davet programı açık mı, abonenin kodu ve davet adresi (abonelik erişimi yoksa ya da program
 * kapalıysa null), katılan, ödülü verilen ve bekleyen arkadaş sayısı, bekleyen ödülün en yakın tahmini tarihi (ISO 8601;
 * yoksa null), hesabın ücretsiz erişimi (ödül uygulanmaz), bu yıl kalan ödül, yıllık en çok ödül, ödülün tutarı (USD) ve
 * ödülden önce iadesiz geçmesi gereken gün.
 */
export interface ReferralInfo {
  readonly enabled: boolean;
  readonly code: string | null;
  readonly inviteUrl: string | null;
  readonly joined: number;
  readonly rewarded: number;
  readonly pending: number;
  readonly nextRewardAt: string | null;
  readonly complimentary: boolean;
  /** Asıl abonelik App Store'dan: ödül (web ödemesinden düşülen alacak) Apple faturasına uygulanmaz. */
  readonly appStoreBilled: boolean;
  readonly rewardsLeftThisYear: number;
  readonly rewardsPerYear: number;
  readonly rewardUsd: number;
  readonly holdDays: number;
}

/** `GET /v1/me` yanıtı. */
export interface Entitlements {
  readonly userId: string;
  readonly plan: "trial" | "subscription";
  readonly trialMeetingsTotal: number;
  /** Denemenin süresi (gün; ilk deneme toplantısından başlar). */
  readonly trialDays: number;
  /** Kalan deneme toplantısı; deneme süresi dolduysa 0. */
  readonly trialMeetingsLeft: number;
  /** Deneme süresinin bittiği an (ISO 8601); deneme başlamadıysa ya da abonelikte null. */
  readonly trialEndsAt: string | null;
  readonly monthlyHoursUsed: number;
  readonly monthlyHoursCap: number;
  /** Aylık saat sınırının sıfırlandığı an: sonraki UTC ayının başı (ISO 8601). */
  readonly monthlyResetsAt: string;
  /** Toplantı dışı yapay zekâ hakkının (Sor, notu yeniden yazma, paylaşım çevirisi, görev araçları) dönemde sayılan tokeni. */
  readonly accountTokensUsed: number;
  /** Toplantı dışı yapay zekâ hakkı: abonede aylık, denemede günlük token sınırı. */
  readonly accountTokensCap: number;
  /** Toplantı dışı hakkın sıfırlandığı an (ISO 8601): abonede sonraki UTC ayının, denemede sonraki UTC gününün başı. */
  readonly accountTokensResetsAt: string;
  /** Hiç abonelik satırı yoksa null; `plan` "subscription" ise her zaman vardır (ayrıştırıcı denetler). */
  readonly subscription: SubscriptionInfo | null;
  /**
   * Ücretli erişimin katmanı; ücretli erişim yoksa (deneme ya da hiçbiri) null. Alanı bilmeyen eski sunucuda abonelik
   * planında `personal`.
   */
  readonly tier: SubscriptionTier | null;
  /**
   * Şu an satın alınabilen katmanlar, gösterim sırasıyla; Pro yalnızca sunucu sunduğunda vardır. Alanı bilmeyen eski
   * sunucuda boş: yalnızca Personal satılır (saatleri bilinmez, katman seçimi gösterilmez).
   */
  readonly offeredTiers: readonly TierOffer[];
}

/** Sunucunun `{error: {code, message}}` gövdesiyle döndürdüğü hata. */
export class ApiRequestError extends Error {
  override readonly name: string = "ApiRequestError";
  readonly status: number;
  readonly code: string;
  readonly path: string;
  /** Yetkisiz yönetim isteğinde (403 `forbidden`) sunucunun bildirdiği giriş kimliği (`google:<sub>`); yoksa null. */
  readonly identity: string | null;

  constructor(path: string, status: number, code: string, message: string, identity: string | null) {
    super(`${path} isteği başarısız (durum ${status}, kod ${code}): ${message}`);
    this.status = status;
    this.code = code;
    this.path = path;
    this.identity = identity;
  }
}

/** Sunucuya ulaşılamadı (ağ hatası, CORS reddi). */
export class ApiNetworkError extends Error {
  override readonly name: string = "ApiNetworkError";
  readonly path: string;

  constructor(path: string, cause: string) {
    super(`${path} isteği sunucuya ulaşamadı: ${cause}`);
    this.path = path;
  }
}

/**
 * Yönetici isteği Cloudflare Access girişine yönlendirildi: Access oturumu yok ya da süresi doldu. Tarayıcı isteği
 * izlemez (`redirect: "manual"`); sayfa yeniden yüklenince Access girişi açılır.
 */
export class AccessSessionError extends Error {
  override readonly name: string = "AccessSessionError";
  readonly path: string;

  constructor(path: string) {
    super(`${path} isteği Cloudflare Access girişine yönlendirildi; sayfayı yeniden yükle.`);
    this.path = path;
  }
}

/** Yönetici API'sinin yolları: bunlar `adminApiBase`'e gider. */
const adminPathPrefix: string = "/v1/admin/";

/** İsteğin gideceği kaynak: yönetici yolları `adminApiBase`'e, diğerleri `apiBase`'e. Saf fonksiyondur. */
export function requestOrigin(config: SiteConfig, path: string): string {
  return path.startsWith(adminPathPrefix) ? config.adminApiBase : config.apiBase;
}

/** Yanıt beklenen biçimde değil. */
export class ApiResponseError extends Error {
  override readonly name: string = "ApiResponseError";
  readonly path: string;
  readonly status: number;
  readonly body: string;

  constructor(path: string, status: number, problem: string, body: string) {
    super(`${path} yanıtı beklenen biçimde değil (durum ${status}): ${problem}; gövde: ${body.slice(0, 300)}`);
    this.path = path;
    this.status = status;
    this.body = body;
  }
}

/** JSON değeri (ayrıştırma sonrası; alanlar aşağıdaki okuyucularla doğrulanır). */
export type JsonValue = string | number | boolean | null | JsonValue[] | { readonly [key: string]: JsonValue };
/** JSON nesnesi. */
export type JsonObject = { readonly [key: string]: JsonValue };

/** HTTP yöntemleri. */
type Method = "GET" | "POST" | "PUT" | "DELETE";

/** Bir isteğin tanımı. */
export interface ApiCall {
  readonly method: Method;
  readonly path: string;
  /** JSON gövde; gövdesiz istekte null. */
  readonly body: JsonObject | null;
  /** Bearer erişim jetonu; kimliksiz istekte null. */
  readonly accessToken: string | null;
  /** Ağ hatası ve 502/503/504'te toplam deneme sayısı; yan etkili istekte 1. */
  readonly attempts: number;
}

/** Ham yanıt: durum ve gövde metni. */
export interface RawResponse {
  readonly status: number;
  readonly text: string;
}

/** Değer JSON nesnesi mi. Saf fonksiyondur. */
function isObject(value: JsonValue): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Nesnedeki metin alanı; yoksa `ApiResponseError`. */
export function stringField(object: JsonObject, key: string, response: RawResponse, path: string): string {
  const value: JsonValue | undefined = object[key];
  if (typeof value !== "string") {
    throw new ApiResponseError(path, response.status, `"${key}" metin değil`, response.text);
  }
  return value;
}

/** Nesnedeki sayı alanı; yoksa `ApiResponseError`. */
export function numberField(object: JsonObject, key: string, response: RawResponse, path: string): number {
  const value: JsonValue | undefined = object[key];
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" sayı değil`, response.text);
  }
  return value;
}

/** Nesnedeki mantıksal alan; değilse (eksikse de) `ApiResponseError`. */
export function booleanField(object: JsonObject, key: string, response: RawResponse, path: string): boolean {
  const value: JsonValue | undefined = object[key];
  if (typeof value !== "boolean") {
    throw new ApiResponseError(path, response.status, `"${key}" mantıksal değil`, response.text);
  }
  return value;
}

/** Nesnedeki metin ya da null alanı; ikisi de değilse (eksikse de) `ApiResponseError`. */
export function nullableStringField(object: JsonObject, key: string, response: RawResponse, path: string): string | null {
  return object[key] === null ? null : stringField(object, key, response, path);
}

/** Nesnedeki iç nesne; değilse `ApiResponseError`. */
export function objectField(object: JsonObject, key: string, response: RawResponse, path: string): JsonObject {
  const value: JsonValue | undefined = object[key];
  if (value === undefined || !isObject(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" nesne değil`, response.text);
  }
  return value;
}

/** Nesnedeki nesne dizisi; dizi değilse ya da öğelerden biri nesne değilse `ApiResponseError`. */
export function objectArrayField(object: JsonObject, key: string, response: RawResponse, path: string): JsonObject[] {
  const value: JsonValue | undefined = object[key];
  if (!Array.isArray(value)) {
    throw new ApiResponseError(path, response.status, `"${key}" dizi değil`, response.text);
  }
  return value.map((item: JsonValue, index: number): JsonObject => {
    if (!isObject(item)) {
      throw new ApiResponseError(path, response.status, `"${key}[${index}]" nesne değil`, response.text);
    }
    return item;
  });
}

/** Gövdeyi JSON nesnesi olarak ayrıştırır; değilse `ApiResponseError`. */
export function parseObject(response: RawResponse, path: string): JsonObject {
  let parsed: JsonValue;
  try {
    parsed = JSON.parse(response.text) as JsonValue;
  } catch {
    throw new ApiResponseError(path, response.status, "JSON değil", response.text);
  }
  if (!isObject(parsed)) {
    throw new ApiResponseError(path, response.status, "JSON nesnesi değil", response.text);
  }
  return parsed;
}

/** Hata yanıtını `ApiRequestError`'a çevirir (gövde sunucunun hata biçiminde değilse kod `http_<durum>`). */
function requestError(response: RawResponse, path: string): ApiRequestError {
  try {
    const body: JsonObject = parseObject(response, path);
    const error: JsonValue | undefined = body["error"];
    if (error !== undefined && isObject(error)) {
      const identity: JsonValue | undefined = error["identity"];
      return new ApiRequestError(
        path,
        response.status,
        stringField(error, "code", response, path),
        stringField(error, "message", response, path),
        typeof identity === "string" ? identity : null,
      );
    }
  } catch (problem: unknown) {
    if (!(problem instanceof ApiResponseError)) {
      throw problem;
    }
  }
  return new ApiRequestError(path, response.status, `http_${response.status}`, response.text.slice(0, 300), null);
}

/** Yeniden denenebilir durum: 502/503/504 (ağ geçidi ya da Worker'ın geçici üst servis hatası). */
function isRetryableStatus(status: number): boolean {
  return status === 502 || status === 503 || status === 504;
}

/** Bekler. */
function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve: () => void): void => {
    setTimeout(resolve, milliseconds);
  });
}

/** Tek bir HTTP isteği; ağ hatası `ApiNetworkError`. */
async function sendOnce(call: ApiCall): Promise<RawResponse> {
  const headers: Headers = new Headers();
  if (call.body !== null) {
    headers.set("content-type", "application/json");
  }
  if (call.accessToken !== null) {
    headers.set("authorization", `Bearer ${call.accessToken}`);
  }
  let response: Response;
  try {
    // Çerez yalnızca aynı kaynağa gider: yayında yönetici isteklerine Cloudflare Access çerezi (`CF_Authorization`);
    // api.gistsmith.com'a giden isteklerde çerez yoktur. Sunucu yönlendirmez; yönlendirme ancak Access girişidir ve
    // izlenmez.
    response = await fetch(`${requestOrigin(siteConfig, call.path)}${call.path}`, {
      method: call.method,
      headers,
      body: call.body === null ? null : JSON.stringify(call.body),
      credentials: "same-origin",
      redirect: "manual",
      cache: "no-store",
    });
  } catch (error: unknown) {
    throw new ApiNetworkError(call.path, error instanceof Error ? error.message : String(error));
  }
  if (response.type === "opaqueredirect") {
    throw new AccessSessionError(call.path);
  }
  return { status: response.status, text: await response.text() };
}

/**
 * İsteği gönderir; ağ hatası ve 502/503/504'te `attempts` kez dener (her denemede uyarı loglanır), sonra son hatayı
 * fırlatır. 2xx dışı yanıt `ApiRequestError`.
 */
export async function send(call: ApiCall): Promise<RawResponse> {
  let lastError: Error = new ApiNetworkError(call.path, "hiç denenmedi");
  for (let attempt: number = 1; attempt <= call.attempts; attempt += 1) {
    try {
      const response: RawResponse = await sendOnce(call);
      if (response.status >= 200 && response.status < 300) {
        return response;
      }
      const error: ApiRequestError = requestError(response, call.path);
      if (!isRetryableStatus(response.status)) {
        throw error;
      }
      lastError = error;
    } catch (error: unknown) {
      if (!(error instanceof ApiNetworkError)) {
        throw error;
      }
      lastError = error;
    }
    if (attempt < call.attempts) {
      console.warn("api_retry", { path: call.path, attempt, error: lastError.message });
      await delay(400 * 2 ** (attempt - 1));
    }
  }
  throw lastError;
}

/** Oturum yanıtını okur. */
export function parseSession(response: RawResponse, path: string): SessionTokens {
  const body: JsonObject = parseObject(response, path);
  return {
    accessToken: stringField(body, "accessToken", response, path),
    refreshToken: stringField(body, "refreshToken", response, path),
    expiresIn: numberField(body, "expiresIn", response, path),
    userId: stringField(body, "userId", response, path),
  };
}

/** `{url}` yanıtını okur (Checkout ve Portal). */
export function parseRedirectUrl(response: RawResponse, path: string): string {
  const url: string = stringField(parseObject(response, path), "url", response, path);
  if (!url.startsWith("https://")) {
    throw new ApiResponseError(path, response.status, "adres https değil", response.text);
  }
  return url;
}

/** Abonelik alanını okur. */
function parseSubscription(value: JsonValue | undefined, response: RawResponse, path: string): SubscriptionInfo | null {
  if (value === null) {
    return null;
  }
  if (value === undefined || !isObject(value)) {
    throw new ApiResponseError(path, response.status, '"subscription" nesne ya da null değil', response.text);
  }
  const access: string = stringField(value, "access", response, path);
  if (access !== "active" && access !== "grace" && access !== "none") {
    throw new ApiResponseError(path, response.status, `bilinmeyen erişim "${access}"`, response.text);
  }
  const status: string = stringField(value, "status", response, path);
  const rawPlan: string | null = nullableStringField(value, "plan", response, path);
  const plan: BillingPlan | null = billingPlanOf(rawPlan);
  if (rawPlan !== null && plan === null) {
    throw new ApiResponseError(path, response.status, `bilinmeyen abonelik planı "${rawPlan}"`, response.text);
  }
  const currentPeriodEnd: string = stringField(value, "currentPeriodEnd", response, path);
  const cancelAt: string | null = value["cancelAt"] === null ? null : stringField(value, "cancelAt", response, path);
  const complimentary: boolean = booleanField(value, "complimentary", response, path);
  const source: SubscriptionSource = subscriptionSourceOf(value, response, path);
  // Alanı bilmeyen eski sunucu yalnızca Personal satar.
  const tier: SubscriptionTier = value["tier"] === undefined ? "personal" : tierField(value, "tier", response, path);
  // Alanı bilmeyen eski sunucuda cayma işlevi yoktur.
  const withdrawableUntil: string | null = value["withdrawableUntil"] === undefined ? null : nullableStringField(value, "withdrawableUntil", response, path);
  const withdrawalPending: boolean = value["withdrawalPending"] === undefined ? false : booleanField(value, "withdrawalPending", response, path);
  if (access === "grace") {
    return {
      source,
      status,
      plan,
      tier,
      currentPeriodEnd,
      cancelAt,
      complimentary,
      withdrawableUntil,
      withdrawalPending,
      access,
      graceEndsAt: stringField(value, "graceEndsAt", response, path),
    };
  }
  if (value["graceEndsAt"] !== null) {
    throw new ApiResponseError(path, response.status, '"graceEndsAt" ek süre dışında null değil', response.text);
  }
  return { source, status, plan, tier, currentPeriodEnd, cancelAt, complimentary, withdrawableUntil, withdrawalPending, access, graceEndsAt: null };
}

/** `POST /v1/billing/withdraw` yanıtını okur: negatif olmayan tam sayı tutar ve üç harfli para birimi. */
export function parseWithdrawal(response: RawResponse, path: string): WithdrawalResult {
  const body: JsonObject = parseObject(response, path);
  const refundedCents: number = numberField(body, "refundedCents", response, path);
  if (!Number.isInteger(refundedCents) || refundedCents < 0) {
    throw new ApiResponseError(path, response.status, `"refundedCents" negatif olmayan tam sayı değil: ${String(refundedCents)}`, response.text);
  }
  const currency: string = stringField(body, "currency", response, path);
  if (!/^[A-Za-z]{3}$/.test(currency)) {
    throw new ApiResponseError(path, response.status, `"currency" ISO 4217 değil: ${currency}`, response.text);
  }
  const pending: boolean = body["pending"] === undefined ? false : booleanField(body, "pending", response, path);
  return { refundedCents, currency: currency.toUpperCase(), pending };
}

/** Nesnedeki katman alanı; tanınmayan değer (eksikse de) `ApiResponseError`. */
function tierField(object: JsonObject, key: string, response: RawResponse, path: string): SubscriptionTier {
  const raw: string = stringField(object, key, response, path);
  const tier: SubscriptionTier | null = subscriptionTierOf(raw);
  if (tier === null) {
    throw new ApiResponseError(path, response.status, `bilinmeyen katman "${raw}"`, response.text);
  }
  return tier;
}

/** Sunulan katmanlar dizisini okur (`offeredTiers`, `tiers`): her öğe katman, aylık saat ve toplantı süresi sınırı. */
function tierOffersField(object: JsonObject, key: string, response: RawResponse, path: string): TierOffer[] {
  const offers: TierOffer[] = objectArrayField(object, key, response, path).map(
    (item: JsonObject): TierOffer => ({
      tier: tierField(item, "tier", response, path),
      monthlyHours: numberField(item, "monthlyHours", response, path),
      meetingMaxMinutes: numberField(item, "meetingMaxMinutes", response, path),
    }),
  );
  if (new Set(offers.map((offer: TierOffer): SubscriptionTier => offer.tier)).size !== offers.length) {
    throw new ApiResponseError(path, response.status, `"${key}" aynı katmanı birden çok kez içeriyor`, response.text);
  }
  return offers;
}

/** Hesabın ücretli erişim katmanı; null olabilir. Alanı bilmeyen eski sunucuda abonelik planı `personal`dır. */
function entitlementTier(body: JsonObject, plan: "trial" | "subscription", response: RawResponse, path: string): SubscriptionTier | null {
  if (body["tier"] === undefined) {
    return plan === "subscription" ? "personal" : null;
  }
  return body["tier"] === null ? null : tierField(body, "tier", response, path);
}

/** `GET /v1/pricing` yanıtını okur: şu an satılan katmanlar ve sınırları. */
export function parsePricing(response: RawResponse, path: string): TierOffer[] {
  return tierOffersField(parseObject(response, path), "tiers", response, path);
}

/** Aboneliğin kaynağı; alan yoksa (eski sunucu) `stripe`, tanınmayan değer hatadır. */
function subscriptionSourceOf(value: JsonObject, response: RawResponse, path: string): SubscriptionSource {
  if (value["source"] === undefined) {
    return "stripe";
  }
  const source: string = stringField(value, "source", response, path);
  if (source !== "stripe" && source !== "app_store") {
    throw new ApiResponseError(path, response.status, `bilinmeyen abonelik kaynağı "${source}"`, response.text);
  }
  return source;
}

/** `GET /v1/referral` yanıtını okur. */
export function parseReferral(response: RawResponse, path: string): ReferralInfo {
  const body: JsonObject = parseObject(response, path);
  return {
    enabled: booleanField(body, "enabled", response, path),
    code: nullableStringField(body, "code", response, path),
    inviteUrl: nullableStringField(body, "inviteUrl", response, path),
    joined: numberField(body, "joined", response, path),
    rewarded: numberField(body, "rewarded", response, path),
    pending: numberField(body, "pending", response, path),
    nextRewardAt: nullableStringField(body, "nextRewardAt", response, path),
    complimentary: booleanField(body, "complimentary", response, path),
    // Bu alanı bilmeyen eski sunucu yalnızca Stripe aboneliğine kod verir (bkz. `subscriptionSourceOf`).
    appStoreBilled: body["appStoreBilled"] === undefined ? false : booleanField(body, "appStoreBilled", response, path),
    rewardsLeftThisYear: numberField(body, "rewardsLeftThisYear", response, path),
    rewardsPerYear: numberField(body, "rewardsPerYear", response, path),
    rewardUsd: numberField(body, "rewardUsd", response, path),
    holdDays: numberField(body, "holdDays", response, path),
  };
}

/** `POST /v1/referral/validate` yanıtını okur: sunucunun biçimlediği geçerli kod. */
export function parseValidatedReferralCode(response: RawResponse, path: string): string {
  return stringField(parseObject(response, path), "code", response, path);
}

/** `GET /v1/download/mac/version` yanıtını okur: yayınlanmış en son Mac sürümü (ör. "0.1.4"). */
export function parseLatestVersion(response: RawResponse, path: string): string {
  const version: string = stringField(parseObject(response, path), "version", response, path);
  if (!/^[0-9]+(\.[0-9]+){1,3}$/.test(version)) {
    throw new ApiResponseError(path, response.status, `sürüm biçimsiz "${version}"`, response.text);
  }
  return version;
}

/** `GET /v1/me` yanıtını okur. */
export function parseEntitlements(response: RawResponse, path: string): Entitlements {
  const body: JsonObject = parseObject(response, path);
  const plan: string = stringField(body, "plan", response, path);
  if (plan !== "trial" && plan !== "subscription") {
    throw new ApiResponseError(path, response.status, `bilinmeyen plan "${plan}"`, response.text);
  }
  const subscription: SubscriptionInfo | null = parseSubscription(body["subscription"], response, path);
  // Sunucu planı aboneliğin erişiminden üretir: abonelik planı abonelik satırı olmadan gelmez.
  if (plan === "subscription" && subscription === null) {
    throw new ApiResponseError(path, response.status, "abonelik planında abonelik bilgisi yok", response.text);
  }
  return {
    userId: stringField(body, "userId", response, path),
    plan,
    trialMeetingsTotal: numberField(body, "trialMeetingsTotal", response, path),
    trialDays: numberField(body, "trialDays", response, path),
    trialMeetingsLeft: numberField(body, "trialMeetingsLeft", response, path),
    trialEndsAt: body["trialEndsAt"] === null ? null : stringField(body, "trialEndsAt", response, path),
    monthlyHoursUsed: numberField(body, "monthlyHoursUsed", response, path),
    monthlyHoursCap: numberField(body, "monthlyHoursCap", response, path),
    monthlyResetsAt: stringField(body, "monthlyResetsAt", response, path),
    accountTokensUsed: numberField(body, "accountTokensUsed", response, path),
    accountTokensCap: numberField(body, "accountTokensCap", response, path),
    accountTokensResetsAt: stringField(body, "accountTokensResetsAt", response, path),
    subscription,
    // Alanları bilmeyen eski sunucu yalnızca Personal satar (bkz. `Entitlements.tier`, `offeredTiers`).
    tier: entitlementTier(body, plan, response, path),
    offeredTiers: body["offeredTiers"] === undefined ? [] : tierOffersField(body, "offeredTiers", response, path),
  };
}
