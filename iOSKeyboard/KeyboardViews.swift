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
            Text(model.askQuestion.isEmpty ? String(localized: "Gistsmith'e sor…") : model.askQuestion)
                .font(.system(size: 15))
                .foregroundStyle(ink(model.isDark).opacity(model.askQuestion.isEmpty ? 0.5 : 1))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// The dictation in place of the keys: cancel on the left, finish on the right, a large waveform over a soft accent glow
/// while listening and, under it, "Live typing on" (the words appear in the field as they are spoken) or the text, its
/// newest words in the accent. Colours follow the app's theme (`KeyboardBrand`). Shown from the start until the text is
/// in the field (`keyboardMicStateCoversKeys`). With Reduce Motion nothing moves and states change without animation.
struct KeyboardDictationView: View {
    let model: KeyboardModel
    let actions: KeyboardActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        ZStack {
            KeyboardDictationGlow(brand: model.brand, isDark: model.isDark, isListening: isListening, levels: model.voiceLevels)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    Button(action: actions.cancelDictation) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ink(model.isDark).opacity(0.75))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(ink(model.isDark).opacity(model.isDark ? 0.16 : 0.08)))
                    }
                    .accessibilityLabel(Text("Vazgeç"))
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Spacer(minLength: 6)
                center
                    .padding(.horizontal, 20)
                    .id(stage)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96)))
                Spacer(minLength: 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: stage)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    private var isListening: Bool {
        if case .listening = model.micState {
            return true
        }
        return false
    }

    /// The panel's stage, for the cross-fade between them (the text changing inside a stage does not count).
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

    @ViewBuilder
    private var trailing: some View {
        switch model.micState {
        case .listening:
            Button(action: actions.finishDictation) {
                ZStack {
                    KeyboardFinishPulse(color: model.brand.fill(isDark: model.isDark))
                        .accessibilityHidden(true)
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(model.brand.onFill(isDark: model.isDark))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(model.brand.fill(isDark: model.isDark)))
                        .shadow(color: model.brand.fill(isDark: model.isDark).opacity(0.45), radius: 8, y: 3)
                }
            }
            .accessibilityLabel(Text("Bitir ve ekle"))
        case .finished(_, false):
            capsuleButton(title: String(localized: "Ekle"), action: actions.insertFinishedDictation)
        case .failed(.microphoneDenied), .failed(.unsupportedLanguage), .failed(.recordingMeeting):
            EmptyView()
        case .failed:
            capsuleButton(title: String(localized: "Yeniden dene"), action: actions.startVoiceTyping)
        case .needsFullAccess, .idle, .starting, .finishing, .finished:
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func capsuleButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(model.brand.onFill(isDark: model.isDark))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Capsule().fill(model.brand.fill(isDark: model.isDark)))
                .shadow(color: model.brand.fill(isDark: model.isDark).opacity(0.35), radius: 6, y: 2)
        }
    }

    @ViewBuilder
    private var center: some View {
        switch model.micState {
        case .starting:
            VStack(spacing: 14) {
                KeyboardProcessingDots(color: model.brand.tint(isDark: model.isDark))
                    .frame(height: 56)
                    .accessibilityHidden(true)
                status(text: String(localized: "Gistsmith dinlemeye hazırlanıyor…"))
            }
        case .listening(let text):
            VStack(spacing: 14) {
                KeyboardWaveform(color: model.brand.tint(isDark: model.isDark), levels: model.voiceLevels)
                    .frame(height: 56)
                    .accessibilityHidden(true)
                if model.isLiveTyping {
                    liveTypingChip
                } else if text.isEmpty {
                    spokenPlaceholder(String(localized: "Dinliyor… konuş"))
                } else {
                    spokenText(text)
                }
            }
        case .finishing(let text):
            VStack(spacing: 14) {
                KeyboardProcessingDots(color: model.brand.tint(isDark: model.isDark))
                    .frame(height: 56)
                    .accessibilityHidden(true)
                if model.isLiveTyping || text.isEmpty {
                    status(text: String(localized: "Yazıya dökülüyor…"))
                } else {
                    spokenText(text)
                }
            }
        case .finished(let text, _):
            spokenText(text)
        case .failed(let failure):
            VStack(spacing: 10) {
                Image(systemName: "mic.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(ink(model.isDark).opacity(0.5))
                    .accessibilityHidden(true)
                Text(failureText(failure))
                    .font(.system(size: 15))
                    .foregroundStyle(ink(model.isDark).opacity(0.75))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .needsFullAccess, .idle:
            EmptyView()
        }
    }

    private var liveTypingChip: some View {
        let tint: Color = model.brand.tint(isDark: model.isDark)
        return Label {
            Text("Canlı yazım açık")
        } icon: {
            Image(systemName: "text.cursor")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 0.5))
    }

    private func status(text: String) -> some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(ink(model.isDark).opacity(0.6))
            .multilineTextAlignment(.center)
    }

    private func spokenPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(ink(model.isDark).opacity(0.55))
            .multilineTextAlignment(.center)
    }

    /// The heard text, its last three words in the accent: the eye follows where the voice is.
    private func spokenText(_ text: String) -> some View {
        Text(keyboardSpokenText(text: text, ink: ink(model.isDark), accent: model.brand.tint(isDark: model.isDark)))
            .font(.system(size: 17, weight: .regular))
            .lineLimit(3)
            .truncationMode(.head)
            .multilineTextAlignment(.center)
            .contentTransition(reduceMotion ? .identity : .interpolate)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: text)
            .accessibilityLabel(Text(text))
            .accessibilityAddTraits(.updatesFrequently)
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

/// The heard text with its last three words in the accent and the rest in the ink. Pure function.
func keyboardSpokenText(text: String, ink: Color, accent: Color) -> AttributedString {
    let words: [Substring] = text.split(separator: " ", omittingEmptySubsequences: false)
    let headCount: Int = max(0, words.count - 3)
    let head: String = words.prefix(headCount).joined(separator: " ")
    let tail: String = words.suffix(words.count - headCount).joined(separator: " ")
    var older: AttributedString = AttributedString(head.isEmpty ? "" : head + " ")
    older.foregroundColor = ink.opacity(0.78)
    var newest: AttributedString = AttributedString(tail)
    newest.foregroundColor = accent
    return older + newest
}

/// How many bars the waveform draws (and how many voice levels the keyboard keeps).
let keyboardWaveformBarCount: Int = 28

/// The listening waveform: symmetric accent bars with a soft top-to-bottom fade. With the keyboard's own capture the
/// bars are the voice's loudness scrolling right to left (`KeyboardModel.voiceLevels`); when Gistsmith listens no audio
/// reaches the keyboard, so slow overlapping waves say "listening". Still bars with Reduce Motion.
struct KeyboardWaveform: View {
    let color: Color
    let levels: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            bars(heights: (0..<keyboardWaveformBarCount).map { (_: Int) -> CGFloat in 0.3 })
        } else if !levels.isEmpty {
            bars(heights: keyboardWaveformLevelHeights(levels: levels, count: keyboardWaveformBarCount))
                .animation(.spring(response: 0.22, dampingFraction: 0.78), value: levels)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { (timeline: TimelineViewDefaultContext) in
                bars(heights: (0..<keyboardWaveformBarCount).map { (index: Int) -> CGFloat in
                    keyboardWaveformHeight(index: index, time: timeline.date.timeIntervalSinceReferenceDate)
                })
            }
        }
    }

    private func bars(heights: [CGFloat]) -> some View {
        GeometryReader { (proxy: GeometryProxy) in
            HStack(alignment: .center, spacing: 4) {
                ForEach(heights.indices, id: \.self) { (index: Int) in
                    Capsule()
                        .fill(LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: max(4, proxy.size.height * heights[index]))
                        // The newest bars on the right are the brightest.
                        .opacity(0.45 + 0.55 * Double(index + 1) / Double(heights.count))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Bar heights (0.08…1) from the voice levels, newest on the right; missing older bars sit at the floor. Pure function.
func keyboardWaveformLevelHeights(levels: [Double], count: Int) -> [CGFloat] {
    let recent: [Double] = Array(levels.suffix(count))
    let padded: [Double] = [Double](repeating: 0, count: count - recent.count) + recent
    return padded.map { (level: Double) -> CGFloat in CGFloat(0.08 + 0.92 * level) }
}

/// A soft accent glow behind the dictation: a radial gradient, brighter and wider with the voice while listening (or
/// breathing slowly when no audio reaches the keyboard), faint otherwise. No blur (drawn as a gradient; cheap).
struct KeyboardDictationGlow: View {
    let brand: KeyboardBrand
    let isDark: Bool
    let isListening: Bool
    let levels: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if isListening, !reduceMotion, levels.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { (timeline: TimelineViewDefaultContext) in
                glow(strength: 0.55 + 0.25 * sin(timeline.date.timeIntervalSinceReferenceDate * 1.6))
            }
        } else {
            glow(strength: isListening ? 0.45 + 0.55 * (levels.suffix(4).max() ?? 0) : 0.3)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: levels.suffix(4).max() ?? 0)
        }
    }

    private func glow(strength: Double) -> some View {
        GeometryReader { (proxy: GeometryProxy) in
            // The fill colour (Olive's lime in light mode, not its darkened text olive, which reads grey as a glow).
            let tint: Color = brand.fill(isDark: isDark)
            // A wide ellipse that fades out before the panel's edges (a circle reaching them would end in a hard line).
            RadialGradient(
                colors: [tint.opacity((isDark ? 0.30 : 0.32) * strength), tint.opacity(0)], center: .center, startRadius: 0,
                endRadius: proxy.size.height * (0.36 + 0.1 * strength)
            )
            .scaleEffect(x: max(1, proxy.size.width / max(proxy.size.height, 1)) * 0.9, y: 1)
        }
    }
}

/// The finish button's slow ring: it widens and fades every 1.6 s while listening (none with Reduce Motion).
struct KeyboardFinishPulse: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            Color.clear.frame(width: 44, height: 44)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { (timeline: TimelineViewDefaultContext) in
                let phase: Double = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Circle()
                    .stroke(color, lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .scaleEffect(1 + 0.45 * phase)
                    .opacity(0.6 * (1 - phase))
            }
        }
    }
}

/// Getting ready or transcribing: short accent bars a bright spot sweeps across, left to right (still, dimmed bars with
/// Reduce Motion).
struct KeyboardProcessingDots: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            dots(time: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { (timeline: TimelineViewDefaultContext) in
                dots(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func dots(time: TimeInterval) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<13, id: \.self) { (index: Int) in
                let opacity: Double = keyboardProcessingDotOpacity(index: index, count: 13, time: time)
                Capsule()
                    .fill(color)
                    .frame(width: 4, height: 10 + 12 * opacity)
                    .opacity(opacity)
            }
        }
    }
}

/// One processing bar's opacity (0.25…1) at `time`: a bright spot that sweeps across the bars every 1.2 seconds. Pure
/// function.
func keyboardProcessingDotOpacity(index: Int, count: Int, time: TimeInterval) -> Double {
    let position: Double = (time.truncatingRemainder(dividingBy: 1.2) / 1.2) * Double(count + 2) - 1
    let distance: Double = abs(Double(index) - position)
    return 0.25 + 0.75 * max(0, 1 - distance / 2)
}

/// One bar's height (0.25…1) at `time`: overlapping slow waves with a per-bar phase, so the bars never move in step.
/// Pure function.
func keyboardWaveformHeight(index: Int, time: TimeInterval) -> CGFloat {
    let phase: Double = Double(index) * 0.55
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
