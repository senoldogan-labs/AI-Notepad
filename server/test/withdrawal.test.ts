import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { type WithdrawalInvoice, retryPendingWithdrawals, withdrawalCashCents, withdrawalOwed } from "../src/billing";
import { parseConfig } from "../src/config";
import { randomToken } from "../src/crypto";
import { type Harness, type Session, defaultHarness, expectError, refreshed, req, signIn } from "./helpers";
import { sendSubscription } from "./stripeEvents";
import { type FakeInvoice, type FakeStripe, fakeYearlySubscription, stubStripeApi } from "./stripeFake";

const dayMs: number = 86_400_000;
const day: number = 86_400;
const year: number = 365 * day;

interface MeBody {
  readonly subscription: { withdrawableUntil: string | null; withdrawalPending: boolean; status: string } | null;
}

/** A paid invoice of the fake subscription with its payment (intent and charged amount). */
interface PaidInvoice {
  readonly invoice: Omit<FakeInvoice, "subscription">;
  /** Charged amount of the invoice's payment; 0: no payment (paid from the balance). */
  readonly charged: number;
}

interface Subscriber {
  readonly session: Session;
  readonly subscriptionId: string;
  readonly customer: string;
  /** Payment intents in the order of `invoices`; "" where the invoice had no payment. */
  readonly intents: readonly string[];
}

/** A yearly Stripe subscriber whose subscription started `ageDays` ago; `invoices` gets the start (seconds). */
async function subscriber(harness: Harness, stripe: FakeStripe, ageDays: number, invoices: (created: number) => readonly PaidInvoice[]): Promise<Subscriber> {
  const session: Session = await signIn(harness);
  await harness.call(req("POST", "/v1/billing/checkout", { token: session.accessToken, json: { plan: "yearly" } }));
  const customer: string = stripe.checkoutForms.at(-1)?.get("customer") ?? "";
  const created: number = Math.floor(harness.clock.nowMs / 1000) - ageDays * day;
  const subscriptionId: string = `sub_${randomToken(6)}`;
  const intents: string[] = invoices(created).map((paid: PaidInvoice): string => {
    const invoiceId: string = `in_${randomToken(6)}`;
    stripe.invoices.set(invoiceId, { ...paid.invoice, subscription: subscriptionId });
    if (paid.charged <= 0) {
      return "";
    }
    const intent: string = `pi_${randomToken(6)}`;
    stripe.invoicePayments.set(invoiceId, [intent]);
    stripe.chargeAmounts.set(intent, paid.charged);
    return intent;
  });
  const subscription = fakeYearlySubscription(subscriptionId, customer, "active", created, created + year);
  expect((await sendSubscription(harness, stripe, `evt_${randomToken(6)}`, "customer.subscription.created", created, subscription)).status).toBe(200);
  return { session, subscriptionId, customer, intents };
}

/** A yearly subscriber who paid 4900 cents for the year. */
function yearlySubscriber(harness: Harness, stripe: FakeStripe, ageDays: number): Promise<Subscriber> {
  return subscriber(harness, stripe, ageDays, (created: number): PaidInvoice[] => [
    { invoice: { paid: true, amountPaid: 4900, created, periodEnd: created + year }, charged: 4900 },
  ]);
}

async function me(harness: Harness, session: Session): Promise<MeBody> {
  return (await harness.call(req("GET", "/v1/me", { token: session.accessToken }))).json<MeBody>();
}

async function withdraw(harness: Harness, session: Session): Promise<Response> {
  return harness.call(req("POST", "/v1/billing/withdraw", { token: session.accessToken, headers: { origin: "http://localhost:8788" } }));
}

describe("withdrawal amounts", () => {
  const invoice = (total: number, paid: number, lines: ReadonlyArray<[number, number, number]>): WithdrawalInvoice => ({
    totalCents: total,
    subtotalCents: total,
    amountPaidCents: paid,
    lines: lines.map(([amountCents, start, end]: [number, number, number]) => ({ amountCents, startMs: start * dayMs, endMs: end * dayMs })),
  });

  it("refunds the unused share of a single payment", () => {
    expect(withdrawalOwed([invoice(4900, 4900, [[4900, 0, 365]])], 3 * dayMs)).toEqual({ unusedCents: 4859, balanceCents: 0 });
    expect(withdrawalOwed([invoice(4900, 4900, [[4900, 0, 365]])], 0)).toEqual({ unusedCents: 4900, balanceCents: 0 });
    expect(withdrawalOwed([invoice(4900, 4900, [[4900, 0, 365]])], 400 * dayMs)).toEqual({ unusedCents: 0, balanceCents: 0 });
  });

  it("after a Pro → Personal downgrade: the Personal time left plus the credit the downgrade left on the balance", () => {
    // Pro yearly paid on day 0; on day 2 the downgrade credits the unused Pro time and charges Personal for the rest
    // (a negative invoice: the difference went onto the balance).
    const owed = withdrawalOwed([invoice(10900, 10900, [[10900, 0, 365]]), invoice(-5967, 0, [[-10840, 2, 365], [4873, 2, 365]])], 3 * dayMs);
    expect(owed).toEqual({ unusedCents: 4859, balanceCents: 5967 });
    // Paid 10900; used 2 days of Pro (≈ 60) and 1 day of Personal (≈ 13): 10826 back once the credit is taken off.
    expect(withdrawalCashCents(owed, 5967)).toBe(10826);
    // Without taking the credit off (it is gone), only the unused value.
    expect(withdrawalCashCents(owed, 0)).toBe(4859);
  });

  it("after a Personal → Pro upgrade: the Pro time left", () => {
    const owed = withdrawalOwed([invoice(4900, 4900, [[4900, 0, 365]]), invoice(5967, 5967, [[-4873, 2, 365], [10840, 2, 365]])], 3 * dayMs);
    expect(owed).toEqual({ unusedCents: 10810, balanceCents: 0 });
    expect(withdrawalCashCents(owed, 0)).toBe(10810);
  });

  it("the part an invite credit paid isn't paid out in cash", () => {
    const owed = withdrawalOwed([invoice(4900, 3900, [[4900, 0, 365]])], 3 * dayMs);
    expect(owed).toEqual({ unusedCents: 4859, balanceCents: -1000 });
    expect(withdrawalCashCents(owed, 0)).toBe(3859);
  });

  it("a discount scales the lines down to what was charged", () => {
    const discounted: WithdrawalInvoice = { totalCents: 4410, subtotalCents: 4900, amountPaidCents: 4410, lines: [{ amountCents: 4900, startMs: 0, endMs: 365 * dayMs }] };
    expect(withdrawalOwed([discounted], 3 * dayMs).unusedCents).toBe(4373);
  });
});

describe("EU online withdrawal function", () => {
  it("within 14 days: /v1/me offers it; withdrawing cancels at once and refunds the unused part", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId } = await yearlySubscriber(harness, stripe, 3);
    const before: MeBody = await me(harness, session);
    expect(before.subscription?.withdrawableUntil).toBe(new Date(harness.clock.nowMs - 3 * dayMs + 14 * dayMs).toISOString().replace(/\.\d{3}Z$/, ".000Z"));
    expect(before.subscription?.withdrawalPending).toBe(false);

    const response: Response = await withdraw(harness, session);
    expect(response.status).toBe(200);
    // 362 of 365 days unused: floor(4900 × 362 / 365) = 4859.
    expect(await response.json()).toEqual({ refundedCents: 4859, currency: "usd", pending: false });
    expect(stripe.refundForms.at(-1)?.get("amount")).toBe("4859");
    expect(stripe.refundForms.at(-1)?.get("metadata[purpose]")).toBe("withdrawal");
    expect(stripe.canceled).toContain(subscriptionId);
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(false);
  });

  it("a retry after a failed cancellation resumes with the same refund, even after the clock moved", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId } = await yearlySubscriber(harness, stripe, 3);
    stripe.failCancels = true;
    const failed: Response = await withdraw(harness, session);
    expect(failed.status).toBeGreaterThanOrEqual(500);
    expect(stripe.refundForms).toHaveLength(0);
    // The request is stored: the site keeps offering it while the refund isn't confirmed.
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(true);
    // Two hours later (the unused share is smaller now), the retry uses the stored moment of the first request.
    stripe.failCancels = false;
    harness.clock.nowMs += 2 * 3_600_000;
    const later: Session = await refreshed(harness, session);
    const retried: Response = await withdraw(harness, later);
    expect(retried.status).toBe(200);
    expect(await retried.json()).toEqual({ refundedCents: 4859, currency: "usd", pending: false });
    expect(stripe.canceled).toContain(subscriptionId);
    // A third call (the subscription has ended) counts the earlier refund and makes none.
    const again: Response = await withdraw(harness, later);
    expect(await again.json()).toEqual({ refundedCents: 4859, currency: "usd", pending: false });
    expect(stripe.refundForms).toHaveLength(1);
  });

  it("a pending refund stays retryable; when it fails, the daily job refunds again under a fresh key", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session } = await yearlySubscriber(harness, stripe, 3);
    stripe.nextRefundStatus = "pending";
    const response: Response = await withdraw(harness, session);
    expect(await response.json()).toEqual({ refundedCents: 4859, currency: "usd", pending: true });
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(true);
    const config = parseConfig(env);
    // Still pending at Stripe: the job counts it and refunds nothing more.
    expect(await retryPendingWithdrawals(env.DB, harness.platform, config, 50)).toBe(1);
    expect(stripe.refundForms).toHaveLength(1);
    // The bank returns it: the refund fails; the next run refunds again and completes the withdrawal.
    stripe.refundForms[0]?.set("fake_status", "failed");
    stripe.nextRefundStatus = null;
    expect(await retryPendingWithdrawals(env.DB, harness.platform, config, 50)).toBe(1);
    expect(stripe.refundForms).toHaveLength(2);
    expect(stripe.refundForms[1]?.get("amount")).toBe("4859");
    expect(stripe.refundKeys[0]).toMatch(/-0$/);
    expect(stripe.refundKeys[1]).toMatch(/-1$/);
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(false);
    expect(await retryPendingWithdrawals(env.DB, harness.platform, config, 50)).toBe(0);
  });

  it("a refund Stripe rejects at once fails the request and stays pending for the daily job", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session } = await yearlySubscriber(harness, stripe, 3);
    stripe.nextRefundStatus = "failed";
    expect((await withdraw(harness, session)).status).toBeGreaterThanOrEqual(500);
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(true);
    stripe.nextRefundStatus = null;
    expect(await retryPendingWithdrawals(env.DB, harness.platform, parseConfig(env), 50)).toBe(1);
    expect(stripe.refundForms.map((form: URLSearchParams): string | null => form.get("fake_status"))).toEqual(["failed", "succeeded"]);
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(false);
  });

  it("ignores a support refund and a failed withdrawal refund when it refunds", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, intents } = await yearlySubscriber(harness, stripe, 3);
    const intent: string = intents[0] ?? "";
    // Support refunded $2 earlier (untagged), and an earlier withdrawal refund failed.
    stripe.refundForms.push(new URLSearchParams({ payment_intent: intent, amount: "200" }));
    stripe.refundForms.push(new URLSearchParams({ payment_intent: intent, amount: "4859", "metadata[purpose]": "withdrawal", fake_status: "failed" }));
    const response: Response = await withdraw(harness, session);
    expect(response.status).toBe(200);
    // Pro rata 4859, but only 4700 is still refundable on the payment; a fresh idempotency key (the failed refund had #0).
    expect(await response.json()).toEqual({ refundedCents: 4700, currency: "usd", pending: false });
    expect(stripe.refundForms.at(-1)?.get("amount")).toBe("4700");
    expect(stripe.refundKeys.at(-1)).toMatch(/-1$/);
  });

  it("after a downgrade: pays the balance credit out with the refund, never twice", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const sub: Subscriber = await subscriber(harness, stripe, 3, (created: number): PaidInvoice[] => [
      { invoice: { paid: true, amountPaid: 10900, created, lines: [{ amount: 10900, start: created, end: created + year }] }, charged: 10900 },
      {
        invoice: {
          paid: true,
          amountPaid: 0,
          total: -5967,
          created: created + 2 * day,
          lines: [
            { amount: -10840, start: created + 2 * day, end: created + year },
            { amount: 4873, start: created + 2 * day, end: created + year },
          ],
        },
        charged: 0,
      },
    ]);
    // The downgrade's credit sits on the balance, next to an invite reward of $5.99.
    stripe.customerBalances.set(sub.customer, -5967 - 599);
    const response: Response = await withdraw(harness, sub.session);
    expect(await response.json()).toEqual({ refundedCents: 10826, currency: "usd", pending: false });
    expect(stripe.refundForms.at(-1)?.get("amount")).toBe("10826");
    // Only the subscription's own credit is taken off; the invite reward stays.
    expect(stripe.balanceTransactions.map((transaction) => transaction.amount)).toEqual([5967]);
    // A retry finds the earlier balance transaction and the refund: nothing more.
    const again: Response = await withdraw(harness, sub.session);
    expect(await again.json()).toEqual({ refundedCents: 10826, currency: "usd", pending: false });
    expect(stripe.refundForms).toHaveLength(1);
    expect(stripe.balanceTransactions).toHaveLength(1);
  });

  it("after an upgrade: refunds the Pro time left, newest payment first", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const sub: Subscriber = await subscriber(harness, stripe, 3, (created: number): PaidInvoice[] => [
      { invoice: { paid: true, amountPaid: 4900, created, periodEnd: created + year }, charged: 4900 },
      {
        invoice: {
          paid: true,
          amountPaid: 5967,
          created: created + 2 * day,
          lines: [
            { amount: -4873, start: created + 2 * day, end: created + year },
            { amount: 10840, start: created + 2 * day, end: created + year },
          ],
        },
        charged: 5967,
      },
    ]);
    const response: Response = await withdraw(harness, sub.session);
    expect(await response.json()).toEqual({ refundedCents: 10810, currency: "usd", pending: false });
    expect(stripe.refundForms.map((form: URLSearchParams): [string | null, string | null] => [form.get("payment_intent"), form.get("amount")])).toEqual([
      [sub.intents[1] ?? "", "5967"],
      [sub.intents[0] ?? "", "4843"],
    ]);
    expect(stripe.balanceTransactions).toHaveLength(0);
  });

  it("a request left from an earlier subscription doesn't count", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session } = await yearlySubscriber(harness, stripe, 3);
    const started = await env.DB.prepare("SELECT started_at FROM subscriptions WHERE user_id = ?").bind(session.userId).first<{ started_at: number }>();
    await env.DB.prepare("UPDATE subscriptions SET withdrawal_requested_at = ? WHERE user_id = ?").bind((started?.started_at ?? 0) - dayMs, session.userId).run();
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(false);
    // The refund is computed at this request (3 days used), not at the stale moment before the start (nothing used).
    expect(await (await withdraw(harness, session)).json()).toEqual({ refundedCents: 4859, currency: "usd", pending: false });
  });

  it("is refused after 14 days and without a Stripe subscription", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session } = await yearlySubscriber(harness, stripe, 20);
    expect((await me(harness, session)).subscription?.withdrawableUntil).toBeNull();
    await expectError(await withdraw(harness, session), 409, "withdrawal_unavailable");
    const none: Session = await signIn(harness);
    await expectError(await withdraw(harness, none), 409, "withdrawal_unavailable");
    const row = await env.DB.prepare("SELECT started_at FROM subscriptions WHERE user_id = ?").bind(session.userId).first<{ started_at: number }>();
    expect(row?.started_at).toBe((Math.floor(harness.clock.nowMs / 1000) - 20 * day) * 1000);
  });
});
