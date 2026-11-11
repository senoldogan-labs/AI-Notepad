import ActivityKit
import Foundation
import os

private let keyboardActivityLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "KeyboardActivity")

/// The Live Activity's relevance: below a meeting recording (100), above most other apps' activities.
private let keyboardActivityRelevanceScore: Double = 50

/// What the Live Activity shows for the warm microphone: while listening the countdown is hidden (the session cannot
/// expire mid-dictation), so only the listening flag changes it. Pure function.
func keyboardActivityState(expiresAt: Date, isListening: Bool) -> KeyboardSessionActivityAttributes.ContentState {
    KeyboardSessionActivityAttributes.ContentState(expiresAt: expiresAt, isListening: isListening)
}

/// Whether the shown state needs an update: listening started or stopped, or the expiry moved by more than a couple of
/// seconds (the session's heartbeat rewrites it every second; ActivityKit throttles frequent updates). Pure function.
func keyboardActivityNeedsUpdate(shown: KeyboardSessionActivityAttributes.ContentState?, next: KeyboardSessionActivityAttributes.ContentState) -> Bool {
    guard let shown else {
        return true
    }
    if shown.isListening != next.isListening {
        return true
    }
    return !next.isListening && abs(shown.expiresAt.timeIntervalSince(next.expiresAt)) > 2
}

/// Adapter over ActivityKit for the keyboard's warm microphone (`KeyboardSessionActivityAttributes`). If the user turned
/// Live Activities off nothing is shown (logged); the session itself is unaffected, the orange microphone dot stays.
@MainActor
final class PhoneKeyboardActivity {
    private var activityID: String?
    private var shown: KeyboardSessionActivityAttributes.ContentState?

    /// Shows the activity for a session that just opened.
    func start(startedAt: Date, expiresAt: Date) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            keyboardActivityLogger.info("Live Activities are off; the warm microphone is not shown in the Dynamic Island")
            return
        }
        let state: KeyboardSessionActivityAttributes.ContentState = keyboardActivityState(expiresAt: expiresAt, isListening: false)
        do {
            let activity: Activity<KeyboardSessionActivityAttributes> = try Activity.request(
                attributes: KeyboardSessionActivityAttributes(startedAt: startedAt), content: content(state: state), pushType: nil
            )
            activityID = activity.id
            shown = state
        } catch {
            keyboardActivityLogger.error("Keyboard Live Activity could not start, error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Follows the session (called with every status write; updates only when something visible changed).
    func update(expiresAt: Date, isListening: Bool) {
        guard let activityID else {
            return
        }
        let next: KeyboardSessionActivityAttributes.ContentState = keyboardActivityState(expiresAt: expiresAt, isListening: isListening)
        guard keyboardActivityNeedsUpdate(shown: shown, next: next) else {
            return
        }
        shown = next
        let content: ActivityContent<KeyboardSessionActivityAttributes.ContentState> = content(state: next)
        Task.detached {
            for running in Activity<KeyboardSessionActivityAttributes>.activities where running.id == activityID {
                await running.update(content)
            }
        }
    }

    /// The microphone closed: the activity goes at once.
    func end() {
        guard let activityID else {
            return
        }
        self.activityID = nil
        shown = nil
        Task.detached {
            for running in Activity<KeyboardSessionActivityAttributes>.activities where running.id == activityID {
                await running.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Removes activities a previous process left (the app was killed while the microphone was warm). Called at launch,
    /// often in the same main-actor turn in which the keyboard's link opens a new session: the activity that session
    /// starts is read after that turn and kept.
    func endLeftovers() {
        Task { @MainActor [weak self] in
            let keep: String? = self?.activityID
            await Task.detached {
                for stale in Activity<KeyboardSessionActivityAttributes>.activities where stale.id != keep {
                    await stale.end(nil, dismissalPolicy: .immediate)
                }
            }.value
        }
    }

    private func content(state: KeyboardSessionActivityAttributes.ContentState) -> ActivityContent<KeyboardSessionActivityAttributes.ContentState> {
        // Stale a minute after the expiry: a killed app's activity does not claim a warm microphone for long.
        ActivityContent(state: state, staleDate: state.expiresAt.addingTimeInterval(60), relevanceScore: keyboardActivityRelevanceScore)
    }
}
