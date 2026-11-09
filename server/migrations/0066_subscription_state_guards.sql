-- State guards for the free-text state columns that no migration guarded yet: the Stripe subscription row
-- (`subscriptions.status` and the complimentary marker), the referral void reason, the sync object kind and the
-- Deepgram stream count. Every allowed set below is the set the code writes (named at each
-- trigger); these triggers make the same rules hold in the database, so a future code path that writes an unknown value
-- fails loudly instead of storing a state no reader understands.
--
-- Additive only: no table rebuild, no existing row is read or changed. Each trigger fires only on an INSERT or on an
-- UPDATE that changes the guarded column (`NEW.x IS NOT OLD.x`), so rows written before this migration stay readable and
-- writable (an UPDATE of other columns on such a row is not checked), and every write the running Worker does passes.
-- `server/scripts/state-guard-violations.sql` lists existing rows outside these sets (read-only).

-- Stripe subscription status (src/billing.ts: the webhook mirrors `Stripe.Subscription.status`, the withdrawal and
-- `charge.refunded` paths write 'canceled'; src/complimentary.ts writes 'active'). Stripe's documented statuses.
CREATE TRIGGER subscriptions_status_insert BEFORE INSERT ON subscriptions
WHEN NEW.status NOT IN ('incomplete', 'incomplete_expired', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'paused')
BEGIN
  SELECT RAISE(ABORT, 'subscriptions: unknown status');
END;

CREATE TRIGGER subscriptions_status_update BEFORE UPDATE OF status ON subscriptions
WHEN NEW.status IS NOT OLD.status
  AND NEW.status NOT IN ('incomplete', 'incomplete_expired', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'paused')
BEGIN
  SELECT RAISE(ABORT, 'subscriptions: unknown status');
END;

-- Complimentary access (src/complimentary.ts) is exactly the row with the synthetic ids `comp_cus_<id>` and
-- `comp_sub_<id>`; the webhook (src/billing.ts) writes real Stripe ids with `complimentary = 0`. `substr`, not LIKE:
-- `_` is a LIKE wildcard.
CREATE TRIGGER subscriptions_complimentary_ids_insert BEFORE INSERT ON subscriptions
WHEN (NEW.complimentary = 1) <> (substr(NEW.stripe_subscription_id, 1, 9) = 'comp_sub_')
  OR (NEW.complimentary = 1) <> (substr(NEW.stripe_customer_id, 1, 9) = 'comp_cus_')
BEGIN
  SELECT RAISE(ABORT, 'subscriptions: complimentary access has comp_ ids, a Stripe subscription has none');
END;

CREATE TRIGGER subscriptions_complimentary_ids_update BEFORE UPDATE OF complimentary, stripe_subscription_id, stripe_customer_id ON subscriptions
WHEN (NEW.complimentary IS NOT OLD.complimentary OR NEW.stripe_subscription_id IS NOT OLD.stripe_subscription_id
    OR NEW.stripe_customer_id IS NOT OLD.stripe_customer_id)
  AND ((NEW.complimentary = 1) <> (substr(NEW.stripe_subscription_id, 1, 9) = 'comp_sub_')
    OR (NEW.complimentary = 1) <> (substr(NEW.stripe_customer_id, 1, 9) = 'comp_cus_'))
BEGIN
  SELECT RAISE(ABORT, 'subscriptions: complimentary access has comp_ ids, a Stripe subscription has none');
END;

-- Referral void reason (src/referrals.ts `ReferralVoidReason`; written by src/referrals.ts and src/referralRewards.ts).
-- 0064 already requires a reason when a row becomes void.
CREATE TRIGGER referral_redemptions_void_reason_insert BEFORE INSERT ON referral_redemptions
WHEN NEW.void_reason IS NOT NULL AND NEW.void_reason NOT IN ('refunded', 'disputed', 'self_referral', 'referrer_deleted',
  'referrer_no_customer', 'referrer_complimentary', 'card_reused', 'self_card', 'canceled_before_payment')
BEGIN
  SELECT RAISE(ABORT, 'referral_redemptions: unknown void_reason');
END;

CREATE TRIGGER referral_redemptions_void_reason_update BEFORE UPDATE OF void_reason ON referral_redemptions
WHEN NEW.void_reason IS NOT OLD.void_reason AND NEW.void_reason IS NOT NULL AND NEW.void_reason NOT IN ('refunded', 'disputed',
  'self_referral', 'referrer_deleted', 'referrer_no_customer', 'referrer_complimentary', 'card_reused', 'self_card',
  'canceled_before_payment')
BEGIN
  SELECT RAISE(ABORT, 'referral_redemptions: unknown void_reason');
END;

-- Sync object kinds (src/sync.ts `syncObjectKinds`); an object's kind never changes.
CREATE TRIGGER sync_objects_kind_insert BEFORE INSERT ON sync_objects
WHEN NEW.kind NOT IN ('meeting.state', 'meeting.content', 'ask.chat', 'people', 'prefs')
BEGIN
  SELECT RAISE(ABORT, 'sync_objects: unknown kind');
END;

CREATE TRIGGER sync_objects_kind_update BEFORE UPDATE OF kind ON sync_objects
WHEN NEW.kind IS NOT OLD.kind
BEGIN
  SELECT RAISE(ABORT, 'sync_objects: an object kind never changes');
END;

-- Deepgram live streams per meeting (src/deepgram.ts `declaredLiveStreams`: 1 or 2; `incrementGrant` only raises it).
CREATE TRIGGER deepgram_live_meetings_streams_insert BEFORE INSERT ON deepgram_live_meetings
WHEN NEW.streams NOT IN (1, 2)
BEGIN
  SELECT RAISE(ABORT, 'deepgram_live_meetings: streams is 1 or 2');
END;

CREATE TRIGGER deepgram_live_meetings_streams_update BEFORE UPDATE OF streams ON deepgram_live_meetings
WHEN NEW.streams IS NOT OLD.streams AND (NEW.streams NOT IN (1, 2) OR NEW.streams < OLD.streams)
BEGIN
  SELECT RAISE(ABORT, 'deepgram_live_meetings: streams is 1 or 2 and only grows');
END;
