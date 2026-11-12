import SwiftUI

/// Renk paleti: Kor (sıcak krem ve bakır; varsayılan), Klasik (önceki beyaz görünüm, pastel kapaklar, turuncu vurgu) ya da
/// Zeytin (düz sıcak kömür zemin, limon-zeytin vurgu, sayfa başlıklarında serif yazı).
/// Açık/Koyu/Sistem teması ayrı seçimdir ve iki palette de çalışır. Mac ve iPhone aynı ayarı
/// (`appearance.themeFamily`) kullanır.
public enum ThemeFamily: String, CaseIterable, Sendable {
    case ember
    case classic
    case olive

    /// Arayüzdeki adı.
    public var displayName: String {
        switch self {
        case .ember: String(localized: "Kor")
        case .classic: String(localized: "Klasik")
        case .olive: String(localized: "Zeytin")
        }
    }

    /// Paletin renkleri.
    public var palette: ThemePalette {
        switch self {
        case .ember: .ember
        case .classic: .classic
        case .olive: .olive
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

/// Saklanan değerlerden tema seçimi (tema `resolvedAppTheme` ile). Palet saklı değilse (paletten önceki sürüm) Kâğıt
/// teması seçmiş kullanıcı Klasik'te kalır (vurgu ve kapakları değişmez), diğerleri Kor'a geçer. Saf fonksiyondur.
public func resolvedThemeChoice(storedFamily: String?, storedTheme: String?, defaultTheme: AppTheme) -> ThemeChoice {
    let theme: AppTheme = resolvedAppTheme(stored: storedTheme, defaultTheme: defaultTheme)
    let family: ThemeFamily = storedFamily.flatMap(ThemeFamily.init(rawValue:)) ?? (storedTheme == "paper" ? .classic : .ember)
    return ThemeChoice(family: family, theme: theme)
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

/// Marka yüzeyleri (Mac'teki kayıt çubuğu ve küresi; iPhone'daki kayıt düğmesi, alt bant ve giriş kartı): film gradyanı ve
/// vurgu renginde küre (Klasik) ya da Kor bandı, kontur çizgileri ve Kor küresi (vurgudan bağımsız). Kısayol kutuları
/// ve kapaklar paletin film ailelerini kullanır.
public enum BrandSurface: Equatable, Sendable {
    case film
    case ember
    /// Düz, gradyansız ve dokusuz: vurgu renginde dolu yüzey (Zeytin).
    case flat
}

/// Büyük sayfa başlıklarının yazısı: seçili yazı tipi ailesi (Inter varsayılanda) ya da paletin kendi serif yazısı.
/// Serif yalnızca varsayılan Inter seçiliyken uygulanır; kullanıcı başka bir aile seçtiyse onunla yazılır.
public enum TitleFace: Equatable, Sendable {
    case body
    case serif
}

/// Bir renk paletinin tamamı: Açık ve Koyu temaların renk takımları, vurgu renkleri, film aileleri ve marka yüzeyi. Saf
/// veridir.
public struct ThemePalette: Sendable {
    public let family: ThemeFamily
    public let light: ThemeColorSet
    public let dark: ThemeColorSet
    public let accents: AccentSet
    public let films: FilmSet
    public let brand: BrandSurface
    public let titleFace: TitleFace

    /// Ayarlardaki örnekte görünen takım: Koyu'da koyu takım, ötekilerde açık takım (Sistem örneği koyuyu çaprazına
    /// çizer). Saf fonksiyondur.
    public func swatchSet(theme: AppTheme) -> ThemeColorSet {
        theme.isDark == true ? dark : light
    }

    /// Klasik: palet eklenmeden önceki görünümün aynısı (ElevenLabs beyazı, pastel filmler, tek renkli vurgular).
    public static let classic: ThemePalette = ThemePalette(
        family: .classic, light: .light, dark: .dark,
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
        brand: .film, titleFace: .body
    )

    /// Kor: krem ve sıcak siyah zemin, bakır vurgu (açık ve koyu görünümde ayrı, her yüzeyde AA), sıcak film aileleri
    /// (kor, kil, alacakaranlık, adaçayı, gül kurusu, kum), Kor bandı.
    public static let ember: ThemePalette = ThemePalette(
        family: .ember, light: .emberLight, dark: .emberDark,
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
        brand: .ember, titleFace: .body
    )

    /// Zeytin: düz sıcak kömür (koyu) ya da kırık beyaz (açık) zemin, limon-zeytin vurgu (varsayılan "Zeytin" yuvası turuncunun
    /// yerindedir; açıkta metin ve simge için koyulaştırılmış zeytin), gradyansız yüzeyler, sayfa başlıklarında serif.
    public static let olive: ThemePalette = ThemePalette(
        family: .olive, light: .oliveLight, dark: .oliveDark,
        accents: AccentSet(
            blue: oliveAccent(light: 0x3755D0, dark: 0x93A8F5, softLight: 0xE6E9F4, softDark: 0x2D3040, name: "Mavi"),
            green: oliveAccent(light: 0x07704F, dark: 0x5BD1A4, softLight: 0xE2EEE6, softDark: 0x253A30, name: "Yeşil"),
            purple: oliveAccent(light: 0x6640D6, dark: 0xB7A2FA, softLight: 0xECE8F5, softDark: 0x35304A, name: "Mor"),
            orange: oliveAccent(light: 0x5F6B14, dark: 0xB5C447, softLight: 0xE9EDCB, softDark: 0x45472A, name: "Zeytin"),
            pink: oliveAccent(light: 0xB0245A, dark: 0xF28DB3, softLight: 0xF4E4E8, softDark: 0x40292F, name: "Pembe")
        ),
        films: FilmSet(
            sunset: FilmColors(base: 0x8E8A5A, clouds: [0xA6A272, 0xD8D5B4, 0x7A7A4A, 0x5E6038]),
            coral: FilmColors(base: 0xA48D6C, clouds: [0xBBA585, 0xE4D8C0, 0x8F7A5C, 0x6B5A40]),
            ocean: FilmColors(base: 0x8A9A98, clouds: [0xA4B2B0, 0xD9E0DD, 0x73827F, 0x55625F]),
            mint: FilmColors(base: 0x93A079, clouds: [0xAAB68F, 0xDCE3C9, 0x7C8963, 0x5C6747]),
            rose: FilmColors(base: 0xA98A84, clouds: [0xC0A29B, 0xE6D4CE, 0x91726C, 0x6D524E]),
            violet: FilmColors(base: 0xB7AED2, clouds: [0xCFC8E4, 0xE3DDF5, 0x9F95BF, 0x7C7399])
        ),
        brand: .flat, titleFace: .serif
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

/// Zeytin vurgusu: açıkta koyulaştırılmış renk üstünde krem, koyuda parlak renk üstünde neredeyse siyah (#1E1F14) yazı; dolu soluk
/// zemin.
private func oliveAccent(light: UInt32, dark: UInt32, softLight: UInt32, softDark: UInt32, name: LocalizedStringResource) -> AccentColors {
    AccentColors(light: light, dark: dark, onLight: 0xFAF9F4, onDark: 0x1E1F14, soft: .solid(light: softLight, dark: softDark), name: name)
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
