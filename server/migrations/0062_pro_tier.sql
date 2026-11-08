-- Pro tier (src/tiers.ts): a subscription is either Personal or Pro; the tier picks the account's usage limits
-- (PRO_* settings in wrangler.jsonc) and the MRR price. Additive only: existing rows are Personal (the only tier sold
-- before this migration). `plan` keeps meaning the billing interval (monthly/yearly) on both tables.
--   subscriptions.tier: written by the Stripe webhook from the subscription's price (src/billing.ts `tierOfSubscription`);
--     complimentary access is Personal.
--   app_store_subscriptions.tier: written by the RevenueCat sync from the product id (src/appStore.ts `appStoreTierOf`).
ALTER TABLE subscriptions ADD COLUMN tier TEXT NOT NULL DEFAULT 'personal' CHECK (tier IN ('personal', 'pro'));
ALTER TABLE app_store_subscriptions ADD COLUMN tier TEXT NOT NULL DEFAULT 'personal' CHECK (tier IN ('personal', 'pro'));
