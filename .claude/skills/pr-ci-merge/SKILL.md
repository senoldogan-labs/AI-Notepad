---
name: pr-ci-merge
description: The branch → test → PR → CI → squash-merge loop for this repository - worktree from origin/main under .claude/worktrees, the required local tests and Debug builds, commit and PR conventions, the required checks (test-and-build, server, web), merging, and confirming main CI on the merge commit. Use whenever a change is ready to ship or the owner asks to open, merge or land a PR.
---

# PR, CI, merge

`main` is branch-protected: `test-and-build`, `server` and `web` (`.github/workflows/ci.yml`) are required. Never merge
or continue past a failing or pending required check: fix the cause first. Stop and report instead of merging when the
change touches secrets, auth, payments, migrations or production infrastructure, or when anything is uncertain.

## 1. Worktree from origin/main

From the main checkout (`git worktree list` shows it first):

```bash
git fetch origin
git worktree add .claude/worktrees/<name> -b <type>/<name> origin/main     # type: feat, fix, chore, perf, docs…
cd .claude/worktrees/<name>
cp ../../../Config/Local.xcconfig Config/      # only if you will sign or archive (untracked)
```

## 2. Before committing

Run both test commands and all three Debug builds from AGENTS.md:

```bash
swift test --package-path Packages/AINotepadCore
(cd Packages/AINotepadCore && xcodebuild test -scheme AINotepadCore-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet)
xcodegen generate
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadHosted -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Debug \
  -derivedDataPath .build/xcode-ios -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet
```

Also, when touched: `server/` → `cd server && npm run typecheck && npm test`; `web/` → `cd web && npm run typecheck &&
npm run build && npm test`; package versions → `scripts/check-package-pins.sh`; UI strings → the `add-ui-strings`
skill; screens → the `visual-qa` skill; server/app contract → the `hosted-e2e` skill.

Xcode builds can rewrite `Packages/AINotepadCore/Package.resolved`. Unless the change is a deliberate package update,
revert it:

```bash
git status --short
git checkout -- Packages/AINotepadCore/Package.resolved
```

## 3. Commit and PR

Conventional Commit, English, body says what and why in plain sentences, last line exactly:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

Stage explicit paths (never `.env`, `.dev.vars`, `Config/Local.xcconfig`, `release-archive*/`). Write the PR body to a
file (non-ASCII symbols can trip the shell guard inline): what changed, why, how it was checked, ending with
`🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

```bash
git push -u origin HEAD
gh pr create --base main --title "<type>: <summary>" --body-file <file>
```

## 4. Wait for checks, merge

```bash
gh pr checks <pr> --required --watch --fail-fast      # or the harness's PR watcher, if it has one
```

All three must be `pass`. On a failure: `gh run view <run-id> --log-failed`, fix, push, wait again. Then:

```bash
gh pr merge <pr> --squash --delete-branch
```

## 5. Confirm main CI on the merge commit

```bash
SHA=$(gh pr view <pr> --json mergeCommit --jq .mergeCommit.oid)
gh run list --branch main --workflow CI --json databaseId,headSha,status,conclusion --jq ".[] | select(.headSha==\"$SHA\")"
gh run watch <databaseId> --exit-status
```

A `web/` change also triggers `Deploy web` on main (publishes the site); check it the same way
(`--workflow "Deploy web"`). If main goes red, fixing it is the next task; nothing else ships on top of it.

## 6. Remove the worktree

```bash
cd <main checkout> && git worktree remove .claude/worktrees/<name>
git branch -D <type>/<name> 2>/dev/null; git fetch --prune origin
```

`git worktree remove` refuses when there are modified or untracked (not ignored) files; look at
`git -C .claude/worktrees/<name> status --short` and only use `--force` once nothing there is needed. Ignored files
(`.build/`, `server/.dev.vars`) are deleted with the worktree.
