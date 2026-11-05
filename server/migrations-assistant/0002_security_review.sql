-- Security review fixes for AI assistant access (docs/superpowers/specs/2026-11-05-remote-mcp.md, review record).

-- A connection remembers the settings epoch it was created under. The code exchange inserts it only while the feature
-- is on at that epoch (one conditional statement), and refreshes and MCP calls accept it only while the epoch still
-- matches, so a connection from before a turn-off is never live. Epochs start at 1: the default 0 never matches.
ALTER TABLE assistant_grants ADD COLUMN epoch INTEGER NOT NULL DEFAULT 0;

-- Every upload is sealed into a new R2 object `a/<user>/<epoch>/<meeting>/<object_id>`; the row points at the current
-- one. A refused upload (feature turned off, epoch moved, quota) deletes only its own new object and never the note
-- the row still points at. Rows from before this migration exist only in local development databases (production's
-- database is created with every migration applied) and have no object id: they are removed; the apps upload again.
DELETE FROM assistant_meetings;
ALTER TABLE assistant_meetings ADD COLUMN object_id TEXT NOT NULL DEFAULT '';

-- OAuth clients that completed a consent. The daily cleanup deletes dynamically registered clients that never did
-- (spam registrations); a client listed here is kept even while it has no connection row (code not yet exchanged, or
-- disconnected and about to reconnect with the same client id). Pruned after `grantMaxAgeMs` without use.
CREATE TABLE assistant_client_uses (
  client_id TEXT PRIMARY KEY,
  last_used_at INTEGER NOT NULL
);
