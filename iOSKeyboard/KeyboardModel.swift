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
    /// The dictation is written into the field it was started in (marked text while Gistsmith listens): the dictation
    /// panel then shows "Live typing on" instead of the text.
    var isLiveTyping: Bool = false
    /// The app's theme colours (Ember until Gistsmith has written its theme).
    var brand: KeyboardBrand = KeyboardBrand(theme: .ember)
    /// The voice's recent loudness, 0…1, newest last: from the keyboard's own capture (`KeyboardInPlaceDictation`) or,
    /// while Gistsmith listens, from the level it publishes (`KeyboardVoiceLevelSample`); empty until the first one.
    var voiceLevels: [Double] = []
    /// When the dictation panel opened for the current dictation (its running time); nil without one.
    var dictationStartedAt: Date?
    /// The voice language's name, in that language (e.g. "Türkçe"), on the dictation panel.
    var voiceLanguageName: String = ""
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
}
