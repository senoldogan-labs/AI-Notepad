import Foundation

/// The guided keyboard setup's pages, in order. Each page is derived from observed facts (`keyboardSetupStep`), so the
/// flow moves on by itself when the user comes back from iOS Settings or the keyboard reports.
///
/// Only documented facts are used: the keyboard extension's own report in the App Group (written when it appears, with
/// its `hasFullAccess`), the setup's own text field (focused or not) and what the user did in the setup. iOS has no
/// public API that tells an app which keyboards are enabled or which one a field shows.
public enum KeyboardSetupStep: String, Sendable, Hashable, CaseIterable {
    /// What the keyboard does; "Turn on in iOS Settings".
    case intro
    /// Numbered steps for Settings › Gistsmith › Keyboards before the app opens Settings.
    case turnOn
    /// Hold the globe key and pick Gistsmith in the setup's text field.
    case switchKeyboard
    /// The field has been focused for a while and the keyboard never reported: it is not picked yet, or Full Access is
    /// off (the keyboard can only report with Full Access). The page says both and keeps the field.
    case fullAccess
    /// Tap the keyboard's microphone and say something (iOS 26+).
    case tryVoice
    /// Set up and proven.
    case ready
}

/// What the app observes while the setup runs. Every value comes from a fact the app reads; none is a guess.
public struct KeyboardSetupFacts: Sendable, Hashable {
    /// The user left the intro page.
    public let introDone: Bool
    /// The user opened iOS Settings from the setup (or said the keyboard is already added) and came back.
    public let returnedFromSettings: Bool
    /// When the keyboard last reported with Full Access (`keyboardFullAccessSeenAt`).
    public let lastFullAccessReportAt: Date?
    /// The last dictation the keyboard inserted (the app sees the keyboard's `acknowledge` of a finished dictation).
    public let lastDictationSucceededAt: Date?
    /// Since when the setup's text field has been focused; nil when it is not.
    public let fieldFocusedSince: Date?
    /// The Full Access hint was already shown in this run: it stays until a report arrives (its page has its own field,
    /// so the focus restarts when the page changes).
    public let fullAccessHintShown: Bool
    /// Voice typing works on this iPhone (iOS 26+).
    public let voiceTypingAvailable: Bool
    /// The user chose to skip the voice try-out.
    public let tryVoiceSkipped: Bool
    /// When this run of the setup started: only reports and dictations after it prove this run.
    public let flowStartedAt: Date
    public let now: Date

    public init(
        introDone: Bool, returnedFromSettings: Bool, lastFullAccessReportAt: Date?, lastDictationSucceededAt: Date?, fieldFocusedSince: Date?,
        fullAccessHintShown: Bool, voiceTypingAvailable: Bool, tryVoiceSkipped: Bool, flowStartedAt: Date, now: Date
    ) {
        self.introDone = introDone
        self.returnedFromSettings = returnedFromSettings
        self.lastFullAccessReportAt = lastFullAccessReportAt
        self.lastDictationSucceededAt = lastDictationSucceededAt
        self.fieldFocusedSince = fieldFocusedSince
        self.fullAccessHintShown = fullAccessHintShown
        self.voiceTypingAvailable = voiceTypingAvailable
        self.tryVoiceSkipped = tryVoiceSkipped
        self.flowStartedAt = flowStartedAt
        self.now = now
    }
}

/// How long the setup's field may stay focused without a keyboard report before the setup says "pick Gistsmith, or turn
/// on Full Access". Switching keyboards takes a few seconds; the keyboard reports as soon as it appears.
public let keyboardFullAccessHintWait: TimeInterval = 15

/// When the keyboard last reported with Full Access, from its report. Reports written before `hasFullAccess` existed
/// count as Full Access: the keyboard could only write the shared folder with it. Pure function.
public func keyboardFullAccessSeenAt(report: KeyboardReport?) -> Date? {
    guard let report, report.hasFullAccess ?? true else {
        return nil
    }
    return report.lastSeenAt
}

/// The setup page for the facts. Pure function.
///
/// - Intro until the user leaves it.
/// - A Full Access report from this run: a dictation inserted in this run (or voice unavailable, or skipped) → ready,
///   else try it.
/// - Not back from Settings yet → the numbered steps.
/// - The field focused for `keyboardFullAccessHintWait` without a report → pick it, or turn on Full Access; once shown, it
///   stays until a report arrives.
/// - Otherwise → switch to it in the field.
public func keyboardSetupStep(facts: KeyboardSetupFacts) -> KeyboardSetupStep {
    guard facts.introDone else {
        return .intro
    }
    let seenThisRun: Bool = facts.lastFullAccessReportAt.map { $0 >= facts.flowStartedAt } ?? false
    if seenThisRun {
        let dictatedThisRun: Bool = facts.lastDictationSucceededAt.map { $0 >= facts.flowStartedAt } ?? false
        return dictatedThisRun || !facts.voiceTypingAvailable || facts.tryVoiceSkipped ? .ready : .tryVoice
    }
    guard facts.returnedFromSettings else {
        return .turnOn
    }
    if facts.fullAccessHintShown {
        return .fullAccess
    }
    if let focused = facts.fieldFocusedSince, facts.now.timeIntervalSince(focused) >= keyboardFullAccessHintWait {
        return .fullAccess
    }
    return .switchKeyboard
}

/// The keyboard's state on the Settings › Keyboard hub.
public enum KeyboardReadiness: String, Sendable, Hashable {
    /// No recent Full Access report: not added, Full Access off, or not used yet (the app cannot tell these apart).
    case notSetUp
    /// Reported with Full Access; no dictation proven yet (voice typing available).
    case voiceUntested
    /// Reported with Full Access and, where voice typing works, a dictation went through.
    case ready
}

/// A keyboard report older than this does not count (the keyboard reports each time it appears).
public let keyboardReportFreshness: TimeInterval = 60 * 60 * 24 * 30

/// The hub's state from the keyboard's last Full Access report and the last inserted dictation. Pure function.
public func keyboardReadiness(lastFullAccessReportAt: Date?, lastDictationSucceededAt: Date?, voiceTypingAvailable: Bool, now: Date) -> KeyboardReadiness {
    guard let reported = lastFullAccessReportAt, now.timeIntervalSince(reported) < keyboardReportFreshness else {
        return .notSetUp
    }
    if voiceTypingAvailable, lastDictationSucceededAt == nil {
        return .voiceUntested
    }
    return .ready
}
