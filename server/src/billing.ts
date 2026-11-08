import Stripe from "stripe";
import {
  type Config,
  type StripePrices,
  type StripeWebhookConfig,
  type SubscriptionPlan,
  type SubscriptionTier,
  isStripeTestModeInProduction,
} from "./config";
import { cancellationStatements } from "./cancellations";
import { complimentaryAccessError } from "./complimentary";
import { type AppStoreSubscription, appStoreAccess, appStoreManageUrl, appStoreSubscriptionOf } from "./appStore";
import { type SubscriptionState, isTerminalSubscription, subscriptionState, withdrawalPeriodMs } from "./entitlements";
import { isLiveStripeStatus, isRunningComplimentary, runningComplimentarySql } from "./subscriptionLifecycle";
import { ApiError, ProviderApiError } from "./errors";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import {
  type AcceptedReferral,
  type ReferralJoin,
  referralCardHash,
  referralCheckoutStatements,
  referralInvoicePaidStatements,
  referralVoidByReferredStatement,
  referralVoidBySubscriptionStatement,
  referralVoidUnpaidStatement,
  requireReferral,
  usdCents,
} from "./referrals";
import { withRetries } from "./retry";
import { requireTierOffered, stripePriceOf } from "./tiers";
import { type InvoiceRevenue, firstPaidAtSql, invoiceRevenueOf, revenueInvoiceStatements, revenueRefundStatement } from "./revenue";

/** Stripe isteğinin zaman aşımı (SDK'nın fetch istemcisi isteğin tamamına uygular). */
const stripeTimeoutMs: number = 20_000;

/** Üretimde test modu anahtarı varsa açık uyarı yazar (ödemeler gerçek değildir). */
export function warnIfStripeTestMode(config: StripeWebhookConfig, operation: string): void {
  if (isStripeTestModeInProduction(config)) {
    log("warn", "stripe_test_mode_in_production", { operation });
  }
}

/** Stripe istemcisi (dış sistem bağlantısı): fetch tabanlı; yeniden denemeyi `withRetries` yapar. */
export function stripeClient(platform: Platform, config: StripeWebhookConfig): Stripe {
  return new Stripe(config.secrets.stripe, {
    httpClient: Stripe.createFetchHttpClient(platform.fetch),
    maxNetworkRetries: 0,
    timeout: stripeTimeoutMs,
  });
}

/** Stripe bağlantı, hız sınırı ve sunucu hataları geçicidir. Saf fonksiyondur. */
export function isRetryableStripeError(error: unknown): boolean {
  if (error instanceof Stripe.errors.StripeConnectionError || error instanceof Stripe.errors.StripeRateLimitError) {
    return true;
  }
  return error instanceof Stripe.errors.StripeAPIError && (error.statusCode ?? 0) >= 500;
}

/** Başarısız Stripe çağrısını loglar (durum, istek kimliği) ve mesaj taşımayan istemci hatasını döndürür. */
function stripeFailure(operation: string, userId: string | null, error: unknown): ProviderApiError {
  const status: number | null = error instanceof Stripe.errors.StripeError ? (error.statusCode ?? null) : null;
  const requestId: string | null = error instanceof Stripe.errors.StripeError ? (error.requestId ?? null) : null;
  log("error", "stripe_failed", { operation, userId, status, requestId, error: errorName(error) });
  return new ProviderApiError("stripe", "upstream_unavailable", "Could not reach the payment service; try again shortly.");
}

/** Stripe çağrısını yeniden denemeyle yapar; başarısızlıkta mesaj taşımayan istemci hatası fırlatır. */
export async function callStripe<T>(platform: Platform, operation: string, userId: string | null, call: () => Promise<T>): Promise<T> {
  try {
    return await withRetries({ service: "stripe", attempts: 3, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableStripeError, recordRetry: platform.recordRetry }, call);
  } catch (error: unknown) {
    throw stripeFailure(operation, userId, error);
  }
}

/** `callStripe` gibi; nesne Stripe'ta yoksa (404) hata yerine null döner. */
async function callStripeOrMissing<T>(platform: Platform, operation: string, userId: string | null, call: () => Promise<T>): Promise<T | null> {
  try {
    return await withRetries({ service: "stripe", attempts: 3, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableStripeError, recordRetry: platform.recordRetry }, call);
  } catch (error: unknown) {
    if (error instanceof Stripe.errors.StripeInvalidRequestError && error.statusCode === 404) {
      return null;
    }
    throw stripeFailure(operation, userId, error);
  }
}

/** Kullanıcının kayıtlı Stripe müşterisi; yoksa null. */
export async function storedCustomerId(db: D1Database, userId: string): Promise<string | null> {
  const row: { stripe_customer_id: string } | null = await db
    .prepare("SELECT stripe_customer_id FROM stripe_customers WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_customer_id: string }>();
  return row === null ? null : row.stripe_customer_id;
}

/** Kullanıcının Stripe müşteri kuşağı: her `customer.deleted` ile artar (bkz. `customerCreationKey`). */
async function customerGeneration(db: D1Database, userId: string): Promise<number> {
  const row: { stripe_customer_generation: number } | null = await db
    .prepare("SELECT stripe_customer_generation FROM users WHERE id = ?")
    .bind(userId)
    .first<{ stripe_customer_generation: number }>();
  if (row === null) {
    throw new ApiError("unauthorized", "Account not found.");
  }
  return row.stripe_customer_generation;
}

/**
 * Müşteri oluşturmanın idempotency anahtarı: eşzamanlı ve yinelenen istekler aynı müşteriyi alır; Stripe müşterisi
 * silinince kuşak artar ve yeni anahtar yeni müşteri açar (Stripe aynı anahtara 24 saat eski yanıtı döndürür). Saf
 * fonksiyondur.
 */
export function customerCreationKey(userId: string, generation: number): string {
  return `customer-${userId}-g${generation}`;
}

/** Kullanıcının Stripe müşterisi; yoksa oluşturulur ve saklanır (sonraki ödemelerde yeniden kullanılır). */
async function customerId(db: D1Database, stripe: Stripe, platform: Platform, userId: string): Promise<string> {
  const existing: string | null = await storedCustomerId(db, userId);
  if (existing !== null) {
    return existing;
  }
  const idempotencyKey: string = customerCreationKey(userId, await customerGeneration(db, userId));
  const customer: Stripe.Customer = await callStripe(platform, "customers.create", userId, () =>
    stripe.customers.create({ metadata: { user_id: userId } }, { idempotencyKey }),
  );
  await db
    .prepare("INSERT OR IGNORE INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, ?, ?)")
    .bind(userId, customer.id, platform.now().getTime())
    .run();
  const stored: string | null = await storedCustomerId(db, userId);
  if (stored === null) {
    throw new ApiError("internal_error", "Could not save the Stripe customer.");
  }
  return stored;
}

/** Stripe'ta yaşayan (iptal edilmemiş, süresi dolmamış) abonelik mi. Saf fonksiyondur. */
export function isLiveInStripe(subscription: Stripe.Subscription): boolean {
  return isLiveStripeStatus(subscription.status);
}

/** Stripe aboneliğinin yazılan durumu. Saf fonksiyondur. */
export function stateOf(subscription: Stripe.Subscription): SubscriptionState {
  return {
    status: subscription.status,
    currentPeriodEnd: subscriptionPeriodEndMs(subscription),
    cancelAt: subscriptionCancelAtMs(subscription),
    pastDueSince: null,
    complimentary: false,
  };
}

/** Müşterinin Stripe'taki tüm abonelikleri (tek sayfa, en çok 100; fazlası alarm ve hata). */
async function customerSubscriptions(stripe: Stripe, platform: Platform, customer: string, userId: string | null): Promise<Stripe.Subscription[]> {
  const page: Stripe.ApiList<Stripe.Subscription> = await callStripe(platform, "subscriptions.list", userId, () =>
    stripe.subscriptions.list({ customer, status: "all", limit: 100 }),
  );
  if (page.has_more) {
    log("alert", "stripe_subscription_list_truncated", { userId, count: page.data.length });
    throw new ApiError("internal_error", "Could not list subscriptions.");
  }
  return page.data;
}

/**
 * Müşterinin açık Checkout oturumlarını sona erdirir (ikinci sekmedeki eski ödeme sayfası ikinci aboneliği açamasın);
 * sona erdirilen sayısını döndürür.
 */
async function expireOpenCheckouts(stripe: Stripe, platform: Platform, customer: string, userId: string): Promise<number> {
  const sessions: Stripe.ApiList<Stripe.Checkout.Session> = await callStripe(platform, "checkout.sessions.list", userId, () =>
    stripe.checkout.sessions.list({ customer, status: "open", limit: 100 }),
  );
  for (const session of sessions.data) {
    await callStripe(platform, "checkout.sessions.expire", userId, () => stripe.checkout.sessions.expire(session.id));
  }
  return sessions.data.length;
}

/** Kopya abonelik iadesinin işareti (Stripe panosunda iadenin nedeni görünsün). */
export const duplicateRefundPurpose: string = "duplicate_subscription";

/**
 * Kopya aboneliği kalıcı olarak yazar (iade ve iptalden önce; tekrarı zararsız). `refundSince`: korunan aboneliğin
 * oluşturulduğu an (Stripe saniyesi); kopyanın yalnızca bundan sonra kesilen faturaları iade edilir.
 */
async function markDuplicate(db: D1Database, subscriptionId: string, userId: string, customer: string, refundSince: number, nowMs: number): Promise<void> {
  await db
    .prepare(
      `INSERT OR IGNORE INTO duplicate_subscriptions (stripe_subscription_id, user_id, stripe_customer_id, created_at, refund_since)
       VALUES (?, ?, ?, ?, ?)`,
    )
    .bind(subscriptionId, userId, customer, nowMs, refundSince)
    .run();
}

/** Kopya olarak yazılmış abonelik. */
interface DuplicateRecord {
  readonly userId: string;
  /** Bundan (Stripe saniyesi) önce kesilen faturaları iade edilmez; eski kayıtta null (tüm faturalar). */
  readonly refundSince: number | null;
}

/** Kopya olarak yazılmış aboneliğin kaydı; kopya değilse null. */
async function duplicateRecord(db: D1Database, subscriptionId: string): Promise<DuplicateRecord | null> {
  const row: { user_id: string; refund_since: number | null } | null = await db
    .prepare("SELECT user_id, refund_since FROM duplicate_subscriptions WHERE stripe_subscription_id = ?")
    .bind(subscriptionId)
    .first<{ user_id: string; refund_since: number | null }>();
  return row === null ? null : { userId: row.user_id, refundSince: row.refund_since };
}

/**
 * Bizim aboneliğimiz mi: Checkout'un yazdığı `metadata.user_id`'yi taşır ya da kalemlerinden biri yapılandırılmış aylık
 * ya da yıllık fiyattır. Aynı Stripe hesabındaki başka ürünlerin abonelikleri webhook'ta iptal ya da iade edilmez. Saf
 * fonksiyondur.
 */
export function isOurSubscription(subscription: Stripe.Subscription, prices: StripePrices): boolean {
  const userId: string | undefined = subscription.metadata["user_id"];
  return (userId !== undefined && userId !== "") || planOfSubscription(subscription, prices) !== null;
}

/** Aboneliğin kalemlerindeki fiyat kimlikleri. Saf fonksiyondur. */
function subscriptionPriceIds(subscription: Stripe.Subscription): string[] {
  return subscription.items.data.map((item: Stripe.SubscriptionItem): string => item.price.id);
}

/**
 * Aboneliğin planı: kalemlerinden biri (Personal ya da Pro) yıllık fiyatsa `yearly`, aylık fiyatsa `monthly`; hiçbiri
 * değilse (yalnızca `metadata.user_id` taşıyan eski ya da değiştirilmiş fiyat) null. Portal'da plan değişince sonraki
 * abonelik olayı yeni planı yazar. Saf fonksiyondur.
 */
export function planOfSubscription(subscription: Stripe.Subscription, prices: StripePrices): SubscriptionPlan | null {
  const priceIds: string[] = subscriptionPriceIds(subscription);
  if (priceIds.includes(prices.yearly) || priceIds.includes(prices.proYearly)) {
    return "yearly";
  }
  return priceIds.includes(prices.monthly) || priceIds.includes(prices.proMonthly) ? "monthly" : null;
}

/**
 * Aboneliğin katmanı: kalemlerinden biri Pro fiyatıysa `pro`, değilse `personal` (tanınmayan fiyat da). Portal'da katman
 * değişince (`createPlanChange`) sonraki abonelik olayı yeni katmanı yazar. Saf fonksiyondur.
 */
export function tierOfSubscription(subscription: Stripe.Subscription, prices: StripePrices): SubscriptionTier {
  const priceIds: string[] = subscriptionPriceIds(subscription);
  return priceIds.includes(prices.proMonthly) || priceIds.includes(prices.proYearly) ? "pro" : "personal";
}

/** Fatura ödemesinin ödeme niyeti ya da ödeme (charge) kimliği; ikisi de yoksa null. Saf fonksiyondur. */
export function paymentTargetOf(payment: Stripe.InvoicePayment): { payment_intent: string } | { charge: string } | null {
  const intent: string | null = payment.payment.payment_intent === undefined
    ? null
    : typeof payment.payment.payment_intent === "string" ? payment.payment.payment_intent : payment.payment.payment_intent.id;
  if (intent !== null) {
    return { payment_intent: intent };
  }
  const charge: string | null = payment.payment.charge === undefined
    ? null
    : typeof payment.payment.charge === "string" ? payment.payment.charge : payment.payment.charge.id;
  return charge === null ? null : { charge };
}

/**
 * Kopyanın iade edilecek faturaları: korunan abonelik oluşturulduktan sonra (`created >= refundSince`) kesilenler, yani
 * iki aboneliğin aynı anda ücretlendiği dönem. Kopya daha eski abonelikse onun önceki meşru ayları iade edilmez.
 * Saf fonksiyondur.
 */
export function duplicateInvoicesToRefund(invoices: readonly Stripe.Invoice[], refundSince: number): Stripe.Invoice[] {
  return invoices.filter((invoice: Stripe.Invoice): boolean => invoice.created >= refundSince);
}

/** Ödeme tamamen iade edilmiş mi (`amount_refunded >= amount`). Saf fonksiyondur. */
export function isFullyRefunded(charge: Stripe.Charge): boolean {
  return charge.amount_refunded >= charge.amount;
}

/** Faturanın aboneliği; abonelik faturası değilse null. Saf fonksiyondur. */
export function invoiceSubscriptionId(invoice: Stripe.Invoice): string | null {
  const subscription: string | Stripe.Subscription | undefined = invoice.parent?.subscription_details?.subscription;
  if (subscription === undefined) {
    return null;
  }
  return typeof subscription === "string" ? subscription : subscription.id;
}

/**
 * Fazla (kopya) aboneliğin, korunan abonelik oluşturulduktan sonra kesilmiş ödenmiş faturalarını tam iade eder
 * (`duplicateInvoicesToRefund`): aynı kişi aynı dönem için iki kez ücretlenmesin, eski meşru aylar geri ödenmesin.
 * Tekrarı güvenlidir (ödeme başına idempotency anahtarı; zaten tam iade edilmiş ödeme atlanır). İade edilen ödeme
 * sayısını döndürür.
 */
async function refundDuplicate(stripe: Stripe, platform: Platform, subscriptionId: string, userId: string, refundSince: number): Promise<number> {
  const invoices: Stripe.ApiList<Stripe.Invoice> = await callStripe(platform, "invoices.list", userId, () =>
    stripe.invoices.list({ subscription: subscriptionId, status: "paid", limit: 100 }),
  );
  let refunded: number = 0;
  for (const invoice of duplicateInvoicesToRefund(invoices.data, refundSince)) {
    if (invoice.id !== undefined) {
      refunded += await refundInvoicePayments(stripe, platform, invoice.id, subscriptionId, userId);
    }
  }
  return refunded;
}

/**
 * Ödemenin henüz tam iade edilmemiş başarılı ödemeleri (charge): ödeme niyetinin ödemeleri ya da tek ödeme. Boşsa
 * iade edilecek bir şey yoktur (Stripe zaten iade edilmiş ödemenin iadesini 24 saatlik idempotency süresinden sonra
 * reddeder; webhook yeniden denendikçe 5xx dönüp sonraki olayları tıkamasın).
 */
async function refundableCharges(stripe: Stripe, platform: Platform, target: { payment_intent: string } | { charge: string }, userId: string): Promise<Stripe.Charge[]> {
  const charges: Stripe.Charge[] =
    "payment_intent" in target
      ? (await callStripe(platform, "charges.list", userId, () => stripe.charges.list({ payment_intent: target.payment_intent, limit: 100 }))).data
      : [await callStripe(platform, "charges.retrieve", userId, () => stripe.charges.retrieve(target.charge))];
  return charges.filter((charge: Stripe.Charge): boolean => charge.paid && !isFullyRefunded(charge));
}

/**
 * Faturanın ödenmiş ödemelerini kopya iadesi olarak tam iade eder (tekrarı güvenli: zaten tam iade edilmiş ödeme
 * atlanır); iade edilen ödeme sayısı.
 */
async function refundInvoicePayments(stripe: Stripe, platform: Platform, invoice: string, subscriptionId: string, userId: string): Promise<number> {
  const payments: Stripe.ApiList<Stripe.InvoicePayment> = await callStripe(platform, "invoicePayments.list", userId, () =>
    stripe.invoicePayments.list({ invoice, status: "paid", limit: 100 }),
  );
  let refunded: number = 0;
  for (const payment of payments.data) {
    const target: { payment_intent: string } | { charge: string } | null = paymentTargetOf(payment);
    if (target === null) {
      log("alert", "stripe_duplicate_refund_unsupported", { userId, subscriptionId, invoiceId: invoice, paymentType: payment.payment.type });
      continue;
    }
    if ((await refundableCharges(stripe, platform, target, userId)).length === 0) {
      log("info", "stripe_duplicate_refund_already_done", { userId, subscriptionId, invoiceId: invoice });
      continue;
    }
    await callStripe(platform, "refunds.create", userId, () =>
      stripe.refunds.create(
        { ...target, reason: "duplicate", metadata: { purpose: duplicateRefundPurpose, subscription_id: subscriptionId, user_id: userId } },
        { idempotencyKey: `refund-duplicate-${subscriptionId}-${"payment_intent" in target ? target.payment_intent : target.charge}` },
      ),
    );
    refunded += 1;
  }
  return refunded;
}

/** Aboneliği Stripe'ta hemen iptal eder (tekrarı güvenli: aynı idempotency anahtarı). */
async function cancelSubscription(stripe: Stripe, platform: Platform, subscriptionId: string, userId: string | null): Promise<void> {
  await callStripe(platform, "subscriptions.cancel", userId, () =>
    stripe.subscriptions.cancel(subscriptionId, {}, { idempotencyKey: `cancel-${subscriptionId}` }),
  );
}

/** Checkout isteği: katman, plan ve isteğe bağlı davet kodu (ham; sunucuda doğrulanır). */
export interface CheckoutRequest {
  readonly tier: SubscriptionTier;
  readonly plan: SubscriptionPlan;
  readonly referralCode: string | null;
}

/** Davet indiriminin Stripe kuponu: kimlik ve beklenen indirim (yüzde ya da sent). */
export interface ReferralCouponSpec {
  readonly id: string;
  readonly percentOff: number | null;
  readonly amountOffCents: number | null;
  readonly name: string;
}

/**
 * Katman ve planın davet kuponu: Personal aylıkta ilk faturaya %100 (ilk ay ücretsiz); Personal yıllıkta ve Pro'nun iki
 * planında ilk faturaya bir Personal aylık fiyatı kadar (USD) indirim (davetin değeri katmandan bağımsız: Pro'nun ilk ayı
 * ücretsiz olsaydı davet en pahalı ayı hediye ederdi). Hepsi tek seferlik (`duration: once`). Tutar kuponunun kimliği
 * tutarı taşır: aylık fiyat değişirse yeni kupon açılır. Saf fonksiyondur.
 */
export function referralCouponSpec(tier: SubscriptionTier, plan: SubscriptionPlan, monthlyPriceCents: number): ReferralCouponSpec {
  return tier === "personal" && plan === "monthly"
    ? { id: "gistsmith_invite_first_month", percentOff: 100, amountOffCents: null, name: "Invite: first month free" }
    : { id: `gistsmith_invite_yearly_${monthlyPriceCents}`, percentOff: null, amountOffCents: monthlyPriceCents, name: "Invite: one month off" };
}

/** Stripe'taki kupon beklenen indirim mi (geçerli, tek seferlik, aynı yüzde ya da USD tutar). Saf fonksiyondur. */
export function couponMatches(coupon: Stripe.Coupon, spec: ReferralCouponSpec): boolean {
  const discountMatches: boolean =
    spec.percentOff !== null
      ? coupon.percent_off === spec.percentOff && coupon.amount_off === null
      : coupon.amount_off === spec.amountOffCents && coupon.currency === "usd" && coupon.percent_off === null;
  return coupon.valid && coupon.duration === "once" && discountMatches;
}

/**
 * Davet kuponu; Stripe'ta yoksa oluşturulur (sabit kimlik + idempotency anahtarı: eşzamanlı istekler aynı kuponu
 * alır). Panodan değiştirilmiş ya da geçersizleşmiş kupon kullanılmaz: alarm ve `referral_unavailable`.
 */
async function ensureReferralCoupon(stripe: Stripe, platform: Platform, spec: ReferralCouponSpec, userId: string): Promise<string> {
  const existing: Stripe.Coupon | null = await callStripeOrMissing(platform, "coupons.retrieve", userId, () => stripe.coupons.retrieve(spec.id));
  const coupon: Stripe.Coupon =
    existing ??
    (await callStripe(platform, "coupons.create", userId, () =>
      stripe.coupons.create(
        spec.percentOff !== null
          ? { id: spec.id, name: spec.name, duration: "once", percent_off: spec.percentOff, metadata: { purpose: "referral" } }
          : { id: spec.id, name: spec.name, duration: "once", amount_off: spec.amountOffCents ?? 0, currency: "usd", metadata: { purpose: "referral" } },
        { idempotencyKey: `coupon-${spec.id}` },
      ),
    ));
  if (!couponMatches(coupon, spec)) {
    log("alert", "referral_coupon_mismatch", { couponId: spec.id, valid: coupon.valid, duration: coupon.duration });
    throw new ApiError("referral_unavailable", "The referral discount can't be applied right now.");
  }
  if (existing === null) {
    log("info", "referral_coupon_created", { couponId: spec.id });
  }
  return coupon.id;
}

/**
 * Seçilen plan (aylık ya da yıllık) için Stripe Checkout oturumu (müşteri yeniden kullanılır); ödeme adresini döndürür.
 * Stripe Managed Payments açıktır: yasal satıcı Stripe/Link'tir; vergiyi o hesaplar, toplar ve öder, adı ve fatura
 * adresini kendisi ister. Bu yüzden `automatic_tax`, `customer_update` ve `tax_id_collection` gönderilmez (Managed
 * Payments reddeder). Bitmemiş bir abonelik varsa (ek süresi geçmiş `past_due` dahil) `subscription_exists`: aynı
 * kullanıcıda iki abonelik aynı anda ücretlendirilmesin; istemci Müşteri Portalı'nı açar. Süren ücretsiz erişimde
 * (`complimentary.ts`) `complimentary_subscription`: Stripe çağrılmaz. Denetim önce yerel satıra,
 * sonra Stripe'taki listeye bakar (webhook'u henüz gelmemiş abonelik de yakalanır). Yeni oturumdan önce müşterinin açık
 * Checkout oturumları sona erdirilir (iki sekmede iki ödeme olmasın; yine de olursa fazlası webhook'ta iptal ve iade
 * edilir). Davet kodu verildiyse `requireReferral` ile doğrulanır, planın davet kuponu oturuma eklenir, kod aboneliğin
 * `metadata.referral_code`'una yazılır ve davet satırı `checkout` olur (`referralCheckoutStatements`); kodsuz oturum
 * hesabın abonelik açmamış davet satırını siler.
 */
export async function createCheckout(db: D1Database, platform: Platform, config: Config, userId: string, request: CheckoutRequest): Promise<string> {
  const subscriptionExists: ApiError = new ApiError(
    "subscription_exists",
    "You already have a subscription; a new one can't be started. Open the Customer Portal to update your payment method or manage your subscription.",
  );
  warnIfStripeTestMode(config, "checkout");
  requireTierOffered(config, request.tier);
  const current: SubscriptionState | null = await subscriptionState(db, userId);
  if (current !== null && !isTerminalSubscription(current, platform.now())) {
    throw current.complimentary ? complimentaryAccessError() : subscriptionExists;
  }
  // App Store'dan (iPhone) abone olan hesap ikinci kez ödemesin: abonelik Apple'da yönetilir.
  const appStore: AppStoreSubscription | null = await appStoreSubscriptionOf(db, userId);
  if (appStoreAccess(appStore, config.appStore.acceptSandbox, platform.now()) !== "none") {
    log("info", "checkout_refused_app_store_subscription", { userId });
    throw appStoreSubscriptionError();
  }
  // Kod Stripe'a gitmeden doğrulanır: reddedilen kod müşteri ya da oturum açtırmaz.
  const referral: AcceptedReferral | null =
    request.referralCode === null ? null : await requireReferral(db, config, userId, request.referralCode, platform.now());
  const stripe: Stripe = stripeClient(platform, config);
  const customer: string = await customerId(db, stripe, platform, userId);
  const unfinished: Stripe.Subscription[] = (await customerSubscriptions(stripe, platform, customer, userId)).filter(
    (subscription: Stripe.Subscription): boolean => !isTerminalSubscription(stateOf(subscription), platform.now()),
  );
  if (unfinished.length > 0) {
    log("warn", "checkout_refused_stripe_subscription", { userId, count: unfinished.length });
    throw subscriptionExists;
  }
  const couponId: string | null =
    referral === null
      ? null
      : await ensureReferralCoupon(stripe, platform, referralCouponSpec(request.tier, request.plan, usdCents(config.priceUsdMonthly)), userId);
  // Önceki açık ödeme sayfaları kapanır: iki sekmede ödenen iki oturum iki abonelik açmasın.
  const expired: number = await expireOpenCheckouts(stripe, platform, customer, userId);
  if (expired > 0) {
    log("info", "checkout_previous_sessions_expired", { userId, count: expired });
  }
  // Davet satırı oturumdan önce yazılır: oturum açılamazsa kalan `checkout` satırı zararsızdır (ödeme olmadan ilerlemez).
  await db.batch(referralCheckoutStatements(db, userId, referral, platform.now().getTime()));
  const metadata: Record<string, string> = referral === null ? { user_id: userId } : { user_id: userId, referral_code: referral.code };
  const session: Stripe.Checkout.Session = await callStripe(platform, "checkout.sessions.create", userId, () =>
    stripe.checkout.sessions.create({
      mode: "subscription",
      customer,
      client_reference_id: userId,
      line_items: [{ price: stripePriceOf(config.stripePrices, request.tier, request.plan), quantity: 1 }],
      ...(couponId === null ? {} : { discounts: [{ coupon: couponId }] }),
      managed_payments: { enabled: true },
      subscription_data: { metadata },
      success_url: `${config.siteOrigin}/account?payment=done`,
      cancel_url: `${config.siteOrigin}/pricing`,
    }),
  );
  if (session.url === null) {
    throw new ProviderApiError("stripe", "upstream_unavailable", "Could not create the checkout page.");
  }
  log("info", "checkout_created", { userId, tier: request.tier, plan: request.plan, referral: referral !== null });
  return session.url;
}

/**
 * Refund of a withdrawal: the paid amount minus the proportionate share for the time already provided (CRD Art. 14(3);
 * the subscription starts at once on the consumer's request). `periodStartMs`/`periodEndMs` are the paid period; the
 * refund is rounded down to the cent. Pure function.
 */
export function withdrawalRefundCents(amountPaidCents: number, periodStartMs: number, periodEndMs: number, nowMs: number): number {
  if (periodEndMs <= periodStartMs || amountPaidCents <= 0) {
    return 0;
  }
  const unused: number = Math.min(1, Math.max(0, (periodEndMs - nowMs) / (periodEndMs - periodStartMs)));
  return Math.floor(amountPaidCents * unused);
}

/** Result of a withdrawal: the refunded amount (cents, all invoices) and its currency. */
export interface WithdrawalResult {
  readonly refundedCents: number;
  readonly currency: string;
}

/** Whether a refund has gone or is going through (`succeeded`, `pending`, `requires_action`). Pure function. */
export function isLiveRefund(refund: Stripe.Refund): boolean {
  return refund.status === "succeeded" || refund.status === "pending" || refund.status === "requires_action";
}

/** The paid period of an invoice: the span of its charged (positive) lines; null when it has none. Pure function. */
export function invoiceChargedPeriodMs(invoice: Stripe.Invoice): { readonly startMs: number; readonly endMs: number } | null {
  const charged: Stripe.InvoiceLineItem[] = invoice.lines.data.filter((line: Stripe.InvoiceLineItem): boolean => line.amount > 0);
  if (charged.length === 0) {
    return null;
  }
  return {
    startMs: Math.min(...charged.map((line: Stripe.InvoiceLineItem): number => line.period.start)) * 1000,
    endMs: Math.max(...charged.map((line: Stripe.InvoiceLineItem): number => line.period.end)) * 1000,
  };
}

/**
 * EU online withdrawal function (CRD Art. 11a): within `withdrawalPeriodMs` of the Stripe subscription's start, the
 * subscriber withdraws from the contract. The moment of the request is stored first (`withdrawal_requested_at`); the
 * subscription is then cancelled at once, and each paid invoice is refunded pro rata for the unused part of its own paid
 * period (`invoiceChargedPeriodMs`, `withdrawalRefundCents`) at that stored moment, to the original payment method; Link
 * emails the refund receipt. A retry after a failed Stripe call (cancellation or a refund) resumes from the stored
 * moment even after the period or the subscription ended: the refunds have the same amounts and idempotency keys, so
 * nothing is refunded twice and nothing is left half done. Refused with `withdrawal_unavailable` after the period (and
 * no request stored), for complimentary access or without a Stripe subscription.
 */
export async function withdrawSubscription(db: D1Database, platform: Platform, config: Config, userId: string): Promise<WithdrawalResult> {
  const unavailable: ApiError = new ApiError("withdrawal_unavailable", "Withdrawal from this subscription isn't available; the 14-day period may have passed.");
  const nowMs: number = platform.now().getTime();
  const row: { stripe_subscription_id: string; started_at: number | null; complimentary: number; withdrawal_requested_at: number | null } | null = await db
    .prepare("SELECT stripe_subscription_id, started_at, complimentary, withdrawal_requested_at FROM subscriptions WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_subscription_id: string; started_at: number | null; complimentary: number; withdrawal_requested_at: number | null }>();
  if (row === null || row.complimentary === 1 || row.started_at === null) {
    throw unavailable;
  }
  const resumed: boolean = row.withdrawal_requested_at !== null;
  if (!resumed && row.started_at + withdrawalPeriodMs <= nowMs) {
    throw unavailable;
  }
  const stripe: Stripe = stripeClient(platform, config);
  const subscription: Stripe.Subscription = await callStripe(platform, "subscriptions.retrieve", userId, () =>
    stripe.subscriptions.retrieve(row.stripe_subscription_id),
  );
  if (!resumed && (!isLiveInStripe(subscription) || subscription.created * 1000 + withdrawalPeriodMs <= nowMs)) {
    throw unavailable;
  }
  // The refund's moment is fixed before any Stripe change: a retry computes the same amounts.
  await db
    .prepare("UPDATE subscriptions SET withdrawal_requested_at = ?1 WHERE user_id = ?2 AND stripe_subscription_id = ?3 AND withdrawal_requested_at IS NULL")
    .bind(nowMs, userId, subscription.id)
    .run();
  const requestedAtMs: number = row.withdrawal_requested_at ?? nowMs;
  if (isLiveInStripe(subscription)) {
    await cancelSubscription(stripe, platform, subscription.id, userId);
  }
  const invoices: Stripe.ApiList<Stripe.Invoice> = await callStripe(platform, "invoices.list", userId, () =>
    stripe.invoices.list({ subscription: subscription.id, status: "paid", limit: 100 }),
  );
  let refundedCents: number = 0;
  let currency: string = invoices.data[0]?.currency ?? "usd";
  for (const invoice of invoices.data) {
    const period: { readonly startMs: number; readonly endMs: number } | null = invoiceChargedPeriodMs(invoice);
    const amount: number = period === null ? 0 : withdrawalRefundCents(invoice.amount_paid, period.startMs, period.endMs, requestedAtMs);
    if (invoice.id === undefined || amount <= 0) {
      continue;
    }
    const payments: Stripe.ApiList<Stripe.InvoicePayment> = await callStripe(platform, "invoicePayments.list", userId, () =>
      stripe.invoicePayments.list({ invoice: invoice.id ?? "", status: "paid", limit: 100 }),
    );
    const target: { payment_intent: string } | { charge: string } | null = payments.data.map(paymentTargetOf).find((found) => found !== null) ?? null;
    if (target === null) {
      log("alert", "withdrawal_refund_unsupported", { userId, subscriptionId: subscription.id, invoiceId: invoice.id });
      continue;
    }
    // A repeated withdrawal (also after the idempotency key's 24 hours): the earlier request's refund on this payment
    // (`metadata.purpose = withdrawal`, not failed or canceled) is counted, not made again; other refunds (e.g. by
    // support) and a failed or canceled withdrawal refund don't count, so the refund is made (again).
    const earlier: Stripe.ApiList<Stripe.Refund> = await callStripe(platform, "refunds.list", userId, () =>
      stripe.refunds.list({ ...target, limit: 100 }),
    );
    const done: number = earlier.data
      .filter((refund: Stripe.Refund): boolean => refund.metadata?.["purpose"] === "withdrawal" && isLiveRefund(refund))
      .reduce((total: number, refund: Stripe.Refund): number => total + refund.amount, 0);
    if (done > 0) {
      log("info", "withdrawal_refund_already_done", { userId, subscriptionId: subscription.id, invoiceId: invoice.id, refundedCents: done });
      refundedCents += done;
      currency = invoice.currency;
      continue;
    }
    await callStripe(platform, "refunds.create", userId, () =>
      stripe.refunds.create(
        { ...target, amount, reason: "requested_by_customer", metadata: { purpose: "withdrawal", subscription_id: subscription.id, user_id: userId } },
        { idempotencyKey: `refund-withdrawal-${subscription.id}-${invoice.id ?? ""}` },
      ),
    );
    refundedCents += amount;
    currency = invoice.currency;
  }
  log("info", "subscription_withdrawn", { userId, subscriptionId: subscription.id, refundedCents, currency, resumed });
  return { refundedCents, currency };
}

/** Plan değişikliği isteği: hedef katman ve plan. */
export interface PlanChangeRequest {
  readonly tier: SubscriptionTier;
  readonly plan: SubscriptionPlan;
}

/**
 * Stripe abonesinin katman ya da plan değişikliği (Personal ↔ Pro, aylık ↔ yıllık): Stripe Müşteri Portalı'nın onay
 * sayfasının adresi (`flow_data.type = subscription_update_confirm`). Kullanıcı orada Stripe'ın orantılı ücret
 * önizlemesini görür ve onaylar; Stripe standardı uygulanır (Portal ayarındaki orantılama: yükseltmede farkın orantılı
 * kısmı hemen faturalanır, düşürmede kullanılmayan süre bakiyeye alacak yazılır). Onaydan sonra abonelik olayı yeni fiyatı
 * taşır, webhook planı ve katmanı yazar (`tierOfSubscription`); onaylanmazsa hiçbir şey değişmez.
 * - App Store aboneliği erişim veriyorsa `app_store_subscription` (değişiklik iPhone'da Apple'da yapılır).
 * - Süren ücretsiz erişimde `complimentary_subscription`.
 * - Stripe'ta yaşayan aboneliği yoksa `subscription_required` (Checkout açılmalı).
 * - Zaten o katman ve plandaysa `plan_unchanged`.
 * - Satışta olmayan katman (`PRO_TIER_POLICY` kapalıyken Pro) `pro_unavailable`.
 * Aboneliğin tek kalemi vardır (Checkout tek fiyatla açar); kalemin fiyatı değiştirilir, miktar 1 kalır.
 */
export async function createPlanChange(db: D1Database, platform: Platform, config: Config, userId: string, request: PlanChangeRequest): Promise<string> {
  warnIfStripeTestMode(config, "plan_change");
  requireTierOffered(config, request.tier);
  const appStore: AppStoreSubscription | null = await appStoreSubscriptionOf(db, userId);
  if (appStoreAccess(appStore, config.appStore.acceptSandbox, platform.now()) !== "none") {
    throw appStoreSubscriptionError();
  }
  const current: SubscriptionState | null = await subscriptionState(db, userId);
  if (current !== null && current.complimentary && !isTerminalSubscription(current, platform.now())) {
    throw complimentaryAccessError();
  }
  const row: { stripe_subscription_id: string } | null = await db
    .prepare("SELECT stripe_subscription_id FROM subscriptions WHERE user_id = ? AND complimentary = 0")
    .bind(userId)
    .first<{ stripe_subscription_id: string }>();
  const customer: string | null = await storedCustomerId(db, userId);
  if (row === null || customer === null) {
    throw new ApiError("subscription_required", "You don't have a subscription to change; subscribe first.");
  }
  const stripe: Stripe = stripeClient(platform, config);
  const subscription: Stripe.Subscription = await callStripe(platform, "subscriptions.retrieve", userId, () =>
    stripe.subscriptions.retrieve(row.stripe_subscription_id),
  );
  const item: Stripe.SubscriptionItem | undefined = subscription.items.data[0];
  if (!isLiveInStripe(subscription) || item === undefined || subscription.items.data.length !== 1) {
    log("warn", "plan_change_refused_subscription", { userId, subscriptionId: subscription.id, status: subscription.status, items: subscription.items.data.length });
    throw new ApiError("subscription_required", "You don't have a subscription to change; subscribe first.");
  }
  const price: string = stripePriceOf(config.stripePrices, request.tier, request.plan);
  if (item.price.id === price) {
    throw new ApiError("plan_unchanged", "You're already on this plan.");
  }
  const session: Stripe.BillingPortal.Session = await callStripe(platform, "billingPortal.sessions.create", userId, () =>
    stripe.billingPortal.sessions.create({
      customer,
      return_url: `${config.siteOrigin}/account`,
      flow_data: {
        type: "subscription_update_confirm",
        subscription_update_confirm: { subscription: subscription.id, items: [{ id: item.id, price, quantity: 1 }] },
        after_completion: { type: "redirect", redirect: { return_url: `${config.siteOrigin}/account?plan_change=done` } },
      },
    }),
  );
  log("info", "plan_change_created", {
    userId,
    subscriptionId: subscription.id,
    fromTier: tierOfSubscription(subscription, config.stripePrices),
    fromPlan: planOfSubscription(subscription, config.stripePrices),
    tier: request.tier,
    plan: request.plan,
  });
  return session.url;
}

/** Hesap App Store'dan abone: Stripe'ta açılacak ya da yönetilecek bir şey yok. Saf fonksiyondur. */
export function appStoreSubscriptionError(): ApiError {
  return new ApiError(
    "app_store_subscription",
    "You're subscribed through the App Store on your iPhone. Manage or cancel it in Settings › your name › Subscriptions.",
  );
}

/**
 * Hesap yönetimi adresi. Stripe'ta bitmemiş aboneliği yoksa (`isTerminalSubscription`) ve App Store aboneliği varsa
 * (iPhone'dan abone; bitmiş olsa da) Stripe çağrılmaz, Apple'ın abonelik yönetim sayfası döner: yayındaki uygulamanın
 * "Hesabı yönet" düğmesi de doğru yere gider. Erişimi olmasa da Stripe'ta yaşayan abonelik (`incomplete`, `unpaid`, ek
 * süresi geçmiş `past_due`) Portal'a gider: kart orada düzeltilir ya da abonelik iptal edilir. Süren ücretsiz erişimde (`complimentary.ts`) Stripe'ta yönetilecek bir şey yoktur: Stripe
 * çağrılmaz, sitedeki hesap sayfası döner (orada "Free access" yazar). Yayındaki uygulama portal adresini yalnızca
 * açar; hata kodu dönülseydi genel bir hata gösterirdi. Bitmiş ücretsiz erişimde Stripe müşterisi yoksa yine hesap
 * sayfası döner. Başka hesapta müşteri yoksa `subscription_required`.
 */
export async function createPortal(db: D1Database, platform: Platform, config: Config, userId: string): Promise<string> {
  const current: SubscriptionState | null = await subscriptionState(db, userId);
  const appStore: AppStoreSubscription | null = await appStoreSubscriptionOf(db, userId);
  if (appStore !== null && (current === null || isTerminalSubscription(current, platform.now()))) {
    log("info", "portal_app_store_manage_page", { userId });
    return appStoreManageUrl;
  }
  if (current !== null && isRunningComplimentary(current, platform.now().getTime())) {
    log("info", "portal_complimentary_account_page", { userId });
    return `${config.siteOrigin}/account`;
  }
  const customer: string | null = await storedCustomerId(db, userId);
  if (customer === null && current !== null && current.complimentary) {
    // Bitmiş ücretsiz erişim, Stripe müşterisi yok: eski uygulama sürümleri de genel hata yerine hesap sayfasını açar.
    log("info", "portal_complimentary_account_page", { userId });
    return `${config.siteOrigin}/account`;
  }
  if (customer === null) {
    throw new ApiError("subscription_required", "You don't have a subscription yet.");
  }
  const stripe: Stripe = stripeClient(platform, config);
  const session: Stripe.BillingPortal.Session = await callStripe(platform, "billingPortal.sessions.create", userId, () =>
    stripe.billingPortal.sessions.create({ customer, return_url: `${config.siteOrigin}/account` }),
  );
  return session.url;
}

/**
 * Hesap silinirken Stripe tarafını kapatır: önce müşterinin açık Checkout oturumları sona erdirilir (silinen hesaba
 * yeni abonelik açılamasın), sonra bitmemiş tüm abonelikler hemen iptal edilir. Stripe müşterisi yoksa Stripe
 * çağrılmaz. Liste Stripe'tan alınır (yalnızca geçerli satır değil): webhook'u henüz gelmemiş ya da geçerli olmayan
 * abonelik de iptal edilir. Zaten iptal edilmiş abonelik atlanır; tekrar çağrı güvenlidir. Ücretsiz erişimin
 * (`complimentary.ts`) Stripe karşılığı ve müşteri eşlemesi yoktur: Stripe'a gitmez. İptal edilen abonelik sayısını
 * döndürür.
 */
export async function closeStripeForDeletion(db: D1Database, platform: Platform, config: Config, userId: string): Promise<number> {
  const customer: string | null = await storedCustomerId(db, userId);
  if (customer === null) {
    return 0;
  }
  const stripe: Stripe = stripeClient(platform, config);
  const expiredCheckouts: number = await expireOpenCheckouts(stripe, platform, customer, userId);
  const live: Stripe.Subscription[] = (await customerSubscriptions(stripe, platform, customer, userId)).filter(isLiveInStripe);
  for (const subscription of live) {
    await cancelSubscription(stripe, platform, subscription.id, userId);
  }
  log("info", "stripe_closed_for_deletion", { userId, expiredCheckouts, canceledSubscriptions: live.length });
  return live.length;
}

/** Abonelik olayının aboneliği; diğer olaylar null. Saf fonksiyondur. */
export function subscriptionFromEvent(event: Stripe.Event): Stripe.Subscription | null {
  switch (event.type) {
    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted":
    case "customer.subscription.paused":
    case "customer.subscription.resumed":
      return event.data.object;
    default:
      return null;
  }
}

/** Aboneliğin dönem sonu: kalemlerin en geç dönem sonu (ms). Saf fonksiyondur. */
export function subscriptionPeriodEndMs(subscription: Stripe.Subscription): number {
  const ends: number[] = subscription.items.data.map((item: Stripe.SubscriptionItem): number => item.current_period_end);
  return Math.max(0, ...ends) * 1000;
}

/**
 * İptal edilmiş aboneliğin biteceği an (ms): Stripe'ın `cancel_at`'ı ya da `cancel_at_period_end` ise dönem sonu.
 * Yenilenecek abonelikte null. Saf fonksiyondur.
 */
export function subscriptionCancelAtMs(subscription: Stripe.Subscription): number | null {
  if (subscription.cancel_at !== null) {
    return subscription.cancel_at * 1000;
  }
  return subscription.cancel_at_period_end ? subscriptionPeriodEndMs(subscription) : null;
}

/** Erişim önceliği: ödenmiş (`active`, `trialing`) önce, sonra `past_due`, sonra diğer yaşayanlar. Saf fonksiyondur. */
function accessRank(subscription: Stripe.Subscription): number {
  if (subscription.status === "active" || subscription.status === "trialing") {
    return 0;
  }
  return subscription.status === "past_due" ? 1 : 2;
}

/** Müşterinin aboneliklerinden yazılacak geçerli abonelik ve iptal edilecek fazlalar. */
export interface SubscriptionChoice {
  readonly current: Stripe.Subscription | null;
  readonly duplicates: readonly Stripe.Subscription[];
}

/**
 * Kullanıcı başına tek abonelik: Stripe'ta yaşayan birden çok abonelik varsa geçerli olan erişim önceliği en yüksek,
 * eşitse en eski (`created`) olandır; diğerleri fazladır (iptal edilir: aynı kişi iki kez ücretlenmesin). Yaşayan yoksa
 * geçerli olan en son oluşturulandır (bitmiş durumu gösterilir); liste boşsa null. Saf fonksiyondur.
 */
export function chooseSubscription(subscriptions: readonly Stripe.Subscription[]): SubscriptionChoice {
  const live: Stripe.Subscription[] = subscriptions
    .filter(isLiveInStripe)
    .sort((left: Stripe.Subscription, right: Stripe.Subscription): number => accessRank(left) - accessRank(right) || left.created - right.created);
  const keeper: Stripe.Subscription | undefined = live[0];
  if (keeper !== undefined) {
    return { current: keeper, duplicates: live.slice(1) };
  }
  const newest: Stripe.Subscription | undefined = [...subscriptions].sort(
    (left: Stripe.Subscription, right: Stripe.Subscription): number => right.created - left.created,
  )[0];
  return { current: newest ?? null, duplicates: [] };
}

/** Stripe nesnesinin müşteri kimliği (genişletilmiş nesne ya da kimlik). Saf fonksiyondur. */
function customerIdOf(customer: string | Stripe.Customer | Stripe.DeletedCustomer): string {
  return typeof customer === "string" ? customer : customer.id;
}

/** Webhook'un işlediği olayın veritabanına yazılacak ifadeleri (olay kaydı hariç). */
type EventStatements = D1PreparedStatement[];

/**
 * Abonelik olayı. Olayın anlık görüntüsüne değil Stripe'taki güncel duruma güvenilir (aynı saniyedeki olaylar ters
 * sırayla gelebilir): müşterinin tüm abonelikleri listelenir ve `chooseSubscription` ile geçerli olan yazılır.
 * - Yalnızca bizim aboneliklerimiz (`isOurSubscription`) işlenir: başka ürünün (aynı Stripe hesabı) abonelik olayı
 *   loglanır ve işlenmiş sayılır; müşterinin başka ürün abonelikleri kopya sayılmaz, iade ya da iptal edilmez.
 * - Tanınmayan müşteri (ör. silinmiş hesap): abonelik Stripe'ta yaşıyorsa hemen iptal edilir ve alarm yazılır (ödeme
 *   alınıp hak verilmeyen abonelik kalmasın); olay işlenmiş sayılır.
 * - Yaşayan ikinci abonelik: fazlası (daha yeni ya da erişimi daha düşük olan) önce kalıcı olarak kopya yazılır, sonra
 *   korunan abonelik oluşturulduktan sonra kesilmiş ödenmiş faturaları tam iade edilir (`refundDuplicate`), en son
 *   iptal edilir ve alarm yazılır. İade ya da iptal başarısız olursa Stripe olayı yeniden gönderir, kopya yine bulunur;
 *   zaten iade edilmiş ödeme atlanır, kalan iş yeniden denenir. İptalden sonra geç ödenen faturası `invoice.paid` ile
 *   aynı kurala göre iade edilir (`invoicePaidDuplicateRefund`).
 * - İptal nedeni (`cancellation_details`): olaydaki geçerli aboneliğin Stripe'taki güncel nedeni
 *   `subscription_cancellations`'a yazılır, iptali geri alınırsa silinir (`cancellationStatements`).
 * - `past_due_since`: durum `past_due` olduğunda yazılır, `past_due` sürdükçe korunur, başka duruma geçince silinir;
 *   ek süre bundan hesaplanır (`entitlements.subscriptionAccess`).
 * - `plan` ve `tier`: geçerli aboneliğin fiyatından (`planOfSubscription`, `tierOfSubscription`); Portal'da plan ya da
 *   katman değişirse (`createPlanChange`) sonraki olay günceller.
 * - `first_paid_at`: boşsa hesabın kayıtlı ilk ücretli faturasından (`firstPaidAtSql`; fatura abonelik olayından önce
 *   gelmiş olabilir); doluysa korunur (yeniden abone olunca da).
 * - Süren ücretsiz erişim (`complimentary.ts`) ezilmez: olay Stripe çağrılmadan işlenmiş sayılır ve alarm yazılır
 *   (ücretsiz erişimi olan hesabın Stripe'ta yaşayan aboneliği elle incelenmeli). Süresi geçmiş ücretsiz erişimin
 *   yerini Stripe aboneliği alır. Koşul yazımın kendisinde de vardır (arada verilen ücretsiz erişim ezilmez).
 * - Davet: Stripe'ta bitmiş (`canceled`, `incomplete_expired`) aboneliklerin ücretsiz ayındaki (`joined`) davetleri
 *   düşer (`referralVoidUnpaidStatement`): ilk ücretli fatura hiç gelmeyecek.
 * - App Store: yeni etkinleşen Stripe aboneliğinin hesabında erişimi olan App Store aboneliği varsa alarm yazılır
 *   (`alertIfBilledTwice`); satır yine yazılır, iade kendiliğinden yapılmaz.
 * Yazım `last_event_created` ile sıralanır: eşzamanlı iki webhook'tan daha eski olayınki daha yeniyi ezmez.
 */
async function subscriptionEventStatements(
  db: D1Database,
  stripe: Stripe,
  platform: Platform,
  event: Stripe.Event,
  subscription: Stripe.Subscription,
  prices: StripePrices,
  appStoreAcceptSandbox: boolean,
): Promise<EventStatements> {
  const customer: string = customerIdOf(subscription.customer);
  const owner: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM stripe_customers WHERE stripe_customer_id = ?")
    .bind(customer)
    .first<{ user_id: string }>();
  if (!isOurSubscription(subscription, prices)) {
    log("info", "stripe_event_foreign_subscription_ignored", { eventId: event.id, type: event.type, subscriptionId: subscription.id, knownCustomer: owner !== null });
    return [];
  }
  if (owner === null) {
    const fresh: Stripe.Subscription = await callStripe(platform, "subscriptions.retrieve", null, () => stripe.subscriptions.retrieve(subscription.id));
    if (isLiveInStripe(fresh)) {
      await cancelSubscription(stripe, platform, fresh.id, null);
      log("alert", "stripe_unknown_customer_subscription_canceled", { eventId: event.id, type: event.type, subscriptionId: fresh.id, status: fresh.status });
    } else {
      log("info", "stripe_event_unknown_customer_terminal", { eventId: event.id, type: event.type });
    }
    return [];
  }
  const stored: SubscriptionState | null = await subscriptionState(db, owner.user_id);
  if (stored !== null && isRunningComplimentary(stored, platform.now().getTime())) {
    log("alert", "stripe_event_complimentary_kept", { eventId: event.id, type: event.type, userId: owner.user_id, subscriptionId: subscription.id, status: subscription.status });
    return [];
  }
  const ours: Stripe.Subscription[] = (await customerSubscriptions(stripe, platform, customer, owner.user_id)).filter(
    (candidate: Stripe.Subscription): boolean => isOurSubscription(candidate, prices),
  );
  const choice: SubscriptionChoice = chooseSubscription(ours);
  const current: Stripe.Subscription | null = choice.current;
  if (current === null) {
    log("alert", "stripe_subscription_missing", { eventId: event.id, userId: owner.user_id, subscriptionId: subscription.id });
    throw new ApiError("internal_error", "The customer's subscription was not found in Stripe.");
  }
  for (const duplicate of choice.duplicates) {
    await markDuplicate(db, duplicate.id, owner.user_id, customer, current.created, platform.now().getTime());
    const refundedPayments: number = await refundDuplicate(stripe, platform, duplicate.id, owner.user_id, current.created);
    await cancelSubscription(stripe, platform, duplicate.id, owner.user_id);
    log("alert", "stripe_duplicate_subscription_canceled", {
      userId: owner.user_id,
      subscriptionId: duplicate.id,
      status: duplicate.status,
      keptSubscriptionId: current.id,
      refundedPayments,
    });
  }
  await alertIfBilledTwice(db, platform, event, owner.user_id, current, appStoreAcceptSandbox);
  const state: SubscriptionState = stateOf(current);
  const nowMs: number = platform.now().getTime();
  return [
    db
      .prepare(
        `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, cancel_at,
           past_due_since, last_event_created, updated_at, plan, first_paid_at, tier, started_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, CASE WHEN ?4 = 'past_due' THEN ?8 END, ?7, ?8, ?9, ${firstPaidAtSql("?1")}, ?10, ?11)
         ON CONFLICT(user_id) DO UPDATE SET stripe_customer_id = excluded.stripe_customer_id, plan = excluded.plan, tier = excluded.tier,
           started_at = excluded.started_at,
           withdrawal_requested_at = CASE WHEN subscriptions.stripe_subscription_id = excluded.stripe_subscription_id
             THEN subscriptions.withdrawal_requested_at ELSE NULL END,
           complimentary = 0,
           first_paid_at = COALESCE(subscriptions.first_paid_at, excluded.first_paid_at),
           past_due_since = CASE
             WHEN excluded.status <> 'past_due' THEN NULL
             WHEN subscriptions.status = 'past_due' AND subscriptions.stripe_subscription_id = excluded.stripe_subscription_id
               THEN COALESCE(subscriptions.past_due_since, excluded.past_due_since)
             ELSE excluded.past_due_since END,
           stripe_subscription_id = excluded.stripe_subscription_id, status = excluded.status,
           current_period_end = excluded.current_period_end, cancel_at = excluded.cancel_at,
           last_event_created = excluded.last_event_created, updated_at = excluded.updated_at
         WHERE excluded.last_event_created >= subscriptions.last_event_created
           AND NOT ${runningComplimentarySql("subscriptions.", "?8")}`,
      )
      .bind(
        owner.user_id,
        customer,
        current.id,
        state.status,
        state.currentPeriodEnd,
        state.cancelAt,
        event.created,
        nowMs,
        planOfSubscription(current, prices),
        tierOfSubscription(current, prices),
        current.created * 1000,
      ),
    // İptal nedeni yalnızca geçerli abonelik için yazılır: bizim iptal ettiğimiz kopya aboneliklerin nedeni
    // (`cancellation_requested`) kullanıcının iptali değildir. Olayın anlık görüntüsü değil güncel hâli yazılır.
    ...(subscription.id === current.id ? cancellationStatements(db, event, current, owner.user_id, nowMs) : []),
    ...ours
      .filter((candidate: Stripe.Subscription): boolean => !isLiveInStripe(candidate))
      .map((ended: Stripe.Subscription): D1PreparedStatement => referralVoidUnpaidStatement(db, ended.id, nowMs)),
  ];
}

/**
 * İki kaynaktan çift ödeme alarmı: iPhone'dan (App Store) abone olmadan önce açılmış bir Checkout sayfası sonradan
 * ödenirse hesap hem Apple'a hem Stripe'a öder (App Store abonesine yeni Checkout açılmaz, ama açık kalmış sayfa
 * ödenebilir). Geçerli Stripe aboneliği `active` ve yeni etkinleşmişse (kayıtlı satır başka abonelik ya da henüz
 * `active` değil) ve hesabın erişimi olan App Store aboneliği varsa alarm yazılır: sahibi Stripe ödemesini elle iade
 * eder. Aynı abonelik `active` kaldıkça sonraki olaylar yeniden alarm yazmaz.
 */
async function alertIfBilledTwice(
  db: D1Database,
  platform: Platform,
  event: Stripe.Event,
  userId: string,
  current: Stripe.Subscription,
  appStoreAcceptSandbox: boolean,
): Promise<void> {
  if (current.status !== "active") {
    return;
  }
  const stored: { stripe_subscription_id: string; status: string } | null = await db
    .prepare("SELECT stripe_subscription_id, status FROM subscriptions WHERE user_id = ?")
    .bind(userId)
    .first<{ stripe_subscription_id: string; status: string }>();
  if (stored !== null && stored.stripe_subscription_id === current.id && stored.status === "active") {
    return;
  }
  const appStore: AppStoreSubscription | null = await appStoreSubscriptionOf(db, userId);
  if (appStore === null || appStoreAccess(appStore, appStoreAcceptSandbox, platform.now()) === "none") {
    return;
  }
  log("alert", "stripe_subscription_with_app_store_access", {
    eventId: event.id,
    type: event.type,
    userId,
    subscriptionId: current.id,
    customer: customerIdOf(current.customer),
    latestInvoice: latestInvoiceId(current),
    appStoreProductId: appStore.productId,
    appStoreStatus: appStore.status,
    appStoreExpiresAt: appStore.expiresAt,
  });
}

/**
 * `customer.deleted`: müşteri eşlemesi ve abonelik satırı silinir (Stripe müşteriyle birlikte abonelikleri de bitirir);
 * kullanıcının müşteri kuşağı artar ki sonraki Checkout yeni müşteri açabilsin (bkz. `customerCreationKey`).
 */
async function customerDeletedStatements(db: D1Database, event: Stripe.Event, customer: string): Promise<EventStatements> {
  const owner: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM stripe_customers WHERE stripe_customer_id = ?")
    .bind(customer)
    .first<{ user_id: string }>();
  log("warn", "stripe_customer_deleted", { eventId: event.id, userId: owner?.user_id ?? null });
  const statements: EventStatements = [
    db.prepare("DELETE FROM subscriptions WHERE stripe_customer_id = ?").bind(customer),
    db.prepare("DELETE FROM stripe_customers WHERE stripe_customer_id = ?").bind(customer),
  ];
  return owner === null
    ? statements
    : [...statements, db.prepare("UPDATE users SET stripe_customer_generation = stripe_customer_generation + 1 WHERE id = ?").bind(owner.user_id)];
}

/** Müşterinin kullanıcısı; tanınmıyorsa null. */
async function customerOwner(db: D1Database, customer: string | null): Promise<string | null> {
  if (customer === null) {
    return null;
  }
  const row: { user_id: string } | null = await db
    .prepare("SELECT user_id FROM stripe_customers WHERE stripe_customer_id = ?")
    .bind(customer)
    .first<{ user_id: string }>();
  return row === null ? null : row.user_id;
}

/**
 * `charge.dispute.created`: itiraz edilen ödemenin müşterisinin bizim (`isOurSubscription`) yaşayan abonelikleri hemen
 * iptal edilir (itiraz sürerken yeni dönem ücretlenmesin) ve alarm yazılır; başka ürünlerin aboneliklerine dokunulmaz.
 * Abonelik satırı ardından gelen `customer.subscription.deleted` ile güncellenir. Müşteri bir davetle abone olduysa
 * bekleyen davet ödülü düşer (`disputed`).
 */
async function disputeStatements(db: D1Database, stripe: Stripe, platform: Platform, event: Stripe.Event, dispute: Stripe.Dispute, prices: StripePrices): Promise<EventStatements> {
  const chargeId: string = typeof dispute.charge === "string" ? dispute.charge : dispute.charge.id;
  const charge: Stripe.Charge = await callStripe(platform, "charges.retrieve", null, () => stripe.charges.retrieve(chargeId));
  const customer: string | null = charge.customer === null ? null : customerIdOf(charge.customer);
  const userId: string | null = await customerOwner(db, customer);
  const live: Stripe.Subscription[] =
    customer === null
      ? []
      : (await customerSubscriptions(stripe, platform, customer, userId)).filter(
          (subscription: Stripe.Subscription): boolean => isLiveInStripe(subscription) && isOurSubscription(subscription, prices),
        );
  for (const subscription of live) {
    await cancelSubscription(stripe, platform, subscription.id, userId);
  }
  log("alert", "stripe_dispute_created", {
    eventId: event.id,
    disputeId: dispute.id,
    chargeId,
    userId,
    amount: dispute.amount,
    currency: dispute.currency,
    reason: dispute.reason,
    canceledSubscriptions: live.length,
  });
  return userId === null ? [] : [referralVoidByReferredStatement(db, userId, "disputed", platform.now().getTime())];
}

/** Ödemenin faturası (Stripe'tan okunan güncel hâli) ve faturanın aboneliği. */
interface ChargeInvoice {
  readonly invoiceId: string;
  readonly subscriptionId: string;
  readonly invoice: Stripe.Invoice;
}

/**
 * Ödemenin ait olduğu fatura ve abonelik: ödeme niyeti → fatura ödemesi → fatura → abonelik. Zincir kurulamazsa
 * (fatura dışı ödeme, eski ödeme kaydı, aboneliksiz fatura) null.
 */
async function chargeInvoice(stripe: Stripe, platform: Platform, charge: Stripe.Charge, userId: string | null): Promise<ChargeInvoice | null> {
  const intent: string | null = charge.payment_intent === null ? null : typeof charge.payment_intent === "string" ? charge.payment_intent : charge.payment_intent.id;
  if (intent === null) {
    return null;
  }
  const payments: Stripe.ApiList<Stripe.InvoicePayment> = await callStripe(platform, "invoicePayments.list", userId, () =>
    stripe.invoicePayments.list({ payment: { type: "payment_intent", payment_intent: intent }, limit: 10 }),
  );
  const first: Stripe.InvoicePayment | undefined = payments.data[0];
  if (first === undefined) {
    return null;
  }
  const invoiceId: string = typeof first.invoice === "string" ? first.invoice : (first.invoice.id ?? "");
  if (invoiceId === "") {
    return null;
  }
  const invoice: Stripe.Invoice = await callStripe(platform, "invoices.retrieve", userId, () => stripe.invoices.retrieve(invoiceId));
  const subscriptionId: string | null = invoiceSubscriptionId(invoice);
  return subscriptionId === null ? null : { invoiceId, subscriptionId, invoice };
}

/**
 * İadenin gelir ifadeleri: ödemenin faturası ödenmişse ve müşterisi tanınan hesapsa önce fatura satırı
 * (`revenueInvoiceStatements`; `invoice.paid` ile aynı satır, zaten yazıldıysa değişmez), sonra birikimli iade. Fatura
 * satırı iadeyle birlikte yazılır: `charge.refunded`, `invoice.paid`'den önce işlenirse iade kaybolmaz (iade satırı
 * kayıtlı faturaya bağlıdır) ve geç gelen `invoice.paid` aynı satırı ikinci kez yazmaz. Saf fonksiyondur.
 */
function chargeRefundRevenueStatements(db: D1Database, event: Stripe.Event, charge: Stripe.Charge, paid: ChargeInvoice | null, userId: string | null): EventStatements {
  if (paid === null) {
    return [];
  }
  const invoiceRow: EventStatements =
    userId !== null && paid.invoice.status === "paid"
      ? revenueInvoiceStatements(db, userId, invoiceRevenueOf(paid.invoice, paid.invoiceId, paid.subscriptionId, event.created))
      : [];
  return [...invoiceRow, revenueRefundStatement(db, charge, paid.invoiceId, event.created * 1000)];
}

/** Aboneliğin son faturasının kimliği; yoksa null. Saf fonksiyondur. */
function latestInvoiceId(subscription: Stripe.Subscription): string | null {
  const latest: string | Stripe.Invoice | null = subscription.latest_invoice;
  if (latest === null) {
    return null;
  }
  return typeof latest === "string" ? latest : (latest.id ?? null);
}

/**
 * `charge.refunded`: her iade alarm yazar. Tam iade (`refunded === true`) yalnızca o ödemenin ait olduğu aboneliği
 * (`chargeInvoice`) ve yalnızca iade edilen ödeme aboneliğin son faturasıysa bitirir: abonelik Stripe'ta yaşıyorsa
 * hemen iptal edilir ve satırı yalnızca abonelik kimliği eşleşiyorsa aynı toplu işlemde `canceled` yazılır (erişim
 * hemen biter; ardından gelen `customer.subscription.deleted` aynı durumu yazar). Alarmdan öteye geçmeyenler: eski bir
 * aboneliğin ya da aynı aboneliğin eski bir ayının iadesi (ödenmiş güncel ay kesilmez), aynı Stripe hesabındaki başka
 * ürünün aboneliği (`isOurSubscription`), kopya aboneliğin iadesi, aboneliği bulunamayan ödeme ve kısmi iade.
 * Davet ödülü: aboneliğin herhangi bir (kısmi de olsa) iadesi bekleyen davet ödülünü düşürür (`refunded`). Gelir:
 * ödemenin faturası abonelik faturasıysa fatura satırı (henüz yoksa) ve birikimli iade tutarı yazılır
 * (`chargeRefundRevenueStatements`).
 */
async function chargeRefundedStatements(db: D1Database, stripe: Stripe, platform: Platform, event: Stripe.Event, charge: Stripe.Charge, prices: StripePrices): Promise<EventStatements> {
  const customer: string | null = charge.customer === null ? null : customerIdOf(charge.customer);
  const userId: string | null = await customerOwner(db, customer);
  const paid: ChargeInvoice | null = await chargeInvoice(stripe, platform, charge, userId);
  const subscriptionId: string | null = paid?.subscriptionId ?? null;
  const duplicate: boolean = subscriptionId !== null && (await duplicateRecord(db, subscriptionId)) !== null;
  const nowMs: number = platform.now().getTime();
  const referralVoid: EventStatements = subscriptionId === null ? [] : [referralVoidBySubscriptionStatement(db, subscriptionId, "refunded", nowMs)];
  let ours: boolean = false;
  let latest: boolean = false;
  let canceled: boolean = false;
  if (paid !== null && charge.refunded && !duplicate) {
    const subscription: Stripe.Subscription = await callStripe(platform, "subscriptions.retrieve", userId, () => stripe.subscriptions.retrieve(paid.subscriptionId));
    ours = isOurSubscription(subscription, prices);
    latest = latestInvoiceId(subscription) === paid.invoiceId;
    if (ours && latest && isLiveInStripe(subscription)) {
      await cancelSubscription(stripe, platform, subscription.id, userId);
      canceled = true;
    }
  }
  const ends: boolean = ours && latest;
  log("alert", "stripe_charge_refunded", {
    eventId: event.id,
    chargeId: charge.id,
    userId,
    subscriptionId,
    amountRefunded: charge.amount_refunded,
    currency: charge.currency,
    fullyRefunded: charge.refunded,
    duplicateRefund: duplicate,
    ourSubscription: ours,
    latestInvoice: latest,
    canceled,
  });
  // Gelir: ödemenin faturası abonelik faturamızsa birikimli iade tutarı (kopya aboneliğin iadesi dahil).
  const revenue: EventStatements = chargeRefundRevenueStatements(db, event, charge, paid, userId);
  if (!ends || userId === null || subscriptionId === null) {
    return [...referralVoid, ...revenue];
  }
  return [
    db
      .prepare(
        `UPDATE subscriptions SET status = 'canceled', cancel_at = ?1, past_due_since = NULL,
           last_event_created = MAX(last_event_created, ?2), updated_at = ?1
         WHERE user_id = ?3 AND stripe_subscription_id = ?4`,
      )
      .bind(nowMs, event.created, userId, subscriptionId),
    ...referralVoid,
    ...revenue,
  ];
}

/**
 * `invoice.paid`: fatura kopya olarak yazılmış bir aboneliğinse (iptalden sonra geç ödendi) ve korunan abonelik
 * oluşturulduktan sonra kesildiyse (`duplicateInvoicesToRefund`) ödemesi tam iade edilir (tekrarı güvenli) ve alarm
 * yazılır; kopyanın daha eski bir dönemine ait fatura iade edilmez (loglanır). Diğer faturalar yalnızca kaydedilir.
 */
async function invoicePaidDuplicateRefund(db: D1Database, stripe: Stripe, platform: Platform, event: Stripe.Event, invoice: Stripe.Invoice): Promise<void> {
  const subscriptionId: string | null = invoiceSubscriptionId(invoice);
  if (subscriptionId === null || invoice.id === undefined) {
    return;
  }
  const record: DuplicateRecord | null = await duplicateRecord(db, subscriptionId);
  if (record === null) {
    return;
  }
  if (record.refundSince !== null && duplicateInvoicesToRefund([invoice], record.refundSince).length === 0) {
    log("info", "stripe_duplicate_late_payment_kept", { eventId: event.id, userId: record.userId, subscriptionId, invoiceId: invoice.id });
    return;
  }
  const refundedPayments: number = await refundInvoicePayments(stripe, platform, invoice.id, subscriptionId, record.userId);
  log("alert", "stripe_duplicate_late_payment_refunded", { eventId: event.id, userId: record.userId, subscriptionId, invoiceId: invoice.id, refundedPayments });
}

/**
 * Aboneliğin varsayılan ödeme yönteminin kart parmak izi (Checkout aboneliği toplanan kartla açar); ödeme yöntemi yoksa
 * ya da kart değilse (ör. Link) null.
 */
async function subscriptionCardFingerprint(stripe: Stripe, platform: Platform, subscriptionId: string, userId: string): Promise<string | null> {
  const subscription: Stripe.Subscription = await callStripe(platform, "subscriptions.retrieve", userId, () =>
    stripe.subscriptions.retrieve(subscriptionId, { expand: ["default_payment_method"] }),
  );
  const method: string | Stripe.PaymentMethod | null = subscription.default_payment_method;
  if (method === null) {
    return null;
  }
  const resolved: Stripe.PaymentMethod =
    typeof method === "string" ? await callStripe(platform, "paymentMethods.retrieve", userId, () => stripe.paymentMethods.retrieve(method)) : method;
  return resolved.card?.fingerprint ?? null;
}

/** Müşterinin Stripe'ta kayıtlı kartlarının parmak izleri (tek sayfa, en çok 100). */
async function customerCardFingerprints(stripe: Stripe, platform: Platform, customer: string, userId: string): Promise<string[]> {
  const page: Stripe.ApiList<Stripe.PaymentMethod> = await callStripe(platform, "customers.listPaymentMethods", userId, () =>
    stripe.customers.listPaymentMethods(customer, { type: "card", limit: 100 }),
  );
  return page.data
    .map((method: Stripe.PaymentMethod): string | null => method.card?.fingerprint ?? null)
    .filter((fingerprint: string | null): fingerprint is string => fingerprint !== null);
}

/**
 * Faturanın davet katılımı: hesabın katılmamış (`joined_at` boş, `checkout` ya da davet eden silindiği için `void`)
 * satırı faturanın koduyla eşleşiyorsa aboneliğin kartı (`subscriptionCardFingerprint`) özetlenir ve davet edenin
 * Stripe kartlarıyla karşılaştırılır; eşleşen satır yoksa Stripe çağrılmaz, null. Kart bulunamazsa uyarı yazılır ve
 * katılım kartsız yazılır (kart denetimi yapılamadı; yönetim panelinde görünür).
 */
async function referralJoinOf(
  db: D1Database,
  stripe: Stripe,
  platform: Platform,
  config: StripeWebhookConfig,
  userId: string,
  subscriptionId: string,
  code: string,
): Promise<ReferralJoin | null> {
  const row: { referrer_user_id: string | null } | null = await db
    .prepare(
      `SELECT referrer_user_id FROM referral_redemptions
       WHERE referred_user_id = ? AND code = ? AND joined_at IS NULL AND status IN ('checkout', 'void')`,
    )
    .bind(userId, code)
    .first<{ referrer_user_id: string | null }>();
  if (row === null) {
    return null;
  }
  const fingerprint: string | null = await subscriptionCardFingerprint(stripe, platform, subscriptionId, userId);
  if (fingerprint === null) {
    log("warn", "referral_join_without_card", { userId, subscriptionId });
    return { code, cardHash: null, referrersCard: false };
  }
  const referrer: string | null = row.referrer_user_id;
  const referrerCustomer: string | null = referrer === null ? null : await storedCustomerId(db, referrer);
  const referrerCards: string[] =
    referrer === null || referrerCustomer === null ? [] : await customerCardFingerprints(stripe, platform, referrerCustomer, referrer);
  const referrersCard: boolean = referrerCards.includes(fingerprint);
  log("info", "referral_join_card_checked", { userId, subscriptionId, referrerUserId: referrer, referrersCard });
  return { code, cardHash: await referralCardHash(config.secrets.trialHash, fingerprint), referrersCard };
}

/**
 * `invoice.paid` davet ifadeleri (`referralInvoicePaidStatements`): faturanın müşterisi tanınan kullanıcıysa ve
 * abonelik kopya değilse. Davet kodu, Checkout'un aboneliğe yazdığı `metadata.referral_code`'un faturadaki kopyasından
 * (`parent.subscription_details.metadata`) okunur; katılım kartı `referralJoinOf` ile denetlenir.
 */
async function invoicePaidReferralStatements(
  db: D1Database,
  stripe: Stripe,
  platform: Platform,
  config: StripeWebhookConfig,
  invoice: Stripe.Invoice,
): Promise<EventStatements> {
  const subscriptionId: string | null = invoiceSubscriptionId(invoice);
  if (subscriptionId === null || invoice.id === undefined || invoice.customer === null) {
    return [];
  }
  const userId: string | null = await customerOwner(db, customerIdOf(invoice.customer));
  if (userId === null || (await duplicateRecord(db, subscriptionId)) !== null) {
    return [];
  }
  const metadata: Stripe.Metadata | null = invoice.parent?.subscription_details?.metadata ?? null;
  const code: string | null = metadata?.["referral_code"] ?? null;
  return referralInvoicePaidStatements(db, {
    userId,
    subscriptionId,
    invoiceId: invoice.id,
    join: code === null ? null : await referralJoinOf(db, stripe, platform, config, userId, subscriptionId, code),
    amountPaid: invoice.amount_paid,
    nowMs: platform.now().getTime(),
  });
}

/**
 * `invoice.paid` gelir ifadeleri (`revenueInvoiceStatements`): faturanın müşterisi tanınan kullanıcıysa ve fatura bir
 * aboneliğinse. Kopya aboneliğin faturası da yazılır (tahsil edildi; iadesi `charge.refunded` ile düşer). Stripe
 * çağrılmaz.
 */
async function invoicePaidRevenueStatements(db: D1Database, event: Stripe.Event, invoice: Stripe.Invoice): Promise<EventStatements> {
  const subscriptionId: string | null = invoiceSubscriptionId(invoice);
  if (subscriptionId === null || invoice.id === undefined || invoice.customer === null) {
    return [];
  }
  const userId: string | null = await customerOwner(db, customerIdOf(invoice.customer));
  if (userId === null) {
    log("info", "stripe_invoice_unknown_customer", { eventId: event.id, invoiceId: invoice.id });
    return [];
  }
  const revenue: InvoiceRevenue = invoiceRevenueOf(invoice, invoice.id, subscriptionId, event.created);
  return revenueInvoiceStatements(db, userId, revenue);
}

/** Olay türüne göre Stripe yan etkileri ve veritabanı ifadeleri; tanınmayan olay yalnızca kaydedilir. */
async function eventStatements(db: D1Database, platform: Platform, config: StripeWebhookConfig, event: Stripe.Event): Promise<EventStatements> {
  const subscription: Stripe.Subscription | null = subscriptionFromEvent(event);
  if (subscription !== null) {
    return subscriptionEventStatements(db, stripeClient(platform, config), platform, event, subscription, config.stripePrices, config.appStore.acceptSandbox);
  }
  switch (event.type) {
    case "customer.deleted":
      return customerDeletedStatements(db, event, event.data.object.id);
    case "charge.refunded":
      return chargeRefundedStatements(db, stripeClient(platform, config), platform, event, event.data.object, config.stripePrices);
    case "invoice.paid": {
      const stripe: Stripe = stripeClient(platform, config);
      await invoicePaidDuplicateRefund(db, stripe, platform, event, event.data.object);
      return [
        ...(await invoicePaidReferralStatements(db, stripe, platform, config, event.data.object)),
        ...(await invoicePaidRevenueStatements(db, event, event.data.object)),
      ];
    }
    case "charge.dispute.created":
      return disputeStatements(db, stripeClient(platform, config), platform, event, event.data.object, config.stripePrices);
    default:
      return [];
  }
}

/**
 * Stripe webhook'u (yalnızca Stripe ayarlarıyla çalışır: `StripeWebhookConfig`): imza `constructEventAsync` ile doğrulanır (5 dakika tolerans). Olayın modu (`livemode`) anahtarın
 * moduyla (`sk_live`/`rk_live` ↔ `sk_test`/`rk_test`) uyuşmazsa alarm yazılır ve `500` döner (yapılandırma hatası;
 * Stripe yeniden dener, düzeltilince olay işlenir). İşlenmiş olay Stripe çağrılmadan `duplicate` döner. Olay kimliği
 * `stripe_events` tablosuna, durum değişiklikleri aynı toplu işlemde yazılır: aynı olay eşzamanlı ikinci kez gelirse
 * birincil anahtar çakışır, hiçbir şey değişmez. İşlenen olaylar: abonelik olayları (`subscriptionEventStatements`),
 * `customer.deleted`, `charge.refunded` (alarm; tam iadede ödemenin aboneliği biter; davet ödülü düşer; gelirden iade),
 * `invoice.paid` (kopya aboneliğin geç ödemesi iade edilir; davetle aboneliğin ilerlemesi ve katılımda kart denetimi;
 * gelir satırı ve ilk ödeme anı),
 * `charge.dispute.created` (alarm, abonelik iptali, davet ödülü düşer); diğerleri yalnızca kaydedilir.
 */
export async function handleStripeWebhook(db: D1Database, platform: Platform, config: StripeWebhookConfig, payload: string, signature: string): Promise<{ duplicate: boolean }> {
  warnIfStripeTestMode(config, "webhook");
  let event: Stripe.Event;
  try {
    event = await Stripe.webhooks.constructEventAsync(
      payload,
      signature,
      config.secrets.stripeWebhook,
      300,
      Stripe.createSubtleCryptoProvider(),
      // Stripe `receivedAt`'ı milisaniye bekler (yaş = floor(receivedAt / 1000) - imza zamanı).
      platform.now().getTime(),
    );
  } catch (error: unknown) {
    log("warn", "stripe_webhook_rejected", { error: errorName(error) });
    throw new ApiError("webhook_invalid", "Invalid webhook signature.");
  }
  if (event.livemode !== (config.stripeMode === "live")) {
    log("alert", "stripe_mode_mismatch", { eventId: event.id, type: event.type, eventLivemode: event.livemode, keyMode: config.stripeMode });
    throw new ApiError("internal_error", "The Stripe key mode does not match the webhook event.");
  }
  const seen: { id: string } | null = await db.prepare("SELECT id FROM stripe_events WHERE id = ?").bind(event.id).first<{ id: string }>();
  if (seen !== null) {
    log("info", "stripe_event_duplicate", { eventId: event.id, type: event.type });
    return { duplicate: true };
  }
  const statements: EventStatements = await eventStatements(db, platform, config, event);
  const recordEvent: D1PreparedStatement = db
    .prepare("INSERT INTO stripe_events (id, type, processed_at) VALUES (?, ?, ?)")
    .bind(event.id, event.type, platform.now().getTime());
  let results: D1Result[];
  try {
    results = await db.batch([recordEvent, ...statements]);
  } catch (error: unknown) {
    const recorded: { id: string } | null = await db.prepare("SELECT id FROM stripe_events WHERE id = ?").bind(event.id).first<{ id: string }>();
    if (recorded !== null) {
      log("info", "stripe_event_duplicate", { eventId: event.id, type: event.type });
      return { duplicate: true };
    }
    throw error;
  }
  if (subscriptionFromEvent(event) !== null && statements.length > 0 && results[1]?.meta.changes !== 1) {
    // Daha yeni bir olay zaten yazılmıştı: kaydedildi, durumu değiştirmedi.
    log("info", "stripe_event_not_applied", { eventId: event.id, type: event.type });
  }
  log("info", "stripe_event_processed", { eventId: event.id, type: event.type });
  return { duplicate: false };
}
