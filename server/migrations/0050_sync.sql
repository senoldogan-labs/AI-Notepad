-- Mac <-> iPhone sync, phase 1 (text only; see docs/superpowers/specs/2026-11-03-mac-iphone-sync-options.md §8 and
-- src/sync.ts). The server stores end-to-end encrypted blobs in R2 and only this index in D1: object ids are random
-- or keyed hashes, kinds are a fixed list, sizes and revisions are numbers. No meeting content, titles or names.

-- One row per account that turned sync on (opt-in). `last_rev` is the account's change counter: every write and delete
-- takes the next value inside the same D1 transaction, so revisions are committed in order and a device's cursor
-- never skips a change. `key_id` identifies the account sync key (a hash of it; the key itself never reaches the
-- server) so two devices cannot start sync with different keys. `purged_through_rev`: tombstones up to this revision
-- were removed by the daily cleanup; a cursor older than it must resync from 0. `access_seen_at`: last moment the
-- account was seen with a subscription or trial (cleanup wipes the copy 90 days after access ends).
CREATE TABLE sync_accounts (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  key_id TEXT NOT NULL,
  enabled_at INTEGER NOT NULL,
  last_rev INTEGER NOT NULL DEFAULT 0,
  purged_through_rev INTEGER NOT NULL DEFAULT 0,
  object_count INTEGER NOT NULL DEFAULT 0,
  stored_bytes INTEGER NOT NULL DEFAULT 0,
  access_seen_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX sync_accounts_access_seen ON sync_accounts (access_seen_at);

-- Index of the account's encrypted objects. A deleted object stays as a tombstone (`deleted = 1`, no blob) for 90 days
-- so other devices learn about the delete. `r2_key` is the current blob (`u/<user>/<object>/<random>`), null for a
-- tombstone. `updated_by_device` is the uploading device's random sync id (no hardware identifier).
CREATE TABLE sync_objects (
  user_id TEXT NOT NULL REFERENCES users(id),
  object_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  rev INTEGER NOT NULL,
  size INTEGER NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  r2_key TEXT,
  updated_at INTEGER NOT NULL,
  updated_by_device TEXT,
  PRIMARY KEY (user_id, object_id)
);
CREATE INDEX sync_objects_changes ON sync_objects (user_id, rev);
CREATE INDEX sync_objects_tombstones ON sync_objects (deleted, updated_at);

-- Wrapped copies of the account sync key that the server cannot open: `recovery` (sealed with a key derived from the
-- user's recovery code; at most one per account) and short-lived `pairing` messages of "add a device" (expire after
-- 10 minutes).
CREATE TABLE sync_key_envelopes (
  user_id TEXT NOT NULL REFERENCES users(id),
  envelope_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER,
  PRIMARY KEY (user_id, envelope_id)
);
CREATE INDEX sync_key_envelopes_expiry ON sync_key_envelopes (expires_at);

-- R2 prefixes still to delete after an opt-out, a reset, account deletion or the end of retention. The D1 rows are
-- removed at once (the copy is unreachable); the blobs are removed right away when possible and by the daily cleanup
-- otherwise. Not linked to `users`: the account may already be deleted.
CREATE TABLE sync_purges (
  prefix TEXT PRIMARY KEY,
  requested_at INTEGER NOT NULL
);
