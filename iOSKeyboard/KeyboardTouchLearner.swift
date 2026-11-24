import Foundation
import KeyboardCore
import os

private let touchLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "Touch")

/// Adaptive touch's memory in the keyboard extension: the learned tap offsets (`KeyboardTouchModel`, offsets and counts
/// only, never text) kept in the extension's own UserDefaults, and the word being typed whose taps wait to be confirmed
/// (`KeyboardTouchWord`). The rules are the pure functions in KeyboardCore; this class only holds the state and saves it,
/// in batches (every `saveEvery` learned taps and when the keyboard closes), never per tap.
@MainActor
final class KeyboardTouchLearner {
    private static let storageKey: String = "keyboard.touchModel"
    private static let saveEvery: Int = 25

    private let defaults: UserDefaults
    private(set) var model: KeyboardTouchModel
    private var word: KeyboardTouchWord = .empty
    private var unsaved: Int = 0

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.storageKey) else {
            model = .empty
            return
        }
        do {
            model = try JSONDecoder().decode(KeyboardTouchModel.self, from: data)
        } catch {
            // An unreadable model (an older format) is dropped and learned again; the taps themselves hold nothing precious.
            touchLogger.error("Touch model unreadable, starting over: \(String(describing: error), privacy: .public)")
            model = .empty
        }
    }

    /// A tap on a letter key. Returns whether the model learned something (the targets are then recomputed).
    func tap(_ sample: KeyboardTouchSample) -> Bool {
        let result: (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) = keyboardTouchWordAfterTap(word: word, sample: sample)
        word = result.word
        return learn(result.learn)
    }

    /// A delete: the word being typed and the one just finished are not learned.
    func deleted() {
        word = keyboardTouchWordAfterDelete(word: word)
    }

    /// A word ended (space, return, punctuation); `accepted` is false when the keyboard autocorrected it.
    func wordEnded(accepted: Bool) -> Bool {
        let result: (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) = keyboardTouchWordAfterBoundary(word: word, accepted: accepted)
        word = result.word
        return learn(result.learn)
    }

    /// The keyboard closes: a finished word is confirmed, everything is saved.
    func close() -> Bool {
        let result: (word: KeyboardTouchWord, learn: [KeyboardTouchSample]) = keyboardTouchWordAfterClose(word: word)
        word = result.word
        let changed: Bool = learn(result.learn)
        save()
        return changed
    }

    /// "Reset touch learning": forgets everything and saves at once.
    func reset() {
        model = .empty
        word = .empty
        save()
    }

    private func learn(_ samples: [KeyboardTouchSample]) -> Bool {
        guard !samples.isEmpty else {
            return false
        }
        model = keyboardTouchLearning(model: model, samples: samples)
        unsaved += samples.count
        if unsaved >= Self.saveEvery {
            save()
        }
        return true
    }

    private func save() {
        unsaved = 0
        do {
            defaults.set(try JSONEncoder().encode(model), forKey: Self.storageKey)
        } catch {
            touchLogger.error("Touch model not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
