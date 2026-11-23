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
    /// As spoken, or polished on the iPhone by Apple Intelligence after the rules above (`KeyboardPolisher`). Nil in
    /// configs from apps before this field (as spoken).
    public let style: KeyboardDictationStyle?

    /// Options written as spoken.
    public init(spokenPunctuation: Bool, formatLists: Bool, cleanUp: Bool, endWithPeriod: Bool, lowercase: Bool) {
        self.spokenPunctuation = spokenPunctuation
        self.formatLists = formatLists
        self.cleanUp = cleanUp
        self.endWithPeriod = endWithPeriod
        self.lowercase = lowercase
        self.style = nil
    }

    public init(spokenPunctuation: Bool, formatLists: Bool, cleanUp: Bool, endWithPeriod: Bool, lowercase: Bool, style: KeyboardDictationStyle) {
        self.spokenPunctuation = spokenPunctuation
        self.formatLists = formatLists
        self.cleanUp = cleanUp
        self.endWithPeriod = endWithPeriod
        self.lowercase = lowercase
        self.style = style
    }

    /// The defaults, also used for configs written before these options existed.
    public static let standard: KeyboardDictationOptions = KeyboardDictationOptions(
        spokenPunctuation: true, formatLists: true, cleanUp: true, endWithPeriod: true, lowercase: false
    )
}

/// How a dictation is written (Settings › Keyboard, "Yazım biçimi").
public enum KeyboardDictationStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// Only the rules of `KeyboardDictationOptions` (`keyboardFormatDictation`).
    case asSpoken
    /// The rules, then Apple Intelligence on the iPhone fixes misheard words, grammar and punctuation, keeping the
    /// meaning and the language and adding nothing (`KeyboardPolisher`).
    case polished
}

/// What Gistsmith Keyboard shows: every key, or only a slim dictation bar (Settings › Keyboard, "Klavye türü").
public enum KeyboardMode: String, Sendable, Hashable, Codable, CaseIterable {
    case full
    /// Voice type, space, delete, return and the globe; letters are typed after switching keyboards with the globe.
    case dictationBar
}

/// Whether the keyboard shows the dictation bar instead of its keys: in that mode, while voice typing is available,
/// unless Ask is open (typing needs the letters, the answer card the height) or a panel (meetings, emoji, voice info)
/// is. Pure function.
public func keyboardShowsDictationBar(mode: KeyboardMode, voiceTypingAvailable: Bool, isAsking: Bool, panelIsOpen: Bool) -> Bool {
    mode == .dictationBar && voiceTypingAvailable && !isAsking && !panelIsOpen
}

/// The dictation bar's key row: the globe (when the system asks the keyboard for one), space, delete and return. Pure
/// function.
public func keyboardDictationBarRows(showsGlobe: Bool) -> [[KeyboardKey]] {
    let globe: [KeyboardKey] = showsGlobe ? [KeyboardKey(kind: .globe, widthUnits: 1.3)] : []
    return [globe + [
        KeyboardKey(kind: .space, widthUnits: showsGlobe ? 4.6 : 5.9), KeyboardKey(kind: .delete, widthUnits: 1.6),
        KeyboardKey(kind: .returnKey, widthUnits: 2.5),
    ]]
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
    /// Full keyboard or dictation bar; nil in configs from apps before this field (full).
    public let mode: KeyboardMode?

    /// Options of the full keyboard.
    public init(haptics: KeyboardHapticStrength, microphoneSide: KeyboardMicrophoneSide, autoCapitalization: Bool, keyPopups: Bool) {
        self.haptics = haptics
        self.microphoneSide = microphoneSide
        self.autoCapitalization = autoCapitalization
        self.keyPopups = keyPopups
        self.mode = nil
    }

    public init(
        haptics: KeyboardHapticStrength, microphoneSide: KeyboardMicrophoneSide, autoCapitalization: Bool, keyPopups: Bool, mode: KeyboardMode
    ) {
        self.haptics = haptics
        self.microphoneSide = microphoneSide
        self.autoCapitalization = autoCapitalization
        self.keyPopups = keyPopups
        self.mode = mode
    }

    /// The defaults, also used for configs written before these options existed.
    public static let standard: KeyboardTypingOptions = KeyboardTypingOptions(
        haptics: .off, microphoneSide: .left, autoCapitalization: true, keyPopups: true
    )
}
