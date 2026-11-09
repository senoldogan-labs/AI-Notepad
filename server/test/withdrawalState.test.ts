import type { D1Migration } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { randomId } from "../src/crypto";
import {
  type WithdrawalEvent,
  type WithdrawalState,
  allowedWithdrawalStateChanges,
  nextWithdrawalState,
  withdrawalStates,
} from "../src/withdrawalState";

/** One example of every event. */
const events: readonly WithdrawalEvent[] = [
  { kind: "requested" },
  { kind: "refundsPending" },
  { kind: "attemptFailed" },
  { kind: "refundsSucceeded", refundedCents: 100, targetCents: 100 },
  { kind: "refundsSucceeded", refundedCents: 99, targetCents: 100 },
  { kind: "refundRefused" },
  { kind: "manualRetry" },
  { kind: "manualSettle" },
];

function changeKey(from: WithdrawalState, to: WithdrawalState): string {
  return `${from}->${to}`;
}

/** Inserts a withdrawal row in `state` (with the fields its state needs) and returns its subscription id. */
async function insertRow(state: WithdrawalState): Promise<string> {
  const id: string = `sub_${randomId()}`;
  await env.DB.prepare(
    `INSERT INTO subscription_withdrawals (stripe_subscription_id, user_id, stripe_customer_id, state, requested_at, settled_at, last_error, attempts, updated_at)
     VALUES (?, 'user', 'cus', ?, 1, ?, ?, 0, 1)`,
  )
    .bind(id, state, state === "settled" || state === "short" ? 2 : null, state === "blocked" ? "charge_disputed" : null)
    .run();
  return id;
}

/** Tries to change the state (with the fields the target needs); false when the database refuses. */
async function tryStateChange(id: string, to: WithdrawalState): Promise<boolean> {
  try {
    await env.DB.prepare(
      `UPDATE subscription_withdrawals SET state = ?1, settled_at = CASE WHEN ?1 IN ('settled', 'short') THEN 3 END, last_error = 'x'
       WHERE stripe_subscription_id = ?2`,
    )
      .bind(to, id)
      .run();
    return true;
  } catch (error: unknown) {
    expect(String(error)).toContain("subscription_withdrawals");
    return false;
  }
}

describe("withdrawal state machine", () => {
  it("the pure transition produces exactly the allowed state changes", () => {
    const produced: Set<string> = new Set();
    for (const from of withdrawalStates) {
      for (const event of events) {
        const to: WithdrawalState | null = nextWithdrawalState(from, event);
        if (to !== null && to !== from) {
          produced.add(changeKey(from, to));
        }
      }
    }
    expect([...produced].sort()).toEqual(allowedWithdrawalStateChanges.map(([from, to]) => changeKey(from, to)).sort());
  });

  it("transitions: requests start only without a row; short and settled are told apart; settled is final", () => {
    expect(nextWithdrawalState(null, { kind: "requested" })).toBe("requested");
    expect(nextWithdrawalState("requested", { kind: "requested" })).toBeNull();
    expect(nextWithdrawalState(null, { kind: "refundsPending" })).toBeNull();
    expect(nextWithdrawalState("requested", { kind: "refundsSucceeded", refundedCents: 4859, targetCents: 4859 })).toBe("settled");
    expect(nextWithdrawalState("requested", { kind: "refundsSucceeded", refundedCents: 4700, targetCents: 4859 })).toBe("short");
    expect(nextWithdrawalState("requested", { kind: "refundRefused" })).toBe("blocked");
    expect(nextWithdrawalState("requested", { kind: "attemptFailed" })).toBe("requested");
    expect(nextWithdrawalState("blocked", { kind: "attemptFailed" })).toBeNull();
    for (const event of events) {
      expect(nextWithdrawalState("settled", event)).toBeNull();
    }
  });

  it("the database trigger allows exactly the allowed state changes", async () => {
    const allowed: Set<string> = new Set(allowedWithdrawalStateChanges.map(([from, to]) => changeKey(from, to)));
    for (const from of withdrawalStates) {
      for (const to of withdrawalStates) {
        if (from === to) {
          continue;
        }
        const id: string = await insertRow(from);
        expect({ change: changeKey(from, to), accepted: await tryStateChange(id, to) }).toEqual({ change: changeKey(from, to), accepted: allowed.has(changeKey(from, to)) });
      }
    }
  });

  it("the database keeps the request fixed, the account only unlinkable, and each state's fields", async () => {
    const id: string = await insertRow("requested");
    const refused = async (sql: string): Promise<void> => {
      await expect(env.DB.prepare(sql).bind(id).run()).rejects.toThrow();
    };
    await refused("UPDATE subscription_withdrawals SET requested_at = 5 WHERE stripe_subscription_id = ?");
    await refused("UPDATE subscription_withdrawals SET stripe_customer_id = 'cus_other' WHERE stripe_subscription_id = ?");
    await refused("UPDATE subscription_withdrawals SET user_id = 'someone_else' WHERE stripe_subscription_id = ?");
    // An owed withdrawal keeps its account; settled needs settled_at; blocked needs a cause.
    await refused("UPDATE subscription_withdrawals SET user_id = NULL WHERE stripe_subscription_id = ?");
    await refused("UPDATE subscription_withdrawals SET state = 'settled' WHERE stripe_subscription_id = ?");
    await refused("UPDATE subscription_withdrawals SET state = 'blocked', last_error = NULL WHERE stripe_subscription_id = ?");
    await refused("UPDATE subscription_withdrawals SET state = 'unknown' WHERE stripe_subscription_id = ?");
    const settled: string = await insertRow("settled");
    await env.DB.prepare("UPDATE subscription_withdrawals SET user_id = NULL WHERE stripe_subscription_id = ?").bind(settled).run();
    await expect(env.DB.prepare("UPDATE subscription_withdrawals SET state = 'requested' WHERE stripe_subscription_id = ?").bind(settled).run()).rejects.toThrow();
  });
});

describe("migration 0065 backfill and bridge", () => {
  /** Signs up a user row and gives it a subscriptions row with the old withdrawal columns. */
  async function legacyRow(fields: { requested: number | null; completed: number | null; started: number | null; complimentary: number }): Promise<string> {
    const userId: string = randomId();
    await env.DB.batch([
      env.DB.prepare("INSERT INTO users (id, created_at) VALUES (?, 0)").bind(userId),
      env.DB.prepare(
        `INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at, plan,
           complimentary, started_at, withdrawal_requested_at, withdrawal_completed_at)
         VALUES (?, ?, ?, 'canceled', 0, 0, 7, 'monthly', ?, ?, ?, ?)`,
      ).bind(userId, `cus_${userId}`, `sub_${userId}`, fields.complimentary, fields.started, fields.requested, fields.completed),
    ]);
    return userId;
  }

  async function stateOf(userId: string): Promise<{ state: string; settled_at: number | null; last_error: string | null } | null> {
    return env.DB.prepare("SELECT state, settled_at, last_error FROM subscription_withdrawals WHERE user_id = ?")
      .bind(userId)
      .first<{ state: string; settled_at: number | null; last_error: string | null }>();
  }

  it("copies the old columns into explicit states", async () => {
    const migration: D1Migration | undefined = env.TEST_MIGRATIONS.find((candidate: D1Migration): boolean => candidate.name.startsWith("0065_"));
    if (migration === undefined) {
      throw new Error("Migration 0065 not found.");
    }
    // Undo the migration (test database only), write rows as the old code did, then run it again.
    for (const trigger of [
      "subscription_withdrawals_state_transition",
      "subscription_withdrawals_identity_fixed",
      "subscription_withdrawals_user_only_unlinked",
      "subscriptions_withdrawal_bridge_request",
      "subscriptions_withdrawal_bridge_complete",
    ]) {
      await env.DB.prepare(`DROP TRIGGER ${trigger}`).run();
    }
    await env.DB.prepare("DROP TABLE subscription_withdrawals").run();
    const completed: string = await legacyRow({ requested: 200, completed: 300, started: 100, complimentary: 0 });
    const pending: string = await legacyRow({ requested: 200, completed: null, started: 100, complimentary: 0 });
    const hidden: string = await legacyRow({ requested: 200, completed: null, started: 100, complimentary: 1 });
    const stale: string = await legacyRow({ requested: 50, completed: null, started: 100, complimentary: 0 });
    const none: string = await legacyRow({ requested: null, completed: null, started: 100, complimentary: 0 });
    for (const query of migration.queries) {
      await env.DB.prepare(query).run();
    }
    expect(await stateOf(completed)).toEqual({ state: "settled", settled_at: 300, last_error: null });
    expect(await stateOf(pending)).toEqual({ state: "requested", settled_at: null, last_error: null });
    expect(await stateOf(hidden)).toEqual({ state: "blocked", settled_at: null, last_error: "legacy_complimentary_overwrite" });
    expect(await stateOf(stale)).toBeNull();
    expect(await stateOf(none)).toBeNull();

    // The previous Worker version, live for a few seconds after the migration, still writes the old columns.
    const late: string = await legacyRow({ requested: null, completed: null, started: 100, complimentary: 0 });
    await env.DB.prepare("UPDATE subscriptions SET withdrawal_requested_at = 400, withdrawal_completed_at = NULL WHERE user_id = ?").bind(late).run();
    expect(await stateOf(late)).toEqual({ state: "requested", settled_at: null, last_error: null });
    await env.DB.prepare("UPDATE subscriptions SET withdrawal_completed_at = 500 WHERE user_id = ?").bind(late).run();
    expect(await stateOf(late)).toEqual({ state: "settled", settled_at: 500, last_error: null });
  });
});
