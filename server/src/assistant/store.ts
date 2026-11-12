import { randomId } from "../crypto";
import { ApiError } from "../errors";
import { errorName, log } from "../log";
import { type AssistantKeyring, openField, openUserFields, sealField } from "./crypto";
import {
  type MeetingIndex,
  type MeetingProjection,
  type ProjectionUpload,
  assistantAccountMaxBytes,
  assistantAccountMaxMeetings,
  encodedNote,
  indexMaxBytes,
  meetingIndex,
  meetingIndexSchema,
  meetingProjection,
  meetingProjectionSchema,
} from "./projection";

/**
 * Storage of the AI assistant copy, shared by the API Worker (apps upload and delete) and the `gistsmith-mcp` Worker
 * (assistants read): settings, meeting rows and connections in the EU D1 database (`ASSISTANT_DB`), sealed notes in the
 * EU R2 bucket (`ASSISTANT_BUCKET`, the sync bucket) under `a/<user>/<epoch>/<meeting>/<object id>` (every upload
 * is a new object; the row names the current one).
 *
 * Every query is scoped by the user id from the caller's token, never from a request body: two accounts with the same
 * meeting id never meet (primary key `(user_id, meeting_id)`, user id in the R2 key and in the encryption's
 * additional data).
 */

/** `assistant_settings` row. */
export interface AssistantSettingsRow {
  readonly enabled: number;
  readonly epoch: number;
  readonly updated_at: number;
  readonly access_lost_at: number | null;
}

/** `GET`/`PUT /v1/assistant/settings` body. */
export interface AssistantSettingsBody {
  readonly enabled: boolean;
  /** Uploads must name this epoch; it changes whenever the feature is turned off. */
  readonly epoch: number;
  readonly meetings: number;
  readonly maxMeetings: number;
}

/** One connection as the apps list it. */
export interface AssistantGrantBody {
  readonly grantId: string;
  readonly clientName: string;
  readonly redirectHost: string;
  readonly verified: boolean;
  readonly createdAt: string;
  readonly lastUsedAt: string | null;
  /** When the connection read more than 100 meetings within an hour (the apps show a notice); else null. */
  readonly heavyReadAt: string | null;
}

/** `assistant_grants` row. */
export interface AssistantGrantRow {
  readonly grant_id: string;
  readonly client_id: string;
  readonly client_name: string;
  readonly redirect_host: string;
  readonly verified: number;
  readonly created_at: number;
  readonly last_used_at: number | null;
  readonly heavy_read_at: number | null;
}

/** An index row with its decrypted index. */
export interface IndexedMeeting {
  readonly meetingId: string;
  readonly startedAtMs: number;
  readonly index: MeetingIndex;
}

/** Result of deleting an R2 prefix. */
export interface AssistantPurgeResult {
  readonly deletedObjects: number;
  readonly complete: boolean;
}

/** First epoch of an account. */
const firstEpoch: number = 1;
/** Pages (1000 keys each) an immediate purge deletes before leaving the rest to the daily cleanup. */
const immediatePurgePages: number = 5;

/** R2 prefix of all of an account's objects. Pure function. */
export function assistantPrefix(userId: string): string {
  return `a/${userId}/`;
}

/** R2 prefix of one epoch of an account. Pure function. */
export function assistantEpochPrefix(userId: string, epoch: number): string {
  return `${assistantPrefix(userId)}${epoch}/`;
}

/** R2 key of one upload of a meeting's sealed note. Pure function. */
export function assistantObjectKey(userId: string, epoch: number, meetingId: string, objectId: string): string {
  return `${assistantEpochPrefix(userId, epoch)}${meetingId}/${objectId}`;
}

/** Settings body; a missing row is "off" at the first epoch. Pure function. */
export function assistantSettingsBody(row: AssistantSettingsRow | null, meetings: number): AssistantSettingsBody {
  return { enabled: row?.enabled === 1, epoch: row?.epoch ?? firstEpoch, meetings, maxMeetings: assistantAccountMaxMeetings };
}

/** Connection body. Pure function. */
export function assistantGrantBody(row: AssistantGrantRow): AssistantGrantBody {
  return {
    grantId: row.grant_id,
    clientName: row.client_name,
    redirectHost: row.redirect_host,
    verified: row.verified === 1,
    createdAt: new Date(row.created_at).toISOString(),
    lastUsedAt: row.last_used_at === null ? null : new Date(row.last_used_at).toISOString(),
    heavyReadAt: row.heavy_read_at === null ? null : new Date(row.heavy_read_at).toISOString(),
  };
}

export async function assistantSettings(adb: D1Database, userId: string): Promise<AssistantSettingsRow | null> {
  return adb
    .prepare("SELECT enabled, epoch, updated_at, access_lost_at FROM assistant_settings WHERE user_id = ?")
    .bind(userId)
    .first<AssistantSettingsRow>();
}

export async function assistantMeetingCount(adb: D1Database, userId: string): Promise<number> {
  const row: { count: number } | null = await adb.prepare("SELECT COUNT(*) AS count FROM assistant_meetings WHERE user_id = ?").bind(userId).first<{ count: number }>();
  if (row === null) {
    throw new Error("COUNT over assistant_meetings returned no row.");
  }
  return row.count;
}

/** Turns the feature on (keeps the current epoch; a new account starts at `firstEpoch`). */
export async function enableAssistant(adb: D1Database, userId: string, now: Date): Promise<AssistantSettingsRow> {
  const nowMs: number = now.getTime();
  await adb
    .prepare(
      `INSERT INTO assistant_settings (user_id, enabled, epoch, updated_at, access_lost_at, access_checked_at) VALUES (?1, 1, ?2, ?3, NULL, ?3)
       ON CONFLICT(user_id) DO UPDATE SET enabled = 1, updated_at = ?3, access_lost_at = NULL, access_checked_at = ?3`,
    )
    .bind(userId, firstEpoch, nowMs)
    .run();
  const row: AssistantSettingsRow | null = await assistantSettings(adb, userId);
  if (row === null) {
    throw new Error("assistant_settings row missing right after its upsert.");
  }
  return row;
}

/** Queues the KV revocation of the user's connections (all, or one) and deletes their D1 rows. */
function grantRemovalStatements(adb: D1Database, userId: string, grantId: string | null, nowMs: number): D1PreparedStatement[] {
  // `?3 IS NULL` selects every connection of the user.
  return [
    adb
      .prepare(
        `INSERT INTO assistant_revocations (user_id, grant_id, requested_at)
         SELECT user_id, grant_id, ?2 FROM assistant_grants WHERE user_id = ?1 AND (?3 IS NULL OR grant_id = ?3)
         ON CONFLICT(user_id, grant_id) DO NOTHING`,
      )
      .bind(userId, nowMs, grantId),
    adb.prepare("DELETE FROM assistant_grants WHERE user_id = ?1 AND (?2 IS NULL OR grant_id = ?2)").bind(userId, grantId),
  ];
}

function purgeQueueStatement(adb: D1Database, prefix: string, nowMs: number): D1PreparedStatement {
  return adb
    .prepare("INSERT INTO assistant_purges (prefix, requested_at) VALUES (?, ?) ON CONFLICT(prefix) DO UPDATE SET requested_at = excluded.requested_at")
    .bind(prefix, nowMs);
}

/**
 * The settings state a turn-off was decided on, re-checked inside the turn-off's own transaction so a decision made on
 * an older read never touches a newer state:
 * - `enabled`: the user turned the feature off while it was on at `epoch`;
 * - `access_lost`: the daily cleanup saw it on at `epoch` with access lost since `accessLostAt` (a re-enable, a new
 *   subscription clearing the mark, or an off/on cycle in between all change one of these columns).
 */
export type AssistantDisableGuard =
  | { readonly kind: "enabled"; readonly epoch: number }
  | { readonly kind: "access_lost"; readonly epoch: number; readonly accessLostAt: number };

/** The guard as an `EXISTS` condition over `assistant_settings` with its positional binds. Pure function. */
export function assistantDisableGuardSql(userId: string, guard: AssistantDisableGuard): { readonly sql: string; readonly binds: readonly (string | number)[] } {
  const base: string = "SELECT 1 FROM assistant_settings WHERE user_id = ? AND enabled = 1 AND epoch = ?";
  return guard.kind === "enabled"
    ? { sql: `EXISTS (${base})`, binds: [userId, guard.epoch] }
    : { sql: `EXISTS (${base} AND access_lost_at = ?)`, binds: [userId, guard.epoch, guard.accessLostAt] };
}

/**
 * Turning off (or access ended for 7 days): one D1 transaction queues the revocation of every connection, deletes the
 * connections and meeting rows, queues the epoch's R2 prefix and moves to the next epoch, so uploads prepared under the
 * old epoch are refused. Every statement carries the guard (`assistantDisableGuardSql`) and the epoch moves last, so
 * either all of them apply to the state the turn-off was decided on or none does; the last statement's row count
 * says which.
 */
function disableStatements(adb: D1Database, userId: string, guard: AssistantDisableGuard, nowMs: number): D1PreparedStatement[] {
  const condition: { readonly sql: string; readonly binds: readonly (string | number)[] } = assistantDisableGuardSql(userId, guard);
  return [
    adb
      .prepare(
        `INSERT INTO assistant_revocations (user_id, grant_id, requested_at)
         SELECT user_id, grant_id, ? FROM assistant_grants WHERE user_id = ? AND ${condition.sql}
         ON CONFLICT(user_id, grant_id) DO NOTHING`,
      )
      .bind(nowMs, userId, ...condition.binds),
    adb.prepare(`DELETE FROM assistant_grants WHERE user_id = ? AND ${condition.sql}`).bind(userId, ...condition.binds),
    adb.prepare(`DELETE FROM assistant_meetings WHERE user_id = ? AND ${condition.sql}`).bind(userId, ...condition.binds),
    adb
      .prepare(
        `INSERT INTO assistant_purges (prefix, requested_at) SELECT ?, ? WHERE ${condition.sql}
         ON CONFLICT(prefix) DO UPDATE SET requested_at = excluded.requested_at`,
      )
      .bind(assistantEpochPrefix(userId, guard.epoch), nowMs, ...condition.binds),
    adb
      .prepare(`UPDATE assistant_settings SET enabled = 0, epoch = epoch + 1, updated_at = ?, access_lost_at = NULL WHERE user_id = ? AND ${condition.sql}`)
      .bind(nowMs, userId, ...condition.binds),
  ];
}

/**
 * Applies a guarded turn-off and deletes the epoch's objects at once; true if it applied (false: the state changed
 * since it was read, nothing was touched).
 */
async function applyDisable(adb: D1Database, bucket: R2Bucket, userId: string, guard: AssistantDisableGuard, now: Date): Promise<boolean> {
  const results: D1Result[] = await adb.batch(disableStatements(adb, userId, guard, now.getTime()));
  if (results.at(-1)?.meta.changes !== 1) {
    log("info", "assistant_disable_skipped", { userId, guard: guard.kind, epoch: guard.epoch });
    return false;
  }
  const purge: AssistantPurgeResult = await purgeAssistantPrefixNow(adb, bucket, userId, assistantEpochPrefix(userId, guard.epoch));
  log("info", "assistant_disabled", { userId, guard: guard.kind, purged: purge.complete });
  return true;
}

/**
 * Statements that remove an account's whole assistant copy (account deletion): connections queued for KV revocation,
 * rows deleted, the account's R2 prefix queued.
 */
export function assistantDeletionStatements(adb: D1Database, userId: string, now: Date): D1PreparedStatement[] {
  const nowMs: number = now.getTime();
  return [
    ...grantRemovalStatements(adb, userId, null, nowMs),
    adb.prepare("DELETE FROM assistant_meetings WHERE user_id = ?").bind(userId),
    adb.prepare("DELETE FROM assistant_settings WHERE user_id = ?").bind(userId),
    purgeQueueStatement(adb, assistantPrefix(userId), nowMs),
  ];
}

/** Deletes the objects under a queued prefix (at most `maxPages` pages); removes the queue row once nothing is left. */
export async function purgeAssistantPrefix(adb: D1Database, bucket: R2Bucket, prefix: string, maxPages: number): Promise<AssistantPurgeResult> {
  let deletedObjects: number = 0;
  for (let page: number = 0; page < maxPages; page += 1) {
    const listed: R2Objects = await bucket.list({ prefix, limit: 1000 });
    if (listed.objects.length === 0) {
      await adb.prepare("DELETE FROM assistant_purges WHERE prefix = ?").bind(prefix).run();
      return { deletedObjects, complete: true };
    }
    await bucket.delete(listed.objects.map((object: R2Object): string => object.key));
    deletedObjects += listed.objects.length;
  }
  log("warn", "assistant_purge_incomplete", { deletedObjects });
  return { deletedObjects, complete: false };
}

/**
 * Deletes a queued prefix right away. The D1 rows are already gone (the copy is unreadable); an R2 failure is logged
 * and left to the daily cleanup, which retries every queued prefix.
 */
export async function purgeAssistantPrefixNow(adb: D1Database, bucket: R2Bucket, userId: string, prefix: string): Promise<AssistantPurgeResult> {
  try {
    return await purgeAssistantPrefix(adb, bucket, prefix, immediatePurgePages);
  } catch (error: unknown) {
    log("warn", "assistant_purge_deferred", { userId, error: errorName(error) });
    return { deletedObjects: 0, complete: false };
  }
}

/**
 * Turns the feature off and deletes the copy at once (idempotent). If another turn-off moved the epoch in between, that
 * one already did the work; the current settings are returned either way.
 */
export async function disableAssistant(adb: D1Database, bucket: R2Bucket, userId: string, now: Date): Promise<AssistantSettingsRow | null> {
  const row: AssistantSettingsRow | null = await assistantSettings(adb, userId);
  if (row === null || row.enabled === 0) {
    return row;
  }
  await applyDisable(adb, bucket, userId, { kind: "enabled", epoch: row.epoch }, now);
  return assistantSettings(adb, userId);
}

/**
 * The daily cleanup's deletion after access ended: turns the feature off only if it is still on at `epoch` with the
 * same access-loss mark the cleanup read; true if it applied.
 */
export async function disableAssistantAfterAccessLoss(adb: D1Database, bucket: R2Bucket, userId: string, epoch: number, accessLostAt: number, now: Date): Promise<boolean> {
  return applyDisable(adb, bucket, userId, { kind: "access_lost", epoch, accessLostAt }, now);
}

/** Removes an account's whole copy (account deletion, or the account no longer exists). */
export async function deleteAssistantAccount(adb: D1Database, bucket: R2Bucket, userId: string, now: Date): Promise<void> {
  await adb.batch(assistantDeletionStatements(adb, userId, now));
  await purgeAssistantPrefixNow(adb, bucket, userId, assistantPrefix(userId));
}

/** `ms` of an ISO 8601 timestamp the schema already validated. Pure function. */
function isoMs(value: string): number {
  const ms: number = Date.parse(value);
  if (!Number.isFinite(ms)) {
    throw new ApiError("invalid_body", "startedAt is not a valid timestamp.");
  }
  return ms;
}

/** Why an upload's conditional insert changed nothing (read after the fact, only to pick the error). */
async function uploadRefusal(adb: D1Database, userId: string, epoch: number): Promise<ApiError> {
  const settings: AssistantSettingsRow | null = await assistantSettings(adb, userId);
  if (settings === null || settings.enabled === 0 || settings.epoch !== epoch) {
    return new ApiError("assistant_epoch_mismatch", "AI assistant access was turned off while uploading; read the settings and upload again.");
  }
  return new ApiError(
    "assistant_quota_exceeded",
    `The assistant copy holds at most ${assistantAccountMaxMeetings} meetings and ${assistantAccountMaxBytes / (1024 * 1024)} MB; remove old meetings first.`,
  );
}

/**
 * Stores one meeting. The sealed note goes to R2 as a new object, then one statement inserts or updates the row only
 * while the feature is on at the upload's epoch and the account stays within `assistantAccountMaxMeetings` and
 * `assistantAccountMaxBytes` (counted without this meeting's current row): no check-then-write gap, so parallel uploads
 * cannot pass the limits together. If that statement changes nothing, only the new object is deleted (the row still
 * names the previous one, which stays readable) and the upload is refused. After an update the previous object is
 * deleted.
 */
export async function putAssistantMeeting(
  adb: D1Database,
  bucket: R2Bucket,
  keyring: AssistantKeyring,
  userId: string,
  meetingId: string,
  upload: ProjectionUpload,
  now: Date,
): Promise<{ readonly meetingId: string; readonly size: number }> {
  const settings: AssistantSettingsRow | null = await assistantSettings(adb, userId);
  if (settings === null || settings.enabled === 0) {
    throw new ApiError("assistant_not_enabled", "AI assistant access is off for this account; turn it on first.");
  }
  if (settings.epoch !== upload.epoch) {
    throw new ApiError("assistant_epoch_mismatch", "AI assistant access was turned off and on again; read the settings and upload again.");
  }
  const projection: MeetingProjection = meetingProjection(upload);
  const sealedNote: Uint8Array = await sealField(keyring, userId, meetingId, "note", encodedNote(projection));
  const sealedIndex: Uint8Array = await sealField(keyring, userId, meetingId, "index", new TextEncoder().encode(JSON.stringify(meetingIndex(projection))));
  const objectId: string = randomId();
  const key: string = assistantObjectKey(userId, settings.epoch, meetingId, objectId);
  await bucket.put(key, sealedNote);
  // The object the row names is read in the same transaction as the write that replaces it: a parallel update of the
  // same meeting that wrote its row after this upload began is the one replaced, and its object is deleted below.
  const previousRead: D1PreparedStatement = adb.prepare("SELECT object_id FROM assistant_meetings WHERE user_id = ? AND meeting_id = ?").bind(userId, meetingId);
  const upsert: D1PreparedStatement = adb
    .prepare(
      `INSERT INTO assistant_meetings (user_id, meeting_id, device_id, started_at, updated_at, size, index_ct, object_id)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?9 FROM assistant_settings
       WHERE user_id = ?1 AND enabled = 1 AND epoch = ?8
         AND (EXISTS (SELECT 1 FROM assistant_meetings WHERE user_id = ?1 AND meeting_id = ?2)
              OR (SELECT COUNT(*) FROM assistant_meetings WHERE user_id = ?1) < ?10)
         AND (SELECT COALESCE(SUM(size + LENGTH(index_ct)), 0) FROM assistant_meetings WHERE user_id = ?1 AND meeting_id <> ?2)
             + ?6 + LENGTH(?7) <= ?11
       ON CONFLICT(user_id, meeting_id) DO UPDATE SET device_id = excluded.device_id, started_at = excluded.started_at,
         updated_at = excluded.updated_at, size = excluded.size, index_ct = excluded.index_ct, object_id = excluded.object_id`,
    )
    .bind(
      userId,
      meetingId,
      upload.deviceId.toLowerCase(),
      isoMs(upload.startedAt),
      now.getTime(),
      sealedNote.byteLength,
      sealedIndex,
      settings.epoch,
      objectId,
      assistantAccountMaxMeetings,
      assistantAccountMaxBytes,
    );
  const [previousResult, result] = await adb.batch<{ object_id: string }>([previousRead, upsert]);
  if (previousResult === undefined || result === undefined) {
    throw new Error("A D1 batch of two statements returned fewer results.");
  }
  if (result.meta.changes === 0) {
    await bucket.delete(key);
    throw await uploadRefusal(adb, userId, settings.epoch);
  }
  const previous: { object_id: string } | undefined = previousResult.results[0];
  if (previous !== undefined) {
    await bucket.delete(assistantObjectKey(userId, settings.epoch, meetingId, previous.object_id));
  }
  return { meetingId, size: sealedNote.byteLength };
}

/** Deletes one meeting from the copy (repeating is harmless). */
export async function deleteAssistantMeeting(adb: D1Database, bucket: R2Bucket, userId: string, meetingId: string): Promise<boolean> {
  const settings: AssistantSettingsRow | null = await assistantSettings(adb, userId);
  const deleted: { object_id: string } | null = await adb
    .prepare("DELETE FROM assistant_meetings WHERE user_id = ? AND meeting_id = ? RETURNING object_id")
    .bind(userId, meetingId)
    .first<{ object_id: string }>();
  if (settings !== null && deleted !== null) {
    await bucket.delete(assistantObjectKey(userId, settings.epoch, meetingId, deleted.object_id));
  }
  return deleted !== null;
}

/** Deletes every meeting a (lost) device uploaded. */
export async function deleteAssistantDevice(adb: D1Database, bucket: R2Bucket, userId: string, deviceId: string): Promise<number> {
  const settings: AssistantSettingsRow | null = await assistantSettings(adb, userId);
  const rows: D1Result<{ meeting_id: string; object_id: string }> = await adb
    .prepare("DELETE FROM assistant_meetings WHERE user_id = ? AND device_id = ? RETURNING meeting_id, object_id")
    .bind(userId, deviceId)
    .all<{ meeting_id: string; object_id: string }>();
  if (settings !== null && rows.results.length > 0) {
    const keys: string[] = rows.results.map((row): string => assistantObjectKey(userId, settings.epoch, row.meeting_id, row.object_id));
    for (let start: number = 0; start < keys.length; start += 1000) {
      await bucket.delete(keys.slice(start, start + 1000));
    }
  }
  return rows.results.length;
}

export async function listAssistantGrants(adb: D1Database, userId: string): Promise<AssistantGrantRow[]> {
  const rows: D1Result<AssistantGrantRow> = await adb
    .prepare(
      `SELECT grant_id, client_id, client_name, redirect_host, verified, created_at, last_used_at, heavy_read_at
       FROM assistant_grants WHERE user_id = ? ORDER BY created_at DESC`,
    )
    .bind(userId)
    .all<AssistantGrantRow>();
  return rows.results;
}

/** Disconnects one assistant: the row goes at once (the next call is refused), the KV revocation is queued. */
export async function deleteAssistantGrant(adb: D1Database, userId: string, grantId: string, now: Date): Promise<boolean> {
  const results: D1Result[] = await adb.batch(grantRemovalStatements(adb, userId, grantId, now.getTime()));
  return (results[1]?.meta.changes ?? 0) > 0;
}

/** Listing bounds: `started_at` range and the position after which a page continues (exclusive). */
export interface IndexBounds {
  readonly sinceMs: number | null;
  readonly untilMs: number | null;
  readonly before: { readonly startedAtMs: number; readonly meetingId: string } | null;
}

/** How much of a user's index one call decrypts: at most `rows` rows and `bytes` sealed bytes. */
export interface ScanLimits {
  readonly rows: number;
  readonly bytes: number;
}

/** Decrypted index rows; `truncated` when more rows matched than the scan limits allowed. */
export interface IndexScan {
  readonly meetings: IndexedMeeting[];
  readonly truncated: boolean;
}

/**
 * Index rows of a user, newest first (ties by meeting id), decrypted, within `limits`: D1 returns the sealed index only
 * for rows whose running total of sealed bytes fits `limits.bytes` (later rows come back without it and only mark the
 * scan as truncated), so memory stays bounded however large the account's copy is.
 */
export async function indexedMeetings(adb: D1Database, keyring: AssistantKeyring, userId: string, bounds: IndexBounds, limits: ScanLimits): Promise<IndexScan> {
  const rows: D1Result<{ meeting_id: string; started_at: number; index_ct: ArrayBuffer | null }> = await adb
    .prepare(
      `SELECT meeting_id, started_at, CASE WHEN running <= ?7 THEN index_ct END AS index_ct FROM (
         SELECT meeting_id, started_at, index_ct,
           SUM(LENGTH(index_ct)) OVER (ORDER BY started_at DESC, meeting_id DESC ROWS UNBOUNDED PRECEDING) AS running
         FROM assistant_meetings
         WHERE user_id = ?1 AND (?2 IS NULL OR started_at >= ?2) AND (?3 IS NULL OR started_at < ?3)
           AND (?5 IS NULL OR started_at < ?5 OR (started_at = ?5 AND meeting_id < ?6))
         ORDER BY started_at DESC, meeting_id DESC LIMIT ?4
       ) ORDER BY started_at DESC, meeting_id DESC`,
    )
    .bind(userId, bounds.sinceMs, bounds.untilMs, limits.rows + 1, bounds.before?.startedAtMs ?? null, bounds.before?.meetingId ?? null, limits.bytes)
    .all<{ meeting_id: string; started_at: number; index_ct: ArrayBuffer | null }>();
  const kept: Array<{ meeting_id: string; started_at: number; index_ct: ArrayBuffer }> = [];
  for (const row of rows.results.slice(0, limits.rows)) {
    if (row.index_ct === null) {
      break;
    }
    if (row.index_ct.byteLength > indexMaxBytes * 2) {
      throw new Error("A sealed meeting index is larger than any index the server writes.");
    }
    kept.push({ meeting_id: row.meeting_id, started_at: row.started_at, index_ct: row.index_ct });
  }
  const decoder: TextDecoder = new TextDecoder();
  const plaintexts: Uint8Array[] = await openUserFields(
    keyring,
    userId,
    "index",
    kept.map((row) => ({ meetingId: row.meeting_id, sealed: new Uint8Array(row.index_ct) })),
  );
  const meetings: IndexedMeeting[] = kept.map((row, index: number): IndexedMeeting => {
    const plaintext: Uint8Array | undefined = plaintexts[index];
    if (plaintext === undefined) {
      throw new Error("openUserFields returned fewer fields than it was given.");
    }
    return { meetingId: row.meeting_id, startedAtMs: row.started_at, index: meetingIndexSchema.parse(JSON.parse(decoder.decode(plaintext))) };
  });
  return { meetings, truncated: rows.results.length > kept.length };
}

/** One meeting's full copy, or null when the user has no such meeting. */
export async function assistantMeeting(
  adb: D1Database,
  bucket: R2Bucket,
  keyring: AssistantKeyring,
  userId: string,
  meetingId: string,
): Promise<MeetingProjection | null> {
  const row: { epoch: number; object_id: string } | null = await adb
    .prepare(
      `SELECT s.epoch AS epoch, m.object_id AS object_id FROM assistant_meetings m JOIN assistant_settings s ON s.user_id = m.user_id
       WHERE m.user_id = ? AND m.meeting_id = ?`,
    )
    .bind(userId, meetingId)
    .first<{ epoch: number; object_id: string }>();
  if (row === null) {
    return null;
  }
  const object: R2ObjectBody | null = await bucket.get(assistantObjectKey(userId, row.epoch, meetingId, row.object_id));
  if (object === null) {
    log("alert", "assistant_object_missing", { userId, meetingId });
    throw new Error("The meeting's row exists but its sealed note is missing.");
  }
  const plaintext: Uint8Array = await openField(keyring, userId, meetingId, "note", new Uint8Array(await object.arrayBuffer()));
  return meetingProjectionSchema.parse(JSON.parse(new TextDecoder().decode(plaintext)));
}
