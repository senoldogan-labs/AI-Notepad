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
});
