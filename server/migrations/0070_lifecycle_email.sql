-- Opt-in lifecycle email (src/email/; spec docs/superpowers/specs/2026-11-26-lifecycle-email.md). The server stores an
-- email address only for an account whose user typed it in the app and asked for these emails (double opt-in).
--
-- Additive only: new tables. Workers running the previous code never read them.

-- One row per account that opted in. `id` is random per opt-in and is what unsubscribe links sign. `email` is the
-- confirmed address (NULL until the first confirmation); `pending_email` an address waiting for its confirmation link
-- (a confirmed address keeps getting mail until a new one is confirmed). `confirm_token_hash` is the SHA-256 of the
-- one-use confirmation token, valid until `confirm_expires_at`. `locale` is one of the supported email languages,
-- `consent_version` the version of the opt-in wording the user agreed to (proof of consent while the address is held).
-- `checked_at` is when the hourly run last looked at the account (round robin). Deleted on unsubscribe, account
-- deletion, 7 days after `pending_at` without a confirmation, as soon as nothing more can be sent, and at the latest 60
-- days after `confirmed_at` (src/email/lifecycle.ts).
CREATE TABLE email_subscriptions (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  id TEXT NOT NULL UNIQUE,
  email TEXT,
  pending_email TEXT,
  confirm_token_hash TEXT UNIQUE,
  confirm_expires_at INTEGER,
  locale TEXT NOT NULL,
  consent_version INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  pending_at INTEGER,
  confirmed_at INTEGER,
  checked_at INTEGER,
  CHECK (email IS NOT NULL OR pending_email IS NOT NULL),
  CHECK ((pending_email IS NULL) = (confirm_token_hash IS NULL)),
  CHECK ((pending_email IS NULL) = (confirm_expires_at IS NULL)),
  CHECK ((email IS NULL) = (confirmed_at IS NULL))
);
CREATE INDEX email_subscriptions_confirmed ON email_subscriptions(confirmed_at) WHERE email IS NOT NULL;
CREATE INDEX email_subscriptions_pending ON email_subscriptions(pending_at) WHERE pending_email IS NOT NULL;
CREATE INDEX email_subscriptions_checked ON email_subscriptions(checked_at) WHERE email IS NOT NULL;

-- Lifecycle emails per account: each kind at most once (claimed before sending; `sent_at` once the provider accepted
-- it). No address. Kept while the account exists, so unsubscribing and opting in again doesn't repeat an email.
CREATE TABLE email_sends (
  user_id TEXT NOT NULL REFERENCES users(id),
  kind TEXT NOT NULL CHECK (kind IN ('welcome', 'activation', 'trial_ending', 'free_plan')),
  claimed_at INTEGER NOT NULL,
  sent_at INTEGER,
  PRIMARY KEY (user_id, kind)
);

-- Confirmation emails per recipient and per account, keyed by an HMAC of the lower-cased address or of the account id
-- (never the address; src/email/signing.ts): sends in the current 24-hour and 7-day windows, and `blocked_at` when the
-- recipient chose "This wasn't me". Throttle rows go 7 days after `last_sent_at`; blocks after 24 months.
CREATE TABLE email_recipient_limits (
  key_hash TEXT PRIMARY KEY,
  day_start INTEGER NOT NULL,
  day_sends INTEGER NOT NULL,
  week_start INTEGER NOT NULL,
  week_sends INTEGER NOT NULL,
  last_sent_at INTEGER NOT NULL,
  blocked_at INTEGER
);
CREATE INDEX email_recipient_limits_last_sent ON email_recipient_limits(last_sent_at);

-- Our sending cap (Workers Paid includes 3,000 emails a month; EMAIL_SENDING.monthlyCap/dailyCap stay under it): one
-- row per UTC month with the month's and the current UTC day's counts, total and confirmation emails. A unit is taken
-- the moment an email is handed to the provider. `*_alerted` hold the day or month whose cap refusal was alerted.
CREATE TABLE email_quota (
  month TEXT PRIMARY KEY,
  sent INTEGER NOT NULL,
  confirm_sent INTEGER NOT NULL,
  day TEXT NOT NULL,
  day_sent INTEGER NOT NULL,
  day_confirm_sent INTEGER NOT NULL,
  day_alerted TEXT,
  month_alerted INTEGER NOT NULL DEFAULT 0
);

-- Daily totals for the admin page (opt-ins, confirmations, unsubscribes, sends per kind, failures). Not linked to
-- anyone. Kept 400 days.
CREATE TABLE email_daily_counts (
  day TEXT NOT NULL,
  metric TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, metric)
);
