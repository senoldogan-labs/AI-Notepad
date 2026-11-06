import { z } from "zod";
import type { Config } from "./config";
import { hasPaidAccess, hasRunningTrial, userTrialState } from "./entitlements";
import { ApiError } from "./errors";
import { jsonResponse, readBodyBytes } from "./http";
import { log } from "./log";

/**
 * Sharing a note with a link, end to end encrypted (design and threat model: the PR that added this file).
 *
 * The app renders the note to JSON, compresses it and seals it with AES-256-GCM under a fresh random key per share
 * (Swift `sealNoteShare`); only the sealed blob and a random 128-bit share id reach the server. The key lives only in
 * the link's fragment (`https://gistsmith.com/s#<shareId>.<key>`), which browsers never send to any server, so the
 * server cannot read a shared note. The site's share page (`web/src/client/share.ts`) fetches the blob from
 * `GET /v1/public/shares/:id` and decrypts it in the browser.
 *
 * Storage: D1 table `note_shares` (ciphertext as a BLOB, at most `shareMaxBytes`; the production database is in the
 * EU). Revoking deletes the row at once; expired rows answer 404 right away and the daily cleanup deletes them
 * (`cleanup.ts`); account deletion deletes them in the same transaction (`account.ts`). No meeting id or title is
 * stored: the apps remember on the device which link belongs to which meeting.
 *
 * Abuse limits (free file hosting, spam): creating needs a subscription or a running trial, at most
 * `shareMaxActivePerUser` live links per account, `shareMaxBytes` each, expiry of at most 90 days, a global storage
 * budget (`shareStoredBytesBudget`, then `503 share_unavailable` and an alert), a per-IP limit on public reads, and
 * the blob is served as an attachment no browser renders. The lists and limits are mirrored by the Swift client
 * (`ServerParityTests`).
 */

/** Blob format marker (`GSS1`), written by the client (`noteShareMagic`). */
export const shareBlobMagic: string = "GSS1";
/** Magic + 12-byte nonce + 16-byte tag (empty plaintext). */
export const shareBlobMinBytes: number = 4 + 12 + 16;
/**
 * Largest blob. A note alone is a few KB compressed; with the transcript a meeting is ~1 MB of JSON per hour, which
 * compresses ~6x (the sync measurement, `sync.ts`), so a 4-hour meeting with its transcript is ~0.7 MB. D1 allows 2 MB
 * per row.
 */
export const shareMaxBytes: number = 1_048_576;
/** Live (not expired) links per account. */
export const shareMaxActivePerUser: number = 50;
/** Expiries the user can choose (days). */
export const shareExpiryDays: readonly number[] = [7, 30, 90];
/**
 * Stored ciphertext across all accounts: 1 GB of D1's 10 GB. Reaching it means abuse or far more use than planned;
 * creating stops (`503 share_unavailable`, alert) until links expire or are removed. Reading and removing never stop.
 */
export const shareStoredBytesBudget: number = 1_000_000_000;

const dayMs: number = 86_400_000;
/** 16 random bytes in base64url without padding. */
const shareIdPattern: RegExp = /^[A-Za-z0-9_-]{22}$/;
const ownSharePath: RegExp = /^\/v1\/shares\/([^/]+)$/;
/** Public read path; the site's share page calls it from the browser (CORS, see `app.ts`). */
export const publicSharePath: RegExp = /^\/v1\/public\/shares\/([^/]+)$/;

/** A live link as the owner sees it (no ciphertext). */
export interface ShareSummary {
  readonly shareId: string;
  readonly size: number;
  /** Milliseconds since 1970. */
  readonly createdAt: number;
  readonly expiresAt: number;
}

interface ShareRow {
  readonly share_id: string;
  readonly size: number;
  readonly created_at: number;
  readonly expires_at: number;
}

/** `GET /v1/shares` body. */
export interface ShareListBody {
  readonly shares: readonly ShareSummary[];
  readonly maxActive: number;
}

function summaryOf(row: ShareRow): ShareSummary {
  return { shareId: row.share_id, size: row.size, createdAt: row.created_at, expiresAt: row.expires_at };
}

/** Share id from a path match; `null` when malformed. Pure function. */
function shareIdOf(match: RegExpExecArray): string | null {
  const value: string | undefined = match[1];
  return value !== undefined && shareIdPattern.test(value) ? value : null;
}

/** `x-share-id` header (22 base64url characters); otherwise `bad_request`. Pure function. */
function shareIdHeader(request: Request): string {
  const value: string | null = request.headers.get("x-share-id");
  if (value === null || !shareIdPattern.test(value)) {
    throw new ApiError("bad_request", "The x-share-id header must be 16 random bytes in base64url (22 characters).");
  }
  return value;
}

/** `x-share-expires-days` header (7, 30 or 90); otherwise `bad_request`. Pure function. */
function expiryDaysHeader(request: Request): number {
  const parsed = z.coerce
    .number()
    .int()
    .refine((days: number): boolean => shareExpiryDays.includes(days))
    .safeParse(request.headers.get("x-share-expires-days"));
  if (!parsed.success) {
    throw new ApiError("bad_request", `The x-share-expires-days header must be one of: ${shareExpiryDays.join(", ")}.`);
  }
  return parsed.data;
}

/** Checks the blob's format marker and minimum length; the server never decrypts. Pure function. */
export function requireShareBlob(blob: Uint8Array): void {
  if (blob.byteLength < shareBlobMinBytes || new TextDecoder().decode(blob.subarray(0, 4)) !== shareBlobMagic) {
    throw new ApiError("invalid_body", "The body is not a sealed shared note.");
  }
}

/** Creating a link needs a subscription or a running trial (like sync writes); otherwise `subscription_required`. */
async function requireShareAccess(db: D1Database, config: Config, userId: string, now: Date): Promise<void> {
  if (await hasPaidAccess(db, config, userId, now)) {
    return;
  }
  if (hasRunningTrial(await userTrialState(db, userId), config, now)) {
    return;
  }
  throw new ApiError("subscription_required", "Sharing a note with a link needs a subscription.");
}

/**
 * Stores a new link. One statement inserts the row only while the account is under `shareMaxActivePerUser` live links
 * and the global storage stays within `shareStoredBytesBudget`, so concurrent requests cannot pass either limit; when
 * nothing was inserted the reason is looked up afterwards. Repeating the same upload (the response was lost and the
 * client retried) returns the stored link; another blob under an existing id is `share_exists` (ids are random).
 */
async function createShare(db: D1Database, config: Config, userId: string, request: Request, now: Date): Promise<ShareSummary> {
  await requireShareAccess(db, config, userId, now);
  const shareId: string = shareIdHeader(request);
  const expiryDays: number = expiryDaysHeader(request);
  if (!(request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/octet-stream")) {
    throw new ApiError("unsupported_media_type", "The request body must be application/octet-stream.");
  }
  const blob: Uint8Array = await readBodyBytes(request, shareMaxBytes);
  requireShareBlob(blob);
  const nowMs: number = now.getTime();
  const expiresAt: number = nowMs + expiryDays * dayMs;
  const inserted: ShareRow | null = await db
    .prepare(
      `INSERT INTO note_shares (share_id, user_id, ciphertext, size, created_at, expires_at)
       SELECT ?1, ?2, ?3, ?4, ?5, ?6
       WHERE (SELECT COUNT(*) FROM note_shares WHERE user_id = ?2 AND expires_at > ?5) < ?7
         AND (SELECT COALESCE(SUM(size), 0) FROM note_shares) + ?4 <= ?8
       ON CONFLICT (share_id) DO NOTHING
       RETURNING share_id, size, created_at, expires_at`,
    )
    .bind(shareId, userId, blob, blob.byteLength, nowMs, expiresAt, shareMaxActivePerUser, shareStoredBytesBudget)
    .first<ShareRow>();
  if (inserted !== null) {
    log("info", "share_created", { userId, size: blob.byteLength, expiryDays });
    return summaryOf(inserted);
  }
  const existing: (ShareRow & { readonly user_id: string }) | null = await db
    .prepare("SELECT share_id, user_id, size, created_at, expires_at FROM note_shares WHERE share_id = ?")
    .bind(shareId)
    .first<ShareRow & { readonly user_id: string }>();
  if (existing !== null) {
    if (existing.user_id === userId && existing.size === blob.byteLength) {
      return summaryOf(existing);
    }
    throw new ApiError("share_exists", "A link with this id already exists; create the link again.");
  }
  const live: { count: number } | null = await db
    .prepare("SELECT COUNT(*) AS count FROM note_shares WHERE user_id = ? AND expires_at > ?")
    .bind(userId, nowMs)
    .first<{ count: number }>();
  if ((live?.count ?? 0) >= shareMaxActivePerUser) {
    throw new ApiError("share_limit_reached", `An account can keep at most ${shareMaxActivePerUser} links; remove old links and try again.`);
  }
  log("alert", "share_storage_budget_reached", { budgetBytes: shareStoredBytesBudget });
  throw new ApiError("share_unavailable", "Sharing with a link is paused for now; try again later.");
}

/** The account's live links, newest first. */
async function listShares(db: D1Database, userId: string, now: Date): Promise<ShareListBody> {
  const rows: D1Result<ShareRow> = await db
    .prepare("SELECT share_id, size, created_at, expires_at FROM note_shares WHERE user_id = ? AND expires_at > ? ORDER BY created_at DESC")
    .bind(userId, now.getTime())
    .all<ShareRow>();
  return { shares: rows.results.map(summaryOf), maxActive: shareMaxActivePerUser };
}

/** Removes the owner's link at once; another account's, unknown or already removed id is `not_found`. */
async function deleteShare(db: D1Database, userId: string, shareId: string): Promise<object> {
  const result: D1Result = await db.prepare("DELETE FROM note_shares WHERE share_id = ? AND user_id = ?").bind(shareId, userId).run();
  if (result.meta.changes === 0) {
    throw new ApiError("not_found", "No such link.");
  }
  log("info", "share_deleted", { userId });
  return { deleted: true };
}

/** Routes `/v1/shares…` for an authenticated, rate-limited user. */
export async function routeShares(request: Request, db: D1Database, config: Config, path: string, userId: string, now: Date): Promise<Response> {
  const method: string = request.method;
  if (path === "/v1/shares") {
    if (method === "POST") {
      return jsonResponse(201, await createShare(db, config, userId, request, now));
    }
    if (method === "GET") {
      return jsonResponse(200, await listShares(db, userId, now));
    }
  }
  const match: RegExpExecArray | null = ownSharePath.exec(path);
  if (match !== null && method === "DELETE") {
    const shareId: string | null = shareIdOf(match);
    if (shareId === null) {
      throw new ApiError("not_found", "No such link.");
    }
    return jsonResponse(200, await deleteShare(db, userId, shareId));
  }
  throw new ApiError("not_found", "No such endpoint.");
}

/**
 * `GET /v1/public/shares/:id` (no session): the sealed blob of a live link. Unknown, malformed, expired (even before the
 * daily cleanup) and removed ids all answer the same 404. The blob is never cached or indexed.
 */
export async function readPublicShare(db: D1Database, match: RegExpExecArray, now: Date): Promise<Response> {
  const shareId: string | null = shareIdOf(match);
  const row: { ciphertext: ArrayBuffer } | null =
    shareId === null
      ? null
      : await db
          .prepare("SELECT ciphertext FROM note_shares WHERE share_id = ? AND expires_at > ?")
          .bind(shareId, now.getTime())
          .first<{ ciphertext: ArrayBuffer }>();
  if (row === null) {
    throw new ApiError("not_found", "This link does not exist, has expired or was removed.");
  }
  // D1 hands BLOBs back as a byte array; copy into a typed array for the body (same as `transcriptionCache.ts`).
  return new Response(new Uint8Array(row.ciphertext), {
    status: 200,
    headers: {
      // `finalizeResponse` (app.ts) adds `default-src 'none'`, nosniff and no-referrer to every response.
      "content-type": "application/octet-stream",
      "cache-control": "no-store",
      "x-robots-tag": "noindex, nofollow",
    },
  });
}

/** Statement that deletes all of an account's links (account deletion, `account.ts`). */
export function shareDeletionStatement(db: D1Database, userId: string): D1PreparedStatement {
  return db.prepare("DELETE FROM note_shares WHERE user_id = ?").bind(userId);
}
