import { z } from "zod";
import type { Config } from "./config";
import { hexEncode, randomToken } from "./crypto";
import { type AccessConfig, hasPaidAccess, hasRunningTrial, userTrialState } from "./entitlements";
import { ApiError } from "./errors";
import { jsonResponse, readBodyBytes, readJsonBody } from "./http";
import { errorName, log } from "./log";

/**
 * Mac <-> iPhone sync, phase 1 (text only; design: docs/superpowers/specs/2026-11-03-mac-iphone-sync-options.md §8).
 *
 * Devices encrypt every object end to end with the account sync key (AES-256-GCM, see the Swift `SyncCrypto`); the
 * server stores the ciphertext in R2 (`SYNC_BUCKET`, EU jurisdiction) and only an index in D1 (`sync_objects`: random
 * object id, kind from a fixed list, revision, size, tombstone flag). It never sees titles, names or text, and the key
 * never reaches it: key envelopes (`sync_key_envelopes`) are sealed on the devices.
 *
 * Revisions: every account has one change counter (`sync_accounts.last_rev`). A write or delete takes the next value in
 * the same D1 transaction that commits it, so changes become visible in revision order and `GET /v1/sync/changes`
 * with a cursor never skips one. Writes are optimistic: `If-Match: <rev>` must equal the object's current revision (0
 * for a new object), otherwise `409 sync_conflict` and the device merges and retries.
 *
 * Access: writing needs a subscription or a running trial (`requireSyncWriteAccess`); reading, deleting, opting out and
 * key envelopes work without one, so a lapsed subscriber can still read and remove the copy during retention. The
 * daily cleanup (`syncCleanup`, `cleanup.ts`) removes tombstones and expired pairing envelopes, wipes accounts 90 days
 * after access ended and finishes R2 deletions. Account deletion removes everything at once (`syncDeletionStatements`).
 *
 * Free tier: R2 bills only beyond 10 GB-month of storage, 1 million Class A operations (writes, lists) and 10 million
 * Class B operations (reads) a month. Sync stops at 80% of each budget (`syncR2…Budget`, counted in `sync_r2_usage`),
 * so the bucket never leaves the free tier: past a budget, uploads or downloads answer `503 sync_unavailable` until the
 * next UTC month (operations) or until deletes free space (storage). Deletes are free and never blocked.
 *
 * The lists and limits below are mirrored by the Swift client (`ServerParityTests`).
 */

/** Object kinds; voiceprints are deliberately not synced in phase 1 (biometric data stays on the device). */
export const syncObjectKinds = ["meeting.state", "meeting.content", "ask.chat", "people", "prefs"] as const;
export type SyncObjectKind = (typeof syncObjectKinds)[number];

/** Key envelope kinds: the recovery-code envelope and short-lived "add a device" pairing messages. */
export const syncEnvelopeKinds = ["recovery", "pairing"] as const;
export type SyncEnvelopeKind = (typeof syncEnvelopeKinds)[number];

/**
 * Largest encrypted object (bytes). The biggest phase-1 object is `meeting.content` of a 4-hour meeting: ~1 MB/h of
 * JSON compresses ~6x before encryption (doc §1.2), ~0.75 MB; the cap leaves headroom.
 */
export const syncObjectMaxBytes: number = 2_097_152;
/** Live (not deleted) objects per account: ~10,000 meetings (state + content) with chats and people. */
export const syncAccountMaxObjects: number = 20_000;
/** Stored bytes per account (phase 1 text only; a heavy user stores ~22 MB a year, so this holds ~4.5 years). */
export const syncAccountMaxBytes: number = 104_857_600;
/** Stored bytes across all accounts: 80% of R2's free 10 GB-month. */
export const syncR2StoredBytesBudget: number = 8_000_000_000;
/** Class A operations (uploads, purge lists) across all accounts per UTC month: 80% of R2's free million. */
export const syncR2ClassABudget: number = 800_000;
/** Class B operations (downloads) across all accounts per UTC month: 80% of R2's free 10 million. */
export const syncR2ClassBBudget: number = 8_000_000;
/** Most changes per `GET /v1/sync/changes` page. */
export const syncChangesMaxLimit: number = 1000;
/** Largest key envelope (base64 characters). */
export const syncEnvelopeMaxChars: number = 4096;
/** Most key envelopes an account holds at once (expired pairing messages excluded). */
export const syncAccountMaxEnvelopes: number = 20;
/** Lifetime of a pairing envelope. */
export const syncPairingTtlMs: number = 10 * 60_000;
/** Days a tombstone stays so other devices learn about the delete. */
export const syncTombstoneRetentionDays: number = 90;
/** Days the encrypted copy stays after the subscription or trial ended. */
export const syncAccessRetentionDays: number = 90;

/**
 * Encrypted blob header written by the client (`SyncCrypto.sealSyncObject`): magic `GSY1`, 16-byte key id, 8-byte
 * big-endian base revision, then the AES-GCM nonce, ciphertext and tag. The server checks only the header: the blob
 * must be sealed with the account's current key and based on the revision named in `If-Match`.
 */
export const syncBlobMagic: string = "GSY1";
const syncBlobHeaderBytes: number = 4 + 16 + 8;
/** Header + 12-byte nonce + 16-byte tag (empty plaintext). */
export const syncBlobMinBytes: number = syncBlobHeaderBytes + 12 + 16;

const dayMs: number = 86_400_000;
/** Reads of an object while concurrent writes keep replacing its blob. */
const readObjectAttempts: number = 3;
/** Pages (1000 keys each) one immediate R2 purge deletes before leaving the rest to the daily cleanup. */
const immediatePurgePages: number = 5;
const objectPath: RegExp = /^\/v1\/sync\/objects\/([0-9a-f-]{36})$/;
const envelopePath: RegExp = /^\/v1\/sync\/envelopes\/([0-9a-f-]{36})$/;
const keyIdSchema = z.string().regex(/^[0-9a-f]{32}$/);
const enableSchema = z.strictObject({ keyId: keyIdSchema });
const envelopeSchema = z.strictObject({
  kind: z.enum(syncEnvelopeKinds),
  ciphertext: z.base64().min(1).max(syncEnvelopeMaxChars),
});

/** `sync_accounts` row. */
interface SyncAccountRow {
  readonly key_id: string;
  readonly enabled_at: number;
  readonly last_rev: number;
  readonly purged_through_rev: number;
  readonly object_count: number;
  readonly stored_bytes: number;
}

/** `sync_objects` row. */
interface SyncObjectRow {
  readonly object_id: string;
  readonly kind: SyncObjectKind;
  readonly rev: number;
  readonly size: number;
  readonly deleted: number;
  readonly r2_key: string | null;
  readonly updated_at: number;
}

/** `GET`/`POST /v1/sync/account` body. `epoch` changes whenever sync is turned on again (revisions restart). */
export interface SyncAccountBody {
  readonly enabled: boolean;
  readonly keyId: string | null;
  readonly epoch: number | null;
  readonly lastRev: number;
  readonly objects: number;
  readonly storedBytes: number;
  readonly maxObjects: number;
  readonly maxBytes: number;
}

/** One entry of the change feed. */
export interface SyncChange {
  readonly objectId: string;
  readonly kind: SyncObjectKind;
  readonly rev: number;
  readonly size: number;
  readonly deleted: boolean;
  readonly updatedAt: number;
}

/** UTC month (`YYYY-MM`) that keys the `sync_r2_usage` counters. Pure function. */
export function syncUsageMonth(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/** The answer once a free-tier budget is spent; logged as an alert so the admin sees sync paused. */
function syncBudgetSpent(budget: string, month: string): ApiError {
  log("alert", "sync_r2_budget_reached", { budget, month });
  return new ApiError("sync_unavailable", "Sync is paused for now; your meetings stay on your devices. Try again later.");
}

/** Takes one Class A operation from this month's budget (atomic upsert); refuses once the budget is spent. */
async function reserveSyncClassA(db: D1Database, now: Date): Promise<void> {
  const month: string = syncUsageMonth(now);
  const row: { class_a: number } | null = await db
    .prepare(
      `INSERT INTO sync_r2_usage (month, class_a, class_b) VALUES (?1, 1, 0)
       ON CONFLICT (month) DO UPDATE SET class_a = class_a + 1 WHERE class_a < ?2
       RETURNING class_a`,
    )
    .bind(month, syncR2ClassABudget)
    .first<{ class_a: number }>();
  if (row === null) {
    throw syncBudgetSpent("class_a", month);
  }
}

/** Takes one Class B operation from this month's budget (atomic upsert); refuses once the budget is spent. */
async function reserveSyncClassB(db: D1Database, now: Date): Promise<void> {
  const month: string = syncUsageMonth(now);
  const row: { class_b: number } | null = await db
    .prepare(
      `INSERT INTO sync_r2_usage (month, class_a, class_b) VALUES (?1, 0, 1)
       ON CONFLICT (month) DO UPDATE SET class_b = class_b + 1 WHERE class_b < ?2
       RETURNING class_b`,
    )
    .bind(month, syncR2ClassBBudget)
    .first<{ class_b: number }>();
  if (row === null) {
    throw syncBudgetSpent("class_b", month);
  }
}

/** Counts a Class A operation that must run even past the budget (purge lists: deleting a copy is never refused). */
async function countSyncClassA(db: D1Database, now: Date): Promise<void> {
  await db
    .prepare(
      `INSERT INTO sync_r2_usage (month, class_a, class_b) VALUES (?1, 1, 0)
       ON CONFLICT (month) DO UPDATE SET class_a = class_a + 1`,
    )
    .bind(syncUsageMonth(now))
    .run();
}

/** Refuses an upload that would take the stored bytes of all accounts past the storage budget. */
async function requireSyncStorageBudget(db: D1Database, byteDelta: number, now: Date): Promise<void> {
  const total: { bytes: number } | null = await db.prepare("SELECT COALESCE(SUM(stored_bytes), 0) AS bytes FROM sync_accounts").first<{ bytes: number }>();
  if (total === null) {
    throw new Error("SUM over sync_accounts returned no row.");
  }
  if (total.bytes + byteDelta > syncR2StoredBytesBudget) {
    throw syncBudgetSpent("storage", syncUsageMonth(now));
  }
}

/** R2 prefix of all of an account's blobs (account deletion purges it). Pure function. */
export function syncPrefix(userId: string): string {
  return `u/${userId}/`;
}

/**
 * R2 prefix of one sync epoch (`sync_accounts.enabled_at`): blobs live under `u/<user>/<epoch>/<object>/<random>`, so
 * purging a wiped epoch never touches the blobs of sync turned on again before the purge finished. Pure function.
 */
export function syncEpochPrefix(userId: string, epoch: number): string {
  return `${syncPrefix(userId)}${epoch}/`;
}

/** Account body; not enabled when the row is missing. Pure function. */
export function syncAccountBody(row: SyncAccountRow | null): SyncAccountBody {
  return {
    enabled: row !== null,
    keyId: row?.key_id ?? null,
    epoch: row?.enabled_at ?? null,
    lastRev: row?.last_rev ?? 0,
    objects: row?.object_count ?? 0,
    storedBytes: row?.stored_bytes ?? 0,
    maxObjects: syncAccountMaxObjects,
    maxBytes: syncAccountMaxBytes,
  };
}

/**
 * Checks an uploaded blob's header: magic, the account's key id and the `If-Match` base revision. Returns nothing;
 * `invalid_body` for a malformed blob, `sync_key_mismatch` when it was sealed with another key. Pure function.
 */
export function requireValidBlob(blob: Uint8Array, accountKeyId: string, baseRev: number): void {
  if (blob.byteLength < syncBlobMinBytes || new TextDecoder().decode(blob.subarray(0, 4)) !== syncBlobMagic) {
    throw new ApiError("invalid_body", "The object is not a sync blob.");
  }
  if (hexEncode(blob.subarray(4, 20)) !== accountKeyId) {
    throw new ApiError("sync_key_mismatch", "The object is sealed with a different sync key; get this account's key from another device.");
  }
  const view: DataView = new DataView(blob.buffer, blob.byteOffset + 20, 8);
  if (view.getBigUint64(0) !== BigInt(baseRev)) {
    throw new ApiError("invalid_body", "The object's base revision does not match If-Match.");
  }
}

/** Whether the account may write (subscription or running trial); the daily cleanup uses it for retention. */
export async function hasSyncAccess(db: D1Database, config: AccessConfig, userId: string, now: Date): Promise<boolean> {
  if (await hasPaidAccess(db, config, userId, now)) {
    return true;
  }
  const trial = await userTrialState(db, userId);
  return hasRunningTrial(trial, config, now);
}

/** Writing (turning sync on, uploading) needs a subscription or a running trial; otherwise `subscription_required`. */
async function requireSyncWriteAccess(db: D1Database, config: Config, userId: string, now: Date): Promise<void> {
  if (!(await hasSyncAccess(db, config, userId, now))) {
    throw new ApiError("subscription_required", "Syncing new changes needs a subscription; your synced copy stays readable for 90 days.");
  }
}

async function accountRow(db: D1Database, userId: string): Promise<SyncAccountRow | null> {
  return db
    .prepare("SELECT key_id, enabled_at, last_rev, purged_through_rev, object_count, stored_bytes FROM sync_accounts WHERE user_id = ?")
    .bind(userId)
    .first<SyncAccountRow>();
}

async function requireAccount(db: D1Database, userId: string): Promise<SyncAccountRow> {
  const row: SyncAccountRow | null = await accountRow(db, userId);
  if (row === null) {
    throw new ApiError("sync_not_enabled", "Sync is off for this account; turn it on first.");
  }
  return row;
}

async function objectRow(db: D1Database, userId: string, objectId: string): Promise<SyncObjectRow | null> {
  return db
    .prepare("SELECT object_id, kind, rev, size, deleted, r2_key, updated_at FROM sync_objects WHERE user_id = ? AND object_id = ?")
    .bind(userId, objectId)
    .first<SyncObjectRow>();
}

/** `If-Match` revision (a non-negative integer, 0 for a new object); `bad_request` when missing or malformed. */
function baseRevHeader(request: Request): number {
  const value: string | null = request.headers.get("if-match");
  if (value === null || !/^\d{1,15}$/.test(value)) {
    throw new ApiError("bad_request", "The If-Match header (the object's current revision, 0 for a new object) is required.");
  }
  return Number(value);
}

/** Optional `x-sync-device` header (the device's random sync id). */
function deviceHeader(request: Request): string | null {
  const value: string | null = request.headers.get("x-sync-device");
  if (value === null) {
    return null;
  }
  if (!z.uuid().safeParse(value).success) {
    throw new ApiError("bad_request", "The x-sync-device header must be a UUID.");
  }
  return value;
}

function kindHeader(request: Request): SyncObjectKind {
  const parsed = z.enum(syncObjectKinds).safeParse(request.headers.get("x-sync-kind"));
  if (!parsed.success) {
    throw new ApiError("bad_request", `The x-sync-kind header must be one of: ${syncObjectKinds.join(", ")}.`);
  }
  return parsed.data;
}

function uuidOf(match: RegExpExecArray): string {
  const value: string | undefined = match[1];
  if (value === undefined || !z.uuid().safeParse(value).success) {
    throw new ApiError("bad_request", "The id must be a UUID.");
  }
  return value;
}

/** Turns sync on with the device's key id; the same key again is a no-op, another key is `sync_key_mismatch`. */
async function enableSync(db: D1Database, config: Config, userId: string, keyId: string, now: Date): Promise<SyncAccountBody> {
  await requireSyncWriteAccess(db, config, userId, now);
  const nowMs: number = now.getTime();
  await db
    .prepare(
      `INSERT INTO sync_accounts (user_id, key_id, enabled_at, access_seen_at, updated_at) VALUES (?1, ?2, ?3, ?3, ?3)
       ON CONFLICT(user_id) DO NOTHING`,
    )
    .bind(userId, keyId, nowMs)
    .run();
  const row: SyncAccountRow = await requireAccount(db, userId);
  if (row.key_id !== keyId) {
    throw new ApiError("sync_key_mismatch", "Sync is already on with a different key; get this account's key from another device.");
  }
  return syncAccountBody(row);
}

/**
 * Change feed after `since`; a stale cursor (older epoch, or tombstones past it were purged) is `sync_cursor_expired`.
 * `listing=full` marks the later pages of a listing that started at 0: they may pass purged tombstones, because the
 * client compares the whole listing with what it knows (an object missing from it was deleted).
 */
async function listChanges(db: D1Database, userId: string, url: URL): Promise<object> {
  const params = z
    .object({
      since: z.coerce.number().int().min(0).max(Number.MAX_SAFE_INTEGER),
      limit: z.coerce.number().int().min(1).max(syncChangesMaxLimit),
      epoch: z.coerce.number().int().min(0).optional(),
      listing: z.enum(["full"]).optional(),
    })
    .safeParse({
      since: url.searchParams.get("since") ?? "0",
      limit: url.searchParams.get("limit") ?? "500",
      epoch: url.searchParams.get("epoch") ?? undefined,
      listing: url.searchParams.get("listing") ?? undefined,
    });
  if (!params.success) {
    throw new ApiError("bad_request", "since and limit must be integers (limit 1-1000); listing can only be full.");
  }
  const { since, limit, epoch, listing } = params.data;
  const account: SyncAccountRow = await requireAccount(db, userId);
  const purgedPast: boolean = listing !== "full" && since < account.purged_through_rev;
  if (since > 0 && (epoch !== account.enabled_at || purgedPast || since > account.last_rev)) {
    throw new ApiError("sync_cursor_expired", "The sync cursor is no longer valid; sync again from the start.");
  }
  const rows: D1Result<SyncObjectRow> = await db
    .prepare(
      "SELECT object_id, kind, rev, size, deleted, r2_key, updated_at FROM sync_objects WHERE user_id = ? AND rev > ? ORDER BY rev LIMIT ?",
    )
    .bind(userId, since, limit + 1)
    .all<SyncObjectRow>();
  const page: SyncObjectRow[] = rows.results.slice(0, limit);
  const changes: SyncChange[] = page.map(
    (row: SyncObjectRow): SyncChange => ({
      objectId: row.object_id,
      kind: row.kind,
      rev: row.rev,
      size: row.size,
      deleted: row.deleted === 1,
      updatedAt: row.updated_at,
    }),
  );
  return {
    keyId: account.key_id,
    epoch: account.enabled_at,
    changes,
    cursor: page.at(-1)?.rev ?? since,
    hasMore: rows.results.length > limit,
  };
}

/** The current blob of a live object; tombstones and unknown ids are `not_found`. */
async function readObject(db: D1Database, bucket: R2Bucket, userId: string, objectId: string, now: Date): Promise<Response> {
  await requireAccount(db, userId);
  for (let attempt: number = 1; ; attempt += 1) {
    const row: SyncObjectRow | null = await objectRow(db, userId, objectId);
    if (row === null || row.deleted === 1 || row.r2_key === null) {
      throw new ApiError("not_found", "No such sync object.");
    }
    await reserveSyncClassB(db, now);
    const blob: R2ObjectBody | null = await bucket.get(row.r2_key);
    if (blob !== null) {
      return new Response(blob.body, {
        status: 200,
        headers: { "content-type": "application/octet-stream", "x-sync-rev": String(row.rev), "x-sync-kind": row.kind, "content-length": String(blob.size) },
      });
    }
    // A concurrent write replaced the object and deleted this blob between the index read and the get: read again.
    const latest: SyncObjectRow | null = await objectRow(db, userId, objectId);
    if (latest?.rev === row.rev || attempt >= readObjectAttempts) {
      // The index points to a blob that is gone without a newer revision: never expected (writes commit the index
      // after the upload).
      log("alert", "sync_blob_missing", { userId, objectId, rev: row.rev, attempt });
      throw new ApiError("internal_error", "The sync object could not be read.");
    }
  }
}

/**
 * Writes an object: the blob goes to a new random R2 key first, then one D1 transaction takes the next revision and
 * repoints the index only if the object is still at `If-Match`; the replaced blob is deleted afterwards. A lost race
 * deletes the new blob and answers `sync_conflict`.
 */
async function writeObject(
  db: D1Database,
  bucket: R2Bucket,
  config: Config,
  userId: string,
  objectId: string,
  request: Request,
  now: Date,
): Promise<object> {
  await requireSyncWriteAccess(db, config, userId, now);
  const account: SyncAccountRow = await requireAccount(db, userId);
  const kind: SyncObjectKind = kindHeader(request);
  const baseRev: number = baseRevHeader(request);
  const device: string | null = deviceHeader(request);
  if (!(request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/octet-stream")) {
    throw new ApiError("unsupported_media_type", "The request body must be application/octet-stream.");
  }
  const blob: Uint8Array = await readBodyBytes(request, syncObjectMaxBytes);
  requireValidBlob(blob, account.key_id, baseRev);
  const current: SyncObjectRow | null = await objectRow(db, userId, objectId);
  if (current === null ? baseRev !== 0 : current.rev !== baseRev) {
    throw new ApiError("sync_conflict", "The object changed on another device; merge and retry.");
  }
  if (current !== null && current.kind !== kind) {
    throw new ApiError("bad_request", "An object's kind cannot change.");
  }
  const live: boolean = current !== null && current.deleted === 0;
  const objectDelta: number = live ? 0 : 1;
  const byteDelta: number = blob.byteLength - (live ? (current?.size ?? 0) : 0);
  if (account.object_count + objectDelta > syncAccountMaxObjects || account.stored_bytes + byteDelta > syncAccountMaxBytes) {
    throw new ApiError("sync_quota_exceeded", "This account's synced copy is full; delete old meetings or chats and try again.");
  }
  if (byteDelta > 0) {
    await requireSyncStorageBudget(db, byteDelta, now);
  }
  await reserveSyncClassA(db, now);
  const r2Key: string = `${syncEpochPrefix(userId, account.enabled_at)}${objectId}/${randomToken(12)}`;
  await bucket.put(r2Key, blob);
  const nowMs: number = now.getTime();
  const stillAtBase: string =
    current === null
      ? "NOT EXISTS (SELECT 1 FROM sync_objects WHERE user_id = ?1 AND object_id = ?2)"
      : "EXISTS (SELECT 1 FROM sync_objects WHERE user_id = ?1 AND object_id = ?2 AND rev = ?3)";
  const bump: D1PreparedStatement = db
    .prepare(
      `UPDATE sync_accounts SET last_rev = last_rev + 1, object_count = object_count + ?4, stored_bytes = stored_bytes + ?5,
         access_seen_at = ?6, updated_at = ?6
       WHERE user_id = ?1 AND enabled_at = ?7 AND ${stillAtBase}`,
    )
    .bind(userId, objectId, baseRev, objectDelta, byteDelta, nowMs, account.enabled_at);
  const write: D1PreparedStatement =
    current === null
      ? db
          .prepare(
            `INSERT INTO sync_objects (user_id, object_id, kind, rev, size, deleted, r2_key, updated_at, updated_by_device)
             SELECT ?1, ?2, ?3, last_rev, ?4, 0, ?5, ?6, ?7 FROM sync_accounts
             WHERE user_id = ?1 AND enabled_at = ?8 AND NOT EXISTS (SELECT 1 FROM sync_objects WHERE user_id = ?1 AND object_id = ?2)
             RETURNING rev`,
          )
          .bind(userId, objectId, kind, blob.byteLength, r2Key, nowMs, device, account.enabled_at)
      : db
          .prepare(
            `UPDATE sync_objects SET rev = (SELECT last_rev FROM sync_accounts WHERE user_id = ?1), size = ?4, deleted = 0, r2_key = ?5,
               updated_at = ?6, updated_by_device = ?7
             WHERE user_id = ?1 AND object_id = ?2 AND rev = ?3
               AND EXISTS (SELECT 1 FROM sync_accounts WHERE user_id = ?1 AND enabled_at = ?8)
             RETURNING rev`,
          )
          .bind(userId, objectId, baseRev, blob.byteLength, r2Key, nowMs, device, account.enabled_at);
  const results: D1Result[] = await db.batch([bump, write]);
  const written: { rev: number } | undefined = (results[1]?.results as Array<{ rev: number }> | undefined)?.[0];
  if (written === undefined) {
    await bucket.delete(r2Key);
    throw new ApiError("sync_conflict", "The object changed on another device; merge and retry.");
  }
  if (current?.r2_key !== null && current?.r2_key !== undefined) {
    await bucket.delete(current.r2_key);
  }
  return { objectId, rev: written.rev };
}

/** Deletes an object: it becomes a tombstone with the next revision and its blob is removed. Repeating is harmless. */
async function deleteObject(db: D1Database, bucket: R2Bucket, userId: string, objectId: string, request: Request, now: Date): Promise<object> {
  await requireAccount(db, userId);
  const baseRev: number = baseRevHeader(request);
  const device: string | null = deviceHeader(request);
  const current: SyncObjectRow | null = await objectRow(db, userId, objectId);
  if (current === null) {
    throw new ApiError("not_found", "No such sync object.");
  }
  if (current.rev !== baseRev) {
    throw new ApiError("sync_conflict", "The object changed on another device; merge and retry.");
  }
  if (current.deleted === 1) {
    return { objectId, rev: current.rev };
  }
  const nowMs: number = now.getTime();
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE sync_accounts SET last_rev = last_rev + 1, object_count = object_count - 1, stored_bytes = stored_bytes - ?4, updated_at = ?5
         WHERE user_id = ?1 AND EXISTS (SELECT 1 FROM sync_objects WHERE user_id = ?1 AND object_id = ?2 AND rev = ?3 AND deleted = 0)`,
      )
      .bind(userId, objectId, baseRev, current.size, nowMs),
    db
      .prepare(
        `UPDATE sync_objects SET rev = (SELECT last_rev FROM sync_accounts WHERE user_id = ?1), size = 0, deleted = 1, r2_key = NULL,
           updated_at = ?4, updated_by_device = ?5
         WHERE user_id = ?1 AND object_id = ?2 AND rev = ?3 AND deleted = 0
         RETURNING rev`,
      )
      .bind(userId, objectId, baseRev, nowMs, device),
  ]);
  const deleted: { rev: number } | undefined = (results[1]?.results as Array<{ rev: number }> | undefined)?.[0];
  if (deleted === undefined) {
    throw new ApiError("sync_conflict", "The object changed on another device; merge and retry.");
  }
  if (current.r2_key !== null) {
    await bucket.delete(current.r2_key);
  }
  return { objectId, rev: deleted.rev };
}

async function listEnvelopes(db: D1Database, userId: string, now: Date): Promise<object> {
  await requireAccount(db, userId);
  const rows: D1Result<{ envelope_id: string; kind: SyncEnvelopeKind; ciphertext: string; created_at: number; expires_at: number | null }> = await db
    .prepare(
      `SELECT envelope_id, kind, ciphertext, created_at, expires_at FROM sync_key_envelopes
       WHERE user_id = ? AND (expires_at IS NULL OR expires_at > ?) ORDER BY created_at`,
    )
    .bind(userId, now.getTime())
    .all();
  return {
    envelopes: rows.results.map((row) => ({
      envelopeId: row.envelope_id,
      kind: row.kind,
      ciphertext: row.ciphertext,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
    })),
  };
}

/** Stores a key envelope; a new recovery envelope replaces the old one, pairing envelopes expire after 10 minutes. */
async function putEnvelope(db: D1Database, userId: string, envelopeId: string, request: Request, now: Date): Promise<object> {
  await requireAccount(db, userId);
  const body = await readJsonBody(request, envelopeSchema, syncEnvelopeMaxChars + 512);
  const nowMs: number = now.getTime();
  const live: { count: number } | null = await db
    .prepare("SELECT COUNT(*) AS count FROM sync_key_envelopes WHERE user_id = ? AND envelope_id <> ? AND (expires_at IS NULL OR expires_at > ?)")
    .bind(userId, envelopeId, nowMs)
    .first<{ count: number }>();
  if ((live?.count ?? 0) >= syncAccountMaxEnvelopes) {
    throw new ApiError("sync_quota_exceeded", "Too many pending key envelopes; wait for pairing requests to expire.");
  }
  const expiresAt: number | null = body.kind === "pairing" ? nowMs + syncPairingTtlMs : null;
  await db.batch([
    ...(body.kind === "recovery"
      ? [db.prepare("DELETE FROM sync_key_envelopes WHERE user_id = ? AND kind = 'recovery' AND envelope_id <> ?").bind(userId, envelopeId)]
      : []),
    db
      .prepare(
        `INSERT INTO sync_key_envelopes (user_id, envelope_id, kind, ciphertext, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(user_id, envelope_id) DO UPDATE SET kind = excluded.kind, ciphertext = excluded.ciphertext,
           created_at = excluded.created_at, expires_at = excluded.expires_at`,
      )
      .bind(userId, envelopeId, body.kind, body.ciphertext, nowMs, expiresAt),
  ]);
  return { envelopeId, kind: body.kind, expiresAt };
}

async function deleteEnvelope(db: D1Database, userId: string, envelopeId: string): Promise<object> {
  const result: D1Result = await db.prepare("DELETE FROM sync_key_envelopes WHERE user_id = ? AND envelope_id = ?").bind(userId, envelopeId).run();
  return { deleted: result.meta.changes > 0 };
}

/**
 * Statements that remove an account's sync data from D1 and queue an R2 prefix for deletion (`sync_purges`), in
 * child-first order: account deletion (`account.ts`) queues the whole account (`syncPrefix`), opting out and the end
 * of retention queue the wiped epoch (`syncEpochPrefix`).
 */
export function syncDeletionStatements(db: D1Database, userId: string, prefix: string, now: Date): D1PreparedStatement[] {
  return [
    db
      .prepare("INSERT INTO sync_purges (prefix, requested_at) VALUES (?, ?) ON CONFLICT(prefix) DO UPDATE SET requested_at = excluded.requested_at")
      .bind(prefix, now.getTime()),
    db.prepare("DELETE FROM sync_objects WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM sync_key_envelopes WHERE user_id = ?").bind(userId),
    db.prepare("DELETE FROM sync_accounts WHERE user_id = ?").bind(userId),
  ];
}

/** Result of deleting an R2 prefix. */
export interface PurgeResult {
  readonly deletedBlobs: number;
  /** No blob is left under the prefix (its `sync_purges` row was removed). */
  readonly complete: boolean;
}

/**
 * Deletes the blobs under a queued prefix, at most `maxPages` pages of 1000; when nothing is left the `sync_purges` row
 * is removed. R2 errors propagate: the row stays and the daily cleanup retries.
 */
export async function purgeSyncPrefix(db: D1Database, bucket: R2Bucket, prefix: string, maxPages: number, now: Date): Promise<PurgeResult> {
  let deletedBlobs: number = 0;
  for (let page: number = 0; page < maxPages; page += 1) {
    await countSyncClassA(db, now);
    const listed: R2Objects = await bucket.list({ prefix, limit: 1000 });
    if (listed.objects.length === 0) {
      await db.prepare("DELETE FROM sync_purges WHERE prefix = ?").bind(prefix).run();
      return { deletedBlobs, complete: true };
    }
    await bucket.delete(listed.objects.map((object: R2Object): string => object.key));
    deletedBlobs += listed.objects.length;
  }
  log("warn", "sync_purge_incomplete", { deletedBlobs });
  return { deletedBlobs, complete: false };
}

/**
 * Deletes the blobs of a queued prefix right away. A failure is logged and left to the daily cleanup (the D1 rows are
 * already gone and the prefix stays in `sync_purges`); it does not fail the user's request.
 */
export async function purgeSyncPrefixNow(db: D1Database, bucket: R2Bucket, userId: string, prefix: string, now: Date): Promise<PurgeResult> {
  try {
    return await purgeSyncPrefix(db, bucket, prefix, immediatePurgePages, now);
  } catch (error: unknown) {
    log("warn", "sync_purge_deferred", { userId, error: errorName(error) });
    return { deletedBlobs: 0, complete: false };
  }
}

/** Turns sync off and removes the account's whole server copy (opt-out, or "start over" with a new key). */
export async function wipeSyncAccount(db: D1Database, bucket: R2Bucket, userId: string, now: Date): Promise<{ readonly objects: number; readonly purged: boolean }> {
  const account: SyncAccountRow | null = await accountRow(db, userId);
  if (account === null) {
    return { objects: 0, purged: true };
  }
  const count: { count: number } | null = await db.prepare("SELECT COUNT(*) AS count FROM sync_objects WHERE user_id = ? AND deleted = 0").bind(userId).first<{ count: number }>();
  const prefix: string = syncEpochPrefix(userId, account.enabled_at);
  await db.batch(syncDeletionStatements(db, userId, prefix, now));
  const purge: PurgeResult = await purgeSyncPrefixNow(db, bucket, userId, prefix, now);
  log("info", "sync_wiped", { userId, objects: count?.count ?? 0, purged: purge.complete });
  return { objects: count?.count ?? 0, purged: purge.complete };
}

/** Routes `/v1/sync/…` for an authenticated, rate-limited user. */
export async function routeSync(request: Request, db: D1Database, bucket: R2Bucket, config: Config, path: string, userId: string, now: Date): Promise<Response> {
  if (config.syncPolicy === "off") {
    throw new ApiError("sync_unavailable", "Sync is not available yet.");
  }
  const method: string = request.method;
  if (path === "/v1/sync/account") {
    if (method === "GET") {
      return jsonResponse(200, syncAccountBody(await accountRow(db, userId)));
    }
    if (method === "POST") {
      const body = await readJsonBody(request, enableSchema, 1024);
      return jsonResponse(200, await enableSync(db, config, userId, body.keyId, now));
    }
    if (method === "DELETE") {
      const wiped = await wipeSyncAccount(db, bucket, userId, now);
      return jsonResponse(200, { deleted: true, objects: wiped.objects });
    }
  }
  if (path === "/v1/sync/changes" && method === "GET") {
    return jsonResponse(200, await listChanges(db, userId, new URL(request.url)));
  }
  const objectMatch: RegExpExecArray | null = objectPath.exec(path);
  if (objectMatch !== null) {
    const objectId: string = uuidOf(objectMatch);
    if (method === "GET") {
      return readObject(db, bucket, userId, objectId, now);
    }
    if (method === "PUT") {
      return jsonResponse(200, await writeObject(db, bucket, config, userId, objectId, request, now));
    }
    if (method === "DELETE") {
      return jsonResponse(200, await deleteObject(db, bucket, userId, objectId, request, now));
    }
  }
  if (path === "/v1/sync/envelopes" && method === "GET") {
    return jsonResponse(200, await listEnvelopes(db, userId, now));
  }
  const envelopeMatch: RegExpExecArray | null = envelopePath.exec(path);
  if (envelopeMatch !== null) {
    const envelopeId: string = uuidOf(envelopeMatch);
    if (method === "PUT") {
      return jsonResponse(200, await putEnvelope(db, userId, envelopeId, request, now));
    }
    if (method === "DELETE") {
      return jsonResponse(200, await deleteEnvelope(db, userId, envelopeId));
    }
  }
  throw new ApiError("not_found", "No such endpoint.");
}

/** Daily sync cleanup report. */
export interface SyncCleanupReport {
  readonly [step: string]: number;
  readonly retentionChecked: number;
  readonly retentionWiped: number;
  readonly purgedPrefixes: number;
  readonly purgedBlobs: number;
}

/** Accounts checked for ended access per run, and queued prefixes purged per run. */
export interface SyncCleanupLimits {
  readonly accounts: number;
  readonly prefixes: number;
  readonly pagesPerPrefix: number;
}

export const scheduledSyncCleanupLimits: SyncCleanupLimits = { accounts: 50, prefixes: 20, pagesPerPrefix: 5 };

/**
 * Daily sync cleanup (R2 and access; tombstones and expired pairing envelopes are D1-only steps in `cleanup.ts`):
 * - accounts not seen with access for `syncAccessRetentionDays` are checked again: still entitled (a subscriber who
 *   only read) refreshes the date, otherwise the server copy is wiped;
 * - queued R2 prefixes (`sync_purges`) are deleted.
 */
export async function syncCleanup(db: D1Database, bucket: R2Bucket, config: Config, now: Date, limits: SyncCleanupLimits): Promise<SyncCleanupReport> {
  const cutoff: number = now.getTime() - syncAccessRetentionDays * dayMs;
  const stale: D1Result<{ user_id: string; enabled_at: number }> = await db
    .prepare("SELECT user_id, enabled_at FROM sync_accounts WHERE access_seen_at < ? ORDER BY access_seen_at LIMIT ?")
    .bind(cutoff, limits.accounts)
    .all<{ user_id: string; enabled_at: number }>();
  let wiped: number = 0;
  for (const { user_id: userId, enabled_at: epoch } of stale.results) {
    if (await hasSyncAccess(db, config, userId, now)) {
      await db.prepare("UPDATE sync_accounts SET access_seen_at = ? WHERE user_id = ?").bind(now.getTime(), userId).run();
    } else {
      await db.batch(syncDeletionStatements(db, userId, syncEpochPrefix(userId, epoch), now));
      log("info", "sync_retention_wiped", { userId });
      wiped += 1;
    }
  }
  const prefixes: D1Result<{ prefix: string }> = await db
    .prepare("SELECT prefix FROM sync_purges ORDER BY requested_at LIMIT ?")
    .bind(limits.prefixes)
    .all<{ prefix: string }>();
  let purgedPrefixes: number = 0;
  let purgedBlobs: number = 0;
  for (const { prefix } of prefixes.results) {
    const result: PurgeResult = await purgeSyncPrefix(db, bucket, prefix, limits.pagesPerPrefix, now);
    purgedPrefixes += result.complete ? 1 : 0;
    purgedBlobs += result.deletedBlobs;
  }
  const report: SyncCleanupReport = { retentionChecked: stale.results.length, retentionWiped: wiped, purgedPrefixes, purgedBlobs };
  log("info", "sync_cleanup_done", report);
  return report;
}
