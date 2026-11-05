# Remote MCP connector ("AI assistant access")

Status: v1 design after three independent reviews (security/privacy, MCP platform/directories, practicality),
2026-11-05. Review record at the end.

## Goal

Let a Gistsmith subscriber read their meeting notes from Claude, ChatGPT and Cursor (Grok once its custom connectors
are verified) through a remote MCP server, and get Gistsmith listed in the Claude and ChatGPT connector directories.

The app already ships a local, read-only stdio MCP server (`Packages/AINotepadCore/Sources/AINotepadCore/MCP/MCPServer.swift`,
`--mcp`) for desktop clients. Remote connectors need HTTPS + OAuth; the directories no longer accept local servers.

## Constraint

Notes live on the devices; sync (off in production) stores only end-to-end encrypted blobs; the servers keep no notes.
A remote connector needs a server-readable copy, so it exists only for users who turn the feature on.

## v1 scope

- **Opt-in in the app only** (Mac and iPhone): Settings › Connections › "Online assistants" › "Let AI assistants read my
  meeting notes". Off by default. It can never be turned on from the web consent page.
- **Notes only**: title, date, duration, folder, attendees, note (summary, decisions, tasks with owner/due/done,
  outline, glossary) and the user's own notes. No transcripts, audio, screen snapshots or voiceprints in v1.
- **Clients**: Claude (first directory submission), ChatGPT (second), Cursor and Claude Code (same endpoint). Grok
  appears in copy only after a manual connection test succeeds.
- **No upsell**: no checkout links or plan prompts in tool output or consent pages (ChatGPT rule). Errors say what to
  do in the app.

## Architecture

Separate Worker `gistsmith-mcp` on `mcp.gistsmith.com`, built from `server/` with its own entry file and wrangler
config, so the payment/auth Worker gets no new dependencies or compatibility flags.

- `@cloudflare/workers-oauth-provider@1.2.4` (pinned): authorization server + resource server; KV namespace
  `OAUTH_KV`. Client ID Metadata Documents enabled (`clientIdMetadataDocumentEnabled`, `global_fetch_strictly_public`
  on this Worker only), DCR kept for older clients. Metadata advertises `iss`, `"none"` token auth,
  `client_id_metadata_document_supported`. PKCE S256 required.
- Resource / audience: exactly `https://mcp.gistsmith.com/mcp`; tokens for it are never accepted by the API Worker and
  app tokens are never accepted here (tests both ways).
- MCP: `createMcpHandler` (`agents`, pinned), stateless Streamable HTTP, tools only; scopes checked in the handler.
- Every MCP call additionally checks in D1 (strongly consistent, unlike KV): feature enabled, account has access
  (`hasSyncAccess`), grant listed as live at the account's current epoch, user not deleted. Revocation therefore takes
  effect immediately. The code exchange records the grant with one conditional statement (`INSERT … SELECT … FROM
  assistant_settings WHERE enabled = 1 AND epoch = ?`), so a turn-off between consent and exchange never revives it.
- The API Worker's assistant code is inert until the owner enables it: production has no `ASSISTANT_DB` /
  `ASSISTANT_BUCKET` bindings while `ASSISTANT_POLICY` is off; routes answer `assistant_unavailable`, account deletion
  and the daily cleanup skip the assistant step (logged). Policy on without the bindings fails configuration
  validation on the first request. Enable order: create the EU D1 → migrate → add the bindings → set the policy.
- Tokens: access 1 h; refresh 30 days idle, 180 days max, then consent again.
- Redirect URIs: allowlist for verified clients (Claude `https://claude.ai/api/mcp/auth_callback`, ChatGPT
  `https://chatgpt.com/connector_platform_oauth_redirect`, Cursor's documented callbacks, loopback for Claude Code).
  Other clients: `https` or loopback only, max 5 URIs, shown as unverified.
- Limits: `/oauth/register` 10 per IP per hour and 16 KB per body (`content-length` checked first, bounded read);
  registered clients that never completed a consent deleted after 24 h (a client that connected once keeps its
  registration, which the library renews on use); MCP 60 calls/min per grant, 300 `fetch` calls per grant per day; ops event + in-app notice when a grant reads more than 100 meetings in
  an hour.

## Sign-in and consent (on mcp.gistsmith.com)

- `/oauth/authorize` → the library's browser-bound, single-use consent session (`__Host-` cookie, 10 min, frame
  blocking) → Apple / Google sign-in on this origin (owner adds `https://mcp.gistsmith.com` to the Apple Services ID
  return URLs and the Google web client origins) → consent screen.
- Consent screen: for allowlisted clients "Claude (verified)"; otherwise the redirect host as the heading and
  "Unverified app: <name, max 40 chars, confusables stripped>"; never a logo. Shows scope "Read your meeting notes",
  the sign-in provider and account creation date (the server stores no email). If the feature is off: "Turn on AI
  assistant access in the Gistsmith app first" and no way to enable it here.
- Invalid client or redirect → error page, never a redirect. Any other invalid request (wrong `resource`, no PKCE)
  of a client that is not a verified product → error page too (RFC 9700 §4.11.2: DCR lets anyone register a redirect
  URI); only verified products' callbacks get standard OAuth error redirects. `Referrer-Policy: no-referrer`, no
  analytics on these pages, every client-supplied value escaped.
- Verified clients' consent pages also ask the user to continue only if they started the connection themselves
  (consent phishing with a real Claude/ChatGPT authorization link).
- After a new grant: "New assistant connected: <name/host>" notice on the user's devices.
- Reviewer login: an email + password form shown only for allowlisted reviewer accounts (secret-held credentials),
  required because directory reviewers cannot use Apple/Google sign-in with MFA.

## Storage (EU)

- New D1 database `gistsmith-assistant` created with `--jurisdiction eu`: `assistant_settings (user_id, enabled, epoch,
  updated_at)`, `assistant_meetings (user_id, meeting_id, device_id, started_at, updated_at, size, index_ct,
  object_id)` with primary key `(user_id, meeting_id)`, `assistant_grants (user_id, grant_id, client_id, redirect_host,
  verified, created_at, epoch, last_used_at, call counters)`. No plaintext titles or note text in D1: `index_ct` is the
  sealed per-meeting index.
- Notes in the existing EU R2 bucket under `a/<user>/<epoch>/<meeting>/<object id>` (every upload is a new object; a
  refused upload deletes only its own object, never the note the row still names): AES-256-GCM, per-user subkey via
  HKDF from `ASSISTANT_DATA_KEY` (secret), key id in each object for rotation, AAD = user + meeting + field + version.
- Caps: index JSON ≤ 8 KB (search text ≤ 4 KB of title, summary, decisions, task text, outline titles; own tasks ≤ 50
  with ≤ 300 characters each, dropped from the end to fit); note JSON ≤ 512 KB; account ≤ 5,000 meetings and ≤ 256 MB
  of sealed notes + indexes, enforced in the same conditional statement as the upload's insert (no check-then-write).
- Search: decrypt the user's newest ≤2,000 indexes, at most 6 MB of them (D1 returns index blobs only within a running
  byte budget), and score in memory (BM25-lite). Query sanitised to at most 8 quoted terms; `limit` ≤ 50.
- Never logged: queries, titles, note text, error messages that echo arguments; no request-body logging or Logpush on
  this Worker.
- Grant props in KV hold only the opaque user id. Connection records may be stored outside the EU (stated in the
  privacy policy).

## Data flow from the apps

- API on `api.gistsmith.com` (existing Worker, app bearer tokens): `GET/PUT /v1/assistant/settings` (enabled + epoch),
  `PUT /v1/assistant/meetings/:id` (accepted only while enabled and with the current epoch, else 409),
  `DELETE /v1/assistant/meetings/:id`, `GET /v1/assistant/grants`, `DELETE /v1/assistant/grants/:id`,
  `DELETE /v1/assistant/devices/:deviceId` (remove a lost device's meetings).
- `meetingId` and `deviceId` are UUIDs; `user_id` always comes from the token. `deviceId` is chosen by the app and
  scoped by `user_id` only: there is no device registry to bind it to (the `devices` table holds App Attest keys of
  iPhones only, with base64 ids, and is pruned when unused). This is safe because every statement that uses it also
  filters by the token's `user_id` (`WHERE user_id = ? AND device_id = ?`), so a guessed or reused device id can only
  ever select the caller's own meetings; it labels uploads for "remove a lost device's meetings" and grants nothing.
- The apps upload after processing/editing and backfill newest first when enabled (iPhone: foreground or BGProcessing,
  with progress). Mac and iPhone upload their own meetings while sync is off; the copy is their union.
- Turning off: delete D1 rows and the R2 prefix at once, revoke grants, bump epoch. Access ends (subscription/trial):
  MCP access stops immediately, the copy is deleted within 7 days. Account deletion: same transaction as today's
  deletion batch + R2 purge + queued KV grant revocation (like `sync_purges`). Backups: gone within 30 days.

## Tools (all `readOnlyHint: true`, `destructiveHint: false`, `openWorldHint: false`, `title` set, `securitySchemes`)

- `search {query}` → `{results: [{id, title, url}]}` (ChatGPT deep research / company knowledge shape).
- `fetch {id}` → `{id, title, text, url, metadata}`; `text` is the note as Markdown inside a clearly labelled data
  field. `url` = stable `https://gistsmith.com/m/<id>` (opens the meeting in the app when installed; otherwise a page
  explaining it lives in the app).
- `list_meetings {cursor?, since?, until?, folder?, limit?}` — ISO 8601 timestamps with offset, opaque cursor.
- `list_my_tasks {include_done?}`.
- Structured content plus a JSON text copy, `outputSchema` declared. Errors use `isError: true` with an actionable
  message ("AI assistant access is off. Turn it on in the Gistsmith app."). Descriptions describe; they never instruct
  the model. Meeting text is returned as data only; `fetch`'s note sits between `BEGIN`/`END UNTRUSTED MEETING CONTENT`
  markers with a random per-response boundary the content cannot guess.

## Copy and legal

Privacy policy (new purpose, data, EU storage, retention, connection records, sub-processor Cloudflare), terms, data
handling table, site copy and FAQ (en, fi), llms.txt, App Store metadata and privacy label ("User Content, linked to
you" when enabled), App Review notes, and every in-app "stays on this Mac" sentence. Wording rules:
- "Off by default. Turn it on and an encrypted copy of your notes, never audio, is kept in the EU so the assistants you
  connect can read them. Turn it off and it is deleted at once (backups within 30 days)."
- Say plainly: our servers can technically read this copy (encrypted at rest, not end to end); what an assistant reads
  falls under that provider's policies; assistants with other tools (email, web) can be steered by meeting content.

## Phases

1. Server Worker + EU D1 + R2 projection + OAuth + MCP + tests (unit; Workers integration; e2e with a fake client doing
   CIMD/DCR + PKCE + resource; two-account isolation; revocation; epoch race).
2. Apps (Mac + iPhone): Connections UI, upload queue, backfill, deletion, grants list with Disconnect, new-connection
   notice.
3. Copy and legal; consent pages; owner console steps (DNS for mcp.gistsmith.com, Apple Services ID, Google origins).
4. Owner submits: Claude first, then ChatGPT (domain challenge, 5 positive / 3 negative test cases, demo video,
   reviewer account with demo meetings).

## Review record

Three independent reviewers read the first draft.
- Security/privacy (red team): consent phishing via DCR (critical), cross-tenant ids (critical), plaintext FTS defeats
  encryption and deletion, token confusion between the two systems, KV revocation lag, email on consent conflicts with
  storing no email, enable/upload race, 90-day retention too long, EU residency of D1/KV, registration abuse,
  consent-page request-id leaks, prompt injection, FTS query abuse, sensitive logs. All adopted above.
- MCP platform/directories: spec is now 2026-07-28 (CIMD preferred, DCR deprecated, `iss`), pin provider 1.2.4,
  exact resource string, required redirect URIs, consent must live on the authorization origin, reviewer login
  blocker, ChatGPT's no-upsell rule, `search`/`fetch` tools, annotations, paging. All adopted; architecture changed to
  a separate Worker on mcp.gistsmith.com.
- Practicality/product: build smaller (notes only, Claude first), encrypted blobs in R2 not D1, consent on the Worker,
  stale-device handling, App Store privacy label. Adopted. Dissent: the reviewer recommends waiting until sync is on in
  production. Not adopted: per-device upload works without sync, the reviewer account is single-device, and the sync
  launch is a separate decision with its own copy changes. Estimated effort about 2.5–3 weeks.

Independent security review of the implementation (PR #256), 2026-11-05. Fixed, each with a regression test:
- The API Worker would not deploy (placeholder EU D1 id) and account deletion called the assistant store
  unconditionally: production now has no assistant bindings, every assistant path needs the policy on and the
  bindings, and the policy without bindings fails configuration validation.
- Grant revival race between the code exchange's gate check and its insert: one conditional insert, `epoch` column on
  grants, compared on every call and refresh.
- Unbounded encrypted index and copy: the caps above, an atomic per-account byte quota, and a byte budget on scans.
- Open redirect through DCR clients on invalid requests: error pages for every client except verified products.
- Registration body read before its size was checked: `content-length` first, bounded reader.
- `deviceId` ownership: documented above (scoped by user, no registry).
- Also: untrusted-content markers in `fetch`, a "did you start this?" line on verified consent pages, unused-client
  cleanup no longer deletes clients that connected, and the API Worker's tests run without the MCP Worker's
  compatibility flags.

Accepted risks:
- The MCP Worker has a writable binding to the production database (`DB`): D1 has no read-only bindings. Its code only
  reads there (users, identities, entitlements; sign-in nonces and key caches live in the EU database), and it holds
  no API secrets. Revisit if Cloudflare adds read-only D1 bindings or a read replica binding.
- Reviewer logins (`REVIEWER_LOGINS`) are password sign-ins that bypass Apple/Google MFA. They exist only for the
  directory reviews: the owner removes the secret (and the reviewer account's grants) once each review is done.
- Turning `ASSISTANT_POLICY` back off after launch makes account deletion skip the assistant copy; the daily cleanup
  deletes copies of deleted accounts once the policy is on again. The policy stays on after launch.
- A reader that loads a meeting's row just before an update replaces its object can miss the old object (rare; the
  call fails and is retried). Two simultaneous updates of the same meeting can leave one superseded object in R2; it
  is deleted with the epoch's prefix when the feature is turned off or the account is deleted.
