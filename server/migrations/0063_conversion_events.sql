-- Subscription funnel telemetry (src/conversion.ts; admin panel "Telemetry" › Conversion). Daily sums per kind,
-- platform (`macos`/`ios` from `x-os-version`, `server` for checkouts the server opened), fixed-list dimensions ("" where
-- a kind has none; `reason` also holds a restore result or a reminder channel) and app version. No account, product,
-- price, country or free text. Kept 400 days (src/cleanup.ts). Additive only.
CREATE TABLE conversion_events_daily (
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  platform TEXT NOT NULL,
  surface TEXT NOT NULL,
  trigger TEXT NOT NULL,
  tiers TEXT NOT NULL,
  tier TEXT NOT NULL,
  plan TEXT NOT NULL,
  reason TEXT NOT NULL,
  app_version TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, kind, platform, surface, trigger, tiers, tier, plan, reason, app_version)
);

-- When the current Stripe subscription was created (ms; Stripe's `created`), written by the webhook. The EU online
-- withdrawal function (src/billing.ts `withdrawSubscription`) is offered for 14 days from it. NULL for rows written
-- before this migration and for complimentary access.
ALTER TABLE subscriptions ADD COLUMN started_at INTEGER;
-- When the subscriber confirmed the withdrawal (ms): the refund is computed at this moment, so a retried withdrawal
-- (a Stripe call failed half way) sends the same refunds under the same idempotency keys. Cleared when the row moves to
-- another Stripe subscription.
ALTER TABLE subscriptions ADD COLUMN withdrawal_requested_at INTEGER;
-- When every refund of the withdrawal succeeded (ms). While the request is set and this is empty, /v1/me reports the
-- withdrawal as pending (`withdrawalPending`) and the daily job retries it. Cleared with `withdrawal_requested_at`.
ALTER TABLE subscriptions ADD COLUMN withdrawal_completed_at INTEGER;
