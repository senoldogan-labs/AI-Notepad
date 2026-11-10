---
name: release-gistsmith
description: Release Gistsmith (the hosted edition) for Mac and iPhone - version bump PR with user-facing release notes, notarized DMG and Sparkle appcast via scripts/release-gistsmith.sh, GitHub release in senoldogann/gistsmith-releases, post-release checks, and the iPhone archive uploaded to TestFlight. Use when the owner asks to ship, release or publish a new Gistsmith version or to upload an iPhone build. Not for the AI-Notepad developer edition (scripts/release.sh).
---

# Release Gistsmith (Mac + iPhone)

Rule: release only after verification (tests, e2e, visual check) **and the owner's explicit go**. CI must be green on
the exact commit you release. Stop at the first failing step and report it; never retry past a red check.

Script details (one-time notary/Sparkle setup, what each check means) live in the headers of
`scripts/release-gistsmith.sh` and `scripts/release-common.sh`; package pinning lives in AGENTS.md ("Paket sabitleri").

## 1. Version bump PR

1. In a fresh worktree from `origin/main` (see the `pr-ci-merge` skill), bump **every** target in `project.yml` (6×
   `MARKETING_VERSION`, 6× `CURRENT_PROJECT_VERSION`: the Apple Watch app and its widgets must match the iPhone app or
   App Store Connect rejects the upload). The build number must be higher than any build already in the appcast or on
   TestFlight.
   ```bash
   sed -i '' -E 's/MARKETING_VERSION: "<old>"/MARKETING_VERSION: "<new>"/; s/CURRENT_PROJECT_VERSION: "<oldbuild>"/CURRENT_PROJECT_VERSION: "<newbuild>"/' project.yml
   grep -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' project.yml | sort | uniq -c   # exactly two distinct lines, 6 each
   ```
2. Write `docs/release-notes/gistsmith-<new>.md`, matching the tone of the latest existing ones: one summary sentence
   ("Gistsmith <new> …"), `## New` and/or `## Improvements` with **bold lead** + one or two plain sentences per item,
   last line `Requires macOS 15 or later on Apple silicon.` Only user benefit: no PR numbers, internal motives,
   telemetry details, provider/vendor names or code terms.
   Add `"<new>": "<YYYY-MM-DD>"` (the planned release day, UTC) at the top of `docs/release-notes/release-dates.json`:
   the site's /changelog is built from the notes and that file, and the web build fails when a note has no date.
3. Commit `chore: release Gistsmith <new> (build <newbuild>)`, open the PR, wait for `test-and-build`, `server`, `web`,
   squash-merge, then wait for the **CI run on the merge commit on main** to finish green:
   ```bash
   SHA=$(gh pr view <pr> --json mergeCommit --jq .mergeCommit.oid)
   gh run list --branch main --workflow CI --json headSha,status,conclusion,databaseId --jq ".[] | select(.headSha==\"$SHA\")"
   ```
   Stop if it is not `completed` / `success`.

## 2. Clean release worktree at the merge commit

The main checkout may hold another session's uncommitted work, and the script refuses a dirty tree.

```bash
MAIN=$(git worktree list --porcelain | awk 'NR==1 {print $2}')     # the main checkout
git -C "$MAIN" fetch origin
git -C "$MAIN" worktree add --detach "$MAIN/.claude/worktrees/release-<new>" "$SHA"
cd "$MAIN/.claude/worktrees/release-<new>"
cp "$MAIN/Config/Local.xcconfig" Config/                            # DEVELOPMENT_TEAM (untracked)
ditto "$MAIN/release-archive-gistsmith" release-archive-gistsmith   # local appcast history (untracked)
xcodegen --version                                                  # must print 2.45.3 (same as CI)
curl -sSfL https://github.com/senoldogann/gistsmith-releases/releases/latest/download/appcast.xml \
  | diff -q - release-archive-gistsmith/appcast.xml                 # must be identical; if not, stop and ask
```

## 3. Build, notarize, write the appcast

```bash
set -o pipefail; scripts/release-gistsmith.sh docs/release-notes/gistsmith-<new>.md 2>&1 | tee .build/release-<new>.log
```

Takes 10–30 min (run it in the background). Check the log for, in order:

- `Paket sabitleri tutarlı: … paket (Config/Package.resolved).`
- `status: Accepted` twice (the app, then the DMG). `Invalid` → read `xcrun notarytool log <id> --keychain-profile AINotepad`, stop.
- `appcast güncellendi: release-archive-gistsmith/appcast.xml`
- `Yayınlamak için:` followed by one `gh release create v<new> … --repo senoldogann/gistsmith-releases …` line.

Stop on any other exit (dirty tree, build/version already in appcast, Sparkle key mismatch, pins changed).
`Packages/AINotepadCore/Package.resolved` rewritten by an earlier local build makes the tree dirty: `git checkout --`
it (never in the release commit).

## 4. Publish (owner's go required)

Show the owner the version, build, notes and the printed command. Only after an explicit go, run that exact printed
command from the release worktree (its paths are relative to it).

## 5. Verify the published release

```bash
curl -sSfL https://github.com/senoldogann/gistsmith-releases/releases/latest/download/appcast.xml \
  | grep -oE '<sparkle:(version|shortVersionString)>[^<]+' | head -2        # <newbuild> and <new>
curl -sSf https://api.gistsmith.com/v1/download/mac/version                 # {"version":"<new>"}
curl -sSIL https://github.com/senoldogann/gistsmith-releases/releases/latest/download/Gistsmith.dmg \
  | grep -i '^content-length' | tail -1
stat -f %z .build/release-gistsmith/Gistsmith.dmg                           # same byte count as above
```

## 6. Sync the appcast history back

The next release starts from the main checkout's copy, so mirror the worktree's archive (new DMG, notes, appcast,
`old_updates/`) back:

```bash
rsync -a --delete release-archive-gistsmith/ "$MAIN/release-archive-gistsmith/"
diff -rq release-archive-gistsmith "$MAIN/release-archive-gistsmith" && echo synced
```

## 7. iPhone: archive and upload to TestFlight (owner's go required)

Same worktree and commit. Commands as in AGENTS.md ("Paket sabitleri"). AGENTS.md archives with
`CALL_CAPTURE_EXPERIMENT=YES` (the on-iPhone call capture experiment); confirm with the owner that this build should
carry it before archiving. The archive carries the Apple Watch app (`Gistsmith.app/Watch/AINotepadWatch.app` with its
widget extension); `-allowProvisioningUpdates` registers its App IDs (`…hosted.watchkitapp`, `…watchkitapp.Widgets`) and
the App Group `group.com.senoldogan.AINotepad.hosted.watch` on the first archive. Check that the export lists the Watch
app before uploading.

```bash
scripts/check-package-pins.sh && xcodegen generate
mkdir -p AINotepad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Config/Package.resolved AINotepad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Release -destination 'generic/platform=iOS' \
  -archivePath .build/ios-release/Gistsmith-<newbuild>.xcarchive -allowProvisioningUpdates \
  -onlyUsePackageVersionsFromResolvedFile CALL_CAPTURE_EXPERIMENT=YES archive
cmp Config/Package.resolved AINotepad.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved   # silent = pins unchanged
```

Export uploads to App Store Connect (TestFlight). `export.plist` is local (`.build/` is untracked); copy it from the
main checkout:

```bash
cp "$MAIN/.build/ios-release/export.plist" .build/ios-release/
xcodebuild -exportArchive -archivePath .build/ios-release/Gistsmith-<newbuild>.xcarchive \
  -exportPath .build/ios-release/export-<newbuild> -exportOptionsPlist .build/ios-release/export.plist -allowProvisioningUpdates
```

If it is missing, recreate it: `method` `app-store-connect`, `destination` `upload`, `teamID` = `DEVELOPMENT_TEAM` from
`Config/Local.xcconfig`, `signingStyle` `automatic`, `manageAppVersionAndBuildNumber` false, `uploadSymbols` true.

Success is `Upload succeeded` in the output. Never pipe `-exportArchive` into `head` or similar: SIGPIPE can kill the
upload mid-way. Keep the archive (dSYMs): `ditto .build/ios-release/Gistsmith-<newbuild>.xcarchive "$MAIN/.build/ios-release/Gistsmith-<newbuild>.xcarchive"`.

## 8. Clean up

```bash
cd "$MAIN" && git worktree remove --force .claude/worktrees/release-<new>
```

Report: version, build, merge SHA, notarization IDs, the verification outputs from step 5 and the upload result.
