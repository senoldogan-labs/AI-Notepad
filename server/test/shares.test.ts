import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { adminOperations } from "../src/adminOps";
import { cleanupExpiredRows, scheduledCleanupLimits } from "../src/cleanup";
import { parseConfig } from "../src/config";
import type { Env } from "../src/env";
import { shareMaxActivePerUser, shareMaxBytes, shareStoredBytesBudget } from "../src/shares";
import { type Harness, type Session, blockingLimiter, defaultHarness, envWith, expectError, grantSubscription, refreshed, req, signIn } from "./helpers";

const allowingLimiter: RateLimit = {
  limit: async (): Promise<RateLimitOutcome> => ({ success: true }),
};
/** Share requests in tests skip the per-user and per-IP limiters (a test sends more than a person does in a minute). */
const shareEnv: Env = envWith({ START_USER_LIMITER: allowingLimiter, SHARE_IP_LIMITER: allowingLimiter });
const dayMs: number = 86_400_000;
const siteOrigin: string = "http://localhost:8788";

/** A random share id in the client's form (16 bytes, base64url, 22 characters). */
function newShareId(): string {
  const bytes: Uint8Array = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

/** A blob shaped like the client's (`sealNoteShare`): `GSS1`, then random bytes standing in for nonce, ciphertext, tag. */
function blob(bodyBytes: number): Uint8Array {
  const result: Uint8Array = new Uint8Array(4 + bodyBytes);
  result.set(new TextEncoder().encode("GSS1"), 0);
  crypto.getRandomValues(result.subarray(4, Math.min(result.byteLength, 4 + 65_536)));
  return result;
}

interface ShareBody {
  readonly shareId: string;
  readonly size: number;
  readonly createdAt: number;
  readonly expiresAt: number;
}

async function subscriber(harness: Harness): Promise<Session> {
  const session: Session = await signIn(harness);
  await grantSubscription(session.userId, "active", harness.clock.nowMs + 30 * dayMs);
  return session;
}

function create(harness: Harness, session: Session, shareId: string, days: string, body: Uint8Array): Promise<Response> {
  return harness.call(
    req("POST", "/v1/shares", {
      token: session.accessToken,
      headers: { "content-type": "application/octet-stream", "x-share-id": shareId, "x-share-expires-days": days },
      body,
      env: shareEnv,
    }),
  );
}

async function created(harness: Harness, session: Session, shareId: string, days: string, body: Uint8Array): Promise<ShareBody> {
  const response: Response = await create(harness, session, shareId, days, body);
  expect(response.status).toBe(201);
  return response.json<ShareBody>();
}

function readPublic(harness: Harness, shareId: string, headers: Record<string, string>): Promise<Response> {
  return harness.call(req("GET", `/v1/public/shares/${shareId}`, { headers, env: shareEnv }));
}

async function list(harness: Harness, session: Session): Promise<{ shares: ShareBody[]; maxActive: number }> {
  const response: Response = await harness.call(req("GET", "/v1/shares", { token: session.accessToken, env: shareEnv }));
  expect(response.status).toBe(200);
  return response.json<{ shares: ShareBody[]; maxActive: number }>();
}

async function storedRows(userId: string): Promise<number> {
  return (await env.DB.prepare("SELECT COUNT(*) AS count FROM note_shares WHERE user_id = ?").bind(userId).first<{ count: number }>())?.count ?? -1;
}

describe("POST /v1/shares", () => {
  it("stores the sealed note, lists it without the ciphertext and serves the exact bytes publicly", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const shareId: string = newShareId();
    const sealed: Uint8Array = blob(400);
    const body: ShareBody = await created(harness, session, shareId, "30", sealed);
    expect(body).toEqual({ shareId, size: sealed.byteLength, createdAt: harness.clock.nowMs, expiresAt: harness.clock.nowMs + 30 * dayMs });

    const listed = await list(harness, session);
    expect(listed).toEqual({ shares: [body], maxActive: shareMaxActivePerUser });

    const response: Response = await readPublic(harness, shareId, { origin: siteOrigin });
    expect(response.status).toBe(200);
    expect(response.headers.get("content-type")).toBe("application/octet-stream");
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(response.headers.get("x-robots-tag")).toBe("noindex, nofollow");
    expect(response.headers.get("referrer-policy")).toBe("no-referrer");
    expect(response.headers.get("access-control-allow-origin")).toBe(siteOrigin);
    expect(new Uint8Array(await response.arrayBuffer())).toEqual(sealed);
  });

  it("accepts 7, 30 and 90 days only", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    expect((await created(harness, session, newShareId(), "7", blob(40))).expiresAt).toBe(harness.clock.nowMs + 7 * dayMs);
    expect((await created(harness, session, newShareId(), "90", blob(40))).expiresAt).toBe(harness.clock.nowMs + 90 * dayMs);
    for (const days of ["1", "31", "365", "abc", ""]) {
      await expectError(await create(harness, session, newShareId(), days, blob(40)), 400, "bad_request");
    }
  });

  it("refuses malformed ids, blobs, media types and bodies over the size cap", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    await expectError(await create(harness, session, "short", "30", blob(40)), 400, "bad_request");
    await expectError(await create(harness, session, `${newShareId().slice(0, 21)}!`, "30", blob(40)), 400, "bad_request");
    await expectError(await create(harness, session, newShareId(), "30", new TextEncoder().encode("GSY1-not-a-share-blob-000000000000")), 400, "invalid_body");
    await expectError(await create(harness, session, newShareId(), "30", blob(10)), 400, "invalid_body");
    await expectError(await create(harness, session, newShareId(), "30", blob(shareMaxBytes)), 413, "payload_too_large");
    expect((await created(harness, session, newShareId(), "30", blob(shareMaxBytes - 4))).size).toBe(shareMaxBytes);
    const wrongType: Response = await harness.call(
      req("POST", "/v1/shares", {
        token: session.accessToken,
        headers: { "content-type": "text/html", "x-share-id": newShareId(), "x-share-expires-days": "30" },
        body: blob(40),
        env: shareEnv,
      }),
    );
    await expectError(wrongType, 415, "unsupported_media_type");
  });

  it("needs a session and a subscription or a running trial", async () => {
    const harness: Harness = await defaultHarness();
    const anonymous: Response = await harness.call(
      req("POST", "/v1/shares", { headers: { "content-type": "application/octet-stream", "x-share-id": newShareId(), "x-share-expires-days": "30" }, body: blob(40), env: shareEnv }),
    );
    await expectError(anonymous, 401, "unauthorized");
    const free: Session = await signIn(harness);
    await expectError(await create(harness, free, newShareId(), "30", blob(40)), 402, "subscription_required");
    await env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(harness.clock.nowMs, free.userId).run();
    await created(harness, free, newShareId(), "30", blob(40));
  });

  it("returns the stored link when the same upload is repeated and refuses another blob under a used id", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const shareId: string = newShareId();
    const first: ShareBody = await created(harness, session, shareId, "30", blob(64));
    harness.clock.nowMs += 5_000;
    expect(await created(harness, session, shareId, "30", blob(64))).toEqual(first);
    await expectError(await create(harness, session, shareId, "30", blob(65)), 409, "share_exists");
    const other: Session = await subscriber(harness);
    await expectError(await create(harness, other, shareId, "30", blob(64)), 409, "share_exists");
    expect(await storedRows(session.userId)).toBe(1);
  });

  // P22 characterization. The server keeps no record of a removed id, so the client must not repeat a create it has
  // already revoked; an expired row is still matched until the daily cleanup deletes it.
  it("a repeated upload after revoke creates the link again; after expiry it returns the expired link", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const revokedId: string = newShareId();
    await created(harness, session, revokedId, "30", blob(64));
    expect((await harness.call(req("DELETE", `/v1/shares/${revokedId}`, { token: session.accessToken, env: shareEnv }))).status).toBe(200);
    const recreated: ShareBody = await created(harness, session, revokedId, "30", blob(64));
    expect(recreated.shareId).toBe(revokedId);
    expect((await readPublic(harness, revokedId, {})).status).toBe(200);

    const expiredId: string = newShareId();
    const first: ShareBody = await created(harness, session, expiredId, "7", blob(64));
    harness.clock.nowMs += 7 * dayMs;
    const later: Session = await refreshed(harness, session);
    const repeated: ShareBody = await created(harness, later, expiredId, "7", blob(64));
    expect(repeated).toEqual(first);
    expect(repeated.expiresAt).toBeLessThanOrEqual(harness.clock.nowMs);
    await expectError(await readPublic(harness, expiredId, {}), 404, "not_found");
  });

  it("caps live links per account; expired links free their place", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const statements: D1PreparedStatement[] = Array.from({ length: shareMaxActivePerUser }, (_: unknown, index: number): D1PreparedStatement =>
      env.DB.prepare("INSERT INTO note_shares (share_id, user_id, ciphertext, size, created_at, expires_at) VALUES (?, ?, ?, 36, ?, ?)").bind(
        newShareId(),
        session.userId,
        blob(32),
        harness.clock.nowMs,
        harness.clock.nowMs + (index === 0 ? 7 : 30) * dayMs,
      ),
    );
    await env.DB.batch(statements);
    await expectError(await create(harness, session, newShareId(), "30", blob(40)), 409, "share_limit_reached");
    harness.clock.nowMs += 8 * dayMs;
    const later: Session = await refreshed(harness, session);
    await created(harness, later, newShareId(), "30", blob(40));
    await expectError(await create(harness, later, newShareId(), "30", blob(40)), 409, "share_limit_reached");
  });

  it("pauses creating once the global storage budget is spent", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const filler: Session = await signIn(harness);
    const fillerId: string = newShareId();
    await env.DB.prepare("INSERT INTO note_shares (share_id, user_id, ciphertext, size, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)")
      .bind(fillerId, filler.userId, blob(32), shareStoredBytesBudget, harness.clock.nowMs, harness.clock.nowMs + dayMs)
      .run();
    try {
      await expectError(await create(harness, session, newShareId(), "30", blob(40)), 503, "share_unavailable");
    } finally {
      await env.DB.prepare("DELETE FROM note_shares WHERE share_id = ?").bind(fillerId).run();
    }
    await created(harness, session, newShareId(), "30", blob(40));
  });
});

describe("GET /v1/public/shares/:id", () => {
  it("answers the same 404 for unknown, malformed, expired and revoked links", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    await expectError(await readPublic(harness, newShareId(), {}), 404, "not_found");
    await expectError(await readPublic(harness, "not-a-share-id", {}), 404, "not_found");

    const expiring: string = newShareId();
    await created(harness, session, expiring, "7", blob(40));
    harness.clock.nowMs += 7 * dayMs;
    // Expired before the daily cleanup ran: already gone for readers and from the owner's list.
    await expectError(await readPublic(harness, expiring, {}), 404, "not_found");
    const later: Session = await refreshed(harness, session);
    expect((await list(harness, later)).shares).toEqual([]);

    const revoked: string = newShareId();
    await created(harness, later, revoked, "30", blob(40));
    expect((await readPublic(harness, revoked, {})).status).toBe(200);
    const deleted: Response = await harness.call(req("DELETE", `/v1/shares/${revoked}`, { token: later.accessToken, env: shareEnv }));
    expect(deleted.status).toBe(200);
    expect(await deleted.json()).toEqual({ deleted: true });
    await expectError(await readPublic(harness, revoked, {}), 404, "not_found");
  });

  it("expired share is denied before physical purge", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const shareId: string = newShareId();
    const body: ShareBody = await created(harness, session, shareId, "7", blob(40));
    harness.clock.nowMs = body.expiresAt - 1;
    expect((await readPublic(harness, shareId, {})).status).toBe(200);
    // The read and the cleanup use the same boundary: from `expiresAt` on the link is unavailable and purgeable.
    harness.clock.nowMs = body.expiresAt;
    await expectError(await readPublic(harness, shareId, {}), 404, "not_found");
    const later: Session = await refreshed(harness, session);
    expect((await list(harness, later)).shares).toEqual([]);
    expect(await storedRows(session.userId)).toBe(1);
    const before = await cleanupExpiredRows(env.DB, new Date(body.expiresAt - 1), scheduledCleanupLimits);
    expect(before["note_shares"] ?? 0).toBe(0);
    expect(await storedRows(session.userId)).toBe(1);
    await cleanupExpiredRows(env.DB, new Date(body.expiresAt), scheduledCleanupLimits);
    expect(await storedRows(session.userId)).toBe(0);
    await expectError(await readPublic(harness, shareId, {}), 404, "not_found");
  });

  it("is rate limited per IP and allows CORS only from the site", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const shareId: string = newShareId();
    await created(harness, session, shareId, "30", blob(40));
    const other: Response = await readPublic(harness, shareId, { origin: "https://evil.example" });
    expect(other.status).toBe(200);
    expect(other.headers.get("access-control-allow-origin")).toBeNull();
    const limited: Response = await harness.call(req("GET", `/v1/public/shares/${shareId}`, { env: envWith({ SHARE_IP_LIMITER: blockingLimiter }) }));
    await expectError(limited, 429, "rate_limited");
  });
});

describe("DELETE /v1/shares/:id", () => {
  it("removes only the owner's link", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Session = await subscriber(harness);
    const stranger: Session = await subscriber(harness);
    const shareId: string = newShareId();
    await created(harness, owner, shareId, "30", blob(40));
    const refused: Response = await harness.call(req("DELETE", `/v1/shares/${shareId}`, { token: stranger.accessToken, env: shareEnv }));
    await expectError(refused, 404, "not_found");
    expect((await readPublic(harness, shareId, {})).status).toBe(200);
    const again: Response = await harness.call(req("DELETE", `/v1/shares/${newShareId()}`, { token: owner.accessToken, env: shareEnv }));
    await expectError(again, 404, "not_found");
    await expectError(await harness.call(req("DELETE", "/v1/shares/bad", { token: owner.accessToken, env: shareEnv })), 404, "not_found");
    expect((await list(harness, stranger)).shares).toEqual([]);
  });

  // P22 characterization. A repeated revoke is `not_found` with no effect (the app treats that as removed). A revoke
  // after expiry deletes the row if the daily cleanup has not, and is `not_found` once it has.
  it("a repeated revoke and a revoke after expiry remove nothing else", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const kept: string = newShareId();
    await created(harness, session, kept, "30", blob(40));
    const revoked: string = newShareId();
    await created(harness, session, revoked, "30", blob(40));
    const revoke = (token: string, shareId: string): Promise<Response> => harness.call(req("DELETE", `/v1/shares/${shareId}`, { token, env: shareEnv }));
    expect((await revoke(session.accessToken, revoked)).status).toBe(200);
    await expectError(await revoke(session.accessToken, revoked), 404, "not_found");
    expect(await storedRows(session.userId)).toBe(1);
    expect((await readPublic(harness, kept, {})).status).toBe(200);

    const expiredBeforePurge: string = newShareId();
    const expiredAfterPurge: string = newShareId();
    await created(harness, session, expiredBeforePurge, "7", blob(40));
    await created(harness, session, expiredAfterPurge, "7", blob(40));
    harness.clock.nowMs += 7 * dayMs;
    const later: Session = await refreshed(harness, session);
    expect((await revoke(later.accessToken, expiredBeforePurge)).status).toBe(200);
    await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs), scheduledCleanupLimits);
    await expectError(await revoke(later.accessToken, expiredAfterPurge), 404, "not_found");
    const left: Array<{ share_id: string }> = (
      await env.DB.prepare("SELECT share_id FROM note_shares WHERE user_id = ?").bind(session.userId).all<{ share_id: string }>()
    ).results;
    expect(left).toEqual([{ share_id: kept }]);
  });
});

describe("share cleanup", () => {
  it("the daily cleanup deletes expired links and keeps live ones", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const live: string = newShareId();
    await created(harness, session, newShareId(), "7", blob(40));
    await created(harness, session, live, "30", blob(40));
    const report = await cleanupExpiredRows(env.DB, new Date(harness.clock.nowMs + 8 * dayMs), scheduledCleanupLimits);
    expect(report["note_shares"]).toBeGreaterThanOrEqual(1);
    const left: Array<{ share_id: string }> = (
      await env.DB.prepare("SELECT share_id FROM note_shares WHERE user_id = ?").bind(session.userId).all<{ share_id: string }>()
    ).results;
    expect(left).toEqual([{ share_id: live }]);
  });

  it("account deletion deletes every link at once", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await env.DB.prepare("UPDATE users SET trial_started_at = ? WHERE id = ?").bind(harness.clock.nowMs, session.userId).run();
    const shareId: string = newShareId();
    await created(harness, session, shareId, "90", blob(40));
    await created(harness, session, newShareId(), "30", blob(40));
    const deleted: Response = await harness.call(req("DELETE", "/v1/me", { token: session.accessToken, env: shareEnv }));
    expect(deleted.status).toBe(200);
    expect(await storedRows(session.userId)).toBe(0);
    await expectError(await readPublic(harness, shareId, {}), 404, "not_found");
  });

  it("admin operations count links without content", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await subscriber(harness);
    const before = (await adminOperations(env.DB, parseConfig(env), new Date(harness.clock.nowMs))).shares;
    await created(harness, session, newShareId(), "30", blob(60));
    const after = (await adminOperations(env.DB, parseConfig(env), new Date(harness.clock.nowMs))).shares;
    expect(after.active - before.active).toBe(1);
    expect(after.storedBytes - before.storedBytes).toBe(64);
    expect(after.storedBytesBudget).toBe(shareStoredBytesBudget);
    expect(Object.keys(after).sort()).toEqual(["active", "owners", "storedBytes", "storedBytesBudget"]);
  });
});
