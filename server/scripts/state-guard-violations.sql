-- Read-only: rows that migration 0066's triggers would refuse if they were written today. The triggers never touch
-- existing rows (they only check new writes), so any row listed here keeps working; the list says whether production
-- holds a value the code does not write, which would mean a reader somewhere sees a state it does not handle.
--
--   npx wrangler d1 execute ainotepad-production --remote --env production --file scripts/state-guard-violations.sql
--
-- Every query only SELECTs; an empty result for each means production already satisfies every guard.

SELECT 'subscriptions.status' AS guard, status AS value, COUNT(*) AS count
FROM subscriptions
WHERE status NOT IN ('incomplete', 'incomplete_expired', 'trialing', 'active', 'past_due', 'canceled', 'unpaid', 'paused')
GROUP BY status;

SELECT 'subscriptions.complimentary_ids' AS guard, complimentary AS value, COUNT(*) AS count
FROM subscriptions
WHERE (complimentary = 1) <> (substr(stripe_subscription_id, 1, 9) = 'comp_sub_')
  OR (complimentary = 1) <> (substr(stripe_customer_id, 1, 9) = 'comp_cus_')
GROUP BY complimentary;

SELECT 'referral_redemptions.void_reason' AS guard, void_reason AS value, COUNT(*) AS count
FROM referral_redemptions
WHERE void_reason IS NOT NULL AND void_reason NOT IN ('refunded', 'disputed', 'self_referral', 'referrer_deleted',
  'referrer_no_customer', 'referrer_complimentary', 'card_reused', 'self_card', 'canceled_before_payment')
GROUP BY void_reason;

SELECT 'app_store_subscriptions.period_type' AS guard, period_type AS value, COUNT(*) AS count
FROM app_store_subscriptions
WHERE period_type NOT IN ('normal', 'trial', 'intro', 'promotional', 'prepaid')
GROUP BY period_type;

SELECT 'sync_objects.kind' AS guard, kind AS value, COUNT(*) AS count
FROM sync_objects
WHERE kind NOT IN ('meeting.state', 'meeting.content', 'ask.chat', 'people', 'prefs')
GROUP BY kind;

SELECT 'deepgram_live_meetings.streams' AS guard, streams AS value, COUNT(*) AS count
FROM deepgram_live_meetings
WHERE streams NOT IN (1, 2)
GROUP BY streams;
