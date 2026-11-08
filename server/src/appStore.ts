import { z } from "zod";
import type { AppStoreProducts, RevenueCatWebhookConfig, SubscriptionPlan, SubscriptionTier } from "./config";
import { constantTimeEqualText } from "./crypto";
import { ApiError, UpstreamError } from "./errors";
import { log } from "./log";
import { recordOpsEvents } from "./opsEvents";
import type { Platform } from "./platform";
import { fetchUpstream } from "./upstream";

/**
 * App Store abonelikleri (iPhone uygulaması, RevenueCat; göç 0048). Uygulama satın almayı RevenueCat SDK'sıyla yapar ve
 * RevenueCat'te kullanıcıyı bizim hesap kimliğimizle tanıtır (`Purchases.logIn(userId)`: `app_user_id` = `users.id`).
 *
 * Durum olaylardan değil RevenueCat REST API'sinden okunur: RevenueCat her webhook olayında `GET /v1/subscribers` ile
 * güncel durumun okunmasını önerir (olay türlerini tek tek işlemekten basit, teslimat sırası garanti değil, yinelenebilir).
 * Webhook yalnızca "bu hesapların durumu değişti" sinyalidir; `syncAppStoreSubscription` hesabın App Store aboneliğini
 * okur ve satırı onunla değiştirir. Uygulama satın almadan hemen sonra aynı eşitlemeyi `POST /v1/billing/app-store/sync`
 * ile ister (webhook saniyeler sürebilir).
 *
 * Hak Stripe aboneliğinden bağımsızdır: hesap iki kaynaktan birinden abone olabilir (bkz. `entitlements.ts`).
 */

/** RevenueCat REST API'sinin (v1) kökü. */
const revenueCatApiBase: string = "https://api.revenuecat.com/v1";
/** RevenueCat çağrısının deneme sayısı ve deneme başına zaman aşımı (webhook 60 sn içinde yanıtlanmalı). */
const revenueCatAttempts: number = 3;
const revenueCatTimeoutMs: number = 10_000;

/** Apple'ın abonelik yönetim sayfası (iPhone'da Ayarlar › [ad] › Abonelikler'i açar). */
export const appStoreManageUrl: string = "https://apps.apple.com/account/subscriptions";

/**
 * Yenilenecek (`active`) App Store aboneliğinin dönem sonundan sonra erişimi koruduğu süre: Apple yenilemeyi dönem
 * sonundan önceki 24 saatte tahsil eder; yenileme olayı ve eşitleme gecikirse abone bu sürede denemeye düşmez. Ödeme
 * alınamazsa RevenueCat `BILLING_ISSUE` gönderir ve satır `billing_issue` olur (bu süre uygulanmaz).
 */
export const appStoreRenewalGraceMs: number = 24 * 3_600_000;

/**
 * Satırın durumu (göç 0048'deki açıklama): RevenueCat okumasının anındaki (`synced_at`) anlık görüntüdür, şimdiki durum
 * değildir. Dönem sonu bir olay gelmeden geçebilir (ör. `active` satırın yenileme olayı kaybolursa): erişim ve sayımlar
 * durumu tek başına okumaz, `appStoreAccess` / `appStoreActiveSql` / `appStoreGraceSql` ile anla birlikte türetir.
 */
export type AppStoreStatus = "active" | "canceled" | "billing_issue" | "expired" | "refunded";

/** RevenueCat ortamı. */
export type AppStoreEnvironment = "PRODUCTION" | "SANDBOX";

/** App Store aboneliğinin erişimi (`entitlements.SubscriptionAccess` ile aynı değerler). */
export type AppStoreAccess = "active" | "grace" | "none";

/** App Store abonelikleri RevenueCat'te bu mağazalardandır (göç 0059 tetikleyicisi aynı listeyi zorlar). */
export const appStoreStoreNames: readonly ["app_store", "mac_app_store"] = ["app_store", "mac_app_store"];

/** Satırın mağazası. */
export type AppStoreStore = (typeof appStoreStoreNames)[number];

/** RevenueCat mağaza adı bizim App Store mağazalarımızdan biri mi. Saf fonksiyondur. */
export function isAppStoreStore(value: string): value is AppStoreStore {
  return appStoreStoreNames.some((store: AppStoreStore): boolean => store === value);
}

/** Hesabın App Store aboneliği (`app_store_subscriptions` satırı). */
export interface AppStoreSubscription {
  readonly store: AppStoreStore;
  readonly productId: string;
  /** Ürün kimliğinden plan; tanınmayan üründe null (hak verir, MRR'a girmez). */
  readonly plan: SubscriptionPlan | null;
  /** Tier from the product id (`appStoreTierOf`; an unknown product is Personal). */
  readonly tier: SubscriptionTier;
  readonly status: AppStoreStatus;
  /** RevenueCat dönem türü (`normal`, `trial`, `intro`, `promotional`, `prepaid`). */
  readonly periodType: string;
  readonly purchasedAt: number;
  readonly expiresAt: number;
  /** Fatura ek süresinin sonu (ms); ek süre yoksa null. */
  readonly graceExpiresAt: number | null;
  readonly environment: AppStoreEnvironment;
}

/** Eşitlemenin okuduğu ayarlar (`Config.appStore` ve webhook yapılandırması ikisi de verir). */
export interface AppStoreSyncSettings {
  readonly revenueCatApiKey: string;
  readonly products: AppStoreProducts;
  readonly acceptSandbox: boolean;
}

/**
 * App Store aboneliğinin şimdiki erişimi. Sandbox satırı `acceptSandbox` kapalıyken erişim vermez. `active`: yenilenecek
 * abonelik dönem sonu + `appStoreRenewalGraceMs`'e, yenilenmeyecek ya da ödemesi sorunlu abonelik dönem sonuna dek;
 * `grace`: dönem sonu geçmiş, ödemesi sorunlu abonelik Apple'ın fatura ek süresi (`graceExpiresAt`) içinde. SQL karşılığı
 * `appStoreActiveSql` ve `appStoreGraceSql`. Saf fonksiyondur.
 */
export function appStoreAccess(subscription: AppStoreSubscription | null, acceptSandbox: boolean, now: Date): AppStoreAccess {
  if (subscription === null || (subscription.environment === "SANDBOX" && !acceptSandbox)) {
    return "none";
  }
  const nowMs: number = now.getTime();
  if (subscription.status === "active" && subscription.expiresAt + appStoreRenewalGraceMs > nowMs) {
    return "active";
  }
  if ((subscription.status === "canceled" || subscription.status === "billing_issue") && subscription.expiresAt > nowMs) {
    return "active";
  }
  if (subscription.status === "billing_issue" && subscription.graceExpiresAt !== null && subscription.graceExpiresAt > nowMs) {
    return "grace";
  }
  return "none";
}

/** `appStoreAccess` `active` (`app_store_subscriptions a`; bağ ?1 = şimdi, ms). Ortam denetimi çağıranın işidir. */
export const appStoreActiveSql: string = `((a.status = 'active' AND a.expires_at + ${appStoreRenewalGraceMs} > ?1)
  OR (a.status IN ('canceled', 'billing_issue') AND a.expires_at > ?1))`;

/** `appStoreAccess` `grace` (`app_store_subscriptions a`; bağ ?1 = şimdi, ms). */
export const appStoreGraceSql: string = "(a.status = 'billing_issue' AND a.expires_at <= ?1 AND a.grace_expires_at > ?1)";

/**
 * Hesabın erişimi olan App Store aboneliği var mı (`appStoreAccess` ≠ `none`); hesap kimliğinin SQL ifadesi `userRef`,
 * bağlar ?1 = şimdi (ms), `sandboxRef` = sandbox kabul ediliyorsa 1, değilse 0 olan SQL ifadesi.
 */
export function appStoreAccessExistsSql(userRef: string, sandboxRef: string): string {
  return `EXISTS (SELECT 1 FROM app_store_subscriptions a WHERE a.user_id = ${userRef}
    AND (a.environment = 'PRODUCTION' OR ${sandboxRef} = 1) AND (${appStoreActiveSql} OR ${appStoreGraceSql}))`;
}

/**
 * Hesap App Store'da ödemiş sayılır mı (dönüşüm, silme kesimi): üretim ortamında, ücretsiz deneme döneminde olmayan
 * (ya da denemeden ücretliye geçmiş) bir App Store aboneliği var. İade edilmiş abonelik de ödemiş sayılır (Stripe'taki
 * iptal gibi). `userRef`: hesap kimliğinin SQL ifadesi.
 */
export function appStorePaidSql(userRef: string): string {
  return `EXISTS (SELECT 1 FROM app_store_subscriptions a WHERE a.user_id = ${userRef} AND a.environment = 'PRODUCTION' AND a.period_type <> 'trial')`;
}

/** `app_store_subscriptions` satırı. */
interface AppStoreRow {
  readonly store: AppStoreStore;
  readonly product_id: string;
  readonly plan: SubscriptionPlan | null;
  readonly tier: SubscriptionTier;
  readonly status: AppStoreStatus;
  readonly period_type: string;
  readonly purchased_at: number;
  readonly expires_at: number;
  readonly grace_expires_at: number | null;
  readonly environment: AppStoreEnvironment;
}

/** Hesabın App Store aboneliği (satır yoksa null). */
export async function appStoreSubscriptionOf(db: D1Database, userId: string): Promise<AppStoreSubscription | null> {
  const row: AppStoreRow | null = await db
    .prepare(
      `SELECT store, product_id, plan, tier, status, period_type, purchased_at, expires_at, grace_expires_at, environment
       FROM app_store_subscriptions WHERE user_id = ?`,
    )
    .bind(userId)
    .first<AppStoreRow>();
  return row === null
    ? null
    : {
        store: row.store,
        productId: row.product_id,
        plan: row.plan,
        tier: row.tier,
        status: row.status,
        periodType: row.period_type,
        purchasedAt: row.purchased_at,
        expiresAt: row.expires_at,
        graceExpiresAt: row.grace_expires_at,
        environment: row.environment,
      };
}

// MARK: RevenueCat REST

/** RevenueCat tarihleri ISO 8601 (UTC, `Z`, isteğe bağlı kesirli saniye). */
const revenueCatDate = z.iso.datetime({ offset: true });

/** `subscriber.subscriptions.<ürün>`: yalnızca kullanılan alanlar (bilinmeyenler atılır). */
const revenueCatSubscriptionSchema = z.object({
  expires_date: revenueCatDate.nullable(),
  purchase_date: revenueCatDate,
  period_type: z.string().min(1),
  store: z.string().min(1),
  is_sandbox: z.boolean(),
  unsubscribe_detected_at: revenueCatDate.nullish(),
  billing_issues_detected_at: revenueCatDate.nullish(),
  grace_period_expires_date: revenueCatDate.nullish(),
  refunded_at: revenueCatDate.nullish(),
});

/** RevenueCat'in abonelik kaydı. */
export type RevenueCatSubscription = z.output<typeof revenueCatSubscriptionSchema>;

/** `GET /v1/subscribers/{app_user_id}` yanıtı (yalnızca kullanılan alanlar). */
const revenueCatSubscriberSchema = z.object({
  request_date_ms: z.number().int().positive(),
  subscriber: z.object({ subscriptions: z.record(z.string(), revenueCatSubscriptionSchema) }),
});

/** RevenueCat'in abone yanıtı. */
export type RevenueCatSubscriber = z.output<typeof revenueCatSubscriberSchema>;

/** ISO tarihini ms'ye çevirir (null/undefined → null). Saf fonksiyondur. */
function msOrNull(value: string | null | undefined): number | null {
  return value === null || value === undefined ? null : Date.parse(value);
}

/**
 * RevenueCat kaydının okuma anındaki durumu: iade edildiyse `refunded`; dönem sürüyorsa yenilenmeyecekse `canceled`,
 * ödemesi sorunluysa `billing_issue`, değilse `active`; dönem bittiyse fatura ek süresindeyse `billing_issue`, değilse
 * `expired`. Saf fonksiyondur.
 */
export function appStoreStatusOf(subscription: RevenueCatSubscription, expiresAtMs: number, nowMs: number): AppStoreStatus {
  if (msOrNull(subscription.refunded_at) !== null) {
    return "refunded";
  }
  if (expiresAtMs > nowMs) {
    if (msOrNull(subscription.unsubscribe_detected_at) !== null) {
      return "canceled";
    }
    return msOrNull(subscription.billing_issues_detected_at) === null ? "active" : "billing_issue";
  }
  const graceEnd: number | null = msOrNull(subscription.grace_period_expires_date);
  return graceEnd !== null && graceEnd > nowMs ? "billing_issue" : "expired";
}

/** Ürün kimliğinin planı (Personal ya da Pro); tanınmayan üründe null. Saf fonksiyondur. */
export function appStorePlanOf(productId: string, products: AppStoreProducts): SubscriptionPlan | null {
  if (productId === products.monthly || productId === products.proMonthly) {
    return "monthly";
  }
  return productId === products.yearly || productId === products.proYearly ? "yearly" : null;
}

/** The product's tier: Pro for the Pro products, otherwise Personal (an unknown product too). Saf fonksiyondur. */
export function appStoreTierOf(productId: string, products: AppStoreProducts): SubscriptionTier {
  return productId === products.proMonthly || productId === products.proYearly ? "pro" : "personal";
}

/** Seçimde erişimin bittiği an: iade edilmişte 0, değilse dönem sonu ile ek süre sonunun büyüğü. Saf fonksiyondur. */
function accessEndMs(subscription: AppStoreSubscription): number {
  return subscription.status === "refunded" ? 0 : Math.max(subscription.expiresAt, subscription.graceExpiresAt ?? 0);
}

/**
 * RevenueCat abonesinin App Store aboneliği: App Store (iOS ya da Mac App Store) kayıtlarından, sandbox kabul edilmiyorsa
 * sandbox olmayanlardan, erişimi en geç biteni (eşitse en son satın alınanı). Bu RevenueCat projesi yalnızca bu ürünü
 * satar: tanınmayan ürün de hak verir, planı null olur (uyarı loglanır). Kayıt yoksa null. Saf fonksiyondur.
 */
export function appStoreSubscriptionFromRevenueCat(subscriber: RevenueCatSubscriber, products: AppStoreProducts, acceptSandbox: boolean): AppStoreSubscription | null {
  const nowMs: number = subscriber.request_date_ms;
  const candidates: AppStoreSubscription[] = Object.entries(subscriber.subscriber.subscriptions).flatMap(
    ([productId, subscription]: [string, RevenueCatSubscription]): AppStoreSubscription[] => {
      const expiresAt: number | null = msOrNull(subscription.expires_date);
      const store: string = subscription.store;
      if (!isAppStoreStore(store) || expiresAt === null || (subscription.is_sandbox && !acceptSandbox)) {
        return [];
      }
      return [
        {
          store,
          productId,
          plan: appStorePlanOf(productId, products),
          tier: appStoreTierOf(productId, products),
          status: appStoreStatusOf(subscription, expiresAt, nowMs),
          periodType: subscription.period_type,
          purchasedAt: Date.parse(subscription.purchase_date),
          expiresAt,
          graceExpiresAt: msOrNull(subscription.grace_period_expires_date),
          environment: subscription.is_sandbox ? "SANDBOX" : "PRODUCTION",
        },
      ];
    },
  );
  return candidates.reduce<AppStoreSubscription | null>((best: AppStoreSubscription | null, candidate: AppStoreSubscription): AppStoreSubscription => {
    if (best === null) {
      return candidate;
    }
    const difference: number = accessEndMs(candidate) - accessEndMs(best);
    return difference > 0 || (difference === 0 && candidate.purchasedAt > best.purchasedAt) ? candidate : best;
  }, null);
}

/**
 * RevenueCat'ten abonenin kaydını okur (gizli anahtarla). RevenueCat bu uçta abone yoksa yaratır: yalnızca bizim
 * hesaplarımız için çağrılır. Geçici hatalar uyarıyla yeniden denenir (`fetchUpstream`), sonra `UpstreamError`;
 * beklenmeyen gövde `UpstreamError` (alan yolları loglanır).
 */
export async function fetchRevenueCatSubscriber(platform: Platform, apiKey: string, appUserId: string): Promise<RevenueCatSubscriber> {
  const response: Response = await fetchUpstream(
    platform,
    "revenuecat",
    `${revenueCatApiBase}/subscribers/${encodeURIComponent(appUserId)}`,
    (): RequestInit => ({ method: "GET", headers: { authorization: `Bearer ${apiKey}`, accept: "application/json" } }),
    revenueCatAttempts,
    revenueCatTimeoutMs,
  );
  let raw: unknown;
  try {
    raw = await response.json();
  } catch (error: unknown) {
    log("error", "revenuecat_response_not_json", { appUserId, status: response.status, error: error instanceof Error ? error.name : typeof error });
    throw new UpstreamError("revenuecat", response.status, false, "yanıt JSON değil");
  }
  const parsed = revenueCatSubscriberSchema.safeParse(raw);
  if (!parsed.success) {
    const issues: string = parsed.error.issues
      .slice(0, 5)
      .map((issue: z.core.$ZodIssue): string => `${issue.path.join(".")}: ${issue.code}`)
      .join("; ");
    log("error", "revenuecat_response_invalid", { appUserId, status: response.status, issues });
    throw new UpstreamError("revenuecat", response.status, false, "yanıt beklenen biçimde değil");
  }
  return parsed.data;
}

/**
 * Satırı RevenueCat okumasıyla değiştiren ifadeler (tek toplu işlemde çalıştırılır). Daha eski bir okuma daha yenisinin
 * üstüne yazamaz (`synced_at`, okumanın anı `request_date_ms`):
 * - abonelik yoksa (ör. satın alma başka hesaba aktarıldı) satır silinir ve okumanın anı hesaba yazılır
 *   (`users.app_store_absent_synced_at`, göç 0051): satır gidince `synced_at` da gider, bu iz olmadan aktarımdan önce
 *   başlamış eski bir okuma silinen satırı yeniden etkinleştirirdi;
 * - abonelik varsa satır yazılır: hesap hâlâ varsa ve okuma son "yok" okumasından eski değilse (yeni satır), ya da var
 *   olan satırdan eski değilse (güncelleme). Silinmiş hesabın satırı yeniden yaratılmaz.
 */
export function appStoreSyncStatements(
  db: D1Database,
  userId: string,
  subscription: AppStoreSubscription | null,
  eventId: string | null,
  syncedAtMs: number,
  nowMs: number,
): D1PreparedStatement[] {
  if (subscription === null) {
    return [
      db.prepare("DELETE FROM app_store_subscriptions WHERE user_id = ? AND synced_at <= ?").bind(userId, syncedAtMs),
      db
        .prepare("UPDATE users SET app_store_absent_synced_at = MAX(COALESCE(app_store_absent_synced_at, 0), ?2) WHERE id = ?1")
        .bind(userId, syncedAtMs),
    ];
  }
  return [
    db
      .prepare(
        `INSERT INTO app_store_subscriptions (user_id, store, product_id, plan, status, period_type, purchased_at, expires_at,
           grace_expires_at, environment, last_event_id, synced_at, updated_at, tier)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14
         WHERE EXISTS (SELECT 1 FROM users WHERE id = ?1 AND COALESCE(app_store_absent_synced_at, 0) <= ?12)
         ON CONFLICT(user_id) DO UPDATE SET store = excluded.store, product_id = excluded.product_id, plan = excluded.plan,
           tier = excluded.tier,
           status = excluded.status, period_type = excluded.period_type, purchased_at = excluded.purchased_at,
           expires_at = excluded.expires_at, grace_expires_at = excluded.grace_expires_at, environment = excluded.environment,
           last_event_id = COALESCE(excluded.last_event_id, app_store_subscriptions.last_event_id),
           synced_at = excluded.synced_at, updated_at = excluded.updated_at
         WHERE excluded.synced_at >= app_store_subscriptions.synced_at`,
      )
      .bind(
        userId,
        subscription.store,
        subscription.productId,
        subscription.plan,
        subscription.status,
        subscription.periodType,
        subscription.purchasedAt,
        subscription.expiresAt,
        subscription.graceExpiresAt,
        subscription.environment,
        eventId,
        syncedAtMs,
        nowMs,
        subscription.tier,
      ),
  ];
}

/**
 * Hesabın App Store aboneliğini RevenueCat'ten okuyup satırı günceller (`eventId`: tetikleyen webhook olayı; uygulamanın
 * isteğinde null) ve okunan aboneliği döndürür. Tanınmayan ürün uyarıyla loglanır.
 */
export async function syncAppStoreSubscription(
  db: D1Database,
  platform: Platform,
  settings: AppStoreSyncSettings,
  userId: string,
  eventId: string | null,
): Promise<AppStoreSubscription | null> {
  const subscriber: RevenueCatSubscriber = await fetchRevenueCatSubscriber(platform, settings.revenueCatApiKey, userId);
  const subscription: AppStoreSubscription | null = appStoreSubscriptionFromRevenueCat(subscriber, settings.products, settings.acceptSandbox);
  if (subscription !== null && subscription.plan === null) {
    log("warn", "app_store_product_unknown", { userId, productId: subscription.productId });
  }
  await db.batch(appStoreSyncStatements(db, userId, subscription, eventId, subscriber.request_date_ms, platform.now().getTime()));
  log("info", "app_store_synced", {
    userId,
    eventId,
    status: subscription?.status ?? null,
    plan: subscription?.plan ?? null,
    tier: subscription?.tier ?? null,
    environment: subscription?.environment ?? null,
    expiresAt: subscription?.expiresAt ?? null,
  });
  return subscription;
}

// MARK: Webhook

/** RevenueCat'in olaydaki kullanıcı kimliği listeleri (takma adlar, aktarım). */
const appUserIdList = z.array(z.string().min(1).max(256)).max(100).nullish();

/**
 * RevenueCat webhook gövdesi (`{api_version, event}`); yalnızca kullanılan alanlar, bilinmeyenler atılır. Olay türü serbest
 * metindir: RevenueCat sürüm değiştirmeden yeni tür ekleyebilir. `TRANSFER` olayında `app_user_id` yoktur, kimlikler
 * `transferred_from`/`transferred_to`'dadır.
 */
export const revenueCatWebhookSchema = z.object({
  api_version: z.string().min(1).max(16),
  event: z.object({
    id: z.string().min(1).max(200),
    type: z.string().regex(/^[A-Z_]{1,64}$/),
    event_timestamp_ms: z.number().int().nonnegative(),
    environment: z.enum(["SANDBOX", "PRODUCTION"]).nullish(),
    app_user_id: z.string().min(1).max(256).nullish(),
    original_app_user_id: z.string().min(1).max(256).nullish(),
    aliases: appUserIdList,
    transferred_from: appUserIdList,
    transferred_to: appUserIdList,
  }),
});

/** Doğrulanmış webhook olayı. */
export type RevenueCatEvent = z.output<typeof revenueCatWebhookSchema>["event"];

/** Olayın işlenme sonucu (`revenuecat_events.outcome`; `duplicate` yazılmaz). */
export type RevenueCatOutcome = "synced" | "unknown_user" | "sandbox_ignored" | "test" | "duplicate";

/** Webhook yanıtının gövdesi. */
export interface RevenueCatWebhookResult {
  readonly outcome: RevenueCatOutcome;
  /** Eşitlenen hesap sayısı. */
  readonly users: number;
}

/** Bizim hesap kimliklerimiz UUID'dir (`crypto.randomUUID`); RevenueCat'in anonim kimlikleri (`$RCAnonymousID:…`) elenir. */
const userIdPattern: RegExp = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/**
 * Olaydaki aday hesap kimlikleri: `app_user_id`, `original_app_user_id`, takma adlar ve aktarımın iki yanı (aktarılan
 * satın alma eski hesaptan düşmeli, yenisine geçmeli); UUID biçiminde olanlar, sırayla ve tekrarsız. Saf fonksiyondur.
 */
export function revenueCatCandidateUserIds(event: RevenueCatEvent): string[] {
  const all: string[] = [
    event.app_user_id ?? "",
    event.original_app_user_id ?? "",
    ...(event.aliases ?? []),
    ...(event.transferred_from ?? []),
    ...(event.transferred_to ?? []),
  ];
  return [...new Set(all.filter((id: string): boolean => userIdPattern.test(id)))];
}

/** Adaylardan bizde var olan hesaplar (aday sırasıyla). */
async function knownUserIds(db: D1Database, candidates: readonly string[]): Promise<string[]> {
  if (candidates.length === 0) {
    return [];
  }
  const rows = await db
    .prepare("SELECT id FROM users WHERE id IN (SELECT value FROM json_each(?))")
    .bind(JSON.stringify(candidates))
    .all<{ id: string }>();
  const known: Set<string> = new Set(rows.results.map((row: { id: string }): string => row.id));
  return candidates.filter((id: string): boolean => known.has(id));
}

/** İşlenmiş olayın kaydı (aynı olay yeniden gelirse `duplicate`). */
function eventRecordStatement(db: D1Database, event: RevenueCatEvent, outcome: Exclude<RevenueCatOutcome, "duplicate">, nowMs: number): D1PreparedStatement {
  return db
    .prepare("INSERT INTO revenuecat_events (id, type, environment, outcome, processed_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING")
    .bind(event.id, event.type, event.environment ?? "UNKNOWN", outcome, nowMs);
}

/** `Authorization` başlığı panelde girilen değerle birebir aynı mı (sabit zamanlı); değilse `unauthorized`. */
export async function requireRevenueCatAuthorization(header: string | null, expected: string): Promise<void> {
  if (header === null || !(await constantTimeEqualText(header, expected))) {
    log("warn", "revenuecat_webhook_unauthorized", { headerPresent: header !== null });
    throw new ApiError("unauthorized", "The Authorization header does not match.");
  }
}

/** Webhook gövdesini JSON olarak çözer ve doğrular; geçersizse `webhook_invalid` (alan yolları mesajdadır). Saf fonksiyondur. */
export function parseRevenueCatWebhook(payload: string): RevenueCatEvent {
  let raw: unknown;
  try {
    raw = JSON.parse(payload);
  } catch {
    throw new ApiError("webhook_invalid", "The webhook body is not valid JSON.");
  }
  const parsed = revenueCatWebhookSchema.safeParse(raw);
  if (!parsed.success) {
    const problems: string = parsed.error.issues
      .slice(0, 5)
      .map((issue: z.core.$ZodIssue): string => `${issue.path.join(".") || "(root)"}: ${issue.code}`)
      .join("; ");
    throw new ApiError("webhook_invalid", `Invalid webhook body: ${problems}`);
  }
  return parsed.data.event;
}

/**
 * RevenueCat webhook'u (`POST /v1/webhooks/revenuecat`). Yalnızca 200 başarıdır; RevenueCat başka her yanıtı 5 kez
 * (~2,5 → 40 dk) yeniden dener. Sıra:
 * 1. `Authorization` başlığı sabit zamanlı denetlenir (`401 unauthorized`); gövde doğrulanır (`400 webhook_invalid`).
 * 2. İşlenmiş olay (aynı `id`) yeniden işlenmez (`duplicate`).
 * 3. `TEST` (paneldeki deneme düğmesi) kaydedilir, başka iş yapılmaz.
 * 4. Sandbox olayı `acceptSandbox` kapalıyken yok sayılır (`sandbox_ignored`).
 * 5. Aday kimliklerden (`revenueCatCandidateUserIds`) bizde olmayanlar elenir. Hiçbiri yoksa (silinmiş hesabın
 *    yenilemesi, uygulamanın `logIn` çağırmadan satın alması) olay kaydedilir, uyarı loglanır ve "Sorunlar"a
 *    `provider_error`/`revenuecat_unknown_user` sayılır; 200 döner (RevenueCat boşuna yeniden denemesin).
 * 6. Her bilinen hesap RevenueCat'ten eşitlenir (`syncAppStoreSubscription`); RevenueCat okunamazsa hata fırlar, olay
 *    kaydedilmez ve RevenueCat yeniden dener. Olay türü ne olursa olsun (bilinmeyen yeni türler dahil) eşitleme aynıdır.
 */
export async function handleRevenueCatWebhook(
  db: D1Database,
  platform: Platform,
  config: RevenueCatWebhookConfig,
  authorization: string | null,
  payload: string,
): Promise<RevenueCatWebhookResult> {
  await requireRevenueCatAuthorization(authorization, config.webhookAuth);
  const event: RevenueCatEvent = parseRevenueCatWebhook(payload);
  const seen: { found: number } | null = await db
    .prepare("SELECT EXISTS (SELECT 1 FROM revenuecat_events WHERE id = ?) AS found")
    .bind(event.id)
    .first<{ found: number }>();
  if (seen !== null && seen.found === 1) {
    log("info", "revenuecat_event_duplicate", { eventId: event.id, type: event.type });
    return { outcome: "duplicate", users: 0 };
  }
  const now: Date = platform.now();
  if (event.type === "TEST") {
    await eventRecordStatement(db, event, "test", now.getTime()).run();
    log("info", "revenuecat_test_event", { eventId: event.id });
    return { outcome: "test", users: 0 };
  }
  if (event.environment === "SANDBOX" && !config.acceptSandbox) {
    await eventRecordStatement(db, event, "sandbox_ignored", now.getTime()).run();
    log("info", "revenuecat_sandbox_ignored", { eventId: event.id, type: event.type });
    return { outcome: "sandbox_ignored", users: 0 };
  }
  const candidates: string[] = revenueCatCandidateUserIds(event);
  const users: string[] = await knownUserIds(db, candidates);
  if (users.length === 0) {
    log("warn", "revenuecat_unknown_user", {
      eventId: event.id,
      type: event.type,
      environment: event.environment ?? null,
      appUserId: event.app_user_id ?? null,
      candidates: candidates.length,
    });
    await recordOpsEvents(db, [{ kind: "provider_error", detail: "revenuecat_unknown_user" }], now);
    await eventRecordStatement(db, event, "unknown_user", now.getTime()).run();
    return { outcome: "unknown_user", users: 0 };
  }
  for (const userId of users) {
    await syncAppStoreSubscription(db, platform, config, userId, event.id);
  }
  await eventRecordStatement(db, event, "synced", platform.now().getTime()).run();
  log("info", "revenuecat_event_processed", { eventId: event.id, type: event.type, environment: event.environment ?? null, users: users.length });
  return { outcome: "synced", users: users.length };
}
