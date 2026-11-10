import Foundation
import XCTest

/// Walks the Watch app's screens in the watchOS Simulator with the Debug sample data (`--ornek`, see
/// Watch/App/WatchDemo.swift) and a real recording on the Simulator's microphone. With `WATCH_SHOTS_DIR` set
/// (xcodebuild: `TEST_RUNNER_WATCH_SHOTS_DIR=<folder>`) every screen is saved as a PNG for the visual check.
final class WatchScreensUITests: XCTestCase {
    private var shotsDirectory: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        shotsDirectory = ProcessInfo.processInfo.environment["WATCH_SHOTS_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        if let shotsDirectory {
            try FileManager.default.createDirectory(at: shotsDirectory, withIntermediateDirectories: true)
        }
    }

    @MainActor private func shot(name: String) throws {
        let png: Data = XCUIScreen.main.screenshot().pngRepresentation
        let attachment: XCTAttachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shotsDirectory {
            try png.write(to: shotsDirectory.appending(path: name + ".png"))
        }
    }

    @MainActor private func launch(arguments: [String], language: String) -> XCUIApplication {
        let app: XCUIApplication = XCUIApplication()
        app.launchArguments = arguments + ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "tr" ? "tr_TR" : "en_US"]
        app.launch()
        return app
    }

    /// Answers a system prompt (microphone, notifications) with "Allow" when it shows (the first recording here).
    /// The prompt is drawn by the system (Carousel on watchOS), not by the app.
    @MainActor private func allowMicrophoneIfAsked(app: XCUIApplication) {
        let system: XCUIApplication = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
        for owner in [system, app] {
            for label in ["Allow", "İzin Ver", "OK", "Tamam"] {
                let button: XCUIElement = owner.buttons[label]
                if button.waitForExistence(timeout: 3) {
                    button.tap()
                    return
                }
            }
        }
    }

    @MainActor func testHomeTasksAndPhoneScreens() throws {
        for language in ["en", "tr"] {
            let home: XCUIApplication = launch(arguments: ["--ornek"], language: language)
            XCTAssertTrue(home.staticTexts["Gistsmith"].waitForExistence(timeout: 10) || home.navigationBars.firstMatch.waitForExistence(timeout: 5))
            try shot(name: "\(language)-home-1")
            // Screen-sized steps down the list (a swipe flings to the end).
            for step in 2...5 {
                let from: XCUICoordinate = home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
                from.press(forDuration: 0.05, thenDragTo: home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
                sleep(1)
                try shot(name: "\(language)-home-\(step)")
            }
            home.terminate()

            let tasks: XCUIApplication = launch(arguments: ["--ornek", "--ekran", "gorevler"], language: language)
            sleep(2)
            try shot(name: "\(language)-tasks")
            tasks.terminate()

            let phone: XCUIApplication = launch(arguments: ["--ornek", "--ekran", "iphone"], language: language)
            sleep(2)
            try shot(name: "\(language)-iphone-recording")
            phone.terminate()

            let disabled: XCUIApplication = launch(arguments: ["--ornek-kapali"], language: language)
            sleep(2)
            try shot(name: "\(language)-home-recording-off")
            disabled.swipeUp()
            sleep(1)
            try shot(name: "\(language)-home-recording-off-2")
            disabled.terminate()
        }
    }

    /// Xcode's accessibility audit (VoiceOver labels, element detection, traits; contrast, hit regions, Dynamic Type
    /// and clipped text are reported only, as in the iPhone's `AccessibilityAuditUITests`: the contrast audit samples
    /// pixels) on the Watch's screens with the sample data: home, tasks, the iPhone's recording and home with Watch
    /// recording off. The evidence behind the Watch's Accessibility Nutrition Labels.
    @MainActor func testAccessibilityAudit() throws {
        let gated: XCUIAccessibilityAuditType = [.sufficientElementDescription, .elementDetection, .trait]
        let screens: [(name: String, arguments: [String])] = [
            ("home", ["--ornek"]), ("tasks", ["--ornek", "--ekran", "gorevler"]),
            ("iphone-recording", ["--ornek", "--ekran", "iphone"]), ("home-recording-off", ["--ornek-kapali"]),
        ]
        var findings: [String] = []
        for screen in screens {
            let app: XCUIApplication = launch(arguments: screen.arguments, language: "en")
            sleep(3)
            for page in 0..<3 {
                if page > 0 {
                    app.swipeUp()
                    sleep(1)
                }
                try app.performAccessibilityAudit(for: gated.union([.contrast, .hitRegion, .dynamicType, .textClipped])) { issue in
                    let element: String = issue.element.map { "\($0.elementType.rawValue) \"\($0.label)\"" } ?? "(no element)"
                    let line: String = "\(screen.name): \(issue.auditType.rawValue) \(element): \(issue.compactDescription)"
                    findings.append(line)
                    if gated.contains(issue.auditType) {
                        XCTFail(line)
                    }
                    return true
                }
            }
            app.terminate()
        }
        let attachment: XCTAttachment = XCTAttachment(string: Set(findings).sorted().joined(separator: "\n"))
        attachment.name = "watch-audit.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let shotsDirectory {
            try Data(Set(findings).sorted().joined(separator: "\n").utf8).write(to: shotsDirectory.appending(path: "watch-audit.txt"))
        }
    }

    // Real WatchConnectivity with the paired iPhone Simulator (only with `WATCH_LINK_TEST=1`): the iPhone app runs in
    // its Debug sample mode (`--tanitim --ornek-kayit --ornek-takvim`), so its snapshot shows a recording, today's
    // meetings and tasks; Pause and Resume from the Watch go to the iPhone as messages and come back in its snapshot.
    @MainActor func testLiveLinkWithPhone() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WATCH_LINK_TEST"] == "1", "needs the paired iPhone Simulator running Gistsmith")
        let app: XCUIApplication = launch(arguments: [], language: "en")
        let recording: XCUIElement = app.staticTexts["iPhone is recording"]
        XCTAssertTrue(recording.waitForExistence(timeout: 60), "no snapshot from the iPhone")
        sleep(2)
        try shot(name: "link-home")
        recording.tap()
        let pause: XCUIElement = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        pause.tap()
        XCTAssertTrue(app.buttons["Resume"].waitForExistence(timeout: 20), "the iPhone did not report the pause")
        try shot(name: "link-phone-paused")
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20), "the iPhone did not report the resume")
        try shot(name: "link-phone-resumed")
    }

    // Records on the Watch and sends it to the paired iPhone Simulator (only with `WATCH_LINK_TEST=1`): the capture is
    // compressed ("Preparing") and handed to `transferFile`, which the Simulator reports as delivered ("Sent to
    // iPhone"). The iPhone's `session(_:didReceive:)` never runs in the Simulator (Apple), so the confirmation that
    // removes the row needs paired devices.
    @MainActor func testRecordAndSendToPhone() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WATCH_LINK_TEST"] == "1", "needs the paired iPhone Simulator running Gistsmith")
        let app: XCUIApplication = launch(arguments: [], language: "en")
        XCTAssertTrue(app.staticTexts["iPhone is recording"].waitForExistence(timeout: 60), "no snapshot from the iPhone")
        app.buttons["Record on Watch"].firstMatch.tap()
        allowMicrophoneIfAsked(app: app)
        // The first recording also asks to show a notice when the system ends a recording.
        allowMicrophoneIfAsked(app: app)
        app.activate()
        let opened: Bool = app.buttons["Finish"].waitForExistence(timeout: 10)
        try shot(name: "link-recording")
        XCTAssertTrue(opened, "the recording screen did not open")
        sleep(2)
        // The Simulator may drop to the watch face meanwhile (the recording keeps running there, with the recording
        // indicator above the time): bring the app back first.
        app.activate()
        XCTAssertTrue(app.buttons["Finish"].waitForExistence(timeout: 10), "the recording did not survive the app leaving the screen")
        app.buttons["Finish"].tap()
        sleep(3)
        for _ in 0..<4 {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Sent to iPhone"].firstMatch.waitForExistence(timeout: 60), "the transfer was not reported as sent")
        try shot(name: "link-after-transfer")
    }

    // A real Watch recording on the Simulator's microphone: the timer runs, Finish lists it.
    @MainActor func testRecordAndFinish() throws {
        let app: XCUIApplication = launch(arguments: ["--ornek", "--ornek-kayit"], language: "en")
        allowMicrophoneIfAsked(app: app)
        // The first recording also asks to show a notice when the system ends a recording.
        allowMicrophoneIfAsked(app: app)
        // A recording cut off by an earlier run (the app was stopped while recording) is reported once.
        let notice: XCUIElement = app.buttons["OK"]
        if notice.waitForExistence(timeout: 3) {
            try shot(name: "en-cut-off-notice")
            notice.tap()
        }
        XCTAssertTrue(app.buttons["Finish"].waitForExistence(timeout: 10), "the recording screen did not open")
        sleep(3)
        try shot(name: "en-watch-recording")
        app.buttons["Finish"].tap()
        XCTAssertTrue(app.staticTexts["Design review"].waitForExistence(timeout: 5))
        sleep(1)
        app.swipeUp()
        app.swipeUp()
        app.swipeUp()
        try shot(name: "en-after-end")
    }
}
