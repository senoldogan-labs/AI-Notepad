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

/// The dictation in place of the keys: cancel on the left, finish on the right, a large waveform while Gistsmith listens
/// and, under it, "Live typing on" (the words appear in the field as they are spoken) or the text when the field is
/// another one. Shown from the start until the text is in the field (`keyboardMicStateCoversKeys`).
struct KeyboardDictationView: View {
    let model: KeyboardModel
    let actions: KeyboardActions

    var body: some View {
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
            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .environment(\.colorScheme, model.isDark ? .dark : .light)
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.micState {
        case .listening:
            Button(action: actions.finishDictation) {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
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
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Capsule().fill(Color.accentColor))
        }
    }

    @ViewBuilder
    private var center: some View {
        switch model.micState {
        case .starting:
            status(text: String(localized: "Gistsmith dinlemeye hazırlanıyor…"), showsProgress: true)
        case .listening(let text):
            VStack(spacing: 14) {
                KeyboardWaveform()
                    .frame(height: 56)
                    .accessibilityHidden(true)
                if model.isLiveTyping {
                    liveTypingChip
                } else {
                    spokenText(text.isEmpty ? String(localized: "Dinliyor… konuş") : text, isPlaceholder: text.isEmpty)
                }
            }
        case .finishing(let text):
            if model.isLiveTyping || text.isEmpty {
                status(text: String(localized: "Yazıya dökülüyor…"), showsProgress: true)
            } else {
                spokenText(text, isPlaceholder: false)
            }
        case .finished(let text, _):
            spokenText(text, isPlaceholder: false)
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
        Label {
            Text("Canlı yazım açık")
        } icon: {
            Image(systemName: "text.cursor")
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5))
    }

    private func status(text: String, showsProgress: Bool) -> some View {
        VStack(spacing: 12) {
            if showsProgress {
                ProgressView()
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(ink(model.isDark).opacity(0.6))
                .multilineTextAlignment(.center)
        }
    }

    private func spokenText(_ text: String, isPlaceholder: Bool) -> some View {
        Text(text)
            .font(.system(size: 16))
            .foregroundStyle(ink(model.isDark).opacity(isPlaceholder ? 0.55 : 1))
            .lineLimit(3)
            .truncationMode(.head)
            .multilineTextAlignment(.center)
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

/// The listening waveform of the dictation panel: eleven accent bars that move while Gistsmith listens (drawn by the
/// keyboard; no audio reaches the extension, so the motion says "listening", not the voice's loudness). Still bars with
/// Reduce Motion.
struct KeyboardWaveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            bars(time: 0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { (timeline: TimelineViewDefaultContext) in
                bars(time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func bars(time: TimeInterval) -> some View {
        GeometryReader { (proxy: GeometryProxy) in
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<11, id: \.self) { (index: Int) in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: proxy.size.height * keyboardWaveformHeight(index: index, time: time))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One bar's height (0.25…1) at `time`: overlapping slow waves with a per-bar phase, so the bars never move in step.
/// Pure function.
func keyboardWaveformHeight(index: Int, time: TimeInterval) -> CGFloat {
    let phase: Double = Double(index) * 0.9
    let wave: Double = (sin(time * 6.1 + phase) + sin(time * 3.7 + phase * 1.7)) / 4 + 0.5
    return CGFloat(0.25 + 0.75 * wave)
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
