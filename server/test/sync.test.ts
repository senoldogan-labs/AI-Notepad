import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { cleanupExpiredRows } from "../src/cleanup";
import { hexEncode, randomId } from "../src/crypto";
import type { Env } from "../src/env";
import {
  scheduledSyncCleanupLimits,
  syncAccountMaxBytes,
  syncAccountMaxEnvelopes,
  syncAccountMaxObjects,
  syncCleanup,
  syncObjectMaxBytes,
  syncEpochPrefix,
  syncPrefix,
  syncR2ClassABudget,
  syncR2ClassBBudget,
  syncR2StoredBytesBudget,
  syncRetentionWipeStatements,
  syncUsageMonth,
} from "../src/sync";
import { parseConfig } from "../src/config";
import { type Harness, type Session, blockingLimiter, defaultHarness, envWith, expectError, grantSubscription, req, signIn } from "./helpers";

const allowingLimiter: RateLimit = {
  limit: async (): Promise<RateLimitOutcome> => ({ success: true }),
};
/** Sync requests in tests skip the per-user limiter (one test sends more than a real device does in a minute). */
const syncEnv: Env = envWith({ SYNC_USER_LIMITER: allowingLimiter });
const dayMs: number = 86_400_000;

/** A random 16-byte key id in the client's hex form. */
function newKeyId(): string {
  const bytes: Uint8Array = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return hexEncode(bytes);
}

/**
 * A blob shaped like the client's (`SyncCrypto.sealSyncObject`): `GSY1`, key id, big-endian base revision, then
 * `bodyBytes` random bytes standing in for nonce + ciphertext + tag. The server never decrypts.
 */
function blob(keyId: string, baseRev: number, bodyBytes: number): Uint8Array {
  const result: Uint8Array = new Uint8Array(28 + bodyBytes);
  result.set(new TextEncoder().encode("GSY1"), 0);
  result.set(Uint8Array.from(keyId.match(/../g) ?? [], (pair: string): number => Number.parseInt(pair, 16)), 4);
  new DataView(result.buffer).setBigUint64(20, BigInt(baseRev));
  crypto.getRandomValues(result.subarray(28, Math.min(result.byteLength, 28 + 65_536)));
  return result;
}

interface SyncUser {
  readonly session: Session;
  readonly keyId: string;
}

/** A subscriber with sync turned on. */
async function syncUser(harness: Harness): Promise<SyncUser> {
  const session: Session = await signIn(harness);
  await grantSubscription(session.userId, "active", harness.clock.nowMs + 30 * dayMs);
  return enabledSync(harness, session);
}

/** A user in a started trial (no Stripe rows, so account deletion makes no Stripe calls) with sync turned on. */
async function syncTrialUser(harness: Harness): Promise<SyncUser> {
  const session: Session = await signIn(harness);
  await env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(harness.clock.nowMs, session.userId).run();
  return enabledSync(harness, session);
}

async function enabledSync(harness: Harness, session: Session): Promise<SyncUser> {
  const keyId: string = newKeyId();
  const response: Response = await harness.call(req("POST", "/v1/sync/account", { token: session.accessToken, json: { keyId }, env: syncEnv }));
  expect(response.status).toBe(200);
  return { session, keyId };
}

function put(harness: Harness, user: SyncUser, objectId: string, kind: string, baseRev: number, body: Uint8Array): Promise<Response> {
  return harness.call(
    req("PUT", `/v1/sync/objects/${objectId}`, {
      token: user.session.accessToken,
      headers: { "content-type": "application/octet-stream", "if-match": String(baseRev), "x-sync-kind": kind, "x-sync-device": "6f9619ff-8b86-4011-b42d-00c04fc964ff" },
      body,
      env: syncEnv,
    }),
  );
}

async function putRev(harness: Harness, user: SyncUser, objectId: string, kind: string, baseRev: number): Promise<number> {
  const response: Response = await put(harness, user, objectId, kind, baseRev, blob(user.keyId, baseRev, 64));
  expect(response.status).toBe(200);
  return (await response.json<{ rev: number }>()).rev;
}

function call(harness: Harness, user: SyncUser, method: string, path: string, headers: Record<string, string>): Promise<Response> {
  return harness.call(req(method, path, { token: user.session.accessToken, headers, env: syncEnv }));
}

interface ChangesBody {
  readonly keyId: string;
  readonly epoch: number;
  readonly changes: ReadonlyArray<{ objectId: string; kind: string; rev: number; size: number; deleted: boolean; updatedAt: number }>;
  readonly cursor: number;
  readonly hasMore: boolean;
}

async function changes(harness: Harness, user: SyncUser, query: string): Promise<ChangesBody> {
  const response: Response = await call(harness, user, "GET", `/v1/sync/changes?${query}`, {});
  expect(response.status).toBe(200);
  return response.json<ChangesBody>();
}

async function blobKeys(userId: string): Promise<string[]> {
  return (await env.SYNC_BUCKET.list({ prefix: syncPrefix(userId) })).objects.map((object: R2Object): string => object.key);
}

async function count(sql: string, userId: string): Promise<number> {
  return (await env.DB.prepare(sql).bind(userId).first<{ count: number }>())?.count ?? -1;
}

describe("/v1/sync account", () => {
  it("is 503 while SYNC_POLICY is off and 401 without a session", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("GET", "/v1/sync/account", { token: session.accessToken, env: envWith({ SYNC_POLICY: "off" }) })), 503, "sync_unavailable");
    await expectError(await harness.call(req("GET", "/v1/sync/account", { env: syncEnv })), 401, "unauthorized");
    await expectError(
      await harness.call(req("GET", "/v1/sync/account", { token: session.accessToken, env: envWith({ SYNC_USER_LIMITER: blockingLimiter }) })),
      429,
      "rate_limited",
    );
  });

  it("is opt-in: off until a device turns it on with its key id; another key is refused", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const off: Response = await harness.call(req("GET", "/v1/sync/account", { token: session.accessToken, env: syncEnv }));
    expect(await off.json()).toEqual({ enabled: false, keyId: null, epoch: null, lastRev: 0, objects: 0, storedBytes: 0, maxObjects: syncAccountMaxObjects, maxBytes: syncAccountMaxBytes });
    // Turning sync on writes, so it needs a subscription or a started trial.
    const keyId: string = newKeyId();
    await expectError(await harness.call(req("POST", "/v1/sync/account", { token: session.accessToken, json: { keyId }, env: syncEnv })), 402, "subscription_required");
    await expectError(await harness.call(req("GET", "/v1/sync/changes?since=0", { token: session.accessToken, env: syncEnv })), 409, "sync_not_enabled");
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 30 * dayMs);
    const on: Response = await harness.call(req("POST", "/v1/sync/account", { token: session.accessToken, json: { keyId }, env: syncEnv }));
    expect(on.status).toBe(200);
    expect(await on.json()).toMatchObject({ enabled: true, keyId, epoch: harness.clock.nowMs, lastRev: 0 });
    // The second device of the same account with the same key: no change. A device that generated its own key races
    // the first one and must fetch the account's key instead.
    expect((await harness.call(req("POST", "/v1/sync/account", { token: session.accessToken, json: { keyId }, env: syncEnv }))).status).toBe(200);
    await expectError(
      await harness.call(req("POST", "/v1/sync/account", { token: session.accessToken, json: { keyId: newKeyId() }, env: syncEnv })),
      409,
      "sync_key_mismatch",
    );
    await expectError(await harness.call(req("POST", "/v1/sync/account", { token: session.accessToken, json: { keyId: "XYZ" }, env: syncEnv })), 400, "invalid_body");
  });

  it("opting out removes the index, envelopes and every blob at once", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    await putRev(harness, user, randomId(), "meeting.state", 0);
    await putRev(harness, user, randomId(), "meeting.content", 0);
    const envelope: Response = await harness.call(
      req("PUT", `/v1/sync/envelopes/${randomId()}`, { token: user.session.accessToken, json: { kind: "recovery", ciphertext: "AAAA" }, env: syncEnv }),
    );
    expect(envelope.status).toBe(200);
    expect(await blobKeys(user.session.userId)).toHaveLength(2);

    const wiped: Response = await call(harness, user, "DELETE", "/v1/sync/account", {});
    expect(await wiped.json()).toEqual({ deleted: true, objects: 2 });
    expect(await blobKeys(user.session.userId)).toEqual([]);
    expect(await count("SELECT COUNT(*) AS count FROM sync_objects WHERE user_id = ?", user.session.userId)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_key_envelopes WHERE user_id = ?", user.session.userId)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_accounts WHERE user_id = ?", user.session.userId)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_purges WHERE prefix = 'u/' || ? || '/'", user.session.userId)).toBe(0);
    // Turning it on again starts a new epoch: old cursors are refused.
    harness.clock.nowMs += 1000;
    expect((await harness.call(req("POST", "/v1/sync/account", { token: user.session.accessToken, json: { keyId: newKeyId() }, env: syncEnv }))).status).toBe(200);
  });
});

describe("/v1/sync epochs", () => {
  it("purging a wiped epoch leaves the blobs of sync turned on again untouched", async () => {
    const harness: Harness = await defaultHarness();
    const first: SyncUser = await syncUser(harness);
    const oldEpoch: number = harness.clock.nowMs;
    await putRev(harness, first, randomId(), "meeting.state", 0);
    expect((await call(harness, first, "DELETE", "/v1/sync/account", {})).status).toBe(200);
    harness.clock.nowMs += 1000;
    const keyId: string = newKeyId();
    expect((await harness.call(req("POST", "/v1/sync/account", { token: first.session.accessToken, json: { keyId }, env: syncEnv }))).status).toBe(200);
    const again: SyncUser = { session: first.session, keyId };
    const objectId: string = randomId();
    await putRev(harness, again, objectId, "meeting.state", 0);
    // The old epoch's purge runs late (e.g. it failed before) and must not delete the new blob.
    await env.DB.prepare("INSERT INTO sync_purges (prefix, requested_at) VALUES (?, ?)").bind(syncEpochPrefix(first.session.userId, oldEpoch), oldEpoch).run();
    await syncCleanup(env.DB, env.SYNC_BUCKET, parseConfig(env), new Date(harness.clock.nowMs), scheduledSyncCleanupLimits);
    expect(await blobKeys(first.session.userId)).toHaveLength(1);
    expect((await call(harness, again, "GET", `/v1/sync/objects/${objectId}`, {})).status).toBe(200);
  });
});

describe("/v1/sync objects", () => {
  it("stores, reads and replaces encrypted blobs with optimistic revisions", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const objectId: string = randomId();
    const first: Uint8Array = blob(user.keyId, 0, 100);
    const created: Response = await put(harness, user, objectId, "meeting.state", 0, first);
    expect(created.status).toBe(200);
    expect(await created.json()).toEqual({ objectId, rev: 1 });

    const read: Response = await call(harness, user, "GET", `/v1/sync/objects/${objectId}`, {});
    expect(read.status).toBe(200);
    expect(read.headers.get("x-sync-rev")).toBe("1");
    expect(read.headers.get("x-sync-kind")).toBe("meeting.state");
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(first);

    // Creating it again (another device's stale view) and updating from an old revision both conflict.
    await expectError(await put(harness, user, objectId, "meeting.state", 0, blob(user.keyId, 0, 64)), 409, "sync_conflict");
    expect(await putRev(harness, user, objectId, "meeting.state", 1)).toBe(2);
    await expectError(await put(harness, user, objectId, "meeting.state", 1, blob(user.keyId, 1, 64)), 409, "sync_conflict");
    // The replaced blob is gone; only the current one stays.
    expect(await blobKeys(user.session.userId)).toHaveLength(1);
    const account = await (await call(harness, user, "GET", "/v1/sync/account", {})).json<{ lastRev: number; objects: number; storedBytes: number }>();
    expect(account).toMatchObject({ lastRev: 2, objects: 1, storedBytes: 28 + 64 });
    expect(await count("SELECT COUNT(*) AS count FROM sync_objects WHERE user_id = ? AND updated_by_device = '6f9619ff-8b86-4011-b42d-00c04fc964ff'", user.session.userId)).toBe(1);
  });

  it("rejects malformed requests and blobs sealed with another key", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const objectId: string = randomId();
    await expectError(await put(harness, user, objectId, "voices", 0, blob(user.keyId, 0, 64)), 400, "bad_request");
    await expectError(await put(harness, user, objectId, "meeting.state", 0, blob(newKeyId(), 0, 64)), 409, "sync_key_mismatch");
    await expectError(await put(harness, user, objectId, "meeting.state", 0, blob(user.keyId, 3, 64)), 400, "invalid_body");
    await expectError(await put(harness, user, objectId, "meeting.state", 0, new TextEncoder().encode("plain text is not a sync blob at all, really")), 400, "invalid_body");
    await expectError(await put(harness, user, objectId, "meeting.state", 0, blob(user.keyId, 0, 10)), 400, "invalid_body");
    await expectError(
      await harness.call(
        req("PUT", `/v1/sync/objects/${objectId}`, {
          token: user.session.accessToken,
          headers: { "content-type": "application/octet-stream", "x-sync-kind": "people" },
          body: blob(user.keyId, 0, 64),
          env: syncEnv,
        }),
      ),
      400,
      "bad_request",
    );
    await expectError(
      await harness.call(
        req("PUT", `/v1/sync/objects/${objectId}`, {
          token: user.session.accessToken,
          headers: { "content-type": "text/plain", "if-match": "0", "x-sync-kind": "people" },
          body: blob(user.keyId, 0, 64),
          env: syncEnv,
        }),
      ),
      415,
      "unsupported_media_type",
    );
    await expectError(await call(harness, user, "GET", "/v1/sync/objects/not-a-uuid", {}), 404, "not_found");
    // An object keeps its kind.
    await putRev(harness, user, objectId, "people", 0);
    await expectError(await put(harness, user, objectId, "prefs", 1, blob(user.keyId, 1, 64)), 400, "bad_request");
    expect(await blobKeys(user.session.userId)).toHaveLength(1);
  });

  it("caps the object size and the account quota", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    await expectError(await put(harness, user, randomId(), "meeting.content", 0, blob(user.keyId, 0, syncObjectMaxBytes)), 413, "payload_too_large");
    await env.DB.prepare("UPDATE sync_accounts SET stored_bytes = ? WHERE user_id = ?").bind(syncAccountMaxBytes - 50, user.session.userId).run();
    await expectError(await put(harness, user, randomId(), "meeting.content", 0, blob(user.keyId, 0, 64)), 413, "sync_quota_exceeded");
    await env.DB.prepare("UPDATE sync_accounts SET stored_bytes = 0, object_count = ? WHERE user_id = ?").bind(syncAccountMaxObjects, user.session.userId).run();
    await expectError(await put(harness, user, randomId(), "meeting.content", 0, blob(user.keyId, 0, 64)), 413, "sync_quota_exceeded");
    expect(await blobKeys(user.session.userId)).toEqual([]);
  });

  it("pauses uploads and downloads before R2's free tier runs out; deletes and opt-out still work", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const month: string = syncUsageMonth(new Date(harness.clock.nowMs));
    const usage = async (): Promise<{ class_a: number; class_b: number } | null> =>
      env.DB.prepare("SELECT class_a, class_b FROM sync_r2_usage WHERE month = ?").bind(month).first<{ class_a: number; class_b: number }>();
    const objectId: string = randomId();
    const before: { class_a: number; class_b: number } = (await usage()) ?? { class_a: 0, class_b: 0 };
    await putRev(harness, user, objectId, "people", 0);
    expect((await call(harness, user, "GET", `/v1/sync/objects/${objectId}`, {})).status).toBe(200);
    expect(await usage()).toEqual({ class_a: before.class_a + 1, class_b: before.class_b + 1 });

    // Class A spent: no upload reaches R2 this month.
    await env.DB.prepare("UPDATE sync_r2_usage SET class_a = ? WHERE month = ?").bind(syncR2ClassABudget, month).run();
    await expectError(await put(harness, user, randomId(), "people", 0, blob(user.keyId, 0, 64)), 503, "sync_unavailable");
    expect(await blobKeys(user.session.userId)).toHaveLength(1);
    // Class B spent: downloads pause too.
    await env.DB.prepare("UPDATE sync_r2_usage SET class_b = ? WHERE month = ?").bind(syncR2ClassBBudget, month).run();
    await expectError(await call(harness, user, "GET", `/v1/sync/objects/${objectId}`, {}), 503, "sync_unavailable");
    expect(await usage()).toEqual({ class_a: syncR2ClassABudget, class_b: syncR2ClassBBudget });

    // Storage spent across accounts: an upload that grows the copy is refused even with operations left.
    await env.DB.prepare("UPDATE sync_r2_usage SET class_a = 0, class_b = 0 WHERE month = ?").bind(month).run();
    const other: SyncUser = await syncUser(harness);
    await env.DB.prepare("UPDATE sync_accounts SET stored_bytes = ? WHERE user_id = ?").bind(syncR2StoredBytesBudget, other.session.userId).run();
    await expectError(await put(harness, user, randomId(), "people", 0, blob(user.keyId, 0, 64)), 503, "sync_unavailable");
    await env.DB.prepare("UPDATE sync_accounts SET stored_bytes = 0 WHERE user_id = ?").bind(other.session.userId).run();

    // Deleting is free and never paused; opting out still purges the blobs.
    const second: string = randomId();
    const secondRev: number = await putRev(harness, user, second, "prefs", 0);
    await env.DB.prepare("UPDATE sync_r2_usage SET class_a = ? WHERE month = ?").bind(syncR2ClassABudget, month).run();
    expect((await call(harness, user, "DELETE", `/v1/sync/objects/${second}`, { "if-match": String(secondRev) })).status).toBe(200);
    expect((await call(harness, user, "DELETE", "/v1/sync/account", {})).status).toBe(200);
    expect(await blobKeys(user.session.userId)).toEqual([]);
    // The counters are shared by the whole test database: give the other tests their budget back.
    await env.DB.prepare("UPDATE sync_r2_usage SET class_a = 0, class_b = 0 WHERE month = ?").bind(month).run();
  });

  it("deletes into a tombstone that other devices see; writing again resurrects it", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const objectId: string = randomId();
    await putRev(harness, user, objectId, "ask.chat", 0);
    await expectError(await call(harness, user, "DELETE", `/v1/sync/objects/${objectId}`, { "if-match": "0" }), 409, "sync_conflict");
    const deleted: Response = await call(harness, user, "DELETE", `/v1/sync/objects/${objectId}`, { "if-match": "1" });
    expect(await deleted.json()).toEqual({ objectId, rev: 2 });
    // Repeating the delete (lost response) is harmless.
    expect(await (await call(harness, user, "DELETE", `/v1/sync/objects/${objectId}`, { "if-match": "2" })).json()).toEqual({ objectId, rev: 2 });
    await expectError(await call(harness, user, "GET", `/v1/sync/objects/${objectId}`, {}), 404, "not_found");
    await expectError(await call(harness, user, "DELETE", `/v1/sync/objects/${randomId()}`, { "if-match": "0" }), 404, "not_found");
    expect(await blobKeys(user.session.userId)).toEqual([]);
    const feed: ChangesBody = await changes(harness, user, "since=0");
    expect(feed.changes).toEqual([{ objectId, kind: "ask.chat", rev: 2, size: 0, deleted: true, updatedAt: harness.clock.nowMs }]);
    const account = await (await call(harness, user, "GET", "/v1/sync/account", {})).json<{ objects: number; storedBytes: number }>();
    expect(account).toMatchObject({ objects: 0, storedBytes: 0 });
    expect(await putRev(harness, user, objectId, "ask.chat", 2)).toBe(3);
  });

  it("writing needs access, reading and deleting do not", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const objectId: string = randomId();
    await putRev(harness, user, objectId, "meeting.state", 0);
    await env.DB.prepare("UPDATE subscriptions SET status = 'canceled', current_period_end = ? WHERE user_id = ?").bind(harness.clock.nowMs - dayMs, user.session.userId).run();
    await expectError(await put(harness, user, objectId, "meeting.state", 1, blob(user.keyId, 1, 64)), 402, "subscription_required");
    expect((await call(harness, user, "GET", `/v1/sync/objects/${objectId}`, {})).status).toBe(200);
    expect((await changes(harness, user, "since=0")).changes).toHaveLength(1);
    expect((await call(harness, user, "DELETE", `/v1/sync/objects/${objectId}`, { "if-match": "1" })).status).toBe(200);
  });
});

describe("/v1/sync/changes", () => {
  it("pages in revision order and refuses stale cursors", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const ids: string[] = [randomId(), randomId(), randomId()];
    for (const id of ids) {
      await putRev(harness, user, id, "meeting.state", 0);
    }
    await putRev(harness, user, ids[0] ?? "", "meeting.state", 1);
    const first: ChangesBody = await changes(harness, user, "since=0&limit=2");
    expect(first.changes.map((change) => change.rev)).toEqual([2, 3]);
    expect(first).toMatchObject({ keyId: user.keyId, cursor: 3, hasMore: true });
    const second: ChangesBody = await changes(harness, user, `since=${first.cursor}&limit=2&epoch=${first.epoch}`);
    expect(second.changes.map((change) => [change.objectId, change.rev])).toEqual([[ids[0], 4]]);
    expect(second).toMatchObject({ cursor: 4, hasMore: false });
    const idle: ChangesBody = await changes(harness, user, `since=4&epoch=${first.epoch}`);
    expect(idle).toMatchObject({ changes: [], cursor: 4, hasMore: false });

    await expectError(await call(harness, user, "GET", "/v1/sync/changes?since=2", {}), 410, "sync_cursor_expired");
    await expectError(await call(harness, user, "GET", `/v1/sync/changes?since=2&epoch=${first.epoch + 1}`, {}), 410, "sync_cursor_expired");
    await expectError(await call(harness, user, "GET", `/v1/sync/changes?since=99&epoch=${first.epoch}`, {}), 410, "sync_cursor_expired");
    await expectError(await call(harness, user, "GET", "/v1/sync/changes?since=0&limit=5000", {}), 400, "bad_request");
    await env.DB.prepare("UPDATE sync_accounts SET purged_through_rev = 3 WHERE user_id = ?").bind(user.session.userId).run();
    await expectError(await call(harness, user, "GET", `/v1/sync/changes?since=2&epoch=${first.epoch}`, {}), 410, "sync_cursor_expired");
    // A full listing (started at 0 after the expiry) pages past the purged tombstones; the epoch still has to match.
    const listed: ChangesBody = await changes(harness, user, `since=2&limit=2&epoch=${first.epoch}&listing=full`);
    expect(listed.changes.map((change) => change.rev)).toEqual([3, 4]);
    await expectError(await call(harness, user, "GET", `/v1/sync/changes?since=2&epoch=${first.epoch + 1}&listing=full`, {}), 410, "sync_cursor_expired");
    await expectError(await call(harness, user, "GET", "/v1/sync/changes?since=0&listing=partial", {}), 400, "bad_request");
  });
});

describe("/v1/sync/envelopes", () => {
  it("keeps one recovery envelope, expires pairing envelopes and caps their number", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const putEnvelope = (id: string, kind: string, ciphertext: string): Promise<Response> =>
      harness.call(req("PUT", `/v1/sync/envelopes/${id}`, { token: user.session.accessToken, json: { kind, ciphertext }, env: syncEnv }));
    const list = async (): Promise<Array<{ envelopeId: string; kind: string; ciphertext: string; expiresAt: number | null }>> =>
      (await (await call(harness, user, "GET", "/v1/sync/envelopes", {})).json<{ envelopes: Array<{ envelopeId: string; kind: string; ciphertext: string; expiresAt: number | null }> }>())
        .envelopes;
    const recoveryA: string = randomId();
    const recoveryB: string = randomId();
    const pairing: string = randomId();
    expect((await putEnvelope(recoveryA, "recovery", "QUFBQQ==")).status).toBe(200);
    expect((await putEnvelope(recoveryB, "recovery", "QkJCQg==")).status).toBe(200);
    expect((await putEnvelope(pairing, "pairing", "Q0NDQw==")).status).toBe(200);
    expect((await list()).map((entry) => [entry.envelopeId, entry.kind, entry.expiresAt]).sort((left, right) => String(left[1]).localeCompare(String(right[1])))).toEqual([
      [pairing, "pairing", harness.clock.nowMs + 10 * 60_000],
      [recoveryB, "recovery", null],
    ]);
    await expectError(await putEnvelope(randomId(), "device", "QUFBQQ=="), 400, "invalid_body");
    await expectError(await putEnvelope(randomId(), "pairing", "not base64!"), 400, "invalid_body");
    harness.clock.nowMs += 11 * 60_000;
    expect((await list()).map((entry) => entry.envelopeId)).toEqual([recoveryB]);
    for (let index: number = 0; index < syncAccountMaxEnvelopes - 1; index += 1) {
      expect((await putEnvelope(randomId(), "pairing", "QUFBQQ==")).status).toBe(200);
    }
    await expectError(await putEnvelope(randomId(), "pairing", "QUFBQQ=="), 413, "sync_quota_exceeded");
    expect(await (await call(harness, user, "DELETE", `/v1/sync/envelopes/${recoveryB}`, {})).json()).toEqual({ deleted: true });
    expect(await (await call(harness, user, "DELETE", `/v1/sync/envelopes/${recoveryB}`, {})).json()).toEqual({ deleted: false });
  });
});

describe("sync cleanup and account deletion", () => {
  it("account deletion removes the sync index and blobs immediately", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncTrialUser(harness);
    await putRev(harness, user, randomId(), "meeting.state", 0);
    expect((await harness.call(req("DELETE", "/v1/me", { token: user.session.accessToken }))).status).toBe(200);
    expect(await blobKeys(user.session.userId)).toEqual([]);
    expect(await count("SELECT COUNT(*) AS count FROM sync_objects WHERE user_id = ?", user.session.userId)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_accounts WHERE user_id = ?", user.session.userId)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_purges WHERE prefix = 'u/' || ? || '/'", user.session.userId)).toBe(0);
  });

  it("removes 90-day-old tombstones (cursors before them must resync) and expired pairing envelopes", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const old: string = randomId();
    const recent: string = randomId();
    await putRev(harness, user, old, "ask.chat", 0);
    await call(harness, user, "DELETE", `/v1/sync/objects/${old}`, { "if-match": "1" });
    // The first tombstone is 91 days old (sessions would expire if the clock moved instead).
    await env.DB.prepare("UPDATE sync_objects SET updated_at = ? WHERE object_id = ?").bind(harness.clock.nowMs - 91 * dayMs, old).run();
    await putRev(harness, user, recent, "ask.chat", 0);
    await call(harness, user, "DELETE", `/v1/sync/objects/${recent}`, { "if-match": "3" });
    await harness.call(req("PUT", `/v1/sync/envelopes/${randomId()}`, { token: user.session.accessToken, json: { kind: "pairing", ciphertext: "QUFBQQ==" }, env: syncEnv }));
    const report = await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs + 11 * 60_000), { batchSize: 1000, maxBatchesPerTable: 3 });
    // Counts include other tests' rows in this file's database; this user's rows are checked below.
    expect(report["sync_tombstones"]).toBeGreaterThanOrEqual(1);
    expect(report["sync_key_envelopes"]).toBeGreaterThanOrEqual(1);
    expect(await count("SELECT COUNT(*) AS count FROM sync_key_envelopes WHERE user_id = ?", user.session.userId)).toBe(0);
    const left = await env.DB.prepare("SELECT object_id FROM sync_objects WHERE user_id = ?").bind(user.session.userId).all<{ object_id: string }>();
    expect(left.results.map((row) => row.object_id)).toEqual([recent]);
    const account = await env.DB.prepare("SELECT purged_through_rev, enabled_at FROM sync_accounts WHERE user_id = ?").bind(user.session.userId).first<{ purged_through_rev: number; enabled_at: number }>();
    expect(account?.purged_through_rev).toBe(2);
    await expectError(await call(harness, user, "GET", `/v1/sync/changes?since=1&epoch=${account?.enabled_at ?? 0}`, {}), 410, "sync_cursor_expired");
    expect((await changes(harness, user, `since=2&epoch=${account?.enabled_at ?? 0}`)).changes.map((change) => change.objectId)).toEqual([recent]);
  });

  it("wipes the copy 90 days after access ended, keeps it while entitled, and finishes queued R2 deletions", async () => {
    const harness: Harness = await defaultHarness();
    const config = parseConfig(env);
    const lapsed: SyncUser = await syncUser(harness);
    const reader: SyncUser = await syncUser(harness);
    await putRev(harness, lapsed, randomId(), "meeting.state", 0);
    await putRev(harness, reader, randomId(), "meeting.state", 0);
    const later: Date = new Date(harness.clock.nowMs + 91 * dayMs);
    // The lapsed account's subscription ended; the reader still pays but only read for 90 days.
    await env.DB.prepare("UPDATE subscriptions SET current_period_end = ?, cancel_at = ? WHERE user_id = ?").bind(harness.clock.nowMs, harness.clock.nowMs, lapsed.session.userId).run();
    await env.DB.prepare("UPDATE subscriptions SET current_period_end = ? WHERE user_id = ?").bind(later.getTime() + 30 * dayMs, reader.session.userId).run();
    // A prefix left behind by an earlier failed purge.
    const orphanPrefix: string = syncPrefix(`orphan-${randomId()}`);
    await env.SYNC_BUCKET.put(`${orphanPrefix}x/y`, new Uint8Array([1, 2, 3]));
    await env.DB.prepare("INSERT INTO sync_purges (prefix, requested_at) VALUES (?, ?)").bind(orphanPrefix, harness.clock.nowMs).run();

    const report = await syncCleanup(env.DB, env.SYNC_BUCKET, config, later, scheduledSyncCleanupLimits);
    expect(report.retentionWiped).toBeGreaterThanOrEqual(1);
    expect(await count("SELECT COUNT(*) AS count FROM sync_accounts WHERE user_id = ?", lapsed.session.userId)).toBe(0);
    expect(await blobKeys(lapsed.session.userId)).toEqual([]);
    const kept = await env.DB.prepare("SELECT access_seen_at FROM sync_accounts WHERE user_id = ?").bind(reader.session.userId).first<{ access_seen_at: number }>();
    expect(kept?.access_seen_at).toBe(later.getTime());
    expect(await blobKeys(reader.session.userId)).toHaveLength(1);
    expect((await env.SYNC_BUCKET.list({ prefix: orphanPrefix })).objects).toEqual([]);
    expect(await env.DB.prepare("SELECT COUNT(*) AS count FROM sync_purges WHERE prefix = ?").bind(orphanPrefix).first<{ count: number }>()).toEqual({ count: 0 });
  });

  it("the retention wipe removes nothing when access came back or sync was reset after the cleanup read the account", async () => {
    const harness: Harness = await defaultHarness();
    const cutoff: number = harness.clock.nowMs - 90 * dayMs;
    const stale = async (user: SyncUser): Promise<number> => {
      // Unseen with access for 91 days, as the cleanup reads it.
      await env.DB.prepare("UPDATE sync_accounts SET access_seen_at = ? WHERE user_id = ?").bind(harness.clock.nowMs - 91 * dayMs, user.session.userId).run();
      const row = await env.DB.prepare("SELECT enabled_at FROM sync_accounts WHERE user_id = ?").bind(user.session.userId).first<{ enabled_at: number }>();
      return row?.enabled_at ?? 0;
    };
    const wipe = async (user: SyncUser, epoch: number): Promise<number> => {
      const results: D1Result[] = await env.DB.batch(syncRetentionWipeStatements(env.DB, user.session.userId, epoch, cutoff, new Date(harness.clock.nowMs)));
      return results.reduce((sum: number, result: D1Result): number => sum + result.meta.changes, 0);
    };
    const queued = async (user: SyncUser): Promise<number> => count("SELECT COUNT(*) AS count FROM sync_purges WHERE prefix LIKE ? || '%'", syncPrefix(user.session.userId));

    // The user writes between the cleanup's read and its wipe: the fresh object stays.
    const writer: SyncUser = await syncUser(harness);
    const epoch: number = await stale(writer);
    const fresh: string = randomId();
    await putRev(harness, writer, fresh, "meeting.state", 0);
    expect(await wipe(writer, epoch)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_objects WHERE user_id = ?", writer.session.userId)).toBe(1);
    expect(await blobKeys(writer.session.userId)).toHaveLength(1);
    expect(await queued(writer)).toBe(0);

    // Sync was turned off and on again (a new epoch) in between: the new epoch's copy stays.
    const resetter: SyncUser = await syncUser(harness);
    const oldEpoch: number = await stale(resetter);
    await env.DB.prepare("UPDATE sync_accounts SET enabled_at = enabled_at + 1 WHERE user_id = ?").bind(resetter.session.userId).run();
    expect(await wipe(resetter, oldEpoch)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_accounts WHERE user_id = ?", resetter.session.userId)).toBe(1);
    expect(await queued(resetter)).toBe(0);

    // Unchanged since the read: the copy is wiped and the epoch queued for R2 deletion.
    const lapsed: SyncUser = await syncUser(harness);
    await putRev(harness, lapsed, randomId(), "meeting.state", 0);
    const lapsedEpoch: number = await stale(lapsed);
    expect(await wipe(lapsed, lapsedEpoch)).toBe(3);
    expect(await count("SELECT COUNT(*) AS count FROM sync_accounts WHERE user_id = ?", lapsed.session.userId)).toBe(0);
    expect(await count("SELECT COUNT(*) AS count FROM sync_objects WHERE user_id = ?", lapsed.session.userId)).toBe(0);
    expect(await queued(lapsed)).toBe(1);
  });
});

/** Replacements for some of an R2 binding's methods (the rest stay the real local binding's). */
interface BucketOverrides {
  readonly put?: (key: string, value: Uint8Array) => Promise<R2Object | null>;
  readonly delete?: (keys: string | string[]) => Promise<void>;
}

/** The real local `SYNC_BUCKET` with `overrides` in place of some methods. */
function interceptedBucket(overrides: BucketOverrides): R2Bucket {
  return new Proxy(env.SYNC_BUCKET, {
    get(target: R2Bucket, property: string | symbol): unknown {
      const override: unknown = Reflect.get(overrides, property);
      if (override !== undefined) {
        return override;
      }
      const member: unknown = Reflect.get(target, property);
      return typeof member === "function" ? member.bind(target) : member;
    },
  });
}

function envWithBucket(bucket: R2Bucket): Env {
  return envWith({ SYNC_USER_LIMITER: allowingLimiter, SYNC_BUCKET: bucket });
}

function putWith(harness: Harness, user: SyncUser, bucket: R2Bucket, objectId: string, baseRev: number, body: Uint8Array): Promise<Response> {
  return harness.call(
    req("PUT", `/v1/sync/objects/${objectId}`, {
      token: user.session.accessToken,
      headers: { "content-type": "application/octet-stream", "if-match": String(baseRev), "x-sync-kind": "meeting.state" },
      body,
      env: envWithBucket(bucket),
    }),
  );
}

interface IndexedObject {
  readonly rev: number;
  readonly r2_key: string | null;
}

async function indexed(userId: string, objectId: string): Promise<IndexedObject | null> {
  return env.DB.prepare("SELECT rev, r2_key FROM sync_objects WHERE user_id = ? AND object_id = ?").bind(userId, objectId).first<IndexedObject>();
}

async function accountCounters(userId: string): Promise<unknown> {
  return env.DB.prepare("SELECT last_rev, object_count, stored_bytes FROM sync_accounts WHERE user_id = ?").bind(userId).first();
}

describe("sync publication boundaries (real D1/R2, fresh requests)", () => {
  it("two writes of one object after both uploaded: the CAS loser deletes only its own blob", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const objectId: string = randomId();
    await putRev(harness, user, objectId, "meeting.state", 0);
    const winner: Uint8Array = blob(user.keyId, 1, 80);
    const loserKeys: string[] = [];
    // The loser passes the revision check and uploads; the winner's whole write commits between that upload and the
    // loser's D1 transaction.
    const racing: R2Bucket = interceptedBucket({
      put: async (key: string, value: Uint8Array): Promise<R2Object | null> => {
        loserKeys.push(key);
        expect((await put(harness, user, objectId, "meeting.state", 1, winner)).status).toBe(200);
        return env.SYNC_BUCKET.put(key, value);
      },
    });
    await expectError(await putWith(harness, user, racing, objectId, 1, blob(user.keyId, 1, 64)), 409, "sync_conflict");

    const row: IndexedObject | null = await indexed(user.session.userId, objectId);
    expect(row?.rev).toBe(2);
    expect(loserKeys).toHaveLength(1);
    expect(row?.r2_key).not.toBe(loserKeys[0]);
    // Only the winner's blob is left: the loser removed its own upload, the winner removed the replaced one.
    expect(await blobKeys(user.session.userId)).toEqual([row?.r2_key]);
    expect(await accountCounters(user.session.userId)).toEqual({ last_rev: 2, object_count: 1, stored_bytes: winner.byteLength });
    const read: Response = await call(harness, user, "GET", `/v1/sync/objects/${objectId}`, {});
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(winner);
  });

  it("a write cut off after its upload or after its publication leaves a consistent index; the stray blob waits for the epoch purge", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const userId: string = user.session.userId;
    const epoch: number = harness.clock.nowMs;
    const objectId: string = randomId();
    // The blob is stored, then the Worker stops before the D1 transaction.
    const stopsAfterUpload: R2Bucket = interceptedBucket({
      put: async (key: string, value: Uint8Array): Promise<R2Object | null> => {
        await env.SYNC_BUCKET.put(key, value);
        throw new Error("worker stopped after the upload");
      },
    });
    await expectError(await putWith(harness, user, stopsAfterUpload, objectId, 0, blob(user.keyId, 0, 64)), 500, "internal_error");
    expect(await indexed(userId, objectId)).toBeNull();
    expect(await accountCounters(userId)).toEqual({ last_rev: 0, object_count: 0, stored_bytes: 0 });
    const strayUpload: string[] = await blobKeys(userId);
    expect(strayUpload).toHaveLength(1);

    // A fresh harness (nothing carried over but D1 and R2) retries the write from the same base.
    const fresh: Harness = await defaultHarness();
    expect(await putRev(fresh, user, objectId, "meeting.state", 0)).toBe(1);
    const replaced: IndexedObject | null = await indexed(userId, objectId);

    // The next write commits in D1, then the Worker stops before deleting the replaced blob.
    const stopsBeforeOldDelete: R2Bucket = interceptedBucket({
      delete: async (): Promise<void> => {
        throw new Error("worker stopped before the replaced blob's delete");
      },
    });
    const next: Uint8Array = blob(user.keyId, 1, 96);
    await expectError(await putWith(fresh, user, stopsBeforeOldDelete, objectId, 1, next), 500, "internal_error");
    const current: IndexedObject | null = await indexed(userId, objectId);
    expect(current?.rev).toBe(2);
    expect(current?.r2_key).not.toBe(replaced?.r2_key);
    expect(await accountCounters(userId)).toEqual({ last_rev: 2, object_count: 1, stored_bytes: next.byteLength });
    // The device's retry from the old base conflicts; it then reads the published revision.
    await expectError(await put(fresh, user, objectId, "meeting.state", 1, blob(user.keyId, 1, 64)), 409, "sync_conflict");
    const read: Response = await call(fresh, user, "GET", `/v1/sync/objects/${objectId}`, {});
    expect(read.headers.get("x-sync-rev")).toBe("2");
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(next);

    // No D1 row names either stray blob, and no queue records it, so the daily cleanup does not find it (open in P21).
    // It is under the live epoch's prefix: turning sync off (like the retention wipe or account deletion) removes it.
    await syncCleanup(env.DB, env.SYNC_BUCKET, parseConfig(env), new Date(fresh.clock.nowMs), scheduledSyncCleanupLimits);
    expect((await blobKeys(userId)).sort()).toEqual([...strayUpload, replaced?.r2_key, current?.r2_key].sort());
    expect((await blobKeys(userId)).every((key: string): boolean => key.startsWith(syncEpochPrefix(userId, epoch)))).toBe(true);
    expect((await call(fresh, user, "DELETE", "/v1/sync/account", {})).status).toBe(200);
    expect(await blobKeys(userId)).toEqual([]);
  });

  it("opting out refuses reads at once; a purge that failed stays queued and a later cleanup removes only the old epoch", async () => {
    const harness: Harness = await defaultHarness();
    const user: SyncUser = await syncUser(harness);
    const userId: string = user.session.userId;
    const oldEpoch: number = harness.clock.nowMs;
    const oldObject: string = randomId();
    await putRev(harness, user, oldObject, "meeting.state", 0);
    await putRev(harness, user, randomId(), "people", 0);
    const failingDeletes: R2Bucket = interceptedBucket({
      delete: async (): Promise<void> => {
        throw new Error("R2 unavailable");
      },
    });
    const optOut: Response = await harness.call(req("DELETE", "/v1/sync/account", { token: user.session.accessToken, env: envWithBucket(failingDeletes) }));
    expect(await optOut.json()).toEqual({ deleted: true, objects: 2 });
    // The blobs are still in R2, but no D1 row names them any more: nothing can read them.
    expect(await blobKeys(userId)).toHaveLength(2);
    expect(await count("SELECT COUNT(*) AS count FROM sync_objects WHERE user_id = ?", userId)).toBe(0);
    await expectError(await call(harness, user, "GET", `/v1/sync/objects/${oldObject}`, {}), 409, "sync_not_enabled");
    await expectError(await call(harness, user, "GET", "/v1/sync/changes?since=0", {}), 409, "sync_not_enabled");
    expect(await count("SELECT COUNT(*) AS count FROM sync_purges WHERE prefix = ?", syncEpochPrefix(userId, oldEpoch))).toBe(1);

    // Sync is turned on again (a new epoch) and writes before the cleanup runs.
    harness.clock.nowMs += 1000;
    const keyId: string = newKeyId();
    expect((await harness.call(req("POST", "/v1/sync/account", { token: user.session.accessToken, json: { keyId }, env: syncEnv }))).status).toBe(200);
    const again: SyncUser = { session: user.session, keyId };
    const newObject: string = randomId();
    await putRev(harness, again, newObject, "meeting.state", 0);

    const report = await syncCleanup(env.DB, env.SYNC_BUCKET, parseConfig(env), new Date(harness.clock.nowMs), scheduledSyncCleanupLimits);
    expect(report.purgedBlobs).toBeGreaterThanOrEqual(2);
    expect(await count("SELECT COUNT(*) AS count FROM sync_purges WHERE prefix = ?", syncEpochPrefix(userId, oldEpoch))).toBe(0);
    expect(await blobKeys(userId)).toEqual([(await indexed(userId, newObject))?.r2_key]);
    expect((await call(harness, again, "GET", `/v1/sync/objects/${newObject}`, {})).status).toBe(200);
  });
});
