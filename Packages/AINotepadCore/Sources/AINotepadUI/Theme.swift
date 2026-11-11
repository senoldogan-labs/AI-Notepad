#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Observation
import SwiftUI

/// Bir tema takımının renkleri (tek görünüm için: açık ya da koyu).
public struct ThemeColorSet: Equatable, Sendable {
    public let background: UInt32
    public let card: UInt32
    public let line: UInt32
    public let soft: UInt32
    public let selected: UInt32
    public let ink: UInt32
    public let muted: UInt32
    public let primary: UInt32
    public let onPrimary: UInt32
    /// Uyarı simgelerinin renkleri (bkz. `NoticeSeverity`): bilgi, dikkat, hata.
    public let info: UInt32
    public let attention: UInt32
    public let error: UInt32

    public init(
        background: UInt32, card: UInt32, line: UInt32, soft: UInt32, selected: UInt32, ink: UInt32, muted: UInt32, primary: UInt32, onPrimary: UInt32,
        info: UInt32, attention: UInt32, error: UInt32
    ) {
        self.background = background
        self.card = card
        self.line = line
        self.soft = soft
        self.selected = selected
        self.ink = ink
        self.muted = muted
        self.primary = primary
        self.onPrimary = onPrimary
        self.info = info
        self.attention = attention
        self.error = error
    }

    /// Klasik açık (ElevenLabs açık): süt beyazı zemin, beyaz kart, neredeyse siyah yazı.
    public static let light: ThemeColorSet = ThemeColorSet(
        background: 0xFDFCFC, card: 0xFFFFFF, line: 0xE5E5E5, soft: 0xF5F5F5, selected: 0xEFEEED, ink: 0x0A0A0A, muted: 0x6B6B6B, primary: 0x171717, onPrimary: 0xFAFAFA, info: 0x52657A, attention: 0x9A5B00, error: 0xB42318
    )
    /// Klasik koyu (ElevenLabs koyu): aynı düzen ters renklerle.
    public static let dark: ThemeColorSet = ThemeColorSet(
        background: 0x0A0A0A, card: 0x141414, line: 0x262626, soft: 0x1C1C1C, selected: 0x232323, ink: 0xFAFAFA, muted: 0xA3A3A3, primary: 0xFAFAFA, onPrimary: 0x0A0A0A, info: 0x9FB3C8, attention: 0xF2B863, error: 0xFF8A7A
    )
    /// Kor açık (Ember Sand): krem zemin, sıcak kart, sıcak siyah yazı; bütün yazı çiftleri AA (`ThemePaletteTests`).
    public static let emberLight: ThemeColorSet = ThemeColorSet(
        background: 0xF6F0E7, card: 0xFFFBF5, line: 0xE2D6C4, soft: 0xEEE5D8, selected: 0xE7DCCB, ink: 0x1C1714, muted: 0x655848, primary: 0x1C1714, onPrimary: 0xFFFBF5,
        info: 0x4B5E73, attention: 0x7A5900, error: 0xB1192F
    )
    /// Kor koyu (Ember Night): sıcak, siyaha yakın zemin, krem yazı.
    public static let emberDark: ThemeColorSet = ThemeColorSet(
        background: 0x100E0D, card: 0x1A1715, line: 0x2E2824, soft: 0x221E1B, selected: 0x2A2521, ink: 0xF5EDE4, muted: 0xA99E93, primary: 0xF5EDE4, onPrimary: 0x141110,
        info: 0x9FB3C8, attention: 0xF5C55A, error: 0xFF7F86
    )
}

/// İki rengin WCAG 2 karşıtlık oranı (1–21; normal yazı için en az 4,5). `ThemeTests` soluk yazının (`muted`) her
/// temada bütün zeminlerde okunur kaldığını bununla denetler. Saf fonksiyondur.
public func contrastRatio(foreground: UInt32, background: UInt32) -> Double {
    let luminance: (UInt32) -> Double = { (hex: UInt32) -> Double in
        let channel: (UInt32) -> Double = { (value: UInt32) -> Double in
            let srgb: Double = Double(value & 0xFF) / 255
            return srgb <= 0.03928 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }
    let lighter: Double = max(luminance(foreground), luminance(background))
    let darker: Double = min(luminance(foreground), luminance(background))
    return (lighter + 0.05) / (darker + 0.05)
}

/// Temalar: Sistem (sistemi izler), Açık ve Koyu; renkleri seçili palet verir (`ThemePalette`). Mac ve iPhone aynı ayarı
/// (`appearance.theme`) kullanır; saklı değer `resolvedAppTheme` ile okunur.
public enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    /// Temanın görünümü koyu mu (Sistem'de nil: sistemi izler). Saf fonksiyondur.
    public var isDark: Bool? {
        switch self {
        case .system: nil
        case .light: false
        case .dark: true
        }
    }

    /// Temanın SwiftUI görünümü (Sistem'de nil: sistemi izler). Saf fonksiyondur.
    public var colorScheme: ColorScheme? {
        isDark.map { (dark: Bool) -> ColorScheme in dark ? .dark : .light }
    }

    /// Arayüzdeki adı.
    public var displayName: String {
        switch self {
        case .system: String(localized: "Sistem")
        case .light: String(localized: "Açık")
        case .dark: String(localized: "Koyu")
        }
    }
}

/// Saklı tema değerinin teması. Kaldırılan sabit renkli temalar görünümlerinin temasına geçer (Kâğıt ve Kum: Açık;
/// Gece ve Grafit: Koyu); saklı değer yeniden yazılmaz, eski sürümün yazdığı değer de her okumada aynı temaya düşer.
/// Saklı değer yoksa ya da tanınmıyorsa `defaultTheme`'dir. Saf fonksiyondur.
public func resolvedAppTheme(stored: String?, defaultTheme: AppTheme) -> AppTheme {
    switch stored {
    case "paper", "sand": .light
    case "midnight", "graphite": .dark
    default: stored.flatMap(AppTheme.init(rawValue:)) ?? defaultTheme
    }
}

/// Seçili tema takımı: açık ve koyu görünüm için birer renk takımı. Uygulama Ayarlar › Görünüm'den değiştirir;
/// `Theme` renklerini okuyan her görünüm gözlemle yeniden çizilir.
@MainActor
@Observable
public final class ThemeStore {
    public static let shared: ThemeStore = ThemeStore()

    public private(set) var light: ThemeColorSet = .emberLight
    public private(set) var dark: ThemeColorSet = .emberDark
    /// Seçili renk paleti (vurgu renkleri, film aileleri, marka yüzeyi).
    public private(set) var palette: ThemePalette = .ember
    /// Takımın rolleri için oluşturulmuş renkler. Her erişimde yeni dinamik renk oluşturulsaydı SwiftUI eski ve yeni
    /// rengi hiç eşit bulmaz, rengi okuyan her görünümü her güncellemede yeniden işlerdi (çalma sırasında saniyede
    /// onlarca kez tüm pencerenin yerleşimi). Takım değişince boşaltılır.
    @ObservationIgnored private var colors: [KeyPath<ThemeColorSet, UInt32>: Color] = [:]
    /// Vurgu renkleri (aynı nedenle palet başına bir kez oluşturulur).
    @ObservationIgnored private var accentColors: [PanelAccent: ResolvedAccent] = [:]

    private init() {}

    /// Seçimi uygular: paleti ve onun açık ve koyu takımını (hangisinin çizileceğini görünüm seçer: iPhone'da
    /// `preferredColorScheme`, Mac'te `NSApp.appearance`).
    public func apply(choice: ThemeChoice) {
        let palette: ThemePalette = choice.family.palette
        colors = [:]
        accentColors = [:]
        self.palette = palette
        light = palette.light
        dark = palette.dark
    }

    /// Vurgunun paletteki renkleri; palet başına bir kez oluşturulur. Palet her erişimde okunur (gözlem).
    func accent(_ accent: PanelAccent) -> ResolvedAccent {
        let values: AccentColors = palette.accents[accent]
        if let cached = accentColors[accent] {
            return cached
        }
        let soft: Color? = switch values.soft {
        case .tint: nil
        case .solid(let softLight, let softDark): dynamicColor(light: softLight, dark: softDark)
        }
        let made: ResolvedAccent = ResolvedAccent(
            color: dynamicColor(light: values.light, dark: values.dark), on: dynamicColor(light: values.onLight, dark: values.onDark), soft: soft,
            onDarkSurface: Color(hex: values.dark), systemLabelFill: Color(hex: values.light)
        )
        accentColors[accent] = made
        return made
    }

    /// Rolün açık ve koyu görünüme göre değişen rengi; takım başına bir kez oluşturulur. Takımlar her erişimde okunur
    /// (gözlem): takım değişince rengi okuyan görünümler yenilenir.
    func color(role: KeyPath<ThemeColorSet, UInt32>) -> Color {
        let lightHex: UInt32 = light[keyPath: role]
        let darkHex: UInt32 = dark[keyPath: role]
        if let cached = colors[role] {
            return cached
        }
        let made: Color = dynamicColor(light: lightHex, dark: darkHex)
        colors[role] = made
        return made
    }
}

/// Vurgunun seçili paletteki hazır renkleri (bkz. `PanelAccent`).
struct ResolvedAccent {
    let color: Color
    let on: Color
    let soft: Color?
    let onDarkSurface: Color
    let systemLabelFill: Color
}

/// Açık ve koyu görünüm için iki renkli dinamik renk.
func dynamicColor(light: UInt32, dark: UInt32) -> Color {
    #if os(macOS)
    return Color(nsColor: NSColor(name: nil) { (appearance: NSAppearance) -> NSColor in
        let hex: UInt32 = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: hexRed(hex), green: hexGreen(hex), blue: hexBlue(hex), alpha: 1)
    })
    #else
    return Color(uiColor: UIColor { (traits: UITraitCollection) -> UIColor in
        let hex: UInt32 = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: hexRed(hex), green: hexGreen(hex), blue: hexBlue(hex), alpha: 1)
    })
    #endif
}

private func hexRed(_ hex: UInt32) -> CGFloat { CGFloat((hex >> 16) & 0xFF) / 255 }
private func hexGreen(_ hex: UInt32) -> CGFloat { CGFloat((hex >> 8) & 0xFF) / 255 }
private func hexBlue(_ hex: UInt32) -> CGFloat { CGFloat(hex & 0xFF) / 255 }

/// ElevenLabs tarzı tasarım değerleri (elevenlabs.io stil dosyalarından): süt beyazı ("eggshell") zemin, beyaz kartlar,
/// ince çerçeveler, neredeyse siyah yazı, siyah ana düğme; koyu temada aynı düzen ters renklerle. Renkler pencerenin
/// görünümüne göre anında değişir; palet (Kor, Klasik) `ThemeStore` ile seçilir.
@MainActor
public enum Theme {
    /// Pencere ve panel zemini.
    public static var background: Color { dynamic(\.background) }
    /// Kartlar, girişler, araç kutucukları.
    public static var card: Color { dynamic(\.card) }
    /// İnce çerçeve ve ayırıcılar.
    public static var line: Color { dynamic(\.line) }
    /// Soluk yüzey (çipler, bölüm seçici izi, hover).
    public static var soft: Color { dynamic(\.soft) }
    /// Kenar çubuğunda seçili satır.
    public static var selected: Color { dynamic(\.selected) }
    /// Ana yazı.
    public static var ink: Color { dynamic(\.ink) }
    /// Soluk yazı.
    public static var muted: Color { dynamic(\.muted) }
    /// Ana düğme zemini ve üstündeki yazı.
    public static var primary: Color { dynamic(\.primary) }
    public static var onPrimary: Color { dynamic(\.onPrimary) }
    /// Uyarı simgeleri (bkz. `NoticeSeverity.tint`).
    public static var info: Color { dynamic(\.info) }
    public static var attention: Color { dynamic(\.attention) }
    public static var error: Color { dynamic(\.error) }
    /// Gömülü Inter yazı tipinin aile adı (OFL; App/Fonts).
    nonisolated public static let interFamily: String = "Inter Variable"

    /// Seçili takımların verilen rolü (bkz. `ThemeStore.color`).
    private static func dynamic(_ role: KeyPath<ThemeColorSet, UInt32>) -> Color {
        ThemeStore.shared.color(role: role)
    }
}

/// Vurgu renginin seçili paletteki değerleri (bkz. `ThemePalette.accents`); palet değişince okuyan görünümler yenilenir.
@MainActor
public extension PanelAccent {
    /// Düğmeler, seçili öğeler ve vurgu yazısı (Kor'da açık ve koyu görünümde ayrı).
    var color: Color { ThemeStore.shared.accent(self).color }
    /// Vurgu dolgusunun üstündeki yazı ve simge.
    var onColor: Color { ThemeStore.shared.accent(self).on }
    /// Hep koyu yüzeylerde (ada) vurgu: paletin koyu görünüm rengi.
    var colorOnDarkSurface: Color { ThemeStore.shared.accent(self).onDarkSurface }
    /// Sistemin beyaz yazıyla çizdiği dolgular (`.borderedProminent`, kaydırma eylemleri): paletin açık görünüm rengi
    /// (beyaz yazı her görünümde AA; Klasik'te vurgunun kendisi).
    var systemLabelFill: Color { ThemeStore.shared.accent(self).systemLabelFill }

    /// Vurgu yazısı ve simgesinin durduğu soluk zemin: Klasik'te vurgunun `tintOpacity` saydamlığı, Kor'da dolu renk.
    func softFill(tintOpacity: Double) -> Color {
        ThemeStore.shared.accent(self).soft ?? color.opacity(tintOpacity)
    }

    /// Ayarlardaki adı (Kor paletinde turuncu "Kor").
    var displayName: String {
        String(localized: ThemeStore.shared.palette.accents[self].name)
    }
}

/// Seçili yazı tipi ailesinde (varsayılan Inter) verilen boyut ve ağırlık; iPhone'un "Kalın Metin" ayarında
/// daha kalın (bkz. `PanelAppearance.boldText`).
private struct AppFont: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    func body(content: Content) -> some View {
        content.font(appearance.font(size: size, weight: weight))
    }
}

public extension View {
    /// Mac'te tıklanabilir öğede el imleci (iPhone'da imleç yok, değişmez).
    @ViewBuilder
    func linkPointer(isEnabled: Bool) -> some View {
        #if os(macOS)
        pointerStyle(isEnabled ? .link : nil)
        #else
        self
        #endif
    }

    /// Ayarlar › Görünüm'deki yazı tipi ailesinde (varsayılan Inter) yazı.
    func appFont(size: CGFloat, weight: Font.Weight) -> some View {
        modifier(AppFont(size: size, weight: weight))
    }

    /// Kart yüzeyi: zeminden ayrılan beyaz kart, ince çerçeve, çok hafif gölge.
    func cardSurface(cornerRadius: CGFloat) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // Gölge yalnızca sabit zemine: içeriğe uygulansaydı içerik her değiştiğinde (ör. çalma çubuğu saniyede onlarca
        // kez) gölge baştan hesaplanır, pencere sunucusu boşuna yorulurdu.
        return background {
            shape.fill(Theme.card).shadow(color: .black.opacity(0.04), radius: 10, y: 4)
        }
        .overlay(shape.strokeBorder(Theme.line))
    }
}
