-- The user's answer to the in-app third-party AI disclosure (App Review 5.1.1(i) / 5.1.2(i); see `src/aiConsent.ts`).
-- `ai_consent_version` is the disclosure version the user agreed to; NULL when they never agreed or withdrew.
-- `ai_consent_at` is when the last answer reached the server (ms); NULL when the app never sent one.
--
-- Additive only: two nullable columns, no existing row is read or changed. Older Workers never read them, and the
-- account's row (with these columns) is deleted with the account.
ALTER TABLE users ADD COLUMN ai_consent_version INTEGER;
ALTER TABLE users ADD COLUMN ai_consent_at INTEGER;
