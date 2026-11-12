import AINotepadCore
import AINotepadUI
import AppKit
import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers
import os

/// `--ayar <sayfa>` başlatma argümanından açılacak Ayarlar sayfası (görsel kontrol için): `profil`, `hesap` (abonelik
/// sürümü), `kayit` (eski `genel` de buraya), `notlar`, `ceviri`, `takvim`, `bildirimler`, `sesle-yazma`, `baglantilar`,
/// `kisayollar`, `llm`, `anahtarlar`, `gorunum`, `destek`, `tanilama`, `veri`; yoksa ya da tanınmıyorsa profil. Saf
/// fonksiyondur.
private func launchSettingsSection(arguments: [String]) -> SettingsSection {
    guard let index = arguments.firstIndex(of: "--ayar"), arguments.indices.contains(index + 1) else {
        return .profile
    }
    switch arguments[index + 1] {
    case "genel", "kayit": return .recording
    case "notlar": return .notes
    case "ceviri": return .translation
    case "takvim": return .calendar
    case "bildirimler": return .notifications
    case "gorunum": return .appearance
    case "llm": return .llm
    case "anahtarlar": return .keys
    case "baglantilar": return .connections
    case "kisayollar": return .shortcuts
    case "sesle-yazma": return .voiceTyping
    case "tanilama": return .diagnostics
    case "destek": return .support
    case "veri": return .data
    #if HOSTED_EDITION
    case "hesap": return .account
    #endif
    default: return .profile
    }
}

/// Ayarlar'ın sol sütunundaki gruplar (iPhone'daki Ayarlar'la aynı sırada).
private enum SettingsCategory: CaseIterable {
    case account
    case features
    case appearance
    case support
    case data

    var title: LocalizedStringKey {
        switch self {
        case .account: "Hesap"
        case .features: "Özellikler"
        case .appearance: "Görünüm"
        case .support: "Destek"
        case .data: "Veri ve paylaşım"
        }
    }
}

/// Ayarlar sayfaları.
private enum SettingsSection: CaseIterable {
    /// Ad, unvan, şirket ve şirket açıklaması.
    case profile
    #if HOSTED_EDITION
    /// Abonelik hesabı: giriş, deneme ya da abonelik, kullanım, davet, hesap silme (bkz. App/Hosted).
    case account
    #endif
    /// Dil, tanıma ve konuşmacılar, kayıt.
    case recording
    /// Not şablonu ve şablon galerisi.
    case notes
    /// Canlı çeviri, "Ne kaçırdım?" ve Sor'da web araması.
    case translation
    case calendar
    case notifications
    /// Sesle yazma (dikte): aç/kapa, kısayol, Erişilebilirlik izni ve dil (bkz. App/VoiceTypingSettings.swift).
    case voiceTyping
    /// Kanallar, görev araçları, yapay zekâ asistanı erişimi (MCP), beceriler.
    case connections
    case shortcuts
    case llm
    case keys
    case appearance
    /// Kurulum, güncelleme, geri bildirim ve iletişim.
    case support
    /// Sürüm, sistem, hesap, bağlantı, izinler, canlı metin, güncelleme ve son hatalar (bkz. App/DiagnosticsViews.swift).
    case diagnostics
    /// Eşitleme, ses saklama, Spotlight, kullanım istatistikleri ve çökme raporları.
    case data

    /// Sol sütundaki sayfalar: abonelik sürümünde LLM ve Anahtarlar yok (model ve anahtar sunucudadır).
    static var visible: [SettingsSection] {
        #if HOSTED_EDITION
        allCases.filter { (section: SettingsSection) -> Bool in section != .llm && section != .keys }
        #else
        allCases
        #endif
    }

    var category: SettingsCategory {
        switch self {
        #if HOSTED_EDITION
        case .account: .account
        #endif
        case .profile: .account
        case .recording, .notes, .translation, .calendar, .notifications, .voiceTyping, .connections, .shortcuts, .llm, .keys: .features
        case .appearance: .appearance
        case .support, .diagnostics: .support
        case .data: .data
        }
    }

    var title: LocalizedStringKey {
        switch self {
        #if HOSTED_EDITION
        case .account: "Plan ve faturalandırma"
        #endif
        case .profile: "Profil"
        case .recording: "Kayıt ve diller"
        case .notes: "Notlar ve şablonlar"
        case .translation: "Canlı çeviri ve Sor"
        case .calendar: "Takvim"
        case .notifications: "Bildirimler"
        case .voiceTyping: "Sesle yazma"
        case .connections: "Bağlantılar"
        case .shortcuts: "Kısayollar"
        case .llm: "LLM"
        case .keys: "Anahtarlar"
        case .appearance: "Tema, renk ve yazı"
        case .support: "Yardım ve geri bildirim"
        case .diagnostics: "Tanılama"
        case .data: "Veri ve gizlilik"
        }
    }

    var icon: String {
        switch self {
        #if HOSTED_EDITION
        case .account: "creditcard"
        #endif
        case .profile: "person.crop.circle"
        case .recording: "waveform"
        case .notes: "doc.text"
        case .translation: "character.bubble"
        case .calendar: "calendar"
        case .notifications: "bell.badge"
        case .voiceTyping: "mic"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .shortcuts: "command"
        case .llm: "sparkles"
        case .keys: "key"
        case .appearance: "paintpalette"
        case .support: "bubble.left.and.text.bubble.right"
        case .diagnostics: "stethoscope"
        case .data: "lock.shield"
        }
    }
}

/// Ana penceredeki Ayarlar: solda gruplu sayfa listesi (üstte plan kartı; Hesap, Özellikler, Görünüm, Destek, Veri ve
/// paylaşım; altta çıkış ve sürüm), sağda seçili sayfa. Sayfada ayarlar sakin bölüm adlarının altında tek kartlık
/// gruplardadır (`SettingsGroup`); her satırda vurgu renkli simge kutusu, başlık, kısa açıklama (uzunu "Ayrıntılar"da
/// satır içinde) ve sağda denetim.
struct SettingsPage: View {
    let model: AppModel
    let router: MainWindowRouter
    let shortcuts: ShortcutController
    let updater: AppUpdater
    let crashReports: CrashReportCenter
    /// Karşılama ve kurulum ekranını yeniden açar.
    let onShowSetup: @MainActor () -> Void
    @State private var section: SettingsSection = launchSettingsSection(arguments: CommandLine.arguments)

    #if HOSTED_EDITION
    /// İstenmişse Plan ve faturalandırma'yı seçer ve isteği sıfırlar.
    private func selectAccountIfRequested() {
        guard router.opensAccountSettings else {
            return
        }
        router.opensAccountSettings = false
        section = .account
    }
    #endif

    /// İstenmişse Takvim'i seçer ve isteği sıfırlar.
    private func selectCalendarIfRequested() {
        guard router.opensCalendarSettings else {
            return
        }
        router.opensCalendarSettings = false
        section = .calendar
    }

    /// İstenmişse Sesle yazma'yı seçer ve isteği sıfırlar.
    private func selectVoiceTypingIfRequested() {
        guard router.opensVoiceTypingSettings else {
            return
        }
        router.opensVoiceTypingSettings = false
        section = .voiceTyping
    }

    var body: some View {
        // Kayıt, işleme ya da içe aktarma sürerken çıkış ve hesap silme kapalı.
        let isMeetingInFlight: Bool = model.isBusy || model.isStarting
        HStack(alignment: .top, spacing: 0) {
            SettingsNavigation(selection: $section, model: model, isMeetingInFlight: isMeetingInFlight)
            Rectangle().fill(Theme.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(section.title)
                        .appTitleFont(size: 28, weight: .regular)
                        .tracking(-0.5)
                        .accessibilityAddTraits(.isHeader)
                    page(isMeetingInFlight: isMeetingInFlight)
                        .padding(.top, 2)
                }
                // Geniş pencerede form satırları ekran boyu uzamasın; kaydırma alanı tam genişlikte.
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            // Sayfa değişince en üstten başlar.
            .id(section)
            .transition(.opacity)
        }
        .animation(.smooth(duration: 0.2), value: section)
        #if HOSTED_EDITION
        // Kullanım göstergesi ya da bildirimi Ayarlar'ı Plan ve faturalandırma'da açar.
        .onAppear { selectAccountIfRequested() }
        .onChange(of: router.opensAccountSettings) { (_: Bool, _: Bool) in selectAccountIfRequested() }
        #endif
        // Sesle yazma hapındaki "izin ver" Ayarlar'ı Sesle yazma'da açar.
        .onAppear { selectVoiceTypingIfRequested() }
        .onChange(of: router.opensVoiceTypingSettings) { (_: Bool, _: Bool) in selectVoiceTypingIfRequested() }
        // Satın almadan sonraki "Takvimini bağla" Ayarlar'ı Takvim'de açar.
        .onAppear { selectCalendarIfRequested() }
        .onChange(of: router.opensCalendarSettings) { (_: Bool, _: Bool) in selectCalendarIfRequested() }
    }

    @ViewBuilder
    private func page(isMeetingInFlight: Bool) -> some View {
        switch section {
        #if HOSTED_EDITION
        // Giriş ya da çıkışta kurulum eksikleri uygulama düzeyinde yenilenir (bkz. AINotepadApp).
        case .account:
            HostedAccountSettings(account: .shared, isMeetingInFlight: isMeetingInFlight) { model.moveDeletedAccountMeetings() }
        #endif
        case .profile: ProfileSettings(model: model)
        case .recording: RecordingSettings(model: model)
        case .notes: NoteSettings()
        case .translation: TranslationSettings(model: model)
        case .calendar: CalendarSettings(model: model)
        case .notifications: NotificationSettingsGroup()
        case .voiceTyping: VoiceTypingSettings(shortcuts: shortcuts, audioInputs: model.audioInputs)
        case .connections: ConnectionSettings(model: model)
        case .shortcuts: ShortcutSettings(shortcuts: shortcuts)
        case .llm: LLMSettings(model: model)
        case .keys: KeySettings(model: model)
        case .appearance: AppearanceSettings()
        case .support: SupportSettings(model: model, updater: updater, onShowSetup: onShowSetup)
        case .diagnostics: DiagnosticsSettings(model: model, updater: updater)
        case .data:
            DataSettings(model: model, crashReports: crashReports) {
                #if HOSTED_EDITION
                section = .account
                #endif
            }
        }
    }
}

/// Ayarlar'ın sol sütunu (sayfa adı "Ayarlar" pencerenin üst çubuğunda): plan kartı (abonelikte plan durumu ve "Abone
/// ol"; geliştirici sürümünde profil), gruplu sayfa listesi (seçili sayfa vurgu renginde), abonelikte iPhone uygulaması
/// önerisi ve çıkış, en altta
/// sürüm.
private struct SettingsNavigation: View {
    @Binding var selection: SettingsSection
    let model: AppModel
    let isMeetingInFlight: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                #if HOSTED_EDITION
                HostedSettingsBanner(account: .shared) { selection = .account }
                #else
                LocalSettingsBanner(userName: model.userName) { selection = .profile }
                #endif
                ForEach(SettingsCategory.allCases, id: \.self) { (category: SettingsCategory) in
                    let items: [SettingsSection] = SettingsSection.visible.filter { $0.category == category }
                    if !items.isEmpty {
                        Text(category.title)
                            .appFont(size: 11, weight: .semibold)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8)
                            .padding(.top, 20)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(items, id: \.self) { (item: SettingsSection) in
                            SettingsNavigationRow(item: item, isSelected: item == selection) { selection = item }
                        }
                    }
                }
                #if HOSTED_EDITION
                // iPhone uygulamasının önerisi (gizlenebilir); tıklayınca tanıtım sayfası açılır.
                HostedIPhoneAppCard()
                    .padding(.top, 20)
                HostedSettingsSignOut(account: .shared, isMeetingInFlight: isMeetingInFlight)
                    .padding(.top, 20)
                #endif
                // Sürüm ve derleme: geri bildirimde hangi derleme olduğu görünsün.
                Text(verbatim: "\(appName) \(currentReportDiagnostics(bundle: .main, platformName: "macOS").appVersion)")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 24)
        }
        .frame(width: 236)
    }
}

/// Sol sütundaki sayfa satırı: simge ve ad; seçiliyse vurgu renginin soluk zemini, vurgu renginde simge ve koyu ad.
private struct SettingsNavigationRow: View {
    let item: SettingsSection
    let isSelected: Bool
    let onSelect: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.icon)
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(isSelected ? appearance.accent.color : Theme.muted)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(item.title)
                    .appFont(size: 13, weight: isSelected ? .medium : .regular)
                    .foregroundStyle(Theme.ink)
                    // A long name (larger interface text, Finnish, German) wraps instead of shrinking: every row keeps
                    // the same type size.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(appearance.accent.softFill(tintOpacity: 0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if !HOSTED_EDITION
/// Geliştirici sürümünde Ayarlar'ın üstündeki kart: baş harf, ad ve verinin bu Mac'te kaldığı; dokununca Profil açılır.
private struct LocalSettingsBanner: View {
    let userName: String
    let onOpenProfile: @MainActor () -> Void

    var body: some View {
        let name: String = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        Button {
            onOpenProfile()
        } label: {
            HStack(spacing: 10) {
                InitialAvatar(initial: accountAvatarInitial(userName: userName, email: nil), size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if name.isEmpty {
                            Text("Adını yaz")
                        } else {
                            Text(verbatim: name)
                        }
                    }
                    .appFont(size: 14, weight: .semibold)
                    .lineLimit(1)
                    Text("Geliştirici sürümü: kendi anahtarlarınla, hesapsız.")
                        .appFont(size: 11, weight: .regular)
                        .opacity(0.72)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.black.opacity(0.85))
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkPointer(isEnabled: true)
        .background { FilmGradient(seed: "ayarlar-yerel", palette: .ocean) }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Pastel zemin her temada açık: yazı koyu kalır.
        .environment(\.colorScheme, .light)
    }
}
#endif

/// Tanıma sözlüğünün açıklaması: sözlüğün nerede uygulandığı sürüme göre (abonelikte motor seçimi yok).
private var vocabularyHelp: LocalizedStringKey {
    #if HOSTED_EDITION
    "Konuşma tanımanın doğru yazması gereken adlar, şirket ve ürün adları, kısaltmalar; satır başına bir tane (2–40 karakter, en fazla 5 sözcük; en fazla 30 kullanılır). Canlı metinde ve kayıt bitince yapılan son geçişte uygulanır. Toplantılarda verdiğin konuşmacı adları ve sözlük terimleri zaten kendiliğinden eklenir."
    #else
    "Konuşma tanımanın doğru yazması gereken adlar, şirket ve ürün adları, kısaltmalar; satır başına bir tane (2–40 karakter, en fazla 5 sözcük; en fazla 30 kullanılır). Bulut motorunda (Deepgram, ElevenLabs) uygulanır. Toplantılarda verdiğin konuşmacı adları ve sözlük terimleri zaten kendiliğinden eklenir."
    #endif
}

/// Profil: ad, unvan, şirket ve şirket açıklaması (notlar bağlamı bunlarla anlar).
private struct ProfileSettings: View {
    let model: AppModel

    var body: some View {
        SettingsGroup(title: Text("Profil")) {
            SettingsRow(icon: "person.crop.circle", title: Text("Adın")) {
                Text("Toplantı notunda sana düşen görevleri ayırmak için kullanılır.")
            } control: {
                TextField("Adın", text: Binding<String>(get: { model.userName }, set: { (name: String) -> Void in model.setUserName(name: name) }))
                    .settingsField(width: 200)
            }
            SettingsRow(icon: "briefcase", title: Text("Unvan")) {
                Text("Toplantıdaki rolünü anlamaya yardım eder.")
            } control: {
                TextField("Unvan", text: Binding<String>(get: { model.jobTitle }, set: { (text: String) -> Void in model.setJobTitle(text: text) }))
                    .settingsField(width: 200)
            }
            SettingsRow(icon: "building.2", title: Text("Şirket")) {
                Text("Kendi şirketini müşteriden ve iş ortağından ayırır.")
            } control: {
                TextField("Şirket", text: Binding<String>(get: { model.companyName }, set: { (text: String) -> Void in model.setCompanyName(text: text) }))
                    .settingsField(width: 200)
            }
            SettingsStackedRow(icon: "text.alignleft", title: Text("Şirket açıklaması")) {
                Text("Ne yaptığınızı, ürünlerinizi ve sık geçen terimleri birkaç cümleyle yaz.")
            } content: {
                SettingsTextEditor(
                    text: Binding<String>(get: { model.companyDescription }, set: { (text: String) -> Void in model.setCompanyDescription(text: text) }),
                    height: 80
                )
                Text("\(model.companyDescription.count)/\(profileDescriptionLimit)")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        } footer: {
            Text("Notlar bağlamını anlamak için bunu kullanır; yalnızca not ya da cevap yazılırken toplantı metniyle gönderilir.")
        }
    }
}

/// Kayıt ve diller: arayüz, not ve ana toplantı dili (geliştirici sürümünde canlı metin motoru), tanıma sözlüğü ve
/// konuşmacılar, kayıt (mikrofon, rıza hatırlatması, görüşme bitince bitirme, ekran görüntüleri).
private struct RecordingSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.voiceRecognition) private var voiceRecognition: Bool = false
    @AppStorage(SettingsKey.consentReminder) private var consentReminder: Bool = true
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(SettingsKey.stopWhenCallEnds) private var stopWhenCallEnds: Bool = true
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    @State private var interfaceLanguage: InterfaceLanguage = storedInterfaceLanguage()
    @State private var relaunchError: String?

    var body: some View {
        // Kayıt ya da toplantı işleme sürerken yeniden başlatılırsa o toplantı yarıda kalır.
        let isBusy: Bool = model.isBusy
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: Text("Dil")) {
                SettingsRow(icon: "globe", title: Text("Arayüz dili")) {
                    Text("Menülerin ve ayarların dili.")
                    if interfaceLanguage != launchInterfaceLanguage {
                        Text("Yeniden başlatınca uygulanır.").foregroundStyle(Theme.ink)
                    }
                    if let relaunchError {
                        NoticeText(relaunchError, severity: .error)
                    }
                } control: {
                    HStack(spacing: 8) {
                        if interfaceLanguage != launchInterfaceLanguage {
                            Button("Şimdi yeniden başlat") {
                                do {
                                    try relaunchApplication()
                                } catch {
                                    relaunchError = String(localized: "Yeniden başlatılamadı: \(error.localizedDescription)")
                                }
                            }
                            .disabled(isBusy)
                            .hoverHint(isBusy ? "Kayıt ve işleme bitince yeniden başlatılabilir" : "Uygulamayı yeni dille yeniden açar", alignment: .trailing, edge: .bottom)
                        }
                        SettingsMenu(selection: $interfaceLanguage, options: InterfaceLanguage.allCases.map { (language: InterfaceLanguage) -> (InterfaceLanguage, Text) in
                            (language, language.nativeName.map { Text(verbatim: $0) } ?? Text("Sistem"))
                        })
                    }
                }
                .onChange(of: interfaceLanguage) { (_: InterfaceLanguage, language: InterfaceLanguage) in
                    storeInterfaceLanguage(language: language)
                }
                SettingsRow(icon: "text.bubble", title: Text("Not ve çeviri dili")) {
                    SettingsMoreText(
                        summary: Text("Notlar, çeviri ve Sor cevapları bu dilde yazılır."),
                        details: Text("Toplantı notları, canlı çeviri, \"Ne kaçırdım?\" özeti ve Sor cevapları bu dilde yazılır. Önceki notlar yazıldıkları dilde kalır.")
                    )
                } control: {
                    SettingsMenu(selection: $noteLanguage, options: ShareLanguage.allCases.map { (language: ShareLanguage) -> (String, Text) in
                        (language.rawValue, Text(verbatim: language.interfaceTitle))
                    })
                }
                // Cihaz içi modelin bu dili yazıp yazamadığı uyarısı yenilensin.
                .onChange(of: noteLanguage) { (_: String, _: String) in
                    model.settingsChanged()
                }
                SettingsRow(icon: "waveform", title: Text("Ana toplantı dili")) {
                    #if HOSTED_EDITION
                    SettingsMoreText(
                        summary: Text("Canlı metin bu dilde başlar; konuşulan dil sonra bulunur."),
                        details: Text("Otomatik dilde canlı metin bu dilde yazılır. Toplantı bitince konuşulan dil (35 dil) kendiliğinden bulunur ve not ona göre yazılır.")
                    )
                    #else
                    SettingsMoreText(
                        summary: Text("Canlı metin bu dilde başlar; konuşulan dil sonra bulunur."),
                        details: Text("Otomatik dilde kayıt bu dille başlar; ilk dakikada konuşulan dil (35 dil) bulunup ona geçilir. Mac'te tanımada bu dil ile İngilizce arasında seçilir.")
                    )
                    #endif
                } control: {
                    SettingsMenu(selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> (String, Text) in
                        (language.rawValue, Text(verbatim: languageName(language: language)))
                    })
                }
                .onChange(of: primaryLanguage) { (_: String, _: String) in
                    model.primaryLanguageChanged()
                }
                #if !HOSTED_EDITION
                SettingsRow(icon: "captions.bubble", title: Text("Canlı metin")) {
                    switch model.liveEngine {
                    case .deepgram: Text("Konuşmacılar ElevenLabs ile dakikada bir ayrılır; kayıt bitince ElevenLabs son geçişi yapılır.")
                    case .whisperKit: Text("Ses Mac'ten çıkmaz; kayıt bitince konuşmacılar Mac'te (SpeakerKit) ayrılır. Not için LLM gerekir.")
                    case .appleSpeech: Text("Apple'ın konuşma tanıması; ses Mac'ten çıkmaz, anahtar ve büyük model indirmesi gerekmez. Dil algılanmaz (ana toplantı diliyle başlar), konuşmacılar ayrılmaz.")
                    }
                    if !appleSpeechSupportedBySystem() {
                        Text("Cihaz içi konuşma tanıma macOS 26 gerektirir.")
                    }
                } control: {
                    SettingsMenu(selection: Binding<LiveEngine>(
                        get: { model.liveEngine },
                        set: { (engine: LiveEngine) -> Void in
                            Task { await model.selectEngine(engine: engine) }
                        }
                    ), options: liveEngineOptions())
                    .disabled(model.isRecording || model.isStarting)
                }
                #endif
            }
            SettingsGroup(title: Text("Tanıma ve konuşmacılar")) {
                SettingsStackedRow(icon: "character.book.closed", title: Text("Tanıma sözlüğü")) {
                    SettingsMoreText(summary: Text("Doğru yazılması gereken adlar ve terimler; satır başına bir tane, en fazla 30."), details: Text(vocabularyHelp))
                } content: {
                    SettingsTextEditor(text: Binding<String>(get: { model.vocabulary }, set: { (text: String) -> Void in model.setVocabulary(text: text) }), height: 80)
                    Text("\(customVocabulary(text: model.vocabulary).count) terim")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                SettingsRow(icon: "person.wave.2", title: Text("Konuşmacıları sesinden tanı")) {
                    SettingsMoreText(
                        summary: Text("Ad verdiğin kişi sonraki toplantılarda sesinden tanınır."),
                        details: Text("Açıkken 8 sn'den fazla konuşan herkesin ses izi (sesi tanıyan sayılar; biyometrik veridir) o toplantıyla saklanır; ad verdiğin kişininki bu Mac'te hatırlanır ve sonraki toplantılarda adı kendiliğinden gelir. Toplantı silinince ondan öğrenilen izler, sesi silinince toplantıdaki izler de silinir. Başkalarının ses izini saklamadan önce onaylarını al.")
                    )
                    if let error = model.voiceRegistryError {
                        NoticeText(error, severity: .error)
                    }
                } control: {
                    Toggle("Konuşmacıları sesinden tanı", isOn: $voiceRecognition).settingsToggle()
                }
                if voiceRecognition {
                    ForEach(model.registeredVoices, id: \.name) { (voice: RegisteredVoice) in
                        SettingsRow(icon: "person.crop.circle.badge.checkmark", title: Text(voice.name)) {
                            Text("\(max(1, Int((voice.voiceprint.seconds / 60).rounded()))) dk konuşmadan · \(voice.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale())))")
                        } control: {
                            Button("Unut", role: .destructive) { model.forgetVoice(name: voice.name) }
                                .hoverHint("Bu kişi bundan sonra sesinden tanınmaz", alignment: .trailing, edge: .bottom)
                        }
                    }
                }
            }
            SettingsGroup(title: Text("Kayıt")) {
                AudioInputSettingsRow(inputs: model.audioInputs)
                SettingsRow(icon: "mic.badge.plus", title: Text("Kendi sesimi de kaydet (mikrofon)")) {
                    SettingsMoreText(
                        summary: Text("Kapalıyken yalnızca bilgisayardan gelen ses kaydedilir."),
                        details: Text("Kapalıyken yalnızca bilgisayardan gelen ses (karşı taraf) kaydedilir: mikrofon hiç açılmaz, hoparlör yankısı \"Sen\" diye yazılmaz. Paneldeki mikrofon düğmesiyle kayıttan önce de seçilebilir. Mikrofonsuz başlayan kayıtta mikrofon kayıt sırasında açılabilir; açıldığı andan itibaren kaydedilir, sonra kapatmak yalnızca susturur. Yüz yüze modunda mikrofon her zaman açıktır (odadaki herkesi kaydeder).")
                    )
                } control: {
                    Toggle("Kendi sesimi de kaydet (mikrofon)", isOn: Binding<Bool>(
                        get: { !model.isMicMuted },
                        set: { (enabled: Bool) -> Void in
                            if enabled == model.isMicMuted {
                                model.toggleMicrophone()
                            }
                        }
                    ))
                    .settingsToggle()
                    // Yüz yüze kayıtta mikrofon tek kaynaktır, değişmez (bkz. `toggleMicrophone`); anahtar geri sıçramasın.
                    .disabled(model.viewState.isInPerson)
                }
                SettingsRow(icon: "hand.raised", title: Text("Kayıt başlarken haber vermeyi hatırlat")) {
                    #if HOSTED_EDITION
                    SettingsMoreText(
                        summary: Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur."),
                        details: Text("Panelde kısa bir hatırlatma ve toplantı sohbetine yapıştırılacak İngilizce bildirim. Kayıt yapmadan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur.")
                    )
                    #else
                    SettingsMoreText(
                        summary: Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur."),
                        details: Text("Panelde kısa bir hatırlatma ve toplantı sohbetine yapıştırılacak Fince/İngilizce bildirim. Kayıt yapmadan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur.")
                    )
                    #endif
                } control: {
                    Toggle("Kayıt başlarken haber vermeyi hatırlat", isOn: $consentReminder).settingsToggle()
                }
                // Takvimden bağımsız: kayıt sırasında görüşme uygulamasının mikrofonu izlenir.
                SettingsRow(icon: "phone.down", title: Text("Görüşme bitince kaydı bitir")) {
                    SettingsMoreText(
                        summary: Text("Görüşme bitip mikrofon boş kalınca kayıt kendiliğinden biter."),
                        details: Text("Kayıt sırasında Teams, Zoom, Meet ya da başka bir uygulama mikrofonu kullanırken görüşme bitip mikrofon 15 sn boş kalırsa, panelde ve bildirimde \"Görüşme bitti gibi görünüyor\" yazar; 30 sn içinde \"Kayda devam et\"e basmazsan kayıt \"Bitir\"e basılmış gibi biter ve not hazırlanır. Unutulan kayıt boşuna dakika harcamaz. Yüz yüze kayıtlar (başka uygulama mikrofonu kullanmadığında) kendiliğinden bitmez.")
                    )
                } control: {
                    Toggle("Görüşme bitince kaydı bitir", isOn: $stopWhenCallEnds)
                        .settingsToggle()
                }
                ScreenSnapshotSettingsRow()
                #if HOSTED_EDITION
                ScreenNotesSettingsRow()
                #endif
            }
        }
    }
}

/// Notlar ve şablonlar: yeni notların şablonu, kendi şablonun, şablon galerisi ve ada göre şablon.
private struct NoteSettings: View {
    @AppStorage(SettingsKey.noteTemplate) private var noteTemplate: String = NoteTemplateKind.general.rawValue
    @AppStorage(SettingsKey.customTemplate) private var customTemplate: String = ""
    @AppStorage(SettingsKey.customTemplateName) private var customTemplateName: String = ""
    @AppStorage(SettingsKey.templateFromTitle) private var templateFromTitle: Bool = true
    /// Not bölümünün altındaki şablon galerisi açık mı.
    @State private var showsTemplateGallery: Bool = false
    /// "Kopyasını düzenle"den sonra kendi şablonunun metnine odaklanılır.
    @FocusState private var customTemplateFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: Text("Not")) {
                SettingsRow(icon: "doc.text", title: Text("Not şablonu")) {
                    Text("Yeni notlar bu şablonla yazılır; eski bir notu ⋯ menüsünden yeniden yazabilirsin.")
                } control: {
                    SettingsMenu(selection: $noteTemplate, options: NoteTemplateKind.allCases.map { (kind: NoteTemplateKind) -> (String, Text) in
                        (kind.rawValue, Text(verbatim: kind == .custom ? customTemplateDisplayName(name: customTemplateName) : kind.displayName))
                    })
                }
                if noteTemplate == NoteTemplateKind.custom.rawValue {
                    SettingsStackedRow(icon: "pencil.line", title: Text("Kendi şablonun")) {
                        Text("Notta neyin öne çıkacağını yaz; ör. “Riskleri ayrı say, kararların gerekçesini yaz.”")
                    } content: {
                        TextField(text: $customTemplateName) {
                            Text("Şablon adı")
                        }
                        .settingsField(width: 260)
                        SettingsTextEditor(text: $customTemplate, height: 120)
                            .focused($customTemplateFocused)
                    }
                }
                SettingsRow(icon: "square.grid.2x2", title: Text("Şablon galerisi")) {
                    Text("Kategorilere ayrılmış hazır şablonlar: önizle, kullan ya da kopyasını düzenleyip kendine göre değiştir.")
                } control: {
                    Button(showsTemplateGallery ? LocalizedStringKey("Galeriyi gizle") : LocalizedStringKey("Galeriyi aç")) {
                        withAnimation(.smooth(duration: 0.2)) { showsTemplateGallery.toggle() }
                    }
                    .buttonStyle(.pill)
                }
                SettingsRow(icon: "wand.and.stars", title: Text("Şablonu toplantı adına göre seç")) {
                    SettingsMoreText(
                        summary: Text("Ad türü gösteriyorsa (ör. \"1:1\", \"Daily\", \"Mülakat\") o şablon kullanılır; kendi şablonun hep geçerli."),
                        details: Text("Takvimdeki toplantının ya da içe aktarılan dosyanın adı türünü açıkça gösteriyorsa (ör. \"1:1\", \"Birebir\", \"Daily\", \"Sprint planning\", \"Mülakat\", \"Müşteri demosu\", \"Ders\") not o şablonla yazılır; ad bir şey söylemiyorsa yukarıdaki şablon kullanılır. Seçilen şablon toplantının ⋯ menüsünde \"(toplantı adından)\" diye görünür, oradan başka şablonla yeniden yazabilirsin. \"Kendi şablonum\" seçiliyken hep o kullanılır.")
                    )
                } control: {
                    Toggle("Şablonu toplantı adına göre seç", isOn: $templateFromTitle)
                        .settingsToggle()
                }
            }
            if showsTemplateGallery {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(title: Text("Şablon galerisi"))
                    TemplateGalleryView(
                        sections: templateGallerySections(templates: templateGallery()), selectedKind: noteTemplate,
                        customName: customTemplateName, customInstructions: customTemplate, initialPreviewID: nil,
                        onUse: { (template: GalleryTemplate) -> Void in useGalleryTemplate(template: template) },
                        onEditCopy: { (template: GalleryTemplate) -> Void in editGalleryTemplateCopy(template: template) }
                    )
                }
                .padding(.top, 26)
                .transition(.opacity)
            }
        }
    }

    /// Galerideki "Kullan": yerleşik tür seçilir; hazır şablon kendi şablonun olarak kaydedilip seçilir.
    private func useGalleryTemplate(template: GalleryTemplate) {
        switch template.source {
        case .builtIn(let kind):
            noteTemplate = kind.rawValue
        case .preset:
            let choice: TemplateCopy = templatePresetChoice(template: template)
            customTemplateName = choice.name
            customTemplate = choice.instructions
            noteTemplate = NoteTemplateKind.custom.rawValue
        }
    }

    /// "Kopyasını düzenle": kendi şablonun şablonun kopyasıyla dolar ve seçilir; galeri kapanır, düzenleyici (Not
    /// bölümünde, galerinin hemen üstünde) odak alır.
    private func editGalleryTemplateCopy(template: GalleryTemplate) {
        let copy: TemplateCopy = templateEditableCopy(template: template)
        customTemplateName = copy.name
        customTemplate = copy.instructions
        noteTemplate = NoteTemplateKind.custom.rawValue
        withAnimation(.smooth(duration: 0.2)) { showsTemplateGallery = false }
        Task { @MainActor in customTemplateFocused = true }
    }
}

/// Canlı çeviri ve Sor: kayıt sırasında not diline çeviri ve gösterimi, "Ne kaçırdım?" süresi, Sor'da web araması.
private struct TranslationSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    var body: some View {
        // Seçili not dilinin adı (arayüz dilinde): çeviri ayarlarında geçer.
        let noteLanguageName: String = storedNoteLanguage(value: noteLanguage).interfaceName
        SettingsGroup(title: Text("Canlı çeviri ve Sor")) {
            SettingsRow(icon: "character.bubble", title: Text("Kayıt sırasında \(noteLanguageName) diline çevir")) {
                if model.displayMode.needsLiveTranslation {
                    SettingsMoreText(
                        summary: Text("Her cümle kayıt sırasında \(noteLanguageName) diline çevrilir."),
                        details: Text("Her cümle kayıt sırasında \(noteLanguageName) diline çevrilir (LLM çağrısı); toplantı zaten bu dildeyse çevrilmez. Toplantı bitince \(noteLanguageName) not (görevler, kararlar, özet) hazırlanır.")
                    )
                } else {
                    SettingsMoreText(
                        summary: Text("Kayıtta yalnız orijinal metin görünür; \(noteLanguageName) not yine yazılır."),
                        details: Text("Kayıt sırasında çeviri yapılmaz, yalnızca orijinal metin görünür. Toplantı bitince \(noteLanguageName) not (görevler, kararlar, özet) yine hazırlanır.")
                    )
                }
            } control: {
                Toggle("Kayıt sırasında \(noteLanguageName) diline çevir", isOn: Binding<Bool>(
                    get: { model.displayMode.needsLiveTranslation },
                    set: { (enabled: Bool) -> Void in model.selectDisplayMode(mode: enabled ? .bilingual : .originalOnly) }
                ))
                .settingsToggle()
            }
            if model.displayMode.needsLiveTranslation {
                SettingsRow(icon: "rectangle.split.2x1", title: Text("Gösterim")) {
                    EmptyView()
                } control: {
                    SettingsMenu(selection: Binding<DisplayMode>(
                        get: { model.displayMode },
                        set: { (mode: DisplayMode) -> Void in model.selectDisplayMode(mode: mode) }
                    ), options: [
                        (DisplayMode.bilingual, Text("İki dil (orijinal + \(noteLanguageName))")),
                        (DisplayMode.turkishOnly, Text("Sadece \(noteLanguageName)")),
                    ])
                }
            }
            SettingsRow(icon: "clock.arrow.circlepath", title: Text("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler")) {
                EmptyView()
            } control: {
                Stepper("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler", value: $missedMinutes, in: SettingsRange.missedWindowMinutes)
                    .labelsHidden()
            }
            AskWebSearchSettingsRow()
        }
    }
}

/// Takvim: takvimi kullan; açıkken toplantı hatırlatması, görüşme başlayınca öneri ve kendiliğinden kayıt.
private struct CalendarSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.calendarEnabled) private var calendarEnabled: Bool = false
    @AppStorage(SettingsKey.meetingReminders) private var meetingReminders: Bool = true
    @AppStorage(SettingsKey.micSuggestions) private var micSuggestions: Bool = true
    @AppStorage(SettingsKey.autoRecord) private var autoRecord: Bool = false

    var body: some View {
        SettingsGroup(title: Text("Takvim")) {
            SettingsRow(icon: "calendar", title: Text("Takvimi kullan")) {
                SettingsMoreText(
                    summary: Text("Yaklaşan toplantılar Ana sayfada görünür; kayıt toplantıya bağlanır."),
                    details: Text("Yaklaşan toplantılar Ana sayfada görünür; kayıt o anki toplantıya bağlanır: başlığı ve katılımcı adları (tanıma ve konuşmacı adı ipucu) kayda geçer. Takvim yalnızca bu Mac'te okunur.")
                )
                if let error = model.calendarError {
                    NoticeText(error, severity: .error)
                }
            } control: {
                Toggle("Takvimi kullan", isOn: Binding<Bool>(
                    get: { calendarEnabled },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            Task { await model.enableCalendar() }
                        } else {
                            model.disableCalendar()
                        }
                    }
                ))
                .settingsToggle()
            }
            if calendarEnabled {
                SettingsRow(icon: "bell", title: Text("Toplantıdan 1 dk önce hatırlat")) {
                    Text("Bildirimdeki \"Kaydı başlat\" ile kayıt hemen başlar.")
                    if let problem = model.notificationProblem {
                        NoticeText(problem, severity: .attention)
                    }
                } control: {
                    // Açılınca bildirim izni yeniden istenir (sonradan kapatılmış olabilir); izin yoksa geri kapanır.
                    Toggle("Toplantıdan 1 dk önce hatırlat", isOn: $meetingReminders)
                        .settingsToggle()
                        .onChange(of: meetingReminders) { (_: Bool, enabled: Bool) in
                            if enabled {
                                Task { await model.enableMeetingReminders() }
                            } else {
                                model.startCalendarServices()
                            }
                        }
                }
                SettingsRow(icon: "phone.arrow.up.right", title: Text("Görüşme başlayınca öner")) {
                    SettingsMoreText(
                        summary: Text("Bir uygulama mikrofonu açınca dinlemeye başlamayı önerir."),
                        details: Text("Teams, Zoom ya da başka bir uygulama mikrofonu açınca (kayıt yoksa) dinlemeye başlamayı önerir; 10 dk'da en fazla bir kez.")
                    )
                } control: {
                    Toggle("Görüşme başlayınca öner", isOn: $micSuggestions)
                        .settingsToggle()
                        .onChange(of: micSuggestions) { (_: Bool, _: Bool) in model.startCalendarServices() }
                }
                SettingsRow(icon: "record.circle", title: Text("Takvimdeki görüşmeleri kendiliğinden kaydet")) {
                    SettingsMoreText(
                        summary: Text("Görüşme bağlantılı toplantılar kendiliğinden kaydedilir."),
                        details: Text("Takvimde görüşme bağlantısı (Teams, Zoom, Meet) olan bir toplantı sürerken başka bir uygulama mikrofonu açınca kayıt kendiliğinden başlar ve bildirilir; bir kez kur, unut. Katılımcılara kaydettiğini söylemek senin sorumluluğunda.")
                    )
                } control: {
                    Toggle("Takvimdeki görüşmeleri kendiliğinden kaydet", isOn: $autoRecord)
                        .settingsToggle()
                        .onChange(of: autoRecord) { (_: Bool, _: Bool) in model.startCalendarServices() }
                }
            }
        }
    }
}

/// Yardım ve geri bildirim: kurulumu yeniden açma, güncelleme, geri bildirim ve (abonelik sürümünde) iletişim.
private struct SupportSettings: View {
    let model: AppModel
    let updater: AppUpdater
    let onShowSetup: @MainActor () -> Void

    var body: some View {
        SettingsGroup(title: Text("Uygulama")) {
            SettingsRow(icon: "arrow.counterclockwise", title: Text("Kurulum")) {
                #if HOSTED_EDITION
                Text("İzinler, hesap ve kısayollar adım adım.")
                #else
                Text("İzinler, anahtarlar ve kısayollar adım adım.")
                #endif
            } control: {
                Button("Kurulumu yeniden aç") { onShowSetup() }
            }
            UpdateSettingsRow(updater: updater)
            FeedbackSettingsRow { await diagnosticsReportText(model: model, updater: updater) }
            #if HOSTED_EDITION
            if let contact = hostedSiteURL(path: "contact") {
                SettingsRow(icon: "envelope", title: Text("Bize ulaş")) {
                    Text("Sorular, hesap ve ödeme için sitedeki iletişim sayfası.")
                } control: {
                    Link("İletişim sayfasını aç", destination: contact)
                }
            }
            #endif
        }
    }
}

/// Veri ve gizlilik: eşitleme, ses saklama, Spotlight, (abonelikte) kullanım istatistikleri ve hesap silme, çökme
/// raporları.
private struct DataSettings: View {
    let model: AppModel
    let crashReports: CrashReportCenter
    /// Abonelik sürümünde Plan ve faturalandırma'yı açar (hesap silme orada, satır içinde onaylanır).
    let onOpenAccount: @MainActor () -> Void
    @AppStorage(SettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    /// Kısalan saklama süresi eski sesleri hemen siler: onay bekleyen seçim.
    @State private var pendingRetention: PendingAudioRetention?

    /// Saklama süresi seçimi: süre kısalıp eski sesler hemen silinecekse önce sorulur (`pendingRetention`).
    private var retentionSelection: Binding<Int> {
        Binding<Int>(
            get: { retentionDays },
            set: { (days: Int) -> Void in
                let count: Int = audioDeletedByRetentionChange(records: model.meetings, now: Date(), setting: days).count
                if count > 0 {
                    pendingRetention = PendingAudioRetention(days: days, meetingCount: count)
                } else {
                    retentionDays = days
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: Text("Eşitleme")) {
                #if HOSTED_EDITION
                HostedSyncSettingsRow()
                #else
                // Abonelik sürümünde iCloud yetkisi yok (eşitleme geliştirici sürümünün kapsayıcısıyla karışmasın).
                CloudSyncRow(model: model)
                #endif
            }
            SettingsGroup(title: Text("Veri ve gizlilik")) {
                SettingsRow(icon: "waveform.badge.minus", title: Text("Sesleri sakla")) {
                    #if HOSTED_EDITION
                    Text("Süre dolunca ses dosyaları silinir; metin ve not kalır.")
                    #else
                    SettingsMoreText(
                        summary: Text("Süre dolunca ses dosyaları silinir; metin ve not kalır."),
                        details: Text("Süre dolunca ses dosyaları silinir; metin ve not kalır. iCloud eşitlemesi açıksa iPhone'da kaydedilen toplantıların sesi de bu süreye göre silinir.")
                    )
                    #endif
                } control: {
                    SettingsMenu(selection: retentionSelection, options: audioRetentionChoices.map { (days: Int) -> (Int, Text) in
                        (days, days == audioRetentionNever ? Text("Hiç silme") : Text("\(days) gün"))
                    })
                }
                .onChange(of: retentionDays) { (_: Int, _: Int) in
                    model.applyRetention()
                }
                .alert(
                    "Sesler silinsin mi?",
                    isPresented: Binding<Bool>(get: { pendingRetention != nil }, set: { if !$0 { pendingRetention = nil } }),
                    presenting: pendingRetention
                ) { (pending: PendingAudioRetention) in
                    Button("Sesleri sil", role: .destructive) { retentionDays = pending.days }
                    Button("Vazgeç", role: .cancel) {}
                } message: { (pending: PendingAudioRetention) in
                    Text("\(pending.meetingCount) toplantının sesi şimdi silinecek; metin ve not kalır. Bu geri alınamaz.")
                }
                SpotlightSettingsRow(model: model)
                #if HOSTED_EDITION
                // The AI disclosure's state: what goes to which service, agree or withdraw (`HostedAIConsentCenter`).
                HostedAIConsentSettingsRow(consent: .shared, isBusy: model.isBusy)
                UsageStatisticsRow()
                #endif
                CrashReportsSettings(center: crashReports)
                #if HOSTED_EDITION
                // Oturum yokken silinecek hesap yok (iPhone'daki gibi gizli).
                if case .signedIn = HostedAccount.shared.state {
                    SettingsRow(icon: "trash", title: Text("Hesabı sil")) {
                        Text("Hesabını ve sunucudaki kayıtlarını Plan ve faturalandırma'dan silebilirsin; bu Mac'teki notlar kalır.")
                    } control: {
                        Button("Plan ve faturalandırma'yı aç") { onOpenAccount() }
                    }
                }
                #endif
            }
        }
    }
}

#if HOSTED_EDITION
/// Sitedeki sayfa (ör. `contact`); site adresi geçersizse nil (bağlantı gösterilmez, hata loglanır).
private func hostedSiteURL(path: String) -> URL? {
    do {
        return try HostedServices.siteBase().appending(path: path)
    } catch {
        settingsPageLogger.error("Site adresi geçersiz, sayfa bağlantısı gösterilmiyor, yol: \(path, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

private let settingsPageLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SettingsPage")
#endif

#if HOSTED_EDITION
/// "Anonim kullanım istatistiklerini paylaş" (varsayılan açık): kapatılınca bekleyen istatistikler silinir ve hiçbiri
/// gönderilmez. Sürüm ve yapay zekâ amacı başlıkları hizmetin işleyişi için her durumda gider (açıklamada yazar).
private struct UsageStatisticsRow: View {
    @AppStorage(SettingsKey.shareUsageStatistics) private var shareUsageStatistics: Bool = true

    var body: some View {
        SettingsRow(icon: "chart.bar.xaxis", title: Text("Anonim kullanım istatistiklerini paylaş")) {
            SettingsMoreText(
                summary: Text("Yalnızca kullanım sayıları paylaşılır; toplantı içeriği, ses ya da metin paylaşılmaz."),
                details: Text("Açıkken uygulama günde bir kez hangi özellikleri kullandığını (canlı çeviri, Sor, sesle yazma, ekran görüntüleri, bağlantı ve dışa aktarma türleri) ve bağlantı kopması, not hatası gibi güvenilirlik sayılarını gönderir; ilk açılışı ve giriş adımlarını (pencere açıldı, kapatıldı, hata verdi, tamamlandı) da sayar. Bunlar hesabına bağlanmaz. Ses, metin, not, başlık ya da ad asla gönderilmez. Uygulama ve macOS sürümü ile yapay zekâ isteklerinin hangi özellik için olduğu, hizmetin işleyişi için her durumda gönderilir.")
            )
        } control: {
            Toggle("Anonim kullanım istatistiklerini paylaş", isOn: $shareUsageStatistics).settingsToggle()
        }
        .onChange(of: shareUsageStatistics) { (_: Bool, enabled: Bool) in
            if !enabled {
                HostedTelemetryCenter.shared.sharingDisabled()
            }
        }
    }
}
#endif

/// Anahtar hesabının arayüz adı. Saf fonksiyondur.
private func secretAccountTitle(account: SecretAccount) -> String {
    switch account {
    case .deepgram: "Deepgram"
    case .elevenlabs: "ElevenLabs"
    case .anthropic: "Anthropic"
    case .openai: String(localized: "OpenAI uyumlu")
    case .webhook: "Webhook"
    case .channel: String(localized: "Kanal bağlantısı")
    case .destinations: String(localized: "Kanal bağlantıları")
    case .taskTrackers: String(localized: "Görev araçları")
    }
}

/// iCloud ile eşitle: biten toplantılar iCloud Drive'a taşınır, iPhone uygulamasıyla ortak görünür; kapatınca geri
/// bu Mac'e taşınır. İş sürerken ve hata olunca durum satırda görünür.
private struct CloudSyncRow: View {
    let model: AppModel

    var body: some View {
        SettingsRow(icon: "icloud", title: Text("iCloud ile eşitle")) {
            SettingsMoreText(
                summary: Text("Biten toplantılar iCloud Drive'a taşınır ve iPhone'da da görünür."),
                details: Text("Biten toplantılar iCloud Drive'a taşınır ve iPhone'daki AI-Notepad'de de görünür; iPhone'da kaydedilenler buraya gelir. Kayıt ve işleme her zaman bu Mac'te yapılır. Kapatınca iCloud'daki toplantıların bir kopyası bu Mac'te kalır; iPhone'dakiler etkilenmez.")
            )
            switch model.cloud.state {
            case .working:
                Text("Toplantılar taşınıyor…").foregroundStyle(Theme.ink)
            case .failed(let message):
                NoticeText(message, severity: .error)
            case .idle:
                if model.cloudDownloadingCount > 0 {
                    Text("\(model.cloudDownloadingCount) toplantı iCloud'dan iniyor…").foregroundStyle(Theme.ink)
                }
            }
        } control: {
            Toggle("iCloud ile eşitle", isOn: Binding<Bool>(
                get: { model.cloud.location == .iCloud },
                set: { (enabled: Bool) -> Void in
                    Task {
                        if enabled {
                            await model.enableCloudSync()
                        } else {
                            await model.disableCloudSync()
                        }
                    }
                }
            ))
            .settingsToggle()
            .disabled(model.cloud.state == .working || model.isBusy)
        }
    }
}

/// Yazı tipi menüsünün seçenekleri: gömülü Inter ve SF tasarımları, bu Mac'te kullanılabilen seçkin aileler (her biri kendi
/// yazısıyla, iPhone'daki seçici gibi); şu an seçili yüklü aile listede yoksa o da eklenir (menü seçimi gösterebilsin).
@MainActor
private func fontOptions(current: AppFontChoice, usableFamilies: [String]) -> [(String, Text)] {
    let builtIn: [(String, Text)] = PanelFontDesign.allCases.map { (design: PanelFontDesign) -> (String, Text) in
        (AppFontChoice.design(design).storageValue, Text(verbatim: design.displayName).font(fontChoicePreview(choice: .design(design), size: 13)))
    }
    // `current` is the font in use (already checked as usable), so it stays listed while `usableFamilies` loads.
    let inUse: Set<String> = if case .installed(let family) = current { [family] } else { [] }
    let families: [String] = suggestedFontFamilies(available: Set(usableFamilies).union(inUse), current: current)
    return builtIn + families.map { (family: String) -> (String, Text) in
        (AppFontChoice.installed(family: family).storageValue, Text(verbatim: family).font(fontChoicePreview(choice: .installed(family: family), size: 13)))
    }
}

/// Görünüm: tema, vurgu rengi, yüzey, ada, yazı tipi, arayüz yazısı, okuma metni, satır aralığı, alt boşluk. Yazı
/// seçenekleri iPhone'dakiyle aynı ad, aralık ve varsayılandadır (yüzey ve ada yalnız Mac'te). Değişiklikler anında görünür.
private struct AppearanceSettings: View {
    @AppStorage(SettingsKey.theme) private var theme: String = AppTheme.light.rawValue
    @AppStorage(SettingsKey.themeFamily) private var themeFamily: String?
    @AppStorage(SettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(SettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue
    @AppStorage(SettingsKey.uiScale) private var uiScale: Double = PanelAppearance.standard.uiScale
    @AppStorage(SettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(SettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing
    @AppStorage(SettingsKey.islandEnabled) private var islandEnabled: Bool = true
    @AppStorage(SettingsKey.surface) private var surface: String = PanelAppearance.standard.surface.rawValue
    @AppStorage(SettingsKey.surfaceOpacity) private var surfaceOpacity: Double = PanelAppearance.standard.surfaceOpacity
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// Seçilebilen yazı aileleri (`macUsableFontFamilies`); sayfa açılınca ve yazı yüklenip kaldırılınca okunur.
    @State private var usableFamilies: [String] = []

    var body: some View {
        let choice: ThemeChoice = resolvedThemeChoice(storedFamily: themeFamily, storedTheme: theme, defaultTheme: .light)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(title: Text("Tema"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(AppTheme.allCases, id: \.self) { (item: AppTheme) in
                        ThemeSwatch(theme: item, isSelected: choice.theme == item, accent: appearance.accent.color) {
                            // Palet de yazılır: saklı palet yokken eski Kâğıt kullanıcısı (Klasik) Kor'a kaymasın.
                            themeFamily = choice.family.rawValue
                            theme = item.rawValue
                        }
                    }
                }
            }
            .padding(.top, 26)
            SettingsGroup(title: Text("Renk ve pencere")) {
                SettingsRow(icon: "swatchpalette", title: Text("Renk paleti")) {
                    Text("Kor: sıcak krem zemin, bakır vurgu ve kapaklar. Klasik: önceki beyaz görünüm ve pastel kapaklar. Zeytin: düz kömür zemin, limon-zeytin vurgu ve serif başlıklar.")
                } control: {
                    PillPicker(
                        selection: Binding<ThemeFamily>(get: { choice.family }, set: { (family: ThemeFamily) -> Void in themeFamily = family.rawValue }),
                        options: [(ThemeFamily.ember, "Kor"), (ThemeFamily.classic, "Klasik"), (ThemeFamily.olive, "Zeytin")]
                    )
                    .fixedSize()
                }
                SettingsRow(icon: "paintpalette", title: Text("Vurgu rengi")) {
                    EmptyView()
                } control: {
                    SettingsMenu(selection: $accent, options: PanelAccent.allCases.map { (item: PanelAccent) -> (String, Text) in
                        (item.rawValue, Text(Image(systemName: "circle.fill")).foregroundColor(item.color) + Text(verbatim: "  ") + Text(verbatim: item.displayName))
                    })
                }
                SettingsRow(icon: "macwindow", title: Text("Yüzey")) {
                    Text("Cam yüzeyde masaüstü pencerenin ardından hafifçe görünür.")
                } control: {
                    PillPicker(selection: $surface, options: [
                        (WindowSurface.solid.rawValue, "Dolu"), (WindowSurface.frosted.rawValue, "Buzlu cam"), (WindowSurface.clear.rawValue, "Şeffaf cam"),
                    ])
                    .fixedSize()
                }
                if surface != WindowSurface.solid.rawValue {
                    SettingsRow(icon: "circle.lefthalf.filled", title: Text("Cam opaklığı: %\(Int((surfaceOpacity * 100).rounded()))")) {
                        EmptyView()
                    } control: {
                        HStack(spacing: 10) {
                            Image(systemName: "circle.dotted").foregroundStyle(Theme.muted)
                            Slider(value: $surfaceOpacity, in: AppearanceRange.surfaceOpacity, step: 0.05).frame(width: 200)
                            Image(systemName: "circle.fill").foregroundStyle(Theme.muted)
                        }
                    }
                }
                SettingsRow(icon: "capsule", title: Text("Kayıt sırasında çentikte adayı göster")) {
                    EmptyView()
                } control: {
                    Toggle("Kayıt sırasında çentikte adayı göster", isOn: $islandEnabled).settingsToggle()
                }
            }
            SettingsGroup(title: Text("Yazı")) {
                SettingsRow(icon: "textformat", title: Text("Yazı tipi")) {
                    Text("Uygulamanın tamamında; uygulamanın dillerindeki tüm harfleri içeren yüklü yazı tipleri seçilebilir.")
                } control: {
                    HStack(spacing: 8) {
                        // The menu shows the font in use: a stored family that cannot be used (removed, or missing the
                        // app's letters) falls back to the default, and the menu says so instead of the stored name.
                        SettingsMenu(
                            selection: Binding<String>(
                                get: { appearance.fontChoice.storageValue }, set: { (value: String) -> Void in fontDesign = value }
                            ),
                            options: fontOptions(current: appearance.fontChoice, usableFamilies: usableFamilies)
                        )
                        Menu {
                            ForEach(usableFamilies, id: \.self) { (family: String) in
                                Button(family) { fontDesign = AppFontChoice.installed(family: family).storageValue }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.pill)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .hoverHint("Tüm yüklü yazı tipleri", alignment: .trailing, edge: .bottom)
                    }
                }
                SettingsRow(icon: "textformat.size", title: Text("Arayüz yazısı: %\(appearancePercent(value: uiScale, reference: 1))")) {
                    Text("Menüler, başlıklar ve düğmeler dahil tüm yazılar.")
                } control: {
                    SettingsSlider(value: $uiScale, range: AppearanceRange.uiScale, step: 0.05, minSymbol: "textformat.size.smaller", maxSymbol: "textformat.size.larger")
                }
                SettingsRow(icon: "character", title: Text("Okuma metni: %\(appearancePercent(value: textSize, reference: PanelAppearance.standard.textSize))")) {
                    Text("Canlı metin ve notlar.")
                } control: {
                    SettingsSlider(value: $textSize, range: AppearanceRange.textSize, step: 1, minSymbol: "textformat.size.smaller", maxSymbol: "textformat.size.larger")
                }
                SettingsRow(icon: "line.3.horizontal", title: Text("Satır aralığı: \(Int(lineSpacing))")) {
                    EmptyView()
                } control: {
                    SettingsSlider(
                        value: $lineSpacing, range: AppearanceRange.lineSpacing, step: 1,
                        minSymbol: "arrow.down.right.and.arrow.up.left", maxSymbol: "arrow.up.left.and.arrow.down.right"
                    )
                }
                SettingsRow(icon: "arrow.down.to.line", title: Text("Alt boşluk: \(Int(bottomSpacing)) pt")) {
                    EmptyView()
                } control: {
                    SettingsSlider(
                        value: $bottomSpacing, range: AppearanceRange.bottomSpacing, step: 4,
                        minSymbol: "arrow.down.right.and.arrow.up.left", maxSymbol: "arrow.up.left.and.arrow.down.right"
                    )
                }
                // Önizleme seçilen yazı tipi ve boyutla.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hyvää huomenta kaikille, aloitetaan palaveri.")
                        .font(appearance.secondaryFont)
                        .opacity(0.6)
                    Text("Herkese günaydın, toplantıya başlayalım.")
                        .font(appearance.bodyFont)
                }
                .lineSpacing(appearance.lineSpacing)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
                .padding(.vertical, SettingsRowMetrics.verticalPadding)
            }
            SettingsCard {
                SettingsRow(icon: "arrow.uturn.backward", title: Text("Varsayılan görünüm")) {
                    EmptyView()
                } control: {
                    Button("Görünümü varsayılana döndür") {
                        resetAppearanceSettings(defaults: UserDefaults.standard)
                    }
                }
            }
            .padding(.top, 26)
        }
        .task { usableFamilies = macUsableFontFamilies() }
        .onReceive(NotificationCenter.default.publisher(for: NSFont.fontSetChangedNotification)) { (_: Notification) in
            forgetFontCoverage()
            usableFamilies = macUsableFontFamilies()
        }
    }
}

/// Bu Mac'te seçilebilen yazı aileleri: yüklü ve uygulamanın harflerini kendisi çiziyor (bkz. `fontFamilyCoversAppText`;
/// yoksa "ş" gibi harfler başka, daha kalın bir yazıyla çizilirdi).
@MainActor
private func macUsableFontFamilies() -> [String] {
    NSFontManager.shared.availableFontFamilies.filter { (family: String) -> Bool in
        !family.hasPrefix(".") && fontFamilyCoversAppText(family: family)
    }
}

/// Canlı metin motoru seçenekleri: cihaz içi tanıma yalnızca sistem destekliyorsa (macOS 26+) listelenir.
private func liveEngineOptions() -> [(LiveEngine, Text)] {
    let others: [(LiveEngine, Text)] = [
        (LiveEngine.deepgram, Text("Deepgram (bulut, ~1 sn)")),
        (LiveEngine.whisperKit, Text("Mac'te (WhisperKit, internetsiz)")),
    ]
    guard appleSpeechSupportedBySystem() else {
        return others
    }
    return [(LiveEngine.appleSpeech, Text("Cihaz içi (ücretsiz, anahtarsız)"))] + others
}

/// LLM sağlayıcı seçenekleri: cihaz içi model yalnızca sistem destekliyorsa (macOS 26+) listelenir.
private func llmProviderOptions() -> [(String, Text)] {
    let others: [(String, Text)] = [
        (LLMProviderKind.anthropic.rawValue, Text("Anthropic (Claude)")),
        (LLMProviderKind.openAICompatible.rawValue, Text("OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…)")),
    ]
    guard onDeviceLLMSupportedBySystem() else {
        return others
    }
    return [(LLMProviderKind.onDevice.rawValue, Text("Cihaz içi (ücretsiz, anahtarsız)"))] + others
}

/// Cihaz içi modelin (Apple Intelligence) durumu: kullanılabilirlik, ne yapılacağı, desteklenen diller ve ana toplantı
/// dili ya da not dili desteklenmiyorsa uyarı.
private struct OnDeviceLLMStatus: View {
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    var body: some View {
        switch onDeviceStatus() {
        case .success(let config):
            SettingsRow(icon: "sparkles", title: Text("Apple Intelligence")) {
                Text("Not, çeviri ve soru bu cihazda yazılır: ücretsiz, anahtarsız, internetsiz. Model küçüktür (4 bin token bağlam): uzun toplantılar parça parça işlenir, not kendi anahtarınla seçilen modellerden daha kısa olur.")
            } control: {
                Label("Hazır", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            }
            SettingsRow(icon: "globe", title: Text("Desteklenen diller")) {
                Text(verbatim: onDeviceLanguageNames(config: config).joined(separator: ", "))
            } control: {
                EmptyView()
            }
            // Ana toplantı dili ya da not dili modelde yoksa uyarı.
            if let warning = MeetingLanguage(rawValue: primaryLanguage).flatMap({ (language: MeetingLanguage) -> String? in
                onDeviceModeWarning(config: config, primaryLanguage: language, outputLanguage: storedNoteLanguage(value: noteLanguage))
            }) {
                SettingsRow(icon: "exclamationmark.triangle", title: Text("Ana toplantı dili")) {
                    Text(verbatim: warning)
                } control: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.muted)
                }
            }
        case .failure(let error):
            SettingsRow(icon: "sparkles", title: Text("Apple Intelligence")) {
                Text(verbatim: userFacingMessage(error: error))
            } control: {
                Label("Kullanılamıyor", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.muted)
            }
        }
    }

    /// Modelin ayarı (kullanılabiliyorsa) ya da neden kullanılamadığı.
    private func onDeviceStatus() -> Result<OnDeviceConfig, any Error> {
        Result { () throws -> OnDeviceConfig in try onDeviceConfig() }
    }
}

/// LLM sağlayıcısı: cihaz içi, Anthropic ya da OpenAI uyumlu (OpenAI, Ollama, OpenCode Go…).
private struct LLMSettings: View {
    let model: AppModel
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue
    @AppStorage(SettingsKey.llmBaseURL) private var baseURL: String = ""
    @AppStorage(SettingsKey.llmFastModel) private var fastModel: String = ""
    @AppStorage(SettingsKey.llmSmartModel) private var smartModel: String = ""
    @AppStorage(SettingsKey.llmFastEffort) private var openAIFastEffort: String = ""
    @AppStorage(SettingsKey.llmSmartEffort) private var openAISmartEffort: String = ""
    @AppStorage(SettingsKey.claudeFastModel) private var claudeFastModel: String = ClaudeModel.haiku.rawValue
    @AppStorage(SettingsKey.claudeSmartModel) private var claudeSmartModel: String = ClaudeModel.haiku.rawValue
    @AppStorage(SettingsKey.claudeFastEffort) private var claudeFastEffort: String = LLMEffort.low.rawValue
    @AppStorage(SettingsKey.claudeSmartEffort) private var claudeSmartEffort: String = LLMEffort.medium.rawValue
    @State private var testResult: ConnectionTest = .idle
    /// Süren bağlantı denemesi: ayar değişince iptal edilir (eski ayarın sonucu yeni ayarın yanında görünmesin).
    @State private var testTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: Text("Sağlayıcı")) {
                LocalLLMSetup(model: model)
                SettingsRow(icon: "cpu", title: Text("Sağlayıcı")) {
                    if !onDeviceLLMSupportedBySystem() {
                        Text("Cihaz içi model (Apple Intelligence) macOS 26 gerektirir.")
                    }
                } control: {
                    SettingsMenu(selection: $provider, options: llmProviderOptions())
                }
                if provider == LLMProviderKind.onDevice.rawValue {
                    OnDeviceLLMStatus()
                } else if provider == LLMProviderKind.anthropic.rawValue {
                    SecretField(icon: "key", title: "Anthropic anahtarı", account: .anthropic, onChange: model.settingsChanged)
                } else {
                    SettingsRow(icon: "link", title: Text("Temel adres")) {
                        EmptyView()
                    } control: {
                        TextField("Temel adres", text: $baseURL, prompt: Text(verbatim: "http://localhost:11434/v1"))
                            .settingsField(width: 260)
                    }
                    SecretField(icon: "key", title: "Anahtar (Ollama'da gerekmez)", account: .openai, onChange: model.settingsChanged)
                }
            }
            if provider == LLMProviderKind.anthropic.rawValue {
                SettingsGroup(title: Text("Canlı çeviri")) {
                    SettingsRow(icon: "bolt", title: Text("Model")) {
                        SettingsMoreText(
                            summary: Text("Hızlı model ve düşük effort önerilir: çeviri 1–2 sn'de gelir."),
                            details: Text("Hızlı model ve düşük effort önerilir: çeviri 1–2 sn'de gelir. Haiku ve Sonnet'te high ve altında düşünme kapatılır; Opus, Fable ve xhigh/max'ta düşünme açık kalır, çeviriler gecikip birikebilir.")
                        )
                    } control: {
                        SettingsMenu(selection: $claudeFastModel, options: claudeModelOptions())
                    }
                    SettingsRow(icon: "gauge.with.dots.needle.33percent", title: Text("Effort")) {
                        EmptyView()
                    } control: {
                        SettingsMenu(selection: $claudeFastEffort, options: claudeEffortOptions(levels: LLMEffort.allCases))
                    }
                }
                SettingsGroup(title: Text("\"Ne kaçırdım?\", soru ve toplantı notu")) {
                    SettingsRow(icon: "doc.text", title: Text("Model")) {
                        Text("Haiku ve yüksek effort önerilir: uzun toplantının notu parça parça yazılır, büyük model gerekmez.")
                    } control: {
                        SettingsMenu(selection: $claudeSmartModel, options: claudeModelOptions())
                    }
                    SettingsRow(icon: "gauge.with.dots.needle.67percent", title: Text("Effort")) {
                        EmptyView()
                    } control: {
                        SettingsMenu(selection: $claudeSmartEffort, options: claudeEffortOptions(levels: smartEfforts))
                    }
                }
            } else if provider != LLMProviderKind.onDevice.rawValue {
                SettingsGroup(title: Text("Canlı çeviri")) {
                    SettingsRow(icon: "bolt", title: Text("Model")) {
                        EmptyView()
                    } control: {
                        TextField("Model", text: $fastModel, prompt: Text("ör. gpt-5-mini, qwen3:8b")).settingsField(width: 260)
                    }
                    SettingsRow(icon: "gauge.with.dots.needle.33percent", title: Text("Effort")) {
                        EmptyView()
                    } control: {
                        SettingsMenu(selection: $openAIFastEffort, options: openAIEffortOptions())
                    }
                }
                SettingsGroup(title: Text("\"Ne kaçırdım?\", soru ve toplantı notu")) {
                    SettingsRow(icon: "doc.text", title: Text("Model")) {
                        EmptyView()
                    } control: {
                        TextField("Model", text: $smartModel, prompt: Text("ör. gpt-5, gpt-oss:120b")).settingsField(width: 260)
                    }
                    SettingsRow(icon: "gauge.with.dots.needle.67percent", title: Text("Effort")) {
                        Text("Effort `reasoning_effort` olarak gönderilir; desteklemeyen sunucularda \"Gönderme\"yi seç.")
                    } control: {
                        SettingsMenu(selection: $openAISmartEffort, options: openAIEffortOptions())
                    }
                }
            }
            SettingsGroup(title: Text("Bağlantı")) {
                SettingsRow(icon: "bolt.horizontal", title: Text("Bağlantıyı dene")) {
                    switch testResult {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.small)
                    case .succeeded(let reply):
                        Label("Çalışıyor: \(reply)", systemImage: "checkmark.circle.fill").foregroundStyle(.tint).lineLimit(1)
                    case .failed(let message):
                        NoticeText(message, severity: .error)
                    }
                } control: {
                    Button("Bağlantıyı dene") {
                        testResult = .running
                        testTask?.cancel()
                        testTask = Task {
                            let result: ConnectionTest = await testConnection()
                            if !Task.isCancelled {
                                testResult = result
                            }
                        }
                    }
                    .disabled(testResult == .running)
                }
            }
        }
        // Yazarken her tuşta Keychain denetlenmesin: son değişiklikten 0,6 sn sonra bir kez.
        .task(id: [provider, baseURL, fastModel, smartModel, openAIFastEffort, openAISmartEffort, claudeFastModel, claudeSmartModel, claudeFastEffort, claudeSmartEffort]) {
            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                // Yeni bir değişiklik geldi; bu bekleme iptal edildi.
                return
            }
            testTask?.cancel()
            testResult = .idle
            model.settingsChanged()
        }
    }
}

/// Claude modelleri (ad, kısa nitelik). Saf fonksiyondur.
private func claudeModelOptions() -> [(String, Text)] {
    [
        (ClaudeModel.haiku.rawValue, Text("Claude Haiku 5.5 — en hızlı, en ucuz")),
        (ClaudeModel.sonnet.rawValue, Text("Claude Sonnet 5.5 — dengeli")),
        (ClaudeModel.opus.rawValue, Text("Claude Opus 5.5 — güçlü")),
        (ClaudeModel.fable.rawValue, Text("Claude Fable 5.1 — en yetenekli, en pahalı")),
    ]
}

/// Claude effort seviyeleri, düşükten en yükseğe (not/özet için en çok `high`, bkz. `smartEfforts`). Saf fonksiyondur.
private func claudeEffortOptions(levels: [LLMEffort]) -> [(String, Text)] {
    levels.map { (level: LLMEffort) -> (String, Text) in (level.rawValue, Text(effortTitle(level: level))) }
}

/// Effort seviyesinin arayüz adı.
private func effortTitle(level: LLMEffort) -> LocalizedStringKey {
    switch level {
    case .low: "Düşük"
    case .medium: "Orta"
    case .high: "Yüksek"
    case .xhigh: "Çok yüksek"
    case .max: "En yüksek"
    }
}

/// OpenAI uyumlu effort (`reasoning_effort`): gönderme ya da low/medium/high (sunucuların kabul ettiği değerler).
/// Saf fonksiyondur.
private func openAIEffortOptions() -> [(String, Text)] {
    [
        ("", Text("Gönderme")),
        (LLMEffort.low.rawValue, Text("Düşük")),
        (LLMEffort.medium.rawValue, Text("Orta")),
        (LLMEffort.high.rawValue, Text("Yüksek")),
    ]
}

private enum ConnectionTest: Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)
}

/// Seçili sağlayıcının iki modelini de dener: çeviri (hızlı) ve not (akıllı). Biri başarısızsa hangisi olduğu yazılır.
@MainActor
private func testConnection() async -> ConnectionTest {
    let provider: LLMProvider
    do {
        provider = try await resolveLLMProvider()
    } catch {
        return .failed(userFacingMessage(error: error))
    }
    let reply: String
    do {
        reply = try await translateSentence(provider: provider, sentence: connectionTestSentence(provider: provider), context: [], language: selectedNoteLanguage())
    } catch {
        return .failed(String(localized: "Çeviri modeli: \(userFacingMessage(error: error))"))
    }
    do {
        _ = try await sendLLM(provider: provider, request: LLMRequest(
            purpose: .connectionTest, tier: .smart, system: "Yalnızca \"tamam\" yaz.", userText: "Bağlantı denemesi", maxTokens: 4000, jsonSchema: nil, timeoutSec: 120, images: [], webSearch: nil
        ))
    } catch {
        return .failed(String(localized: "Not modeli: \(userFacingMessage(error: error))"))
    }
    return .succeeded(reply)
}

/// Bağlantı denemesinde çevrilen cümle: Fince; cihaz içi model Fince anlamadığı için orada İngilizce. Saf fonksiyondur.
private func connectionTestSentence(provider: LLMProvider) -> String {
    guard case .onDevice = provider else {
        return "Hyvää huomenta."
    }
    return "Good morning."
}

/// Bulut konuşma tanıma anahtarları.
private struct KeySettings: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup(title: Text("Konuşma tanıma")) {
                SecretField(icon: "waveform", title: "Deepgram", account: .deepgram, onChange: model.settingsChanged)
                SecretField(icon: "person.2.wave.2", title: "ElevenLabs", account: .elevenlabs, onChange: model.settingsChanged)
            } footer: {
                Text("Anahtarlar macOS Anahtar Zinciri'nde saklanır ve hiçbir zaman gösterilmez. Terminal'den eklediysen ilk kullanımda çıkan izin penceresinde \"Her Zaman İzin Ver\"i seç.")
            }
        }
    }
}

/// Tıklanınca bir sonraki tuş bileşimini kaydeden düğme. Kısayol atanmamışsa (`binding` nil) "Kısayol seç" yazar.
/// Kayıt `ShortcutController`'dadır: kaydedilirken uygulamanın global kısayolları askıdadır (atanmış bir bileşime basmak
/// onu tetiklemez); Esc, düğmeye yeniden tıklamak, odak kaybı ya da sayfadan çıkmak kaydı bitirir.
struct ShortcutRecorder: View {
    let shortcuts: ShortcutController
    let action: ShortcutAction
    let binding: KeyBinding?

    private var isRecording: Bool {
        shortcuts.recorder.recording == action
    }

    var body: some View {
        Button {
            shortcuts.handleRecorder(event: .tapped(action))
        } label: {
            Group {
                if isRecording {
                    Text("Tuşlara bas…")
                } else if let binding {
                    Text(verbatim: keyBindingDisplay(binding: binding))
                } else {
                    Text("Kısayol seç")
                }
            }
            .monospaced()
            .frame(minWidth: 110)
        }
        .accessibilityLabel(accessibilityText)
        .onDisappear { shortcuts.handleRecorder(event: .disappeared(action)) }
    }

    private var accessibilityText: String {
        if isRecording {
            return String(localized: "Kısayol kaydediliyor")
        }
        guard let binding else {
            return String(localized: "Kısayol atanmadı. Seç")
        }
        return String(localized: "Kısayol: \(keyBindingDisplay(binding: binding)). Değiştir")
    }
}

/// AppKit değiştiricilerini Carbon maskesine çevirir. Saf fonksiyondur.
func carbonModifiers(flags: NSEvent.ModifierFlags) -> UInt32 {
    var modifiers: UInt32 = 0
    if flags.contains(.control) { modifiers |= CarbonModifier.control }
    if flags.contains(.option) { modifiers |= CarbonModifier.option }
    if flags.contains(.shift) { modifiers |= CarbonModifier.shift }
    if flags.contains(.command) { modifiers |= CarbonModifier.command }
    return modifiers
}

// MARK: Ayar satırı bileşenleri

/// Kart içindeki satırın iç boşluğu ve simge sütunu: satırlar arasındaki çizgi metnin başladığı yerden başlar.
private enum SettingsRowMetrics {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let iconSpacing: CGFloat = 12
    /// Simge kutusu (28) + aralık: çizginin ve tam genişlikli içeriğin girintisi.
    static let textInset: CGFloat = horizontalPadding + 28 + iconSpacing
}

/// Ayar satırı: solda simge kutusu, başlık ve kısa soluk açıklama, sağda denetim. Satırlar arasındaki ince çizgiyi
/// içinde durduğu `SettingsGroup` (ya da `SettingsCard`) çizer.
struct SettingsRow<Detail: View, Control: View>: View {
    let icon: String
    let title: Text
    let detail: Detail
    let control: Control

    init(icon: String, title: Text, @ViewBuilder detail: () -> Detail, @ViewBuilder control: () -> Control) {
        self.icon = icon
        self.title = title
        self.detail = detail()
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: SettingsRowMetrics.iconSpacing) {
            SettingsIconTile(systemImage: icon)
            HStack(alignment: .center, spacing: 20) {
                SettingsRowText(title: title, detail: detail)
                // Denetim sığdığı genişlikte kalır; dar pencerede açıklama satırları kısalır (düğme yazıları ezilmesin).
                control.fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Altında tam genişlikli içerik olan ayar satırı (ör. tanıma sözlüğü düzenleyicisi): başlık ve açıklamanın altında,
/// metinle aynı hizada.
struct SettingsStackedRow<Detail: View, Content: View>: View {
    let icon: String
    let title: Text
    let detail: Detail
    let content: Content

    init(icon: String, title: Text, @ViewBuilder detail: () -> Detail, @ViewBuilder content: () -> Content) {
        self.icon = icon
        self.title = title
        self.detail = detail()
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsRowMetrics.iconSpacing) {
            SettingsIconTile(systemImage: icon)
            VStack(alignment: .leading, spacing: 10) {
                SettingsRowText(title: title, detail: detail)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
            }
        }
        .padding(.horizontal, SettingsRowMetrics.horizontalPadding)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Satırın başlığı ve soluk açıklaması (açıklama yoksa yalnız başlık).
private struct SettingsRowText<Detail: View>: View {
    let title: Text
    let detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title
                .appFont(size: 14, weight: .medium)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                detail
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kısa açıklama ve sonunda vurgu renginde "Ayrıntılar": dokununca yerinde tam açıklama açılır ("Daha az" kapatır).
/// Mac'te tüm açıklama satır içinde kalır (açılır pencere ya da "?" yok); satır yine de tek bakışta okunur.
struct SettingsMoreText: View {
    let summary: Text
    let details: Text
    @State private var isExpanded: Bool = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            (isExpanded ? details : summary) + Text(verbatim: " ") + Text(isExpanded ? LocalizedStringKey("Daha az") : LocalizedStringKey("Ayrıntılar")).foregroundStyle(.tint)
        }
        .buttonStyle(.plain)
        .multilineTextAlignment(.leading)
        .linkPointer(isEnabled: true)
        .accessibilityHint(Text(isExpanded ? LocalizedStringKey("Kısa açıklamayı gösterir") : LocalizedStringKey("Tam açıklamayı gösterir")))
    }
}

/// Ayar grubu: üstte sakin bölüm adı, altında tek kart; kartın satırları arasında ince çizgi, isteğe bağlı altında
/// dipnot. Gruptaki satırların hepsi gizliyse (koşullu satırlar) bölüm adı da görünmez.
struct SettingsGroup<Content: View, Footer: View>: View {
    let title: Text
    let content: Content
    let footer: Footer

    init(title: Text, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    init(title: Text, @ViewBuilder content: () -> Content) where Footer == EmptyView {
        self.init(title: title, content: content) { EmptyView() }
    }

    var body: some View {
        Group(subviews: content) { (rows: SubviewsCollection) in
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(title: title)
                    SettingsCardRows(rows: rows)
                    VStack(alignment: .leading, spacing: 4) {
                        footer
                    }
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                }
                .padding(.top, 26)
            }
        }
    }
}

/// Bölüm adı (ör. "Dil", "Takvim"): küçük, soluk, büyük harfe çevrilmez.
struct SettingsSectionTitle: View {
    let title: Text

    var body: some View {
        title
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(Theme.muted)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Başlıksız ayar kartı (ör. Bağlantılar'daki gelişmiş satırlar).
struct SettingsCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Group(subviews: content) { (rows: SubviewsCollection) in
            if !rows.isEmpty {
                SettingsCardRows(rows: rows)
            }
        }
    }
}

/// Kartın kendisi: beyaz yüzey, ince çerçeve, gölge yok; satırlar arasında metnin hizasından başlayan ince çizgi.
private struct SettingsCardRows: View {
    let rows: SubviewsCollection

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { (item: (offset: Int, element: Subview)) in
                if item.offset > 0 {
                    SettingsDivider().padding(.leading, SettingsRowMetrics.textInset)
                }
                item.element
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.line))
    }
}

/// Çok satırlı ayar metni (tanıma sözlüğü, kendi şablonun): yumuşak zeminli, ince çerçeveli düzenleyici.
struct SettingsTextEditor: View {
    @Binding var text: String
    let height: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .appFont(size: 13, weight: .regular)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: height)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Ayar kaydırıcısı: iki ucunda küçük ve büyük ucu gösteren soluk simgeler, hepsinde aynı genişlik (Görünüm'deki
/// kaydırıcılar alt alta hizalı dursun).
private struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minSymbol: String
    let maxSymbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: minSymbol)
                .foregroundStyle(Theme.muted)
                .frame(width: 18)
                .accessibilityHidden(true)
            Slider(value: $value, in: range, step: step).frame(width: 220)
            Image(systemName: maxSymbol)
                .foregroundStyle(Theme.muted)
                .frame(width: 18)
                .accessibilityHidden(true)
        }
    }
}

/// Satırlar arasındaki ince çizgi.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }
}

/// Açılır seçim: beyaz hap düğme (seçili değer ve ok); menüde seçili değer işaretli.
struct SettingsMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, Text)]

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: (Value, Text))) in
                    item.element.1.tag(item.element.0)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                options.first { $0.0 == selection }?.1 ?? Text(verbatim: "–")
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(size: 10, weight: .semibold)
                    .foregroundStyle(Theme.muted)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.pill)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

extension View {
    /// Ayar yazı alanı: düz alan, beyaz zemin, ince çerçeve.
    func settingsField(width: CGFloat) -> some View {
        textFieldStyle(.plain)
            .appFont(size: 14, weight: .regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line))
    }

    /// Ayar anahtarı: etiketsiz, vurgu renginde, küçük boyda (sağa yaslı satırlarda ağır durmasın; karşılama ve Ayarlar'da
    /// aynı).
    func settingsToggle() -> some View {
        toggleStyle(.switch).labelsHidden().controlSize(.small)
    }
}

/// Anahtarsız kullanım: Mac'teki Ollama algılanır, yüklü modellerden önerilen seçilir ve tek tıkla LLM sağlayıcısı
/// yapılır (OpenAI uyumlu, `localhost:11434`). Bulut modelleri işaretlenir (metin Ollama'ya gider). Ollama yoksa kurulum
/// adımları gösterilir.
struct LocalLLMSetup: View {
    let model: AppModel
    @State private var state: DetectState = .idle
    @State private var choice: String = ""

    private enum DetectState: Equatable {
        case idle
        case detecting
        case found([String])
        case missing(String)
        case applied(String)
    }

    var body: some View {
        SettingsRow(icon: "desktopcomputer", title: Text("Mac'te, anahtarsız (Ollama)")) {
            switch state {
            case .idle, .detecting:
                Text("Yerel model (ör. gpt-oss:20b, qwen3) ile not ve çeviri: anahtar gerekmez, toplantı metni Mac'ten çıkmaz. Konuşma tanıma için Genel › Canlı metin'de \"Mac'te (WhisperKit)\" seç.")
            case .found(let names):
                Text("\(names.count) model bulundu. Bulut modelleri (\"cloud\") internet ister ve metni Ollama'ya gönderir.")
            case .missing(let message):
                NoticeText("Ollama bulunamadı (\(message)). ollama.com'dan kur, sonra Terminal'de: ollama pull gpt-oss:20b", severity: .attention)
            case .applied(let name):
                Label("Kullanılıyor: \(name). Bağlantıyı denemek için LLM sekmesi.", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        } control: {
            HStack(spacing: 8) {
                if case .found(let names) = state {
                    SettingsMenu(selection: $choice, options: names.map { (name: String) -> (String, Text) in
                        (name, isOllamaCloudModel(name: name) ? Text(verbatim: "\(name) ☁︎") : Text(verbatim: name))
                    })
                    Button("Kullan") { apply(name: choice) }
                        .buttonStyle(.pillPrimary)
                        .disabled(choice.isEmpty)
                } else {
                    Button(state == .detecting ? "Aranıyor…" : "Algıla", systemImage: "magnifyingglass") { detect() }
                        .disabled(state == .detecting)
                }
            }
        }
    }

    private func detect() {
        state = .detecting
        Task {
            do {
                let names: [String] = try await ollamaModels(baseURL: URL(string: "http://localhost:11434/v1")!).filter(isChatModel)
                guard let recommended = recommendedOllamaModel(names: names) else {
                    state = .missing(String(localized: "sohbet modeli yüklü değil"))
                    return
                }
                choice = recommended
                state = .found(names)
            } catch {
                state = .missing(error.localizedDescription)
            }
        }
    }

    /// Sağlayıcıyı Ollama'ya çevirir: iki model sınıfı da seçilen model, effort gönderilmez (her sunucu desteklemez).
    private func apply(name: String) {
        let defaults: UserDefaults = .standard
        defaults.set(LLMProviderKind.openAICompatible.rawValue, forKey: SettingsKey.llmProvider)
        defaults.set("http://localhost:11434/v1", forKey: SettingsKey.llmBaseURL)
        defaults.set(name, forKey: SettingsKey.llmFastModel)
        defaults.set(name, forKey: SettingsKey.llmSmartModel)
        defaults.set("", forKey: SettingsKey.llmFastEffort)
        defaults.set("", forKey: SettingsKey.llmSmartEffort)
        model.settingsChanged()
        state = .applied(name)
    }
}

/// Onay bekleyen ses saklama seçimi: yeni süre ve sesi hemen silinecek toplantı sayısı.
struct PendingAudioRetention: Equatable {
    let days: Int
    let meetingCount: Int
}
