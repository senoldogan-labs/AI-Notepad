import Foundation

/// Uygulamanın klavyeye verdiği ayarlar ve sözlük (`config.json`; yalnız uygulama yazar). Veri yalnız uygulamadan
/// klavyeye akar: klavyede öğrenilen kelimeler uygulamaya ve sunucuya gitmez.
public struct KeyboardSharedConfig: Sendable, Hashable, Codable {
    public let languages: [KeyboardLanguage]
    public let autocorrect: Bool
    /// Kaydırarak yazma (varsayılan açık).
    public let swipeTyping: Bool
    /// The mechanical key sound (off by default; needs Full Access). Haptics are `typingOptions.haptics`.
    public let mechanicalSounds: Bool
    /// Mikrofon oturumunun süresi (dakika; son dikteden itibaren).
    public let sessionMinutes: Int
    /// "Klavyede toplantı notları" açık: toplantı listesi ve toplantılardan gelen adlar klavyede.
    public let meetingNotesEnabled: Bool
    /// Sesle yazma dili (ör. "ja"); nil ise klavyenin o anki dili.
    public let voiceLanguageCode: String?
    /// Kişisel sözlük: kullanıcının adı ve Gistsmith sözlüğü; toplantı notları açıksa kişiler ve toplantı terimleri.
    public let vocabulary: [String]
    /// Gistsmith has the microphone permission: the keyboard may then dictate in place, as its capture runs under the
    /// app's permission and cannot ask for it. Nil in configs from apps before this field (treated as not allowed).
    public let microphoneAllowed: Bool?
    /// The app's theme colours; nil in configs from apps before this field (the keyboard then uses `KeyboardTheme.ember`).
    public let theme: KeyboardTheme?
    /// How dictations are written; nil in configs from apps before this field (`KeyboardDictationOptions.standard`).
    public let dictationOptions: KeyboardDictationOptions?
    /// Haptics, microphone side, capitalization and key pop-ups; nil in configs from apps before this field
    /// (`KeyboardTypingOptions.standard`).
    public let typingOptions: KeyboardTypingOptions?
    /// The language dictations are written in after Apple's on-device translation (BCP 47, e.g. "en", "zh-TW"); nil keeps
    /// them in the spoken language, also in configs from apps before this field.
    public let dictationTranslationTarget: String?
    /// Letter layouts, emoji suggestions and learning (`KeyboardTypingExtras.standard` when nil: configs from apps before this field).
    public let typingExtras: KeyboardTypingExtras?
    /// Two-language dictation (a second transcriber for the user's other keyboard language); nil, in configs from apps
    /// before this field, means on.
    public let twoLanguageDictation: Bool?
    /// This iPhone has a Gistsmith account signed in. The keyboard needs no account: typing and on-device voice typing
    /// work either way, and only Ask (and meeting notes) need one. Nil, in configs from apps before this field, means
    /// signed in (those apps required an account for everything).
    public let accountSignedIn: Bool?

    public init(
        languages: [KeyboardLanguage], autocorrect: Bool, swipeTyping: Bool, mechanicalSounds: Bool, sessionMinutes: Int, meetingNotesEnabled: Bool,
        voiceLanguageCode: String?, vocabulary: [String], microphoneAllowed: Bool, theme: KeyboardTheme,
        dictationOptions: KeyboardDictationOptions, typingOptions: KeyboardTypingOptions, dictationTranslationTarget: String?, typingExtras: KeyboardTypingExtras,
        twoLanguageDictation: Bool, accountSignedIn: Bool?
    ) {
        self.languages = languages
        self.autocorrect = autocorrect
        self.swipeTyping = swipeTyping
        self.mechanicalSounds = mechanicalSounds
        self.sessionMinutes = sessionMinutes
        self.meetingNotesEnabled = meetingNotesEnabled
        self.voiceLanguageCode = voiceLanguageCode
        self.vocabulary = vocabulary
        self.microphoneAllowed = microphoneAllowed
        self.theme = theme
        self.dictationOptions = dictationOptions
        self.typingOptions = typingOptions
        self.dictationTranslationTarget = dictationTranslationTarget
        self.typingExtras = typingExtras
        self.twoLanguageDictation = twoLanguageDictation
        self.accountSignedIn = accountSignedIn
    }
}

/// Klavyenin uygulamaya bildirdiği son görülme (`report.json`): kurulum ekranı klavyenin eklendiğini ve Tam Erişim'in
/// açık olduğunu buradan anlar (Tam Erişim kapalıyken klavye yazamaz; o zaman dosya yoktur).
public struct KeyboardReport: Sendable, Hashable, Codable {
    /// When the keyboard last appeared (opened in any app).
    public let lastSeenAt: Date
    /// The keyboard's `hasFullAccess` then. Nil in reports from keyboards before this field (see
    /// `keyboardFullAccessSeenAt`).
    public let hasFullAccess: Bool?
    /// Taps adaptive touch has learned from (`KeyboardTouchModel.totalSamples`); nil in reports from keyboards before it.
    public let touchSamples: Int?

    public init(lastSeenAt: Date, hasFullAccess: Bool) {
        self.lastSeenAt = lastSeenAt
        self.hasFullAccess = hasFullAccess
        self.touchSamples = nil
    }

    public init(lastSeenAt: Date, hasFullAccess: Bool, touchSamples: Int) {
        self.lastSeenAt = lastSeenAt
        self.hasFullAccess = hasFullAccess
        self.touchSamples = touchSamples
    }
}

/// Klavyedeki "Gistsmith'ten ekle" listesinin bir toplantısı.
public struct KeyboardMeetingItem: Sendable, Hashable, Codable, Identifiable {
    /// Toplantının kimliği (`MeetingRecord.id`).
    public let id: String
    public let title: String
    public let date: Date
    /// Özetin düz metni (başlıksız Markdown).
    public let summary: String
    public let actionItems: [String]
    /// Kullanıcıya atanan görevler.
    public let myTasks: [String]
    /// The note's decisions and open questions, for Ask from the keyboard (`keyboardAskContext`). Nil in snapshots
    /// written before these fields.
    public let decisions: [String]?
    public let openQuestions: [String]?

    public init(id: String, title: String, date: Date, summary: String, actionItems: [String], myTasks: [String], decisions: [String], openQuestions: [String]) {
        self.id = id
        self.title = title
        self.date = date
        self.summary = summary
        self.actionItems = actionItems
        self.myTasks = myTasks
        self.decisions = decisions
        self.openQuestions = openQuestions
    }
}

/// Toplantı listesinin anlık görüntüsü (`meetings.json`; yalnız "Klavyede toplantı notları" açıkken var).
public struct KeyboardMeetingSnapshot: Sendable, Hashable, Codable {
    public let meetings: [KeyboardMeetingItem]

    public init(meetings: [KeyboardMeetingItem]) {
        self.meetings = meetings
    }
}

/// Toplantıdan eklenecek kısım.
public enum KeyboardMeetingPart: String, Sendable, Hashable, CaseIterable {
    case summary
    case actionItems
    case myTasks
}

/// Toplantının seçilen kısmının eklenecek metni: özet olduğu gibi, görevler madde işaretli satırlar. Boşsa nil. Saf
/// fonksiyondur.
public func keyboardMeetingText(meeting: KeyboardMeetingItem, part: KeyboardMeetingPart) -> String? {
    let text: String
    switch part {
    case .summary:
        text = meeting.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    case .actionItems:
        text = meeting.actionItems.map { "• " + $0 }.joined(separator: "\n")
    case .myTasks:
        text = meeting.myTasks.map { "• " + $0 }.joined(separator: "\n")
    }
    return text.isEmpty ? nil : text
}

/// Klavyeye giden kişisel sözlük: önce kullanıcının adı ve kendi sözlüğü, toplantı notları açıksa sonra toplantılardan
/// gelen adlar ve terimler; tekrarlar (büyük/küçük harf duyarsız) atılır, en fazla `limit`. Saf fonksiyondur.
public func keyboardVocabulary(own: [String], meetingDerived: [String], meetingNotesEnabled: Bool, limit: Int) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for term in own + (meetingNotesEnabled ? meetingDerived : []) {
        let cleaned: String = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else {
            continue
        }
        result.append(cleaned)
        if result.count == limit {
            break
        }
    }
    return result
}

/// Sözlük terimlerini kelimelere böler (öneri çubuğu kelime kelime çalışır; "Gistsmith Keyboard" → iki kelime).
/// Saf fonksiyondur.
public func keyboardVocabularyWords(terms: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for term in terms {
        for part in term.split(whereSeparator: { $0.isWhitespace }) {
            let word: String = String(part).trimmingCharacters(in: .punctuationCharacters)
            guard word.count >= 2, seen.insert(word).inserted else {
                continue
            }
            result.append(word)
        }
    }
    return result
}

/// Emoji ten rengi (Fitzpatrick değiştiricileri); `none` sarı varsayılan.
public enum KeyboardSkinTone: String, Sendable, Hashable, CaseIterable, Codable {
    case none
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var modifier: Unicode.Scalar? {
        switch self {
        case .none: nil
        case .light: Unicode.Scalar(0x1F3FB)
        case .mediumLight: Unicode.Scalar(0x1F3FC)
        case .medium: Unicode.Scalar(0x1F3FD)
        case .mediumDark: Unicode.Scalar(0x1F3FE)
        case .dark: Unicode.Scalar(0x1F3FF)
        }
    }
}

private let keyboardSkinToneCapable: Set<String> = Set(keyboardSkinToneCapableText.split(separator: " ").map(String.init))

/// Emojiyi ten rengiyle yazar: ten alabilen emojilerde değiştirici ilk karakterin ardına gelir (ardındaki emoji biçim
/// seçicisi düşer); diğerleri ve `none` olduğu gibi. Saf fonksiyondur.
public func keyboardEmojiApplyingTone(emoji: String, tone: KeyboardSkinTone) -> String {
    guard let modifier = tone.modifier, keyboardSkinToneCapable.contains(emoji) else {
        return emoji
    }
    var scalars: [Unicode.Scalar] = Array(emoji.unicodeScalars)
    guard !scalars.isEmpty else {
        return emoji
    }
    if scalars.count > 1, scalars[1].value == 0xFE0F {
        scalars.remove(at: 1)
    }
    scalars.insert(modifier, at: 1)
    var result: String.UnicodeScalarView = String.UnicodeScalarView()
    result.append(contentsOf: scalars)
    return String(result)
}

/// Son kullanılan emojiler: seçilen öne gelir, en fazla `limit`. Saf fonksiyondur.
public func keyboardRecentEmojiAdding(emoji: String, to recents: [String], limit: Int) -> [String] {
    Array(([emoji] + recents.filter { $0 != emoji }).prefix(limit))
}

/// The app's theme colours for the keyboard (`ThemePalette.accents` of the chosen palette and accent, 0xRRGGBB): the
/// accent for glyphs and lines, the fill of big accent surfaces and the ink drawn on that fill, in light and dark.
public struct KeyboardTheme: Sendable, Hashable, Codable {
    public let tintLight: UInt32
    public let tintDark: UInt32
    public let fillLight: UInt32
    public let fillDark: UInt32
    public let onFillLight: UInt32
    public let onFillDark: UInt32

    public init(tintLight: UInt32, tintDark: UInt32, fillLight: UInt32, fillDark: UInt32, onFillLight: UInt32, onFillDark: UInt32) {
        self.tintLight = tintLight
        self.tintDark = tintDark
        self.fillLight = fillLight
        self.fillDark = fillDark
        self.onFillLight = onFillLight
        self.onFillDark = onFillDark
    }

    /// Gistsmith's copper (the Ember stops), for a keyboard whose app has not written a theme yet.
    public static let ember: KeyboardTheme = KeyboardTheme(
        tintLight: 0xA5664B, tintDark: 0xBD976F, fillLight: 0xA5664B, fillDark: 0x93553D, onFillLight: 0xFFFFFF, onFillDark: 0xFFFFFF
    )
}
