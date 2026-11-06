#if os(macOS)
@testable import AINotepadCore
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AINotepadUI

/// A 1600×1000 "slide" (dark title bar, light body) as the loaded snapshot.
@MainActor
private func slideImage() -> NSImage {
    let image: NSImage = NSImage(size: NSSize(width: 1600, height: 1000))
    image.lockFocus()
    NSColor(calibratedRed: 0.93, green: 0.95, blue: 1, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 1000).fill()
    NSColor(calibratedRed: 0.1, green: 0.12, blue: 0.3, alpha: 1).setFill()
    NSRect(x: 0, y: 820, width: 1600, height: 180).fill()
    image.unlockFocus()
    return image
}

/// A row with two paragraphs and the "In note" tick, as on the Screens tab.
@MainActor
private func row() -> ScreenSnapshotRow {
    let paragraphs: [TranscriptParagraph] = [
        TranscriptParagraph(id: "a", speaker: .others, person: 1, startSec: 29, endSec: 35, text: "Tässä on uusi hinnoittelusivu ja sen kolme tasoa.", turkish: nil, translationFailed: false, words: []),
        TranscriptParagraph(id: "b", speaker: .me, person: nil, startSec: 36, endSec: 42, text: "Selvä, katsotaan seuraavaksi painikkeita.", turkish: nil, translationFailed: false, words: []),
    ]
    let image: NSImage = slideImage()
    return ScreenSnapshotRow(
        item: LinkedScreenSnapshot(snapshot: screenSnapshot(offsetSec: 32), startSec: 29, endSec: 42, paragraphs: paragraphs),
        speakerNames: [1: "Mikko"], isExpanded: false, isLocked: false, canPlay: true, noteChoice: ScreenNoteChoice(isIncluded: true, isEnabled: true),
        isConfirmingDelete: false, thumbnailPixels: 640, fullPixels: 1600,
        loadImage: { (_: ScreenSnapshot, _: Int) async throws -> NSImage in image },
        onToggleNote: {}, onToggleExpanded: {}, onPlay: { (_: Double) -> Void in }, onAskDelete: {}, onCancelDelete: {}, onDelete: {}
    )
}

/// The row laid out at `width` in an off-screen window (so geometry changes and image loading run), with its fitted
/// height and the window's image.
@MainActor
private func laidOut(width: CGFloat, scheme: ColorScheme) async throws -> (height: CGFloat, png: Data) {
    let host: NSHostingView = NSHostingView(rootView: row().frame(width: width).padding(10).background(Theme.background).environment(\.colorScheme, scheme))
    let window: NSWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 20, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = host
    for _ in 0..<6 {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }
    let size: NSSize = host.fittingSize
    window.setContentSize(size)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    let bitmap: NSBitmapImageRep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return (height: size.height, png: try #require(bitmap.representation(using: .png, properties: [:])))
}

@Suite @MainActor struct ScreenSnapshotRowTests {
    // In the narrow side panel the thumbnail goes full width on top and the time range stays on one line: the row is
    // about as tall as the image plus a few lines (it was ~1,000 pt when the range wrapped one character per line).
    // Wide rows keep the thumbnail on the left. With AINOTEPAD_VISUAL_OUT set, the window images (light and dark,
    // narrow and wide) are written there for a visual check.
    @Test func narrowRowsStackAndKeepTheRangeOnOneLine() async throws {
        let output: String? = ProcessInfo.processInfo.environment["AINOTEPAD_VISUAL_OUT"]
        for scheme in [ColorScheme.light, ColorScheme.dark] {
            let narrow: (height: CGFloat, png: Data) = try await laidOut(width: 320, scheme: scheme)
            let wide: (height: CGFloat, png: Data) = try await laidOut(width: 760, scheme: scheme)
            // Image 296×185 + range row + two short paragraphs + padding.
            #expect(narrow.height > 250 && narrow.height < 420, "dar: \(narrow.height)")
            // Thumbnail 240×150 beside the details.
            #expect(wide.height < 230, "geniş: \(wide.height)")
            if let output {
                let name: String = scheme == .dark ? "dark" : "light"
                try narrow.png.write(to: URL(fileURLWithPath: output).appending(path: "screens-row-narrow-\(name).png"))
                try wide.png.write(to: URL(fileURLWithPath: output).appending(path: "screens-row-wide-\(name).png"))
            }
        }
    }
}
#endif
