# Shared folders

Date: 2026-11-08. Status: revised after three independent reviews (see "Review" at the end); built behind
`SHARED_FOLDERS_POLICY` (off in production) in two stacked pull requests: (1) server, migration, core cryptography,
client and service with unit, server and hosted end-to-end tests; (2) Mac and iPhone screens, invite links (`/j`,
`gistsmith://join`) and translations. Growth plan step 4. Related: the share-link design (`server/src/shares.ts`,
`Sharing/NoteShare.swift`, PR #284) and sync (`2026-11-03-mac-iphone-sync-options.md` §8, `Sync/SyncCrypto.swift`).

## Goal

A Gistsmith user shares one of their folders with teammates. Every note in that folder, now and later, becomes readable
by the members on Mac and iPhone: title, date, summary, outline, decisions, open questions, tasks and glossary.
Transcripts only when the owner turns them on for that folder (off by default). Audio, screenshots, photos, personal
marks ("done", "You"), own notes (`myNotes`) and Ask chats are never shared. The owner can remove a member and stop
sharing. Members read; they do not edit, comment or assign tasks in v1.

The server must never be able to read a shared note, a folder name, an invitee label or a member's display name.

## Threat model

Assets: note contents, folder names, the owner's labels for invitees (often an e-mail address), member display names.

| Adversary | Can | Must not be able to |
|---|---|---|
| Honest-but-curious server / Cloudflare / a D1 or R2 dump | See who owns which folder, which accounts are members, counts, sizes, timestamps | Read a note, folder name, label or display name |
| Actively malicious server | Drop, delay or replay ciphertext; withhold items; refuse requests; hide a removal from an owner device that has never seen it (below) | Read content; inject or alter a note; get a folder key wrapped to a key of its choosing |
| A member (current or removed) | Read what the folder gave them while they were a member | Forge a note, the folder metadata or the member roster; read invite labels or pending invite secrets; read notes published after their removal |
| Someone holding a forwarded invite link | Accept the invite first (it is single-use) | Stay unnoticed: the owner sees the accepted name and can remove them |

Out of scope: a compromised owner or member device (it holds plaintext anyway), traffic analysis, the social graph
(the server must know who may download what), and the website serving malicious JavaScript on `/j` (the same trust the
existing `/s` share page already needs; universal links remove it, see "Later").

Known limits, stated rather than hidden:
- Rollback: the server can serve an older genuine item or roster to a device that has not seen the newer one. Devices
  pin the highest key epoch and roster version they have seen per folder and refuse anything older, so the window is
  limited to a device's first contact.
- Removal hiding: a malicious server colluding with a removed member could show an owner device that never saw the
  removal the old roster, and that device would keep publishing under the old key. Every owner device pins the highest
  roster version it has seen; the device that made the removal can never be fooled.
- Sizes: item sizes reveal roughly whether a transcript is included.
- The sync recovery code now also protects the sharing identity (it opens the sync key, which opens the sealed seed).

## Keys

### Sharing identity (per account)

- A random 32-byte **identity seed** per account, created on the first device that uses shared folders. HKDF-SHA256
  derives three keys from it: an **X25519** key (`gistsmith.folder.v1.agreement`, receives keyrings), an **Ed25519** key
  (`…signing`, the owner signs keyrings, metadata, rosters and notes) and an **owner-private** AES key (`…owner-private`,
  seals what only the owner's devices may read: invite labels and invite secrets).
- The seed is stored in the account's Keychain item on this device only (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  on iPhone), like the sync key. It never reaches the server in the clear. Signing out of the account removes it with
  the account's other Keychain items.
- Public keys are registered once (`sharing_identities`); the first registration wins (`INSERT … ON CONFLICT DO NOTHING`)
  and later calls cannot replace the keys. A device that loses the race discards its seed.
- **Other devices of the account**: when sync is on, the seed is also stored on the server sealed with the account sync
  key (`sealed_seed`: AES-256-GCM under HKDF(ASK, `gistsmith.folder.v1.seed`), AAD = user id, both public keys and the
  ASK key id). A device that joined sync through an existing authenticated path (link code, pairing, recovery code)
  opens it and checks that the derived public keys equal the registered ones. When the account's sync key changes,
  any device that still holds the seed re-seals it. A device that finds a registered identity it cannot open never
  creates a new one: it says "Open Gistsmith on a device where shared folders are set up". Single-device members need
  no sync at all.
- Why the identity is not derived from the sync key: the sync key is replaced whenever sync is reset or wiped after 90
  days without access (`SyncSetup.startSync`), which would silently change every identity.
- **Reset**: if every device lost the seed, "Reset shared folders" stops sharing every owned folder, leaves every joined
  folder and deletes the identity in one request; the next use creates a new one.

### Folder keyring

- Each folder has a **keyring**: one 256-bit key per **epoch** (1, 2, …). The newest epoch seals new notes; older
  epochs stay so earlier notes remain readable.
- **Items** (one per shared note) are sealed with AES-256-GCM under HKDF(epoch key, `gistsmith.folder.v1.item`, info =
  item id), AAD = framed label, folder id, item id, epoch. The owner signs the framed label, folder id, item id, epoch
  and `SHA-256` of the sealed part with Ed25519. Format `GSF1 ‖ epoch (u32 BE) ‖ nonce (12) ‖ ciphertext ‖ tag (16) ‖
  signature (64)`. Members verify the signature with the owner's pinned signing key before decrypting, so a member
  cannot forge a note although they hold the folder key.
- **Folder metadata** (name, owner display name, transcripts on/off) is sealed and signed the same way with item id
  `meta`, under the newest epoch.
- **Item ids** are UUID-shaped HMACs of the meeting's local id under a key derived from epoch 1
  (`…item-id`); a **content tag** (HMAC of the payload under the same key) lets the publisher skip unchanged uploads.
  The server cannot link either to a meeting.
- **Keyring envelopes**: the whole keyring is wrapped to a member's X25519 key with **HPKE** (RFC 9180, base mode,
  `Curve25519_SHA256_ChachaPoly`, CryptoKit), `info` = framed label, folder id, member id, epoch; the owner signs the
  framed folder id, member id, epoch and the HPKE output. The owner wraps it to their own identity too (member id
  `owner`). Format `GSK1 ‖ encapsulated key (32) ‖ ciphertext ‖ signature (64)`.

### Signed member roster

The owner signs a **roster**: folder id, roster version, key epoch and, for every active member, member id, user id and
both public keys. Owner devices wrap keyrings only to keys in a roster they signed or verified, and refuse a roster
version older than the highest they have seen. Members verify the roster's signature too (they see who else is in the
folder by count only; names are not in the roster). The server stores the roster and its signature but cannot change
it.

- **Activation** (a verified acceptance becomes a member): new roster version with the member added, same epoch, the
  member's envelope.
- **Removal**: one request carries the new roster without the member, epoch N+1, the new sealed metadata and envelopes
  for the owner and every remaining member. The server applies it atomically (below). Items already published stay at
  their epoch; the removed member could already read them.
- **Leaving** and **a member's account deletion** remove the member row at once and set `needs_rotation`; the next owner
  device rotates them out of the roster the same way. While `needs_rotation` is set, the server refuses new items.

## Invites

E-mail invites without the server knowing e-mail addresses (since migration 0015 the server keeps no account e-mail and
it sends no e-mail; this feature keeps it that way).

1. The owner types who they are inviting (a name or e-mail address: the **label**, sealed with the owner-private key).
2. The owner's device makes a random 128-bit **invite id** and 256-bit **invite secret** and uploads: the sealed label,
   the secret sealed with the owner-private key, an **owner proof** `HMAC(secret, framed("owner", folder id, invite id,
   owner public keys))`, and a **preview** (folder name and owner name sealed with a key derived from the secret).
   The invite expires after 7 days.
3. The system share sheet opens (Mail, Messages, Slack…) with a prefilled subject and the link
   `https://gistsmith.com/j#<inviteId>.<secret>`. The fragment never reaches a server. The `/j` page offers
   "Open in Gistsmith" (passes the fragment to `gistsmith://join#…` in the browser), "Copy link" and the download links.
4. The invitee opens the link in Gistsmith (custom URL scheme, or paste on the join screen; the join screen offers an
   invite link found on the pasteboard). The app fetches the invite, checks the owner proof against the owner keys the
   server returned (a swapped key fails here), opens the preview and shows "Ayşe shares “Sales weekly” with you".
   Signing in is required; the invitee may need to create a free account.
5. Accepting sends `memberProof = HMAC(secret, framed("member", folder id, invite id, member user id, member public
   keys))` and the member's display name (prefilled from the profile) sealed with the preview key. The server copies the
   member's registered public keys onto the member row; the invite is used up.
6. The member's device pins the owner's public keys for the folder, sealed with a key derived from its own seed
   (`sealed_pin` on the member row), so every device of the member checks the same owner keys.
7. Any owner device, on its next refresh (start, foreground, after a sync pass, every 5 minutes on Mac while running),
   opens the sealed secret, verifies the member proof against the keys and user id the server reports and activates the
   member. A proof that does not verify is never activated: "This join couldn't be verified. Remove it if you don't
   recognize it."

Activation is automatic (holding the link is the authorization, like a single-use invite code). The owner sees the
accepted name and can remove the member in one tap; a forwarded link burns the invite, so the intended person notices.

## Server

### Switch

`SHARED_FOLDERS_POLICY` (`on`/`off`, wrangler vars; with `SHARED_FOLDERS_MEMBER_ACCESS` below): `off` in production until verified, `on` in development and tests.
`off`: `GET /v1/shared-folders` answers `200 {available: false, folders: []}` so the apps hide the feature, and every
other shared-folder endpoint answers `503 shared_folders_unavailable`. Account deletion and the daily cleanup still
delete shared-folder data while it is off. Apps never delete their member cache on `available: false`.

### D1 schema (`0060_shared_folders.sql`, additive only; a code rollback is safe only while the policy is off and the tables are empty: rows reference `users`, so code that predates the feature could not delete those accounts — after enabling, fix forward)

- `sharing_identities(user_id PK → users, agreement_key, signing_key, sealed_seed, seed_key_id, created_at, updated_at)`
- `shared_folders(folder_id PK, owner_id → users, sealed_meta, key_epoch, owner_envelope, roster, roster_signature,
  roster_version, members_version, items_rev, needs_rotation, created_at, updated_at, access_seen_at)`
- `shared_folder_members(folder_id, member_id, status ('invited'|'accepted'|'active'), user_id, sealed_label,
  sealed_secret, owner_proof, sealed_preview, expires_at, member_agreement_key, member_signing_key, member_proof,
  sealed_name, sealed_pin, envelope, envelope_epoch, created_at, updated_at; PK (folder_id, member_id); member_id unique)`
- `shared_folder_items(folder_id, item_id, key_epoch, tag, size, r2_key, items_rev, updated_at; PK (folder_id, item_id))`

`members_version` increases on every membership change (invite, accept, activation, removal, leave, account deletion);
`items_rev` on every item change or rotation. Both are compare-and-set guards and change detectors.

### Storage

Item ciphertext lives in R2 (`SYNC_BUCKET`, prefix `f/<folderId>/`), D1 holds only the index, reusing sync's free-tier
budgets (`sync_r2_usage` Class A/B counters, the stored-bytes budget now counts shared items too) and its purge queue
(`sync_purges`). Item lists never read blobs.

### API (session required; `SYNC_USER_LIMITER`, 300/min per user)

| Method and path | Who | What |
|---|---|---|
| `GET /v1/sharing/identity` | any | own public keys, sealed seed and its key id, or null |
| `PUT /v1/sharing/identity` | any | register keys (first wins); later calls may only refresh the sealed seed |
| `DELETE /v1/sharing/identity` | any | reset: stop sharing owned folders, leave joined ones, delete the identity |
| `GET /v1/shared-folders` | any | `{available, folders}`: owned and joined folders with sealed meta, epoch, own envelope, roster, owner keys, versions, member's sealed pin |
| `POST /v1/shared-folders` | owner, subscription or trial | create (id, sealed meta, owner envelope, roster v1); same id again is 200 |
| `DELETE /v1/shared-folders/:id` | owner | stop sharing: rows deleted at once, blobs queued for purge |
| `PUT /v1/shared-folders/:id/roster` | owner (no subscription needed) | activation or rotation, compare-and-set on epoch and `members_version` |
| `GET /v1/shared-folders/:id/members` | owner | invites and members with sealed label/secret/name, proofs, keys |
| `POST /v1/shared-folders/:id/invites` | owner, subscription or trial | create an invite; same id again is 200 |
| `DELETE /v1/shared-folders/:id/invites/:memberId` | owner | revoke an invite that has not been activated |
| `DELETE /v1/shared-folders/:id/membership` | member | leave (sets `needs_rotation`) |
| `GET /v1/shared-invites/:inviteId` | any with identity | preview: owner keys, owner proof, sealed preview, state |
| `POST /v1/shared-invites/:inviteId/accept` | any with identity, not the owner | accept; same user again is 200 |
| `GET /v1/shared-folders/:id/items` | owner, active member | index (id, epoch, tag, size, rev) |
| `GET /v1/shared-folders/:id/items/:itemId` | owner, active member | the sealed item |
| `PUT /v1/shared-folders/:id/items/:itemId` | owner, subscription or trial | upload at the current epoch; refused while `needs_rotation` |
| `DELETE /v1/shared-folders/:id/items/:itemId` | owner | delete; already gone is 200 |

Scoping: owner routes check `owner_id = user`; member routes check an `active` row with `user_id = user` and
`envelope_epoch = key_epoch`. A stranger gets `404`, so ids cannot be probed.

Atomicity (D1 batches are transactions but cannot branch): the first statement of a roster change is the
compare-and-set `UPDATE shared_folders … WHERE key_epoch = ? AND members_version = ?`; every later statement of the
batch is guarded by `EXISTS (folder at the new epoch and version)`, and the handler checks the first statement's row
count. Item writes check `key_epoch = ? AND needs_rotation = 0` and every limit inside the `INSERT … SELECT … WHERE`.
Retried requests are idempotent (same id and same bytes answer as the first time); a client whose roster change
succeeded but lost the response sees its own roster stored and treats that as success.

### Limits (abuse, spam, cost)

Owned folders per account 20; memberships per account 100; members plus open invites per folder 50; open invites per
folder 20; invites created per account per day 30; invite lifetime 7 days; accepted-but-never-activated invites 30
days. Items per folder 1,000; item size 1 MiB; stored item bytes per owner 100 MB; all of R2 within sync's free-tier
budget. No server-sent e-mail at all.

### Billing

- Owner: creating a folder, inviting and publishing need a subscription or a running trial (as sync writes and share
  links). Rotation, removal, revoking and stopping never need one.
- Members: controlled by `SHARED_FOLDERS_MEMBER_ACCESS` (`free` | `subscription`). Recommended and default: `free` —
  any signed-in Gistsmith account may accept and read. `subscription`: accepting and reading need a subscription or a
  running trial (a new account's trial starts with its first meeting, so an invitee would hit a paywall before seeing
  a single note). The owner decides; the switch is a wrangler var, so it can change without an app release.
- Owner access ends: members keep reading; publishing stops and the owner's app says so. 90 days after the owner was
  last seen with access (`access_seen_at`, refreshed by owner writes and by the daily check), the cleanup deletes the
  folder.

### Account deletion and cleanup

- Account deletion, in the same batch and before `users`: folders the account is a member of get `needs_rotation` and
  a new `members_version`, then its memberships, its owned folders' members, items and folders (R2 prefixes queued for
  purge) and its identity are deleted.
- Daily cleanup: expired invites, accepted invites never activated for 30 days, folders of owners without access for
  90 days.

## Apps

### Core (`Packages/AINotepadCore/Sources/AINotepadCore/SharedFolders/`)

- `SharedFolderCrypto.swift` (pure): identity, keyring, item and metadata seal/open with signatures, HPKE envelopes,
  rosters, invite proofs, previews, pins.
- `SharedFolderModel.swift` (pure): payloads (`SharedFolderMeta`, `SharedFolderItemPayload` wrapping the existing
  `SharedNotePayload`), invite links, the publish, activation and rotation plans, version pins.
- `HostedSharedFolderClient.swift`: HTTP adapter with retry and backoff like the share client.
- `SharedFolderIdentityStore` (Keychain item `sharingIdentitySeed`, this device only).

### Publishing (one publisher device per folder)

Only the folder's **publisher** device uploads and deletes items (the device that shared the folder; another owner
device can take over with "Publish from this device", and takes over by itself when the publisher was not seen for 3
days). This removes every multi-device race (two devices flapping an item while sync converges, ids that differ by a
`-2` suffix on another device). The publisher matches its local folder by the name in the metadata:

- Upload: real meetings (never the sample meeting) in the folder with a note, whose content tag differs from the remote
  one.
- Delete: only items this device published (local ledger) whose meeting left the folder or was deleted.
- When the local folder does not exist at all (removed or not yet synced), the pass does nothing. Removing a shared
  folder in the app first asks inline to stop sharing.
- Other owner devices still activate members and rotate; with sync on, meetings recorded on them reach the publisher
  through sync.

### Reading (member devices)

The folder list returns `items_rev`; a folder's item index is fetched only when it changed, then changed items (by tag)
are downloaded, signature-checked, opened and cached in the account's data folder (`SharedFolders/<folderId>.json`, the
same protection as the user's own meetings) for offline reading. The cache of a folder is deleted only when a
successful list (with `available: true`) no longer has it. Shared notes stay out of the user's own library, search,
Ask, MCP, Spotlight, statistics and tasks in v1.

### Ask, search and the AI assistant

- The owner's Ask is unchanged: its folder scope (`AskScope.folder(name:)`) works on the owner's own meetings, shared
  or not. Sharing a folder never changes what the owner's Ask, MCP connector or assistant copy sees.
- A member's Ask, search, MCP connector and AI assistant copy never see shared notes in v1: the notes are not meetings
  in the member's library (they live in the shared-folder cache) and the scope picker does not offer shared folders.
  Above all, a shared note must never enter the member's assistant copy (`server/src/assistant/`), which the server
  can read: that would hand the owner's end-to-end encrypted note to the server through the member. "Ask about a
  shared folder" is listed for later and, when it comes, runs only with on-device or per-request context, never the
  stored assistant copy.

### UI (Mac full inline help, iPhone short inline; no pop-ups on Mac)

- Shared views in `AINotepadUI`: `SharedFolderPanel` (owner: transcripts toggle with a note that it shares what every
  participant said, invite field, "Create invite link", members and invites with state and Remove, publisher device,
  "Stop sharing" with an inline confirmation that says what members keep), `SharedFoldersList`, `SharedFolderNotes`,
  `SharedNoteView` (read-only note), `JoinSharedFolderView` (paste link, preview, display name, Join; waiting state
  "Waiting for Ayşe's Gistsmith to confirm — usually the next time Ayşe opens the app").
- Mac: the folder page header gets a Share button and the folder menu "Share folder…", both opening the panel inline;
  shared folders carry a people badge in the sidebar and in "Move to folder" menus (the warning that the note will be
  shared). The sidebar gets "Shared with me" once there is a membership; "Join a shared folder" is in the library's
  folder section and the account menu.
- iPhone: the library's folder actions get "Share folder" (sheet with the panel; the share sheet sends the link); the
  library gets "Shared with me" and "Join a shared folder"; the app opens `gistsmith://join#…` links.
- Copy: "End-to-end encrypted: not even Gistsmith can read these notes."

## Later (v1.1+), deliberately cut

Universal links (needs the Associated Domains capability on both App IDs: an owner change in the developer portal),
push to owner devices for faster activation, a multi-use team link, "copy task to my tasks", shared notes in Ask and
search, comments and task assignment, a safety-number UI (when it comes, at least 60 digits).

## Rollout

1. Merge with `SHARED_FOLDERS_POLICY=off` in production: apps hide everything (the server says unavailable); the `/j`
   page ships now so no link can ever 404.
2. Owner test on a local server with two accounts (Mac + iPhone).
3. Turn on in production by a PR that flips the var.

## Test plan

- Core unit tests (pure): seal/open round trips; every tamper case (wrong folder, item, epoch, signature, swapped owner
  key, swapped member key, wrong invite secret, member-forged note); HPKE envelope bound to member and epoch;
  deterministic identity; roster verification and version pins; publish, activation and rotation plans; invite links;
  server parity of limits and formats.
- Server tests (`server/test/sharedFolders.test.ts`): flag off; scoping (stranger 404, member cannot write, removed
  member loses access at once); limits; invite single use, expiry and idempotent retries; roster compare-and-set and
  stale epochs; `needs_rotation` blocks uploads; account deletion of owner and member; cleanup; subscription checks.
- Hosted e2e (`HostedSharedFolderE2ETests`, gated by `AINOTEPAD_HOSTED_E2E`): two accounts on the local server —
  create, invite, accept, activate, member reads, removal with rotation, removed member denied and unable to open the
  newer epoch, stop sharing.
- Visual QA: Mac and iPhone screens with demo data.

## Owner decisions

1. **Members free with any account** (`SHARED_FOLDERS_MEMBER_ACCESS=free`, recommended: the invitee meets the product
   through real team notes, which is the point of growth step 4; reading costs only R2 Class B reads inside the free
   tier, ~10 KB per note; the owner already pays) vs. `subscription`.
2. **Invite link through the share sheet** (recommended: the server keeps no e-mail and sends none) vs. server-side
   e-mail lookup and sending (needs storing addresses again and an e-mail provider).
3. **Automatic activation** (recommended by the product review; the security review preferred owner approval — see
   below) vs. owner approval of each acceptance.
4. Universal links for `gistsmith.com/j` (Associated Domains capability on both App IDs).
5. Turning `SHARED_FOLDERS_POLICY` on in production.

## Review

Three independent reviewers read the first draft (spec only).

### Security / cryptography (red team)

| Finding | Resolution |
|---|---|
| Critical: invite secrets and labels were sealed with the folder key, which members hold: a member (or a removed one with a malicious server) could read labels, take pending invites and forge acceptances that owner devices would auto-activate | Fixed: sealed with an owner-private key derived from the owner's seed; members never get it |
| Critical: rotation wrapped keys to the member list the server reported; a malicious server could add its own key | Fixed: owner-signed, versioned roster; keys are wrapped only to roster members; devices refuse older roster versions |
| Important: removal and `needs_rotation` relied on an honest server | Fixed for removal (one signed rotation request); version pins on every device; remaining window documented as a known limit |
| Important: leaving did not trigger rotation | Fixed: leaving and member account deletion set `needs_rotation` |
| Important: auto-activation lets whoever holds the link join; `/j` JavaScript could read the fragment | Partly accepted: activation stays automatic (product decision 3, owner may override); the owner sees the chosen name and removes in one tap; `/j` reads the fragment only to hand it to the app, with a strict CSP; the trust in `/j` equals the existing `/s` page and is documented; universal links listed for later |
| Important: 12-digit safety code is brute-forceable | Safety code dropped from v1 (also the product review's advice); at least 60 digits when added |
| Important: upload vs. rotation race | Fixed: guards inside the write statement |
| Important: keyring rollback | Fixed: devices pin the highest epoch and roster version |
| Important: storage DoS (8 owners fill 1.5 GB) | Fixed: R2 with sync's budget, 100 MB per owner |
| Minor: per-item rollback, size padding | Accepted as known limits (rollback) / not done (padding; sizes stated) |
| Minor: server may claim "no identity" to split it | Fails safe (no disclosure); a device never replaces a registered identity |
| Minor: recovery code now also protects the identity; seed in Keychain on sign-out; seed loss path | Documented; the seed is an account Keychain item; "Reset shared folders" added |
| Agreed: HPKE base mode + signature, encrypt-then-sign items, not deriving from the sync key, invite proofs, sealed pins, CAS rotation, 404 for strangers, no e-mail | — |

Dissent kept: the red team prefers owner approval by default (decision 3). Recorded for the owner.

### Distributed systems / sync

| Finding | Resolution |
|---|---|
| Critical: item ids from `record.id` differ across owner devices (`-2` suffix) | Fixed by design: one publisher device per folder; a takeover may duplicate an item only in that rare collision |
| Critical: deletes and re-uploads flap between owner devices; removing or renaming the local folder wipes all items | Fixed: one publisher; it deletes only items it published; no pass when the local folder is missing; removing a shared folder asks to stop sharing |
| Important: activation and rotation collide in D1 batches | Fixed: `members_version` + epoch compare-and-set first, every other statement guarded |
| Important: `needs_rotation` gaps (leave, in-statement guard, subscription for rotation, deletion order) | Fixed as proposed |
| Important: retries not idempotent | Fixed: create, invite, accept, item delete and roster changes are idempotent |
| Important: counters drift | Fixed: limits checked with `COUNT`/`SUM` inside the insert |
| Important: D1 blobs | Fixed: R2 |
| Important: polling cost | Fixed: `items_rev` per folder in the folder list |
| Minor: identity races, sealed seed after a sync reset, seed loss | Fixed: first registration wins, never auto-create over a registered identity, reset path |
| Minor: cache deletion, epoch pins, never-activated invites, `access_seen_at` | Fixed as proposed |
| Agreed: identity not from the sync key, signed items, forward-only rotation, HMAC ids, additive migration | — |

### Product / UX

| Finding | Resolution |
|---|---|
| Critical: the link opens Safari, not the app (no universal links) | Custom URL scheme `gistsmith://join` on both hosted apps, `/j` "Open in Gistsmith" button, pasteboard offer on the join screen; universal links listed for later (owner decision 4) |
| Critical: invisible wait between accept and activation | Honest waiting state; owner devices check every 5 minutes on Mac and on every foreground; push deferred to v1.1 |
| Important: share sheet instead of `mailto:`, prefilled subject, multi-use team link | Share sheet with subject on both; team link deferred to v1.1 |
| Important: auto-activation | Kept (agrees) |
| Important: scope of auto-sharing | People badge on shared folders and in "Move to folder" menus; the panel says how many notes are shared |
| Important: members need a next step (copy tasks, Ask) | Deferred to v1.1 (needs a standalone task model) |
| Important: lapsed owner banner, 90-day notice | Owner's app says publishing is paused; members' banner deferred (would reveal the owner's subscription state) |
| Important: transcript copy, state texts, removal/stop honesty | Done as proposed |
| Minor: discoverability, safety code, E2E copy, naming, limits warning | Done, except the 1,000-note warning (the panel shows the count) |
