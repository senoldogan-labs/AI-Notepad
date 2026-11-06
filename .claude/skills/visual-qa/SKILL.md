---
name: visual-qa
description: Visually check app UI changes before shipping - demo-mode Mac screenshots with scripts/make-screenshots.sh, offscreen light/dark renders of a single AINotepadUI SwiftUI view through a temporary test, and iPhone Simulator checks with the Debug launch arguments. Use after changing any Mac or iPhone screen, theme, colour or layout, or when asked for screenshots of the app.
---

# Visual QA

Never quit or relaunch the owner's running AI-Notepad/Gistsmith (it may be recording). The methods below run separate
copies and never touch the owner's data.

## 1. Mac screens in demo mode (whole windows)

```bash
scripts/make-screenshots.sh <scene> [<scene> …]      # output: .build/screenshots/<scene>.png
```

Scenes (from the script; they mirror `DemoScene` in `App/DemoData.swift`):

- Site scenes: `ana not sor canli` (also the default when no scene is given).
- Check-only scenes: `abone deneme-bitiyor deneme-bitti guncelleme ayarlar kisiler sirketler gorevler toplantilar ekranlar`.
- Empty first-run scenes: `toplantilar-bos gorevler-bos kisiler-bos sor-bos`.
- Sign-in gate and onboarding: `giris kurulum kurulum-takvim kurulum-takvim-bagli kurulum-izinler kurulum-ornek-giris
  kurulum-ornek kurulum-not kurulum-hazir`.

Dark theme: `GISTSMITH_THEME=dark scripts/make-screenshots.sh <scene> …` (same output paths; copy the light PNGs away
first).

Requires `cwebp` (`brew install webp`) and a Retina display. The script builds the Gistsmith Debug app and launches a
re-signed copy with its own bundle id and a temporary home folder.

**Gotcha:** the site scenes also overwrite `web/src/assets/screenshots/{home,note,ask,live}.webp`. Unless the website
is meant to change, revert them afterwards:

```bash
git checkout -- web/src/assets/screenshots/
git status --short web/        # must be empty
```

Look at every PNG (Read tool) in the themes and states the change touches before calling it done.

## 2. One SwiftUI view offscreen, light and dark

Only for views in `Packages/AINotepadCore/Sources/AINotepadUI` (views in `App/` or `iOS/` are not importable from
package tests; use section 1 or 3). Add a **temporary, uncommitted** test file, e.g.
`Packages/AINotepadCore/Tests/AINotepadUITests/TmpVisualCheckTests.swift` (pattern taken from
`ScreenSnapshotRowTests.swift`):

```swift
#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import AINotepadUI

@Suite @MainActor struct TmpVisualCheckTests {
    @Test func render() async throws {
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let view = MyView(/* sample data */).frame(width: 480).padding(10).background(Theme.background)
                .environment(\.colorScheme, scheme)
            let host: NSHostingView = NSHostingView(rootView: view)
            let window: NSWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 900),
                                            styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap: NSBitmapImageRep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png: Data = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/visual-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
#endif
```

```bash
swift test --package-path Packages/AINotepadCore --filter TmpVisualCheckTests
```

Read both PNGs, then **delete the file** and confirm `git status --short Packages/` shows no test file left.
Both `window.appearance` and `.environment(\.colorScheme, …)` are needed: `Theme` colours resolve from the window's
appearance, SwiftUI's own styles from the environment.

**Gotcha:** macOS draws an unfocused `TextField(…, prompt:)` placeholder in the text colour, so it looks like real
input. Use an empty-text overlay placeholder in `Theme.muted` instead of `prompt:`.

## 3. iPhone in the Simulator

Build (AGENTS.md command), then install and launch the Debug app with demo arguments (Debug only; no sign-in):

```bash
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Debug \
  -derivedDataPath .build/xcode-ios -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet
xcrun simctl install booted .build/xcode-ios/Build/Products/Debug-iphonesimulator/Gistsmith.app
xcrun simctl launch booted com.senoldogan.AINotepad.hosted --tanitim [<more arguments>]
```

If the harness offers its own device tools (for example a Device panel), launch and screenshot through those with
the same arguments instead of `simctl`.

Arguments (listed in AGENTS.md, defined in `iOS/`): `--tanitim` fake trial account; `--abone` with it: App Store
subscriber with invite code; `--paywall` subscription screen; `--sohbet <uuid>` a saved Ask chat; `--ornek-kayit`
sample live recording, plus `--ornek-bitir` (finishing layer), `--ornek-duraklat` (paused), `--ornek-sinir` (offline,
shortened by the monthly limit); `--ornek-takvim` sample upcoming meetings; there is no tab bar: `--sekme sor|gorevler|ayarlar` and `--ekran
kitaplik|arama|kisiler|profil` open that screen over the home (`--ekran klasorler` the library sheet), `--toplanti <id>` a
meeting; `--karsilama` first-run onboarding (with
`--karsilama-adim <step>` and `--karsilama-ornek <canli|not>`).

StoreKit purchases cannot be tested this way (`xcodebuild`/`simctl` launches use the sandbox, see AGENTS.md).
Check light and dark (`xcrun simctl ui booted appearance dark|light`) and every state the change touches.
