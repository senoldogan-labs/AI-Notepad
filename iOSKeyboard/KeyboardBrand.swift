import UIKit

/// Gistsmith's copper (the Ember band's stops, `AINotepadUI.EmberStop`) on the keyboard: the prominent return key, the
/// microphone key, the swipe trail and the panels' accent (`Color.accentColor` follows the hosting views' tint).
enum KeyboardBrand {
    /// Fills with white text on them: e500 in light (4.6:1 with white), e600 in dark.
    static let copperFill: UIColor = UIColor { (traits: UITraitCollection) -> UIColor in
        traits.userInterfaceStyle == .dark ? hex(0x93553D) : hex(0xA5664B)
    }
    /// Glyphs and lines on the keys: e500 in light, e300 in dark (readable on the dark caps).
    static let copperTint: UIColor = UIColor { (traits: UITraitCollection) -> UIColor in
        traits.userInterfaceStyle == .dark ? hex(0xBD976F) : hex(0xA5664B)
    }

    private static func hex(_ value: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1
        )
    }
}
