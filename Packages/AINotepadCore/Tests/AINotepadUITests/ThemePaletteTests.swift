import CoreGraphics
import Testing
@testable import AINotepadUI

@Suite struct ThemePaletteTests {
    private let emberSets: [(name: String, colors: ThemeColorSet)] = [("emberLight", .emberLight), ("emberDark", .emberDark)]

    /// Kor'da bütün yazı çiftleri AA (en az 4,5:1): ana ve soluk yazı her yüzeyde, ana düğme yazısı, uyarı simgeleri.
    @Test func emberTextPairsMeetAA() {
        for (name, colors) in emberSets {
            for (surface, hex) in surfaces(colors) {
                for (role, foreground) in [("ink", colors.ink), ("muted", colors.muted), ("info", colors.info), ("attention", colors.attention), ("error", colors.error)] {
                    let ratio: Double = contrastRatio(foreground: foreground, background: hex)
                    #expect(ratio >= 4.5, "\(name) \(role) on \(surface): \(ratio)")
                }
            }
            #expect(contrastRatio(foreground: colors.onPrimary, background: colors.primary) >= 4.5, "\(name) onPrimary")
        }
    }

    /// Kor vurguları her açık ve koyu temanın yüzeylerinde, kendi soluk zemininde ve dolgusunun üstündeki yazıyla AA;
    /// soluk zeminde soluk yazı da okunur.
    @Test func emberAccentsMeetAAOnEverySurface() {
        let lightSets: [ThemeColorSet] = [.emberLight, .sand]
        let darkSets: [ThemeColorSet] = [.emberDark, .midnight, .graphite]
        for accent in PanelAccent.allCases {
            let colors: AccentColors = ThemePalette.ember.accents[accent]
            guard case .solid(let softLight, let softDark) = colors.soft else {
                Issue.record("\(accent) has no solid soft fill")
                continue
            }
            for set in lightSets {
                for (surface, hex) in surfaces(set) + [("accentSoft", softLight)] {
                    #expect(contrastRatio(foreground: colors.light, background: hex) >= 4.5, "\(accent) light on \(surface)")
                }
            }
            for set in darkSets {
                for (surface, hex) in surfaces(set) + [("accentSoft", softDark)] {
                    #expect(contrastRatio(foreground: colors.dark, background: hex) >= 4.5, "\(accent) dark on \(surface)")
                }
            }
            #expect(contrastRatio(foreground: colors.onLight, background: colors.light) >= 4.5, "\(accent) on light fill")
            #expect(contrastRatio(foreground: colors.onDark, background: colors.dark) >= 4.5, "\(accent) on dark fill")
            #expect(contrastRatio(foreground: ThemeColorSet.emberLight.muted, background: softLight) >= 4.5, "\(accent) muted on light soft")
            #expect(contrastRatio(foreground: ThemeColorSet.emberDark.muted, background: softDark) >= 4.5, "\(accent) muted on dark soft")
        }
    }

    /// Text and icons on a filled accent (`PanelAccent.onColor`: accent pills, the paywall button, checkmarks) in every
    /// palette and mode. Ember reaches AA (4.5:1) everywhere; its dark mode needs dark ink, white on "Kor" E39A72 is
    /// about 2.3:1. Classic keeps the pre-palette white on its single accent: AA for blue, purple and pink, and the
    /// large-text/UI floor (3:1) for green 0CA678 and orange E8590C, which the Classic look would have to change to pass.
    @Test func onAccentTextIsReadableInEveryPaletteAndMode() {
        for accent in PanelAccent.allCases {
            let ember: AccentColors = ThemePalette.ember.accents[accent]
            #expect(contrastRatio(foreground: ember.onLight, background: ember.light) >= 4.5, "ember \(accent) light")
            #expect(contrastRatio(foreground: ember.onDark, background: ember.dark) >= 4.5, "ember \(accent) dark")
            let classic: AccentColors = ThemePalette.classic.accents[accent]
            let classicFloor: Double = [PanelAccent.green, .orange].contains(accent) ? 3.0 : 4.5
            #expect(contrastRatio(foreground: classic.onLight, background: classic.light) >= classicFloor, "classic \(accent) light")
            #expect(contrastRatio(foreground: classic.onDark, background: classic.dark) >= classicFloor, "classic \(accent) dark")
        }
    }

    /// Uyarı renginin sistem dolgusu (`NoticeSeverity.systemLabelFill`, paletin açık takımı) üstünde beyaz yazı iki
    /// palette de AA.
    @Test func severityFillsKeepWhiteLabelsReadable() {
        for palette in [ThemePalette.ember, ThemePalette.classic] {
            for (role, fill) in [("info", palette.light.info), ("attention", palette.light.attention), ("error", palette.light.error)] {
                let ratio: Double = contrastRatio(foreground: 0xFFFFFF, background: fill)
                #expect(ratio >= 4.5, "\(palette.family) \(role) fill: \(ratio)")
            }
        }
    }

    /// Speaker names and badge numbers (`personTextColor`): AA on every surface of every light and dark theme and on
    /// the badge's 16% tint of the person's colour.
    @Test func personTextColorsMeetAAOnEverySurface() {
        let lightSets: [ThemeColorSet] = [.emberLight, .light, .paper, .sand]
        let darkSets: [ThemeColorSet] = [.emberDark, .dark, .midnight, .graphite]
        let tints: [UInt32] = [0x5E8C78, 0xB98552, 0xAD6878, 0x7770A6, 0x5A889E, 0x878A55, 0x5A6EA8]
        let pairs: [(light: UInt32, dark: UInt32)] = PersonTextPalette.colors + [PersonTextPalette.me]
        #expect(pairs.count == tints.count)
        for (pair, tint) in zip(pairs, tints) {
            for set in lightSets {
                for (surface, hex) in surfaces(set) + surfaces(set).map({ ("\($0.0)+tint", mixed(hex: $0.1, with: tint, amount: 0.16)) }) {
                    #expect(contrastRatio(foreground: pair.light, background: hex) >= 4.5, "\(pair.light) on \(surface)")
                }
            }
            for set in darkSets {
                for (surface, hex) in surfaces(set) + surfaces(set).map({ ("\($0.0)+tint", mixed(hex: $0.1, with: tint, amount: 0.16)) }) {
                    #expect(contrastRatio(foreground: pair.dark, background: hex) >= 4.5, "\(pair.dark) on \(surface)")
                }
            }
        }
    }

    /// Klasik, paletten önceki görünümün değerlerini aynen taşır.
    @Test func classicKeepsThePreviousValues() {
        let classic: ThemePalette = .classic
        #expect(classic.light == .light && classic.dark == .dark)
        #expect(classic.themes == AppTheme.allCases)
        #expect(classic.brand == .film)
        #expect(PanelAccent.allCases.map { classic.accents[$0].light } == [0x3B5BDB, 0x0CA678, 0x7048E8, 0xE8590C, 0xD6336C])
        #expect(PanelAccent.allCases.allSatisfy { classic.accents[$0].soft == .tint && classic.accents[$0].onLight == 0xFFFFFF })
        #expect(classic.films[.sunset] == FilmColors(base: 0xF89870, clouds: [0xFFC2A4, 0xFFF3E6, 0xC68FE8, 0xF27A52]))
        #expect(ThemeColorSet.light.attention == 0x9A5B00 && ThemeColorSet.dark.error == 0xFF8A7A)
    }

    /// Kor'da Kâğıt yok; geri kalan temalar iki palette de var.
    @Test func emberOffersEveryThemeButPaper() {
        #expect(ThemePalette.ember.themes == [.system, .light, .dark, .sand, .midnight, .graphite])
        #expect(ThemePalette.ember.colorSets(theme: .system) == (ThemeColorSet.emberLight, ThemeColorSet.emberDark))
        #expect(ThemePalette.ember.colorSets(theme: .midnight) == (ThemeColorSet.emberLight, ThemeColorSet.midnight))
        #expect(ThemePalette.ember.swatchSet(theme: .midnight) == .midnight)
        #expect(ThemePalette.ember.swatchSet(theme: .dark) == .emberDark)
        #expect(ThemePalette.classic.swatchSet(theme: .paper) == .paper)
    }

    /// Koyu temada da açık görünümlü adalar (Kor'daki krem "Bir şey sor" hapı, pastel kartlar) açık takımla çizilir:
    /// iki yuva da koyu takım olunca hapın yazısı krem üstüne krem kalıyordu. Uygulama temanın görünümünü kendisi zorlar.
    @Test func fixedThemesKeepTheOppositeSetForForcedIslands() {
        for palette in [ThemePalette.ember, ThemePalette.classic] {
            for theme in palette.themes where theme.isDark == true {
                #expect(palette.colorSets(theme: theme).light == palette.light)
            }
            for theme in palette.themes where theme.isDark == false {
                #expect(palette.colorSets(theme: theme).dark == palette.dark)
            }
            #expect(palette.colorSets(theme: .dark).light == palette.light)
            #expect(palette.colorSets(theme: .light).dark == palette.dark)
        }
    }

    /// Saklanan değerler: palet yokken Kâğıt kullanıcısı Klasik'te kalır, ötekiler Kor'a geçer; Kor'da Kâğıt Açık'tır.
    @Test func storedValuesResolveToAChoice() {
        #expect(resolvedThemeChoice(storedFamily: nil, storedTheme: "paper", defaultTheme: .light) == ThemeChoice(family: .classic, theme: .paper))
        #expect(resolvedThemeChoice(storedFamily: nil, storedTheme: "dark", defaultTheme: .light) == ThemeChoice(family: .ember, theme: .dark))
        #expect(resolvedThemeChoice(storedFamily: nil, storedTheme: nil, defaultTheme: .system) == ThemeChoice(family: .ember, theme: .system))
        #expect(resolvedThemeChoice(storedFamily: "ember", storedTheme: "paper", defaultTheme: .system) == ThemeChoice(family: .ember, theme: .light))
        #expect(resolvedThemeChoice(storedFamily: "classic", storedTheme: "paper", defaultTheme: .system) == ThemeChoice(family: .classic, theme: .paper))
        #expect(resolvedThemeChoice(storedFamily: "classic", storedTheme: "graphite", defaultTheme: .light) == ThemeChoice(family: .classic, theme: .graphite))
        #expect(resolvedThemeChoice(storedFamily: "neon", storedTheme: "bogus", defaultTheme: .light) == ThemeChoice(family: .ember, theme: .light))
    }

    @Test func contourLinesAreDeterministicAndNeverCross() {
        let size: CGSize = CGSize(width: 1004, height: 200)
        let lines: [[CGPoint]] = contourPaths(seed: "kayit-karti", size: size, count: 5)
        #expect(lines == contourPaths(seed: "kayit-karti", size: size, count: 5))
        #expect(lines != contourPaths(seed: "iphone-dock", size: size, count: 5))
        #expect(lines.count == 5)
        for line in lines {
            #expect(line.count == 97)
            #expect(line.first?.x == 0 && line.last?.x == size.width)
        }
        for (upper, lower) in zip(lines, lines.dropFirst()) {
            for (a, b) in zip(upper, lower) {
                #expect(b.y >= a.y + size.height * 0.022 - 0.0001)
            }
        }
        #expect(contourPaths(seed: "x", size: size, count: 0).isEmpty)
    }

    private func surfaces(_ colors: ThemeColorSet) -> [(String, UInt32)] {
        [("background", colors.background), ("card", colors.card), ("soft", colors.soft), ("selected", colors.selected)]
    }

    /// `hex` with `amount` of `tint` painted over it (an opacity fill), per sRGB channel.
    private func mixed(hex: UInt32, with tint: UInt32, amount: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { (result: UInt32, shift: UInt32) -> UInt32 in
            let base: Double = Double((hex >> shift) & 0xFF)
            let top: Double = Double((tint >> shift) & 0xFF)
            return result | (UInt32((base + (top - base) * amount).rounded()) << shift)
        }
    }
}
