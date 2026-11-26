import KeyboardCore
import SwiftUI

private func ink(_ isDark: Bool) -> Color {
    isDark ? .white : .black
}

/// Öneri çubuğu ya da (sesle yazarken) canlı metin şeridi.
struct KeyboardTopBar: View {
    let model: KeyboardModel
    let actions: KeyboardActions

    var body: some View {
        Group {
            if model.isAsking {
                askField
            } else if model.askState != .idle, isMicIdle {
                askStrip
            } else if model.askInsertedAnswer != nil, isMicIdle {
                insertedStrip(title: String(localized: "Cevap eklendi"), undo: actions.undoInsertedAnswer)
            } else if model.insertedDictation != nil, isMicIdle {
                insertedStrip(title: String(localized: "Dikte eklendi"), undo: actions.undoInsertedDictation)
            } else {
                micContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A margin above the 36 pt controls: they do not touch the keyboard's rounded top edge.
        .padding(.top, 6)
        .padding(.bottom, 2)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    private var isMicIdle: Bool {
        if case .idle = model.micState {
            return true
        }
        return model.micState == .needsFullAccess
    }

    /// Soru alanı: tuşlar buraya yazar; dönüş tuşu ya da "Sor" gönderir.
    private var askField: some View {
        HStack(spacing: 8) {
            Button(action: actions.cancelAsking) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink(model.isDark).opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(ink(model.isDark).opacity(0.08)))
            }
            .accessibilityLabel(Text("Vazgeç"))
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            HStack(spacing: 1) {
                if model.askQuestion.isEmpty {
                    KeyboardAskCaret()
                }
                Text(model.askQuestion.isEmpty ? String(localized: "Gistsmith'e sor…") : model.askQuestion)
                    .font(.system(size: 15))
                    .foregroundStyle(ink(model.isDark).opacity(model.askQuestion.isEmpty ? 0.5 : 1))
                    .lineLimit(1)
                    .truncationMode(.head)
                if !model.askQuestion.isEmpty {
                    KeyboardAskCaret()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Soru"))
            .accessibilityValue(Text(model.askQuestion))
            Button(action: actions.sendQuestion) {
                Text("Sor")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(Color.accentColor))
            }
            .disabled(model.askQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 8)
    }

    /// The question being answered (or answered), above the answer card that covers the keys (`KeyboardAskPanel`).
    private var askStrip: some View {
        HStack(spacing: 8) {
            Button(action: actions.dismissAnswer) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink(model.isDark).opacity(0.7))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(ink(model.isDark).opacity(0.08)))
            }
            .accessibilityLabel(Text("Kapat"))
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(model.askedQuestion.isEmpty ? String(localized: "Gistsmith'e sor") : model.askedQuestion)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink(model.isDark).opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
    }

    /// "Added · Undo" for a moment after an answer or a dictation went into the field.
    private func insertedStrip(title: String, undo: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink(model.isDark).opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: undo) {
                Text("Geri al")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Capsule().fill(ink(model.isDark).opacity(0.08)))
            }
        }
        .padding(.horizontal, 12)
        .transition(.opacity)
    }

    /// The suggestions, or the "Voice type" button while no word is being typed (the dictation itself covers the keys,
    /// `KeyboardDictationView`); a note after a dictation for a few seconds.
    @ViewBuilder
    private var micContent: some View {
        if let note = model.dictationNote, isMicIdle {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(ink(model.isDark).opacity(0.6))
                    .accessibilityHidden(true)
                Text(note)
                    .font(.system(size: 14))
                    .foregroundStyle(ink(model.isDark).opacity(0.75))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .accessibilityElement(children: .combine)
        } else {
            suggestionBar
        }
    }

    private var suggestionBar: some View {
        HStack(spacing: 0) {
            // Meeting notes come from the account: with none signed in there is nothing to add.
            if model.accountSignedIn {
                Button(action: actions.openGistsmithPanel) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(ink(model.isDark).opacity(0.7))
                        .frame(width: 44, height: 36)
                }
                .accessibilityLabel(Text("Gistsmith'ten ekle"))
            }
            Button(action: actions.startAsking) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 36)
            }
            .accessibilityLabel(Text("Gistsmith'e sor"))
            // The dictation bar has no letters to suggest for: only the big Voice type button.
            if model.suggestions.items.isEmpty, !model.isDictationBar, model.pastableDictation != nil, isMicIdle {
                pasteDictationButton
            } else if model.suggestions.items.isEmpty || model.isDictationBar, model.showsMicrophone {
                voiceTypeButton
            }
            ForEach(Array((model.isDictationBar ? [] : model.suggestions.items).enumerated()), id: \.offset) { (index: Int, suggestion: KeyboardSuggestion) in
                if index > 0 {
                    Divider().frame(height: 22)
                }
                Button {
                    actions.pickSuggestion(suggestion)
                } label: {
                    Text(suggestion.kind == .typed ? "“\(suggestion.text)”" : suggestion.text)
                        .font(.system(size: 16, weight: suggestion.text == model.suggestions.autocorrection ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(ink(model.isDark))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(suggestion.text == model.suggestions.autocorrection ? ink(model.isDark).opacity(0.1) : .clear)
                        )
                }
            }
            if model.suggestions.items.isEmpty, !model.showsMicrophone {
                Spacer()
            }
        }
        .padding(.horizontal, 4)
    }

    private var isMicrophoneWarm: Bool {
        if case .idle(let remaining?) = model.micState {
            return remaining > 0
        }
        return false
    }

    /// "Paste dictation": the last dictation did not go into a field (it expired, the field changed, the panel was
    /// closed); one tap puts it here.
    private var pasteDictationButton: some View {
        Button(action: actions.pasteDictation) {
            HStack(spacing: 8) {
                Image(systemName: "text.insert")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Dikteyi yapıştır")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ink(model.isDark))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: 36)
            .background(Capsule().fill(ink(model.isDark).opacity(model.isDark ? 0.14 : 0.07)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5))
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
        .accessibilityHint(Text("Son dikteyi bu alana ekler"))
    }

    /// The wide "Voice type" capsule: one tap starts dictating into this field.
    private var voiceTypeButton: some View {
        Button(action: actions.startVoiceTyping) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Sesle yaz")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(ink(model.isDark))
                    .lineLimit(1)
                if isMicrophoneWarm {
                    // The microphone is ready in Gistsmith: the next tap dictates here without opening the app.
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 36)
            .background(Capsule().fill(ink(model.isDark).opacity(model.isDark ? 0.14 : 0.07)))
            .overlay(Capsule().strokeBorder(ink(model.isDark).opacity(0.08), lineWidth: 0.5))
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
    }
}

/// The dictation, compact: a status line (recording dot and time, or the heard words when the field is another one; the
/// voice language on the right), a capsule with cancel, the voice field (`KeyboardParticleField`) and Done, and a row with space, delete and
/// return. A key in that row finishes the dictation first; its action follows once the text is in. The keyboard is
/// shorter while it shows (`KeyboardViewController.keyboardHeight`). Done takes the theme's fill; the rest is quiet ink.
/// With Reduce Motion nothing moves.
struct KeyboardDictationView: View {
    let model: KeyboardModel
    let actions: KeyboardActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 10) {
            statusLine
                .frame(height: 22)
                .padding(.horizontal, 10)
            capsule
                .frame(height: 52)
            keyRow
                .frame(height: 46)
        }
        .padding(.horizontal, 6)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88), value: stage)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    private var ink: Color {
        model.isDark ? .white : .black
    }

    /// The panel's stage, for the animated changes between them.
    private var stage: Int {
        switch model.translation {
        case .translating:
            return 6
        case .failed:
            return 7
        case nil:
            break
        }
        return switch model.micState {
        case .starting: 1
        case .listening: 2
        case .finishing: 3
        case .finished: 4
        case .failed: 5
        case .needsFullAccess, .idle: 0
        }
    }

    // MARK: Status line

    @ViewBuilder
    private var statusLine: some View {
        HStack(spacing: 8) {
            switch model.micState {
            case .finishing where model.isPolishing:
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Düzenleniyor…")
                    .foregroundStyle(ink.opacity(0.75))
            case .finished where model.translation == .translating:
                Text("Çevriliyor…")
                    .foregroundStyle(ink.opacity(0.6))
            case .listening(let text) where !model.isLiveTyping && !text.isEmpty:
                recordingDot
                heard(text)
            case .finishing(let text) where !model.isLiveTyping && !text.isEmpty:
                heard(text)
            case .finished(let text, _):
                heard(text)
            case .listening, .starting:
                recordingDot
                elapsed
            case .finishing:
                Text("Yazıya dökülüyor…")
                    .foregroundStyle(ink.opacity(0.6))
            case .failed, .needsFullAccess, .idle:
                EmptyView()
            }
            Spacer(minLength: 8)
            Text(model.voiceLanguageName)
                .foregroundStyle(ink.opacity(0.55))
        }
        .font(.system(size: 15, weight: .medium))
        .lineLimit(1)
    }

    private var recordingDot: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var elapsed: some View {
        KeyboardDictationElapsed(model: model, color: ink.opacity(0.85))
            .accessibilityLabel(Text("Dinliyor… konuş"))
    }

    private func heard(_ text: String) -> some View {
        Text(text)
            .truncationMode(.head)
            .foregroundStyle(ink.opacity(0.85))
            .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: Capsule

    private var capsule: some View {
        HStack(spacing: 8) {
            Button(action: actions.cancelDictation) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(ink.opacity(model.isDark ? 0.12 : 0.07)))
            }
            .accessibilityLabel(Text("Vazgeç"))
            middle
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            trailing
        }
        .padding(.horizontal, 6)
        .background(Capsule().fill(ink.opacity(model.isDark ? 0.07 : 0.045)))
        .overlay(Capsule().strokeBorder(ink.opacity(model.isDark ? 0.08 : 0.06), lineWidth: 0.5))
    }

    /// One field for every listening stage, so it keeps its motion from start to Done (only its mode changes).
    @ViewBuilder
    private var middle: some View {
        if case .failed(let failure) = model.translation {
            Text(translationFailureText(failure))
                .font(.system(size: 13))
                .foregroundStyle(ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.75)
        } else if case .failed(let failure) = model.micState {
            Text(failureText(failure))
                .font(.system(size: 13))
                .foregroundStyle(ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        } else {
            KeyboardVoiceField(model: model, mode: fieldMode)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        }
    }

    private var fieldMode: KeyboardParticleField.Mode {
        if model.translation == .translating {
            return .processing
        }
        return switch model.micState {
        case .listening:
            .listening
        case .starting, .finishing:
            .processing
        case .finished, .failed, .needsFullAccess, .idle:
            .still
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.translation {
        case .translating:
            pill(title: String(localized: "Bitti"), action: {})
                .disabled(true)
                .opacity(0.45)
        case .failed:
            pill(title: String(localized: "Çevirmeden ekle"), action: actions.insertUntranslatedDictation)
        case nil:
            micTrailing
        }
    }

    @ViewBuilder
    private var micTrailing: some View {
        switch model.micState {
        case .listening:
            pill(title: String(localized: "Bitti"), action: actions.finishDictation)
                .accessibilityLabel(Text("Bitir ve ekle"))
        case .starting, .finishing:
            pill(title: String(localized: "Bitti"), action: {})
                .disabled(true)
                .opacity(0.45)
        case .finished(_, false):
            pill(title: String(localized: "Ekle"), action: actions.insertFinishedDictation)
        case .failed(.microphoneDenied), .failed(.unsupportedLanguage), .failed(.recordingMeeting):
            Color.clear.frame(width: 1, height: 40)
        case .failed:
            pill(title: String(localized: "Yeniden dene"), action: actions.startVoiceTyping)
        case .needsFullAccess, .idle, .finished:
            Color.clear.frame(width: 1, height: 40)
        }
    }

    private func pill(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.brand.onFill(isDark: model.isDark))
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(Capsule().fill(model.brand.fill(isDark: model.isDark)))
        }
    }

    // MARK: Key row

    private var keyRow: some View {
        HStack(spacing: 6) {
            key(label: Text("boşluk").font(.system(size: 16)), key: .space)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text("boşluk"))
            key(label: Image(systemName: "delete.left").font(.system(size: 18)), key: .delete)
                .frame(width: 64)
                .accessibilityLabel(Text("sil"))
            key(label: Image(systemName: "return").font(.system(size: 18)), key: .newline)
                .frame(width: 72)
                .accessibilityLabel(Text("satır başı"))
        }
    }

    private func key(label: some View, key: KeyboardDictationKey) -> some View {
        Button(action: { actions.dictationKey(key) }) {
            label
                .foregroundStyle(ink.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8.5, style: .continuous).fill(ink.opacity(model.isDark ? 0.14 : 0.08)))
        }
        .buttonStyle(.plain)
    }

    private func translationFailureText(_ failure: KeyboardTranslationFailure) -> String {
        switch failure {
        case .notInstalled:
            String(localized: "Çeviri dilleri bu iPhone'a indirilmemiş. Gistsmith › Ayarlar › Klavye'den indir.")
        case .unsupportedPair:
            String(localized: "Bu dil çifti cihazda çevrilemiyor. Gistsmith › Ayarlar › Klavye'den başka dil seç.")
        case .failed:
            String(localized: "Çevrilemedi. Yeniden konuş ya da çevirmeden ekle.")
        }
    }

    private func failureText(_ failure: KeyboardDictationFailure) -> String {
        switch failure {
        case .noSpeech:
            String(localized: "Konuşma duyulmadı. Mikrofona dokunup yeniden dene.")
        case .microphoneDenied:
            String(localized: "Gistsmith'in mikrofon izni kapalı (Ayarlar › Gistsmith).")
        case .unsupportedLanguage:
            String(localized: "Bu dil için cihaz içi dikte yok.")
        case .recordingMeeting:
            String(localized: "Toplantı kaydı sürüyor; mikrofon toplantıda.")
        case .failed:
            String(localized: "Yazıya dökülemedi. Yeniden dene.")
        }
    }
}

/// A key in the dictation panel's row.
enum KeyboardDictationKey: Equatable {
    case space
    case delete
    case newline
}

/// "0:07", "1:12": the dictation's running time. Pure function.
func keyboardElapsedText(seconds: TimeInterval) -> String {
    let whole: Int = max(0, Int(seconds))
    return String(format: "%d:%02d", whole / 60, whole % 60)
}

/// How many recent voice levels the keyboard keeps for the dictation panel.
let keyboardVoiceLevelHistoryLimit: Int = 8

/// Tuşların yerini alan paneller: emoji, Gistsmith'ten ekle, sesle yazma bilgisi.
struct KeyboardPanelView: View {
    let model: KeyboardModel
    let actions: KeyboardActions

    var body: some View {
        Group {
            switch model.panel {
            case .none:
                EmptyView()
            case .emoji:
                KeyboardEmojiPanel(model: model, actions: actions)
            case .gistsmith:
                KeyboardGistsmithPanel(model: model, actions: actions)
            case .voiceInfo(let info):
                voiceInfo(info)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    private func voiceInfoButton(_ info: KeyboardVoiceInfo) -> (String, () -> Void)? {
        switch info {
        case .needsFullAccess: (String(localized: "Ayarları aç"), actions.openSettings)
        case .needsAccount: (String(localized: "Giriş yap"), actions.openGistsmithSignIn)
        case .openGistsmithManually: nil
        }
    }

    private func voiceInfo(_ info: KeyboardVoiceInfo) -> some View {
        let title: String
        let message: String
        switch info {
        case .needsFullAccess:
            title = String(localized: "Sesle yazma için Tam Erişim'i aç")
            message = String(localized: "Klavyeler mikrofonu kullanamaz; ses Gistsmith'te, bu iPhone'da yazıya dökülür. Bunun için Ayarlar › Gistsmith › Klavyeler'de Tam Erişim'i aç. Yazdıkların hiçbir yere gönderilmez.")
        case .needsAccount:
            title = String(localized: "Sor için Gistsmith'e giriş yap")
            message = String(localized: "Sor, toplantı notlarından cevap verir; bunun için bir Gistsmith hesabı gerekir. Yazmak ve sesle yazmak hesapsız çalışır.")
        case .openGistsmithManually:
            title = String(localized: "Gistsmith'i aç ve sesle yazmayı başlat")
            message = String(localized: "Gistsmith'te Ayarlar › Klavye › Mikrofonu hazırla'ya dokun, sonra bu uygulamaya dön ve mikrofona dokun.")
        }
        return KeyboardMessage(
            model: model, actions: actions, symbol: info == .needsAccount ? "sparkles" : "mic", title: title, message: message,
            button: voiceInfoButton(info)
        )
    }
}

/// Panelde tek mesaj: başlık ve açıklama (sığmazsa kayar); düğme alt satırda "ABC"nin yanında, her zaman görünür.
struct KeyboardMessage: View {
    let model: KeyboardModel
    let actions: KeyboardActions
    let symbol: String
    let title: String
    let message: String
    let button: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 6) {
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: symbol)
                            .foregroundStyle(Color.accentColor)
                    }
                    .font(.system(.headline))
                    .foregroundStyle(ink(model.isDark))
                    .multilineTextAlignment(.center)
                    Text(message)
                        .font(.system(.subheadline))
                        .foregroundStyle(ink(model.isDark).opacity(0.7))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            KeyboardPanelFooter(model: model, actions: actions, trailing: button.map { (button: (String, () -> Void)) -> AnyView in
                AnyView(
                    Button(action: button.1) {
                        Text(button.0)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
                    }
                )
            })
        }
    }
}

/// Panelin alt satırı: "ABC" (tuşlara dön), ortada isteğe bağlı içerik, sağda silme.
struct KeyboardPanelFooter<Trailing: View>: View {
    let model: KeyboardModel
    let actions: KeyboardActions
    let trailing: Trailing?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: actions.closePanel) {
                Text("ABC")
                    .font(.system(size: 16))
                    .foregroundStyle(ink(model.isDark))
                    .frame(width: 56, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink(model.isDark).opacity(0.12)))
            }
            .accessibilityLabel(Text("Harflere dön"))
            if let trailing {
                trailing
            } else {
                Spacer()
            }
            Button(action: actions.deleteBackward) {
                Image(systemName: "delete.left")
                    .font(.system(size: 18))
                    .foregroundStyle(ink(model.isDark))
                    .frame(width: 56, height: 40)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ink(model.isDark).opacity(0.12)))
            }
            .accessibilityLabel(Text("sil"))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

/// Emoji paneli: kategoriler, son kullanılanlar; yatay kayar (sistem klavyesindeki gibi).
struct KeyboardEmojiPanel: View {
    let model: KeyboardModel
    let actions: KeyboardActions

    private var shown: [String] {
        switch model.emojiCategory {
        case nil:
            model.recentEmoji.isEmpty ? keyboardEmoji(category: .smileysAndPeople) : model.recentEmoji
        case .some(let category):
            keyboardEmoji(category: category)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(40), spacing: 2), count: 4), spacing: 2) {
                    ForEach(shown, id: \.self) { (base: String) in
                        let emoji: String = keyboardEmojiApplyingTone(emoji: base, tone: model.skinTone)
                        Button {
                            actions.insertEmoji(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 30))
                                .frame(width: 42, height: 40)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .id(model.emojiCategory)
            KeyboardPanelFooter(model: model, actions: actions, trailing: categoryBar)
        }
        .padding(.top, 4)
    }

    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                // Ten rengi önde: kayan kategori satırının sonunda görünmezdi.
                Button(action: actions.cycleSkinTone) {
                    Text(keyboardEmojiApplyingTone(emoji: "✋", tone: model.skinTone))
                        .font(.system(size: 18))
                        .frame(width: 34, height: 40)
                }
                .accessibilityLabel(Text("Ten rengi"))
                categoryButton(category: nil, symbol: "clock", label: String(localized: "Son kullanılanlar"))
                ForEach(KeyboardEmojiCategory.allCases, id: \.self) { (category: KeyboardEmojiCategory) in
                    categoryButton(category: category, symbol: symbol(category), label: label(category))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func categoryButton(category: KeyboardEmojiCategory?, symbol: String, label: String) -> some View {
        Button {
            model.emojiCategory = category
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(ink(model.isDark).opacity(model.emojiCategory == category ? 1 : 0.5))
                .frame(width: 32, height: 40)
        }
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(model.emojiCategory == category ? .isSelected : [])
    }

    private func symbol(_ category: KeyboardEmojiCategory) -> String {
        switch category {
        case .smileysAndPeople: "face.smiling"
        case .animalsAndNature: "pawprint"
        case .foodAndDrink: "fork.knife"
        case .activities: "soccerball"
        case .travelAndPlaces: "car"
        case .objects: "lightbulb"
        case .symbols: "number"
        case .flags: "flag"
        }
    }

    private func label(_ category: KeyboardEmojiCategory) -> String {
        switch category {
        case .smileysAndPeople: String(localized: "İfadeler ve insanlar")
        case .animalsAndNature: String(localized: "Hayvanlar ve doğa")
        case .foodAndDrink: String(localized: "Yiyecek ve içecek")
        case .activities: String(localized: "Etkinlikler")
        case .travelAndPlaces: String(localized: "Seyahat ve yerler")
        case .objects: String(localized: "Nesneler")
        case .symbols: String(localized: "Simgeler")
        case .flags: String(localized: "Bayraklar")
        }
    }
}

/// "Gistsmith'ten ekle": son toplantılar; birine dokununca özet, eylem maddeleri ya da görevlerim eklenir.
struct KeyboardGistsmithPanel: View {
    let model: KeyboardModel
    let actions: KeyboardActions
    @State private var selected: KeyboardMeetingItem?

    var body: some View {
        if !model.hasFullAccess {
            KeyboardMessage(
                model: model, actions: actions, symbol: "text.badge.plus", title: String(localized: "Toplantı notlarını eklemek için Tam Erişim'i aç"),
                message: String(localized: "Klavye toplantı listesini yalnız bu iPhone'da, Gistsmith'ten okur; hiçbir şey gönderilmez."),
                button: (String(localized: "Ayarları aç"), actions.openSettings)
            )
        } else if let meetings = model.meetings {
            VStack(spacing: 0) {
                if let selected {
                    parts(of: selected)
                } else if meetings.isEmpty {
                    Spacer()
                    Text("Henüz toplantı yok.")
                        .font(.system(.subheadline))
                        .foregroundStyle(ink(model.isDark).opacity(0.6))
                    Spacer()
                } else {
                    List(meetings) { (meeting: KeyboardMeetingItem) in
                        Button {
                            selected = meeting
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .font(.system(.subheadline, weight: .semibold))
                                    .foregroundStyle(ink(model.isDark))
                                    .lineLimit(1)
                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(.caption))
                                    .foregroundStyle(ink(model.isDark).opacity(0.6))
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                KeyboardPanelFooter(model: model, actions: actions, trailing: nil as EmptyView?)
            }
        } else {
            KeyboardMessage(
                model: model, actions: actions, symbol: "text.badge.plus", title: String(localized: "Klavyede toplantı notları kapalı"),
                message: String(localized: "Gistsmith'te Ayarlar › Klavye › Klavyede toplantı notları'nı aç: son toplantılarının özetini ve görevlerini her uygulamaya ekleyebilirsin."),
                button: (String(localized: "Gistsmith'i aç"), actions.openGistsmithSetup)
            )
        }
    }

    private func parts(of meeting: KeyboardMeetingItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    selected = nil
                } label: {
                    Label(meeting.title, systemImage: "chevron.left")
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                }
                ForEach(KeyboardMeetingPart.allCases, id: \.self) { (part: KeyboardMeetingPart) in
                    if let text = keyboardMeetingText(meeting: meeting, part: part) {
                        Button {
                            actions.insertMeetingText(text)
                            selected = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(partTitle(part))
                                    .font(.system(.subheadline, weight: .semibold))
                                    .foregroundStyle(ink(model.isDark))
                                Text(text)
                                    .font(.system(.caption))
                                    .foregroundStyle(ink(model.isDark).opacity(0.65))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(ink(model.isDark).opacity(0.08)))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private func partTitle(_ part: KeyboardMeetingPart) -> String {
        switch part {
        case .summary: String(localized: "Özet")
        case .actionItems: String(localized: "Eylem maddeleri")
        case .myTasks: String(localized: "Görevlerim")
        }
    }
}

/// The blinking caret of the question field, in the accent colour; it stays on under Reduce Motion
/// (`keyboardAskCaretIsVisible`).
struct KeyboardAskCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool
    @State private var shownAt: Date = Date()

    var body: some View {
        TimelineView(.periodic(from: shownAt, by: 0.53)) { (context: TimelineViewDefaultContext) in
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: 19)
                .opacity(keyboardAskCaretIsVisible(elapsed: context.date.timeIntervalSince(shownAt), reduceMotion: reduceMotion) ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}

/// "Ask Gistsmith" over the keys (the strip above shows the question): the particle field while Gistsmith looks through
/// the meetings, then the whole answer, written out word by word, with Add, Copy and Ask again; or why there is none.
/// The keyboard keeps its height, so the app underneath does not jump.
struct KeyboardAskPanel: View {
    let model: KeyboardModel
    let actions: KeyboardActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        Group {
            switch model.askState {
            case .awaitingApp:
                thinking(String(localized: "Gistsmith açılınca sorulacak…"))
            case .answering:
                thinking(String(localized: "Gistsmith toplantılarına bakıyor…"))
            case .answered(let answer):
                answerCard(answer)
            case .failed(let reason):
                problem(reason ?? String(localized: "Cevap alınamadı. Yeniden sor."))
            case .notDelivered:
                problem(String(localized: "Soru Gistsmith'e ulaşmadı. Gistsmith'i açıp yeniden sor."))
            case .idle:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: model.askState)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    private var ink: Color {
        model.isDark ? .white : .black
    }

    // MARK: Thinking

    private func thinking(_ status: String) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            KeyboardThinkingField(model: model)
                .frame(height: 64)
            .accessibilityHidden(true)
            Text(status)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ink.opacity(0.6))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .transition(.opacity)
    }

    // MARK: Answer

    private func answerCard(_ answer: String) -> some View {
        VStack(spacing: 10) {
            ScrollView(.vertical) {
                KeyboardAnswerText(model: model, answer: answer, color: ink.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .modifier(KeyboardNoScrollEdgeEffect())
            HStack(spacing: 8) {
                Button(action: actions.insertAnswer) {
                    Label("Ekle", systemImage: "text.insert")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(model.brand.onFill(isDark: model.isDark))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(model.brand.fill(isDark: model.isDark)))
                }
                Button(action: actions.copyAnswer) {
                    Label(model.askAnswerCopied ? "Kopyalandı" : "Kopyala", systemImage: model.askAnswerCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.85))
                        .padding(.horizontal, 16)
                        .frame(height: 44)
                        .background(Capsule().fill(ink.opacity(0.08)))
                }
                Button(action: actions.askAgain) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(ink.opacity(0.08)))
                }
                .accessibilityLabel(Text("Yeniden sor"))
            }
        }
        .padding(12)
        .background(cardBackground)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var cardBackground: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let tint: Color = model.brand.tint(isDark: model.isDark)
        return shape
            .fill(ink.opacity(model.isDark ? 0.07 : 0.045))
            .overlay(shape.fill(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(shape.strokeBorder(tint.opacity(0.28), lineWidth: 1))
    }

    // MARK: Problem

    private func problem(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 24))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 8) {
                if model.askCanOpenInGistsmith {
                    Button(action: actions.openAskInGistsmith) {
                        Text("Gistsmith'te aç")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(model.brand.onFill(isDark: model.isDark))
                            .padding(.horizontal, 18)
                            .frame(height: 42)
                            .background(Capsule().fill(model.brand.fill(isDark: model.isDark)))
                    }
                }
                Button(action: actions.askAgain) {
                    Text("Yeniden sor")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.85))
                        .padding(.horizontal, 18)
                        .frame(height: 42)
                        .background(Capsule().fill(ink.opacity(0.08)))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .transition(.opacity)
    }
}

/// The card draws its own edge: iOS 26's scroll edge effect would put a line across its top.
private struct KeyboardNoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

/// The answer written out word by word from the moment it arrived (`keyboardAnswerReveal`, at `KeyboardModel.frameDate`); the
/// whole text holds its place from the start, so the card does not grow while it is written. Whole at once with Reduce
/// Motion.
private struct KeyboardAnswerText: View {
    let model: KeyboardModel
    let answer: String
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            text(answer).hidden()
            text(shown)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(answer))
    }

    private var shown: String {
        guard let arrivedAt = model.askAnswerArrivedAt, !reduceMotion else {
            return answer
        }
        return keyboardAnswerReveal(
            answer: answer, elapsed: max(0, model.frameDate.timeIntervalSince(arrivedAt)), wordsPerSecond: keyboardAnswerRevealWordsPerSecond
        )
    }

    private func text(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 16))
            .lineSpacing(3)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Frame readers
// Only these small views read `KeyboardModel.frameDate`, so each frame redraws them and not the panels around them.

/// The dictation's running time.
private struct KeyboardDictationElapsed: View {
    let model: KeyboardModel
    let color: Color

    var body: some View {
        Text(keyboardElapsedText(seconds: model.dictationStartedAt.map { max(0, model.frameDate.timeIntervalSince($0)) } ?? 0))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

/// The dictation panel's field, moved by the voice.
private struct KeyboardVoiceField: View {
    let model: KeyboardModel
    let mode: KeyboardParticleField.Mode

    var body: some View {
        KeyboardParticleField(brand: model.brand, isDark: model.isDark, levels: model.voiceLevels, mode: mode, date: model.frameDate)
    }
}

/// The Ask panel's field while the answer is on its way: a calm, breathing pull (no voice: it is fed a slow wave).
private struct KeyboardThinkingField: View {
    let model: KeyboardModel

    var body: some View {
        let time: Double = model.frameDate.timeIntervalSinceReferenceDate
        let level: Double = 0.42 + 0.2 * sin(time * 2.1) + 0.08 * sin(time * 5.3)
        KeyboardParticleField(brand: model.brand, isDark: model.isDark, levels: [level, level], mode: .listening, date: model.frameDate)
    }
}
