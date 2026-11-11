import Foundation
import Testing
@testable import AINotepadUI

@Suite struct EmberTintTests {
    private let bakedStops: [UInt32] = [
        EmberStop.e900, EmberStop.e700, EmberStop.e600, EmberStop.e500, EmberStop.e400, EmberStop.e300, EmberStop.e200, EmberStop.e100,
    ]

    private func values(_ stops: EmberBandStops) -> [UInt32] {
        [stops.e900, stops.e700, stops.e600, stops.e500, stops.e400, stops.e300, stops.e200, stops.e100]
    }

    /// The Ember (orange) accent keeps today's band, orb and contour colours exactly.
    @Test func emberAccentKeepsTodaysColours() {
        #expect(values(emberBandStops(accent: .orange)) == bakedStops)
        for hex: UInt32 in [0xC4A07A, 0xFAECDC, 0xF4E3CF, 0xCF9670, 0x5A2C1D, 0xE9C9AC] {
            #expect(emberTinted(hex: hex, accent: .orange) == hex)
        }
        #expect(EmberOrbGradient.recordButton(accent: .orange).stops.map(\.color) == [0xE9C9AC, EmberStop.e500, EmberStop.e600, EmberStop.e900])
        #expect(EmberBandColors.light(accent: .orange).glow == 0xC4A07A && EmberBandColors.dark(accent: .orange).deep == EmberStop.e900)
    }

    /// Other accents turn the hue only: every stop keeps its perceived lightness (OKLCH L within 0.01, so dark stops stay
    /// dark and light stops light) and lands near the accent's hue.
    @Test func otherAccentsKeepLightnessAndTakeTheAccentHue() {
        for accent in PanelAccent.allCases where accent != .orange {
            let tinted: [UInt32] = values(emberBandStops(accent: accent))
            #expect(tinted != bakedStops, "\(accent)")
            let accentHue: Double = oklch(hex: ThemePalette.ember.accents[accent].light).hue
            for (source, result) in zip(bakedStops, tinted) {
                #expect(abs(oklch(hex: source).lightness - oklch(hex: result).lightness) < 0.01, "\(accent) \(String(source, radix: 16))")
                // The darkest copper stops have the most chroma; their hue must follow the accent's.
                if oklch(hex: result).chroma > 0.04 {
                    let delta: Double = abs(remainder(oklch(hex: result).hue - accentHue, 2 * Double.pi))
                    #expect(delta < 0.6, "\(accent) \(String(result, radix: 16)) hue delta \(delta)")
                }
            }
        }
    }

    /// The white microphone on the record orb stays readable (AA 4.5:1) on the orb's middle and outer stops in every
    /// accent, and the white "Finish" text on the widget fill (the Ember accent's light colour) is AA too.
    @Test func whiteGlyphsOnTheOrbMeetAA() {
        for accent in PanelAccent.allCases {
            let stops: [UInt32] = EmberOrbGradient.recordButton(accent: accent).stops.map(\.color)
            for hex in stops.dropFirst(2) {
                #expect(contrastRatio(foreground: 0xFFFFFF, background: hex) >= 4.5, "\(accent) \(String(hex, radix: 16))")
            }
            #expect(contrastRatio(foreground: 0xFFFFFF, background: ThemePalette.ember.accents[accent].light) >= 4.5, "\(accent) finish")
        }
    }

    /// Colours outside sRGB at the turned hue keep their lightness and hue and lose chroma until they fit.
    @Test func outOfGamutColoursReduceChroma() {
        let vivid: OKLCH = OKLCH(lightness: 0.6, chroma: 0.4, hue: 2.5)
        let fitted: OKLCH = oklch(hex: srgbHex(oklch: vivid))
        #expect(abs(fitted.lightness - 0.6) < 0.01)
        #expect(fitted.chroma < 0.4)
        #expect(abs(remainder(fitted.hue - 2.5, 2 * Double.pi)) < 0.05)
        #expect(srgbHex(oklch: oklch(hex: 0x93553D)) == 0x93553D)
    }
}
