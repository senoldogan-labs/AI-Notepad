-- Permanent free plan (src/freePlan.ts; spec docs/superpowers/specs/2026-11-23-free-plan.md). A free account never gets
-- a meeting session: each free AI note is a note grant with its own token budget, counted per UTC month.
--
-- Additive only: new tables and new columns with defaults. Workers running the previous code never read them, and
-- their inserts name their columns, so the defaults apply.

-- One free AI note: a token budget the LLM proxy reserves against (`x-free-note: <id>`). `month` is the UTC month the
-- grant counts toward. `client_ref` makes `POST /v1/free/notes` idempotent per recording (unique while not refunded).
-- `first_settled_at` is the first settled call on the grant; a grant still without one after 24 hours is refunded
-- (`refunded_at`) by the daily cleanup and no longer counts. `device_id` is the App Attest key the request was
-- asserted with (logs only), `ip_hash` the HMAC of the client IP (same secret as the trial's). Kept 400 days.
CREATE TABLE free_note_grants (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  month TEXT NOT NULL,
  client_ref TEXT NOT NULL,
  token_budget INTEGER NOT NULL,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  first_settled_at INTEGER,
  refunded_at INTEGER,
  device_id TEXT,
  ip_hash TEXT NOT NULL
);
CREATE UNIQUE INDEX free_note_grants_client_ref ON free_note_grants(user_id, client_ref) WHERE refunded_at IS NULL;
CREATE INDEX free_note_grants_user_month ON free_note_grants(user_id, month);
CREATE INDEX free_note_grants_created ON free_note_grants(created_at);

-- Accounts that got their first free note grant, per IP (HMAC) and UTC day: `FREE_ACCOUNTS_PER_IP_PER_DAY`. No link to
-- `users` on purpose: a deleted account still counts for its day, so deleting and re-creating accounts doesn't reset
-- the limit. Rows hold only the opaque account id, the IP hash and the day, and are cleared the next day.
CREATE TABLE free_starts (
  user_id TEXT PRIMARY KEY,
  ip_hash TEXT NOT NULL,
  day TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX free_starts_ip_day ON free_starts(ip_hash, day);

-- Reservations: the note grant a call reserves against, whether it is free spend, and whether it is a free Ask answer
-- (pending ones count against the grant budget, the free ceilings and `FREE_ASKS_PER_MONTH`).
ALTER TABLE usage_reservations ADD COLUMN free_note_id TEXT;
ALTER TABLE usage_reservations ADD COLUMN free_spend INTEGER NOT NULL DEFAULT 0 CHECK (free_spend IN (0, 1));
ALTER TABLE usage_reservations ADD COLUMN free_ask INTEGER NOT NULL DEFAULT 0 CHECK (free_ask IN (0, 1));
CREATE INDEX usage_reservations_free_note ON usage_reservations(free_note_id) WHERE free_note_id IS NOT NULL;

-- Free spend (part of `micro_usd`): its own daily and monthly ceilings, and the once-a-day alert marks.
ALTER TABLE daily_spend ADD COLUMN free_micro_usd INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_spend ADD COLUMN free_ceiling_alerted_at INTEGER;
ALTER TABLE daily_spend ADD COLUMN free_monthly_ceiling_alerted_at INTEGER;
ALTER TABLE daily_spend ADD COLUMN free_monthly_warning_alerted_at INTEGER;

-- The month's free counters: notes carried over from a deleted account of the same identity, and settled Ask answers.
ALTER TABLE monthly_usage ADD COLUMN free_notes_carried INTEGER NOT NULL DEFAULT 0;
ALTER TABLE monthly_usage ADD COLUMN free_asks INTEGER NOT NULL DEFAULT 0;

-- DeviceCheck bit1 ("this device has a free plan bound to an account"), the same claim steps as the trial's bit0.
ALTER TABLE users ADD COLUMN free_device_verified_at INTEGER;
ALTER TABLE users ADD COLUMN free_device_claim_started_at INTEGER;

-- The identity ledger carries the month's free counters and the device binding across account deletion.
ALTER TABLE trial_identity_ledger ADD COLUMN free_month TEXT;
ALTER TABLE trial_identity_ledger ADD COLUMN free_notes_used INTEGER NOT NULL DEFAULT 0;
ALTER TABLE trial_identity_ledger ADD COLUMN free_asks_used INTEGER NOT NULL DEFAULT 0;
ALTER TABLE trial_identity_ledger ADD COLUMN free_device_verified INTEGER NOT NULL DEFAULT 0;

-- Daily snapshot: the day's free spend.
ALTER TABLE daily_metrics ADD COLUMN spend_free_micro_usd INTEGER NOT NULL DEFAULT 0;
