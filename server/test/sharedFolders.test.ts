import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { parseConfig } from "../src/config";
import type { Env } from "../src/env";
import { sharedFolderCleanup, sharedFolderInvitesPerDay, sharedFolderMaxOpenInvites, sharedFolderPrefix } from "../src/sharedFolders";
import { type Harness, type Session, defaultHarness, envWith, expectError, grantSubscription, refreshed, req, signIn } from "./helpers";

// The server never decrypts, so the tests use shaped random values: 32-byte keys in base64, sealed values as random
// base64, items as `GSF1` + epoch + random bytes. The Swift tests and the hosted e2e cover the real cryptography.

const allowingLimiter: RateLimit = { limit: async (): Promise<RateLimitOutcome> => ({ success: true }) };
const folderEnv: Env = envWith({ SYNC_USER_LIMITER: allowingLimiter });
const dayMs: number = 86_400_000;

function randomBase64(bytes: number): string {
  const data: Uint8Array = new Uint8Array(bytes);
  crypto.getRandomValues(data);
  return btoa(String.fromCharCode(...data));
}

function randomInviteId(): string {
  return randomBase64(16).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

interface Account {
  readonly session: Session;
  readonly keys: { readonly agreementKey: string; readonly signingKey: string };
}

interface RosterMember {
  readonly memberId: string;
  readonly userId: string;
  readonly agreementKey: string;
  readonly signingKey: string;
}

interface FolderListBody {
  readonly available: boolean;
  readonly folders: ReadonlyArray<{
    readonly folderId: string;
    readonly role: string;
    readonly keyEpoch: number;
    readonly membersVersion: number;
    readonly rosterVersion: number;
    readonly itemsRev: number;
    readonly needsRotation: boolean;
    readonly envelope: string | null;
    readonly memberStatus: string | null;
  }>;
}

function call(harness: Harness, account: Account, method: string, path: string, json: object | null): Promise<Response> {
  return harness.call(req(method, path, { token: account.session.accessToken, json, env: folderEnv }));
}

async function ok<Body>(response: Response, status: number): Promise<Body> {
  const text: string = await response.text();
  expect(response.status, text).toBe(status);
  return JSON.parse(text) as Body;
}

async function account(harness: Harness, subscribed: boolean): Promise<Account> {
  const session: Session = await signIn(harness);
  if (subscribed) {
    await grantSubscription(session.userId, "active", harness.clock.nowMs + 30 * dayMs);
  }
  const keys = { agreementKey: randomBase64(32), signingKey: randomBase64(32) };
  await ok(await call(harness, { session, keys }, "PUT", "/v1/sharing/identity", { ...keys, sealedSeed: null, seedKeyId: null }), 200);
  return { session, keys };
}

function roster(folderId: string, version: number, epoch: number, members: readonly RosterMember[]): string {
  return JSON.stringify({ folderId, version, epoch, members });
}

async function createFolder(harness: Harness, owner: Account, device: string): Promise<string> {
  const folderId: string = crypto.randomUUID();
  await ok(
    await call(harness, owner, "POST", "/v1/shared-folders", {
      folderId,
      sealedMeta: randomBase64(80),
      ownerEnvelope: randomBase64(120),
      roster: roster(folderId, 1, 1, []),
      rosterSignature: randomBase64(64),
      publisherDevice: device,
    }),
    201,
  );
  return folderId;
}

async function invite(harness: Harness, owner: Account, folderId: string): Promise<string> {
  const memberId: string = randomInviteId();
  await ok(
    await call(harness, owner, "POST", `/v1/shared-folders/${folderId}/invites`, {
      memberId,
      sealedLabel: randomBase64(40),
      sealedSecret: randomBase64(60),
      ownerProof: randomBase64(32),
      sealedPreview: randomBase64(60),
    }),
    201,
  );
  return memberId;
}

function acceptBody(): object {
  return { memberProof: randomBase64(32), sealedName: randomBase64(30), sealedPin: randomBase64(90) };
}

async function folders(harness: Harness, account: Account): Promise<FolderListBody> {
  return ok<FolderListBody>(await call(harness, account, "GET", "/v1/shared-folders", null), 200);
}

async function folderOf(harness: Harness, account: Account, folderId: string): Promise<FolderListBody["folders"][number]> {
  const found = (await folders(harness, account)).folders.find((folder) => folder.folderId === folderId);
  if (found === undefined) {
    throw new Error("folder missing from the list");
  }
  return found;
}

function memberOf(account: Account, memberId: string): RosterMember {
  return { memberId, userId: account.session.userId, ...account.keys };
}

/** Activates (or rotates with) `members` at `epoch`; envelopes for `envelopeFor`. */
async function changeRoster(
  harness: Harness,
  owner: Account,
  folderId: string,
  epoch: number,
  members: readonly RosterMember[],
  envelopeFor: readonly string[],
): Promise<Response> {
  const current = await folderOf(harness, owner, folderId);
  const rotation: boolean = epoch > current.keyEpoch;
  return call(harness, owner, "PUT", `/v1/shared-folders/${folderId}/roster`, {
    keyEpoch: epoch,
    expectedMembersVersion: current.membersVersion,
    roster: roster(folderId, current.rosterVersion + 1, epoch, members),
    rosterSignature: randomBase64(64),
    sealedMeta: rotation ? randomBase64(80) : null,
    ownerEnvelope: rotation ? randomBase64(120) : null,
    envelopes: envelopeFor.map((memberId: string) => ({ memberId, envelope: randomBase64(150) })),
  });
}

function item(epoch: number, bytes: number): Uint8Array {
  const body: Uint8Array = new Uint8Array(8 + bytes);
  body.set(new TextEncoder().encode("GSF1"), 0);
  new DataView(body.buffer).setUint32(4, epoch);
  crypto.getRandomValues(body.subarray(8, Math.min(body.byteLength, 8 + 65_536)));
  return body;
}

function putItem(harness: Harness, owner: Account, folderId: string, itemId: string, epoch: number, device: string, body: Uint8Array): Promise<Response> {
  return harness.call(
    req("PUT", `/v1/shared-folders/${folderId}/items/${itemId}`, {
      token: owner.session.accessToken,
      headers: { "content-type": "application/octet-stream", "x-item-epoch": String(epoch), "x-item-tag": "ab".repeat(16), "x-publisher-device": device },
      body,
      env: folderEnv,
    }),
  );
}

/** Owner with a folder and one active member. */
async function folderWithMember(harness: Harness): Promise<{ owner: Account; member: Account; folderId: string; memberId: string; device: string }> {
  const owner: Account = await account(harness, true);
  const member: Account = await account(harness, false);
  const device: string = crypto.randomUUID();
  const folderId: string = await createFolder(harness, owner, device);
  const memberId: string = await invite(harness, owner, folderId);
  await ok(await call(harness, member, "POST", `/v1/shared-invites/${memberId}/accept`, acceptBody()), 200);
  await ok(await changeRoster(harness, owner, folderId, 1, [memberOf(member, memberId)], [memberId]), 200);
  return { owner, member, folderId, memberId, device };
}

describe("shared folders", () => {
  it("hides the feature while SHARED_FOLDERS_POLICY is off", async () => {
    const harness: Harness = await defaultHarness();
    const session: Session = await signIn(harness);
    const off: Env = envWith({ SYNC_USER_LIMITER: allowingLimiter, SHARED_FOLDERS_POLICY: "off" });
    const list: Response = await harness.call(req("GET", "/v1/shared-folders", { token: session.accessToken, env: off }));
    expect(await ok(list, 200)).toEqual({ available: false, folders: [] });
    await expectError(await harness.call(req("GET", "/v1/sharing/identity", { token: session.accessToken, env: off })), 503, "shared_folders_unavailable");
    await expectError(await harness.call(req("GET", "/v1/shared-folders", {})), 401, "unauthorized");
  });

  it("keeps the first identity and refuses other keys", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Account = await account(harness, false);
    const other = { agreementKey: randomBase64(32), signingKey: randomBase64(32), sealedSeed: null, seedKeyId: null };
    await expectError(await call(harness, owner, "PUT", "/v1/sharing/identity", other), 409, "shared_folder_conflict");
    const sealedSeed: string = randomBase64(80);
    const updated = await ok<{ identity: { sealedSeed: string; agreementKey: string } }>(
      await call(harness, owner, "PUT", "/v1/sharing/identity", { ...owner.keys, sealedSeed, seedKeyId: "0".repeat(32) }),
      200,
    );
    expect(updated.identity).toMatchObject({ sealedSeed, agreementKey: owner.keys.agreementKey });
  });

  it("runs invite, accept, activation, reading, removal with rotation and stop sharing", async () => {
    const harness: Harness = await defaultHarness();
    const { owner, member, folderId, memberId, device } = await folderWithMember(harness);
    const stranger: Account = await account(harness, true);

    const joined = await folderOf(harness, member, folderId);
    expect(joined).toMatchObject({ role: "member", memberStatus: "active", keyEpoch: 1 });
    expect(joined.envelope).not.toBeNull();

    const itemId: string = crypto.randomUUID();
    const sealed: Uint8Array = item(1, 300);
    await ok(await putItem(harness, owner, folderId, itemId, 1, device, sealed), 200);
    const listed = await ok<{ items: Array<{ itemId: string; keyEpoch: number }> }>(await call(harness, member, "GET", `/v1/shared-folders/${folderId}/items`, null), 200);
    expect(listed.items.map((entry) => entry.itemId)).toEqual([itemId]);
    const read: Response = await call(harness, member, "GET", `/v1/shared-folders/${folderId}/items/${itemId}`, null);
    expect(new Uint8Array(await read.arrayBuffer())).toEqual(sealed);

    // Strangers cannot see or probe anything.
    await expectError(await call(harness, stranger, "GET", `/v1/shared-folders/${folderId}/items`, null), 404, "not_found");
    await expectError(await call(harness, stranger, "GET", `/v1/shared-folders/${folderId}/members`, null), 404, "not_found");
    await expectError(await call(harness, member, "GET", `/v1/shared-folders/${folderId}/members`, null), 404, "not_found");
    // A member cannot write.
    await expectError(await putItem(harness, member, folderId, crypto.randomUUID(), 1, device, item(1, 120)), 404, "not_found");

    // Removal is a rotation: the new roster leaves the member out and the member loses access at once.
    await ok(await changeRoster(harness, owner, folderId, 2, [], []), 200);
    await expectError(await call(harness, member, "GET", `/v1/shared-folders/${folderId}/items`, null), 404, "not_found");
    expect((await folders(harness, member)).folders).toEqual([]);
    // Old-epoch uploads are refused after the rotation.
    await expectError(await putItem(harness, owner, folderId, crypto.randomUUID(), 1, device, item(1, 120)), 409, "shared_folder_conflict");
    await ok(await putItem(harness, owner, folderId, crypto.randomUUID(), 2, device, item(2, 120)), 200);
    expect(memberId.length).toBe(22);

    await ok(await call(harness, owner, "DELETE", `/v1/shared-folders/${folderId}`, null), 200);
    // A retry after a lost response answers the same.
    await ok(await call(harness, owner, "DELETE", `/v1/shared-folders/${folderId}`, null), 200);
    expect((await folders(harness, owner)).folders).toEqual([]);
    expect((await env.SYNC_BUCKET.list({ prefix: sharedFolderPrefix(folderId) })).objects).toEqual([]);
  });

  it("makes invites single-use, idempotent for the same account, and not usable by the owner", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Account = await account(harness, true);
    const folderId: string = await createFolder(harness, owner, crypto.randomUUID());
    const memberId: string = await invite(harness, owner, folderId);
    const first: Account = await account(harness, false);
    const second: Account = await account(harness, false);
    const preview = await ok<{ state: string; ownerSigningKey: string }>(await call(harness, first, "GET", `/v1/shared-invites/${memberId}`, null), 200);
    expect(preview).toMatchObject({ state: "open", ownerSigningKey: owner.keys.signingKey });
    expect((await ok<{ state: string }>(await call(harness, owner, "GET", `/v1/shared-invites/${memberId}`, null), 200)).state).toBe("own");
    await expectError(await call(harness, owner, "POST", `/v1/shared-invites/${memberId}/accept`, acceptBody()), 410, "shared_invite_unavailable");
    const body: object = acceptBody();
    await ok(await call(harness, first, "POST", `/v1/shared-invites/${memberId}/accept`, body), 200);
    await ok(await call(harness, first, "POST", `/v1/shared-invites/${memberId}/accept`, body), 200);
    await expectError(await call(harness, second, "POST", `/v1/shared-invites/${memberId}/accept`, acceptBody()), 410, "shared_invite_unavailable");
    expect((await folderOf(harness, first, folderId)).memberStatus).toBe("accepted");
    // Accepted but not activated: no items yet.
    await expectError(await call(harness, first, "GET", `/v1/shared-folders/${folderId}/items`, null), 404, "not_found");
  });

  it("expires invites after 7 days", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Account = await account(harness, true);
    const folderId: string = await createFolder(harness, owner, crypto.randomUUID());
    const memberId: string = await invite(harness, owner, folderId);
    harness.clock.nowMs += 8 * dayMs;
    const late: Account = await account(harness, false);
    expect((await ok<{ state: string }>(await call(harness, late, "GET", `/v1/shared-invites/${memberId}`, null), 200)).state).toBe("expired");
    await expectError(await call(harness, late, "POST", `/v1/shared-invites/${memberId}/accept`, acceptBody()), 410, "shared_invite_unavailable");
    const report = await sharedFolderCleanup(env.DB, parseConfig(env), new Date(harness.clock.nowMs), 50);
    expect(report.invitesExpired).toBeGreaterThanOrEqual(1);
  });

  it("refuses a roster that does not match the member rows or a stale members version", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Account = await account(harness, true);
    const member: Account = await account(harness, false);
    const folderId: string = await createFolder(harness, owner, crypto.randomUUID());
    const memberId: string = await invite(harness, owner, folderId);
    await ok(await call(harness, member, "POST", `/v1/shared-invites/${memberId}/accept`, acceptBody()), 200);
    // A key the member row does not have (a substituted key) is refused.
    const forged: RosterMember = { ...memberOf(member, memberId), agreementKey: randomBase64(32) };
    await expectError(await changeRoster(harness, owner, folderId, 1, [forged], [memberId]), 409, "shared_folder_conflict");
    // A member who never accepted cannot be in the roster.
    const ghost: RosterMember = { memberId: randomInviteId(), userId: "nobody", ...owner.keys };
    await expectError(await changeRoster(harness, owner, folderId, 1, [ghost], [ghost.memberId]), 409, "shared_folder_conflict");
    // A new member without an envelope is refused.
    await expectError(await changeRoster(harness, owner, folderId, 1, [memberOf(member, memberId)], []), 400, "invalid_body");
    // A stale members version is refused.
    const current = await folderOf(harness, owner, folderId);
    const stale: Response = await call(harness, owner, "PUT", `/v1/shared-folders/${folderId}/roster`, {
      keyEpoch: 1,
      expectedMembersVersion: current.membersVersion - 1,
      roster: roster(folderId, current.rosterVersion + 1, 1, [memberOf(member, memberId)]),
      rosterSignature: randomBase64(64),
      sealedMeta: null,
      ownerEnvelope: null,
      envelopes: [{ memberId, envelope: randomBase64(150) }],
    });
    await expectError(stale, 409, "shared_folder_conflict");
    // The same change sent twice (lost response) succeeds both times.
    const body = {
      keyEpoch: 1,
      expectedMembersVersion: current.membersVersion,
      roster: roster(folderId, current.rosterVersion + 1, 1, [memberOf(member, memberId)]),
      rosterSignature: randomBase64(64),
      sealedMeta: null,
      ownerEnvelope: null,
      envelopes: [{ memberId, envelope: randomBase64(150) }],
    };
    await ok(await call(harness, owner, "PUT", `/v1/shared-folders/${folderId}/roster`, body), 200);
    await ok(await call(harness, owner, "PUT", `/v1/shared-folders/${folderId}/roster`, body), 200);
    // Removing an active member without a new epoch is refused.
    await expectError(await changeRoster(harness, owner, folderId, 1, [], []), 409, "shared_folder_conflict");
  });

  it("blocks new items after a member leaves until the key is rotated", async () => {
    const harness: Harness = await defaultHarness();
    const { owner, member, folderId, device } = await folderWithMember(harness);
    await ok(await call(harness, member, "DELETE", `/v1/shared-folders/${folderId}/membership`, null), 200);
    expect((await folderOf(harness, owner, folderId)).needsRotation).toBe(true);
    await expectError(await putItem(harness, owner, folderId, crypto.randomUUID(), 1, device, item(1, 120)), 409, "shared_folder_conflict");
    // Rotation needs no subscription (a security action).
    await env.DB.prepare("DELETE FROM subscriptions WHERE user_id = ?").bind(owner.session.userId).run();
    await ok(await changeRoster(harness, owner, folderId, 2, [], []), 200);
    expect((await folderOf(harness, owner, folderId)).needsRotation).toBe(false);
    // Publishing again needs the subscription.
    await expectError(await putItem(harness, owner, folderId, crypto.randomUUID(), 2, device, item(2, 120)), 402, "subscription_required");
  });

  it("lets only the publisher device upload and hands over after the lease or on request", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Account = await account(harness, true);
    const first: string = crypto.randomUUID();
    const second: string = crypto.randomUUID();
    const folderId: string = await createFolder(harness, owner, first);
    await expectError(await putItem(harness, owner, folderId, crypto.randomUUID(), 1, second, item(1, 120)), 409, "shared_folder_conflict");
    const claimed = await ok<{ publisherDevice: string }>(await call(harness, owner, "POST", `/v1/shared-folders/${folderId}/publisher`, { device: second }), 200);
    expect(claimed.publisherDevice).toBe(first);
    harness.clock.nowMs += 4 * dayMs;
    const later: Account = { session: await refreshed(harness, owner.session), keys: owner.keys };
    expect((await ok<{ publisherDevice: string }>(await call(harness, later, "POST", `/v1/shared-folders/${folderId}/publisher`, { device: second }), 200)).publisherDevice).toBe(second);
    expect((await ok<{ publisherDevice: string }>(await call(harness, later, "PUT", `/v1/shared-folders/${folderId}/publisher`, { device: first }), 200)).publisherDevice).toBe(first);
  });

  it("needs the owner's subscription to share and caps open invites", async () => {
    const harness: Harness = await defaultHarness();
    const free: Account = await account(harness, false);
    const folderId: string = crypto.randomUUID();
    const create: Response = await call(harness, free, "POST", "/v1/shared-folders", {
      folderId,
      sealedMeta: randomBase64(80),
      ownerEnvelope: randomBase64(120),
      roster: roster(folderId, 1, 1, []),
      rosterSignature: randomBase64(64),
      publisherDevice: crypto.randomUUID(),
    });
    await expectError(create, 402, "subscription_required");
    const owner: Account = await account(harness, true);
    const shared: string = await createFolder(harness, owner, crypto.randomUUID());
    for (let index: number = 0; index < sharedFolderMaxOpenInvites; index += 1) {
      await invite(harness, owner, shared);
    }
    const over: Response = await call(harness, owner, "POST", `/v1/shared-folders/${shared}/invites`, {
      memberId: randomInviteId(),
      sealedLabel: randomBase64(40),
      sealedSecret: randomBase64(60),
      ownerProof: randomBase64(32),
      sealedPreview: randomBase64(60),
    });
    await expectError(over, 409, "shared_folder_limit_reached");
    // Refused attempts on a full folder do not use up the daily invites.
    const other: string = await createFolder(harness, owner, crypto.randomUUID());
    for (let index: number = 0; index < sharedFolderInvitesPerDay - sharedFolderMaxOpenInvites; index += 1) {
      await invite(harness, owner, other);
    }
  });

  it("counts every invite toward the daily limit, revoked ones too", async () => {
    const harness: Harness = await defaultHarness();
    const owner: Account = await account(harness, true);
    const folderId: string = await createFolder(harness, owner, crypto.randomUUID());
    for (let index: number = 0; index < sharedFolderInvitesPerDay; index += 1) {
      const memberId: string = await invite(harness, owner, folderId);
      await ok(await call(harness, owner, "DELETE", `/v1/shared-folders/${folderId}/invites/${memberId}`, null), 200);
    }
    await expectError(
      await call(harness, owner, "POST", `/v1/shared-folders/${folderId}/invites`, {
        memberId: randomInviteId(),
        sealedLabel: randomBase64(40),
        sealedSecret: randomBase64(60),
        ownerProof: randomBase64(32),
        sealedPreview: randomBase64(60),
      }),
      409,
      "shared_folder_limit_reached",
    );
    // Resetting shared folders does not give invites back.
    await ok(await call(harness, owner, "DELETE", "/v1/sharing/identity", null), 200);
    await ok(await call(harness, owner, "PUT", "/v1/sharing/identity", { ...owner.keys, sealedSeed: null, seedKeyId: null }), 200);
    const again: string = await createFolder(harness, owner, crypto.randomUUID());
    await expectError(
      await call(harness, owner, "POST", `/v1/shared-folders/${again}/invites`, {
        memberId: randomInviteId(),
        sealedLabel: randomBase64(40),
        sealedSecret: randomBase64(60),
        ownerProof: randomBase64(32),
        sealedPreview: randomBase64(60),
      }),
      409,
      "shared_folder_limit_reached",
    );
    harness.clock.nowMs += dayMs;
    const tomorrow: Account = { session: await refreshed(harness, owner.session), keys: owner.keys };
    await invite(harness, tomorrow, again);
  });

  it("asks members for a subscription only under SHARED_FOLDERS_MEMBER_ACCESS=subscription", async () => {
    const harness: Harness = await defaultHarness();
    const { member, folderId } = await folderWithMember(harness);
    const paid: Env = envWith({ SYNC_USER_LIMITER: allowingLimiter, SHARED_FOLDERS_MEMBER_ACCESS: "subscription" });
    const items: Response = await harness.call(req("GET", `/v1/shared-folders/${folderId}/items`, { token: member.session.accessToken, env: paid }));
    await expectError(items, 402, "subscription_required");
  });

  it("deletes an owner's folders and a member's memberships with the account", async () => {
    const harness: Harness = await defaultHarness();
    const { owner, member, folderId, device } = await folderWithMember(harness);
    await ok(await putItem(harness, owner, folderId, crypto.randomUUID(), 1, device, item(1, 120)), 200);
    // The member leaves by deleting the account: the folder needs a rotation.
    await env.DB.prepare("UPDATE users SET trial_started_at = NULL WHERE id = ?").bind(member.session.userId).run();
    expect((await call(harness, member, "DELETE", "/v1/me", null)).status).toBe(200);
    expect((await folderOf(harness, owner, folderId)).needsRotation).toBe(true);
    // No Stripe rows, so the deletion makes no Stripe calls.
    await env.DB.prepare("DELETE FROM subscriptions WHERE user_id = ?").bind(owner.session.userId).run();
    await env.DB.prepare("DELETE FROM stripe_customers WHERE user_id = ?").bind(owner.session.userId).run();
    expect((await call(harness, owner, "DELETE", "/v1/me", null)).status).toBe(200);
    const left: { count: number } | null = await env.DB.prepare(
      "SELECT (SELECT COUNT(*) FROM shared_folders WHERE folder_id = ?1) + (SELECT COUNT(*) FROM shared_folder_items WHERE folder_id = ?1) + (SELECT COUNT(*) FROM sharing_identities WHERE user_id = ?2) AS count",
    )
      .bind(folderId, owner.session.userId)
      .first<{ count: number }>();
    expect(left?.count ?? -1).toBe(0);
    expect((await env.SYNC_BUCKET.list({ prefix: sharedFolderPrefix(folderId) })).objects).toEqual([]);
  });
});
