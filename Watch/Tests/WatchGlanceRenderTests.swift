import AINotepadWatchLink
import Foundation
import SwiftUI
import Testing
import WidgetKit
@testable import AINotepadWatch

/// Draws every glance family for every glance content in the watchOS Simulator. With `WATCH_SHOTS_DIR` set (xcodebuild:
/// `TEST_RUNNER_WATCH_SHOTS_DIR=<folder>`) the PNGs are written there for a visual check; without it the test only
/// checks that each one draws.
@MainActor
@Suite struct WatchGlanceRenderTests {
    private let now: Date = Date()

    private var contents: [(name: String, content: WatchGlanceContent)] {
        [
            ("watch-recording", .watchRecording(timerStart: now.addingTimeInterval(-754), pausedAt: nil)),
            ("watch-paused", .watchRecording(timerStart: now.addingTimeInterval(-754), pausedAt: now)),
            ("phone-recording", .phoneRecording(WatchPhoneRecording(recordingID: "r", phase: .recording, title: "Design review", timerStart: now.addingTimeInterval(-1_384), timerStoppedAt: nil))),
            ("next-meeting", .nextMeeting(WatchMeeting(id: "m", title: "Weekly sync with the product team", start: now.addingTimeInterval(1_800), end: now.addingTimeInterval(5_400)))),
            ("idle", .idle),
        ]
    }

    private let families: [(name: String, family: WidgetFamily, size: CGSize)] = [
        ("circular", .accessoryCircular, CGSize(width: 50, height: 50)),
        ("corner", .accessoryCorner, CGSize(width: 50, height: 50)),
        ("rectangular", .accessoryRectangular, CGSize(width: 180, height: 72)),
        ("inline", .accessoryInline, CGSize(width: 180, height: 20)),
    ]

    @Test func everyFamilyDraws() throws {
        let directory: URL? = ProcessInfo.processInfo.environment["WATCH_SHOTS_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (contentName, content) in contents {
            for (familyName, family, size) in families {
                let view = GlanceView(entry: GlanceEntry(date: now, content: content), family: family)
                    .frame(width: size.width, height: size.height)
                    .padding(6)
                    .background(Color.black)
                    .environment(\.colorScheme, .dark)
                let renderer: ImageRenderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image: UIImage = try #require(renderer.uiImage, "\(contentName) \(familyName) did not draw")
                #expect(image.size.width > 0)
                if let directory {
                    let png: Data = try #require(image.pngData())
                    try png.write(to: directory.appending(path: "glance-\(familyName)-\(contentName).png"))
                }
            }
        }
    }
}
