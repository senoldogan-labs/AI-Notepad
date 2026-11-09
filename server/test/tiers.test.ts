import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { countsByTier, tieredMrrUsd } from "../src/admin";
import { appStoreSubscriptionFromRevenueCat } from "../src/appStore";
import { referralCouponSpec } from "../src/billing";
import { parseConfig } from "../src/config";
import { randomToken } from "../src/crypto";
import { offeredTiers, strongerTier } from "../src/tiers";
import { type Harness, type Session, type StartedMeetingBody, defaultHarness, envWith, expectError, grantAppStoreSubscription, req, signIn } from "./helpers";
import { sendSubscription } from "./stripeEvents";
import { type FakeStripe, fakeSubscription, fakeSubscriptionWithPrice, stubStripeApi } from "./stripeFake";

const dayMs: number = 86_400_000;
const proOff = envWith({ PRO_TIER_POLICY: "off" });

/** The part of `GET /v1/me` this file checks. */
interface MeBody {
  readonly plan: string;
  readonly tier: string | null;
  readonly monthlyHoursCap: number;
  readonly meetingMaxMinutes: number;
  readonly accountTokensCap: number;
  readonly offeredTiers: ReadonlyArray<{ tier: string; monthlyHours: number; meetingMaxMinutes: number }>;
  readonly subscription: { tier: string; plan: string | null; source: string } | null;
  readonly appStoreSubscription: { tier: string; plan: string | null } | null;
}

async function me(harness: Harness, session: Session): Promise<MeBody> {
  return (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
}

/** A Stripe subscription row of the given tier and plan (shortcut outside the webhook tests). */
async function grantStripe(userId: string, tier: "personal" | "pro", plan: "monthly" | "yearly", periodEndMs: number): Promise<string> {
  const customer: string = `cus_${randomToken(8)}`;
  const subscriptionId: string = `sub_${randomToken(8)}`;
  await env.DB.batch([
    env.DB.prepare("INSERT INTO stripe_customers (user_id, stripe_customer_id, created_at) VALUES (?, ?, 0)").bind(userId, customer),
    env.DB.prepare(
      `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at, plan, tier)
       VALUES (?, ?, ?, 'active', ?, 0, 0, ?, ?)`,
    ).bind(userId, customer, subscriptionId, periodEndMs, plan, tier),
  ]);
  return subscriptionId;
}

describe("tiers: pure functions", () => {
  it("offers Pro only while PRO_TIER_POLICY is on, with the configured limits", () => {
    expect(offeredTiers(parseConfig(env))).toEqual([
      { tier: "personal", monthlyHours: 10, meetingMaxMinutes: 240 },
      { tier: "pro", monthlyHours: 30, meetingMaxMinutes: 240 },
    ]);
    expect(offeredTiers(parseConfig(envWith({ PRO_TIER_POLICY: "off" })))).toEqual([{ tier: "personal", monthlyHours: 10, meetingMaxMinutes: 240 }]);
    expect(offeredTiers(parseConfig(envWith({ PRO_MONTHLY_CAP_HOURS: "25", PRO_MAX_MEETING_MINUTES: "180" })))[1]).toEqual({
      tier: "pro",
      monthlyHours: 25,
      meetingMaxMinutes: 180,
    });
  });

  it("refuses a configuration whose Pro ids repeat Personal's or whose Pro account cap exceeds the monthly cap", () => {
    expect(() => parseConfig(envWith({ STRIPE_PRO_PRICE_ID: env.STRIPE_PRICE_ID }))).toThrow(/STRIPE_PRO_PRICE_ID/);
    expect(() => parseConfig(envWith({ APP_STORE_PRODUCT_PRO_YEARLY: env.APP_STORE_PRODUCT_YEARLY }))).toThrow(/APP_STORE_PRODUCT_PRO_YEARLY/);
    expect(() => parseConfig(envWith({ PRO_MONTHLY_ACCOUNT_TOKEN_CAP: "99999999" }))).toThrow(/PRO_MONTHLY_ACCOUNT_TOKEN_CAP/);
  });

  it("picks the higher tier and prices MRR per tier", () => {
    expect(strongerTier("personal", "pro")).toBe("pro");
    expect(strongerTier(null, "personal")).toBe("personal");
    expect(strongerTier(null, null)).toBeNull();
    const counts = { monthly: 3, yearly: 2, proMonthly: 1, proYearly: 1 };
    expect(countsByTier(counts)).toEqual({ personal: { monthly: 2, yearly: 1 }, pro: { monthly: 1, yearly: 1 } });
    // Each tier to the cent: 2 × 5.99 + 49 / 12 = 16.06; 12.99 + 109 / 12 = 22.07.
    expect(tieredMrrUsd(counts, { personal: { monthly: 5.99, yearly: 49 }, pro: { monthly: 12.99, yearly: 109 } })).toBe(38.13);
  });

  it("gives Pro invitees one Personal month off, never a free Pro month", () => {
    expect(referralCouponSpec("personal", "monthly", 599).percentOff).toBe(100);
    for (const plan of ["monthly", "yearly"] as const) {
      expect(referralCouponSpec("pro", plan, 599)).toEqual(referralCouponSpec("personal", "yearly", 599));
    }
  });

  it("reads the App Store tier from the product id", () => {
    const config = parseConfig(env);
    const subscriber = {
      request_date_ms: Date.UTC(2026, 9, 15),
      subscriber: {
        subscriptions: {
          [env.APP_STORE_PRODUCT_PRO_YEARLY]: {
            expires_date: "2027-10-15T00:00:00Z",
            purchase_date: "2026-10-15T00:00:00Z",
            period_type: "normal",
            store: "app_store",
            is_sandbox: false,
          },
        },
      },
    };
    expect(appStoreSubscriptionFromRevenueCat(subscriber, config.appStore.products, false)).toMatchObject({ plan: "yearly", tier: "pro" });
  });

  it("after a Personal yearly → Pro monthly upgrade, the active Pro record wins over the later-ending Personal one", () => {
    const config = parseConfig(env);
    const record = (expires: string, purchased: string) => ({ expires_date: expires, purchase_date: purchased, period_type: "normal", store: "app_store", is_sandbox: false });
    const subscriber = {
      request_date_ms: Date.UTC(2026, 9, 20),
      subscriber: {
        subscriptions: {
          // RevenueCat may still show the replaced Personal product with its old end date.
          [env.APP_STORE_PRODUCT_YEARLY]: record("2027-10-01T00:00:00Z", "2026-10-01T00:00:00Z"),
          [env.APP_STORE_PRODUCT_PRO_MONTHLY]: record("2026-11-15T00:00:00Z", "2026-10-15T00:00:00Z"),
        },
      },
    };
    expect(appStoreSubscriptionFromRevenueCat(subscriber, config.appStore.products, false)).toMatchObject({ plan: "monthly", tier: "pro" });
    // Once Pro has lapsed, the Personal record that still gives access is the subscription again.
    const lapsed = { ...subscriber, request_date_ms: Date.UTC(2026, 10, 20) };
    expect(appStoreSubscriptionFromRevenueCat(lapsed, config.appStore.products, false)).toMatchObject({ plan: "yearly", tier: "personal" });
  });
});

describe("tiers: entitlements and limits", () => {
  it("a Stripe Pro subscriber gets Pro limits; Personal and trial keep Personal's", async () => {
    const harness: Harness = await defaultHarness();
    const trial: Session = await signIn(harness);
    const trialMe: MeBody = await me(harness, trial);
    expect(trialMe.tier).toBeNull();
    expect(trialMe.monthlyHoursCap).toBe(10);
    expect(trialMe.offeredTiers.map((offer) => offer.tier)).toEqual(["personal", "pro"]);

    const personal: Session = await signIn(harness);
    await grantStripe(personal.userId, "personal", "monthly", harness.clock.nowMs + 20 * dayMs);
    expect(await me(harness, personal)).toMatchObject({ tier: "personal", monthlyHoursCap: 10, accountTokensCap: 1_500_000, subscription: { tier: "personal" } });

    const pro: Session = await signIn(harness);
    await grantStripe(pro.userId, "pro", "yearly", harness.clock.nowMs + 200 * dayMs);
    expect(await me(harness, pro)).toMatchObject({
      tier: "pro",
      monthlyHoursCap: 30,
      meetingMaxMinutes: 240,
      accountTokensCap: 3_000_000,
      subscription: { tier: "pro", plan: "yearly", source: "stripe" },
    });
    // While Pro is off sale it is not offered, but the Pro subscriber keeps Pro limits.
    const hidden: MeBody = await (await harness.call(req("GET", "/v1/me", { token: pro.accessToken, env: proOff }))).json<MeBody>();
    expect(hidden.offeredTiers.map((offer) => offer.tier)).toEqual(["personal"]);
    expect(hidden).toMatchObject({ tier: "pro", monthlyHoursCap: 30 });
  });

  it("an App Store Pro subscription gives Pro; the higher tier wins across sources", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantAppStoreSubscription(session.userId, { status: "active", periodType: "normal", environment: "PRODUCTION", expiresAtMs: harness.clock.nowMs + 20 * dayMs });
    expect(await me(harness, session)).toMatchObject({ tier: "personal", appStoreSubscription: { tier: "personal" } });
    await env.DB.prepare("UPDATE app_store_subscriptions SET product_id = ?, tier = 'pro' WHERE user_id = ?").bind(env.APP_STORE_PRODUCT_PRO_MONTHLY, session.userId).run();
    expect(await me(harness, session)).toMatchObject({ tier: "pro", monthlyHoursCap: 30, appStoreSubscription: { tier: "pro" } });
    await grantStripe(session.userId, "personal", "monthly", harness.clock.nowMs + 20 * dayMs);
    expect(await me(harness, session)).toMatchObject({ tier: "pro", subscription: { source: "stripe", tier: "personal" } });
  });

  it("a Pro meeting gets the Pro budget and the Pro month's remainder", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantStripe(session.userId, "pro", "monthly", harness.clock.nowMs + 20 * dayMs);
    const tuned = envWith({ PRO_MEETING_TOKEN_BUDGET: "2700000", PRO_MONTHLY_CAP_HOURS: "0.5" });
    const response: Response = await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: tuned }));
    expect(response.status).toBe(201);
    const started: StartedMeetingBody = await response.json<StartedMeetingBody>();
    expect(started).toMatchObject({ kind: "subscription", tokenBudget: 2_700_000, maxDurationMinutes: 30 });
  });
});

describe("tiers: reprocessing", () => {
  it("tops a reprocessed meeting up from the account's own tier budget", async () => {
    const harness: Harness = await defaultHarness();
    // Pro's meeting budget is larger here, so taking Pro's share would show.
    const tuned = envWith({ PRO_MEETING_TOKEN_BUDGET: "4000000" });
    const reprocessed = async (tier: "personal" | "pro"): Promise<number> => {
      const session: Session = await signIn(harness);
      await grantStripe(session.userId, tier, "monthly", harness.clock.nowMs + 20 * dayMs);
      const started: StartedMeetingBody = await (
        await harness.call(req("POST", "/v1/meetings/start", { token: session.accessToken, json: {}, env: tuned }))
      ).json<StartedMeetingBody>();
      await harness.call(req("POST", `/v1/meetings/${started.meetingId}/end`, { token: session.accessToken, env: tuned }));
      await env.DB.prepare("UPDATE meeting_sessions SET audio_seconds = 600, tokens_used = 1000 WHERE id = ?").bind(started.meetingId).run();
      const response: Response = await harness.call(req("POST", `/v1/meetings/${started.meetingId}/reprocess`, { token: session.accessToken, env: tuned }));
      expect(response.status).toBe(200);
      const row = await env.DB.prepare("SELECT token_budget FROM meeting_sessions WHERE id = ?").bind(started.meetingId).first<{ token_budget: number }>();
      return (row?.token_budget ?? 0) - 1000;
    };
    // 15 % note reserve of each tier's budget.
    expect(await reprocessed("personal")).toBe(Math.floor(2_600_000 * 0.15));
    expect(await reprocessed("pro")).toBe(Math.floor(4_000_000 * 0.15));
  });
});

describe("tiers: billing", () => {
  it("GET /v1/pricing lists the tiers on sale without a session", async () => {
    const harness: Harness = await defaultHarness();
    const on: Response = await harness.call(req("GET", "/v1/pricing", { headers: { origin: "http://localhost:8788" } }));
    expect(on.status).toBe(200);
    expect(on.headers.get("access-control-allow-origin")).toBe("http://localhost:8788");
    expect(((await on.json()) as { tiers: Array<{ tier: string }> }).tiers.map((offer) => offer.tier)).toEqual(["personal", "pro"]);
    const off: Response = await harness.call(req("GET", "/v1/pricing", { env: proOff }));
    expect(((await off.json()) as { tiers: Array<{ tier: string }> }).tiers.map((offer) => offer.tier)).toEqual(["personal"]);
  });

  it("Pro checkout uses the Pro price; it is refused while Pro is off sale", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await expectError(
      await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "monthly", tier: "pro" }, env: proOff })),
      503,
      "pro_unavailable",
    );
    expect(stripe.checkoutForms).toHaveLength(0);
    const response: Response = await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "yearly", tier: "pro" } }));
    expect(response.status).toBe(200);
    expect(stripe.checkoutForms[0]?.get("line_items[0][price]")).toBe(env.STRIPE_PRO_YEARLY_PRICE_ID);
    // Without a tier the checkout stays Personal (older apps and site).
    await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "monthly" } }));
    expect(stripe.checkoutForms[1]?.get("line_items[0][price]")).toBe(env.STRIPE_PRICE_ID);
  });

  it("the webhook writes the tier from the subscription's price, and a portal switch updates it", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const session: Session = await signIn(harness);
    await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "monthly" } }));
    const customer: string = stripe.checkoutForms[0]?.get("customer") ?? "";
    const now: number = Math.floor(harness.clock.nowMs / 1000);
    const id: string = `sub_${randomToken(6)}`;
    const personal = fakeSubscription(id, customer, "active", now - 10, now + 30 * 86_400);
    expect((await sendSubscription(harness, stripe, `evt_${randomToken(6)}`, "customer.subscription.created", now - 10, personal)).status).toBe(200);
    expect(await me(harness, session)).toMatchObject({ tier: "personal", monthlyHoursCap: 10, subscription: { tier: "personal", plan: "monthly" } });

    // Plan change: the portal confirm page for the subscription's single item, then Stripe's update event.
    const change: Response = await harness.call(req("POST", "/v1/billing/change-plan", { token: session.accessToken, json: { tier: "pro", plan: "monthly" } }));
    expect(change.status).toBe(200);
    const form: URLSearchParams | undefined = stripe.portalForms[0];
    expect(form?.get("flow_data[type]")).toBe("subscription_update_confirm");
    expect(form?.get("flow_data[subscription_update_confirm][subscription]")).toBe(id);
    expect(form?.get("flow_data[subscription_update_confirm][items][0][id]")).toBe(`si_${id}`);
    expect(form?.get("flow_data[subscription_update_confirm][items][0][price]")).toBe(env.STRIPE_PRO_PRICE_ID);

    const pro = fakeSubscriptionWithPrice(id, customer, "active", now - 10, now + 30 * 86_400, env.STRIPE_PRO_PRICE_ID);
    expect((await sendSubscription(harness, stripe, `evt_${randomToken(6)}`, "customer.subscription.updated", now, pro)).status).toBe(200);
    expect(await me(harness, session)).toMatchObject({ tier: "pro", monthlyHoursCap: 30, subscription: { tier: "pro", plan: "monthly" } });
    const row = await env.DB.prepare("SELECT tier, plan FROM subscriptions WHERE user_id = ?").bind(session.userId).first<{ tier: string; plan: string }>();
    expect(row).toEqual({ tier: "pro", plan: "monthly" });

    await expectError(
      await harness.call(req("POST", "/v1/billing/change-plan", { token: session.accessToken, json: { tier: "pro", plan: "monthly" } })),
      409,
      "plan_unchanged",
    );
    await expectError(
      await harness.call(req("POST", "/v1/billing/change-plan", { token: session.accessToken, json: { tier: "pro", plan: "yearly" }, env: proOff })),
      503,
      "pro_unavailable",
    );
  });

  it("change-plan needs a Stripe subscription; App Store subscribers change on iPhone", async () => {
    const harness: Harness = await defaultHarness();
    stubStripeApi(harness);
    const none: Session = await signIn(harness);
    await expectError(
      await harness.call(req("POST", "/v1/billing/change-plan", { token: none.accessToken, json: { tier: "pro", plan: "monthly" } })),
      402,
      "subscription_required",
    );
    const iPhone: Session = await signIn(harness);
    await grantAppStoreSubscription(iPhone.userId, { status: "active", periodType: "normal", environment: "PRODUCTION", expiresAtMs: harness.clock.nowMs + 20 * dayMs });
    await expectError(
      await harness.call(req("POST", "/v1/billing/change-plan", { token: iPhone.accessToken, json: { tier: "pro", plan: "monthly" } })),
      409,
      "app_store_subscription",
    );
  });
});
