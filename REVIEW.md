# Review guide

Read by the pre-push review (`.claude/hooks/pre-push-review.sh`) and `/code-review`. AI-Notepad and Gistsmith record
meetings, transcribe them and write notes; the hosted edition keeps accounts, subscriptions and synced meetings on the
Cloudflare Workers in `server/`. A change is judged by whose meetings it could expose and who it could charge, as much
as by how it reads. Pull requests merge on their own once CI is green, so this review is the only one a change gets.

## What failure looks like here

- A meeting's audio, transcript, note, screenshot or chat reaches anyone but its owner: another account through sync, a
  share link, the MCP connector, the AI assistant copy (`server/src/assistant/`), or the logs, telemetry and admin
  pages without redaction.
- The server answers a request it should refuse: a missing, expired or forged token, another user's id, an MCP client
  without a grant, an admin route without admin access, a device that fails App Attest or DeviceCheck.
- Someone gets paid use without paying, or a payer loses it: entitlements, trials, referrals, complimentary grants,
  usage limits, App Store, Stripe and RevenueCat handling.
- A secret (API key, token, Keychain item, share key) is logged, synced, or sent to a service other than its own.
- The app records audio or the screen without the user seeing it, or keeps recording after it says it stopped.
- A D1 migration loses or rewrites existing rows, or code needs a column or table no migration creates.
- A line in `AGENTS.md`, `server/README.md` or `web/` says the product does something it no longer does.

## Always flag (Important)

- Behavior that contradicts the PR's stated intent; a bug fix that patches a symptom instead of the root cause
- An error swallowed, caught by a catch-all, or hidden behind a fallback
- Data from outside (a request body, an upstream or webhook answer, a file, a model's output) used before it is
  validated
- A server query that reads or writes a user's rows without scoping them to the authenticated account
- A test that calls a paid service or the network without its environment gate (`AINOTEPAD_CLOUD_TESTS` and the
  others in `AGENTS.md`)
- The sample meeting (`isSampleMeeting`) reaching sync, processing, notifications, MCP or automatic sending
- A user-facing string without its translations (`LocalizationCompletenessTests`)
- A change in what the server or `server/README.md` promises without the matching change in the other

## Read with extra care

A change under these paths gets the surrounding code read, not just the diff, against the failures above:

- `server/src/auth/`, `server/src/attest/`, `server/src/mcp/` (authorize, grants, gate), `server/src/admin*.ts`
- `server/src/crypto.ts`, `server/src/assistant/crypto.ts`, `server/src/shares.ts`, `server/src/sync.ts`
- `server/src/billing.ts`, `server/src/appStore.ts`, `server/src/entitlements.ts`, `server/src/revenue.ts`,
  `server/src/trialLedger.ts`, `server/src/referral*.ts`, `server/src/complimentary.ts`, `iOS/Purchases/`
- `server/migrations/`, `server/migrations-assistant/`
- `server/wrangler.jsonc`, `server/wrangler.mcp.jsonc` (production bindings, variables and routes)
- `Packages/AINotepadCore/Sources/AINotepadCore/Sync/`, `Sharing/`, `Support/Keychain.swift`, `App/Hosted/`
- `scripts/release*.sh`, `Config/Signing.xcconfig`, `*.entitlements`, `.github/workflows/`

## Evidence and format

- Cite file and line for every finding; read the code instead of guessing from names
- Tag each finding **Important** (introduced by this change, must fix), **Nit** (optional) or **Pre-existing** (was
  already there; don't block on it)
- At most 3 nits; skip what the Swift compiler, `tsc` and `ruff` already enforce
- When a bug has siblings, name the bug class and list every instance
- Start the summary with the finding count, e.g. "2 Important, 1 Nit"; with nothing to fix, say "No issues found"

## Re-reviews

- After the first full pass, review only the new diff
- Don't repeat findings that were fixed or answered with a reason
- After 3 rounds, stop and ask the author to reconsider the approach (the hook counts the rounds and says so; a push
  that only brings main in is not a round)

## Skip

- `Config/Package.resolved`, `*/package-lock.json`, `*/uv.lock`
- Images, `docs/appstore/`, `docs/release-notes/`, `promo/` media
- Translations in `*.xcstrings` beyond their completeness
