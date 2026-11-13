import ActivityKit
import AppIntents
import Foundation

// Shared by the app and the widget extension: the warm-microphone Live Activity of Gistsmith Keyboard and its stop
// button. In the extension (`WIDGET_EXTENSION`) the intent's body is empty; the system runs it in the app's process.

/// The keyboard's warm microphone on the Lock Screen and in the Dynamic Island: the keyboard glyph while Gistsmith keeps
/// the microphone ready for voice typing, a waveform while it listens, and a button that turns the microphone off.
struct KeyboardSessionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// When the microphone closes unless the user dictates again (the session length counts from the last dictation).
        let expiresAt: Date
        /// When the running dictation (preparing, listening or finishing) started; nil while the microphone only waits.
        /// The Dynamic Island counts up from it, like a recording.
        let listeningSince: Date?

        var isListening: Bool {
            listeningSince != nil
        }
    }

    let startedAt: Date
}

/// "Turn off microphone" in the keyboard's Live Activity: ends the warm session without opening the app.
struct EndKeyboardSessionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mikrofonu kapat"
    static let isDiscoverable: Bool = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        PhoneKeyboardHost.shared.endSession(reason: "canlı etkinlikten bitirildi")
        #endif
        return .result()
    }
}
