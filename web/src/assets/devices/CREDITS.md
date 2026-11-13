# Device pictures: sources and licence

`mac-light.webp`, `mac-dark.webp`, `iphone.webp` and `watch.webp` are Apple's official product bezels with Gistsmith's
real screens inside, made by `web/scripts/make-device-mockups.ts`. They are finished pictures of the app (mock-ups); the
bezel PNGs themselves are not in this repository and must not be added to it.

## Bezels

From Apple Design Resources → Product Bezels (https://developer.apple.com/design/resources/), downloaded 2026-11-11:

| Picture | Bezel DMG | PNG used |
|---|---|---|
| `mac-*.webp` | `Bezel-MacBook-Pro-M5.dmg` | `PNG/MacBook Pro M5 14-inch Space Black.png` |
| `iphone.webp` | `Bezel-iPhone-18.dmg` | `PNG/iPhone 18 Pro/iPhone 18 Pro - Black - Portrait.png` |
| `watch.webp` | `Bezel-Apple-Watch-Series-11-2025.dmg` | `PNG/Sport Band/Apple Watch S11 - 46mm - Aluminum Jet Black + Sport Band Black.png` |

Licence: each DMG carries the "Apple Inc. License Agreement for Apple Design Resources" (also in the volume as
`Apple Design Resources License.rtf`). It allows the resources only for mock-ups of user interfaces of software that runs
on Apple's platforms, including "the right to show the Apple Design Resources in screen shots, images or other depictions
of such Mock-Ups" (section 2A). The template content may not be extracted, copied, modified, distributed or repackaged as
content or clip art (2C, 3), so only the finished pictures ship; anyone we give them to (the press page says so) may use
them only as pictures of Gistsmith. The design resources page links the App Store Marketing Guidelines
(https://developer.apple.com/app-store/marketing/guidelines/#section-products) for product bezels in marketing, and the
pictures follow them: the latest devices, used as is (no added shadow, reflection or tilt, nothing covering them), the
app's real screens, no Apple Home Screen, and the true relative scale when the three are shown in one row (screens wider
than 640 px). On phones the two rules conflict: at the Mac's scale the iPhone and Watch would be ~75 px and ~45 px
wide, under the 200 px minimum device size. There the Mac and the iPhone + Watch pair are two rows, each at its own
scale (the iPhone and Watch true to each other).

## Screens

- Mac: `../screenshots/note.webp` and `note-dark.webp` (scripts/make-screenshots.sh) on a desktop whose wallpaper is
  `../photos/dune-sunset.jpg` (Unsplash License, see `../photos/CREDITS.md`); the menu bar is hidden, so no system UI is drawn.
- iPhone: `../screenshots/iphone-home.webp` (scripts/make-iphone-shots.ts) without its drawn frame and island.
- Apple Watch: `../screenshots/watch-recording.png`, the watch app's own screen (WatchScreensUITests,
  `TEST_RUNNER_WATCH_SHOTS_DIR`).

To remake them, download the three DMGs, accept the licence, and run from `web/`:
`node scripts/make-device-mockups.ts mac=<png> iphone=<png> watch=<png>`.
