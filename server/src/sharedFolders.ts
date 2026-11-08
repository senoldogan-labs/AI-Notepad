import { z } from "zod";
import type { Config } from "./config";
import { randomToken } from "./crypto";
import { ApiError } from "./errors";
import { jsonResponse, readBodyBytes, readJsonBody } from "./http";
import { log } from "./log";
import { hasSyncAccess, purgeSyncPrefixNow, reserveSyncClassA, reserveSyncClassB, requireSyncStorageBudget } from "./sync";

/**
 * Shared folders, end to end encrypted (design and threat model: docs/superpowers/specs/2026-11-08-shared-folders.md).
 *
 * The owner's devices seal everything before it leaves them (Swift `SharedFolderCrypto`): folder metadata and notes with
 * the folder's keyring (AES-256-GCM, signed with the owner's Ed25519 key), the keyring itself wrapped to each member's
 * X25519 key (HPKE), invite labels and secrets with a key only the owner's devices hold. The server stores public keys,
 * sealed values, signatures and an index; item blobs go to R2 (`SYNC_BUCKET`, prefix `f/<folder>/`) inside sync's
 * free-tier budgets. It never sees a folder name, label, display name or note.
 *
 * Membership: invites carry a secret only in the link's fragment; an account that accepts proves it knew the secret
 * (HMAC over its own public keys), and an owner device verifies that proof before it adds the account to the
 * owner-signed roster and wraps the keyring to it. The server checks that a roster change matches the member rows it
 * holds and applies it with compare-and-set on `key_epoch` and `members_version`, but it cannot sign a roster, so it
 * cannot add a key of its own. Removing a member is a rotation: a new epoch whose keyring only the remaining members
 * get. Leaving and a member's account deletion set `needs_rotation`, which blocks new items until an owner device
 * rotates.
 *
 * Access: owner routes check `owner_id`; item reads need an `active` member row. Strangers get 404 (ids cannot be
 * probed). Creating folders, invites and items needs the owner's subscription or trial; rotation, removal and stopping
 * never do. Members need nothing (`SHARED_FOLDERS_MEMBER_ACCESS=free`) or a subscription or trial (`subscription`).
 *
 * The limits below are mirrored by the Swift client (`ServerParityTests`).
 */

export const sharedFolderItemMagic: string = "GSF1";
/** Magic + epoch (4) + nonce (12) + tag (16) + signature (64). */
export const sharedFolderItemMinBytes: number = 4 + 4 + 12 + 16 + 64;
export const sharedFolderItemMaxBytes: number = 1_048_576;
export const sharedFolderMaxItems: number = 1000;
export const sharedFolderOwnerMaxBytes: number = 104_857_600;
export const sharedFolderMaxOwned: number = 20;
export const sharedFolderMaxMemberships: number = 100;
/** Members plus open invites per folder. */
export const sharedFolderMaxMembers: number = 50;
export const sharedFolderMaxOpenInvites: number = 20;
export const sharedFolderInvitesPerDay: number = 30;
export const sharedFolderInviteTtlDays: number = 7;
/** An accepted invite that no owner device activated is dropped after this many days. */
export const sharedFolderAcceptedTtlDays: number = 30;
/** Another owner device may take over publishing when the publisher was not seen for this long. */
export const sharedFolderPublisherLeaseDays: number = 3;
/** Days a folder stays after its owner was last seen with a subscription or trial. */
export const sharedFolderAccessRetentionDays: number = 90;

const dayMs: number = 86_400_000;
const key32 = z.string().regex(/^[A-Za-z0-9+/]{43}=$/);
const sealed = (max: number) => z.base64().min(1).max(max);
const memberIdSchema = z.string().regex(/^[A-Za-z0-9_-]{22}$/);
const uuidSchema = z.uuid();
const folderPath: RegExp = /^\/v1\/shared-folders\/([0-9a-f-]{36})(\/.*)?$/;
const invitePath: RegExp = /^\/v1\/shared-invites\/([A-Za-z0-9_-]{22})(\/accept)?$/;
const itemPath: RegExp = /^\/items\/([0-9a-f-]{36})$/;
const memberPath: RegExp = /^\/invites\/([A-Za-z0-9_-]{22})$/;

const identitySchema = z.strictObject({
  agreementKey: key32,
  signingKey: key32,
  sealedSeed: sealed(512).nullable(),
  seedKeyId: z.string().regex(/^[0-9a-f]{32}$/).nullable(),
});

/** The roster as the owner signs it (JSON text; the server parses it to compare with the member rows). */
const rosterSchema = z.strictObject({
  folderId: uuidSchema,
  version: z.number().int().min(1),
  epoch: z.number().int().min(1),
  members: z
    .array(z.strictObject({ memberId: memberIdSchema, userId: z.string().min(1).max(64), agreementKey: key32, signingKey: key32 }))
    .max(sharedFolderMaxMembers),
});
type Roster = z.infer<typeof rosterSchema>;

const createSchema = z.strictObject({
  folderId: uuidSchema,
  sealedMeta: sealed(8192),
  ownerEnvelope: sealed(65_536),
  roster: z.string().min(1).max(32_768),
  rosterSignature: sealed(128),
  publisherDevice: uuidSchema,
});

const rosterChangeSchema = z.strictObject({
  keyEpoch: z.number().int().min(1),
  expectedMembersVersion: z.number().int().min(0),
  roster: z.string().min(1).max(32_768),
  rosterSignature: sealed(128),
  sealedMeta: sealed(8192).nullable(),
  ownerEnvelope: sealed(65_536).nullable(),
  envelopes: z.array(z.strictObject({ memberId: memberIdSchema, envelope: sealed(65_536) })).max(sharedFolderMaxMembers),
});

const inviteSchema = z.strictObject({
  memberId: memberIdSchema,
  sealedLabel: sealed(2048),
  sealedSecret: sealed(512),
  ownerProof: sealed(64),
  sealedPreview: sealed(2048),
});

const acceptSchema = z.strictObject({ memberProof: sealed(64), sealedName: sealed(1024), sealedPin: sealed(2048) });
const publisherSchema = z.strictObject({ device: uuidSchema });

/** Who may accept and read as a member (`SHARED_FOLDERS_MEMBER_ACCESS`). */
export type SharedFoldersMemberAccess = "free" | "subscription";

interface IdentityRow {
  readonly agreement_key: string;
  readonly signing_key: string;
  readonly sealed_seed: string | null;
  readonly seed_key_id: string | null;
}

interface FolderRow {
  readonly folder_id: string;
  readonly owner_id: string;
  readonly sealed_meta: string;
  readonly key_epoch: number;
  readonly owner_envelope: string;
  readonly roster: string;
  readonly roster_signature: string;
  readonly roster_version: number;
  readonly members_version: number;
  readonly items_rev: number;
  readonly needs_rotation: number;
  readonly publisher_device: string;
  readonly publisher_seen_at: number;
  readonly updated_at: number;
}

interface MemberRow {
  readonly folder_id: string;
  readonly member_id: string;
  readonly status: "invited" | "accepted" | "active";
  readonly user_id: string | null;
  readonly sealed_label: string;
  readonly sealed_secret: string;
  readonly owner_proof: string;
  readonly sealed_preview: string;
  readonly expires_at: number;
  readonly member_agreement_key: string | null;
  readonly member_signing_key: string | null;
  readonly member_proof: string | null;
  readonly sealed_name: string | null;
  readonly sealed_pin: string | null;
  readonly envelope: string | null;
  readonly envelope_epoch: number | null;
  readonly created_at: number;
}

interface ItemRow {
  readonly item_id: string;
  readonly key_epoch: number;
  readonly tag: string;
  readonly size: number;
  readonly r2_key: string;
  readonly rev: number;
  readonly updated_at: number;
}

/** One folder in `GET /v1/shared-folders`. */
export interface SharedFolderBody {
  readonly folderId: string;
  readonly role: "owner" | "member";
  readonly ownerAgreementKey: string;
  readonly ownerSigningKey: string;
  /**
   * Sealed metadata and the signed roster (member ids, user ids and public keys of the active members): null for a member
   * whose acceptance no owner device has confirmed yet, who must not learn who else is in the folder.
   */
  readonly sealedMeta: string | null;
  readonly keyEpoch: number;
  readonly roster: string | null;
  readonly rosterSignature: string | null;
  readonly rosterVersion: number;
  readonly membersVersion: number;
  readonly itemsRev: number;
  readonly needsRotation: boolean;
  /** The keyring wrapped to this account (owner envelope, or the member's own); null while waiting for activation. */
  readonly envelope: string | null;
  readonly envelopeEpoch: number | null;
  /** Member only: the invite that brought this account, its state and the owner keys it pinned. */
  readonly memberId: string | null;
  readonly memberStatus: "accepted" | "active" | null;
  readonly sealedPin: string | null;
  /** Owner only: the publishing device and when it was last seen. */
  readonly publisherDevice: string | null;
  readonly publisherSeenAt: number | null;
}

/** R2 prefix of a folder's item blobs. Pure function. */
export function sharedFolderPrefix(folderId: string): string {
  return `f/${folderId}/`;
}

/** Item header check: magic and the epoch the upload claims; the server never decrypts. Pure function. */
export function requireSharedFolderItem(blob: Uint8Array, epoch: number): void {
  if (blob.byteLength < sharedFolderItemMinBytes || new TextDecoder().decode(blob.subarray(0, 4)) !== sharedFolderItemMagic) {
    throw new ApiError("invalid_body", "The body is not a sealed shared-folder item.");
  }
  const view: DataView = new DataView(blob.buffer, blob.byteOffset + 4, 4);
  if (view.getUint32(0) !== epoch) {
    throw new ApiError("invalid_body", "The item's epoch does not match x-item-epoch.");
  }
}

/** Parses a roster text; malformed is `invalid_body`. Pure function. */
export function parseRoster(text: string): Roster {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new ApiError("invalid_body", "The roster is not JSON.");
  }
  const parsed = rosterSchema.safeParse(raw);
  if (!parsed.success) {
    throw new ApiError("invalid_body", "The roster does not have the expected fields.");
  }
  return parsed.data;
}

/** The member's own row as the folder list needs it. */
type MemberView = Pick<MemberRow, "member_id" | "status" | "envelope" | "envelope_epoch" | "sealed_pin">;

function folderBody(row: FolderRow & IdentityRow, member: MemberView | null): SharedFolderBody {
  const owner: boolean = member === null;
  const confirmed: boolean = owner || member?.status === "active";
  return {
    folderId: row.folder_id,
    role: owner ? "owner" : "member",
    ownerAgreementKey: row.agreement_key,
    ownerSigningKey: row.signing_key,
    sealedMeta: confirmed ? row.sealed_meta : null,
    keyEpoch: row.key_epoch,
    roster: confirmed ? row.roster : null,
    rosterSignature: confirmed ? row.roster_signature : null,
    rosterVersion: row.roster_version,
    membersVersion: row.members_version,
    itemsRev: row.items_rev,
    needsRotation: row.needs_rotation === 1,
    envelope: owner ? row.owner_envelope : (member?.envelope ?? null),
    envelopeEpoch: owner ? row.key_epoch : (member?.envelope_epoch ?? null),
    memberId: member?.member_id ?? null,
    memberStatus: member === null ? null : member.status === "active" ? "active" : "accepted",
    sealedPin: member?.sealed_pin ?? null,
    publisherDevice: owner ? row.publisher_device : null,
    publisherSeenAt: owner ? row.publisher_seen_at : null,
  };
}

async function identityOf(db: D1Database, userId: string): Promise<IdentityRow | null> {
  return db.prepare("SELECT agreement_key, signing_key, sealed_seed, seed_key_id FROM sharing_identities WHERE user_id = ?").bind(userId).first<IdentityRow>();
}

async function requireIdentity(db: D1Database, userId: string): Promise<IdentityRow> {
  const identity: IdentityRow | null = await identityOf(db, userId);
  if (identity === null) {
    throw new ApiError("sharing_identity_required", "Set up shared folders on this account first.");
  }
  return identity;
}

/** Owner writes (create, invite, publish) need a subscription or a running trial. */
async function requireOwnerWriteAccess(db: D1Database, config: Config, userId: string, now: Date): Promise<void> {
  if (!(await hasSyncAccess(db, config, userId, now))) {
    throw new ApiError("subscription_required", "Sharing new notes needs a subscription; your members keep what is already shared.");
  }
}

/** Member access under `SHARED_FOLDERS_MEMBER_ACCESS=subscription`; nothing under `free`. */
async function requireMemberAccess(db: D1Database, config: Config, userId: string, now: Date): Promise<void> {
  if (config.sharedFolders.memberAccess === "subscription" && !(await hasSyncAccess(db, config, userId, now))) {
    throw new ApiError("subscription_required", "Reading shared folders needs a subscription or a trial.");
  }
}

async function ownedFolder(db: D1Database, userId: string, folderId: string): Promise<FolderRow> {
  const row: FolderRow | null = await db.prepare("SELECT * FROM shared_folders WHERE folder_id = ? AND owner_id = ?").bind(folderId, userId).first<FolderRow>();
  if (row === null) {
    throw new ApiError("not_found", "No such shared folder.");
  }
  return row;
}

/** The folder when the user owns it or is an active member; otherwise `not_found`. */
async function readableFolder(db: D1Database, config: Config, userId: string, folderId: string, now: Date): Promise<FolderRow> {
  const row: FolderRow | null = await db
    .prepare(
      `SELECT f.* FROM shared_folders f WHERE f.folder_id = ?1 AND (f.owner_id = ?2 OR EXISTS (
         SELECT 1 FROM shared_folder_members m WHERE m.folder_id = f.folder_id AND m.user_id = ?2 AND m.status = 'active'))`,
    )
    .bind(folderId, userId)
    .first<FolderRow>();
  if (row === null) {
    throw new ApiError("not_found", "No such shared folder.");
  }
  if (row.owner_id !== userId) {
    await requireMemberAccess(db, config, userId, now);
  }
  return row;
}

// MARK: identity

async function putIdentity(db: D1Database, userId: string, request: Request, now: Date): Promise<object> {
  const body = await readJsonBody(request, identitySchema, 4096);
  if ((body.sealedSeed === null) !== (body.seedKeyId === null)) {
    throw new ApiError("invalid_body", "sealedSeed and seedKeyId go together.");
  }
  const nowMs: number = now.getTime();
  await db
    .prepare(
      `INSERT INTO sharing_identities (user_id, agreement_key, signing_key, sealed_seed, seed_key_id, created_at, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6) ON CONFLICT (user_id) DO NOTHING`,
    )
    .bind(userId, body.agreementKey, body.signingKey, body.sealedSeed, body.seedKeyId, nowMs)
    .run();
  const stored: IdentityRow = await requireIdentity(db, userId);
  if (stored.agreement_key !== body.agreementKey || stored.signing_key !== body.signingKey) {
    throw new ApiError("shared_folder_conflict", "This account already has other sharing keys; open Gistsmith on a device where shared folders are set up.");
  }
  if (body.sealedSeed !== null && (stored.sealed_seed !== body.sealedSeed || stored.seed_key_id !== body.seedKeyId)) {
    await db
      .prepare("UPDATE sharing_identities SET sealed_seed = ?, seed_key_id = ?, updated_at = ? WHERE user_id = ?")
      .bind(body.sealedSeed, body.seedKeyId, nowMs, userId)
      .run();
  }
  return { identity: identityBody({ ...stored, sealed_seed: body.sealedSeed ?? stored.sealed_seed, seed_key_id: body.seedKeyId ?? stored.seed_key_id }) };
}

/** Identity as the API returns it. Pure function. */
function identityBody(row: IdentityRow): object {
  return { agreementKey: row.agreement_key, signingKey: row.signing_key, sealedSeed: row.sealed_seed, seedKeyId: row.seed_key_id };
}

/**
 * Statements that remove an account's shared-folder data, child first and before the `users` row: folders it is a
 * member of get `needs_rotation` and a new `members_version`, then its memberships go; its own folders' blobs are queued
 * for purge (`sync_purges`), then their items, members and rows go; last the identity. Used by account deletion
 * (`account.ts`) and by "Reset shared folders".
 */
export function sharedFolderDeletionStatements(db: D1Database, userId: string, now: Date): D1PreparedStatement[] {
  const nowMs: number = now.getTime();
  return [
    db
      .prepare(
        `UPDATE shared_folders SET needs_rotation = CASE WHEN EXISTS (SELECT 1 FROM shared_folder_members m WHERE m.folder_id = shared_folders.folder_id
           AND m.user_id = ?1 AND m.status = 'active') THEN 1 ELSE needs_rotation END, members_version = members_version + 1, updated_at = ?2
         WHERE folder_id IN (SELECT folder_id FROM shared_folder_members WHERE user_id = ?1)`,
      )
      .bind(userId, nowMs),
    db.prepare("DELETE FROM shared_folder_members WHERE user_id = ?").bind(userId),
    db
      .prepare(
        `INSERT INTO sync_purges (prefix, requested_at) SELECT 'f/' || folder_id || '/', ?2 FROM shared_folders WHERE owner_id = ?1
         ON CONFLICT (prefix) DO UPDATE SET requested_at = excluded.requested_at`,
      )
      .bind(userId, nowMs),
    db.prepare("DELETE FROM shared_folder_items WHERE folder_id IN (SELECT folder_id FROM shared_folders WHERE owner_id = ?)").bind(userId),
    db.prepare("DELETE FROM shared_folder_members WHERE folder_id IN (SELECT folder_id FROM shared_folders WHERE owner_id = ?)").bind(userId),
    db.prepare("DELETE FROM shared_folders WHERE owner_id = ?").bind(userId),
    db.prepare("DELETE FROM sharing_identities WHERE user_id = ?").bind(userId),
  ];
}

/**
 * Account deletion: everything `sharedFolderDeletionStatements` removes, plus the daily invite counter (which a reset
 * keeps so that resetting cannot give invites back).
 */
export function sharedFolderAccountDeletionStatements(db: D1Database, userId: string, now: Date): D1PreparedStatement[] {
  return [...sharedFolderDeletionStatements(db, userId, now), db.prepare("DELETE FROM shared_folder_invite_days WHERE user_id = ?").bind(userId)];
}

/** Deletes the R2 blobs of the account's own folders right away (after their rows are gone); failures stay queued. */
export async function purgeOwnedFolderBlobs(db: D1Database, bucket: R2Bucket, userId: string, folderIds: readonly string[], now: Date): Promise<void> {
  for (const folderId of folderIds) {
    await purgeSyncPrefixNow(db, bucket, userId, sharedFolderPrefix(folderId), now);
  }
}

async function ownedFolderIds(db: D1Database, userId: string): Promise<string[]> {
  const rows: D1Result<{ folder_id: string }> = await db.prepare("SELECT folder_id FROM shared_folders WHERE owner_id = ?").bind(userId).all<{ folder_id: string }>();
  return rows.results.map((row: { folder_id: string }): string => row.folder_id);
}

async function resetIdentity(db: D1Database, bucket: R2Bucket, userId: string, now: Date): Promise<object> {
  const owned: string[] = await ownedFolderIds(db, userId);
  await db.batch(sharedFolderDeletionStatements(db, userId, now));
  await purgeOwnedFolderBlobs(db, bucket, userId, owned, now);
  log("info", "shared_folders_reset", { userId, ownedFolders: owned.length });
  return { deleted: true, ownedFolders: owned.length };
}

// MARK: folders

async function listFolders(db: D1Database, config: Config, userId: string): Promise<object> {
  if (config.sharedFolders.policy === "off") {
    return { available: false, folders: [] };
  }
  const owned: D1Result<FolderRow & IdentityRow> = await db
    .prepare(
      `SELECT f.*, i.agreement_key, i.signing_key, i.sealed_seed, i.seed_key_id FROM shared_folders f
       JOIN sharing_identities i ON i.user_id = f.owner_id WHERE f.owner_id = ? ORDER BY f.created_at`,
    )
    .bind(userId)
    .all<FolderRow & IdentityRow>();
  const joined: D1Result<FolderRow & IdentityRow & { m_member_id: string; m_status: MemberRow["status"]; m_envelope: string | null; m_envelope_epoch: number | null; m_sealed_pin: string | null }> =
    await db
      .prepare(
        `SELECT f.*, i.agreement_key, i.signing_key, i.sealed_seed, i.seed_key_id, m.member_id AS m_member_id, m.status AS m_status,
           m.envelope AS m_envelope, m.envelope_epoch AS m_envelope_epoch, m.sealed_pin AS m_sealed_pin
         FROM shared_folder_members m JOIN shared_folders f ON f.folder_id = m.folder_id JOIN sharing_identities i ON i.user_id = f.owner_id
         WHERE m.user_id = ? AND m.status IN ('accepted', 'active') ORDER BY m.accepted_at`,
      )
      .bind(userId)
      .all();
  const folders: SharedFolderBody[] = [
    ...owned.results.map((row: FolderRow & IdentityRow): SharedFolderBody => folderBody(row, null)),
    ...joined.results.map((row) =>
      folderBody(row, {
        member_id: row.m_member_id,
        status: row.m_status,
        envelope: row.m_envelope,
        envelope_epoch: row.m_envelope_epoch,
        sealed_pin: row.m_sealed_pin,
      }),
    ),
  ];
  return { available: true, memberAccess: config.sharedFolders.memberAccess, folders };
}

async function createFolder(db: D1Database, config: Config, userId: string, request: Request, now: Date): Promise<object> {
  await requireOwnerWriteAccess(db, config, userId, now);
  await requireIdentity(db, userId);
  const body = await readJsonBody(request, createSchema, 128 * 1024);
  const roster: Roster = parseRoster(body.roster);
  if (roster.folderId !== body.folderId || roster.version !== 1 || roster.epoch !== 1 || roster.members.length > 0) {
    throw new ApiError("invalid_body", "A new folder's roster is version 1, epoch 1, with no members.");
  }
  const nowMs: number = now.getTime();
  const inserted: { folder_id: string } | null = await db
    .prepare(
      `INSERT INTO shared_folders (folder_id, owner_id, sealed_meta, key_epoch, owner_envelope, roster, roster_signature, roster_version,
         publisher_device, publisher_seen_at, created_at, updated_at, access_seen_at)
       SELECT ?1, ?2, ?3, 1, ?4, ?5, ?6, 1, ?7, ?8, ?8, ?8, ?8
       WHERE (SELECT COUNT(*) FROM shared_folders WHERE owner_id = ?2) < ?9
       ON CONFLICT (folder_id) DO NOTHING RETURNING folder_id`,
    )
    .bind(body.folderId, userId, body.sealedMeta, body.ownerEnvelope, body.roster, body.rosterSignature, body.publisherDevice, nowMs, sharedFolderMaxOwned)
    .first<{ folder_id: string }>();
  if (inserted !== null) {
    log("info", "shared_folder_created", { userId });
    return { folderId: body.folderId };
  }
  const existing: FolderRow | null = await db.prepare("SELECT * FROM shared_folders WHERE folder_id = ?").bind(body.folderId).first<FolderRow>();
  if (existing !== null) {
    if (existing.owner_id === userId && existing.roster === body.roster) {
      return { folderId: body.folderId };
    }
    throw new ApiError("shared_folder_conflict", "A shared folder with this id already exists; share the folder again.");
  }
  throw new ApiError("shared_folder_limit_reached", `An account can share at most ${sharedFolderMaxOwned} folders.`);
}

async function stopSharing(db: D1Database, bucket: R2Bucket, userId: string, folderId: string, now: Date): Promise<object> {
  const owned: { folder_id: string } | null = await db
    .prepare("SELECT folder_id FROM shared_folders WHERE folder_id = ? AND owner_id = ?")
    .bind(folderId, userId)
    .first<{ folder_id: string }>();
  if (owned === null) {
    // Already stopped (a retry after a lost response), unknown or someone else's: the same answer for all three, so
    // the endpoint tells nobody whether a folder id exists; nothing is deleted.
    return { deleted: true };
  }
  await db.batch([
    db
      .prepare("INSERT INTO sync_purges (prefix, requested_at) VALUES (?, ?) ON CONFLICT (prefix) DO UPDATE SET requested_at = excluded.requested_at")
      .bind(sharedFolderPrefix(folderId), now.getTime()),
    db.prepare("DELETE FROM shared_folder_items WHERE folder_id = ?").bind(folderId),
    db.prepare("DELETE FROM shared_folder_members WHERE folder_id = ?").bind(folderId),
    db.prepare("DELETE FROM shared_folders WHERE folder_id = ? AND owner_id = ?").bind(folderId, userId),
  ]);
  await purgeSyncPrefixNow(db, bucket, userId, sharedFolderPrefix(folderId), now);
  log("info", "shared_folder_stopped", { userId });
  return { deleted: true };
}

/** Checks a roster change against the folder and its member rows (a snapshot guarded by `members_version`). Pure. */
export function checkRosterChange(folder: FolderRow, members: readonly MemberRow[], roster: Roster, change: z.infer<typeof rosterChangeSchema>): "activation" | "rotation" {
  if (roster.folderId !== folder.folder_id || roster.epoch !== change.keyEpoch || roster.version !== folder.roster_version + 1) {
    throw new ApiError("shared_folder_conflict", "The roster does not follow the folder's current one; refresh and try again.");
  }
  const rotation: boolean = change.keyEpoch === folder.key_epoch + 1;
  if (!rotation && change.keyEpoch !== folder.key_epoch) {
    throw new ApiError("shared_folder_conflict", "The key epoch is not current; refresh and try again.");
  }
  if (rotation !== (change.sealedMeta !== null && change.ownerEnvelope !== null)) {
    throw new ApiError("invalid_body", "A rotation carries the new sealed metadata and owner envelope; an activation carries neither.");
  }
  if (!rotation && folder.needs_rotation === 1) {
    throw new ApiError("shared_folder_conflict", "A member left; rotate the folder key first.");
  }
  const rows: Map<string, MemberRow> = new Map(members.map((row: MemberRow): [string, MemberRow] => [row.member_id, row]));
  const rosterIds: Set<string> = new Set(roster.members.map((member) => member.memberId));
  if (rosterIds.size !== roster.members.length) {
    throw new ApiError("invalid_body", "The roster lists a member twice.");
  }
  for (const member of roster.members) {
    const row: MemberRow | undefined = rows.get(member.memberId);
    if (
      row === undefined ||
      (row.status !== "accepted" && row.status !== "active") ||
      row.user_id !== member.userId ||
      row.member_agreement_key !== member.agreementKey ||
      row.member_signing_key !== member.signingKey
    ) {
      throw new ApiError("shared_folder_conflict", "The roster lists a member the folder does not have; refresh and try again.");
    }
  }
  const envelopeIds: Set<string> = new Set(change.envelopes.map((entry) => entry.memberId));
  if (envelopeIds.size !== change.envelopes.length || [...envelopeIds].some((id: string): boolean => !rosterIds.has(id))) {
    throw new ApiError("invalid_body", "Every envelope must belong to one roster member.");
  }
  for (const member of roster.members) {
    const row: MemberRow | undefined = rows.get(member.memberId);
    const needsEnvelope: boolean = rotation || row?.status !== "active";
    if (needsEnvelope && !envelopeIds.has(member.memberId)) {
      throw new ApiError("invalid_body", "Every new member, and every member in a rotation, needs an envelope.");
    }
  }
  if (!rotation) {
    const activeIds: string[] = members.filter((row: MemberRow): boolean => row.status === "active").map((row: MemberRow): string => row.member_id);
    if (activeIds.some((id: string): boolean => !rosterIds.has(id))) {
      throw new ApiError("shared_folder_conflict", "Removing a member needs a new key epoch.");
    }
  }
  return rotation ? "rotation" : "activation";
}

/**
 * Activation or rotation. The first statement is the compare-and-set on epoch, roster version and `members_version`;
 * every later statement is guarded by this exact change (the new roster signature, which no concurrent request can
 * produce: the owner's signatures are randomized and cover the roster text), so a lost race changes nothing. A rotation removes the active
 * members the new roster leaves out. A retry of a change that already went through answers as the first time.
 */
async function changeRoster(db: D1Database, userId: string, folderId: string, request: Request, now: Date): Promise<object> {
  const change = await readJsonBody(request, rosterChangeSchema, 1_200_000);
  const folder: FolderRow = await ownedFolder(db, userId, folderId);
  if (folder.roster === change.roster && folder.roster_signature === change.rosterSignature) {
    return { keyEpoch: folder.key_epoch, rosterVersion: folder.roster_version, membersVersion: folder.members_version };
  }
  if (folder.members_version !== change.expectedMembersVersion) {
    throw new ApiError("shared_folder_conflict", "The members changed meanwhile; refresh and try again.");
  }
  const roster: Roster = parseRoster(change.roster);
  const members: D1Result<MemberRow> = await db.prepare("SELECT * FROM shared_folder_members WHERE folder_id = ?").bind(folderId).all<MemberRow>();
  const kind: "activation" | "rotation" = checkRosterChange(folder, members.results, roster, change);
  const nowMs: number = now.getTime();
  const newVersion: number = folder.members_version + 1;
  // Version numbers alone are not enough: two owner devices that read the same state compute the same numbers, and the
  // loser's later statements would still match after the winner committed. The signature is unique to this change.
  const guard = (signatureParameter: number): string =>
    `EXISTS (SELECT 1 FROM shared_folders WHERE folder_id = ?1 AND roster_version = ?2 AND members_version = ?3 AND roster_signature = ?${signatureParameter})`;
  const rosterIds: string = JSON.stringify(roster.members.map((member) => member.memberId));
  const statements: D1PreparedStatement[] = [
    db
      .prepare(
        `UPDATE shared_folders SET key_epoch = ?3, roster = ?4, roster_signature = ?5, roster_version = ?6, members_version = members_version + 1,
           items_rev = items_rev + ?7, needs_rotation = CASE WHEN ?7 = 1 THEN 0 ELSE needs_rotation END,
           sealed_meta = COALESCE(?8, sealed_meta), owner_envelope = COALESCE(?9, owner_envelope), updated_at = ?10
         WHERE folder_id = ?1 AND owner_id = ?2 AND key_epoch = ?11 AND roster_version = ?12 AND members_version = ?13`,
      )
      .bind(
        folderId,
        userId,
        change.keyEpoch,
        change.roster,
        change.rosterSignature,
        roster.version,
        kind === "rotation" ? 1 : 0,
        change.sealedMeta,
        change.ownerEnvelope,
        nowMs,
        folder.key_epoch,
        folder.roster_version,
        folder.members_version,
      ),
    ...change.envelopes.map(
      (entry): D1PreparedStatement =>
        db
          .prepare(
            `UPDATE shared_folder_members SET status = 'active', envelope = ?4, envelope_epoch = ?5, updated_at = ?6
             WHERE folder_id = ?1 AND member_id = ?7 AND ${guard(8)}`,
          )
          .bind(folderId, roster.version, newVersion, entry.envelope, change.keyEpoch, nowMs, entry.memberId, change.rosterSignature),
    ),
    ...(kind === "rotation"
      ? [
          db
            .prepare(
              `DELETE FROM shared_folder_members WHERE folder_id = ?1 AND status = 'active'
                 AND member_id NOT IN (SELECT value FROM json_each(?4)) AND ${guard(5)}`,
            )
            .bind(folderId, roster.version, newVersion, rosterIds, change.rosterSignature),
        ]
      : []),
  ];
  const results: D1Result[] = await db.batch(statements);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    throw new ApiError("shared_folder_conflict", "The folder changed meanwhile; refresh and try again.");
  }
  log("info", "shared_folder_roster_changed", { userId, kind, members: roster.members.length, epoch: change.keyEpoch });
  return { keyEpoch: change.keyEpoch, rosterVersion: roster.version, membersVersion: newVersion };
}

/** Publisher claim: the same device renews, any owner device takes over after the lease, `force` takes over at once. */
async function claimPublisher(db: D1Database, userId: string, folderId: string, request: Request, now: Date, force: boolean): Promise<object> {
  const body = await readJsonBody(request, publisherSchema, 1024);
  const nowMs: number = now.getTime();
  await db
    .prepare(
      `UPDATE shared_folders SET publisher_device = ?3, publisher_seen_at = ?4
       WHERE folder_id = ?1 AND owner_id = ?2 AND (?6 = 1 OR publisher_device = ?3 OR publisher_seen_at < ?5)`,
    )
    .bind(folderId, userId, body.device, nowMs, nowMs - sharedFolderPublisherLeaseDays * dayMs, force ? 1 : 0)
    .run();
  const folder: FolderRow = await ownedFolder(db, userId, folderId);
  return { publisherDevice: folder.publisher_device, publisherSeenAt: folder.publisher_seen_at };
}

// MARK: members and invites

async function listMembers(db: D1Database, userId: string, folderId: string, now: Date): Promise<object> {
  await ownedFolder(db, userId, folderId);
  const rows: D1Result<MemberRow> = await db
    .prepare("SELECT * FROM shared_folder_members WHERE folder_id = ? AND (status <> 'invited' OR expires_at > ?) ORDER BY created_at")
    .bind(folderId, now.getTime())
    .all<MemberRow>();
  return {
    members: rows.results.map((row: MemberRow) => ({
      memberId: row.member_id,
      status: row.status,
      userId: row.user_id,
      sealedLabel: row.sealed_label,
      sealedSecret: row.sealed_secret,
      sealedName: row.sealed_name,
      memberProof: row.member_proof,
      agreementKey: row.member_agreement_key,
      signingKey: row.member_signing_key,
      envelopeEpoch: row.envelope_epoch,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
    })),
  };
}

async function createInvite(db: D1Database, config: Config, userId: string, folderId: string, request: Request, now: Date): Promise<object> {
  await ownedFolder(db, userId, folderId);
  await requireOwnerWriteAccess(db, config, userId, now);
  const body = await readJsonBody(request, inviteSchema, 16 * 1024);
  const nowMs: number = now.getTime();
  const expiresAt: number = nowMs + sharedFolderInviteTtlDays * dayMs;
  const repeated: MemberRow | null = await db.prepare("SELECT * FROM shared_folder_members WHERE member_id = ?").bind(body.memberId).first<MemberRow>();
  if (repeated !== null && repeated.folder_id === folderId && repeated.owner_proof === body.ownerProof) {
    return { memberId: repeated.member_id, expiresAt: repeated.expires_at };
  }
  // One batch: the insert checks the folder limits and the daily limit (every invite created counts; revoking or a
  // reset does not give one back); the counter moves only when the row was inserted.
  const today: string = now.toISOString().slice(0, 10);
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `INSERT INTO shared_folder_members (folder_id, member_id, status, sealed_label, sealed_secret, owner_proof, sealed_preview, expires_at, created_at, updated_at)
         SELECT ?1, ?2, 'invited', ?3, ?4, ?5, ?6, ?7, ?8, ?8
         WHERE (SELECT COUNT(*) FROM shared_folder_members WHERE folder_id = ?1 AND status = 'invited' AND expires_at > ?8) < ?9
           AND (SELECT COUNT(*) FROM shared_folder_members WHERE folder_id = ?1 AND (status <> 'invited' OR expires_at > ?8)) < ?10
           AND COALESCE((SELECT count FROM shared_folder_invite_days WHERE user_id = ?11 AND day = ?12), 0) < ?13
         ON CONFLICT DO NOTHING RETURNING member_id`,
      )
      .bind(
        folderId,
        body.memberId,
        body.sealedLabel,
        body.sealedSecret,
        body.ownerProof,
        body.sealedPreview,
        expiresAt,
        nowMs,
        sharedFolderMaxOpenInvites,
        sharedFolderMaxMembers,
        userId,
        today,
        sharedFolderInvitesPerDay,
      ),
    db
      .prepare(
        `INSERT INTO shared_folder_invite_days (user_id, day, count)
         SELECT ?1, ?2, 1 WHERE EXISTS (SELECT 1 FROM shared_folder_members WHERE member_id = ?3 AND folder_id = ?4 AND created_at = ?5)
         ON CONFLICT (user_id) DO UPDATE SET count = CASE WHEN day = ?2 THEN count + 1 ELSE 1 END, day = ?2`,
      )
      .bind(userId, today, body.memberId, folderId, nowMs),
  ]);
  const inserted: { member_id: string } | undefined = (results[0]?.results as Array<{ member_id: string }> | undefined)?.[0];
  if (inserted === undefined) {
    const existing: MemberRow | null = await db.prepare("SELECT * FROM shared_folder_members WHERE member_id = ?").bind(body.memberId).first<MemberRow>();
    if (existing !== null) {
      if (existing.folder_id === folderId && existing.owner_proof === body.ownerProof) {
        return { memberId: existing.member_id, expiresAt: existing.expires_at };
      }
      throw new ApiError("shared_folder_conflict", "An invite with this id already exists; create the invite again.");
    }
    throw new ApiError(
      "shared_folder_limit_reached",
      `A folder can have ${sharedFolderMaxMembers} members and ${sharedFolderMaxOpenInvites} open invites, and an account can create ${sharedFolderInvitesPerDay} invites a day.`,
    );
  }
  await db.prepare("UPDATE shared_folders SET access_seen_at = ? WHERE folder_id = ?").bind(nowMs, folderId).run();
  log("info", "shared_folder_invite_created", { userId });
  return { memberId: body.memberId, expiresAt };
}

/** Revokes an invite, or drops an acceptance that is not active yet. Active members leave the roster by rotation. */
async function revokeInvite(db: D1Database, userId: string, folderId: string, memberId: string, now: Date): Promise<object> {
  await ownedFolder(db, userId, folderId);
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE shared_folders SET members_version = members_version + 1, updated_at = ?3 WHERE folder_id = ?1
         AND EXISTS (SELECT 1 FROM shared_folder_members WHERE folder_id = ?1 AND member_id = ?2 AND status IN ('invited', 'accepted'))`,
      )
      .bind(folderId, memberId, now.getTime()),
    db.prepare("DELETE FROM shared_folder_members WHERE folder_id = ? AND member_id = ? AND status IN ('invited', 'accepted')").bind(folderId, memberId),
  ]);
  if ((results[1]?.meta.changes ?? 0) === 0) {
    const active: { status: string } | null = await db
      .prepare("SELECT status FROM shared_folder_members WHERE folder_id = ? AND member_id = ?")
      .bind(folderId, memberId)
      .first<{ status: string }>();
    if (active !== null) {
      throw new ApiError("shared_folder_conflict", "This person is a member; remove them by rotating the folder key.");
    }
  }
  return { deleted: true };
}

async function leaveFolder(db: D1Database, userId: string, folderId: string, now: Date): Promise<object> {
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE shared_folders SET needs_rotation = CASE WHEN EXISTS (SELECT 1 FROM shared_folder_members WHERE folder_id = ?1 AND user_id = ?2
           AND status = 'active') THEN 1 ELSE needs_rotation END, members_version = members_version + 1, updated_at = ?3
         WHERE folder_id = ?1 AND EXISTS (SELECT 1 FROM shared_folder_members WHERE folder_id = ?1 AND user_id = ?2)`,
      )
      .bind(folderId, userId, now.getTime()),
    db.prepare("DELETE FROM shared_folder_members WHERE folder_id = ? AND user_id = ?").bind(folderId, userId),
  ]);
  // Nothing deleted: already left (a retry after a lost response) or never a member; both answer the same.
  if ((results[1]?.meta.changes ?? 0) > 0) {
    log("info", "shared_folder_left", { userId });
  }
  return { deleted: true };
}

async function inviteRow(db: D1Database, inviteId: string): Promise<(MemberRow & { owner_id: string }) | null> {
  return db
    .prepare("SELECT m.*, f.owner_id FROM shared_folder_members m JOIN shared_folders f ON f.folder_id = m.folder_id WHERE m.member_id = ?")
    .bind(inviteId)
    .first<MemberRow & { owner_id: string }>();
}

/** Invite state as the person holding the link sees it. Pure function. */
export function inviteState(row: MemberRow & { owner_id: string }, userId: string, nowMs: number): "open" | "own" | "accepted" | "used" | "expired" {
  if (row.owner_id === userId) {
    return "own";
  }
  if (row.user_id === userId) {
    return "accepted";
  }
  if (row.status !== "invited") {
    return "used";
  }
  return row.expires_at > nowMs ? "open" : "expired";
}

async function readInvite(db: D1Database, userId: string, inviteId: string, now: Date): Promise<object> {
  const row = await inviteRow(db, inviteId);
  if (row === null) {
    throw new ApiError("not_found", "No such invite.");
  }
  const owner: IdentityRow = await requireIdentity(db, row.owner_id);
  return {
    folderId: row.folder_id,
    state: inviteState(row, userId, now.getTime()),
    ownerAgreementKey: owner.agreement_key,
    ownerSigningKey: owner.signing_key,
    ownerProof: row.owner_proof,
    sealedPreview: row.sealed_preview,
    expiresAt: row.expires_at,
  };
}

async function acceptInvite(db: D1Database, config: Config, userId: string, inviteId: string, request: Request, now: Date): Promise<object> {
  const body = await readJsonBody(request, acceptSchema, 8 * 1024);
  const identity: IdentityRow = await requireIdentity(db, userId);
  await requireMemberAccess(db, config, userId, now);
  const row = await inviteRow(db, inviteId);
  if (row === null) {
    throw new ApiError("not_found", "No such invite.");
  }
  const nowMs: number = now.getTime();
  const state = inviteState(row, userId, nowMs);
  if (state === "accepted" && row.member_proof === body.memberProof) {
    return { folderId: row.folder_id, memberId: inviteId };
  }
  if (state === "own") {
    throw new ApiError("shared_invite_unavailable", "This is your own folder's invite.");
  }
  if (state !== "open") {
    throw new ApiError("shared_invite_unavailable", "This invite was already used or has expired; ask for a new one.");
  }
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE shared_folder_members SET status = 'accepted', user_id = ?2, member_agreement_key = ?3, member_signing_key = ?4, member_proof = ?5,
           sealed_name = ?6, sealed_pin = ?7, accepted_at = ?8, expires_at = ?9, updated_at = ?8
         WHERE member_id = ?1 AND status = 'invited' AND expires_at > ?8
           AND NOT EXISTS (SELECT 1 FROM shared_folder_members WHERE folder_id = ?10 AND user_id = ?2)
           AND (SELECT COUNT(*) FROM shared_folder_members WHERE user_id = ?2) < ?11`,
      )
      .bind(
        inviteId,
        userId,
        identity.agreement_key,
        identity.signing_key,
        body.memberProof,
        body.sealedName,
        body.sealedPin,
        nowMs,
        nowMs + sharedFolderAcceptedTtlDays * dayMs,
        row.folder_id,
        sharedFolderMaxMemberships,
      ),
    db
      .prepare(
        `UPDATE shared_folders SET members_version = members_version + 1, updated_at = ?2
         WHERE folder_id = ?1 AND EXISTS (SELECT 1 FROM shared_folder_members WHERE member_id = ?3 AND user_id = ?4 AND accepted_at = ?2)`,
      )
      .bind(row.folder_id, nowMs, inviteId, userId),
  ]);
  if ((results[0]?.meta.changes ?? 0) === 0) {
    const already: { count: number } | null = await db
      .prepare("SELECT COUNT(*) AS count FROM shared_folder_members WHERE folder_id = ? AND user_id = ?")
      .bind(row.folder_id, userId)
      .first<{ count: number }>();
    if ((already?.count ?? 0) > 0) {
      throw new ApiError("shared_folder_conflict", "You already belong to this shared folder.");
    }
    throw new ApiError("shared_folder_limit_reached", `An account can belong to at most ${sharedFolderMaxMemberships} shared folders.`);
  }
  log("info", "shared_folder_invite_accepted", { userId });
  return { folderId: row.folder_id, memberId: inviteId };
}

// MARK: items

async function listItems(db: D1Database, config: Config, userId: string, folderId: string, now: Date): Promise<object> {
  const folder: FolderRow = await readableFolder(db, config, userId, folderId, now);
  const rows: D1Result<Omit<ItemRow, "r2_key">> = await db
    .prepare("SELECT item_id, key_epoch, tag, size, rev, updated_at FROM shared_folder_items WHERE folder_id = ? ORDER BY rev")
    .bind(folderId)
    .all<Omit<ItemRow, "r2_key">>();
  return {
    itemsRev: folder.items_rev,
    items: rows.results.map((row) => ({ itemId: row.item_id, keyEpoch: row.key_epoch, tag: row.tag, size: row.size, rev: row.rev, updatedAt: row.updated_at })),
  };
}

async function readItem(db: D1Database, bucket: R2Bucket, config: Config, userId: string, folderId: string, itemId: string, now: Date): Promise<Response> {
  await readableFolder(db, config, userId, folderId, now);
  const row: ItemRow | null = await db.prepare("SELECT * FROM shared_folder_items WHERE folder_id = ? AND item_id = ?").bind(folderId, itemId).first<ItemRow>();
  if (row === null) {
    throw new ApiError("not_found", "No such item.");
  }
  await reserveSyncClassB(db, now);
  const blob: R2ObjectBody | null = await bucket.get(row.r2_key);
  if (blob === null) {
    // A concurrent write replaced the blob between the index read and the get; the client retries.
    throw new ApiError("shared_folder_conflict", "The item changed meanwhile; refresh and try again.");
  }
  return new Response(blob.body, {
    status: 200,
    headers: { "content-type": "application/octet-stream", "x-item-epoch": String(row.key_epoch), "x-item-tag": row.tag, "content-length": String(blob.size) },
  });
}

/**
 * Uploads an item from the publisher device. The blob goes to a new R2 key first; then one batch bumps `items_rev` only
 * if the folder is still at the read revision and epoch, has no pending rotation, this device publishes and the limits
 * hold, and writes the index row guarded by the new revision. A lost race deletes the new blob.
 */
async function writeItem(db: D1Database, bucket: R2Bucket, config: Config, userId: string, folderId: string, itemId: string, request: Request, now: Date): Promise<object> {
  const folder: FolderRow = await ownedFolder(db, userId, folderId);
  await requireOwnerWriteAccess(db, config, userId, now);
  const epoch = z.coerce.number().int().min(1).safeParse(request.headers.get("x-item-epoch"));
  const tag: string | null = request.headers.get("x-item-tag");
  const device: string | null = request.headers.get("x-publisher-device");
  if (!epoch.success || tag === null || !/^[0-9a-f]{32}$/.test(tag) || device === null) {
    throw new ApiError("bad_request", "x-item-epoch, x-item-tag (32 hex characters) and x-publisher-device are required.");
  }
  if (device !== folder.publisher_device) {
    throw new ApiError("shared_folder_conflict", "Another device publishes this folder.");
  }
  if (folder.needs_rotation === 1 || epoch.data !== folder.key_epoch) {
    throw new ApiError("shared_folder_conflict", "The folder key changed or must be rotated first; refresh and try again.");
  }
  if (!(request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/octet-stream")) {
    throw new ApiError("unsupported_media_type", "The request body must be application/octet-stream.");
  }
  const blob: Uint8Array = await readBodyBytes(request, sharedFolderItemMaxBytes);
  requireSharedFolderItem(blob, epoch.data);
  const current: ItemRow | null = await db.prepare("SELECT * FROM shared_folder_items WHERE folder_id = ? AND item_id = ?").bind(folderId, itemId).first<ItemRow>();
  if (current !== null && current.tag === tag && current.size === blob.byteLength && current.key_epoch === epoch.data) {
    return { itemId, rev: current.rev };
  }
  const byteDelta: number = blob.byteLength - (current?.size ?? 0);
  if (byteDelta > 0) {
    await requireSyncStorageBudget(db, byteDelta, now);
  }
  await reserveSyncClassA(db, now);
  const r2Key: string = `${sharedFolderPrefix(folderId)}${itemId}/${randomToken(12)}`;
  await bucket.put(r2Key, blob);
  const nowMs: number = now.getTime();
  const newRev: number = folder.items_rev + 1;
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE shared_folders SET items_rev = items_rev + 1, updated_at = ?3, access_seen_at = ?3, publisher_seen_at = ?3
         WHERE folder_id = ?1 AND owner_id = ?2 AND items_rev = ?4 AND key_epoch = ?5 AND needs_rotation = 0 AND publisher_device = ?6
           AND (EXISTS (SELECT 1 FROM shared_folder_items WHERE folder_id = ?1 AND item_id = ?7)
                OR (SELECT COUNT(*) FROM shared_folder_items WHERE folder_id = ?1) < ?8)
           AND (SELECT COALESCE(SUM(size), 0) FROM shared_folder_items WHERE folder_id IN (SELECT folder_id FROM shared_folders WHERE owner_id = ?2)) + ?9 <= ?10`,
      )
      .bind(folderId, userId, nowMs, folder.items_rev, epoch.data, device, itemId, sharedFolderMaxItems, byteDelta, sharedFolderOwnerMaxBytes),
    db
      .prepare(
        `INSERT INTO shared_folder_items (folder_id, item_id, key_epoch, tag, size, r2_key, rev, updated_at)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8 WHERE EXISTS (SELECT 1 FROM shared_folders WHERE folder_id = ?1 AND items_rev = ?7 AND updated_at = ?8)
         ON CONFLICT (folder_id, item_id) DO UPDATE SET key_epoch = excluded.key_epoch, tag = excluded.tag, size = excluded.size,
           r2_key = excluded.r2_key, rev = excluded.rev, updated_at = excluded.updated_at`,
      )
      .bind(folderId, itemId, epoch.data, tag, blob.byteLength, r2Key, newRev, nowMs),
  ]);
  if ((results[0]?.meta.changes ?? 0) !== 1) {
    await bucket.delete(r2Key);
    const count: { count: number; bytes: number } | null = await db
      .prepare(
        `SELECT (SELECT COUNT(*) FROM shared_folder_items WHERE folder_id = ?1) AS count,
           (SELECT COALESCE(SUM(size), 0) FROM shared_folder_items WHERE folder_id IN (SELECT folder_id FROM shared_folders WHERE owner_id = ?2)) AS bytes`,
      )
      .bind(folderId, userId)
      .first<{ count: number; bytes: number }>();
    if ((current === null && (count?.count ?? 0) >= sharedFolderMaxItems) || (count?.bytes ?? 0) + byteDelta > sharedFolderOwnerMaxBytes) {
      throw new ApiError("shared_folder_limit_reached", `A shared folder holds at most ${sharedFolderMaxItems} notes and an account's shared notes at most 100 MB.`);
    }
    throw new ApiError("shared_folder_conflict", "The folder changed meanwhile; refresh and try again.");
  }
  if (current !== null) {
    await bucket.delete(current.r2_key);
  }
  return { itemId, rev: newRev };
}

async function deleteItem(db: D1Database, bucket: R2Bucket, userId: string, folderId: string, itemId: string, now: Date): Promise<object> {
  await ownedFolder(db, userId, folderId);
  const current: ItemRow | null = await db.prepare("SELECT * FROM shared_folder_items WHERE folder_id = ? AND item_id = ?").bind(folderId, itemId).first<ItemRow>();
  if (current === null) {
    return { deleted: true };
  }
  await db.batch([
    db
      .prepare(
        `UPDATE shared_folders SET items_rev = items_rev + 1, updated_at = ?3
         WHERE folder_id = ?1 AND EXISTS (SELECT 1 FROM shared_folder_items WHERE folder_id = ?1 AND item_id = ?2 AND r2_key = ?4)`,
      )
      .bind(folderId, itemId, now.getTime(), current.r2_key),
    db.prepare("DELETE FROM shared_folder_items WHERE folder_id = ? AND item_id = ? AND r2_key = ?").bind(folderId, itemId, current.r2_key),
  ]);
  await bucket.delete(current.r2_key);
  return { deleted: true };
}

// MARK: routing

function uuidOf(value: string | undefined): string {
  if (value === undefined || !uuidSchema.safeParse(value).success) {
    throw new ApiError("not_found", "No such shared folder.");
  }
  return value;
}

/** Routes `/v1/sharing/…`, `/v1/shared-folders…` and `/v1/shared-invites/…` for an authenticated, rate-limited user. */
export async function routeSharedFolders(request: Request, db: D1Database, bucket: R2Bucket, config: Config, path: string, userId: string, now: Date): Promise<Response> {
  const method: string = request.method;
  if (path === "/v1/shared-folders" && method === "GET") {
    return jsonResponse(200, await listFolders(db, config, userId));
  }
  if (config.sharedFolders.policy === "off") {
    throw new ApiError("shared_folders_unavailable", "Shared folders are not available yet.");
  }
  if (path === "/v1/sharing/identity") {
    if (method === "GET") {
      const row: IdentityRow | null = await identityOf(db, userId);
      return jsonResponse(200, { identity: row === null ? null : identityBody(row) });
    }
    if (method === "PUT") {
      return jsonResponse(200, await putIdentity(db, userId, request, now));
    }
    if (method === "DELETE") {
      return jsonResponse(200, await resetIdentity(db, bucket, userId, now));
    }
  }
  if (path === "/v1/shared-folders" && method === "POST") {
    return jsonResponse(201, await createFolder(db, config, userId, request, now));
  }
  const invite: RegExpExecArray | null = invitePath.exec(path);
  if (invite !== null) {
    const inviteId: string = invite[1] ?? "";
    if (invite[2] === undefined && method === "GET") {
      return jsonResponse(200, await readInvite(db, userId, inviteId, now));
    }
    if (invite[2] === "/accept" && method === "POST") {
      return jsonResponse(200, await acceptInvite(db, config, userId, inviteId, request, now));
    }
  }
  const folder: RegExpExecArray | null = folderPath.exec(path);
  if (folder !== null) {
    const folderId: string = uuidOf(folder[1]);
    const rest: string = folder[2] ?? "";
    if (rest === "" && method === "DELETE") {
      return jsonResponse(200, await stopSharing(db, bucket, userId, folderId, now));
    }
    if (rest === "/roster" && method === "PUT") {
      return jsonResponse(200, await changeRoster(db, userId, folderId, request, now));
    }
    if (rest === "/publisher" && (method === "POST" || method === "PUT")) {
      return jsonResponse(200, await claimPublisher(db, userId, folderId, request, now, method === "PUT"));
    }
    if (rest === "/members" && method === "GET") {
      return jsonResponse(200, await listMembers(db, userId, folderId, now));
    }
    if (rest === "/invites" && method === "POST") {
      return jsonResponse(201, await createInvite(db, config, userId, folderId, request, now));
    }
    const member: RegExpExecArray | null = memberPath.exec(rest);
    if (member !== null && method === "DELETE") {
      return jsonResponse(200, await revokeInvite(db, userId, folderId, member[1] ?? "", now));
    }
    if (rest === "/membership" && method === "DELETE") {
      return jsonResponse(200, await leaveFolder(db, userId, folderId, now));
    }
    if (rest === "/items" && method === "GET") {
      return jsonResponse(200, await listItems(db, config, userId, folderId, now));
    }
    const item: RegExpExecArray | null = itemPath.exec(rest);
    if (item !== null) {
      const itemId: string = uuidOf(item[1]);
      if (method === "GET") {
        return readItem(db, bucket, config, userId, folderId, itemId, now);
      }
      if (method === "PUT") {
        return jsonResponse(200, await writeItem(db, bucket, config, userId, folderId, itemId, request, now));
      }
      if (method === "DELETE") {
        return jsonResponse(200, await deleteItem(db, bucket, userId, folderId, itemId, now));
      }
    }
  }
  throw new ApiError("not_found", "No such endpoint.");
}

// MARK: cleanup

/** Daily shared-folder cleanup report. */
export interface SharedFolderCleanupReport {
  readonly [step: string]: number;
  readonly invitesExpired: number;
  readonly retentionChecked: number;
  readonly foldersDeleted: number;
}

/**
 * Daily cleanup: expired invites and acceptances never activated (their `expires_at`, set at accept) go; folders whose
 * owner was not seen with access for `sharedFolderAccessRetentionDays` are checked again (still entitled refreshes the
 * date, otherwise the folder is deleted and its blobs queued for the sync purge step).
 */
export async function sharedFolderCleanup(db: D1Database, config: Config, now: Date, maxFolders: number): Promise<SharedFolderCleanupReport> {
  const nowMs: number = now.getTime();
  // Dropping an acceptance changes the membership: `members_version` moves first (same batch), so an owner device that
  // read the old state cannot sign a roster with the dropped member (its compare-and-set fails and it refreshes).
  const expiredBatch: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE shared_folders SET members_version = members_version + 1, updated_at = ?1
         WHERE folder_id IN (SELECT folder_id FROM shared_folder_members WHERE status = 'accepted' AND expires_at <= ?1)`,
      )
      .bind(nowMs),
    db.prepare("DELETE FROM shared_folder_members WHERE status IN ('invited', 'accepted') AND expires_at <= ?").bind(nowMs),
  ]);
  const expired: D1Result | undefined = expiredBatch[1];
  if (expired === undefined) {
    throw new Error("The cleanup batch returned no result for the delete.");
  }
  const stale: D1Result<{ folder_id: string; owner_id: string }> = await db
    .prepare("SELECT folder_id, owner_id FROM shared_folders WHERE access_seen_at < ? ORDER BY access_seen_at LIMIT ?")
    .bind(nowMs - sharedFolderAccessRetentionDays * dayMs, maxFolders)
    .all<{ folder_id: string; owner_id: string }>();
  let deleted: number = 0;
  for (const { folder_id: folderId, owner_id: ownerId } of stale.results) {
    if (await hasSyncAccess(db, config, ownerId, now)) {
      await db.prepare("UPDATE shared_folders SET access_seen_at = ? WHERE folder_id = ?").bind(nowMs, folderId).run();
      continue;
    }
    await db.batch([
      db
        .prepare("INSERT INTO sync_purges (prefix, requested_at) VALUES (?, ?) ON CONFLICT (prefix) DO UPDATE SET requested_at = excluded.requested_at")
        .bind(sharedFolderPrefix(folderId), nowMs),
      db.prepare("DELETE FROM shared_folder_items WHERE folder_id = ?").bind(folderId),
      db.prepare("DELETE FROM shared_folder_members WHERE folder_id = ?").bind(folderId),
      db.prepare("DELETE FROM shared_folders WHERE folder_id = ?").bind(folderId),
    ]);
    deleted += 1;
  }
  const report: SharedFolderCleanupReport = { invitesExpired: expired.meta.changes, retentionChecked: stale.results.length, foldersDeleted: deleted };
  log("info", "shared_folder_cleanup_done", report);
  return report;
}
