-- In-app dialer pilot (src/phone/calls.ts; off while PHONE_CALLS_POLICY=off). Additive only: new tables and one new
-- daily_spend column; nothing existing is changed.

-- The user's opt-in to the dialer after the disclosure (the voice provider carries and records the call). `version` is
-- the disclosure text's version; a new version asks again.
CREATE TABLE phone_consents (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  version INTEGER NOT NULL,
  accepted_at INTEGER NOT NULL
);

-- The user's own number as caller ID, verified by the provider calling it (one per account). `provider_sid` is the
-- provider's caller ID id once verified; `attempts` counts verification calls on `attempts_day` (UTC).
CREATE TABLE phone_numbers (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  e164 TEXT NOT NULL,
  country TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'verified', 'failed')),
  validation_call_sid TEXT,
  provider_sid TEXT,
  attempts_day TEXT NOT NULL,
  attempts INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  pending_until INTEGER,
  verified_at INTEGER
);
-- A number can be verified by one account only.
CREATE UNIQUE INDEX phone_numbers_verified_e164 ON phone_numbers (e164) WHERE status = 'verified';
CREATE INDEX phone_numbers_e164 ON phone_numbers (e164);

-- One row per dialer call. While `settled_at` is NULL and `reserved_until` is in the future, `estimated_micro_usd` (the
-- call's worst case: longest duration × the country's price) counts toward the daily spend ceilings; settling writes
-- the real cost to daily_spend and clears the numbers (`destination`, `caller_id`). The recording stays at the provider
-- until the app has fetched it (`recording_deleted_at`), at most a day (scheduled cleanup).
CREATE TABLE phone_calls (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  status TEXT NOT NULL CHECK (status IN ('reserved', 'dialing', 'completed', 'failed', 'expired')),
  destination TEXT,
  caller_id TEXT,
  country TEXT NOT NULL,
  max_seconds INTEGER NOT NULL,
  micro_usd_per_minute INTEGER NOT NULL,
  estimated_micro_usd INTEGER NOT NULL,
  month TEXT NOT NULL,
  day TEXT NOT NULL,
  provider_call_sid TEXT,
  billed_seconds INTEGER,
  cost_micro_usd INTEGER,
  recording_status TEXT CHECK (recording_status IN ('ready', 'absent')),
  recording_sid TEXT,
  recording_seconds INTEGER,
  recording_deleted_at INTEGER,
  created_at INTEGER NOT NULL,
  reserved_until INTEGER NOT NULL,
  settled_at INTEGER
);
CREATE INDEX phone_calls_user_month ON phone_calls (user_id, month);
CREATE INDEX phone_calls_user_day ON phone_calls (user_id, day);
CREATE INDEX phone_calls_day_open ON phone_calls (day, settled_at);
CREATE INDEX phone_calls_reserved_until ON phone_calls (reserved_until) WHERE settled_at IS NULL;
CREATE INDEX phone_calls_recordings ON phone_calls (created_at) WHERE recording_sid IS NOT NULL AND recording_deleted_at IS NULL;

-- Provider objects to delete (caller IDs and recordings of deleted accounts or replaced numbers); the scheduled cleanup
-- deletes them at the provider and then the row.
CREATE TABLE phone_provider_purges (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK (kind IN ('caller_id', 'recording')),
  provider_sid TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

-- The dialer's part of the day's settled spend (also included in micro_usd).
ALTER TABLE daily_spend ADD COLUMN phone_micro_usd INTEGER NOT NULL DEFAULT 0;
