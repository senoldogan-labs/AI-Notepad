import AINotepadCore
import AINotepadUI
import KeyboardCore
import SwiftUI

/// Klavyenin son görülmesi bu kadar yeniyse kurulum "tamam" sayılır (klavye yalnız Tam Erişim'le rapor yazar).
private let keyboardReportFreshness: TimeInterval = 60 * 60 * 24 * 30

/// Ayarlar › Klavye: kurulum durumu, diller, kendiliğinden düzeltme, sesle yazma, klavyede toplantı notları ve sözlük.
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

    var body: some View {
        PhoneGroupedList {
            Section {
                Button {
                    host.refreshReport()
                    host.isShowingSetup = true
                } label: {
                    PhoneSettingLabel(icon: "keyboard", title: Text("Klavyeyi kur")) {
                        Text(keyboardSetupSummary(report: host.report))
                    }
                }
                .tint(Theme.ink)
            } footer: {
                Text("Gistsmith Klavye her uygulamada yazar; Tam Erişim'le sesle yazma ve toplantı notlarından ekleme de açılır.")
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
                Text("Klavye dilleri")
            } footer: {
                Text("Birden çok dil seçersen klavyedeki dil tuşu aralarında geçer. Japonca, Korece ve Çince yazma yakında; sesle yazma bu dillerde de çalışır.")
            }
            Section {
                Toggle("Kendiliğinden düzelt", isOn: $autocorrect)
                Toggle("Kaydırarak yazma", isOn: $swipeTyping)
                Toggle("Mekanik klavye sesi", isOn: $mechanicalSounds)
            } footer: {
                Text("Sözlüğündeki adlar ve terimler hiç düzeltilmez. Bir düzeltmeyi geri almak için hemen ardından sile dokun. Kaydırarak yazmada parmağını harflerin üstünden kaldırmadan geçir; kelimeler bu iPhone'un sözlüğünden bulunur. Mekanik ses ve titreşim Tam Erişim ister.")
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
                Text("Sesle yazma")
            } footer: {
                Text("Klavyedeki mikrofona dokununca Gistsmith dinler ve metni bu iPhone'da yazıya döker; ses hiçbir yere gönderilmez, aylık süreden düşmez. Son dikteden sonra mikrofon bu süre kadar hazır kalır (turuncu nokta görünür), sonra kapanır.")
            }
            Section {
                Toggle("Klavyede toplantı notları", isOn: $meetingNotes)
                NavigationLink(value: PhoneRoute.settingsPage(.recording)) {
                    PhoneSettingLabel(icon: "character.book.closed", title: Text("Tanıma sözlüğü"))
                }
            } header: {
                Text("Gistsmith'ten")
            } footer: {
                Text("Açıkken son toplantılarının özeti ve görevleri klavyeden her uygulamaya eklenebilir; toplantılardaki adlar önerilere girer. Liste yalnız bu iPhone'da kalır. Tanıma sözlüğün toplantılarda, Sor'da ve klavyede aynıdır.")
            }
        }
        .onChange(of: autocorrect) { host.syncShared() }
        .onChange(of: swipeTyping) { host.syncShared() }
        .onChange(of: mechanicalSounds) { host.syncShared() }
        .onChange(of: sessionMinutes) { host.syncShared() }
        .onChange(of: meetingNotes) { host.syncShared() }
        .onChange(of: voiceLanguage) { host.syncShared() }
        .onAppear { host.refreshReport() }
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

/// Kurulum satırının durumu: klavye Tam Erişim'le kullanıldıysa hazır, değilse yapılacak.
private func keyboardSetupSummary(report: KeyboardReport?) -> LocalizedStringKey {
    if let report, Date().timeIntervalSince(report.lastSeenAt) < keyboardReportFreshness {
        return "Klavye ekli, Tam Erişim açık."
    }
    return "Klavyeyi ekle ve Tam Erişim'i aç."
}

/// Klavyenin kurulum sayfası (`HeroSheet`): ne yaptığı, üç adım (klavyeyi ekle, Tam Erişim'i aç, sesle yazmayı hazırla)
/// ve son adımda "Klavyede toplantı notları" için açık bir evet/hayır.
struct PhoneKeyboardSetupSheet: View {
    let host: PhoneKeyboardHost
    @AppStorage(PhoneKeyboardKey.meetingNotes) private var meetingNotes: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let heroRatio: CGFloat = dynamicTypeSize.isAccessibilitySize ? 0.22 : 0.36
        GeometryReader { (geometry: GeometryProxy) in
            HeroSheet(
                palette: .ocean,
                seed: "gistsmith-klavye",
                heroHeight: phoneHeroHeight(screenHeight: geometry.size.height, ratio: heroRatio, minimum: 170, maximum: 340),
                title: Text("Gistsmith Klavye"),
                subtitle: Text("Her uygulamada sesle yaz. Ses bu iPhone'da yazıya dökülür; adlarını ve terimlerini bilir."),
                doneTitle: Text("Bitti"),
                onDone: { dismiss() }
            ) { (size: CGSize) in
                KeyboardArtwork()
                    .frame(width: min(size.width - 40, 380))
                    .frame(width: size.width, height: size.height, alignment: .bottom)
                    .offset(y: 18)
            } actions: {
                VStack(spacing: 12) {
                    setupStep(
                        number: 1, title: Text("Klavyeyi ekle"),
                        detail: Text("Ayarlar › Gistsmith › Klavyeler › Gistsmith Klavye."), isDone: isKeyboardSeen
                    )
                    setupStep(
                        number: 2, title: Text("Tam Erişim'i aç"),
                        detail: Text("Sesle yazma ve toplantı notları için. Yazdıkların hiçbir yere gönderilmez; klavyenin ağ bağlantısı yoktur."),
                        isDone: isKeyboardSeen
                    )
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button {
                            openURL(settings)
                        } label: {
                            HeroTileLabel(systemImage: "gearshape", title: Text("Ayarları aç"), detail: nil)
                        }
                        .buttonStyle(HeroTileButtonStyle())
                    }
                    if #available(iOS 26, *) {
                        prepareStep
                    }
                    Toggle(isOn: $meetingNotes) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Klavyede toplantı notları")
                                .appFont(size: 16, weight: .semibold)
                                .foregroundStyle(Theme.ink)
                            Text("Son toplantılarının özetini ve görevlerini her uygulamaya ekle. Liste yalnız bu iPhone'da kalır.")
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(16)
                    .cardSurface(cornerRadius: 18)
                    .onChange(of: meetingNotes) { host.syncShared() }
                }
            }
        }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            // Kullanıcı Ayarlar'dan dönünce adımların durumu yenilenir.
            if phase == .active {
                host.refreshReport()
            }
        }
    }

    private var isKeyboardSeen: Bool {
        host.report.map { Date().timeIntervalSince($0.lastSeenAt) < keyboardReportFreshness } ?? false
    }

    @available(iOS 26, *)
    private var prepareStep: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sesle yazmayı hazırla")
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Group {
                    switch host.preparation {
                    case .idle:
                        Text("Klavye dilinin dikte modeli bu iPhone'a indirilir; ilk dikte beklemez.")
                    case .preparing(let progress?):
                        Text("İndiriliyor… \(Int(progress * 100))%")
                    case .preparing(nil):
                        Text("Hazırlanıyor…")
                    case .ready:
                        Text("Hazır.")
                    case .failed(let message):
                        Text(verbatim: message)
                    }
                }
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            switch host.preparation {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(Text("Hazır"))
            case .preparing:
                ProgressView()
            case .idle, .failed:
                Button("Hazırla") {
                    Task { await host.prepareDictation() }
                }
                .buttonStyle(.borderedProminent)
                .tint(appearance.accent.systemLabelFill)
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: 18)
    }

    private func setupStep(number: Int, title: Text, detail: Text, isDone: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.accentColor : Theme.soft)
                    .frame(width: 28, height: 28)
                if isDone {
                    Image(systemName: "checkmark")
                        .appFont(size: 13, weight: .bold)
                        .foregroundStyle(.white)
                } else {
                    Text(verbatim: "\(number)")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                title
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                detail
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .cardSurface(cornerRadius: 18)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? Text("Tamam") : Text("Yapılacak"))
    }
}

/// Kurulum görselindeki klavye: Gistsmith Klavye'nin kendi düzeni (`keyboardRows`), üstte öneri ve canlı dikte şeridi.
private struct KeyboardArtwork: View {
    var body: some View {
        let rows: [[KeyboardKey]] = keyboardRows(
            language: .english, page: .letters, options: KeyboardLayoutOptions(showsGlobe: false, showsMicrophone: true, showsLanguage: false, field: .text)
        )
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.orange))
                Text(verbatim: "Send Ayşe the Q4 roadmap after the Gistsmith sync")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(.black)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
            GeometryReader { (geometry: GeometryProxy) in
                let maxUnits: Double = rows.map { (row: [KeyboardKey]) -> Double in row.reduce(0) { $0 + $1.widthUnits } }.max() ?? 10
                let unit: CGFloat = geometry.size.width / CGFloat(maxUnits)
                VStack(spacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { (_: Int, row: [KeyboardKey]) in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { (_: Int, key: KeyboardKey) in
                                artworkKey(key)
                                    .padding(.horizontal, 2.5)
                                    .frame(width: unit * CGFloat(key.widthUnits))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 4 * 30 + 3 * 7)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.82, green: 0.84, blue: 0.87)))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
        // Görsel bir klavye resmidir (VoiceOver'da gizli): tuş yazıları gerçek klavyedeki gibi sabit boyda kalır.
        .dynamicTypeSize(.large)
    }

    private func artworkKey(_ key: KeyboardKey) -> some View {
        let isCharacter: Bool
        let label: AnyView
        switch key.kind {
        case .character(let character):
            isCharacter = true
            label = AnyView(Text(verbatim: character).appFont(size: 15, weight: .regular))
        case .space:
            isCharacter = true
            label = AnyView(Text(verbatim: "English").appFont(size: 11, weight: .regular))
        case .microphone:
            isCharacter = false
            label = AnyView(Image(systemName: "mic.fill").appFont(size: 12, weight: .regular).foregroundStyle(Color.orange))
        case .shift:
            isCharacter = false
            label = AnyView(Image(systemName: "shift").appFont(size: 12, weight: .regular))
        case .delete:
            isCharacter = false
            label = AnyView(Image(systemName: "delete.left").appFont(size: 12, weight: .regular))
        case .emoji:
            isCharacter = false
            label = AnyView(Image(systemName: "face.smiling").appFont(size: 12, weight: .regular))
        case .returnKey:
            isCharacter = false
            label = AnyView(Image(systemName: "return").appFont(size: 12, weight: .regular))
        case .page:
            isCharacter = false
            label = AnyView(Text(verbatim: "123").appFont(size: 11, weight: .regular))
        case .globe, .language:
            isCharacter = false
            label = AnyView(EmptyView())
        }
        return label
            .foregroundStyle(.black)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isCharacter ? Color.white : Color(red: 0.68, green: 0.70, blue: 0.74)))
    }
}

/// Klavyeden açılınca görünen sayfa: Gistsmith dinliyor; kullanıcı ◀ ile ya da alt kenarda sağa kaydırarak uygulamasına
/// döner, dikte orada sürer.
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
            if host.dictation?.phase != .failed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.uturn.backward")
                    .foregroundStyle(appearance.accent.color)
                    .accessibilityHidden(true)
                Text("Uygulamana dönmek için sol üstteki ◀'e dokun ya da alt kenarda sağa kaydır. Konuşmaya devam edebilirsin; metin klavyede görünür.")
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .cardSurface(cornerRadius: 18)
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
            if let question = host.question {
                Text(verbatim: question)
                    .appFont(size: 17, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Group {
                switch host.phase {
                case .answering, nil:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Gistsmith toplantılarına bakıyor…")
                    }
                case .answered:
                    Text(verbatim: host.answer ?? "")
                        .lineLimit(8)
                case .failed:
                    Text(verbatim: host.failureReason ?? "")
                }
            }
            .appFont(size: 15, weight: .regular)
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            if host.phase != .failed {
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
}
