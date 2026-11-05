-- AI assistant access (remote MCP connector; docs/superpowers/specs/2026-11-05-remote-mcp.md). EU D1 database
-- `gistsmith-assistant` (created with `--jurisdiction eu`), bound as ASSISTANT_DB to both the API Worker and the
-- `gistsmith-mcp` Worker. No plaintext titles or note text live here: the per-meeting index is AES-256-GCM ciphertext
-- (src/assistant/crypto.ts), the full note is an encrypted R2 object.

-- One row per account that ever turned the feature on. `epoch` grows every time it is turned off, so uploads started
-- before the switch are refused (409) and their R2 prefix (`a/<user>/<epoch>/`) can be purged without touching newer
-- uploads. `access_lost_at`: the daily cleanup saw no subscription or running trial (the copy is deleted 7 days later);
-- NULL while entitled. `access_checked_at` rotates the daily access check over all accounts.
CREATE TABLE assistant_settings (
  user_id TEXT PRIMARY KEY,
  enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
  epoch INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  access_lost_at INTEGER,
  access_checked_at INTEGER NOT NULL
);

-- Uploaded meetings. `index_ct` is the encrypted index (title, folder, start, duration, search text, own tasks) the
-- MCP tools search and list without reading R2; `size` is the encrypted R2 object's size in bytes.
CREATE TABLE assistant_meetings (
  user_id TEXT NOT NULL,
  meeting_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  size INTEGER NOT NULL,
  index_ct BLOB NOT NULL,
  PRIMARY KEY (user_id, meeting_id)
);
CREATE INDEX assistant_meetings_started ON assistant_meetings (user_id, started_at DESC, meeting_id DESC);
CREATE INDEX assistant_meetings_device ON assistant_meetings (user_id, device_id);

-- Live connections (OAuth grants of `gistsmith-mcp`). The MCP Worker reads this row on every call, so deleting it stops
-- the assistant at once (KV, where the tokens live, is eventually consistent). `client_name` is already sanitised
-- (at most 40 characters, no bidi or invisible characters). `calls_day` counts `fetch` calls on `calls_day_date`
-- (UTC day); `reads_hour` counts meetings read since `reads_hour_start`; `heavy_read_at` is set when a connection read
-- more than 100 meetings in an hour (the apps show a notice).
CREATE TABLE assistant_grants (
  user_id TEXT NOT NULL,
  grant_id TEXT NOT NULL,
  client_id TEXT NOT NULL,
  client_name TEXT NOT NULL,
  redirect_host TEXT NOT NULL,
  verified INTEGER NOT NULL CHECK (verified IN (0, 1)),
  created_at INTEGER NOT NULL,
  last_used_at INTEGER,
  calls_day INTEGER NOT NULL DEFAULT 0,
  calls_day_date TEXT,
  reads_hour INTEGER NOT NULL DEFAULT 0,
  reads_hour_start INTEGER,
  heavy_read_at INTEGER,
  PRIMARY KEY (user_id, grant_id)
);
CREATE INDEX assistant_grants_client ON assistant_grants (client_id);

-- Grants whose D1 row is gone but whose KV records (tokens) the MCP Worker still has to revoke (its cron).
CREATE TABLE assistant_revocations (
  user_id TEXT NOT NULL,
  grant_id TEXT NOT NULL,
  requested_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, grant_id)
);

-- R2 prefixes queued for deletion (turned off, access ended, account deleted); the daily cleanup finishes them.
CREATE TABLE assistant_purges (
  prefix TEXT PRIMARY KEY,
  requested_at INTEGER NOT NULL
);

-- Dynamic client registrations per IP (HMAC) and UTC hour: at most 10.
CREATE TABLE assistant_registrations (
  ip_hash TEXT NOT NULL,
  hour INTEGER NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (ip_hash, hour)
);

-- Daily counters (no user ids): heavy readers, upstream retries.
CREATE TABLE assistant_ops_events (
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, kind)
);

-- Sign-in on mcp.gistsmith.com: single-use identity token nonces and the Apple/Google key cache (same shape as the
-- production database's tables, so `auth/identityToken.ts` works unchanged against this database).
CREATE TABLE used_nonces (
  nonce_hash TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);
CREATE TABLE identity_jwks (
  jwks_url TEXT PRIMARY KEY,
  keys_json TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
);
