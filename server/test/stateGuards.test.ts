import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { refreshTokenStateOf, supersededMarker, usedTokenOutcome } from "../src/auth/refreshState";
import { parseConfig } from "../src/config";
import { randomId } from "../src/crypto";
import { type TrialState, trialMeetingsLeft, userTrialState } from "../src/entitlements";
import { type SqlCondition, trialDeviceDecision, trialDevicePhaseOf, trialMeetingLeftSql } from "../src/trialState";

/**
 * The state guards of migration 0059: each trigger accepts the moves the code makes and rejects a write that would
 * leave a contradictory or backwards row. The pure decoders the code uses for the same states are checked alongside.
 */

const dayMs: number = 86_400_000;

async function newUser(): Promise<string> {
  const userId: string = randomId();
  await env.DB.prepare("INSERT INTO users (id, created_at) VALUES (?, 0)").bind(userId).run();
  return userId;
}

/** Runs a write that a trigger must refuse; the error names the table. */
async function expectRefused(statement: D1PreparedStatement, table: string): Promise<void> {
  await expect(statement.run()).rejects.toThrow(new RegExp(`${table}:`));
}

describe("phone_calls guards", () => {
  async function reservedCall(userId: string): Promise<string> {
    const callId: string = randomId();
    await env.DB.prepare(
      `INSERT INTO phone_calls (id, user_id, status, destination, caller_id, country, max_seconds, micro_usd_per_minute,
         estimated_micro_usd, month, day, created_at, reserved_until)
       VALUES (?, ?, 'reserved', '+12125550199', '+14155551000', 'US', 600, 20000, 200000, '2030-01', '2030-01-01', 0, 60000)`,
    )
      .bind(callId, userId)
      .run();
    return callId;
  }
  const update = (sql: string, ...binds: (string | number | null)[]): D1PreparedStatement => env.DB.prepare(sql).bind(...binds);

  it("accepts the code's path: reserved → dialing → completed, then a recording that is deleted later", async () => {
    const callId: string = await reservedCall(await newUser());
    await update("UPDATE phone_calls SET status = 'dialing', provider_call_sid = 'CA1', reserved_until = 99 WHERE id = ?", callId).run();
    await update("UPDATE phone_calls SET status = 'completed', billed_seconds = 30, cost_micro_usd = 10, settled_at = 5, destination = NULL, caller_id = NULL WHERE id = ?", callId).run();
    await update("UPDATE phone_calls SET recording_status = 'ready', recording_sid = 'RE1', recording_seconds = 30 WHERE id = ?", callId).run();
    await update("UPDATE phone_calls SET recording_deleted_at = 6 WHERE id = ? AND recording_sid = 'RE1'", callId).run();
    const absent: string = await reservedCall(await newUser());
    await update("UPDATE phone_calls SET status = 'expired', billed_seconds = 0, cost_micro_usd = 0, settled_at = 5 WHERE id = ?", absent).run();
    await update("UPDATE phone_calls SET recording_status = 'absent', recording_sid = NULL, recording_seconds = 0 WHERE id = ?", absent).run();
    await update("UPDATE phone_calls SET recording_status = 'ready', recording_sid = 'RE2', recording_seconds = 3 WHERE id = ?", absent).run();
  });

  it("refuses a call inserted in any state but reserved", async () => {
    const userId: string = await newUser();
    await expectRefused(
      env.DB.prepare(
        `INSERT INTO phone_calls (id, user_id, status, country, max_seconds, micro_usd_per_minute, estimated_micro_usd, month, day, created_at,
           reserved_until, settled_at) VALUES (?, ?, 'completed', 'US', 600, 1, 1, '2030-01', '2030-01-01', 0, 0, 1)`,
      ).bind(randomId(), userId),
      "phone_calls",
    );
  });

  it("refuses moves the state machine does not have and a settled call that changes", async () => {
    const callId: string = await reservedCall(await newUser());
    // reserved → completed skips the connect.
    await expectRefused(update("UPDATE phone_calls SET status = 'completed', settled_at = 5 WHERE id = ?", callId), "phone_calls");
    // An end state without settled_at, and a settled_at on a running call.
    await update("UPDATE phone_calls SET status = 'dialing' WHERE id = ?", callId).run();
    await expectRefused(update("UPDATE phone_calls SET status = 'failed' WHERE id = ?", callId), "phone_calls");
    await expectRefused(update("UPDATE phone_calls SET settled_at = 5 WHERE id = ?", callId), "phone_calls");
    await update("UPDATE phone_calls SET status = 'failed', billed_seconds = 0, cost_micro_usd = 0, settled_at = 5 WHERE id = ?", callId).run();
    // A late callback cannot reopen, re-settle or re-price a settled call.
    await expectRefused(update("UPDATE phone_calls SET status = 'dialing', settled_at = NULL WHERE id = ?", callId), "phone_calls");
    await expectRefused(update("UPDATE phone_calls SET status = 'completed' WHERE id = ?", callId), "phone_calls");
    await expectRefused(update("UPDATE phone_calls SET settled_at = 9 WHERE id = ?", callId), "phone_calls");
    await expectRefused(update("UPDATE phone_calls SET cost_micro_usd = 999 WHERE id = ?", callId), "phone_calls");
  });

  it("never lets a stored recording sid change or vanish, so it is always deleted at the provider", async () => {
    const callId: string = await reservedCall(await newUser());
    await update("UPDATE phone_calls SET recording_status = 'ready', recording_sid = 'RE1' WHERE id = ?", callId).run();
    // A late "absent" callback, a different sid, and a deletion mark without a sid.
    await expectRefused(update("UPDATE phone_calls SET recording_status = 'absent', recording_sid = NULL WHERE id = ?", callId), "phone_calls");
    await expectRefused(update("UPDATE phone_calls SET recording_sid = 'RE2' WHERE id = ?", callId), "phone_calls");
    await expectRefused(update("UPDATE phone_calls SET recording_status = 'absent' WHERE id = ?", callId), "phone_calls");
    const other: string = await reservedCall(await newUser());
    await expectRefused(update("UPDATE phone_calls SET recording_deleted_at = 1 WHERE id = ?", other), "phone_calls");
    await expectRefused(update("UPDATE phone_calls SET recording_status = 'ready' WHERE id = ?", other), "phone_calls");
    await update("UPDATE phone_calls SET recording_deleted_at = 6 WHERE id = ?", callId).run();
    await expectRefused(update("UPDATE phone_calls SET recording_deleted_at = NULL WHERE id = ?", callId), "phone_calls");
  });
});

describe("refresh token guards", () => {
  async function family(): Promise<string> {
    const familyId: string = randomId();
    await env.DB.prepare("INSERT INTO refresh_families (id, user_id, created_at) VALUES (?, ?, 0)").bind(familyId, await newUser()).run();
    return familyId;
  }
  async function token(familyId: string): Promise<string> {
    const hash: string = randomId();
    await env.DB.prepare("INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES (?, ?, 0, ?)").bind(hash, familyId, 10 * dayMs).run();
    return hash;
  }

  it("accepts rotation, a retry's new successor and a superseded successor", async () => {
    const familyId: string = await family();
    const first: string = await token(familyId);
    const successor: string = await token(familyId);
    await env.DB.prepare("UPDATE refresh_tokens SET used_at = 1, replaced_by = ? WHERE token_hash = ?").bind(successor, first).run();
    await env.DB.prepare("UPDATE refresh_tokens SET replaced_by = 'next' WHERE token_hash = ?").bind(first).run();
    await env.DB.prepare("UPDATE refresh_tokens SET used_at = 2, replaced_by = ? WHERE token_hash = ?").bind(supersededMarker, successor).run();
    await env.DB.prepare("UPDATE refresh_families SET revoked_at = 3, revoke_reason = 'logout' WHERE id = ?").bind(familyId).run();
  });

  it("refuses a successor without a use, an undone use and a superseded token that comes back", async () => {
    const familyId: string = await family();
    const first: string = await token(familyId);
    await expectRefused(env.DB.prepare("UPDATE refresh_tokens SET replaced_by = 'x' WHERE token_hash = ?").bind(first), "refresh_tokens");
    await expectRefused(
      env.DB.prepare("INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at, replaced_by) VALUES (?, ?, 0, 1, 'x')").bind(randomId(), familyId),
      "refresh_tokens",
    );
    await env.DB.prepare("UPDATE refresh_tokens SET used_at = 1, replaced_by = 'x' WHERE token_hash = ?").bind(first).run();
    await expectRefused(env.DB.prepare("UPDATE refresh_tokens SET used_at = NULL, replaced_by = NULL WHERE token_hash = ?").bind(first), "refresh_tokens");
    await expectRefused(env.DB.prepare("UPDATE refresh_tokens SET used_at = 5 WHERE token_hash = ?").bind(first), "refresh_tokens");
    await expectRefused(env.DB.prepare("UPDATE refresh_tokens SET replaced_by = NULL WHERE token_hash = ?").bind(first), "refresh_tokens");
    const superseded: string = await token(familyId);
    await env.DB.prepare("UPDATE refresh_tokens SET used_at = 1, replaced_by = ? WHERE token_hash = ?").bind(supersededMarker, superseded).run();
    await expectRefused(env.DB.prepare("UPDATE refresh_tokens SET replaced_by = 'y' WHERE token_hash = ?").bind(superseded), "refresh_tokens");
    await env.DB.prepare("UPDATE refresh_families SET revoked_at = 3 WHERE id = ?").bind(familyId).run();
    await expectRefused(env.DB.prepare("UPDATE refresh_families SET revoked_at = NULL WHERE id = ?").bind(familyId), "refresh_families");
  });

  it("decodes the token states and the outcome of presenting a used token", () => {
    expect(refreshTokenStateOf({ used_at: null, replaced_by: null })).toEqual({ kind: "unused" });
    expect(() => refreshTokenStateOf({ used_at: null, replaced_by: "x" })).toThrow(/Contradictory refresh token/);
    const rotated = refreshTokenStateOf({ used_at: 1000, replaced_by: "next" });
    expect(rotated).toEqual({ kind: "rotated", usedAt: 1000, successor: "next" });
    expect(usedTokenOutcome(rotated, 1000 + 600_000, 600_000)).toBe("retry");
    expect(usedTokenOutcome(rotated, 1001 + 600_000, 600_000)).toBe("reuse");
    expect(usedTokenOutcome(refreshTokenStateOf({ used_at: 1000, replaced_by: supersededMarker }), 1000, 600_000)).toBe("superseded_reuse");
    expect(usedTokenOutcome(refreshTokenStateOf({ used_at: 1000, replaced_by: null }), 1000, 600_000)).toBe("reuse");
  });
});

describe("trial guards", () => {
  it("accepts the code's writes: start, carry-over, claim, binding and a rejected claim", async () => {
    const userId: string = await newUser();
    const update = (sql: string, ...binds: (string | number)[]): Promise<D1Result> => env.DB.prepare(sql).bind(...binds, userId).run();
    await update("UPDATE users SET trial_started_at = ? WHERE id = ? AND trial_started_at IS NULL", 1000);
    await update("UPDATE users SET carried_trial_meetings = carried_trial_meetings + 2, trial_started_at = COALESCE(trial_started_at, 5) WHERE id = ?");
    await update("UPDATE users SET trial_device_claim_started_at = ? WHERE id = ? AND trial_device_verified_at IS NULL", 2000);
    await update("UPDATE users SET trial_device_claim_started_at = NULL WHERE id = ?");
    await update("UPDATE users SET trial_device_claim_started_at = ? WHERE id = ? AND trial_device_verified_at IS NULL", 3000);
    await update("UPDATE users SET trial_device_verified_at = ?, trial_device_claim_started_at = NULL WHERE id = ? AND trial_device_verified_at IS NULL", 4000);
    const row = await env.DB.prepare("SELECT trial_started_at, carried_trial_meetings, trial_device_verified_at FROM users WHERE id = ?").bind(userId).first();
    expect(row).toEqual({ trial_started_at: 1000, carried_trial_meetings: 2, trial_device_verified_at: 4000 });
  });

  it("refuses a write that would hand out a new trial or unbind a Mac", async () => {
    const userId: string = await newUser();
    const write = (sql: string): D1PreparedStatement => env.DB.prepare(sql).bind(userId);
    await env.DB.prepare("UPDATE users SET trial_started_at = 1000, carried_trial_meetings = 2, trial_device_verified_at = 5 WHERE id = ?").bind(userId).run();
    await expectRefused(write("UPDATE users SET trial_started_at = NULL WHERE id = ?"), "users");
    await expectRefused(write("UPDATE users SET trial_started_at = 2000 WHERE id = ?"), "users");
    await expectRefused(write("UPDATE users SET carried_trial_meetings = 0 WHERE id = ?"), "users");
    await expectRefused(write("UPDATE users SET trial_device_verified_at = NULL WHERE id = ?"), "users");
    await expectRefused(write("UPDATE users SET trial_device_claim_started_at = 7 WHERE id = ?"), "users");
    // Moving the start earlier only shortens the trial.
    await write("UPDATE users SET trial_started_at = 500 WHERE id = ?").run();
  });

  it("the start gate's SQL and trialMeetingsLeft agree on every trial state", async () => {
    const config = parseConfig(env);
    const nowMs: number = Date.UTC(2031, 0, 10);
    const cases: ReadonlyArray<{ readonly carried: number; readonly startedAt: number | null }> = [
      { carried: 0, startedAt: null },
      { carried: config.trialMeetings - 1, startedAt: null },
      { carried: config.trialMeetings, startedAt: null },
      { carried: 0, startedAt: nowMs - config.trialDurationMs + 1 },
      { carried: 0, startedAt: nowMs - config.trialDurationMs },
      { carried: 1, startedAt: nowMs - dayMs },
      { carried: config.trialMeetings + 2, startedAt: nowMs },
    ];
    for (const testCase of cases) {
      const userId: string = await newUser();
      await env.DB.prepare("UPDATE users SET carried_trial_meetings = ?, trial_started_at = ? WHERE id = ?").bind(testCase.carried, testCase.startedAt, userId).run();
      const gate: SqlCondition = trialMeetingLeftSql(config, userId, nowMs);
      const row: { open: number } | null = await env.DB.prepare(`SELECT (${gate.sql}) AS open`).bind(...gate.binds).first<{ open: number }>();
      const trial: TrialState = await userTrialState(env.DB, userId);
      expect({ ...testCase, open: row?.open === 1 }).toEqual({ ...testCase, open: trialMeetingsLeft(trial, config, new Date(nowMs)) > 0 });
    }
  });

  it("decodes the Mac binding and decides a claim", () => {
    expect(() => trialDevicePhaseOf({ verified_at: 1, claim_started_at: 2 })).toThrow(/Contradictory trial device/);
    expect(trialDevicePhaseOf({ verified_at: 1, claim_started_at: null })).toEqual({ kind: "verified", verifiedAt: 1 });
    const pending = { kind: "claim_pending", startedAt: 1000 } as const;
    expect(trialDeviceDecision({ kind: "unclaimed" }, false, 0, 60_000)).toBe("claim");
    expect(trialDeviceDecision({ kind: "unclaimed" }, true, 0, 60_000)).toBe("refuse");
    expect(trialDeviceDecision(pending, true, 61_000, 60_000)).toBe("resume");
    expect(trialDeviceDecision(pending, true, 61_001, 60_000)).toBe("refuse");
    expect(trialDeviceDecision(pending, false, 99_999_999, 60_000)).toBe("claim");
  });
});

describe("sync key envelope and App Store guards", () => {
  it("keeps recovery envelopes without expiry and pairing messages with one", async () => {
    const userId: string = await newUser();
    const insert = (kind: string, expiresAt: number | null): D1PreparedStatement =>
      env.DB.prepare("INSERT INTO sync_key_envelopes (user_id, envelope_id, kind, ciphertext, created_at, expires_at) VALUES (?, ?, ?, 'c', 0, ?)").bind(
        userId,
        randomId(),
        kind,
        expiresAt,
      );
    await insert("recovery", null).run();
    await insert("pairing", 10).run();
    await expectRefused(insert("recovery", 10), "sync_key_envelopes");
    await expectRefused(insert("pairing", null), "sync_key_envelopes");
    await expectRefused(insert("voiceprint", null), "sync_key_envelopes");
    await expectRefused(env.DB.prepare("UPDATE sync_key_envelopes SET expires_at = 5 WHERE user_id = ? AND kind = 'recovery'").bind(userId), "sync_key_envelopes");
  });

  it("accepts only App Store and Mac App Store rows", async () => {
    const insert = (userId: string, store: string): D1PreparedStatement =>
      env.DB.prepare(
        `INSERT INTO app_store_subscriptions (user_id, store, product_id, plan, status, period_type, purchased_at, expires_at, environment, synced_at, updated_at)
         VALUES (?, ?, 'p', NULL, 'active', 'normal', 0, 1, 'PRODUCTION', 0, 0)`,
      ).bind(userId, store);
    const userId: string = await newUser();
    await insert(userId, "mac_app_store").run();
    await expectRefused(insert(await newUser(), "play_store"), "app_store_subscriptions");
    await expectRefused(env.DB.prepare("UPDATE app_store_subscriptions SET store = 'stripe' WHERE user_id = ?").bind(userId), "app_store_subscriptions");
  });
});
