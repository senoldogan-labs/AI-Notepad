import Foundation
import XCTest

/// One screen of a common task, opened straight from the Debug launch arguments (AGENTS.md, `iOS/AINotepadiOSApp.swift`
/// `launchPath`). `scrolls` is how many screen-sized swipes the audit follows down a long page.
struct AuditScene {
    let name: String
    let arguments: [String]
    let scrolls: Int
}

/// One finding of `performAccessibilityAudit`, written to the report.
struct AuditFinding: Codable, Hashable {
    let scene: String
    /// The scrolled page (0: as opened); the page's screenshot is `<scene>-<page>.png` in the report folder.
    let page: Int
    let type: String
    let element: String
    let summary: String
}

/// Runs Xcode's accessibility audit (the Accessibility Inspector audit) on every screen of Gistsmith's common tasks in
/// the iPhone Simulator: sign in, onboarding, home, recording (live, paused, finishing), the meeting note with Ask,
/// tasks, Ask, Settings with the language page, the paywall, import and the account page.
///
/// It fails on the audit types VoiceOver and Voice Control depend on (element description, element detection, traits).
/// Contrast, hit-region, Dynamic Type and clipped text findings are written to the report but do not fail the run: the
/// contrast audit samples rendered pixels, so it also flags text that only looks faint because it sits under the
/// navigation bar's or the bottom bar's fade, under an open sheet, or is anti-aliased; measure a flagged element on the
/// page's screenshot before treating it as a real failure. Issues on the system keyboard (its empty prediction slots)
/// are not the app's and are skipped.
///
/// Inputs (xcodebuild passes `TEST_RUNNER_<name>` to the runner as `<name>`):
/// - `A11Y_MEETING`: the id of a seeded meeting (`scripts/appstore-screenshots/seeder`, copied into the `--tanitim`
///   account's data folder); without it the meeting scenes are skipped.
/// - `A11Y_CONVERSATION`: the id of a seeded Ask conversation (same seeder); optional.
/// - `A11Y_REPORT_DIR`: folder for `audit.json`, every scene's accessibility tree (`<scene>.txt`) and its findings
///   (`<scene>.findings.txt`); optional.
/// - `A11Y_SCENES`: comma-separated scene names to run (default: all).
/// - `A11Y_THEME`: `dark` runs every scene in the dark theme (default: light).
///
/// Command (seed with `swift run --package-path scripts/appstore-screenshots/seeder AppStoreSeeder team <folder>`, copy
/// its `Sessions` and `AskHistory` into the Simulator app's `Library/Application Support/AINotepad Hosted
/// Debug/Accounts/840e998c43c314a273d650cdfc0a3559/`; about 25 minutes):
///
///     TEST_RUNNER_A11Y_MEETING=<id> TEST_RUNNER_A11Y_REPORT_DIR=<folder> xcodebuild -project AINotepad.xcodeproj \
///       -scheme AINotepadiOS -derivedDataPath .build/xcode-ios -destination 'platform=iOS Simulator,name=iPhone 17' \
///       test -only-testing:AINotepadiOSUITests
final class AccessibilityAuditUITests: XCTestCase {
    private static let gatedTypes: XCUIAccessibilityAuditType = [.sufficientElementDescription, .elementDetection, .trait]
    private static let reportedTypes: XCUIAccessibilityAuditType = [.contrast, .hitRegion, .dynamicType, .textClipped]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor func testCommonTaskScreens() throws {
        let environment: [String: String] = ProcessInfo.processInfo.environment
        let theme: [String] = ["-appearance.theme", environment["A11Y_THEME"] == "dark" ? "dark" : "light"]
        let language: [String] = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + theme
        let common: [String] = language + ["-onboardingCompleted", "YES"]
        let demo: [String] = ["--tanitim"] + common
        // Onboarding: `--karsilama` clears the stored flag, which an argument would override.
        let onboarding: [String] = ["--tanitim", "--karsilama"] + language
        var scenes: [AuditScene] = [
            AuditScene(name: "sign-in", arguments: common, scrolls: 0),
            AuditScene(name: "onboarding-welcome", arguments: onboarding, scrolls: 0),
            AuditScene(name: "onboarding-calendar", arguments: onboarding + ["--karsilama-adim", "calendar"], scrolls: 0),
            AuditScene(name: "onboarding-permissions", arguments: onboarding + ["--karsilama-adim", "permissions"], scrolls: 0),
            AuditScene(name: "onboarding-ready", arguments: onboarding + ["--karsilama-adim", "ready"], scrolls: 0),
            AuditScene(name: "home", arguments: demo + ["--abone", "--ornek-takvim"], scrolls: 2),
            AuditScene(name: "home-trial-offer", arguments: demo + ["--teklif", "deneme-bitiyor"], scrolls: 0),
            AuditScene(name: "recording-live", arguments: demo + ["--ornek-kayit"], scrolls: 1),
            AuditScene(name: "recording-paused", arguments: demo + ["--ornek-kayit", "--ornek-duraklat"], scrolls: 0),
            AuditScene(name: "recording-finishing", arguments: demo + ["--ornek-kayit", "--ornek-bitir"], scrolls: 0),
            AuditScene(name: "tasks", arguments: demo + ["--sekme", "gorevler"], scrolls: 1),
            AuditScene(name: "ask", arguments: demo + ["--sekme", "sor"], scrolls: 0),
            AuditScene(name: "settings", arguments: demo + ["--sekme", "ayarlar"], scrolls: 3),
            AuditScene(name: "settings-recording-languages", arguments: demo + ["--sekme", "ayarlar", "--ayar", "kayit"], scrolls: 3),
            AuditScene(name: "settings-notes", arguments: demo + ["--sekme", "ayarlar", "--ayar", "notlar"], scrolls: 2),
            AuditScene(name: "account", arguments: demo + ["--ekran", "hesap"], scrolls: 1),
            AuditScene(name: "paywall", arguments: demo + ["--paywall"], scrolls: 2),
            AuditScene(name: "import-phone-call", arguments: demo + ["--ekran", "telefon"], scrolls: 1),
            AuditScene(name: "library", arguments: demo + ["--ekran", "kitaplik"], scrolls: 1),
            AuditScene(name: "search", arguments: demo + ["--ekran", "arama"], scrolls: 0),
        ]
        if let meeting = environment["A11Y_MEETING"] {
            scenes += [
                AuditScene(name: "meeting-note", arguments: demo + ["--toplanti", meeting], scrolls: 4),
                AuditScene(name: "meeting-ask", arguments: demo + ["--toplanti", meeting, "--sor-ornek"], scrolls: 0),
                AuditScene(name: "meeting-transcript", arguments: demo + ["--toplanti", meeting, "--cekmece"], scrolls: 1),
            ]
        }
        if let conversation = environment["A11Y_CONVERSATION"] {
            scenes.append(AuditScene(name: "ask-conversation", arguments: demo + ["--sohbet", conversation], scrolls: 1))
        }
        if let only = environment["A11Y_SCENES"] {
            let names: Set<String> = Set(only.split(separator: ",").map(String.init))
            scenes = scenes.filter { names.contains($0.name) }
        }
        let reportDirectory: URL? = environment["A11Y_REPORT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        if let reportDirectory {
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        }

        var findings: [AuditFinding] = []
        for scene in scenes {
            findings += try audit(scene: scene, reportDirectory: reportDirectory)
        }
        let unique: [AuditFinding] = Array(Set(findings)).sorted { ($0.scene, $0.type, $0.element) < ($1.scene, $1.type, $1.element) }
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report: Data = try encoder.encode(unique)
        let attachment: XCTAttachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
        attachment.name = "audit.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let reportDirectory {
            try report.write(to: reportDirectory.appending(path: "audit.json"))
        }
        let gatedNames: Set<String> = Set(Self.typeNames(types: Self.gatedTypes))
        for finding in unique where gatedNames.contains(finding.type) {
            XCTFail("\(finding.scene): \(finding.type) — \(finding.element): \(finding.summary)")
        }
    }

    /// Launches the scene, audits the visible screen and each scrolled page, and saves the accessibility tree.
    @MainActor private func audit(scene: AuditScene, reportDirectory: URL?) throws -> [AuditFinding] {
        let app: XCUIApplication = XCUIApplication()
        app.launchArguments = scene.arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "\(scene.name) did not start")
        sleep(4)
        var findings: [AuditFinding] = []
        var tree: String = ""
        for page in 0...scene.scrolls {
            if page > 0 {
                app.swipeUp()
                sleep(1)
            }
            tree += "=== \(scene.name) page \(page) ===\n" + app.debugDescription + "\n"
            if let reportDirectory {
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: reportDirectory.appending(path: "\(scene.name)-\(page).png"))
            }
            let keyboard: XCUIElement = app.keyboards.firstMatch
            let keyboardTop: CGFloat? = keyboard.exists ? keyboard.frame.minY - 44 : nil
            // Two passes: the gated types are quick; Dynamic Type re-renders the page at every size and can run out of
            // time on a long page, which then fails only that report-only pass.
            for types in [Self.gatedTypes, Self.reportedTypes] {
                findings += try audit(app: app, types: types, scene: scene.name, page: page, keyboardTop: keyboardTop)
            }
        }
        if let reportDirectory {
            try Data(tree.utf8).write(to: reportDirectory.appending(path: "\(scene.name).txt"))
            let lines: [String] = findings.map { "page \($0.page) \($0.type) — \($0.element): \($0.summary)" }
            try Data(Set(lines).sorted().joined(separator: "\n").utf8).write(to: reportDirectory.appending(path: "\(scene.name).findings.txt"))
        }
        app.terminate()
        return findings
    }

    /// One audit of the visible page, tried twice when it runs out of time ("Audit failed to complete in time"); still
    /// out of time, a gated pass fails the test and a report-only pass becomes an `auditTimeout` finding.
    @MainActor private func audit(app: XCUIApplication, types: XCUIAccessibilityAuditType, scene: String, page: Int, keyboardTop: CGFloat?) throws -> [AuditFinding] {
        var lastError: Error?
        for _ in 0..<2 {
            var findings: [AuditFinding] = []
            do {
                try app.performAccessibilityAudit(for: types) { issue in
                    if let keyboardTop, let element = issue.element, element.exists, element.frame.minY >= keyboardTop {
                        return true
                    }
                    // XCTest lists views hidden from VoiceOver (`accessibilityHidden`) too, and the audit now and then
                    // asks them for a description; the app marks such decoration with this identifier.
                    if let element = issue.element, element.exists, element.identifier == "decorative" {
                        return true
                    }
                    findings.append(AuditFinding(
                        scene: scene,
                        page: page,
                        type: Self.typeNames(types: issue.auditType).joined(separator: "+"),
                        element: Self.describe(element: issue.element),
                        summary: issue.compactDescription
                    ))
                    return true
                }
                return findings
            } catch {
                lastError = error
            }
        }
        let message: String = "\(scene) page \(page): \(Self.typeNames(types: types).joined(separator: "+")) audit failed twice: \(String(describing: lastError))"
        if types == Self.gatedTypes {
            XCTFail(message)
            return []
        }
        return [AuditFinding(scene: scene, page: page, type: "auditTimeout", element: "(page)", summary: message)]
    }

    /// A short, stable description of the element an issue points at.
    @MainActor private static func describe(element: XCUIElement?) -> String {
        guard let element, element.exists else {
            return "(no element)"
        }
        let frame: CGRect = element.frame
        return "\(element.elementType.rawValue) label=\"\(element.label)\" id=\"\(element.identifier)\" frame=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))"
    }

    /// Names of the audit types in a set.
    private static func typeNames(types: XCUIAccessibilityAuditType) -> [String] {
        let named: [(XCUIAccessibilityAuditType, String)] = [
            (.contrast, "contrast"), (.elementDetection, "elementDetection"), (.hitRegion, "hitRegion"),
            (.sufficientElementDescription, "sufficientElementDescription"), (.dynamicType, "dynamicType"),
            (.textClipped, "textClipped"), (.trait, "trait"),
        ]
        return named.filter { types.contains($0.0) }.map(\.1)
    }
}
