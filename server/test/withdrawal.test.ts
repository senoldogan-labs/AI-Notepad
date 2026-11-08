import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { withdrawalRefundCents } from "../src/billing";
import { randomToken } from "../src/crypto";
import { type Harness, type Session, defaultHarness, expectError, req, signIn } from "./helpers";
import { sendSubscription } from "./stripeEvents";
import { type FakeStripe, fakeYearlySubscription, stubStripeApi } from "./stripeFake";

const dayMs: number = 86_400_000;

interface MeBody {
  readonly subscription: { withdrawableUntil: string | null; status: string } | null;
}

/** A yearly Stripe subscriber whose subscription started `ageDays` ago and paid 4900 cents. */
async function yearlySubscriber(harness: Harness, stripe: FakeStripe, ageDays: number): Promise<{ session: Session; subscriptionId: string }> {
  const session: Session = await signIn(harness);
  await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "yearly" } }));
  const customer: string = stripe.checkoutForms.at(-1)?.get("customer") ?? "";
  const now: number = Math.floor(harness.clock.nowMs / 1000);
  const created: number = now - ageDays * 86_400;
  const subscriptionId: string = `sub_${randomToken(6)}`;
  const invoiceId: string = `in_${randomToken(6)}`;
  const intent: string = `pi_${randomToken(6)}`;
  stripe.invoices.set(invoiceId, { subscription: subscriptionId, paid: true, amountPaid: 4900, created });
  stripe.invoicePayments.set(invoiceId, [intent]);
  const subscription = fakeYearlySubscription(subscriptionId, customer, "active", created, created + 365 * 86_400);
  expect((await sendSubscription(harness, stripe, `evt_${randomToken(6)}`, "customer.subscription.created", created, subscription)).status).toBe(200);
  return { session, subscriptionId };
}

describe("EU online withdrawal function", () => {
  it("refunds the unused share pro rata", () => {
    expect(withdrawalRefundCents(4900, 0, 365 * dayMs, 0)).toBe(4900);
    expect(withdrawalRefundCents(4900, 0, 365 * dayMs, 73 * dayMs)).toBe(3920);
    expect(withdrawalRefundCents(0, 0, 365 * dayMs, dayMs)).toBe(0);
    expect(withdrawalRefundCents(4900, 0, 365 * dayMs, 400 * dayMs)).toBe(0);
  });

  it("within 14 days: /v1/me offers it; withdrawing cancels at once and refunds the unused part", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId } = await yearlySubscriber(harness, stripe, 3);
    const me: MeBody = await (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
    expect(me.subscription?.withdrawableUntil).toBe(new Date(harness.clock.nowMs - 3 * dayMs + 14 * dayMs).toISOString().replace(/\.\d{3}Z$/, ".000Z"));

    const response: Response = await harness.call(req("POST", "/v1/billing/withdraw", { token: session.accessToken, headers: { origin: "http://localhost:8788" } }));
    expect(response.status).toBe(200);
    // 362 of 365 days unused: floor(4900 × 362 / 365) = 4859.
    expect(await response.json()).toEqual({ refundedCents: 4859, currency: "usd" });
    expect(stripe.refundForms.at(-1)?.get("amount")).toBe("4859");
    expect(stripe.refundForms.at(-1)?.get("metadata[purpose]")).toBe("withdrawal");
    expect(stripe.canceled).toContain(subscriptionId);
  });

  it("is refused after 14 days and without a Stripe subscription", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session } = await yearlySubscriber(harness, stripe, 20);
    const me: MeBody = await (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
    expect(me.subscription?.withdrawableUntil).toBeNull();
    await expectError(await harness.call(req("POST", "/v1/billing/withdraw", { token: session.accessToken })), 409, "withdrawal_unavailable");
    const none: Session = await signIn(harness);
    await expectError(await harness.call(req("POST", "/v1/billing/withdraw", { token: none.accessToken })), 409, "withdrawal_unavailable");
    const row = await env.DB.prepare("SELECT started_at FROM subscriptions WHERE user_id = ?").bind(session.userId).first<{ started_at: number }>();
    expect(row?.started_at).toBe((Math.floor(harness.clock.nowMs / 1000) - 20 * 86_400) * 1000);
  });
});
