import AINotepadCore
import AINotepadUI
import KeyboardCore
import SwiftUI

/// Ayarlar › Klavye: hazır kartı (ya da eksik adım ve kuruluma devam), diller, kendiliğinden düzeltme, sesle yazma, klavyede toplantı notları ve sözlük.
struct PhoneKeyboardSettingsList: View {
    let store: PhoneStore
    @State private var host: PhoneKeyboardHost = .shared
    @AppStorage(PhoneKeyboardKey.autocorrect) private var autocorrect: Bool = true
    @AppStorage(PhoneKeyboardKey.swipeTyping) private var swipeTyping: Bool = true
    @AppStorage(PhoneKeyboardKey.mechanicalSounds) private var mechanicalSounds: Bool = false
    @AppStorage(PhoneKeyboardKey.sessionMinutes) private var sessionMinutes: Int = keyboardDefaultSessionMinutes
    @AppStorage(PhoneKeyboardKey.meetingNotes) private var meetingNotes: Bool = false
    @AppStorage(PhoneKeyboardKey.voiceLanguage) private var voiceLanguage: String = ""
    @State private var languages: [KeyboardLanguage] = phoneKeyboardLanguages()
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    var body: some View {
        PhoneGroupedList {
            Section {
                readinessCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(KeyboardLanguage.allCases, id: \.self) { (language: KeyboardLanguage) in
                    Button {
                        toggle(language: language)
                    } label: {
                        HStack {
                            Text(verbatim: language.endonym)
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            if languages.contains(language) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .accessibilityAddTraits(languages.contains(language) ? .isSelected : [])
                }
            } header: {
                PhoneSecondaryText {
                    Text("Klavye dilleri")
                }
            } footer: {
                PhoneSecondaryText {
                    Text("Birden çok dil seçersen klavyedeki dil tuşu aralarında geçer. Japonca, Korece ve Çince yazma yakında; sesle yazma bu dillerde de çalışır.")
                }
            }
            Section {
                Toggle("Kendiliğinden düzelt", isOn: $autocorrect)
                Toggle("Kaydırarak yazma", isOn: $swipeTyping)
                Toggle("Mekanik klavye sesi", isOn: $mechanicalSounds)
            } footer: {
                PhoneSecondaryText {
                    Text("Sözlüğündeki adlar ve terimler hiç düzeltilmez. Bir düzeltmeyi geri almak için hemen ardından sile dokun. Kaydırarak yazmada parmağını harflerin üstünden kaldırmadan geçir; kelimeler bu iPhone'un sözlüğünden bulunur. Mekanik ses ve titreşim Tam Erişim ister.")
                }
            }
            Section {
                Picker("Mikrofonu hazır tut", selection: $sessionMinutes) {
                    ForEach(keyboardSessionMinuteChoices, id: \.self) { (minutes: Int) in
                        Text("\(minutes) dk").tag(minutes)
                    }
                }
                Picker("Sesle yazma dili", selection: $voiceLanguage) {
                    Text("Klavyenin dili").tag("")
                    ForEach(host.dictationLanguageCodes, id: \.self) { (code: String) in
                        Text(verbatim: Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
                if host.isSessionActive {
                    Button("Mikrofon oturumunu bitir", role: .destructive) {
                        host.endSession(reason: "Ayarlar'dan bitirildi")
                    }
                } else if #available(iOS 26, *) {
                    // Klavye uygulamayı açamazsa (ya da bu derleme açmıyorsa) oturum buradan başlar.
                    Button("Mikrofonu hazırla") {
                        host.startSessionManually()
                    }
                }
            } header: {
                PhoneSecondaryText {
                    Text("Sesle yazma")
                }
            } footer: {
                PhoneSecondaryText {
                    Text("Klavyedeki mikrofona dokununca Gistsmith dinler ve metni bu iPhone'da yazıya döker; ses hiçbir yere gönderilmez, aylık süreden düşmez. Son dikteden sonra mikrofon bu süre kadar hazır kalır (turuncu nokta görünür), sonra kapanır.")
                }
            }
            Section {
                Toggle("Klavyede toplantı notları", isOn: $meetingNotes)
                NavigationLink(value: PhoneRoute.settingsPage(.recording)) {
                    PhoneSettingLabel(icon: "character.book.closed", title: Text("Tanıma sözlüğü"))
                }
            } header: {
                PhoneSecondaryText {
                    Text("Gistsmith'ten")
                }
            } footer: {
                PhoneSecondaryText {
                    Text("Açıkken son toplantılarının özeti ve görevleri klavyeden her uygulamaya eklenebilir; toplantılardaki adlar önerilere girer. Liste yalnız bu iPhone'da kalır. Tanıma sözlüğün toplantılarda, Sor'da ve klavyede aynıdır.")
                }
            }
            Section {
                Button {
                    host.isShowingSetup = true
                } label: {
                    PhoneSettingLabel(icon: "book", title: Text("Kurulum adımlarını yeniden göster"))
                }
                .tint(Theme.ink)
            }
        }
        .onChange(of: autocorrect) { host.syncShared() }
        .onChange(of: swipeTyping) { host.syncShared() }
        .onChange(of: mechanicalSounds) { host.syncShared() }
        .onChange(of: sessionMinutes) { host.syncShared() }
        .onChange(of: meetingNotes) { host.syncShared() }
        .onChange(of: voiceLanguage) { host.syncShared() }
        .onAppear { host.refreshReport() }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            if phase == .active {
                host.refreshReport()
            }
        }
    }

    private var readiness: KeyboardReadiness {
        phoneKeyboardReadiness(host: host, now: Date())
    }

    /// The top of the hub: "ready" once the keyboard reported with Full Access and (where voice typing works) a dictation
    /// went through; otherwise what is missing and the button that continues the setup.
    @ViewBuilder
    private var readinessCard: some View {
        switch readiness {
        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                KeyboardReadyCard(title: Text("Gistsmith Klavye hazır"), subtitle: phoneKeyboardReadySubtitle())
                // iOS gives no documented way to see that the keyboard was removed: the card stays "ready" until its last
                // report is `keyboardReportFreshness` old, so the user can start over from here.
                Button {
                    host.isShowingSetup = true
                } label: {
                    Text("Klavye listede yok mu? Kurulumu yeniden başlat")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .underline()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        case .notSetUp:
            setupCard(
                title: Text("Klavyeyi kur"),
                detail: Text("Gistsmith Klavye'yi ekle, Tam Erişim'i aç ve bir kez kullan. Klavye Gistsmith'e haber verince burada hazır görünür."),
                action: Text("Kurulumu başlat")
            )
        case .voiceUntested:
            setupCard(
                title: Text("Sesle yazmayı dene"), detail: Text("Klavye ekli ve Tam Erişim açık. Bir dikteyle sesle yazmanın çalıştığını gör."),
                action: Text("Şimdi dene")
            )
        }
    }

    private func setupCard(title: Text, detail: Text, action: Text) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AccentSymbolTile(symbol: "keyboard", size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    title
                        .appFont(size: 18, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    detail
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                host.isShowingSetup = true
            } label: {
                action
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.primary, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 22)
    }

    private func toggle(language: KeyboardLanguage) {
        var updated: [KeyboardLanguage] = languages
        if let index = updated.firstIndex(of: language) {
            guard updated.count > 1 else {
                return
            }
            updated.remove(at: index)
        } else {
            updated.append(language)
        }
        languages = updated
        UserDefaults.standard.set(updated.map(\.rawValue), forKey: PhoneKeyboardKey.languages)
        host.syncShared()
    }
}

/// Klavyeden açılınca görünen sayfa: mikrofon hazır; kullanıcı ◀ ile ya da alt kenarda sağa kaydırarak uygulamasına
/// döner ve klavyede yeniden dokununca dikte orada başlar. Mikrofon açılamadıysa (izin, süren kayıt) nedeni gösterir.
struct PhoneKeyboardSessionSheet: View {
    let host: PhoneKeyboardHost
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            Image(systemName: isListening ? "waveform" : "mic.fill")
                .appFont(size: 34, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                .frame(width: 84, height: 84)
                .background(appearance.accent.softFill(tintOpacity: 0.14), in: Circle())
                .symbolEffect(.variableColor.iterative, isActive: isListening)
                .accessibilityHidden(true)
            Text(title)
                .appFont(size: 26, weight: .semibold)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if let text = host.dictation?.partialText, !text.isEmpty {
                Text(verbatim: text)
                    .appFont(size: 17, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)
                    .truncationMode(.head)
                    .padding(.horizontal, 8)
            }
            // The keyboard's first tap only warms the microphone: iOS has no API to return to the other app, so the
            // user goes back and taps again; the dictation then runs in the keyboard.
            if host.dictation?.phase != .failed, host.isSessionActive {
                KeyboardStepList(
                    steps: [
                        AttributedString(localized: "Uygulamana dön: sol üstteki **◀**'e dokun ya da alt kenarda sağa kaydır"),
                        AttributedString(localized: "Klavyede **mikrofona** yeniden dokun ve konuş; metin orada yazılır"),
                    ],
                    footnote: Text(
                        "Mikrofon son dikteden sonra \(phoneKeyboardSessionMinutes()) dk hazır kalır; turuncu nokta ve Dynamic Island'daki klavye simgesi bunu gösterir. Yalnız dikte ederken dinler; ses bu iPhone'dan çıkmaz."
                    )
                )
            }
            Spacer()
            VStack(spacing: 10) {
                if isListening {
                    Button {
                        host.finishDictation()
                    } label: {
                        PhonePrimaryButtonLabel(title: "Dikteyi bitir")
                    }
                }
                Button(role: .destructive) {
                    host.endSession(reason: "oturum sayfasından bitirildi")
                    dismiss()
                } label: {
                    Text("Mikrofonu kapat")
                        .appFont(size: 16, weight: .semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private var isListening: Bool {
        guard let phase = host.dictation?.phase else {
            return false
        }
        return phase == .listening || phase == .preparing
    }

    private var title: LocalizedStringKey {
        switch host.dictation?.phase {
        case .preparing:
            "Hazırlanıyor…"
        case .listening:
            "Dinliyorum"
        case .finishing:
            "Yazıya dökülüyor…"
        case .finished:
            "Metin hazır"
        case .failed:
            failureTitle
        case nil:
            host.isSessionActive ? "Mikrofon hazır" : "Mikrofon kapalı"
        }
    }

    private var failureTitle: LocalizedStringKey {
        switch host.dictation?.failure {
        case .recordingMeeting:
            "Toplantı kaydı sürüyor; mikrofon toplantıda."
        case .microphoneDenied:
            "Mikrofon izni kapalı."
        case .unsupportedLanguage:
            "Bu dil için cihaz içi dikte yok."
        case .noSpeech:
            "Konuşma duyulmadı."
        case .failed, nil:
            "Yazıya dökülemedi."
        }
    }
}

/// Klavyeden soru gelince görünen sayfa: soru, cevaplanırken bekleme, sonra cevabın önizlemesi; kullanıcı uygulamasına
/// döner, cevap klavyede "Ekle" ile eklenir.
struct PhoneKeyboardAskSheet: View {
    let host: PhoneKeyboardAskHost
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            Image(systemName: "sparkles")
                .appFont(size: 30, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                .frame(width: 76, height: 76)
                .background(appearance.accent.softFill(tintOpacity: 0.14), in: Circle())
                .accessibilityHidden(true)
            if let question = host.sheet.question {
                Text(verbatim: question)
                    .appFont(size: 17, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Group {
                switch host.sheet {
                case .answering, .idle:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Gistsmith toplantılarına bakıyor…")
                    }
                case .answered(_, _, let answer, _):
                    Text(verbatim: answer)
                        .lineLimit(8)
                case .failed(_, _, let reason, _):
                    Text(verbatim: reason)
                }
            }
            .appFont(size: 15, weight: .regular)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            if !isFailed {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.uturn.backward")
                        .foregroundStyle(appearance.accent.color)
                        .accessibilityHidden(true)
                    Text("Uygulamana dön: cevap hazır olunca klavyenin üstünde görünür, \"Ekle\" ile eklersin.")
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .cardSurface(cornerRadius: 18)
            }
            Spacer()
            Button {
                host.dismiss()
            } label: {
                PhonePrimaryButtonLabel(title: "Tamam")
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private var isFailed: Bool {
        if case .failed = host.sheet {
            return true
        }
        return false
    }
}

/// The ready card's sentence: with voice typing, how to start it; without (iOS 18–25), typing only.
func phoneKeyboardReadySubtitle() -> Text {
    phoneVoiceTypingAvailable()
        ? Text("Sevdiğin uygulamalarda kullanmaya başla: 🌐 ile Gistsmith'e geç, mikrofona dokun ve konuş.")
        : Text("Sevdiğin uygulamalarda yazmaya başla. Sesle yazma iOS 26 ister.")
}

/// The keyboard's state from its last Full Access report and the last inserted dictation, or the state forced by
/// `--klavye-durum` in Debug: Settings › Keyboard, the home screen's tip and the onboarding's last page read it.
@MainActor
func phoneKeyboardReadiness(host: PhoneKeyboardHost, now: Date) -> KeyboardReadiness {
    if let forced = PhoneKeyboardHubDebug.forcedReadiness {
        return forced
    }
    return keyboardReadiness(
        lastFullAccessReportAt: keyboardFullAccessSeenAt(report: host.report), lastDictationSucceededAt: host.lastDictationSucceededAt,
        voiceTypingAvailable: phoneVoiceTypingAvailable(), now: now
    )
}

/// Debug: a hub state forced by `--klavye-durum <durum>` (screenshots); nil in normal use.
@MainActor
enum PhoneKeyboardHubDebug {
    static var forcedReadiness: KeyboardReadiness?
}

/// The `--klavye-durum` value of each hub state.
func keyboardReadiness(launchValue: String) -> KeyboardReadiness? {
    switch launchValue {
    case "kurulmadi": .notSetUp
    case "denenmedi": .voiceUntested
    case "hazir": .ready
    default: nil
    }
}
