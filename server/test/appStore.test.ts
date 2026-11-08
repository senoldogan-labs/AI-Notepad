import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { type AppStoreSubscription, appStoreSyncStatements } from "../src/appStore";
import { randomId } from "../src/crypto";
import type { Env } from "../src/env";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantAppStoreSubscription, grantSubscription, req, signIn, signInWithGoogle, startMeeting } from "./helpers";
import { type FakeStripe, stubStripeApi } from "./stripeFake";

const dayMs: number = 86_400_000;
const webhookAuth: string = "Bearer test-revenuecat-webhook-auth-000";
const monthly: string = "com.senoldogan.gistsmith.monthly";
const yearly: string = "com.senoldogan.gistsmith.yearly";
const revenueCatPrefix: string = "https://api.revenuecat.com/v1/subscribers/";
const adminSubject: string = "app-store-admin-sub";
const adminEnv: Env = envWith({ ADMIN_IDENTITIES: `google:${adminSubject}` });

/** Gizli RevenueCat API anahtarı girilmemiş ortam. */
function envWithoutRevenueCatKey(): Env {
  const { REVENUECAT_SECRET_API_KEY: removed, ...rest }: Env = env;
  expect(removed).toBeDefined();
  return rest;
}

/** RevenueCat abonelik kaydının test alanları. */
interface FakeSubscription {
  readonly expiresMs: number;
  readonly purchasedMs: number;
  readonly sandbox: boolean;
  readonly periodType: string;
  readonly store: string;
  readonly unsubscribedMs: number | null;
  readonly billingIssueMs: number | null;
  readonly graceMs: number | null;
  readonly refundedMs: number | null;
}

function subscription(fields: Partial<FakeSubscription> & { expiresMs: number }): FakeSubscription {
  return {
    purchasedMs: fields.expiresMs - 30 * dayMs,
    sandbox: false,
    periodType: "normal",
    store: "app_store",
    unsubscribedMs: null,
    billingIssueMs: null,
    graceMs: null,
    refundedMs: null,
    ...fields,
  };
}

function iso(ms: number | null): string | null {
  return ms === null ? null : new Date(ms).toISOString();
}

/** `GET /v1/subscribers/{id}` yanıtı (RevenueCat v1 biçimi). */
function subscriberBody(nowMs: number, subscriptions: Readonly<Record<string, FakeSubscription>>): object {
  return {
    request_date: new Date(nowMs).toISOString(),
    request_date_ms: nowMs,
    subscriber: {
      entitlements: {},
      original_app_user_id: "ignored",
      management_url: "https://apps.apple.com/account/subscriptions",
      subscriptions: Object.fromEntries(
        Object.entries(subscriptions).map(([productId, item]: [string, FakeSubscription]): [string, object] => [
          productId,
          {
            expires_date: iso(item.expiresMs),
            purchase_date: iso(item.purchasedMs),
            original_purchase_date: iso(item.purchasedMs),
            period_type: item.periodType,
            store: item.store,
            is_sandbox: item.sandbox,
            unsubscribe_detected_at: iso(item.unsubscribedMs),
            billing_issues_detected_at: iso(item.billingIssueMs),
            grace_period_expires_date: iso(item.graceMs),
            refunded_at: iso(item.refundedMs),
            ownership_type: "PURCHASED",
            store_transaction_id: "1000000000000000",
          },
        ]),
      ),
    },
  };
}

/** RevenueCat REST API'sinin sahtesi: kullanıcı başına abonelikler; çağrılar sayılır. */
interface FakeRevenueCat {
  readonly subscribers: Map<string, Record<string, FakeSubscription>>;
  readonly calls: string[];
  failures: number;
}

function stubRevenueCat(harness: Harness): FakeRevenueCat {
  const fake: FakeRevenueCat = { subscribers: new Map(), calls: [], failures: 0 };
  harness.stub(revenueCatPrefix, async (request: Request): Promise<Response> => {
    expect(request.headers.get("authorization")).toBe("Bearer sk_test_revenuecat_fake_000000");
    const userId: string = decodeURIComponent(request.url.slice(revenueCatPrefix.length));
    fake.calls.push(userId);
    if (fake.failures > 0) {
      fake.failures -= 1;
      return new Response("unavailable", { status: 503 });
    }
    return Response.json(subscriberBody(harness.clock.nowMs, fake.subscribers.get(userId) ?? {}), { status: 200 });
  });
  return fake;
}

interface WebhookEvent {
  readonly id: string;
  readonly type: string;
  readonly environment: "SANDBOX" | "PRODUCTION";
  readonly app_user_id?: string;
  readonly original_app_user_id?: string;
  readonly aliases?: string[];
  readonly transferred_from?: string[];
  readonly transferred_to?: string[];
}

function webhookEvent(type: string, userId: string): WebhookEvent {
  return { id: randomId(), type, environment: "PRODUCTION", app_user_id: userId, original_app_user_id: `$RCAnonymousID:${randomId()}`, aliases: [userId] };
}

function postWebhook(harness: Harness, event: WebhookEvent, auth: string | null, testEnv: Env | null): Promise<Response> {
  const body: object = { api_version: "1.0", event: { event_timestamp_ms: harness.clock.nowMs, product_id: monthly, ...event } };
  return harness.call(req("POST", "/v1/webhooks/revenuecat", { json: body, headers: auth === null ? {} : { authorization: auth }, env: testEnv }));
}

interface WebhookBody {
  readonly received: boolean;
  readonly outcome: string;
  readonly users: number;
}

interface MeBody {
  readonly plan: string;
  readonly subscriptionSources: string[];
  readonly appStoreSubscription: {
    status: string;
    plan: string | null;
    productId: string;
    access: string;
    expiresAt: string;
    willRenew: boolean;
    graceEndsAt: string | null;
    environment: string;
    manageUrl: string;
  } | null;
  readonly subscription: {
    source: string;
    status: string;
    currentPeriodEnd: string;
    cancelAt: string | null;
    access: string;
    graceEndsAt: string | null;
    plan: string | null;
    complimentary: boolean;
  } | null;
}

async function me(harness: Harness, session: Session): Promise<MeBody> {
  const response: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken }));
  expect(response.status).toBe(200);
  return response.json<MeBody>();
}

async function appStoreRow(userId: string): Promise<{ status: string; plan: string | null; environment: string; last_event_id: string | null } | null> {
  return env.DB.prepare("SELECT status, plan, environment, last_event_id FROM app_store_subscriptions WHERE user_id = ?")
    .bind(userId)
    .first<{ status: string; plan: string | null; environment: string; last_event_id: string | null }>();
}

/** Hesaba App Store aboneliği verir (RevenueCat sahtesi + webhook). */
async function subscribeViaAppStore(harness: Harness, fake: FakeRevenueCat, session: Session, item: FakeSubscription, product: string): Promise<void> {
  fake.subscribers.set(session.userId, { [product]: item });
  const response: Response = await postWebhook(harness, webhookEvent("INITIAL_PURCHASE", session.userId), webhookAuth, null);
  expect(response.status).toBe(200);
}

describe("POST /v1/webhooks/revenuecat", () => {
  it("Authorization başlığı yoksa ya da yanlışsa 401; RevenueCat çağrılmaz, olay yazılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const session: Session = await signIn(harness);
    const event: WebhookEvent = webhookEvent("INITIAL_PURCHASE", session.userId);
    await expectError(await postWebhook(harness, event, null, null), 401, "unauthorized");
    await expectError(await postWebhook(harness, event, "Bearer wrong-value-000000000000", null), 401, "unauthorized");
    await expectError(await postWebhook(harness, event, webhookAuth.toUpperCase(), null), 401, "unauthorized");
    expect(fake.calls).toEqual([]);
    const row = await env.DB.prepare("SELECT COUNT(*) AS count FROM revenuecat_events WHERE id = ?").bind(event.id).first<{ count: number }>();
    expect(row?.count).toBe(0);
  });

  it("gizli değerler eksikse 500 (RevenueCat yeniden dener); bozuk gövde 400 webhook_invalid", async () => {
    const harness: Harness = await defaultHarness();
    stubRevenueCat(harness);
    const session: Session = await signIn(harness);
    const missing: Env = envWithoutRevenueCatKey();
    await expectError(await postWebhook(harness, webhookEvent("RENEWAL", session.userId), webhookAuth, missing), 500, "internal_error");
    const bad: Response = await harness.call(
      req("POST", "/v1/webhooks/revenuecat", { json: { api_version: "1.0", event: { id: "x" } }, headers: { authorization: webhookAuth } }),
    );
    await expectError(bad, 400, "webhook_invalid");
  });

  it("TEST olayı kaydedilir, RevenueCat çağrılmaz", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const response: Response = await postWebhook(harness, { id: randomId(), type: "TEST", environment: "PRODUCTION", app_user_id: "test-user" }, webhookAuth, null);
    expect(response.status).toBe(200);
    expect(await response.json<WebhookBody>()).toEqual({ received: true, outcome: "test", users: 0 });
    expect(fake.calls).toEqual([]);
  });

  it("satın alma durumu REST'ten okur ve hakkı açar; aynı olay ikinci kez işlenmez", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const session: Session = await signIn(harness);
    const expiresMs: number = harness.clock.nowMs + 30 * dayMs;
    fake.subscribers.set(session.userId, { [monthly]: subscription({ expiresMs }) });
    const event: WebhookEvent = webhookEvent("INITIAL_PURCHASE", session.userId);

    const first: Response = await postWebhook(harness, event, webhookAuth, null);
    expect(first.status).toBe(200);
    expect(await first.json<WebhookBody>()).toEqual({ received: true, outcome: "synced", users: 1 });
    expect(fake.calls).toEqual([session.userId]);
    expect(await appStoreRow(session.userId)).toEqual({ status: "active", plan: "monthly", environment: "PRODUCTION", last_event_id: event.id });

    const again: Response = await postWebhook(harness, event, webhookAuth, null);
    expect(await again.json<WebhookBody>()).toEqual({ received: true, outcome: "duplicate", users: 0 });
    expect(fake.calls).toHaveLength(1);

    const body: MeBody = await me(harness, session);
    expect(body.plan).toBe("subscription");
    expect(body.subscriptionSources).toEqual(["app_store"]);
    expect(body.subscription).toEqual({
      source: "app_store",
      status: "active",
      currentPeriodEnd: new Date(expiresMs).toISOString(),
      cancelAt: null,
      access: "active",
      graceEndsAt: null,
      plan: "monthly",
      tier: "personal",
      complimentary: false,
    });
    expect(body.appStoreSubscription).toMatchObject({ status: "active", access: "active", willRenew: true, environment: "PRODUCTION", manageUrl: "https://apps.apple.com/account/subscriptions" });
    // Abone toplantısı açılır (deneme ve DeviceCheck yolu değil).
    const started: Response = await startMeeting(harness, session);
    expect(started.status).toBe(201);
    expect((await started.json<{ kind: string }>()).kind).toBe("subscription");
  });

  // Durum olay türünden değil RevenueCat'in güncel kaydından gelir: her tür aynı eşitlemeyi tetikler.
  const cases: ReadonlyArray<{ type: string; item: (nowMs: number) => Record<string, FakeSubscription>; status: string; access: string; plan: string | null }> = [
    { type: "RENEWAL", item: (nowMs) => ({ [monthly]: subscription({ expiresMs: nowMs + 30 * dayMs }) }), status: "active", access: "active", plan: "monthly" },
    {
      type: "CANCELLATION",
      item: (nowMs) => ({ [monthly]: subscription({ expiresMs: nowMs + 10 * dayMs, unsubscribedMs: nowMs - dayMs }) }),
      status: "canceled",
      access: "active",
      plan: "monthly",
    },
    { type: "UNCANCELLATION", item: (nowMs) => ({ [monthly]: subscription({ expiresMs: nowMs + 10 * dayMs }) }), status: "active", access: "active", plan: "monthly" },
    {
      type: "BILLING_ISSUE",
      item: (nowMs) => ({ [monthly]: subscription({ expiresMs: nowMs - dayMs, billingIssueMs: nowMs - dayMs, graceMs: nowMs + 5 * dayMs }) }),
      status: "billing_issue",
      access: "grace",
      plan: "monthly",
    },
    { type: "EXPIRATION", item: (nowMs) => ({ [monthly]: subscription({ expiresMs: nowMs - 2 * dayMs }) }), status: "expired", access: "none", plan: "monthly" },
    {
      type: "PRODUCT_CHANGE",
      item: (nowMs) => ({
        [monthly]: subscription({ expiresMs: nowMs - dayMs }),
        [yearly]: subscription({ expiresMs: nowMs + 365 * dayMs, purchasedMs: nowMs - dayMs }),
      }),
      status: "active",
      access: "active",
      plan: "yearly",
    },
    {
      type: "CANCELLATION",
      item: (nowMs) => ({ [monthly]: subscription({ expiresMs: nowMs + 20 * dayMs, refundedMs: nowMs - 3_600_000 }) }),
      status: "refunded",
      access: "none",
      plan: "monthly",
    },
    { type: "SUBSCRIPTION_EXTENDED", item: (nowMs) => ({ [yearly]: subscription({ expiresMs: nowMs + 40 * dayMs }) }), status: "active", access: "active", plan: "yearly" },
  ];
  for (const testCase of cases) {
    it(`${testCase.type} → ${testCase.status} (${testCase.access})`, async () => {
      const harness: Harness = await defaultHarness();
      const fake: FakeRevenueCat = stubRevenueCat(harness);
      const session: Session = await signIn(harness);
      fake.subscribers.set(session.userId, testCase.item(harness.clock.nowMs));
      expect((await postWebhook(harness, webhookEvent(testCase.type, session.userId), webhookAuth, null)).status).toBe(200);
      expect((await appStoreRow(session.userId))?.status).toBe(testCase.status);
      const body: MeBody = await me(harness, session);
      expect(body.appStoreSubscription?.access).toBe(testCase.access);
      expect(body.appStoreSubscription?.plan).toBe(testCase.plan);
      expect(body.plan).toBe(testCase.access === "none" ? "trial" : "subscription");
      expect(body.subscription?.source).toBe("app_store");
    });
  }

  it("TRANSFER: satın alma eski hesaptan düşer, yeni hesaba geçer", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const from: Session = await signIn(harness);
    const to: Session = await signIn(harness);
    const item: FakeSubscription = subscription({ expiresMs: harness.clock.nowMs + 20 * dayMs });
    await subscribeViaAppStore(harness, fake, from, item, monthly);
    expect((await me(harness, from)).plan).toBe("subscription");

    fake.subscribers.set(from.userId, {});
    fake.subscribers.set(to.userId, { [monthly]: item });
    const transfer: WebhookEvent = { id: randomId(), type: "TRANSFER", environment: "PRODUCTION", transferred_from: [from.userId], transferred_to: [to.userId] };
    const response: Response = await postWebhook(harness, transfer, webhookAuth, null);
    expect(await response.json<WebhookBody>()).toEqual({ received: true, outcome: "synced", users: 2 });
    expect(await appStoreRow(from.userId)).toBeNull();
    expect((await appStoreRow(to.userId))?.status).toBe("active");
    expect((await me(harness, from)).plan).toBe("trial");
    expect((await me(harness, to)).subscriptionSources).toEqual(["app_store"]);
  });

  it("aktarımdan önce başlamış eski okuma, aktarımla silinen satırı yeniden yaratmaz; daha yeni okuma yazar", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const from: Session = await signIn(harness);
    const item: FakeSubscription = subscription({ expiresMs: harness.clock.nowMs + 20 * dayMs });
    await subscribeViaAppStore(harness, fake, from, item, monthly);
    const staleReadMs: number = harness.clock.nowMs + 1_000;
    const active: AppStoreSubscription = {
      store: "app_store",
      productId: monthly,
      plan: "monthly",
      tier: "personal",
      status: "active",
      periodType: "normal",
      purchasedAt: item.purchasedMs,
      expiresAt: item.expiresMs,
      graceExpiresAt: null,
      environment: "PRODUCTION",
    };
    // Aktarım: daha yeni okuma aboneliği bulamaz, satır silinir.
    harness.clock.nowMs += 5_000;
    fake.subscribers.set(from.userId, {});
    const transfer: WebhookEvent = { id: randomId(), type: "TRANSFER", environment: "PRODUCTION", transferred_from: [from.userId], transferred_to: [] };
    expect((await postWebhook(harness, transfer, webhookAuth, null)).status).toBe(200);
    expect(await appStoreRow(from.userId)).toBeNull();
    // Aktarımdan önce yanıtlanmış (eski) okuma şimdi yazılmaya çalışır: satır geri gelmez, hesap abone olmaz.
    await env.DB.batch(appStoreSyncStatements(env.DB, from.userId, active, null, staleReadMs, harness.clock.nowMs));
    expect(await appStoreRow(from.userId)).toBeNull();
    expect((await me(harness, from)).plan).toBe("trial");
    // Aktarımdan sonraki okuma (ör. satın alma geri aktarıldı) yine yazar.
    await env.DB.batch(appStoreSyncStatements(env.DB, from.userId, active, null, harness.clock.nowMs + 1_000, harness.clock.nowMs));
    expect((await appStoreRow(from.userId))?.status).toBe("active");
  });

  it("bilinmeyen kullanıcı: 200, RevenueCat çağrılmaz, Sorunlar'a sayılır", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const day: string = new Date(harness.clock.nowMs).toISOString().slice(0, 10);
    const before = await env.DB.prepare("SELECT COALESCE(SUM(count), 0) AS count FROM ops_events WHERE day = ? AND kind = 'provider_error' AND detail = 'revenuecat_unknown_user'")
      .bind(day)
      .first<{ count: number }>();
    const response: Response = await postWebhook(harness, webhookEvent("RENEWAL", randomId()), webhookAuth, null);
    expect(await response.json<WebhookBody>()).toEqual({ received: true, outcome: "unknown_user", users: 0 });
    expect(fake.calls).toEqual([]);
    const after = await env.DB.prepare("SELECT COALESCE(SUM(count), 0) AS count FROM ops_events WHERE day = ? AND kind = 'provider_error' AND detail = 'revenuecat_unknown_user'")
      .bind(day)
      .first<{ count: number }>();
    expect((after?.count ?? 0) - (before?.count ?? 0)).toBe(1);
  });

  it("RevenueCat okunamazsa 502 ve olay yazılmaz; yeniden teslimde işlenir", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const session: Session = await signIn(harness);
    fake.subscribers.set(session.userId, { [monthly]: subscription({ expiresMs: harness.clock.nowMs + 30 * dayMs }) });
    fake.failures = 3;
    const event: WebhookEvent = webhookEvent("INITIAL_PURCHASE", session.userId);
    await expectError(await postWebhook(harness, event, webhookAuth, null), 502, "upstream_unavailable");
    expect(fake.calls).toHaveLength(3);
    expect(await appStoreRow(session.userId)).toBeNull();
    const retried: Response = await postWebhook(harness, event, webhookAuth, null);
    expect(await retried.json<WebhookBody>()).toEqual({ received: true, outcome: "synced", users: 1 });
  });

  it("sandbox kapalıyken sandbox olayı yok sayılır ve sandbox kaydı erişim vermez; açıkken verir", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const session: Session = await signIn(harness);
    const noSandbox: Env = envWith({ REVENUECAT_ACCEPT_SANDBOX: "false" });
    fake.subscribers.set(session.userId, { [monthly]: subscription({ expiresMs: harness.clock.nowMs + dayMs, sandbox: true }) });

    const ignored: Response = await postWebhook(harness, { ...webhookEvent("INITIAL_PURCHASE", session.userId), environment: "SANDBOX" }, webhookAuth, noSandbox);
    expect(await ignored.json<WebhookBody>()).toEqual({ received: true, outcome: "sandbox_ignored", users: 0 });
    expect(fake.calls).toEqual([]);
    // Olay üretim dese de REST kaydı sandbox ise eşitleme onu atar.
    expect((await postWebhook(harness, webhookEvent("RENEWAL", session.userId), webhookAuth, noSandbox)).status).toBe(200);
    expect(await appStoreRow(session.userId)).toBeNull();

    // Açıkken (geliştirme ve üretim varsayılanı: App Review ve TestFlight sandbox'tır) erişim verir.
    expect((await postWebhook(harness, { ...webhookEvent("INITIAL_PURCHASE", session.userId), environment: "SANDBOX" }, webhookAuth, null)).status).toBe(200);
    expect((await appStoreRow(session.userId))?.environment).toBe("SANDBOX");
    expect((await me(harness, session)).plan).toBe("subscription");
    // Sonradan kapatılırsa var olan sandbox satırı da erişim vermez.
    const closed: Response = await harness.call(req("GET", "/v1/me", { token: session.accessToken, env: noSandbox }));
    expect((await closed.json<MeBody>()).plan).toBe("trial");
  });
});

describe("hak birleştirme (Stripe + App Store)", () => {
  it("yalnızca Stripe, ikisi birden ve bitmiş App Store + süren Stripe", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const stripeOnly: Session = await signIn(harness);
    await grantSubscription(stripeOnly.userId, "active", harness.clock.nowMs + 20 * dayMs);
    const stripeBody: MeBody = await me(harness, stripeOnly);
    expect(stripeBody.subscriptionSources).toEqual(["stripe"]);
    expect(stripeBody.subscription?.source).toBe("stripe");
    expect(stripeBody.appStoreSubscription).toBeNull();

    const both: Session = await signIn(harness);
    await grantSubscription(both.userId, "active", harness.clock.nowMs + 20 * dayMs);
    await subscribeViaAppStore(harness, fake, both, subscription({ expiresMs: harness.clock.nowMs + 300 * dayMs }), yearly);
    const bothBody: MeBody = await me(harness, both);
    expect(bothBody.subscriptionSources).toEqual(["stripe", "app_store"]);
    expect(bothBody.subscription?.source).toBe("stripe");
    expect(bothBody.appStoreSubscription?.plan).toBe("yearly");

    const expiredAppStore: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, expiredAppStore, subscription({ expiresMs: harness.clock.nowMs - 5 * dayMs }), monthly);
    const expiredBody: MeBody = await me(harness, expiredAppStore);
    expect(expiredBody.plan).toBe("trial");
    expect(expiredBody.subscriptionSources).toEqual([]);
    // Eski Mac sürümleri bitmiş aboneliği "sona erdi" okur.
    expect(expiredBody.subscription).toMatchObject({ source: "app_store", status: "expired", access: "none" });
  });

  it("App Store abonesine Checkout açılmaz; portal Apple'ın abonelik sayfasıdır", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const session: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, session, subscription({ expiresMs: harness.clock.nowMs + 20 * dayMs }), monthly);
    await expectError(
      await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "monthly" } })),
      409,
      "app_store_subscription",
    );
    const portal: Response = await harness.call(req("POST", "/v1/billing/portal", { token: session.accessToken }));
    expect(portal.status).toBe(200);
    expect(await portal.json<{ url: string }>()).toEqual({ url: "https://apps.apple.com/account/subscriptions" });
  });

  it("portal: Stripe'ta yaşayan (erişimsiz) abonelik App Store satırına rağmen Stripe Portal'ına gider; bitmişse Apple sayfası", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const portalUrl = async (session: Session): Promise<string> => {
      const response: Response = await harness.call(req("POST", "/v1/billing/portal", { token: session.accessToken }));
      expect(response.status).toBe(200);
      return (await response.json<{ url: string }>()).url;
    };
    const expiredAppStore = { status: "expired", periodType: "normal", environment: "PRODUCTION", expiresAtMs: harness.clock.nowMs - 5 * dayMs } as const;
    // Ek süresi geçmiş `past_due` ve ödemesi tamamlanmamış abonelik Stripe'ta yaşar: kart Portal'da düzeltilir.
    for (const status of ["past_due", "incomplete"]) {
      const session: Session = await signIn(harness);
      await grantSubscription(session.userId, status, harness.clock.nowMs - 30 * dayMs);
      await grantAppStoreSubscription(session.userId, expiredAppStore);
      expect(await portalUrl(session)).toMatch(/^https:\/\/billing\.stripe\.com\//);
    }
    expect(stripe.portalForms).toHaveLength(2);
    // Bitmiş Stripe aboneliğinde Apple'ın sayfası döner, Stripe çağrılmaz.
    const canceled: Session = await signIn(harness);
    await grantSubscription(canceled.userId, "canceled", harness.clock.nowMs - 30 * dayMs);
    await grantAppStoreSubscription(canceled.userId, expiredAppStore);
    expect(await portalUrl(canceled)).toBe("https://apps.apple.com/account/subscriptions");
    expect(stripe.portalForms).toHaveLength(2);
  });

  it("davet: App Store abonesi kod alır ve kodu geçerlidir; özet ödülün Apple faturasına uygulanmadığını bildirir", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const appStoreOnly: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, appStoreOnly, subscription({ expiresMs: harness.clock.nowMs + 20 * dayMs }), monthly);
    const summary: Response = await harness.call(req("GET", "/v1/referral", { token: appStoreOnly.accessToken }));
    expect(summary.status).toBe(200);
    const body = await summary.json<{ code: string | null; inviteUrl: string | null; appStoreBilled: boolean; complimentary: boolean }>();
    expect(body.code).toMatch(/^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{8}$/);
    expect(body.inviteUrl).toContain(`/invite?code=${body.code ?? ""}`);
    expect(body.appStoreBilled).toBe(true);
    expect(body.complimentary).toBe(false);
    // Hiç abone olmamış arkadaş bu kodu web'de kullanabilir.
    const friend: Session = await signIn(harness);
    const validated: Response = await harness.call(req("POST", "/v1/referral/validate", { token: friend.accessToken, json: { code: body.code } }));
    expect(validated.status).toBe(200);

    // Stripe aboneliği asıl kaynaksa ödül Stripe alacağıdır.
    const stripeOnly: Session = await signIn(harness);
    await grantSubscription(stripeOnly.userId, "active", harness.clock.nowMs + 20 * dayMs);
    const stripeBody = await (await harness.call(req("GET", "/v1/referral", { token: stripeOnly.accessToken }))).json<{ code: string | null; appStoreBilled: boolean }>();
    expect(stripeBody.code).not.toBeNull();
    expect(stripeBody.appStoreBilled).toBe(false);

    // Bitmiş App Store aboneliği kod vermez.
    const expired: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, expired, subscription({ expiresMs: harness.clock.nowMs - 5 * dayMs }), monthly);
    const expiredBody = await (await harness.call(req("GET", "/v1/referral", { token: expired.accessToken }))).json<{ code: string | null }>();
    expect(expiredBody.code).toBeNull();
  });

  it("POST /v1/billing/app-store/sync: anahtar yoksa 503, varsa eşitleyip hak durumunu döndürür", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const session: Session = await signIn(harness);
    fake.subscribers.set(session.userId, { [monthly]: subscription({ expiresMs: harness.clock.nowMs + 30 * dayMs }) });
    await expectError(
      await harness.call(req("POST", "/v1/billing/app-store/sync", { token: session.accessToken, env: envWithoutRevenueCatKey() })),
      503,
      "app_store_unavailable",
    );
    const synced: Response = await harness.call(req("POST", "/v1/billing/app-store/sync", { token: session.accessToken }));
    expect(synced.status).toBe(200);
    const body: MeBody = await synced.json<MeBody>();
    expect(body.plan).toBe("subscription");
    expect(body.subscriptionSources).toEqual(["app_store"]);
    expect((await appStoreRow(session.userId))?.last_event_id).toBeNull();
  });
});

describe("hesap silme", () => {
  it("App Store aboneliği sürüyorsa silinir ve iptal uyarısı döner; yoksa uyarı yok", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const subscriber: Session = await signIn(harness);
    const expiresMs: number = harness.clock.nowMs + 12 * dayMs;
    await subscribeViaAppStore(harness, fake, subscriber, subscription({ expiresMs }), monthly);
    const deleted: Response = await harness.call(req("DELETE", "/v1/me", { token: subscriber.accessToken }));
    expect(deleted.status).toBe(200);
    const body = await deleted.json<{ deleted: boolean; appStoreSubscription: object | null; notice: string | null }>();
    expect(body.deleted).toBe(true);
    expect(body.appStoreSubscription).toEqual({ willRenew: true, expiresAt: new Date(expiresMs).toISOString(), manageUrl: "https://apps.apple.com/account/subscriptions" });
    expect(body.notice).toContain("Subscriptions");
    expect(await appStoreRow(subscriber.userId)).toBeNull();
    // Silinen hesabın sonraki yenilemesi bilinmeyen kullanıcıdır.
    const renewal: Response = await postWebhook(harness, webhookEvent("RENEWAL", subscriber.userId), webhookAuth, null);
    expect((await renewal.json<WebhookBody>()).outcome).toBe("unknown_user");

    const plain: Session = await signIn(harness);
    const plainDeleted: Response = await harness.call(req("DELETE", "/v1/me", { token: plain.accessToken }));
    expect(await plainDeleted.json()).toEqual({ deleted: true, appStoreSubscription: null, notice: null });
  });
});

interface SourceStats {
  readonly active: number;
  readonly grace: number;
  readonly ending: number;
  readonly monthly: number;
  readonly yearly: number;
  readonly mrrUsd: number;
}

interface StatsBody {
  readonly subscriptions: {
    readonly active: number;
    readonly monthly: number;
    readonly yearly: number;
    readonly mrrUsd: number;
    readonly bySource: { readonly stripe: SourceStats; readonly appStore: SourceStats & { grossMrrUsd: number; commissionRate: number; trial: number; sandbox: number } };
  };
}

describe("yönetici istatistiği: kaynağa göre abonelik ve MRR", () => {
  it("App Store MRR'ı Apple komisyonu düşülerek sayılır; sandbox ve deneme dönemi gelire girmez", async () => {
    const harness: Harness = await defaultHarness();
    const fake: FakeRevenueCat = stubRevenueCat(harness);
    const admin: Session = await signInWithGoogle(harness, adminSubject);
    const stats = async (): Promise<StatsBody> => {
      const response: Response = await harness.call(req("GET", "/v1/admin/stats", { token: admin.accessToken, env: adminEnv }));
      expect(response.status).toBe(200);
      return response.json<StatsBody>();
    };
    const before: StatsBody = await stats();

    const stripeUser: Session = await signIn(harness);
    await grantSubscription(stripeUser.userId, "active", harness.clock.nowMs + 20 * dayMs);
    const monthlyUser: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, monthlyUser, subscription({ expiresMs: harness.clock.nowMs + 20 * dayMs }), monthly);
    const yearlyUser: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, yearlyUser, subscription({ expiresMs: harness.clock.nowMs + 200 * dayMs }), yearly);
    const trialUser: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, trialUser, subscription({ expiresMs: harness.clock.nowMs + 3 * dayMs, periodType: "trial" }), monthly);
    const sandboxUser: Session = await signIn(harness);
    await subscribeViaAppStore(harness, fake, sandboxUser, subscription({ expiresMs: harness.clock.nowMs + dayMs, sandbox: true }), monthly);

    const after: StatsBody = await stats();
    const appStore = after.subscriptions.bySource.appStore;
    const appStoreBefore = before.subscriptions.bySource.appStore;
    expect(appStore.active - appStoreBefore.active).toBe(3);
    expect(appStore.monthly - appStoreBefore.monthly).toBe(1);
    expect(appStore.yearly - appStoreBefore.yearly).toBe(1);
    expect(appStore.trial - appStoreBefore.trial).toBe(1);
    expect(appStore.sandbox - appStoreBefore.sandbox).toBe(1);
    expect(appStore.commissionRate).toBe(0.15);
    const grossDelta: number = 5.99 + 49 / 12;
    expect(appStore.grossMrrUsd - appStoreBefore.grossMrrUsd).toBeCloseTo(grossDelta, 1);
    expect(appStore.mrrUsd - appStoreBefore.mrrUsd).toBeCloseTo(grossDelta * 0.85, 1);
    expect(after.subscriptions.bySource.stripe.monthly - before.subscriptions.bySource.stripe.monthly).toBe(1);
    expect(after.subscriptions.active - before.subscriptions.active).toBe(4);
    expect(after.subscriptions.mrrUsd).toBeCloseTo(after.subscriptions.bySource.stripe.mrrUsd + appStore.mrrUsd, 1);
  });
});
