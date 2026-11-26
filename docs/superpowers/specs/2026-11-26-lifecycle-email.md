# Lifecycle email (opt-in)

Status: implemented with this spec. Date: 2026-11-26. Goal: activation. People who sign up and then don't record get a
few short, useful emails, only if they ask for them.

## Constraints

- The server stores no email address today (`server/migrations/0015_data_minimization.sql`, `server/src/auth/users.ts`;
  the privacy policy says "we don't store it"). That stays true for everyone who does not opt in. We never read an
  address from an Apple or Google identity token; the user types it.
- Sending uses Cloudflare Email Service from the API Worker (`send_email` binding `EMAIL`). The Workers Paid plan
  includes 3,000 emails per month per account; anything above costs money. Owner rule: never pay for email. The server
  enforces a hard cap below the allowance for all our emails together.
- From `Gistsmith <hello@gistsmith.com>`, reply-to `support@gistsmith.com`, privacy questions to `privacy@gistsmith.com` (Email Routing forwards it to the owner). No DNS
  change in this repo.

## User flow

1. Settings › Account (Mac and iPhone): a toggle "Email me tips and a reminder before my trial ends", off by default.
   Turning it on shows an address field and "Send confirmation link". One calm, skippable card after sign-in (Mac main
   window, iPhone home) while the account is in its trial, shown once per device, not on the sign-in gate. Both appear only while the server says the
   feature is available (`EMAIL_SENDING.policy` on, or the account on its allowlist).
2. `PUT /v1/me/email {address, locale}` stores the address as `pending` with a random confirmation token (SHA-256 hash
   stored) and sends one confirmation email. The app shows "Check your inbox at …" with Resend and Change.
3. The link opens `https://gistsmith.com/email/confirm#<token>`. The page asks for one click ("Confirm my email"), then
   `POST /v1/email/confirm {token}`. A click is required because mail scanners open links; a GET never changes state.
4. Confirmed: the welcome email goes out at once, the rest on schedule. The toggle shows "Sending to …".
5. Turning the toggle off (`DELETE /v1/me/email`), the one-click unsubscribe, the unsubscribe page, or deleting the
   account deletes the address immediately.

## Data (migration 0070, additive)

- `email_subscriptions` (one row per account, only for people who opted in): `user_id` (PK, FK users), `id` (random
  per opt-in, used in unsubscribe links), `email` (the confirmed address, NULL until confirmed), `pending_email` (an
  address waiting for its confirmation; a confirmed address keeps getting mail until a new one is confirmed),
  `confirm_token_hash`, `confirm_expires_at`, `locale` (validated against the supported list), `consent_version`
  (version of the opt-in wording the user agreed to), `created_at`, `pending_at`, `confirmed_at`.
- `email_sends`: `(user_id, kind)` unique, `claimed_at`, `sent_at`. No address. It makes each lifecycle email at most
  once per account, also across unsubscribe and opt-in again. Deleted with the account.
- `email_recipient_limits`: keyed by `HMAC(TRIAL_HASH_SECRET-derived key, lower-cased address)`, never the address:
  confirmation sends in the last 24 hours and 7 days, and `blocked_at` when the recipient used "This wasn't me" in a
  confirmation email. Throttle rows are deleted after 7 days, blocks after 24 months.
- `email_quota`: one row per UTC month: `sent`, `confirm_sent`, `day`, `day_sent`, `day_confirm_sent`, alert marks.
  Not personal.
- `email_daily_counts`: `(day, metric)` → count, for the admin page (opt-ins, confirmations, unsubscribes, expired,
  suppressed, failed, cap refusals, sent per kind). Not linked to anyone. Kept 400 days like the other daily totals.

Retention: an unconfirmed address is deleted 7 days after it was stored. A confirmed address is deleted on
unsubscribe, account deletion, as soon as nothing more can be sent (the welcome is sent and the account has paid access
or got the free plan email), and at the latest 60 days after confirmation. The app and the privacy policy say so.

## Endpoints

| Route | Auth | Does |
|---|---|---|
| `GET /v1/me/email` | bearer | `{available, status: off/pending/confirmed, address, locale}` |
| `PUT /v1/me/email` | bearer | stores the pending address and sends the confirmation; same address again = resend |
| `DELETE /v1/me/email` | bearer | deletes the address and any pending token |
| `POST /v1/email/confirm` | token in body, site CORS | confirms; then sends the welcome email |
| `POST /v1/email/unsubscribe?s=<id>.<sig>` | HMAC signature, site CORS | RFC 8058 one-click and the site page; idempotent |
| `GET /v1/email/unsubscribe?s=…` | — | `303` to the site's unsubscribe page (clients without one-click); never unsubscribes |
| `POST /v1/email/not-me` | token in body, site CORS | "This wasn't me" from a confirmation email: drops the pending address, blocks the recipient |

Errors: `email_unavailable` (403, feature off for this account), `email_quota_reached` (503; the app says "try again
later"), `rate_limited` (at most 3 confirmation emails per account per 24 hours; per recipient at most 1 per 24 hours and
3 per 7 days across all accounts), `email_blocked` (the recipient said "This wasn't me"), `bad_request` (address not
`local@domain.tld`, over 254 characters, or with spaces or control characters), `not_found` (confirm token unknown,
used or expired: one answer for all three).

Unsubscribe signature: `HMAC-SHA256(k, "email-unsubscribe:v1:" + id)` with `k = HMAC-SHA256(TRIAL_HASH_SECRET,
"gistsmith/email-unsubscribe-key/v1")` (domain-separated from the trial hashes; no new secret binding, see the
128-binding limit). The subscription `id` is random per opt-in, so an old link never touches a later opt-in.

## Emails

| Kind | When | Says |
|---|---|---|
| `confirm` | on `PUT` | one link; ignore it if it wasn't you; the address is deleted in 7 days otherwise |
| `welcome` | on confirmation (cron retries) | record the first meeting (Mac, iPhone), Gistsmith Keyboard |
| `activation` | 48 h to 7 days after confirmation, no meeting yet (no trial meeting, no free note) | one reminder: how to start |
| `trial_ending` | trial running, no paid access, 1 trial meeting left or under 24 h left | what happens next (Free plan if it applies, else subscribe; notes stay on the device) |
| `free_plan` | account is on the free plan (`freePlan.isFreePlanAccount` with the last app build seen) | what Free includes, from `FREE_PLAN` |

Each lifecycle email: once per account (`email_sends`), claimed before sending (at most once even if a run dies), in
the opt-in locale (en, tr and `scripts/l10n.py` `TARGET_LANGUAGES`; anything else falls back to English). One shared,
table-based, inline-CSS layout (600 px, system fonts, the site's warm palette, hosted PNG logo with alt text, one
button that is also a plain link, `color-scheme` light dark, preheader) and a plain-text part. Footer (owner decision,
2026-11-26): "Gistsmith · Oulu, <Finland in the email's language>", a link to the privacy policy (where the legal name and
address are) and the privacy address, why the reader gets it, the unsubscribe link; no legal name or street address. Headers: `List-Unsubscribe:
<https://api.gistsmith.com/v1/email/unsubscribe?s=…>`, `List-Unsubscribe-Post: List-Unsubscribe=One-Click`, `List-Id`,
`Precedence: bulk`. The confirmation email (`Auto-Submitted: auto-generated`) has no unsubscribe header (there is no
subscription yet); it carries a "This wasn't me" link instead, which also stops any further confirmation emails to that
address. HTML stays far under Gmail's 102 KB clipping size (tested).

## Sending and caps

- `EMAIL_SENDING` JSON var (not a text binding; the `send_email` binding is `EMAIL`): `policy` (`on`/`off`, global kill switch), `users` (allowlist while
  off), `from`, `fromName`, `replyTo`, `apiOrigin`, `monthlyCap` (2,500), `dailyCap` (150), `confirmMonthlyCap` (1,000),
  `confirmDailyCap` (60), `perRunCap` (40).
  Production shipped with `policy: "off"`; it is `on` since 2026-11-26, after a real send to the owner's Gmail passed
  SPF, DKIM and DMARC.
- Every email (confirmation included) first takes one unit from `email_quota` in a single atomic statement that refuses
  when `sent >= monthlyCap` or the day's `day_sent >= dailyCap` (UTC month and day). It counts the moment it is handed
  to `env.EMAIL.send`, success or failure. At the cap nothing is sent; the first refusal per day/month logs `alert`
  `email_cap_reached` once; sending resumes the next period.
- Cron: a new hourly trigger (`41 * * * *`) runs only the email step (send due lifecycle emails up to `perRunCap`,
  delete expired pending addresses and addresses past retention). Why hourly: the 48-hour and 24-hours-left moments
  land within an hour instead of up to a day late, and the daily cap spreads over the day. The daily trigger keeps
  every other step.
- Errors from `send`: `E_RECIPIENT_SUPPRESSED` (bounced or complained at Cloudflare) deletes the address and counts
  `suppressed`; `E_VALIDATION_ERROR` deletes it as well; `E_RATE_LIMIT_EXCEEDED` and `E_INTERNAL_SERVER_ERROR` retry
  the same call with backoff and then give up for this run (the claim is released, the next run tries again);
  `E_DAILY_LIMIT_EXCEEDED`, `E_SENDER_*`, `E_EMAIL_SENDING_NOT_READY`, `E_ACCOUNT_SUSPENDED` stop the run and `alert`.
- Confirmations have their own share of both caps (`confirmDailyCap`, `confirmMonthlyCap`, inside the totals), so
  someone pushing confirmation emails cannot use up the lifecycle emails' allowance.
- Order per account in a run: `welcome` first; `activation` only without any meeting; `trial_ending` and `free_plan`
  never to an account with paid access; `free_plan` not within 24 hours of `trial_ending`. Eligibility is read right
  before each send. An opt-in after a moment has passed doesn't get that email (e.g. no `trial_ending` once the trial
  ended).
- The kill switch (`policy: "off"`) stops sending only: the hourly retention clean-up, `DELETE /v1/me/email` and the
  unsubscribe endpoints keep working.
- Logs never carry an address, a token or a signature (a test checks the log output).

## Chain

Server (`server/src/email/`), migration, `wrangler.jsonc` (binding and var in dev and production), tests with a fake
binding, admin page totals, `server/README.md`; Mac and iPhone (Settings › Account row, post-sign-in card, strings in
every language); site pages `/email/confirm` and `/email/unsubscribe` (noindex); privacy policy (what, why, legal
basis consent, retention, Cloudflare Email Service as processor, how to withdraw); `AGENTS.md`.

## Owner/parent steps (outside the repo)

Cloudflare dashboard: Compute › Email Service › Email Sending › Onboard Domain › gistsmith.com (adds MX/SPF on
`cf-bounce.gistsmith.com` and DKIM `cf-bounce._domainkey`; Email Routing's root records stay). Add DMARC `p=none`
first. Turn off "Email preview" (it keeps message copies about 7 days). Send one test email to a Gmail address (add
the account to `EMAIL_SENDING.users`) and check the headers show `spf=pass`, `dkim=pass` and `dmarc=pass` (DMARC passes
through relaxed SPF alignment of `cf-bounce.gistsmith.com`). Apple Developer › Certificates, IDs & Profiles › Services ›
Sign in with Apple for Email Communication: register `gistsmith.com` and `hello@gistsmith.com` (and
`cf-bounce.gistsmith.com` if the envelope domain is required), otherwise mail to "Hide My Email" relay addresses
(`privaterelay.appleid.com`), which users may type, bounces. Then set `EMAIL_SENDING.policy` to `on` in a PR.

## Review

Reviewed on 2026-11-26 by an independent red-team subagent (Sonnet; privacy/GDPR and deliverability) against the code.

Adopted:
- Critical: confirmation emails could email-bomb a third party → per-recipient limits by address HMAC (1 per 24 h, 3 per
  7 days, across accounts) and a "This wasn't me" link that blocks the recipient without storing the address.
- Critical: one attacker could use up the shared caps → confirmations get their own share of the daily and monthly cap.
- Critical: proof of consent → `consent_version` and `confirmed_at` are stored with the address.
- Account deletion deletes `email_subscriptions` and `email_sends` in the same batch (tested).
- One-use confirm tokens with one `not_found` answer for unknown, used and expired; constant-time signature check;
  the site pages clear the fragment from the address bar, send no referrer, and need a click.
- `Precedence: bulk`, `List-Id`, `Auto-Submitted` on the confirmation; the Gmail DMARC check and Apple relay
  registration are in the owner steps.
- No address, token or signature in logs (tested). Privacy policy: Cloudflare Email Service as processor, consent
  (Art. 6(1)(a)), retention, withdrawal; the app shows a short notice with a privacy link at the opt-in.
- Ordering, paid accounts get no trial or free plan emails, `free_plan` not within 24 h of `trial_ending`,
  eligibility re-read at send time, missed moments are not sent late.
- Kill switch stops sending only; retention clean-up and unsubscribe keep working (tested).
- Retention shortened to 60 days and to "nothing more to send"; a confirmed address stays until a new one is
  confirmed (`pending_email`).

Not adopted, with reasons:
- Keeping a hashed consent record after unsubscribe or erasure: with double opt-in the record exists for as long as we
  email anyone, and "deleted immediately" is the stronger promise. We email no one without a held, confirmed record.
- Not counting suppressed sends toward our cap (Cloudflare doesn't bill them): the owner's rule is to count every
  hand-off to `send`; counting more is the safe side of "never pay".
- Accepting unsubscribe links by stored id when `TRIAL_HASH_SECRET` rotates: that secret can't rotate without breaking
  the trial ledger, and every address is gone within 60 days, so old links point at deleted rows anyway. The endpoint
  answers "unsubscribed" for any well-signed id, existing or not.
- An IP limit on `PUT /v1/me/email`: it is behind a signed-in account (sign-in is IP limited) and the per-user,
  per-recipient and confirmation-share caps bound the damage.
- Minimum age wording: the terms already require 18+.
