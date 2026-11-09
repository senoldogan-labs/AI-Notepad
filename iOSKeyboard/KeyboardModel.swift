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
    let insertFinishedDictation: () -> Void
    let endSession: () -> Void
    let openSettings: () -> Void
    let openGistsmithSetup: () -> Void
}
