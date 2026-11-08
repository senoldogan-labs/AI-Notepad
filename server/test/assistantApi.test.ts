import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { accessLossDeleteDays, assistantCleanup, scheduledAssistantCleanupLimits } from "../src/assistant/cleanup";
import { type AssistantKeyring, parseAssistantKeyring } from "../src/assistant/crypto";
import { assistantAccountMaxBytes } from "../src/assistant/projection";
import {
  type IndexScan,
  assistantEpochPrefix,
  assistantMeeting,
  assistantPrefix,
  disableAssistant,
  disableAssistantAfterAccessLoss,
  indexedMeetings,
} from "../src/assistant/store";
import { parseConfig } from "../src/config";
import { randomId } from "../src/crypto";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantSubscription, req, signIn } from "./helpers";
import { assistantEnv, assistantRows, dayMs, fieldsFor, objectKeys, putMeeting, setAssistant, subscriber, upload } from "./assistantHelpers";

async function ready(harness: Harness): Promise<{ session: Session; epoch: number }> {
  const session: Session = await subscriber(harness, await signIn(harness));
  const settings = await setAssistant(harness, session, true);
  return { session, epoch: settings.epoch };
}

async function insertGrant(userId: string, grantId: string): Promise<void> {
  await env.ASSISTANT_DB.prepare(
    "INSERT INTO assistant_grants (user_id, grant_id, client_id, client_name, redirect_host, verified, created_at) VALUES (?, ?, 'c', 'Claude', 'claude.ai', 1, 0)",
  )
    .bind(userId, grantId)
    .run();
}

describe("assistant settings", () => {
  it("is 503 while ASSISTANT_POLICY is off and 401 without a session", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await expectError(await harness.call(req("GET", "/v1/assistant/settings", { token: session.accessToken, env: envWith({ ASSISTANT_POLICY: "off" }) })), 503, "assistant_unavailable");
    await expectError(await harness.call(req("GET", "/v1/assistant/settings", {})), 401, "unauthorized");
  });

  it("starts off, needs access to turn on, and reports the epoch", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const initial: Response = await harness.call(req("GET", "/v1/assistant/settings", { token: session.accessToken, env: assistantEnv }));
    expect(await initial.json()).toEqual({ enabled: false, epoch: 1, meetings: 0, maxMeetings: 5000 });
    await expectError(
      await harness.call(req("PUT", "/v1/assistant/settings", { token: session.accessToken, json: { enabled: true }, env: assistantEnv })),
      402,
      "subscription_required",
    );
    await subscriber(harness, session);
    expect(await setAssistant(harness, session, true)).toMatchObject({ enabled: true, epoch: 1 });
    // Turning on again keeps the epoch.
    expect(await setAssistant(harness, session, true)).toMatchObject({ enabled: true, epoch: 1 });
  });

  it("turning off deletes the copy and connections at once and moves the epoch", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    const meetingId: string = randomId();
    await putMeeting(harness, session, meetingId, fieldsFor(epoch, "Roadmap"));
    await insertGrant(session.userId, "grant-to-revoke-1");
    expect(await objectKeys(assistantEpochPrefix(session.userId, epoch))).toHaveLength(1);
    const off = await setAssistant(harness, session, false);
    expect(off).toMatchObject({ enabled: false, epoch: epoch + 1, meetings: 0 });
    expect(await objectKeys(assistantPrefix(session.userId))).toEqual([]);
    expect(await assistantRows("assistant_grants", session.userId)).toBe(0);
    expect(await assistantRows("assistant_revocations", session.userId)).toBe(1);
    // Off again is harmless.
    expect(await setAssistant(harness, session, false)).toMatchObject({ enabled: false, epoch: epoch + 1 });
  });
});

describe("assistant meetings", () => {
  it("accepts an upload only while on and at the current epoch", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    const meetingId: string = randomId();
    await putMeeting(harness, session, meetingId, fieldsFor(epoch, "Planning"));
    await setAssistant(harness, session, false);
    await expectError(
      await harness.call(req("PUT", `/v1/assistant/meetings/${meetingId}`, { token: session.accessToken, json: upload(fieldsFor(epoch + 1, "Planning")), env: assistantEnv })),
      409,
      "assistant_not_enabled",
    );
    await setAssistant(harness, session, true);
    // An upload prepared before the switch names the old epoch.
    await expectError(
      await harness.call(req("PUT", `/v1/assistant/meetings/${meetingId}`, { token: session.accessToken, json: upload(fieldsFor(epoch, "Planning")), env: assistantEnv })),
      409,
      "assistant_epoch_mismatch",
    );
    await putMeeting(harness, session, meetingId, fieldsFor(epoch + 1, "Planning"));
  });

  it("refuses an upload whose epoch moved while it was being stored, and leaves no object behind", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    // The bucket turns the feature off between the object write and the D1 row, like a concurrent "off" from another device.
    const racing: R2Bucket = new Proxy(env.ASSISTANT_BUCKET, {
      get(target: R2Bucket, property: string | symbol): unknown {
        if (property === "put") {
          return async (key: string, value: Uint8Array): Promise<R2Object | null> => {
            await disableAssistant(env.ASSISTANT_DB, target, session.userId, new Date(harness.clock.nowMs));
            return target.put(key, value);
          };
        }
        const member: unknown = Reflect.get(target, property);
        return typeof member === "function" ? member.bind(target) : member;
      },
    });
    const response: Response = await harness.call(
      req("PUT", `/v1/assistant/meetings/${randomId()}`, { token: session.accessToken, json: upload(fieldsFor(epoch, "Race")), env: envWith({ ASSISTANT_USER_LIMITER: assistantEnv.ASSISTANT_USER_LIMITER, ASSISTANT_BUCKET: racing }) }),
    );
    await expectError(response, 409, "assistant_epoch_mismatch");
    expect(await objectKeys(assistantPrefix(session.userId))).toEqual([]);
    expect(await assistantRows("assistant_meetings", session.userId)).toBe(0);
  });

  it("keeps two accounts with the same meeting id apart", async () => {
    const harness: Harness = await defaultHarness();
    const first = await ready(harness);
    const second = await ready(harness);
    const meetingId: string = randomId();
    await putMeeting(harness, first.session, meetingId, fieldsFor(first.epoch, "First"));
    await putMeeting(harness, second.session, meetingId, fieldsFor(second.epoch, "Second"));
    const deleted: Response = await harness.call(req("DELETE", `/v1/assistant/meetings/${meetingId}`, { token: first.session.accessToken, env: assistantEnv }));
    expect(await deleted.json()).toEqual({ meetingId, deleted: true });
    expect(await assistantRows("assistant_meetings", first.session.userId)).toBe(0);
    expect(await assistantRows("assistant_meetings", second.session.userId)).toBe(1);
    expect(await objectKeys(assistantPrefix(second.session.userId))).toHaveLength(1);
    expect(await objectKeys(assistantPrefix(first.session.userId))).toEqual([]);
  });

  it("validates ids, fields and sizes", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    const call = (path: string, body: object): Promise<Response> => harness.call(req("PUT", path, { token: session.accessToken, json: body, env: assistantEnv }));
    await expectError(await call("/v1/assistant/meetings/not.an.id", upload(fieldsFor(epoch, "X"))), 400, "bad_request");
    await expectError(await call(`/v1/assistant/meetings/${"a".repeat(65)}`, upload(fieldsFor(epoch, "X"))), 400, "bad_request");
    await expectError(await call(`/v1/assistant/meetings/${randomId()}`, upload({ ...fieldsFor(epoch, "X"), deviceId: "device-1" })), 400, "invalid_body");
    await expectError(await call(`/v1/assistant/meetings/${randomId()}`, upload({ ...fieldsFor(epoch, "X"), startedAt: "yesterday" })), 400, "invalid_body");
    await expectError(await call(`/v1/assistant/meetings/${randomId()}`, upload({ ...fieldsFor(epoch, "X"), summary: "s".repeat(40_001) })), 400, "invalid_body");
    await expectError(await call(`/v1/assistant/meetings/${randomId()}`, { ...upload(fieldsFor(epoch, "X")), transcript: "never" }), 400, "invalid_body");
    const huge: object = { ...upload(fieldsFor(epoch, "X")), myNotes: "m".repeat(600_000) };
    await expectError(await call(`/v1/assistant/meetings/${randomId()}`, huge), 413, "payload_too_large");
    // Upper-case UUIDs (Swift's uuidString) are stored lower-case.
    const upper: string = randomId().toUpperCase();
    expect(await (await call(`/v1/assistant/meetings/${upper}`, upload(fieldsFor(epoch, "Upper")))).json()).toMatchObject({ meetingId: upper.toLowerCase() });
    // The apps' own ids are session folder names; they are stored unchanged.
    expect(await (await call("/v1/assistant/meetings/20261105-103000", upload(fieldsFor(epoch, "Folder id")))).json()).toMatchObject({ meetingId: "20261105-103000" });
  });

  it("deletes a lost device's meetings only", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    const lost: string = randomId();
    await putMeeting(harness, session, randomId(), { ...fieldsFor(epoch, "Lost one"), deviceId: lost });
    await putMeeting(harness, session, randomId(), { ...fieldsFor(epoch, "Lost two"), deviceId: lost });
    await putMeeting(harness, session, randomId(), fieldsFor(epoch, "Kept"));
    await expectError(await harness.call(req("DELETE", "/v1/assistant/devices/abc", { token: session.accessToken, env: assistantEnv })), 400, "bad_request");
    const response: Response = await harness.call(req("DELETE", `/v1/assistant/devices/${lost}`, { token: session.accessToken, env: assistantEnv }));
    expect(await response.json()).toEqual({ deviceId: lost, deletedMeetings: 2 });
    expect(await assistantRows("assistant_meetings", session.userId)).toBe(1);
    expect(await objectKeys(assistantPrefix(session.userId))).toHaveLength(1);
  });

  it("needs access to upload but deleting works without it", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    await grantSubscription(session.userId, "canceled", harness.clock.nowMs + 5 * dayMs);
    await env.DB.prepare("UPDATE subscriptions SET status = 'active', cancel_at = current_period_end WHERE user_id = ?").bind(session.userId).run();
    const { epoch } = await setAssistant(harness, session, true);
    const meetingId: string = randomId();
    await putMeeting(harness, session, meetingId, fieldsFor(epoch, "Before"));
    harness.clock.nowMs += 10 * dayMs;
    await expectError(
      await harness.call(req("PUT", `/v1/assistant/meetings/${randomId()}`, { token: (await signInAgain(harness, session)).accessToken, json: upload(fieldsFor(epoch, "After")), env: assistantEnv })),
      402,
      "subscription_required",
    );
    const fresh: Session = await signInAgain(harness, session);
    expect((await harness.call(req("DELETE", `/v1/assistant/meetings/${meetingId}`, { token: fresh.accessToken, env: assistantEnv }))).status).toBe(200);
  });
});

/** A fresh access token for the same session after the clock moved (refresh). */
async function signInAgain(harness: Harness, session: Session): Promise<Session> {
  const response: Response = await harness.call(req("POST", "/v1/auth/refresh", { json: { refreshToken: session.refreshToken } }));
  expect(response.status).toBe(200);
  const next: Session = await response.json<Session>();
  Object.assign(session, { refreshToken: next.refreshToken, accessToken: next.accessToken });
  return next;
}

/** A row that takes `bytes` of the account's quota without an object (the quota counts rows, not R2). */
async function insertFiller(userId: string, bytes: number): Promise<void> {
  await env.ASSISTANT_DB.prepare(
    "INSERT INTO assistant_meetings (user_id, meeting_id, device_id, started_at, updated_at, size, index_ct, object_id) VALUES (?, ?, ?, 0, 0, ?, X'00', 'filler')",
  )
    .bind(userId, randomId(), randomId(), bytes)
    .run();
}

describe("assistant storage limits", () => {
  it("refuses an upload past the account's byte quota and leaves no object behind", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    await insertFiller(session.userId, assistantAccountMaxBytes - 1000);
    const response: Response = await harness.call(
      req("PUT", `/v1/assistant/meetings/${randomId()}`, { token: session.accessToken, json: upload(fieldsFor(epoch, "Over")), env: assistantEnv }),
    );
    await expectError(response, 413, "assistant_quota_exceeded");
    expect(await objectKeys(assistantPrefix(session.userId))).toEqual([]);
  });

  it("lets only one of two parallel uploads take the last free space", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    // Same title length as the parallel uploads, so all three seal to the same size.
    await putMeeting(harness, session, randomId(), fieldsFor(epoch, "Parallel abc"));
    const used = await env.ASSISTANT_DB.prepare("SELECT size + LENGTH(index_ct) AS bytes FROM assistant_meetings WHERE user_id = ?").bind(session.userId).first<{ bytes: number }>();
    // Room for one more meeting of the same size, not two.
    await insertFiller(session.userId, assistantAccountMaxBytes - 2 * (used?.bytes ?? 0) - 1 - 50);
    const responses: Response[] = await Promise.all(
      ["Parallel one", "Parallel two"].map((title: string): Promise<Response> =>
        harness.call(req("PUT", `/v1/assistant/meetings/${randomId()}`, { token: session.accessToken, json: upload(fieldsFor(epoch, title)), env: assistantEnv })),
      ),
    );
    expect(responses.map((response: Response): number => response.status).sort()).toEqual([200, 413]);
    expect(await objectKeys(assistantPrefix(session.userId))).toHaveLength(2);
  });

  it("keeps the stored note readable when an update is refused", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    const meetingId: string = randomId();
    await putMeeting(harness, session, meetingId, fieldsFor(epoch, "Original"));
    await insertFiller(session.userId, assistantAccountMaxBytes - 1000);
    const bigger = { ...fieldsFor(epoch, "Rewritten"), summary: "r".repeat(30_000) };
    await expectError(await harness.call(req("PUT", `/v1/assistant/meetings/${meetingId}`, { token: session.accessToken, json: upload(bigger), env: assistantEnv })), 413, "assistant_quota_exceeded");
    const keyring: AssistantKeyring = parseAssistantKeyring(env.ASSISTANT_DATA_KEY);
    expect((await assistantMeeting(env.ASSISTANT_DB, env.ASSISTANT_BUCKET, keyring, session.userId, meetingId))?.title).toBe("Original");
    expect(await objectKeys(assistantPrefix(session.userId))).toHaveLength(1);
    // A successful update replaces the object (the old one is deleted).
    await env.ASSISTANT_DB.prepare("DELETE FROM assistant_meetings WHERE user_id = ? AND object_id = 'filler'").bind(session.userId).run();
    await putMeeting(harness, session, meetingId, bigger);
    expect((await assistantMeeting(env.ASSISTANT_DB, env.ASSISTANT_BUCKET, keyring, session.userId, meetingId))?.title).toBe("Rewritten");
    expect(await objectKeys(assistantPrefix(session.userId))).toHaveLength(1);
  });

  it("decrypts at most the scan's byte budget of index rows, newest first", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    for (const day of [1, 2, 3]) {
      await putMeeting(harness, session, randomId(), { ...fieldsFor(epoch, `Day ${day}`), startedAt: `2026-10-0${day}T09:00:00+00:00` });
    }
    const sizes = await env.ASSISTANT_DB.prepare("SELECT LENGTH(index_ct) AS bytes FROM assistant_meetings WHERE user_id = ? ORDER BY started_at DESC").bind(session.userId).all<{ bytes: number }>();
    const twoNewest: number = (sizes.results[0]?.bytes ?? 0) + (sizes.results[1]?.bytes ?? 0);
    const keyring: AssistantKeyring = parseAssistantKeyring(env.ASSISTANT_DATA_KEY);
    const bounds = { sinceMs: null, untilMs: null, before: null };
    const scan: IndexScan = await indexedMeetings(env.ASSISTANT_DB, keyring, session.userId, bounds, { rows: 2000, bytes: twoNewest });
    expect(scan.meetings.map((meeting) => meeting.index.title)).toEqual(["Day 3", "Day 2"]);
    expect(scan.truncated).toBe(true);
    const byRows: IndexScan = await indexedMeetings(env.ASSISTANT_DB, keyring, session.userId, bounds, { rows: 1, bytes: 1_000_000 });
    expect(byRows.meetings).toHaveLength(1);
    expect(byRows.truncated).toBe(true);
    const all: IndexScan = await indexedMeetings(env.ASSISTANT_DB, keyring, session.userId, bounds, { rows: 3, bytes: 1_000_000 });
    expect(all.meetings).toHaveLength(3);
    expect(all.truncated).toBe(false);
  });

  it("scopes device ids by account: deleting a device never touches another account's meetings", async () => {
    const harness: Harness = await defaultHarness();
    const first = await ready(harness);
    const second = await ready(harness);
    const deviceId: string = randomId();
    await putMeeting(harness, first.session, randomId(), { ...fieldsFor(first.epoch, "Mine"), deviceId });
    await putMeeting(harness, second.session, randomId(), { ...fieldsFor(second.epoch, "Theirs"), deviceId });
    const response: Response = await harness.call(req("DELETE", `/v1/assistant/devices/${deviceId}`, { token: first.session.accessToken, env: assistantEnv }));
    expect(await response.json()).toEqual({ deviceId, deletedMeetings: 1 });
    expect(await assistantRows("assistant_meetings", second.session.userId)).toBe(1);
    expect(await objectKeys(assistantPrefix(second.session.userId))).toHaveLength(1);
  });
});

describe("assistant grants", () => {
  it("lists and disconnects connections, queueing the KV revocation", async () => {
    const harness: Harness = await defaultHarness();
    const { session } = await ready(harness);
    await insertGrant(session.userId, "grant-aaaaaaaaaaa1");
    const listed: Response = await harness.call(req("GET", "/v1/assistant/grants", { token: session.accessToken, env: assistantEnv }));
    expect(await listed.json()).toEqual({
      grants: [{ grantId: "grant-aaaaaaaaaaa1", clientName: "Claude", redirectHost: "claude.ai", verified: true, createdAt: new Date(0).toISOString(), lastUsedAt: null, heavyReadAt: null }],
    });
    const other: Session = await signIn(harness);
    const foreign: Response = await harness.call(req("DELETE", "/v1/assistant/grants/grant-aaaaaaaaaaa1", { token: other.accessToken, env: assistantEnv }));
    expect(await foreign.json()).toEqual({ grantId: "grant-aaaaaaaaaaa1", deleted: false });
    const own: Response = await harness.call(req("DELETE", "/v1/assistant/grants/grant-aaaaaaaaaaa1", { token: session.accessToken, env: assistantEnv }));
    expect(await own.json()).toEqual({ grantId: "grant-aaaaaaaaaaa1", deleted: true });
    expect(await assistantRows("assistant_revocations", session.userId)).toBe(1);
    await expectError(await harness.call(req("DELETE", "/v1/assistant/grants/a b", { token: session.accessToken, env: assistantEnv })), 400, "bad_request");
  });
});

describe("assistant copy lifecycle", () => {
  it("account deletion removes the whole copy", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    await putMeeting(harness, session, randomId(), fieldsFor(epoch, "Doomed"));
    await insertGrant(session.userId, "grant-deleteaccount");
    // No Stripe subscription to cancel (that path is covered by account.test.ts).
    await env.DB.batch([
      env.DB.prepare("DELETE FROM subscriptions WHERE user_id = ?").bind(session.userId),
      env.DB.prepare("DELETE FROM stripe_customers WHERE user_id = ?").bind(session.userId),
    ]);
    const response: Response = await harness.call(req("DELETE", "/v1/me", { token: session.accessToken }));
    expect(response.status).toBe(200);
    for (const table of ["assistant_settings", "assistant_meetings", "assistant_grants"]) {
      expect(await assistantRows(table, session.userId)).toBe(0);
    }
    expect(await assistantRows("assistant_revocations", session.userId)).toBe(1);
    expect(await objectKeys(assistantPrefix(session.userId))).toEqual([]);
  });

  it("daily cleanup deletes the copy within 7 days of access ending and removes orphans", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    await putMeeting(harness, session, randomId(), fieldsFor(epoch, "Lapsing"));
    const orphan: string = randomId();
    await env.ASSISTANT_DB.prepare("INSERT INTO assistant_settings (user_id, enabled, epoch, updated_at, access_checked_at) VALUES (?, 1, 1, 0, 0)").bind(orphan).run();
    await env.ASSISTANT_BUCKET.put(`${assistantEpochPrefix(orphan, 1)}${randomId()}`, new Uint8Array([1]));
    const config = parseConfig(env);
    const run = (offsetDays: number) => assistantCleanup(env.ASSISTANT_DB, env.DB, env.ASSISTANT_BUCKET, config, new Date(harness.clock.nowMs + offsetDays * dayMs), scheduledAssistantCleanupLimits);
    // Other tests' accounts share this file's database, so the assertions look at this account and the orphan only.
    const lostAt = async (): Promise<unknown> =>
      (await env.ASSISTANT_DB.prepare("SELECT access_lost_at FROM assistant_settings WHERE user_id = ?").bind(session.userId).first<{ access_lost_at: number | null }>())?.access_lost_at;
    expect((await run(1)).orphansDeleted).toBeGreaterThanOrEqual(1);
    expect(await objectKeys(assistantPrefix(orphan))).toEqual([]);
    expect(await assistantRows("assistant_settings", orphan)).toBe(0);
    expect(await lostAt()).toBeNull();
    // The subscription ends after 60 days (plus the 48-hour renewal grace): marked on the first run after, deleted 6 days later.
    await run(63);
    expect(await lostAt()).toBe(harness.clock.nowMs + 63 * dayMs);
    await run(63 + accessLossDeleteDays - 1);
    expect(await assistantRows("assistant_meetings", session.userId)).toBe(1);
    await run(63 + accessLossDeleteDays);
    expect(await assistantRows("assistant_meetings", session.userId)).toBe(0);
    expect(await objectKeys(assistantPrefix(session.userId))).toEqual([]);
    const settings = await env.ASSISTANT_DB.prepare("SELECT enabled, epoch FROM assistant_settings WHERE user_id = ?").bind(session.userId).first();
    expect(settings).toEqual({ enabled: 0, epoch: epoch + 1 });
  });

  it("an access-loss deletion decided on an older read never touches a re-enabled or newer copy", async () => {
    const harness: Harness = await defaultHarness();
    const { session, epoch } = await ready(harness);
    await putMeeting(harness, session, randomId(), fieldsFor(epoch, "Kept"));
    const now: Date = new Date(harness.clock.nowMs);
    const lostAt: number = harness.clock.nowMs - 10 * dayMs;
    const settings = async (): Promise<unknown> =>
      env.ASSISTANT_DB.prepare("SELECT enabled, epoch, access_lost_at FROM assistant_settings WHERE user_id = ?").bind(session.userId).first();
    // The cleanup read the mark, then the user turned the feature on again (which clears the mark): nothing is deleted.
    await env.ASSISTANT_DB.prepare("UPDATE assistant_settings SET access_lost_at = ? WHERE user_id = ?").bind(lostAt, session.userId).run();
    await setAssistant(harness, session, true);
    expect(await disableAssistantAfterAccessLoss(env.ASSISTANT_DB, env.ASSISTANT_BUCKET, session.userId, epoch, lostAt, now)).toBe(false);
    expect(await assistantRows("assistant_meetings", session.userId)).toBe(1);
    expect(await settings()).toEqual({ enabled: 1, epoch, access_lost_at: null });
    // The user turned it off and on again (new epoch) and access was lost again: the old epoch's decision is void.
    await setAssistant(harness, session, false);
    const fresh = await setAssistant(harness, session, true);
    await putMeeting(harness, session, randomId(), fieldsFor(fresh.epoch, "Fresh"));
    await env.ASSISTANT_DB.prepare("UPDATE assistant_settings SET access_lost_at = ? WHERE user_id = ?").bind(lostAt, session.userId).run();
    expect(await disableAssistantAfterAccessLoss(env.ASSISTANT_DB, env.ASSISTANT_BUCKET, session.userId, epoch, lostAt, now)).toBe(false);
    expect(await assistantRows("assistant_meetings", session.userId)).toBe(1);
    expect(await objectKeys(assistantEpochPrefix(session.userId, fresh.epoch))).toHaveLength(1);
    // The matching decision applies.
    expect(await disableAssistantAfterAccessLoss(env.ASSISTANT_DB, env.ASSISTANT_BUCKET, session.userId, fresh.epoch, lostAt, now)).toBe(true);
    expect(await assistantRows("assistant_meetings", session.userId)).toBe(0);
    expect(await settings()).toEqual({ enabled: 0, epoch: fresh.epoch + 1, access_lost_at: null });
  });

});
