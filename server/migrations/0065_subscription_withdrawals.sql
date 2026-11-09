-- EU withdrawals as their own records, one per Stripe subscription (src/withdrawalState.ts, src/billing.ts
-- `withdrawSubscription`). Before this migration the request lived on the account's single `subscriptions` row
-- (`withdrawal_requested_at`, `withdrawal_completed_at`, migration 0063), which other writers move or delete: a
-- re-subscribe cleared it, complimentary access hid it from the daily retry, `customer.deleted` and account deletion
-- removed it. This table is only written by the withdrawal flow; those writers leave it alone.
--
-- `state` (transitions: `allowedWithdrawalStateChanges`, enforced by the trigger below):
--   requested: refund not confirmed yet (retried by the subscriber and daily);
--   settled: every refund succeeded and reached the computed amount;
--   short: every refund succeeded below the computed amount (alerted; the owner pays the rest);
--   blocked: Stripe refused the refund for good (alerted; not retried; the owner resolves it).
-- `user_id`: the account; set to NULL on account deletion once the refund run is finished (settled/short). A withdrawal
-- still owed keeps it: its refunds are retried with the same parameters (metadata) under the same idempotency keys.
-- No foreign key, so the row outlives the account. `target_cents`, `refunded_cents`, `currency`: the last run's computed
-- refund and what Stripe has (live refunds). `attempts`: runs that failed; `last_error`: the latest failure (required
-- when blocked). `settled_at`: when the run finished (set exactly in settled/short).
--
-- The old `subscriptions.withdrawal_*` columns stay (additive migration only); the new code neither reads nor writes them. The two
-- `subscriptions_withdrawal_bridge_*` triggers copy writes the previous Worker version makes to them into this table, for
-- the seconds between this migration and the new code going live (migrations run first).
CREATE TABLE subscription_withdrawals (
  stripe_subscription_id TEXT PRIMARY KEY,
  user_id TEXT,
  stripe_customer_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('requested', 'settled', 'short', 'blocked')),
  requested_at INTEGER NOT NULL,
  settled_at INTEGER,
  target_cents INTEGER CHECK (target_cents IS NULL OR target_cents >= 0),
  refunded_cents INTEGER CHECK (refunded_cents IS NULL OR refunded_cents >= 0),
  currency TEXT,
  attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error TEXT,
  updated_at INTEGER NOT NULL,
  CHECK ((state IN ('settled', 'short')) = (settled_at IS NOT NULL)),
  CHECK (state <> 'blocked' OR last_error IS NOT NULL),
  CHECK (user_id IS NOT NULL OR state IN ('settled', 'short'))
);

CREATE INDEX subscription_withdrawals_state ON subscription_withdrawals (state, requested_at);
CREATE INDEX subscription_withdrawals_user ON subscription_withdrawals (user_id, state);

CREATE TRIGGER subscription_withdrawals_state_transition BEFORE UPDATE OF state ON subscription_withdrawals
WHEN OLD.state <> NEW.state AND NOT (
  (OLD.state = 'requested' AND NEW.state IN ('settled', 'short', 'blocked'))
  OR (OLD.state = 'blocked' AND NEW.state IN ('requested', 'settled'))
  OR (OLD.state = 'short' AND NEW.state = 'settled')
)
BEGIN
  SELECT RAISE(ABORT, 'subscription_withdrawals: state transition not allowed');
END;

CREATE TRIGGER subscription_withdrawals_identity_fixed BEFORE UPDATE OF stripe_subscription_id, stripe_customer_id, requested_at ON subscription_withdrawals
WHEN NEW.stripe_subscription_id <> OLD.stripe_subscription_id
  OR NEW.stripe_customer_id <> OLD.stripe_customer_id
  OR NEW.requested_at <> OLD.requested_at
BEGIN
  SELECT RAISE(ABORT, 'subscription_withdrawals: subscription, customer and request moment are fixed');
END;

CREATE TRIGGER subscription_withdrawals_user_only_unlinked BEFORE UPDATE OF user_id ON subscription_withdrawals
WHEN NEW.user_id IS NOT NULL AND NEW.user_id IS NOT OLD.user_id
BEGIN
  SELECT RAISE(ABORT, 'subscription_withdrawals: user_id can only be cleared');
END;

-- Backfill: requests for the row's current subscription (`withdrawal_requested_at >= started_at`, the old rule).
-- Completed → settled (amounts unknown); pending → requested; pending on a complimentary row → blocked (complimentary
-- access replaced the Stripe subscription id, so it can't be retried automatically; the owner resolves it).
INSERT INTO subscription_withdrawals (stripe_subscription_id, user_id, stripe_customer_id, state, requested_at, settled_at, last_error, attempts, updated_at)
SELECT
  stripe_subscription_id,
  user_id,
  stripe_customer_id,
  CASE WHEN withdrawal_completed_at IS NOT NULL THEN 'settled' WHEN complimentary = 1 THEN 'blocked' ELSE 'requested' END,
  withdrawal_requested_at,
  withdrawal_completed_at,
  CASE WHEN withdrawal_completed_at IS NULL AND complimentary = 1 THEN 'legacy_complimentary_overwrite' END,
  0,
  updated_at
FROM subscriptions
WHERE withdrawal_requested_at IS NOT NULL AND started_at IS NOT NULL AND withdrawal_requested_at >= started_at;

CREATE TRIGGER subscriptions_withdrawal_bridge_request AFTER UPDATE OF withdrawal_requested_at ON subscriptions
WHEN NEW.withdrawal_requested_at IS NOT NULL AND NEW.withdrawal_requested_at IS NOT OLD.withdrawal_requested_at
  AND NEW.started_at IS NOT NULL AND NEW.withdrawal_requested_at >= NEW.started_at AND NEW.complimentary = 0
BEGIN
  INSERT INTO subscription_withdrawals (stripe_subscription_id, user_id, stripe_customer_id, state, requested_at, attempts, updated_at)
  SELECT NEW.stripe_subscription_id, NEW.user_id, NEW.stripe_customer_id, 'requested', NEW.withdrawal_requested_at, 0, NEW.withdrawal_requested_at
  WHERE NOT EXISTS (SELECT 1 FROM subscription_withdrawals WHERE stripe_subscription_id = NEW.stripe_subscription_id);
END;

CREATE TRIGGER subscriptions_withdrawal_bridge_complete AFTER UPDATE OF withdrawal_completed_at ON subscriptions
WHEN NEW.withdrawal_completed_at IS NOT NULL AND OLD.withdrawal_completed_at IS NULL
BEGIN
  UPDATE subscription_withdrawals SET state = 'settled', settled_at = NEW.withdrawal_completed_at, updated_at = NEW.withdrawal_completed_at
  WHERE stripe_subscription_id = NEW.stripe_subscription_id AND state = 'requested';
END;
