---
name: hosted-e2e
description: Run the hosted (Gistsmith) end-to-end tests locally - the Swift HostedE2E, HostedSyncE2E and HostedLongMeetingE2E suites against a local wrangler dev server with fake secrets and the free fake Anthropic/ElevenLabs upstreams. Use after changing server/ endpoints, the app's hosted client (HostedAPI, sync, long-meeting finishing) or anything both sides share, and before releasing.
---

# Hosted end-to-end tests (local)

The one-line command is in AGENTS.md; `server/README.md` ("Yerel geliştirme") and the header of
`server/scripts/fake-upstreams.ts` describe the server side. No paid or third-party call is made: the server only
accepts the stub URL in development and on a loopback address (`server/src/upstreamStub.ts`).

## 1. Fake secrets (never the real ones)

Never open, print, copy or overwrite an existing `server/.dev.vars`: it may hold real keys. Run from a worktree that
has none (a fresh `git worktree` never does).

```bash
cd server
test -e .dev.vars && { echo ".dev.vars exists; stop and ask the owner"; exit 1; }
npm ci
sed -n '/const fakeSecrets/,/^};/p' vitest.config.ts | sed -nE 's/^  ([A-Z_]+): "(.*)",$/\1="\2"/p' > .dev.vars
wc -l < .dev.vars          # 10 (the fake test secrets of vitest.config.ts, so they stay in sync)
npm run migrate:local      # both local D1s (production schema + EU assistant) under server/.wrangler/ (untracked); rerun after new migrations
```

## 2. Start the fake upstreams and the local server

Two long-running processes (run them in the background; Node 22.18+ runs the `.ts` script directly):

```bash
node scripts/fake-upstreams.ts 8798
npx wrangler dev --port 8797 --var UPSTREAM_STUB_URL:http://127.0.0.1:8798
```

Wait until the server answers (`200`):

```bash
until curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8797/v1/health | grep -q 200; do sleep 1; done
```

## 3. Run the suites

From the repository root:

```bash
AINOTEPAD_HOSTED_E2E=1 AINOTEPAD_HOSTED_UPSTREAM_STUB=1 AINOTEPAD_HOSTED_BASE=http://127.0.0.1:8797 \
  swift test --no-parallel --package-path Packages/AINotepadCore --filter 'HostedE2E|HostedSyncE2E|HostedLongMeetingE2E'
```

`--no-parallel` is required: the local D1 (SQLite) returns `SQLITE_BUSY` under concurrent writes and tests fail
randomly. `HostedLongMeetingE2E` runs only with `AINOTEPAD_HOSTED_UPSTREAM_STUB=1`. Local limits come from the
development `vars` in `server/wrangler.jsonc`.

A failure is real until proven otherwise: read the wrangler output for the request that failed before rerunning.

## 4. Stop both servers

Always, also after a failure. `wrangler dev` leaves a `workerd` child listening, so stop by port:

```bash
kill $(lsof -ti tcp:8797 -sTCP:LISTEN) $(lsof -ti tcp:8798 -sTCP:LISTEN)
lsof -nP -iTCP:8797 -iTCP:8798 -sTCP:LISTEN          # no output
```

Leave `server/.dev.vars` and `server/.wrangler/` in place (both untracked); never commit them.
