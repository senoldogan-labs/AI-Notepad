import SwiftUI

/// Renk paleti: Kor (sıcak krem ve bakır; varsayılan) ya da Klasik (önceki beyaz görünüm, pastel kapaklar, turuncu vurgu).
/// Açık/Koyu/Sistem teması ayrı seçimdir ve iki palette de çalışır. Mac ve iPhone aynı ayarı
/// (`appearance.themeFamily`) kullanır.
public enum ThemeFamily: String, CaseIterable, Sendable {
    case ember
    case classic

    /// Arayüzdeki adı.
    public var displayName: String {
        switch self {
        case .ember: String(localized: "Kor")
        case .classic: String(localized: "Klasik")
        }
    }

    /// Paletin renkleri.
    public var palette: ThemePalette {
        switch self {
        case .ember: .ember
        case .classic: .classic
        }
    }
}

/// Saklanan tema seçimi: palet ve tema.
public struct ThemeChoice: Equatable, Sendable {
    public let family: ThemeFamily
    public let theme: AppTheme

    public init(family: ThemeFamily, theme: AppTheme) {
        self.family = family
        self.theme = theme
    }
}

/// Saklanan değerlerden tema seçimi. Palet saklı değilse (paletten önceki sürüm) Kâğıt teması seçmiş kullanıcı Klasik'te
/// kalır (görünümü değişmez), diğerleri Kor'a geçer. Tanınmayan tema `defaultTheme`'dir; palette olmayan tema (Kor'da
/// Kâğıt) Açık'tır, saklı değer silinmez (Klasik'e dönünce Kâğıt geri gelir). Saf fonksiyondur.
public func resolvedThemeChoice(storedFamily: String?, storedTheme: String?, defaultTheme: AppTheme) -> ThemeChoice {
    let theme: AppTheme = storedTheme.flatMap(AppTheme.init(rawValue:)) ?? defaultTheme
    let family: ThemeFamily = storedFamily.flatMap(ThemeFamily.init(rawValue:)) ?? (theme == .paper ? .classic : .ember)
    return ThemeChoice(family: family, theme: family.palette.themes.contains(theme) ? theme : .light)
}

/// Vurgu renginin bir paletteki değerleri: açık ve koyu görünümde renk, dolgusunun üstündeki yazı, soluk zemin ve adı.
public struct AccentColors: Sendable {
    public let light: UInt32
    public let dark: UInt32
    public let onLight: UInt32
    public let onDark: UInt32
    public let soft: AccentSoft
    public let name: LocalizedStringResource
}

/// Vurgunun soluk zemini: vurgunun yarı saydamı (Klasik; opaklığı kullanıldığı yer verir) ya da açık ve koyu görünüm
/// için dolu renk (Kor: üstündeki vurgu yazısı her yerde aynı karşıtlıkta kalır).
public enum AccentSoft: Equatable, Sendable {
    case tint
    case solid(light: UInt32, dark: UInt32)
}

/// Bir paletin beş vurgu rengi.
public struct AccentSet: Sendable {
    public let blue: AccentColors
    public let green: AccentColors
    public let purple: AccentColors
    public let orange: AccentColors
    public let pink: AccentColors

    public subscript(accent: PanelAccent) -> AccentColors {
        switch accent {
        case .blue: blue
        case .green: green
        case .purple: purple
        case .orange: orange
        case .pink: pink
        }
    }
}

/// Bir film ailesinin renkleri: zemin ve dört bulut (açık ton, ışık, karşıt ton, derin ton).
public struct FilmColors: Equatable, Sendable {
    public let base: UInt32
    public let clouds: [UInt32]
}

/// Bir paletin altı film ailesi (kapaklar ve kartlar); aile adları yuva adıdır, renkler palete göre.
public struct FilmSet: Equatable, Sendable {
    public let sunset: FilmColors
    public let coral: FilmColors
    public let ocean: FilmColors
    public let mint: FilmColors
    public let rose: FilmColors
    public let violet: FilmColors

    public subscript(palette: FilmPalette) -> FilmColors {
        switch palette {
        case .sunset: sunset
        case .coral: coral
        case .ocean: ocean
        case .mint: mint
        case .rose: rose
        case .violet: violet
        }
    }
}

/// Marka yüzeyleri (iPhone'daki kayıt düğmesi, alt bant ve giriş kartı): film gradyanı ve vurgu renginde düğme
/// (Klasik) ya da Kor bandı, kontur çizgileri ve Kor küresi (vurgudan bağımsız).
public enum BrandSurface: Equatable, Sendable {
    case film
    case ember
}

/// Bir renk paletinin tamamı: Açık ve Koyu temaların renk takımları, seçilebilen temalar, vurgu renkleri, film aileleri
/// ve marka yüzeyi. Saf veridir.
public struct ThemePalette: Sendable {
    public let family: ThemeFamily
    public let light: ThemeColorSet
    public let dark: ThemeColorSet
    public let themes: [AppTheme]
    public let accents: AccentSet
    public let films: FilmSet
    public let brand: BrandSurface

    /// Temanın açık ve koyu görünümdeki renk takımları; sabit görünümlü temalarda ikisi aynı. Saf fonksiyondur.
    public func colorSets(theme: AppTheme) -> (light: ThemeColorSet, dark: ThemeColorSet) {
        switch theme {
        case .system: (light, dark)
        case .light: (light, light)
        case .dark: (dark, dark)
        case .paper: (.paper, .paper)
        case .sand: (.sand, .sand)
        case .midnight: (.midnight, .midnight)
        case .graphite: (.graphite, .graphite)
        }
    }

    /// Klasik: palet eklenmeden önceki görünümün aynısı (ElevenLabs beyazı, pastel filmler, tek renkli vurgular).
    public static let classic: ThemePalette = ThemePalette(
        family: .classic, light: .light, dark: .dark, themes: AppTheme.allCases,
        accents: AccentSet(
            blue: classicAccent(hex: 0x3B5BDB, name: "Mavi"),
            green: classicAccent(hex: 0x0CA678, name: "Yeşil"),
            purple: classicAccent(hex: 0x7048E8, name: "Mor"),
            orange: classicAccent(hex: 0xE8590C, name: "Turuncu"),
            pink: classicAccent(hex: 0xD6336C, name: "Pembe")
        ),
        films: FilmSet(
            sunset: FilmColors(base: 0xF89870, clouds: [0xFFC2A4, 0xFFF3E6, 0xC68FE8, 0xF27A52]),
            coral: FilmColors(base: 0xF8B87D, clouds: [0xFFD8AF, 0xFFF6E8, 0xFA8DA0, 0xE89954]),
            ocean: FilmColors(base: 0x92ADF6, clouds: [0xC0CFFE, 0xF4F1FF, 0xF1ABD5, 0x6E8DEE]),
            mint: FilmColors(base: 0x8FD8B2, clouds: [0xC2EDD6, 0xF6F7EA, 0xF4D88C, 0x55BB8A]),
            rose: FilmColors(base: 0xF390A5, clouds: [0xFEC0CD, 0xFFF1EC, 0xA8BFF8, 0xE66C90]),
            violet: FilmColors(base: 0xBEA1F4, clouds: [0xDBC9FD, 0xFFF4EE, 0xFCB18E, 0x9A6FE3])
        ),
        brand: .film
    )

    /// Kor: krem ve sıcak siyah zemin, bakır vurgu (açık ve koyu görünümde ayrı, her yüzeyde AA), sıcak film aileleri
    /// (kor, kil, alacakaranlık, adaçayı, gül kurusu, kum), Kor bandı. Kâğıt Kor Açık'a çok yakın olduğu için listede yok.
    public static let ember: ThemePalette = ThemePalette(
        family: .ember, light: .emberLight, dark: .emberDark, themes: AppTheme.allCases.filter { $0 != .paper },
        accents: AccentSet(
            blue: emberAccent(light: 0x3755D0, dark: 0x8EA4F5, softLight: 0xEBEAF1, softDark: 0x2D2E39, name: "Mavi"),
            green: emberAccent(light: 0x07704F, dark: 0x4FCB9E, softLight: 0xE6EDE4, softDark: 0x22342B, name: "Yeşil"),
            purple: emberAccent(light: 0x6640D6, dark: 0xB7A2FA, softLight: 0xF0E8F2, softDark: 0x332D3A, name: "Mor"),
            orange: emberAccent(light: 0x984B2C, dark: 0xE39A72, softLight: 0xF5E8DD, softDark: 0x3A2419, name: "Kor"),
            pink: emberAccent(light: 0xB0245A, dark: 0xF28DB3, softLight: 0xF7E6E6, softDark: 0x3D2A2E, name: "Pembe")
        ),
        films: FilmSet(
            sunset: FilmColors(base: 0xB07A58, clouds: [0xBD976F, 0xE8D3B8, 0xA5664B, 0x93553D]),
            coral: FilmColors(base: 0xC98A64, clouds: [0xD9A47E, 0xF0DCC4, 0xB07872, 0x8E4A33]),
            ocean: FilmColors(base: 0xA88A97, clouds: [0xC2A8AF, 0xE9D6D6, 0xB07A58, 0x6A5267]),
            mint: FilmColors(base: 0xA9AC92, clouds: [0xBFC0A8, 0xE4E2CF, 0xD2B48E, 0x6C735C]),
            rose: FilmColors(base: 0xB07872, clouds: [0xC6958B, 0xE9C9C1, 0xBD976F, 0x7A4044]),
            violet: FilmColors(base: 0xCDB08A, clouds: [0xD9C19E, 0xF2E6D2, 0xBD976F, 0x8A6E4E])
        ),
        brand: .ember
    )
}

/// Klasik vurgu: iki görünümde tek renk, üstünde beyaz, soluk zemin yarı saydam vurgu.
private func classicAccent(hex: UInt32, name: LocalizedStringResource) -> AccentColors {
    AccentColors(light: hex, dark: hex, onLight: 0xFFFFFF, onDark: 0xFFFFFF, soft: .tint, name: name)
}

/// Kor vurgusu: açık ve koyu görünümde ayrı renk; dolgunun üstünde açıkta krem, koyuda sıcak siyah; dolu soluk zemin.
private func emberAccent(light: UInt32, dark: UInt32, softLight: UInt32, softDark: UInt32, name: LocalizedStringResource) -> AccentColors {
    AccentColors(light: light, dark: dark, onLight: 0xFFFBF5, onDark: 0x141110, soft: .solid(light: softLight, dark: softDark), name: name)
}

/// Saklanan ham palet ve tema değerleri (ayar değişikliğini tek değerle izlemek için).
public struct ThemeChoiceKey: Equatable, Sendable {
    public let family: String?
    public let theme: String

    public init(family: String?, theme: String) {
        self.family = family
        self.theme = theme
    }
}
