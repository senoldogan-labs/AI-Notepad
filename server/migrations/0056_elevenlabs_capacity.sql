-- ElevenLabs' own report of the account's credits (GET /v1/user/subscription), cached as a single row and refreshed
-- before audio reservations and by the daily Cron (src/elevenLabsCapacity.ts). Additive only: a new table; audio
-- reservations read it for the first time after the deploy.
CREATE TABLE elevenlabs_capacity (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  -- character_count / character_limit: credits used and available in the current period (plan + top-up packs).
  credits_used INTEGER NOT NULL,
  credits_limit INTEGER NOT NULL,
  -- next_character_count_reset_unix in ms; NULL when ElevenLabs does not report one.
  resets_at INTEGER,
  -- Subscription status (active, trialing, past_due, ...).
  status TEXT NOT NULL,
  -- When the row was read (ms, server clock) and that UTC day.
  fetched_at INTEGER NOT NULL,
  fetch_day TEXT NOT NULL,
  -- daily_spend.audio_seconds since fetch_day at read time: audio sent after the read is subtracted from the credits.
  local_seconds_at_fetch REAL NOT NULL
);
