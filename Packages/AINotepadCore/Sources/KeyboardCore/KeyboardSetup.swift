import Foundation

/// The guided keyboard setup's pages, in order. Each page is derived from observed facts (`keyboardSetupStep`), so the
/// flow moves on by itself when the user comes back from iOS Settings or switches keyboards.
public enum KeyboardSetupStep: String, Sendable, Hashable, CaseIterable {
    /// What the keyboard does; "Turn on in iOS Settings".
    case intro
    /// Numbered steps for Settings › Gistsmith › Keyboards before the app opens Settings.
    case turnOn
    /// Our keyboard is up in the setup's text field but never reported back: Full Access is off.
    case fullAccess
    /// Hold the globe key and pick Gistsmith in the setup's text field.
    case switchKeyboard
    /// Tap the keyboard's microphone and say something (iOS 26+).
    case tryVoice
    /// Set up and proven.
    case ready
}

/// What the app can observe about the keyboard while the setup runs. Every value comes from a fact the app reads; none
/// is a guess.
public struct KeyboardSetupFacts: Sendable, Hashable {
    /// The user left the intro page.
    public let introDone: Bool
    /// The keyboard is in the system's list of active keyboards (`UITextInputMode.activeInputModes`); nil when the
    /// system does not tell.
    public let isEnabled: Bool?
    /// The keyboard's last report (`report.json`); the keyboard can write it only with Full Access.
    public let lastKeyboardSeenAt: Date?
    /// The last dictation the keyboard inserted (the app sees the keyboard's `acknowledge` of a finished dictation).
    public let lastDictationSucceededAt: Date?
    /// Since when our keyboard is the input mode of the setup's text field; nil when it is not (or the field is not
    /// focused).
    public let keyboardActiveInFieldSince: Date?
    /// Voice typing works on this iPhone (iOS 26+).
    public let voiceTypingAvailable: Bool
    /// The user chose to skip the voice try-out.
    public let tryVoiceSkipped: Bool
    /// When this run of the setup started: only reports and dictations after it prove this run.
    public let flowStartedAt: Date
    public let now: Date

    public init(
        introDone: Bool, isEnabled: Bool?, lastKeyboardSeenAt: Date?, lastDictationSucceededAt: Date?, keyboardActiveInFieldSince: Date?,
        voiceTypingAvailable: Bool, tryVoiceSkipped: Bool, flowStartedAt: Date, now: Date
    ) {
        self.introDone = introDone
        self.isEnabled = isEnabled
        self.lastKeyboardSeenAt = lastKeyboardSeenAt
        self.lastDictationSucceededAt = lastDictationSucceededAt
        self.keyboardActiveInFieldSince = keyboardActiveInFieldSince
        self.voiceTypingAvailable = voiceTypingAvailable
        self.tryVoiceSkipped = tryVoiceSkipped
        self.flowStartedAt = flowStartedAt
        self.now = now
    }
}

/// How long our keyboard may be up in the setup's field without reporting before the setup says Full Access is off. The
/// keyboard reports as soon as it appears; the wait covers a slow extension launch.
public let keyboardFullAccessReportWait: TimeInterval = 3

/// The setup page for the facts. Pure function.
///
/// - Intro until the user leaves it.
/// - Not in the active keyboards (and no report from this run) → turn it on in Settings. Unknown → the field step.
/// - Our keyboard up in the field: no report from this run within `keyboardFullAccessReportWait` → Full Access is off.
/// - Reported in this run: a dictation inserted in this run (or voice unavailable, or skipped) → ready, else try it.
/// - Otherwise → switch to it in the field.
public func keyboardSetupStep(facts: KeyboardSetupFacts) -> KeyboardSetupStep {
    guard facts.introDone else {
        return .intro
    }
    let seenThisRun: Bool = facts.lastKeyboardSeenAt.map { $0 >= facts.flowStartedAt } ?? false
    let dictatedThisRun: Bool = facts.lastDictationSucceededAt.map { $0 >= facts.flowStartedAt } ?? false
    if seenThisRun, dictatedThisRun {
        return .ready
    }
    // A report proves the keyboard is enabled; when the system does not tell (nil), the field step finds out.
    if facts.isEnabled == false, !seenThisRun {
        return .turnOn
    }
    if seenThisRun {
        if !facts.voiceTypingAvailable || facts.tryVoiceSkipped {
            return .ready
        }
        return facts.keyboardActiveInFieldSince == nil ? .switchKeyboard : .tryVoice
    }
    if let activeSince = facts.keyboardActiveInFieldSince, facts.now.timeIntervalSince(activeSince) >= keyboardFullAccessReportWait {
        return .fullAccess
    }
    return .switchKeyboard
}

/// The keyboard's state on the Settings › Keyboard hub.
public enum KeyboardReadiness: String, Sendable, Hashable {
    /// Not in the active keyboards.
    case notAdded
    /// Added, but it never reported back recently: Full Access is off or the keyboard was not used yet.
    case needsFullAccess
    /// Added with Full Access; no dictation proven yet (voice typing available).
    case voiceUntested
    /// Added with Full Access and, where voice typing works, a dictation went through.
    case ready
}

/// A keyboard report older than this does not count as "Full Access on" (the keyboard reports each time it appears).
public let keyboardReportFreshness: TimeInterval = 60 * 60 * 24 * 30

/// The hub's state. A recent report proves the keyboard is enabled with Full Access; the system list decides "added"
/// when there is no report. Pure function.
public func keyboardReadiness(
    isEnabled: Bool?, lastKeyboardSeenAt: Date?, lastDictationSucceededAt: Date?, voiceTypingAvailable: Bool, now: Date
) -> KeyboardReadiness {
    let reportedRecently: Bool = lastKeyboardSeenAt.map { now.timeIntervalSince($0) < keyboardReportFreshness } ?? false
    // The system list is the truth for "removed": a keyboard taken out of Settings keeps its old report.
    if isEnabled == false || (isEnabled == nil && !reportedRecently) {
        return .notAdded
    }
    guard reportedRecently else {
        return .needsFullAccess
    }
    if voiceTypingAvailable, lastDictationSucceededAt == nil {
        return .voiceUntested
    }
    return .ready
}

/// The keyboard extension's bundle identifier inside the app (`project.yml`: app id + ".Keyboard"). Pure function.
public func keyboardExtensionBundleIdentifier(appBundleIdentifier: String) -> String {
    appBundleIdentifier + ".Keyboard"
}

/// Whether one of the system's input mode identifiers is our keyboard. Third-party keyboards are listed by their
/// extension's bundle identifier. Pure function.
public func keyboardInputModesContainOurs(identifiers: [String], extensionBundleIdentifier: String) -> Bool {
    identifiers.contains(extensionBundleIdentifier)
}
