import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { type WithdrawalInvoice, retryPendingWithdrawals, withdrawalCashCents, withdrawalOwed, withdrawalRefundFailureLimit } from "../src/billing";
import { grantComplimentaryAccess } from "../src/complimentary";
import { parseConfig } from "../src/config";
import { randomToken } from "../src/crypto";
import { type Harness, type Session, defaultHarness, expectError, refreshed, req, signIn } from "./helpers";
import { eventOf, postEvent, sendSubscription } from "./stripeEvents";
import { type FakeInvoice, type FakeStripe, fakeYearlySubscription, stubStripeApi } from "./stripeFake";

const dayMs: number = 86_400_000;
const day: number = 86_400;
const year: number = 365 * day;

interface MeBody {
  readonly plan: string;
  readonly subscription: {
    withdrawableUntil: string | null;
    withdrawalPending: boolean;
    status: string;
    access: string;
    complimentary: boolean;
  } | null;
}

/** The `subscription_withdrawals` row of a Stripe subscription; null when there is none. */
interface WithdrawalRowBody {
  readonly state: string;
  readonly user_id: string | null;
  readonly target_cents: number | null;
  readonly refunded_cents: number | null;
  readonly attempts: number;
  readonly last_error: string | null;
}

function withdrawalRow(subscriptionId: string): Promise<WithdrawalRowBody | null> {
  return env.DB.prepare("SELECT state, user_id, target_cents, refunded_cents, attempts, last_error FROM subscription_withdrawals WHERE stripe_subscription_id = ?")
    .bind(subscriptionId)
    .first<WithdrawalRowBody>();
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
    // Access ends with the withdrawal, before Stripe's deletion webhook: no second withdrawal card.
    const after: MeBody = await me(harness, session);
    expect(after.plan).toBe("trial");
    expect(after.subscription).toMatchObject({ status: "canceled", access: "none", withdrawableUntil: null, withdrawalPending: false });
    expect(await withdrawalRow(subscriptionId)).toMatchObject({ state: "settled", target_cents: 4859, refunded_cents: 4859, attempts: 0, user_id: session.userId });
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

  it("a webhook read before Stripe's cancellation doesn't give access back; the retry settles it", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId, customer } = await yearlySubscriber(harness, stripe, 3);
    stripe.failCancels = true;
    expect((await withdraw(harness, session)).status).toBeGreaterThanOrEqual(500);
    // Stripe still reports it live; an event arrives meanwhile.
    const created: number = Math.floor(harness.clock.nowMs / 1000);
    const live = fakeYearlySubscription(subscriptionId, customer, "active", created - 3 * day, created - 3 * day + year);
    expect((await sendSubscription(harness, stripe, `evt_${randomToken(6)}`, "customer.subscription.updated", created, live)).status).toBe(200);
    const during: MeBody = await me(harness, session);
    expect(during.plan).toBe("trial");
    expect(during.subscription?.status).toBe("canceled");
    expect(during.subscription?.withdrawableUntil).toBeNull();
    expect(during.subscription?.withdrawalPending).toBe(true);
    expect((await withdrawalRow(subscriptionId))?.attempts).toBe(1);
    stripe.failCancels = false;
    expect(await retryPendingWithdrawals(env.DB, harness.platform, parseConfig(env), 50)).toBe(1);
    expect(stripe.canceled).toContain(subscriptionId);
    expect((await withdrawalRow(subscriptionId))?.state).toBe("settled");
    // Stripe's own deletion event afterwards writes the same.
    const ended = fakeYearlySubscription(subscriptionId, customer, "canceled", created - 3 * day, created - 3 * day + year);
    expect((await sendSubscription(harness, stripe, `evt_${randomToken(6)}`, "customer.subscription.deleted", created + 1, ended)).status).toBe(200);
    const after: MeBody = await me(harness, session);
    expect(after.subscription).toMatchObject({ status: "canceled", access: "none", withdrawableUntil: null, withdrawalPending: false });
  });

  it("re-subscribing while a refund is pending keeps the old withdrawal owed and retried", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId, customer } = await yearlySubscriber(harness, stripe, 3);
    stripe.nextRefundStatus = "pending";
    expect(await (await withdraw(harness, session)).json()).toEqual({ refundedCents: 4859, currency: "usd", pending: true });
    stripe.nextRefundStatus = null;
    // A new subscription the same day: the account's single subscriptions row moves to it.
    const created: number = Math.floor(harness.clock.nowMs / 1000);
    const next: string = `sub_${randomToken(6)}`;
    const renewed = fakeYearlySubscription(next, customer, "active", created, created + year);
    expect((await sendSubscription(harness, stripe, `evt_${randomToken(6)}`, "customer.subscription.created", created, renewed)).status).toBe(200);
    const subscribed: MeBody = await me(harness, session);
    expect(subscribed.plan).toBe("subscription");
    expect(subscribed.subscription).toMatchObject({ status: "active", access: "active", withdrawalPending: true });
    expect((await withdrawalRow(subscriptionId))?.state).toBe("requested");
    // The site's retry resumes the old withdrawal, never withdraws the new subscription.
    expect(await (await withdraw(harness, session)).json()).toEqual({ refundedCents: 4859, currency: "usd", pending: true });
    expect(stripe.canceled).not.toContain(next);
    expect(await withdrawalRow(next)).toBeNull();
    // The bank confirms the refund: the daily job settles the old withdrawal.
    stripe.refundForms[0]?.set("fake_status", "succeeded");
    expect(await retryPendingWithdrawals(env.DB, harness.platform, parseConfig(env), 50)).toBe(1);
    expect((await withdrawalRow(subscriptionId))?.state).toBe("settled");
    expect(stripe.refundForms).toHaveLength(1);
    const settled: MeBody = await me(harness, session);
    expect(settled.subscription).toMatchObject({ status: "active", withdrawalPending: false });
    expect(settled.subscription?.withdrawableUntil).not.toBeNull();
  });

  it("complimentary access granted while a refund is pending doesn't hide it from the daily job", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId } = await yearlySubscriber(harness, stripe, 3);
    stripe.nextRefundStatus = "failed";
    expect((await withdraw(harness, session)).status).toBeGreaterThanOrEqual(500);
    stripe.nextRefundStatus = null;
    // The withdrawal set the row to canceled: free access can be granted over it.
    await grantComplimentaryAccess(env.DB, session.userId, null, "admin", new Date(harness.clock.nowMs));
    const granted: MeBody = await me(harness, session);
    expect(granted.subscription).toMatchObject({ complimentary: true, withdrawalPending: true });
    expect(await retryPendingWithdrawals(env.DB, harness.platform, parseConfig(env), 50)).toBe(1);
    expect((await withdrawalRow(subscriptionId))?.state).toBe("settled");
    expect((await me(harness, session)).subscription).toMatchObject({ complimentary: true, withdrawalPending: false });
  });

  it("customer and account deletion keep an owed withdrawal; the daily job still refunds it", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId, customer } = await yearlySubscriber(harness, stripe, 3);
    stripe.nextRefundStatus = "failed";
    expect((await withdraw(harness, session)).status).toBeGreaterThanOrEqual(500);
    stripe.nextRefundStatus = null;
    const deleted: string = eventOf(`evt_${randomToken(6)}`, "customer.deleted", Math.floor(harness.clock.nowMs / 1000), { id: customer, object: "customer", deleted: true });
    expect((await postEvent(harness, deleted)).status).toBe(200);
    expect((await withdrawalRow(subscriptionId))?.state).toBe("requested");
    expect((await harness.call(req("DELETE", "/v1/me", { token: session.accessToken }))).status).toBe(200);
    expect(await withdrawalRow(subscriptionId)).toMatchObject({ state: "requested", user_id: session.userId });
    expect(await retryPendingWithdrawals(env.DB, harness.platform, parseConfig(env), 50)).toBe(1);
    // Settled: the deleted account's link is cleared.
    expect(await withdrawalRow(subscriptionId)).toMatchObject({ state: "settled", user_id: null, refunded_cents: 4859 });
  });

  it("concurrent requests and the daily job make one refund; a lost response is replayed under the same key", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId } = await yearlySubscriber(harness, stripe, 3);
    const config = parseConfig(env);
    const results: Response[] = await Promise.all([withdraw(harness, session), withdraw(harness, session), withdraw(harness, session)]);
    for (const response of results) {
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ refundedCents: 4859, currency: "usd", pending: false });
    }
    expect(stripe.refundForms).toHaveLength(1);
    expect((await withdrawalRow(subscriptionId))?.state).toBe("settled");

    const other: Subscriber = await yearlySubscriber(harness, stripe, 3);
    stripe.failCancels = true;
    expect((await withdraw(harness, other.session)).status).toBeGreaterThanOrEqual(500);
    stripe.failCancels = false;
    // The refund is made but its response is lost: the retry inside the run sends the same key and Stripe replays it.
    stripe.loseRefundResponse = true;
    const [mine, daily] = await Promise.all([withdraw(harness, other.session), retryPendingWithdrawals(env.DB, harness.platform, config, 50)]);
    expect(mine.status).toBe(200);
    expect(daily).toBeLessThanOrEqual(1);
    const otherRefunds: URLSearchParams[] = stripe.refundForms.filter((form: URLSearchParams): boolean => form.get("payment_intent") === other.intents[0]);
    expect(otherRefunds).toHaveLength(1);
    expect(stripe.refundKeys.filter((key: string): boolean => key.includes(other.subscriptionId))).toEqual([`refund-withdrawal-${other.subscriptionId}-${other.intents[0] ?? ""}-0`]);
    expect((await withdrawalRow(other.subscriptionId))?.state).toBe("settled");
  });

  it("a refund below the computed amount ends short, alerted and not retried", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId, intents } = await yearlySubscriber(harness, stripe, 3);
    // Support refunded $2 earlier: only 4700 of the 4859 owed is still refundable on the payment.
    stripe.refundForms.push(new URLSearchParams({ payment_intent: intents[0] ?? "", amount: "200" }));
    expect(await (await withdraw(harness, session)).json()).toEqual({ refundedCents: 4700, currency: "usd", pending: false });
    expect(await withdrawalRow(subscriptionId)).toMatchObject({ state: "short", target_cents: 4859, refunded_cents: 4700 });
    expect(await retryPendingWithdrawals(env.DB, harness.platform, parseConfig(env), 50)).toBe(0);
    expect((await me(harness, session)).subscription?.withdrawalPending).toBe(false);
    // Asked again: the stored result, no Stripe refund.
    expect(await (await withdraw(harness, session)).json()).toEqual({ refundedCents: 4700, currency: "usd", pending: false });
    expect(stripe.refundForms).toHaveLength(2);
  });

  it("a refund Stripe refuses for good blocks the withdrawal: alerted, not retried", async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId } = await yearlySubscriber(harness, stripe, 3);
    stripe.refuseRefunds = "charge_disputed";
    await expectError(await withdraw(harness, session), 502, "upstream_rejected");
    expect(await withdrawalRow(subscriptionId)).toMatchObject({ state: "blocked", last_error: "charge_disputed", attempts: 1 });
    expect(stripe.canceled).toContain(subscriptionId);
    expect(await retryPendingWithdrawals(env.DB, harness.platform, parseConfig(env), 50)).toBe(0);
    const blocked: MeBody = await me(harness, session);
    expect(blocked.subscription).toMatchObject({ status: "canceled", withdrawalPending: false, withdrawableUntil: null });
    stripe.refuseRefunds = null;
    await expectError(await withdraw(harness, session), 502, "upstream_rejected");
    expect(stripe.refundForms).toHaveLength(0);
  });

  it(`refunds that keep failing block the withdrawal after ${withdrawalRefundFailureLimit} attempts`, async () => {
    const harness: Harness = await defaultHarness();
    const stripe: FakeStripe = stubStripeApi(harness);
    const { session, subscriptionId } = await yearlySubscriber(harness, stripe, 3);
    const config = parseConfig(env);
    stripe.nextRefundStatus = "failed";
    expect((await withdraw(harness, session)).status).toBeGreaterThanOrEqual(500);
    await expect(retryPendingWithdrawals(env.DB, harness.platform, config, 50)).rejects.toThrow("1 of 1 withdrawal retries failed.");
    expect((await withdrawalRow(subscriptionId))?.state).toBe("requested");
    await expect(retryPendingWithdrawals(env.DB, harness.platform, config, 50)).rejects.toThrow("1 of 1 withdrawal retries failed.");
    expect(await withdrawalRow(subscriptionId)).toMatchObject({ state: "blocked", last_error: "refund_failed_repeatedly", attempts: 3 });
    expect(stripe.refundKeys.map((key: string): string => key.slice(-2))).toEqual(["-0", "-1", "-2"]);
    expect(await retryPendingWithdrawals(env.DB, harness.platform, config, 50)).toBe(0);
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
