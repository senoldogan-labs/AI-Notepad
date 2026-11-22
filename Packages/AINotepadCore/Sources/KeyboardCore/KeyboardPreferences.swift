import Foundation

/// How a finished dictation is written into the field (Settings › Keyboard, "Sesle yazma"). Applied by
/// `keyboardFormatDictation` to the text both dictation routes deliver.
public struct KeyboardDictationOptions: Sendable, Hashable, Codable {
    /// "comma", "question mark", "new line"… become the mark or the line break.
    public let spokenPunctuation: Bool
    /// "first … second …" or "bullet … bullet …" become a numbered or bulleted list.
    public let formatLists: Bool
    /// Fillers ("um", "ıı") and stuttered words ("the the") are dropped.
    public let cleanUp: Bool
    /// Off drops the final period (a question or exclamation mark stays).
    public let endWithPeriod: Bool
    /// Everything in lowercase.
    public let lowercase: Bool

    public init(spokenPunctuation: Bool, formatLists: Bool, cleanUp: Bool, endWithPeriod: Bool, lowercase: Bool) {
        self.spokenPunctuation = spokenPunctuation
        self.formatLists = formatLists
        self.cleanUp = cleanUp
        self.endWithPeriod = endWithPeriod
        self.lowercase = lowercase
    }

    /// The defaults, also used for configs written before these options existed.
    public static let standard: KeyboardDictationOptions = KeyboardDictationOptions(
        spokenPunctuation: true, formatLists: true, cleanUp: true, endWithPeriod: true, lowercase: false
    )
}

/// How strongly a key press taps (Full Access only: iOS gives a keyboard no haptics without it).
public enum KeyboardHapticStrength: String, Sendable, Hashable, Codable, CaseIterable {
    case off
    case light
    case medium
    case strong
}

/// Which side of the space bar the microphone key sits on.
public enum KeyboardMicrophoneSide: String, Sendable, Hashable, Codable, CaseIterable {
    case left
    case right
}

/// The keyboard's typing preferences (Settings › Keyboard).
public struct KeyboardTypingOptions: Sendable, Hashable, Codable {
    public let haptics: KeyboardHapticStrength
    public let microphoneSide: KeyboardMicrophoneSide
    /// Capitalizes the start of sentences (as the field asks); off types lowercase until Shift.
    public let autoCapitalization: Bool
    /// The enlarged letter above the finger while a key is down (long-press alternates always show).
    public let keyPopups: Bool

    public init(haptics: KeyboardHapticStrength, microphoneSide: KeyboardMicrophoneSide, autoCapitalization: Bool, keyPopups: Bool) {
        self.haptics = haptics
        self.microphoneSide = microphoneSide
        self.autoCapitalization = autoCapitalization
        self.keyPopups = keyPopups
    }

    /// The defaults, also used for configs written before these options existed.
    public static let standard: KeyboardTypingOptions = KeyboardTypingOptions(
        haptics: .off, microphoneSide: .left, autoCapitalization: true, keyPopups: true
    )
}
