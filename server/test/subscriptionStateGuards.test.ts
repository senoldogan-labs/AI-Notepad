import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { randomId } from "../src/crypto";
import { paidStripeStatuses, terminalStripeStatuses } from "../src/subscriptionLifecycle";
import { syncObjectKinds } from "../src/sync";

/**
 * The state guards of migration 0066: each trigger accepts every value the code writes and refuses an unknown one, and
 * an UPDATE that leaves the guarded column alone is never checked.
 */

/** Every status Stripe documents for a subscription; the webhook mirrors these. */
const stripeStatuses: readonly string[] = ["incomplete", "incomplete_expired", "trialing", "active", "past_due", "canceled", "unpaid", "paused"];

/** `ReferralVoidReason` (src/referrals.ts) as a list. */
const voidReasons: readonly string[] = [
  "refunded",
  "disputed",
  "self_referral",
  "referrer_deleted",
  "referrer_no_customer",
  "referrer_complimentary",
  "card_reused",
  "self_card",
  "canceled_before_payment",
];

async function newUser(): Promise<string> {
  const userId: string = randomId();
  await env.DB.prepare("INSERT INTO users (id, created_at) VALUES (?, 0)").bind(userId).run();
  return userId;
}

/** Runs a write that a trigger must refuse; the error names the table. */
async function expectRefused(statement: D1PreparedStatement, table: string): Promise<void> {
  await expect(statement.run()).rejects.toThrow(new RegExp(`${table}:`));
}

function insertSubscription(userId: string, status: string, customer: string, subscription: string, complimentary: number): D1PreparedStatement {
  return env.DB.prepare(
    `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at, complimentary)
     VALUES (?, ?, ?, ?, 0, 0, 0, ?)`,
  ).bind(userId, customer, subscription, status, complimentary);
}

describe("subscriptions guards", () => {
  it("the lifecycle's statuses are all Stripe statuses the guard accepts", () => {
    for (const status of [...paidStripeStatuses, ...terminalStripeStatuses]) {
      expect(stripeStatuses).toContain(status);
    }
  });

  it("accepts every Stripe status on insert and update, refuses an unknown one", async () => {
    for (const status of stripeStatuses) {
      const userId: string = await newUser();
      await insertSubscription(userId, status, `cus_${randomId()}`, `sub_${randomId()}`, 0).run();
    }
    await expectRefused(insertSubscription(await newUser(), "expired", `cus_${randomId()}`, `sub_${randomId()}`, 0), "subscriptions");
    const userId: string = await newUser();
    await insertSubscription(userId, "active", `cus_${randomId()}`, `sub_${randomId()}`, 0).run();
    for (const status of stripeStatuses) {
      await env.DB.prepare("UPDATE subscriptions SET status = ? WHERE user_id = ?").bind(status, userId).run();
    }
    await expectRefused(env.DB.prepare("UPDATE subscriptions SET status = 'ended' WHERE user_id = ?").bind(userId), "subscriptions");
    // Other columns stay free.
    await env.DB.prepare("UPDATE subscriptions SET cancel_at = 5, first_paid_at = 6 WHERE user_id = ?").bind(userId).run();
  });

  it("complimentary access has comp_ ids and a Stripe subscription has none, on insert and on update", async () => {
    const tag: string = randomId();
    const comp: string = await newUser();
    await insertSubscription(comp, "active", `comp_cus_${tag}`, `comp_sub_${tag}`, 1).run();
    await expectRefused(insertSubscription(await newUser(), "active", `cus_${randomId()}`, `sub_${randomId()}`, 1), "subscriptions");
    await expectRefused(insertSubscription(await newUser(), "active", `comp_cus_${randomId()}`, `comp_sub_${randomId()}`, 0), "subscriptions");
    await expectRefused(insertSubscription(await newUser(), "active", `cus_${randomId()}`, `comp_sub_${randomId()}`, 1), "subscriptions");
    // The webhook replaces ended complimentary access with the Stripe subscription in one write (ids and flag together).
    await env.DB.prepare("UPDATE subscriptions SET stripe_customer_id = ?, stripe_subscription_id = ?, complimentary = 0 WHERE user_id = ?")
      .bind(`cus_${tag}`, `sub_${tag}`, comp)
      .run();
    // And complimentary access replaces an ended Stripe row the same way; flipping only the flag is refused.
    await expectRefused(env.DB.prepare("UPDATE subscriptions SET complimentary = 1 WHERE user_id = ?").bind(comp), "subscriptions");
    await env.DB.prepare("UPDATE subscriptions SET stripe_customer_id = ?, stripe_subscription_id = ?, complimentary = 1 WHERE user_id = ?")
      .bind(`comp_cus_${tag}x`, `comp_sub_${tag}x`, comp)
      .run();
  });
});

describe("referral, App Store, sync and Deepgram guards", () => {
  function insertRedemption(status: string, voidReason: string | null): D1PreparedStatement {
    return env.DB.prepare(
      `INSERT INTO referral_redemptions (id, referred_identity_hash, code, status, void_reason, created_at, updated_at)
       VALUES (?, ?, 'CODE', ?, ?, 0, 0)`,
    ).bind(randomId(), randomId(), status, voidReason);
  }

  it("referral void_reason: NULL or one of ReferralVoidReason", async () => {
    await insertRedemption("checkout", null).run();
    for (const reason of voidReasons) {
      await insertRedemption("void", reason).run();
    }
    await expectRefused(insertRedemption("void", "fraud"), "referral_redemptions");
    const id: string = randomId();
    await env.DB.prepare(
      "INSERT INTO referral_redemptions (id, referred_identity_hash, code, status, created_at, updated_at) VALUES (?, ?, 'CODE', 'checkout', 0, 0)",
    )
      .bind(id, randomId())
      .run();
    await env.DB.prepare("UPDATE referral_redemptions SET status = 'void', void_reason = 'canceled_before_payment' WHERE id = ?").bind(id).run();
    await expectRefused(env.DB.prepare("UPDATE referral_redemptions SET void_reason = 'other' WHERE id = ?").bind(id), "referral_redemptions");
  });

  it("App Store period_type: RevenueCat's period types only", async () => {
    const insert = (userId: string, periodType: string): D1PreparedStatement =>
      env.DB.prepare(
        `INSERT INTO app_store_subscriptions (user_id, store, product_id, status, period_type, purchased_at, expires_at, environment, synced_at, updated_at)
         VALUES (?, 'app_store', 'p', 'active', ?, 0, 1, 'PRODUCTION', 0, 0)`,
      ).bind(userId, periodType);
    for (const periodType of ["normal", "trial", "intro", "promotional", "prepaid"]) {
      await insert(await newUser(), periodType).run();
    }
    await expectRefused(insert(await newUser(), "lifetime"), "app_store_subscriptions");
    const userId: string = await newUser();
    await insert(userId, "trial").run();
    await env.DB.prepare("UPDATE app_store_subscriptions SET period_type = 'normal' WHERE user_id = ?").bind(userId).run();
    await expectRefused(env.DB.prepare("UPDATE app_store_subscriptions SET period_type = 'free' WHERE user_id = ?").bind(userId), "app_store_subscriptions");
  });

  it("sync object kind: one of syncObjectKinds, and it never changes", async () => {
    const userId: string = await newUser();
    const insert = (objectId: string, kind: string): D1PreparedStatement =>
      env.DB.prepare("INSERT INTO sync_objects (user_id, object_id, kind, rev, size, updated_at) VALUES (?, ?, ?, 1, 1, 0)").bind(userId, objectId, kind);
    for (const kind of syncObjectKinds) {
      await insert(randomId(), kind).run();
    }
    await expectRefused(insert(randomId(), "voiceprint"), "sync_objects");
    const objectId: string = randomId();
    await insert(objectId, "prefs").run();
    await env.DB.prepare("UPDATE sync_objects SET rev = 2, size = 3, deleted = 1 WHERE user_id = ? AND object_id = ?").bind(userId, objectId).run();
    await expectRefused(env.DB.prepare("UPDATE sync_objects SET kind = 'people' WHERE user_id = ? AND object_id = ?").bind(userId, objectId), "sync_objects");
  });

  it("Deepgram streams: 1 or 2, and only grows", async () => {
    const insert = (meetingId: string, streams: number): D1PreparedStatement =>
      env.DB.prepare(
        "INSERT INTO deepgram_live_meetings (meeting_id, grants, first_grant_at, charged_seconds, window_started_at, window_grants, streams) VALUES (?, 1, 0, 0, 0, 1, ?)",
      ).bind(meetingId, streams);
    const meetingId: string = randomId();
    await insert(meetingId, 1).run();
    await insert(randomId(), 2).run();
    await expectRefused(insert(randomId(), 3), "deepgram_live_meetings");
    await expectRefused(insert(randomId(), 0), "deepgram_live_meetings");
    await env.DB.prepare("UPDATE deepgram_live_meetings SET streams = 2 WHERE meeting_id = ?").bind(meetingId).run();
    await expectRefused(env.DB.prepare("UPDATE deepgram_live_meetings SET streams = 1 WHERE meeting_id = ?").bind(meetingId), "deepgram_live_meetings");
    await expectRefused(env.DB.prepare("UPDATE deepgram_live_meetings SET streams = 3 WHERE meeting_id = ?").bind(meetingId), "deepgram_live_meetings");
    // The unlink on account deletion and the settle leave streams alone.
    await env.DB.prepare("UPDATE deepgram_live_meetings SET meeting_id = ?, settled_at = 1, charged_seconds = 0 WHERE meeting_id = ?").bind(`unlinked_${meetingId}`, meetingId).run();
  });
});
