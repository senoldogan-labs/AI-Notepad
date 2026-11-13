-- Checkout funnel by campaign (src/conversion.ts `checkoutCampaignStatement`): how many Stripe Checkouts a campaign
-- opened (`created`), finished (`completed`) and left to lapse (`expired`), counted from the `utm_source` and
-- `utm_campaign` values the site passed to `POST /v1/billing/checkout` (the same allow-list and name format as
-- `download_campaigns`; unknown sources and malformed names are `other`). The completed and expired stages come from
-- the Stripe `checkout.session.completed` and `checkout.session.expired` webhooks, which read the values back from the
-- session metadata. Daily sums only: no account, IP or other identifier; kept 400 days (src/cleanup.ts).
--
-- Additive only: one new table; older Workers never read it.
CREATE TABLE checkout_campaigns (
  day TEXT NOT NULL,
  stage TEXT NOT NULL,
  utm_source TEXT NOT NULL,
  utm_campaign TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, stage, utm_source, utm_campaign)
);
