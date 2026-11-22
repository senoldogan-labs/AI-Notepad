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
            } else {
                micContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Sorunun durumu: cevaplanıyor, cevap (Ekle) ya da neden.
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
            switch model.askState {
            case .awaitingApp:
                ProgressView()
                Text("Gistsmith açılınca sorulacak…")
                    .font(.system(size: 15))
                    .foregroundStyle(ink(model.isDark).opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .answering:
                ProgressView()
                Text("Gistsmith toplantılarına bakıyor…")
                    .font(.system(size: 15))
                    .foregroundStyle(ink(model.isDark).opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .notDelivered:
                Text("Soru Gistsmith'e ulaşmadı. Gistsmith'i açıp yeniden sor.")
                    .font(.system(size: 14))
                    .foregroundStyle(ink(model.isDark).opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .answered(let answer):
                Text(answer)
                    .font(.system(size: 15))
                    .foregroundStyle(ink(model.isDark))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: actions.copyAnswer) {
                    Text(model.askAnswerCopied ? "Kopyalandı" : "Kopyala")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(Capsule().fill(ink(model.isDark).opacity(0.08)))
                }
                Button(action: actions.insertAnswer) {
                    Text("Ekle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Capsule().fill(Color.accentColor))
                }
            case .failed(let reason):
                Text(reason ?? String(localized: "Cevap alınamadı. Yeniden sor."))
                    .font(.system(size: 14))
                    .foregroundStyle(ink(model.isDark).opacity(0.7))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.askCanOpenInGistsmith {
                    Button(action: actions.openAskInGistsmith) {
                        Text("Gistsmith'te aç")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 8)
    }

    /// The suggestions, or the "Voice type" button while no word is being typed (the dictation itself covers the keys,
    /// `KeyboardDictationView`).
    private var micContent: some View {
        suggestionBar
    }

    private var suggestionBar: some View {
        HStack(spacing: 0) {
            Button(action: actions.openGistsmithPanel) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 18))
                    .foregroundStyle(ink(model.isDark).opacity(0.7))
                    .frame(width: 44, height: 40)
            }
            .accessibilityLabel(Text("Gistsmith'ten ekle"))
            Button(action: actions.startAsking) {
                Image(systemName: "sparkles")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel(Text("Gistsmith'e sor"))
            if model.suggestions.items.isEmpty, model.showsMicrophone {
                voiceTypeButton
            }
            ForEach(Array(model.suggestions.items.enumerated()), id: \.offset) { (index: Int, suggestion: KeyboardSuggestion) in
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
                        .frame(maxWidth: .infinity, minHeight: 40)
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
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Capsule().fill(ink(model.isDark).opacity(model.isDark ? 0.14 : 0.07)))
            .overlay(Capsule().strokeBorder(ink(model.isDark).opacity(0.08), lineWidth: 0.5))
        }
        .padding(.leading, 2)
        .padding(.trailing, 6)
    }
}

/// The dictation, compact: a status line (recording dot and time, or the heard words when the field is another one; the
/// voice language on the right), a capsule with cancel, a dot-matrix waveform and Done, and a row with space, delete and
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
        switch model.micState {
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
        TimelineView(.periodic(from: .now, by: 1)) { (timeline: TimelineViewDefaultContext) in
            Text(keyboardElapsedText(seconds: model.dictationStartedAt.map { timeline.date.timeIntervalSince($0) } ?? 0))
                .monospacedDigit()
                .foregroundStyle(ink.opacity(0.85))
        }
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

    @ViewBuilder
    private var middle: some View {
        switch model.micState {
        case .listening:
            KeyboardDotWaveform(ink: ink, levels: model.voiceLevels, mode: .listening)
                .accessibilityHidden(true)
        case .starting, .finishing:
            KeyboardDotWaveform(ink: ink, levels: [], mode: .working)
                .accessibilityHidden(true)
        case .finished:
            KeyboardDotWaveform(ink: ink, levels: [], mode: .still)
                .accessibilityHidden(true)
        case .failed(let failure):
            Text(failureText(failure))
                .font(.system(size: 13))
                .foregroundStyle(ink.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        case .needsFullAccess, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
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

/// How many columns the dot waveform draws (and how many voice levels the keyboard keeps).
let keyboardWaveformBarCount: Int = 44

/// The dot-matrix waveform: a grid of small dots; in each column the dots within the voice's height from the middle
/// light up, the rest stay faint, and both ends fade out. Listening with the keyboard's own capture, the columns are
/// the voice's loudness scrolling right to left (`KeyboardModel.voiceLevels`); when Gistsmith listens (no audio reaches
/// the keyboard) slow overlapping waves stand in. Working: a bright band sweeps across. Drawn in one `Canvas`.
struct KeyboardDotWaveform: View {
    enum Mode {
        case listening
        case working
        case still
    }

    let ink: Color
    let levels: [Double]
    let mode: Mode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if reduceMotion || mode == .still || (mode == .listening && !levels.isEmpty) {
            dots(time: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { (timeline: TimelineViewDefaultContext) in
                dots(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(time: TimeInterval) -> some View {
        let columns: Int = keyboardWaveformBarCount
        let rows: Int = 7
        let heights: [Double] = (0..<columns).map { (column: Int) -> Double in
            switch mode {
            case .listening:
                levels.isEmpty ? Double(keyboardWaveformHeight(index: column, time: time)) : keyboardDotColumnHeight(levels: levels, column: column, columns: columns)
            case .working:
                keyboardProcessingDotOpacity(index: column, count: columns, time: time) * 0.6
            case .still:
                0.12
            }
        }
        return Canvas { (context: inout GraphicsContext, size: CGSize) -> Void in
            let stepX: CGFloat = size.width / CGFloat(columns)
            let stepY: CGFloat = min(size.height / CGFloat(rows + 1), stepX)
            let radius: CGFloat = min(stepX, stepY) * 0.32
            let middle: CGFloat = size.height / 2
            for column in 0..<columns {
                let x: CGFloat = stepX * (CGFloat(column) + 0.5)
                let edge: Double = keyboardDotEdgeFade(column: column, columns: columns)
                let lit: Double = heights[column] * Double(rows) / 2
                for row in 0..<rows {
                    let offset: Double = abs(Double(row) - Double(rows - 1) / 2)
                    let on: Bool = offset <= lit
                    let alpha: Double = (on ? 0.92 - offset * 0.12 : 0.1) * edge
                    let y: CGFloat = middle + (CGFloat(row) - CGFloat(rows - 1) / 2) * stepY
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)), with: .color(ink.opacity(alpha))
                    )
                }
            }
        }
    }
}

/// A column's height (0…1) from the voice levels, newest on the right; older columns without a level are silent.
/// Pure function.
func keyboardDotColumnHeight(levels: [Double], column: Int, columns: Int) -> Double {
    let index: Int = levels.count - (columns - column)
    return index >= 0 && index < levels.count ? 0.15 + 0.85 * levels[index] : 0.15
}

/// How much a column is faded toward the ends (0…1): the outer sixth on each side fades out. Pure function.
func keyboardDotEdgeFade(column: Int, columns: Int) -> Double {
    let band: Double = Double(columns) / 6
    let fromEdge: Double = Double(min(column, columns - 1 - column)) + 0.5
    return min(1, fromEdge / band)
}

/// One processing column's brightness (0.25…1) at `time`: a bright spot that sweeps across every 1.2 seconds. Pure
/// function.
func keyboardProcessingDotOpacity(index: Int, count: Int, time: TimeInterval) -> Double {
    let position: Double = (time.truncatingRemainder(dividingBy: 1.2) / 1.2) * Double(count + 8) - 4
    let distance: Double = abs(Double(index) - position)
    return 0.25 + 0.75 * max(0, 1 - distance / 4)
}

/// One column's height (0.2…0.9) at `time`: overlapping slow waves with a per-column phase. Pure function.
func keyboardWaveformHeight(index: Int, time: TimeInterval) -> CGFloat {
    let phase: Double = Double(index) * 0.35
    let wave: Double = (sin(time * 5.3 + phase) + sin(time * 3.1 + phase * 1.7)) / 4 + 0.5
    return CGFloat(0.2 + 0.7 * wave)
}

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

    private func voiceInfo(_ info: KeyboardVoiceInfo) -> some View {
        let title: String
        let message: String
        switch info {
        case .needsFullAccess:
            title = String(localized: "Sesle yazma için Tam Erişim'i aç")
            message = String(localized: "Klavyeler mikrofonu kullanamaz; ses Gistsmith'te, bu iPhone'da yazıya dökülür. Bunun için Ayarlar › Gistsmith › Klavyeler'de Tam Erişim'i aç. Yazdıkların hiçbir yere gönderilmez.")
        case .openGistsmithManually:
            title = String(localized: "Gistsmith'i aç ve sesle yazmayı başlat")
            message = String(localized: "Gistsmith'te Ayarlar › Klavye › Mikrofonu hazırla'ya dokun, sonra bu uygulamaya dön ve mikrofona dokun.")
        }
        return KeyboardMessage(
            model: model, actions: actions, symbol: "mic", title: title, message: message,
            button: info == .needsFullAccess ? (String(localized: "Ayarları aç"), actions.openSettings) : nil
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
