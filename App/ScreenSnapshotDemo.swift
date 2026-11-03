#if DEBUG
import AINotepadCore
import AppKit
import Foundation
import SwiftUI

// Tanıtım modu (yalnız Debug): "Product weekly" toplantısına sahte ama inandırıcı ekran görüntüleri (paylaşılan slayt ve
// tasarım ekranları) yazılır; "ekranlar" sahnesi toplantının Ekranlar sekmesini açar (görsel kontrol).

/// Tanıtım ekranının içeriği.
private struct DemoScreen {
    let offsetSec: Double
    let title: String
    let subtitle: String
    let lines: [String]
    let accent: NSColor
}

/// "Product weekly"de paylaşılan ekranlar (transkriptteki konularla aynı anlarda).
private let demoScreens: [DemoScreen] = [
    DemoScreen(offsetSec: 6, title: "Beta plan", subtitle: "Product weekly · agenda", lines: ["Open beta on 14 November", "Export sync bug: last blocker", "First wave: 200 accounts"], accent: NSColor(red: 0.36, green: 0.42, blue: 0.95, alpha: 1)),
    DemoScreen(offsetSec: 610, title: "Pricing", subtitle: "Current tiers during the beta", lines: ["Monthly $5.99", "Yearly $49", "No discounts until usage data"], accent: NSColor(red: 0.93, green: 0.45, blue: 0.36, alpha: 1)),
    DemoScreen(offsetSec: 1308, title: "Support during the beta", subtitle: "Weekly sync", lines: ["Wednesday call with support", "Shared triage board", "Escalation path to engineering"], accent: NSColor(red: 0.20, green: 0.66, blue: 0.55, alpha: 1)),
    DemoScreen(offsetSec: 2386, title: "Next steps", subtitle: "Owners and dates", lines: ["Release notes — Friday", "Pricing table — today", "Beta list — Monday"], accent: NSColor(red: 0.62, green: 0.40, blue: 0.90, alpha: 1)),
]

/// Toplantının klasörüne tanıtım ekran görüntülerini yazar.
func seedDemoScreenSnapshots(meetingDirectory: URL) throws {
    for screen in demoScreens {
        let image: CGImage = try demoScreenImage(screen: screen)
        try writeScreenSnapshot(meetingDirectory: meetingDirectory, snapshot: screenSnapshot(offsetSec: screen.offsetSec), jpeg: try jpegData(image: image, quality: 0.8))
    }
}

/// Tanıtım görüntüsü çizilemedi.
private struct DemoScreenRenderError: Error {}

/// Slayt benzeri bir ekran: beyaz zemin, renkli başlık şeridi, başlık ve maddeler.
private func demoScreenImage(screen: DemoScreen) throws -> CGImage {
    let width: Int = 1600
    let height: Int = 1000
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw DemoScreenRenderError()
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    NSColor(white: 0.985, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    screen.accent.withAlphaComponent(0.14).setFill()
    NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 640, height: 640), xRadius: 32, yRadius: 32).fill()
    screen.accent.setFill()
    NSRect(x: 0, y: CGFloat(height) - 18, width: CGFloat(width), height: 18).fill()
    let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 76, weight: .bold), .foregroundColor: NSColor(white: 0.08, alpha: 1)]
    let subtitle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: screen.accent]
    let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44, weight: .regular), .foregroundColor: NSColor(white: 0.2, alpha: 1)]
    (screen.subtitle as NSString).draw(at: NSPoint(x: 120, y: 820), withAttributes: subtitle)
    (screen.title as NSString).draw(at: NSPoint(x: 120, y: 710), withAttributes: title)
    for (index, line) in screen.lines.enumerated() {
        let y: CGFloat = 560 - CGFloat(index) * 110
        screen.accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: 128, y: y + 16, width: 18, height: 18)).fill()
        ("  " + line as NSString).draw(at: NSPoint(x: 150, y: y), withAttributes: body)
    }
    screen.accent.withAlphaComponent(0.85).setFill()
    NSBezierPath(roundedRect: NSRect(x: 1060, y: 240, width: 400, height: 520), xRadius: 28, yRadius: 28).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    for row in 0..<4 {
        NSBezierPath(roundedRect: NSRect(x: 1100, y: 640 - CGFloat(row) * 110, width: row == 3 ? 200 : 320, height: 40), xRadius: 20, yRadius: 20).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else {
        throw DemoScreenRenderError()
    }
    return image
}

/// `--tanitim-ekran-ayari` (yalnız Debug): Ayarlar açılınca "Paylaşılan ekranın görüntülerini al" satırı görünene dek
/// kaydırılır (görsel kontrol için).
struct DemoScrollIntoView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view: NSView = NSView()
        guard CommandLine.arguments.contains("--tanitim-ekran-ayari") else {
            return view
        }
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(800))
            } catch {
                return
            }
            // Yalnızca ayarların kaydırma görünümü kaydırılır (satır ortada); pencereye dokunulmaz.
            guard let scrollView = view.enclosingScrollView, let document = scrollView.documentView else {
                return
            }
            let frame: NSRect = view.convert(view.bounds, to: document)
            let visible: CGFloat = scrollView.contentView.bounds.height
            let y: CGFloat = frame.midY - visible / 2
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
