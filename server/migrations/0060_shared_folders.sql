-- Shared folders (src/sharedFolders.ts; design: docs/superpowers/specs/2026-11-08-shared-folders.md). End-to-end
-- encrypted: the server keeps public keys, sealed values it cannot open, signatures, counters and the index of item
-- blobs (the blobs live in R2 under `f/<folder>/`). No folder names, labels, display names or note text. Additive only:
-- nothing else reads these tables, so a code rollback keeps working.

-- One sharing identity per account: its X25519 and Ed25519 public keys (base64, 32 bytes each) and, when the account
-- has sync on, the identity seed sealed with the account sync key (`sealed_seed`; `seed_key_id` is that sync key's id).
-- The first registration wins; the keys never change afterwards (only a reset deletes the row).
CREATE TABLE sharing_identities (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  agreement_key TEXT NOT NULL,
  signing_key TEXT NOT NULL,
  sealed_seed TEXT,
  seed_key_id TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- A shared folder. `sealed_meta` (name, owner name, transcripts on/off) and `owner_envelope` (the keyring wrapped to the
-- owner) are sealed on the owner's device. `roster` is the owner-signed member list (JSON with ids and public keys only)
-- with `roster_signature`. `members_version` changes on every membership change and `items_rev` on every item change or
-- rotation (compare-and-set guards and change detectors). `needs_rotation`: a member left or was deleted; new items are
-- refused until an owner device rotates the key. `publisher_device`: the one owner device that uploads items (random
-- id, no hardware identifier). `access_seen_at`: last moment the owner was seen with a subscription or trial.
CREATE TABLE shared_folders (
  folder_id TEXT PRIMARY KEY,
  owner_id TEXT NOT NULL REFERENCES users(id),
  sealed_meta TEXT NOT NULL,
  key_epoch INTEGER NOT NULL,
  owner_envelope TEXT NOT NULL,
  roster TEXT NOT NULL,
  roster_signature TEXT NOT NULL,
  roster_version INTEGER NOT NULL,
  members_version INTEGER NOT NULL DEFAULT 0,
  items_rev INTEGER NOT NULL DEFAULT 0,
  needs_rotation INTEGER NOT NULL DEFAULT 0,
  publisher_device TEXT NOT NULL,
  publisher_seen_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  access_seen_at INTEGER NOT NULL
);
CREATE INDEX shared_folders_owner ON shared_folders (owner_id);
CREATE INDEX shared_folders_access_seen ON shared_folders (access_seen_at);

-- Invites and members of a folder; `member_id` is the invite id (16 random bytes, base64url). States: `invited` (link
-- sent, not used), `accepted` (an account used it; waiting for an owner device to verify and add it), `active` (in the
-- signed roster with a keyring `envelope`). Sealed on devices: `sealed_label` and `sealed_secret` (owner-only key),
-- `sealed_preview` and `sealed_name` (key from the invite secret), `sealed_pin` (the member's own key).
CREATE TABLE shared_folder_members (
  folder_id TEXT NOT NULL REFERENCES shared_folders(folder_id),
  member_id TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,
  user_id TEXT REFERENCES users(id),
  sealed_label TEXT NOT NULL,
  sealed_secret TEXT NOT NULL,
  owner_proof TEXT NOT NULL,
  sealed_preview TEXT NOT NULL,
  expires_at INTEGER NOT NULL,
  member_agreement_key TEXT,
  member_signing_key TEXT,
  member_proof TEXT,
  sealed_name TEXT,
  sealed_pin TEXT,
  envelope TEXT,
  envelope_epoch INTEGER,
  accepted_at INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (folder_id, member_id)
);
CREATE INDEX shared_folder_members_user ON shared_folder_members (user_id);
CREATE INDEX shared_folder_members_expiry ON shared_folder_members (status, expires_at);

-- Index of a folder's sealed items (one per shared note). The blob is in R2 at `r2_key`; `tag` is a keyed hash of the
-- plaintext the owner's device compares to skip unchanged uploads; `rev` is the folder's `items_rev` at the write.
CREATE TABLE shared_folder_items (
  folder_id TEXT NOT NULL REFERENCES shared_folders(folder_id),
  item_id TEXT NOT NULL,
  key_epoch INTEGER NOT NULL,
  tag TEXT NOT NULL,
  size INTEGER NOT NULL,
  r2_key TEXT NOT NULL,
  rev INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (folder_id, item_id)
);
