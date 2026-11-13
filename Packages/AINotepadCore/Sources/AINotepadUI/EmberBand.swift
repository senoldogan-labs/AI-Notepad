import CoreGraphics
import SwiftUI

/// Kor (Ember) bandının sekiz durağı: bakırdan kuma (900 en koyu, 100 en açık), Kor vurgusunda. Öteki vurgularda
/// `emberBandStops` aynı durakları vurgunun tonuna döndürür. İki görünümde aynı; açık görünüm köşelerde bir adım açık
/// durakları kullanır (krem zeminde band çamura çalmasın).
public enum EmberStop {
    public static let e900: UInt32 = 0x4A2519
    public static let e700: UInt32 = 0x7E4330
    public static let e600: UInt32 = 0x93553D
    public static let e500: UInt32 = 0xA5664B
    public static let e400: UInt32 = 0xB07A58
    public static let e300: UInt32 = 0xBD976F
    public static let e200: UInt32 = 0xD2B48E
    public static let e100: UInt32 = 0xE8D3B8
}

/// Bandın bir görünümdeki renkleri: zemin geçişinin üç durağı, iki köşe ve iki ışık.
struct EmberBandColors: Equatable {
    let top: UInt32
    let middle: UInt32
    let bottom: UInt32
    /// Sol alt köşe.
    let corner: UInt32
    /// Sağ alt derin köşe.
    let deep: UInt32
    /// Sağ üstteki küçük ışık.
    let highlight: UInt32
    /// Sol ortadaki geniş açık ton.
    let glow: UInt32
    /// Üst kenardaki 1 pt beyaz çizginin opaklığı (krem zeminden ayırır; koyuda yok).
    let topEdgeOpacity: Double

    /// Açık görünüm: derin köşede 600/500, ışıklar bir adım koyu, üst kenarda ince ışık; vurgunun tonunda. Saf
    /// fonksiyondur.
    static func light(accent: PanelAccent) -> EmberBandColors {
        let stops: EmberBandStops = emberBandStops(accent: accent)
        return EmberBandColors(
            top: stops.e400, middle: stops.e500, bottom: stops.e600, corner: stops.e500, deep: stops.e600,
            highlight: stops.e200, glow: emberTinted(hex: 0xC4A07A, accent: accent), topEdgeOpacity: 0.5
        )
    }

    /// Koyu görünüm: derin köşede 900/700; vurgunun tonunda. Saf fonksiyondur.
    static func dark(accent: PanelAccent) -> EmberBandColors {
        let stops: EmberBandStops = emberBandStops(accent: accent)
        return EmberBandColors(
            top: stops.e400, middle: stops.e500, bottom: stops.e600, corner: stops.e700, deep: stops.e900,
            highlight: stops.e100, glow: stops.e200, topEdgeOpacity: 0
        )
    }
}

/// Kor bandı: bakırdan kuma durgun geçiş, ince gren ve isteğe göre ince kontur çizgileri (bkz. `ContourLines`); renkler
/// vurgunun tonunda (`emberBandStops`). Bir kez çizilir (zamanlayıcı, kare kare bulanıklık ya da canlandırma yok).
/// Bandın üstüne doğrudan yazı konmaz; yazı beyaz hap ve çiplerde durur.
public struct EmberBand: View {
    let contourSeed: String
    let contourCount: Int
    @Environment(\.colorScheme) private var colorScheme: ColorScheme
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// `contourCount` 0 ise kontur çizilmez.
    public init(contourSeed: String, contourCount: Int) {
        self.contourSeed = contourSeed
        self.contourCount = contourCount
    }

    public var body: some View {
        if ThemeStore.shared.palette.brand == .flat {
            flatBody
        } else {
            emberBody
        }
    }

    /// Flat palettes (Olive) draw the band as one flat accent surface: no light, grain or contour lines.
    private var flatBody: some View {
        appearance.accent.colorOnDarkSurface
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .accessibilityIdentifier("decorative")
    }

    private var emberBody: some View {
        let colors: EmberBandColors = colorScheme == .dark ? .dark(accent: appearance.accent) : .light(accent: appearance.accent)
        return ZStack {
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                drawEmberBand(context: context, size: size, colors: colors)
            }
            Rectangle()
                .fill(ImagePaint(image: Image(decorative: filmGrainImage, scale: 2)))
                .blendMode(.overlay)
                .opacity(0.38)
            if contourCount > 0 {
                ContourLines(seed: contourSeed, count: contourCount)
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(colors.topEdgeOpacity)).frame(height: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // The identifier tells the iPhone's accessibility audit test (iOSUITests) that this hidden view is decoration.
        .accessibilityIdentifier("decorative")
    }
}

/// Bandı çizer: alttan üste doğrusal zemin, iki koyu köşe, iki ışık (eliptik radyal geçişler).
private func drawEmberBand(context: GraphicsContext, size: CGSize, colors: EmberBandColors) {
    let rect: CGRect = CGRect(origin: .zero, size: size)
    // 160°: üstte hafif sağdan alta sola.
    context.fill(Path(rect), with: .linearGradient(
        Gradient(stops: [
            .init(color: Color(hex: colors.top), location: 0),
            .init(color: Color(hex: colors.middle), location: 0.55),
            .init(color: Color(hex: colors.bottom), location: 1),
        ]),
        startPoint: CGPoint(x: size.width * 0.33, y: 0), endPoint: CGPoint(x: size.width * 0.67, y: size.height)
    ))
    let ellipses: [(x: Double, y: Double, rx: Double, ry: Double, stops: [Gradient.Stop])] = [
        (0.02, 0.96, 0.52, 0.64, [.init(color: Color(hex: colors.corner), location: 0), .init(color: Color(hex: colors.corner).opacity(0), location: 0.72)]),
        (0.92, 1.0, 0.60, 0.70, [
            .init(color: Color(hex: colors.deep), location: 0), .init(color: Color(hex: colors.deep).opacity(0.4), location: 0.5),
            .init(color: Color(hex: colors.deep).opacity(0), location: 0.8),
        ]),
        (0.78, 0.22, 0.38, 0.50, [.init(color: Color(hex: colors.highlight).opacity(0.7), location: 0), .init(color: Color(hex: colors.highlight).opacity(0), location: 0.7)]),
        (0.34, 0.38, 0.46, 0.62, [
            .init(color: Color(hex: colors.glow), location: 0), .init(color: Color(hex: colors.glow).opacity(0.4), location: 0.45),
            .init(color: Color(hex: colors.glow).opacity(0), location: 0.75),
        ]),
    ]
    for ellipse in ellipses {
        var layer: GraphicsContext = context
        layer.clip(to: Path(rect))
        layer.translateBy(x: ellipse.x * size.width, y: ellipse.y * size.height)
        layer.scaleBy(x: ellipse.rx * size.width, y: ellipse.ry * size.height)
        layer.fill(
            Path(CGRect(x: -4, y: -4, width: 8, height: 8)),
            with: .radialGradient(Gradient(stops: ellipse.stops), center: .zero, startRadius: 0, endRadius: 1)
        )
    }
}

/// Bandın üstündeki ince açık kontur çizgileri: bir konuşma dalgasının iç içe zarfları (sesin topografyası), vurgunun
/// tonunda krem. Çizgiler `contourPaths` ile boyuttan ve tohumdan bir kez hesaplanır; durgundur.
public struct ContourLines: View {
    let seed: String
    let count: Int
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(seed: String, count: Int) {
        self.seed = seed
        self.count = count
    }

    public var body: some View {
        let stroke: Color = Color(hex: emberTinted(hex: 0xFAECDC, accent: appearance.accent)).opacity(0.3)
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            for line in contourPaths(seed: seed, size: size, count: count) {
                context.stroke(contourPath(points: line), with: .color(stroke), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Noktalardan yumuşak çizgi: ardışık noktaların orta noktalarından geçen ikinci derece eğriler.
func contourPath(points: [CGPoint]) -> Path {
    var path: Path = Path()
    guard let first = points.first else {
        return path
    }
    path.move(to: first)
    for index in 1..<max(1, points.count - 1) {
        let point: CGPoint = points[index]
        let next: CGPoint = points[index + 1]
        path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
    }
    if points.count > 1, let last = points.last {
        path.addLine(to: last)
    }
    return path
}

/// Kontur çizgilerinin noktaları: tohumdan sabit altı hece tümseğinden bir ses zarfı; her çizgi zarfı biraz daha geniş ve
/// aşağıda çizer, bir öncekinin en az %2,2 yükseklik altında kalır (çizgiler kesişmez). Her çizgi soldan sağa
/// `steps + 1` noktadır. Saf fonksiyondur.
public func contourPaths(seed: String, size: CGSize, count: Int) -> [[CGPoint]] {
    var state: UInt64 = seed.unicodeScalars.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1.value)) &* 0x100_0000_01B3 }
    let next: () -> Double = {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    let bumps: [(center: Double, width: Double, amplitude: Double)] = (0..<6).map { (index: Int) -> (center: Double, width: Double, amplitude: Double) in
        let center: Double = 0.08 + (Double(index) + next() * 0.8) / 6 * 0.86
        return (center, 0.05 + next() * 0.07, 0.25 + next() * 0.75)
    }
    let raw: (Double, Double) -> Double = { (x: Double, spread: Double) -> Double in
        bumps.reduce(0) { (sum: Double, bump: (center: Double, width: Double, amplitude: Double)) -> Double in
            let distance: Double = (x - bump.center) / (bump.width * spread)
            return sum + bump.amplitude / spread.squareRoot() * exp(-distance * distance)
        }
    }
    let peak: Double = (0...200).map { raw(Double($0) / 200, 1) }.max() ?? 1
    let steps: Int = 96
    let height: Double = Double(size.height)
    let width: Double = Double(size.width)
    var lines: [[CGPoint]] = []
    for index in 0..<max(0, count) {
        let base: Double = height * (0.42 + Double(index) * 0.62 / Double(count))
        let amplitude: Double = height * 0.34
        let spread: Double = 1 + Double(index) * 0.45
        let previous: [CGPoint]? = lines.last
        let points: [CGPoint] = (0...steps).map { (step: Int) -> CGPoint in
            let x: Double = Double(step) / Double(steps)
            let envelope: Double = raw(x, spread) / peak
            let y: Double = base - amplitude * envelope
            let floor: Double = previous.map { Double($0[step].y) + height * 0.022 } ?? -Double.infinity
            return CGPoint(x: x * width, y: max(y, floor))
        }
        lines.append(points)
    }
    return lines
}

/// Kürenin radyal geçişi: ışığın konumu (0...1) ve durakları.
public struct EmberOrbGradient: Equatable, Sendable {
    let center: UnitPoint
    let stops: [(color: UInt32, location: Double)]

    public static func == (left: EmberOrbGradient, right: EmberOrbGradient) -> Bool {
        left.center == right.center && left.stops.map(\.color) == right.stops.map(\.color) && left.stops.map(\.location) == right.stops.map(\.location)
    }

    /// Marka küresi (Mac'teki kayıt çubuğu): sol üstte kum ışığı, kenarda koyu bakır; vurgunun tonunda. Saf fonksiyondur.
    public static func brand(accent: PanelAccent) -> EmberOrbGradient {
        EmberOrbGradient(center: UnitPoint(x: 0.34, y: 0.30), stops: tinted(stops: [(0xF4E3CF, 0), (0xCF9670, 0.22), (EmberStop.e500, 0.5), (0x5A2C1D, 0.88)], accent: accent))
    }

    /// Kayıt düğmesi (iPhone): ışık kenara yakın, ortası koyu (beyaz mikrofon okunur); vurgunun tonunda. Saf fonksiyondur.
    public static func recordButton(accent: PanelAccent) -> EmberOrbGradient {
        EmberOrbGradient(
            center: UnitPoint(x: 0.22, y: 0.18), stops: tinted(stops: [(0xE9C9AC, 0), (EmberStop.e500, 0.26), (EmberStop.e600, 0.55), (EmberStop.e900, 1)], accent: accent)
        )
    }

    /// Durakların renkleri vurgunun tonunda. Saf fonksiyondur.
    private static func tinted(stops: [(color: UInt32, location: Double)], accent: PanelAccent) -> [(color: UInt32, location: Double)] {
        stops.map { (stop: (color: UInt32, location: Double)) -> (color: UInt32, location: Double) in (emberTinted(hex: stop.color, accent: accent), stop.location) }
    }
}

/// Kor küresi: marka yüzeyi (vurgunun tonunda, bkz. `EmberOrbGradient`), içte hafif alt gölge. Durgundur.
public struct EmberOrb: View {
    let gradient: EmberOrbGradient

    public init(gradient: EmberOrbGradient) {
        self.gradient = gradient
    }

    public var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            let side: Double = Double(min(proxy.size.width, proxy.size.height))
            // CSS `circle at x y` gibi: yarıçap ışıktan en uzak köşeye.
            let reach: Double = (pow(max(gradient.center.x, 1 - gradient.center.x), 2) + pow(max(gradient.center.y, 1 - gradient.center.y), 2)).squareRoot()
            Circle()
                .fill(
                    RadialGradient(
                        stops: gradient.stops.map { Gradient.Stop(color: Color(hex: $0.color), location: $0.location) },
                        center: gradient.center, startRadius: 0, endRadius: side * reach
                    )
                    .shadow(.inner(color: Color(red: 40 / 255, green: 16 / 255, blue: 8 / 255).opacity(0.35), radius: 3, y: -2))
                )
        }
        .accessibilityHidden(true)
    }
}
