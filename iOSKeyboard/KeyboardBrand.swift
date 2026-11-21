import KeyboardCore
import SwiftUI
import UIKit

/// The keyboard's accent colours from the app's theme (`KeyboardTheme`, written by Gistsmith; Ember before it has):
/// the prominent return key, the microphone key, the swipe trail, the dictation panel and the panels' accent
/// (`Color.accentColor` follows the hosting views' tint).
struct KeyboardBrand: Equatable {
    let theme: KeyboardTheme

    /// Glyphs, lines and text in the accent.
    var tint: UIColor {
        dynamic(light: theme.tintLight, dark: theme.tintDark)
    }

    /// Big accent surfaces (return key, finish button, the microphone key while listening).
    var fill: UIColor {
        dynamic(light: theme.fillLight, dark: theme.fillDark)
    }

    /// The ink on `fill`.
    var onFill: UIColor {
        dynamic(light: theme.onFillLight, dark: theme.onFillDark)
    }

    func tint(isDark: Bool) -> Color {
        Color(uiColor: color(hex: isDark ? theme.tintDark : theme.tintLight))
    }

    func fill(isDark: Bool) -> Color {
        Color(uiColor: color(hex: isDark ? theme.fillDark : theme.fillLight))
    }

    func onFill(isDark: Bool) -> Color {
        Color(uiColor: color(hex: isDark ? theme.onFillDark : theme.onFillLight))
    }

    private func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        let lightColor: UIColor = color(hex: light)
        let darkColor: UIColor = color(hex: dark)
        return UIColor { (traits: UITraitCollection) -> UIColor in traits.userInterfaceStyle == .dark ? darkColor : lightColor }
    }

    private func color(hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
