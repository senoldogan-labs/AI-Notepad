// Draws the app icon and its variants. The glyph is the same everywhere: three rounded bars (sound) and a horizontal
// stroke on the right (the note), sound -> note. The variants only change the ground and the glyph colours so the mark
// stays recognisable at 29 pt, in the Dock and on the watch face.
//
// Apple Watch uses `ios cream` (Watch/Assets.xcassets): watchOS masks the square to a circle, and App Review requires
// a ground lighter than the black watch face so the icon reads as a circle (Guideline 4).
//
// Variants:
//   standard  near-black ground, faint grain, white glyph (the App Store icon; unchanged)
//   ember     copper band (sand -> copper -> deep ember) with faint contour lines, cream glyph
//   cream     Ember's light cream ground, near-black bars and a copper note stroke
//   night     warm near-black ground with faint copper contours, copper glyph
//   classic   pastel sunset film (the Classic palette's covers), near-black glyph
//   dark      iOS 18+ dark appearance of `standard`: transparent ground, white bars, copper note (iOS only)
//   tinted    iOS 18+ tinted appearance of `standard`: transparent ground, grayscale glyph (iOS only)
//
// macOS follows Apple's icon grid: a 1024 canvas with an 824 rounded body, a transparent margin and a soft shadow.
// macOS 26 does not treat a full-bleed square as a standard shape and puts it in a grey frame (the mark disappears in
// the Dock). The launch splash mark (`AppMark`) uses the same proportions. iOS icons are full-bleed squares; the opaque
// ones have no alpha channel (iOS masks the corners itself; App Store Connect rejects an alpha channel, ITMS-90717).
// The dark and tinted appearances are the exception: Xcode expects a transparent ground there.
//
// Usage: swift scripts/render-app-icon.swift <output.png> <mac|ios> <variant>
import AppKit
import CoreGraphics
import Foundation

let variants: [String] = ["standard", "ember", "cream", "night", "classic", "dark", "tinted"]
let iosOnlyVariants: Set<String> = ["dark", "tinted"]
guard CommandLine.arguments.count == 4, ["mac", "ios"].contains(CommandLine.arguments[2]), variants.contains(CommandLine.arguments[3]),
      CommandLine.arguments[2] == "ios" || !iosOnlyVariants.contains(CommandLine.arguments[3])
else {
    FileHandle.standardError.write(Data("Usage: swift scripts/render-app-icon.swift <output.png> <mac|ios> <\(variants.joined(separator: "|"))> (dark and tinted are iOS only)\n".utf8))
    exit(1)
}

let canvas: CGFloat = 1024
let outputPath: String = CommandLine.arguments[1]
let isIOS: Bool = CommandLine.arguments[2] == "ios"
let variant: String = CommandLine.arguments[3]
/// Transparent iOS appearances (dark, tinted): the system draws the ground.
let isTransparentAppearance: Bool = iosOnlyVariants.contains(variant)
/// Body: 824x824 with a 100 pt transparent margin on macOS (corner radius ~22.4 % of the body); a full square on iOS.
let body: CGRect = isIOS ? CGRect(x: 0, y: 0, width: 1024, height: 1024) : CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = isIOS ? 0 : 185
let size: CGFloat = body.width
let unit: CGFloat = size / 100

/// sRGB colour from 0...255 channels.
func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

/// sRGB colour from a 0xRRGGBB value.
func hex(_ value: UInt32, _ alpha: CGFloat) -> CGColor {
    rgb(CGFloat((value >> 16) & 0xFF), CGFloat((value >> 8) & 0xFF), CGFloat(value & 0xFF), alpha)
}

let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let hasAlpha: Bool = !isIOS || isTransparentAppearance
let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
let context: CGContext = CGContext(
    data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: alphaInfo.rawValue
)!
let bodyPath: CGPath = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

/// Colours of one variant's ground and glyph.
struct Look {
    /// Top-to-bottom linear ground.
    let ground: [CGColor]
    /// Radial light or shade spots on the ground: centre and radius in body fractions (y up), colour.
    let spots: [(x: CGFloat, y: CGFloat, radius: CGFloat, color: CGColor)]
    /// Grain dot colours (light, dark).
    let grain: (light: CGColor, dark: CGColor)
    /// Contour line colour, or nil for none.
    let contour: CGColor?
    /// Bar colours top to bottom (one colour = flat).
    let bars: [CGColor]
    /// Note stroke colours top to bottom.
    let note: [CGColor]
    /// Glyph shadow colour.
    let glyphShadow: CGColor
}

let looks: [String: Look] = [
    "standard": Look(
        ground: [rgb(34, 34, 34, 1), rgb(6, 6, 6, 1)],
        spots: [(0.3, 0.95, 0.9, rgb(255, 255, 255, 0.07))],
        grain: (rgb(255, 255, 255, 0.035), rgb(0, 0, 0, 0.12)), contour: nil,
        bars: [rgb(250, 250, 250, 1)], note: [rgb(250, 250, 250, 1)], glyphShadow: rgb(0, 0, 0, 0.45)
    ),
    "ember": Look(
        ground: [hex(0xBD976F, 1), hex(0xA5664B, 1), hex(0x7E4330, 1)],
        spots: [
            (0.82, 0.92, 0.5, hex(0xD9B898, 0.6)), (0.05, 0.05, 0.75, hex(0x4A2519, 0.85)),
            (0.95, 0.0, 0.6, hex(0x5A2C1D, 0.7)),
        ],
        grain: (rgb(255, 240, 225, 0.05), rgb(40, 16, 8, 0.10)), contour: hex(0xFAECDC, 0.26),
        bars: [hex(0xFFFBF5, 1)], note: [hex(0xFFFBF5, 1)], glyphShadow: hex(0x2A120A, 0.55)
    ),
    "cream": Look(
        ground: [hex(0xFBF7F0, 1), hex(0xF6F0E7, 1), hex(0xE9DCC8, 1)],
        spots: [(0.25, 0.95, 0.8, rgb(255, 255, 255, 0.6)), (0.95, 0.0, 0.7, hex(0xE8D3B8, 0.45))],
        grain: (rgb(255, 255, 255, 0.05), rgb(60, 40, 20, 0.05)), contour: nil,
        bars: [hex(0x100E0D, 1)], note: [hex(0x8E5038, 1)], glyphShadow: hex(0x4A2519, 0.18)
    ),
    "night": Look(
        ground: [hex(0x2A1E19, 1), hex(0x140F0D, 1)],
        spots: [(0.85, 0.05, 0.75, hex(0x4A2519, 0.45)), (0.3, 0.95, 0.9, rgb(255, 235, 215, 0.05))],
        grain: (rgb(255, 235, 215, 0.035), rgb(0, 0, 0, 0.12)), contour: hex(0xB07A58, 0.13),
        bars: [hex(0xF3D9C0, 1), hex(0xD9946C, 1)], note: [hex(0xE7B08C, 1)],
        glyphShadow: rgb(0, 0, 0, 0.5)
    ),
    "classic": Look(
        ground: [hex(0xFFC2A4, 1), hex(0xF89870, 1)],
        spots: [
            (0.18, 0.9, 0.62, hex(0xFFF3E6, 0.95)), (0.95, 0.85, 0.55, hex(0xF4B6C2, 0.8)),
            (0.85, 0.05, 0.6, hex(0xF27A52, 0.8)), (0.05, 0.1, 0.55, hex(0xFA8DA0, 0.55)),
        ],
        grain: (rgb(255, 255, 255, 0.05), rgb(80, 30, 10, 0.04)), contour: nil,
        bars: [hex(0x141414, 1)], note: [hex(0x141414, 1)], glyphShadow: hex(0x7A2E14, 0.18)
    ),
    "dark": Look(
        ground: [], spots: [], grain: (rgb(0, 0, 0, 0), rgb(0, 0, 0, 0)), contour: nil,
        bars: [rgb(250, 250, 250, 1)], note: [hex(0xE2A47F, 1)], glyphShadow: rgb(0, 0, 0, 0)
    ),
    "tinted": Look(
        ground: [], spots: [], grain: (rgb(0, 0, 0, 0), rgb(0, 0, 0, 0)), contour: nil,
        bars: [rgb(255, 255, 255, 1)], note: [rgb(186, 186, 186, 1)], glyphShadow: rgb(0, 0, 0, 0)
    ),
]
let look: Look = looks[variant]!

if !isTransparentAppearance {
    // Soft shadow under the body (macOS icons; outside the canvas on iOS).
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: rgb(0, 0, 0, 0.32))
    context.addPath(bodyPath)
    context.setFillColor(look.ground.last!)
    context.fillPath()
    context.restoreGState()
}

// Everything below is clipped to the body, with the body's bottom-left corner as the origin.
context.addPath(bodyPath)
context.clip()
context.translateBy(x: body.minX, y: body.minY)

if !look.ground.isEmpty {
    let locations: [CGFloat] = look.ground.indices.map { CGFloat($0) / CGFloat(max(1, look.ground.count - 1)) }
    let ground: CGGradient = CGGradient(colorsSpace: space, colors: look.ground as CFArray, locations: locations)!
    context.drawLinearGradient(ground, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
}

for spot in look.spots {
    let clear: CGColor = spot.color.copy(alpha: 0)!
    let gradient: CGGradient = CGGradient(colorsSpace: space, colors: [spot.color, clear] as CFArray, locations: [0, 1])!
    let center: CGPoint = CGPoint(x: size * spot.x, y: size * spot.y)
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: size * spot.radius, options: [])
}

/// Contour lines: nested envelopes of a speech wave (the sound's topography), like the Ember band's `ContourLines`,
/// in the lower part of the body. Fixed seed, so every render is identical.
if let contour = look.contour {
    var state: UInt64 = 0x5EED_1C0F_0000_0001
    func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(state >> 11) / Double(1 << 53))
    }
    let bumps: [(center: CGFloat, width: CGFloat, amplitude: CGFloat)] = (0..<5).map { (index: Int) in
        (0.1 + (CGFloat(index) + next() * 0.8) / 5 * 0.85, 0.06 + next() * 0.07, 0.3 + next() * 0.7)
    }
    func envelope(_ x: CGFloat, _ spread: CGFloat) -> CGFloat {
        bumps.reduce(0) { (sum: CGFloat, bump: (center: CGFloat, width: CGFloat, amplitude: CGFloat)) -> CGFloat in
            let distance: CGFloat = (x - bump.center) / (bump.width * spread)
            return sum + bump.amplitude / spread.squareRoot() * exp(-distance * distance)
        }
    }
    let peak: CGFloat = (0...200).map { envelope(CGFloat($0) / 200, 1) }.max()!
    context.setStrokeColor(contour)
    context.setLineWidth(size * 0.0045)
    let count: Int = 5
    for index in 0..<count {
        // y up: the first line is the highest, later ones sit lower and flatter.
        let base: CGFloat = size * (0.24 - CGFloat(index) * 0.045)
        let spread: CGFloat = 1 + CGFloat(index) * 0.45
        let path: CGMutablePath = CGMutablePath()
        for step in 0...120 {
            let x: CGFloat = CGFloat(step) / 120
            let point: CGPoint = CGPoint(x: x * size, y: base + size * 0.12 * envelope(x, spread) / peak)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        context.addPath(path)
        context.strokePath()
    }
}

// Fine grain: fixed-seed dots (identical on every render).
if !isTransparentAppearance {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for _ in 0..<60000 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let x: CGFloat = CGFloat(seed >> 40) / CGFloat(1 << 24) * size
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let y: CGFloat = CGFloat(seed >> 40) / CGFloat(1 << 24) * size
        context.setFillColor(seed & 1 == 0 ? look.grain.light : look.grain.dark)
        context.fill(CGRect(x: x, y: y, width: 2, height: 2))
    }
}

// Glyph on a 100-unit grid (y up): three bars and a stroke, centred horizontally.
let bars: [CGRect] = [
    CGRect(x: 24, y: 40, width: 7, height: 20),
    CGRect(x: 35, y: 30, width: 7, height: 40),
    CGRect(x: 46, y: 36, width: 7, height: 28),
]
let note: CGRect = CGRect(x: 58, y: 46.5, width: 20, height: 7)
let shift: CGFloat = 50 - (24 + 78) / 2

/// Fills one glyph mark with a flat colour or a top-to-bottom gradient spanning the glyph's full height.
func drawMark(_ mark: CGRect, colors: [CGColor]) {
    let rect: CGRect = CGRect(x: (mark.minX + shift) * unit, y: (100 - mark.maxY) * unit, width: mark.width * unit, height: mark.height * unit)
    let radius: CGFloat = min(rect.width, rect.height) / 2
    let path: CGPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 24, color: look.glyphShadow)
    context.addPath(path)
    context.setFillColor(colors[0])
    context.fillPath()
    context.restoreGState()
    guard colors.count > 1 else {
        return
    }
    context.saveGState()
    context.addPath(path)
    context.clip()
    let locations: [CGFloat] = colors.indices.map { CGFloat($0) / CGFloat(colors.count - 1) }
    let gradient: CGGradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 70 * unit), end: CGPoint(x: 0, y: 30 * unit), options: [])
    context.restoreGState()
}

for bar in bars {
    drawMark(bar, colors: look.bars)
}
drawMark(note, colors: look.note)

// Cream on macOS: a faint inner edge so the light tile stays visible on light windows and wallpapers (iOS masks the
// corners itself, so a drawn edge would break there).
if variant == "cream" && !isIOS {
    context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 2, dy: 2), cornerWidth: max(0, cornerRadius - 2), cornerHeight: max(0, cornerRadius - 2), transform: nil))
    context.setStrokeColor(hex(0x100E0D, 0.10))
    context.setLineWidth(4)
    context.strokePath()
}

let image: CGImage = context.makeImage()!
let data: Data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
