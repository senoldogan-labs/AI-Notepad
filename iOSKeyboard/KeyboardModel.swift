import KeyboardCore
import Observation
import SwiftUI

/// Tuşların yerini alan panel.
enum KeyboardPanel: Equatable {
    case none
    case emoji
    case gistsmith
    /// Sesle yazma neden kullanılamıyor ya da ne yapılmalı.
    case voiceInfo(KeyboardVoiceInfo)
}

/// Sesle yazma bilgisinin türü.
enum KeyboardVoiceInfo: Equatable {
    case needsFullAccess
    /// Uygulama açılamadı (ya da bu derleme uygulamayı açmıyor): kullanıcı Gistsmith'i kendisi açar.
    case openGistsmithManually
}

/// Klavyenin SwiftUI kısmının (öneri çubuğu, sesle yazma şeridi, paneller) durumu; denetleyici yazar.
@MainActor
@Observable
final class KeyboardModel {
    var suggestions: KeyboardSuggestions = .empty
    var micState: KeyboardMicState = .idle(sessionRemaining: nil)
    var panel: KeyboardPanel = .none
    var hasFullAccess: Bool = false
    var showsMicrophone: Bool = false
    var isDark: Bool = false
    var meetings: [KeyboardMeetingItem]?
    var recentEmoji: [String] = []
    var emojiCategory: KeyboardEmojiCategory? = nil
    /// Emojilerin ten rengi (klavyenin kendi kabında saklanır).
    var skinTone: KeyboardSkinTone = .none
    /// "Gistsmith'e sor" açık: tuşlar soru alanına yazar, alandaki belgeye değil.
    var isAsking: Bool = false
    var askQuestion: String = ""
    var askState: KeyboardAskState = .idle
    /// The answer was just copied: the button says so for a moment.
    var askAnswerCopied: Bool = false
    /// The shown failure is of a question asked directly: "Open in Gistsmith" asks it there.
    var askCanOpenInGistsmith: Bool = false
    /// The question the answer card belongs to (its header and "Ask again"); empty when the keyboard did not ask it in
    /// this run.
    var askedQuestion: String = ""
    /// When the shown answer arrived: the card writes it out from then on (`keyboardAnswerReveal`).
    var askAnswerArrivedAt: Date?
    /// The answer just added to the field, while "Added · Undo" is shown (`keyboardAnswerUndoWindow`).
    var askInsertedAnswer: String?
    /// The dictation just added to the field, while "Dictation added · Undo" is shown (`keyboardDictationUndoWindow`).
    var insertedDictation: KeyboardInsertion?
    /// The last finished dictation that did not go into a field: "Paste dictation" puts it in
    /// (`keyboardPastableDictation`).
    var pastableDictation: String?
    /// The dictation is written into the field it was started in (marked text while Gistsmith listens): the dictation
    /// panel then shows "Live typing on" instead of the text.
    var isLiveTyping: Bool = false
    /// The app's theme colours (Ember until Gistsmith has written its theme).
    var brand: KeyboardBrand = KeyboardBrand(theme: .ember)
    /// The voice's recent loudness, 0…1, newest last: from the keyboard's own capture (`KeyboardInPlaceDictation`) or,
    /// while Gistsmith listens, from the level it publishes (`KeyboardVoiceLevelSample`); empty until the first one.
    var voiceLevels: [Double] = []
    /// The time of the panels' current frame (the dictation field and timer, the Ask panel's field and answer): set by
    /// the keyboard's display link (`KeyboardViewController.refreshFrameLink`) while one of them moves. SwiftUI's
    /// `TimelineView` stops in a keyboard extension at times (seen after coming back from Gistsmith: a timer frozen at
    /// 0:00 and an empty field), so the panels are driven from here.
    var frameDate: Date = Date()
    /// When the dictation panel opened for the current dictation (its running time); nil without one.
    var dictationStartedAt: Date?
    /// The voice language's name, in that language (e.g. "Türkçe"), on the dictation panel; with "Söylediğimi çevir"
    /// also the language it is written in ("Türkçe → English").
    var voiceLanguageName: String = ""
    /// The finished dictation's translation, while it runs or after it failed; nil otherwise.
    var translation: KeyboardTranslationState?
    /// Apple Intelligence is cleaning up the transcript (the polished style): the dictation panel says "Polishing…".
    var isPolishing: Bool = false
    /// A short line in the suggestion bar after a dictation (the clean-up failed and the text went in as spoken).
    var dictationNote: String?
    /// The keyboard is the dictation bar: the suggestion bar holds only the big Voice type button.
    var isDictationBar: Bool = false
}

/// A finished dictation's translation on the dictation panel.
enum KeyboardTranslationState: Equatable {
    case translating
    /// Nothing was inserted; the panel says why and offers the spoken text untranslated.
    case failed(KeyboardTranslationFailure)
}

/// SwiftUI kısmının denetleyiciye ilettiği işler.
@MainActor
struct KeyboardActions {
    let pickSuggestion: (KeyboardSuggestion) -> Void
    let openGistsmithPanel: () -> Void
    let closePanel: () -> Void
    let insertEmoji: (String) -> Void
    let deleteBackward: () -> Void
    let insertMeetingText: (String) -> Void
    let finishDictation: () -> Void
    let cancelDictation: () -> Void
    /// Space, delete or return in the dictation panel: finishes the dictation, then acts once its text is in.
    let dictationKey: (KeyboardDictationKey) -> Void
    let insertFinishedDictation: () -> Void
    /// After a failed translation: inserts the spoken text as it was said.
    let insertUntranslatedDictation: () -> Void
    let startVoiceTyping: () -> Void
    let openSettings: () -> Void
    let openGistsmithSetup: () -> Void
    let cycleSkinTone: () -> Void
    let startAsking: () -> Void
    let sendQuestion: () -> Void
    let cancelAsking: () -> Void
    let insertAnswer: () -> Void
    let copyAnswer: () -> Void
    let openAskInGistsmith: () -> Void
    let dismissAnswer: () -> Void
    /// The question field opens again with the last question in it (sent only with Ask).
    let askAgain: () -> Void
    /// Takes the answer just added out of the field again.
    let undoInsertedAnswer: () -> Void
    /// Puts the last dictation that did not go in into the field.
    let pasteDictation: () -> Void
    /// Takes the dictation just added out of the field again.
    let undoInsertedDictation: () -> Void
}
