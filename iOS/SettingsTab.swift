import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar: hesap (giriş yapan kimlik, plan, kullanım, çıkış, hesap silme), görünüm, bağlantılar (kanallar, görev
/// araçları), kayıt (rıza hatırlatması, ses saklama), takvim, toplantı dili ve ad, konuşmacılar (sesinden tanıma), not,
/// Sor (web araması), beceriler (SKILL.md), gizlilik (anonim kullanım istatistikleri), sürüm ve tanılama.
struct PhoneSettingsTab: View {
    let store: PhoneStore
    /// Sor: SKILL.md'den içe aktarılan beceriler onun tariflerine eklenir.
    let ask: PhoneAsk
    let calendar: PhoneCalendar
    let account: HostedAccount
    /// Hesabın verisine yazan bir iş sürüyor (bkz. `phoneOpenWriters`): çıkış ve hesap silme kapalı.
    let isMeetingInFlight: Bool
    let crashReports: CrashReportCenter
    /// Kök ekranda yatay kaydırma komşu sekmeye geçer.
    let router: PhoneRouter
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    @AppStorage(PhoneSettingsKey.consentReminder) private var consentReminder: Bool = true
    @AppStorage(PhoneSettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(PhoneSettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(shareUsageStatisticsDefaultsKey) private var shareUsageStatistics: Bool = true
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue
    @AppStorage(PhoneSettingsKey.noteTemplate) private var noteTemplate: String = NoteTemplateKind.general.rawValue
    @AppStorage(PhoneSettingsKey.customTemplate) private var customTemplate: String = ""
    @AppStorage(PhoneSettingsKey.templateFromTitle) private var templateFromTitle: Bool = true
    @AppStorage(PhoneSettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    /// Sor'da web araması (varsayılan açık; `askWebSearchAllowed` okur).
    @AppStorage(askWebSearchSettingKey) private var askWebSearch: Bool = true
    /// "Kurulumu yeniden aç" bunu kapatır: kök görünüm karşılamayı yeniden sunar.
    @AppStorage(PhoneSettingsKey.onboardingCompleted) private var onboardingCompleted: Bool = true
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        // Seçili not dilinin adı (arayüz dilinde): çeviri ayarlarında geçer.
        let noteLanguageName: String = phoneStoredNoteLanguage(value: noteLanguage).interfaceName
        // Yol yönlendiricidedir: Kayıt'taki engel bildiriminin "Kullanımı gör"ü hesabı buradan açar.
        NavigationStack(path: Binding<[PhoneSettingsRoute]>(get: { router.settingsPath }, set: { (path: [PhoneSettingsRoute]) -> Void in router.settingsPath = path })) {
            List {
                CrashReportNotice(center: crashReports)
                Section {
                    NavigationLink(value: PhoneSettingsRoute.account) {
                        PhoneAccountRow(account: account)
                    }
                } header: {
                    Text("Hesap")
                }
                Section {
                    NavigationLink {
                        PhoneAppearanceScreen()
                    } label: {
                        PhoneAppearanceRow(theme: theme, accent: accent)
                    }
                } header: {
                    Text("Görünüm")
                }
                Section {
                    PhoneConnectionsRow()
                } header: {
                    Text("Bağlantılar")
                } footer: {
                    Text("Notlar Slack, Teams, Discord, Notion ya da Zoom'a, görevler Linear ya da Jira'ya gider.")
                }
                Section {
                    Toggle("Kayıt başlarken haber vermeyi hatırlat", isOn: $consentReminder)
                    MenuPickerRow(title: "Sesleri sakla", selection: $retentionDays, options: [7, 14, 30, 60, 90, 180, 365].map { (days: Int) -> MenuPickerOption<Int> in
                        MenuPickerOption(value: days, label: Text("\(days) gün"))
                    })
                    .onChange(of: retentionDays) { (_: Int, _: Int) in
                        store.applyRetention(now: Date())
                    }
                } header: {
                    Text("Kayıt")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur.")
                        Text("Süre dolunca ses silinir, not kalır; Teams/Zoom görüşmeleri için Mac'i kullan.")
                    }
                }
                CalendarSettingsSection(calendar: calendar)
                Section {
                    MenuPickerRow(title: "Ana toplantı dili", selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> MenuPickerOption<String> in
                        MenuPickerOption(value: language.rawValue, label: Text(languageName(language: language)))
                    })
                    MenuPickerRow(title: "Not ve çeviri dili", selection: $noteLanguage, options: ShareLanguage.allCases.map { (language: ShareLanguage) -> MenuPickerOption<String> in
                        MenuPickerOption(value: language.rawValue, label: Text(verbatim: language.nativeName))
                    })
                    // Etiketli satır: ad yazılınca alan yalnızca adı gösteriyor, neyin adı olduğu anlaşılmıyordu.
                    PhoneCaptionedRow(caption: Text("Notta sana düşen görevleri ayırmak için kullanılır.")) {
                        LabeledContent {
                            TextField("Adın", text: Binding<String>(get: { store.userName }, set: { (name: String) -> Void in store.setUserName(name: name) }), prompt: Text("İsteğe bağlı"))
                                .multilineTextAlignment(.trailing)
                                .textContentType(.givenName)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                        } label: {
                            Text("Adın")
                        }
                    }
                } header: {
                    Text("Toplantı")
                } footer: {
                    Text("Notlar, canlı çeviri ve Sor cevapları not ve çeviri dilinde yazılır.")
                }
                PhoneVoiceSettingsSection(voices: store.voices)
                Section {
                    Toggle("Kayıt sırasında \(noteLanguageName) diline çevir", isOn: Binding<Bool>(
                        get: { (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation },
                        set: { (enabled: Bool) -> Void in displayMode = (enabled ? DisplayMode.bilingual : .originalOnly).rawValue }
                    ))
                    if (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation {
                        MenuPickerRow(title: "Gösterim", selection: $displayMode, options: [
                            MenuPickerOption(value: DisplayMode.bilingual.rawValue, label: Text("İki dil (orijinal + \(noteLanguageName))")),
                            MenuPickerOption(value: DisplayMode.turkishOnly.rawValue, label: Text("Sadece \(noteLanguageName)")),
                        ])
                    }
                    Stepper(value: $missedMinutes, in: missedWindowMinutesRange) {
                        Text("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler")
                    }
                } header: {
                    Text("Canlı metin")
                } footer: {
                    Text((DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation
                        ? "Cümleler kayıt sırasında \(noteLanguageName) diline çevrilir; ✦ özetler ve soruları yanıtlar."
                        : "Kayıtta yalnız orijinal metin görünür; \(noteLanguageName) not yine yazılır.")
                }
                Section {
                    MenuPickerRow(title: "Not şablonu", selection: $noteTemplate, options: NoteTemplateKind.allCases.map { (kind: NoteTemplateKind) -> MenuPickerOption<String> in
                        MenuPickerOption(value: kind.rawValue, label: Text(verbatim: kind.displayName))
                    })
                    if noteTemplate == NoteTemplateKind.custom.rawValue {
                        NavigationLink {
                            PhoneTextSettingScreen(
                                title: "Kendi şablonun",
                                help: "Notta neyin öne çıkacağını yaz; ör. “Riskleri ayrı say, kararların gerekçesini yaz.”",
                                load: { () -> String in UserDefaults.standard.string(forKey: PhoneSettingsKey.customTemplate) ?? "" },
                                save: { (value: String) -> Void in UserDefaults.standard.set(value, forKey: PhoneSettingsKey.customTemplate) }
                            )
                        } label: {
                            LabeledContent("Kendi şablonun", value: customTemplate.isEmpty ? String(localized: "Boş") : String(localized: "Yazıldı"))
                        }
                    }
                    Toggle(isOn: $templateFromTitle) {
                        Text("Şablonu toplantı adına göre seç")
                        Text("Ad türü gösteriyorsa (ör. \"1:1\", \"Daily\", \"Mülakat\") o şablon kullanılır; kendi şablonun hep geçerli.")
                    }
                    NavigationLink {
                        // Sözlük hesabındır (bkz. `PhoneStore.vocabulary`): aynı iPhone'daki başka hesap görmez.
                        PhoneTextSettingScreen(
                            title: "Tanıma sözlüğü",
                            help: "Doğru yazılması gereken adlar ve terimler; satır başına bir tane, en fazla 30.",
                            load: { () -> String in store.vocabulary },
                            save: { (value: String) -> Void in store.setVocabulary(text: value) }
                        )
                    } label: {
                        LabeledContent("Tanıma sözlüğü", value: String(localized: "\(customVocabulary(text: store.vocabulary).count) terim"))
                    }
                } header: {
                    Text("Not")
                } footer: {
                    Text("Yeni notlar bu şablonla yazılır; eski bir notu ⋯ menüsünden yeniden yazabilirsin.")
                }
                Section {
                    Toggle("Sor'da web aramasına izin ver", isOn: $askWebSearch)
                } header: {
                    Text("Sor")
                } footer: {
                    Text("Toplantılarda olmayan bilgi için cevap başına en çok 3 arama; sorgu Anthropic üzerinden arama sağlayıcısına gider.")
                }
                PhoneSkillImportSection(ask: ask)
                Section {
                    Toggle("Anonim kullanım istatistiklerini paylaş", isOn: $shareUsageStatistics)
                        .onChange(of: shareUsageStatistics) { (_: Bool, enabled: Bool) in
                            if !enabled {
                                HostedTelemetryCenter.shared.sharingDisabled()
                            }
                        }
                    if let privacy = phoneLegalURL(path: "privacy") {
                        Link("Gizlilik politikası", destination: privacy)
                    }
                } header: {
                    Text("Gizlilik")
                } footer: {
                    Text("Yalnızca kullanım sayıları paylaşılır; toplantı içeriği, ses ya da metin paylaşılmaz.")
                }
                Section {
                    // Arayüz dili iOS'ta uygulama başına iPhone Ayarları'ndan seçilir (Mac'te uygulamanın içinden): satır
                    // uygulamanın Ayarlar sayfasını açar, sağdaki simge uygulamadan çıkıldığını gösterir.
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button {
                            openURL(settings)
                        } label: {
                            LabeledContent {
                                HStack(spacing: 6) {
                                    Text(verbatim: interfaceLanguageName())
                                    Image(systemName: "arrow.up.forward.app")
                                        .imageScale(.small)
                                        .accessibilityHidden(true)
                                }
                            } label: {
                                Text("Arayüz dili")
                            }
                        }
                        .tint(Theme.ink)
                        .accessibilityHint(Text("iPhone Ayarları'nı açar"))
                    }
                    // Mac'teki "Kurulumu yeniden aç": karşılama (ad, ana toplantı dili) baştan gösterilir. Kayıt ya da
                    // işleme sürerken kapalı (karşılama tam ekran açılır).
                    Button("Kurulumu yeniden aç") { onboardingCompleted = false }
                        .disabled(isMeetingInFlight)
                    LabeledContent("Sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Toplantılar", value: "\(store.meetings.count)")
                    NavigationLink("Tanılama") { PhoneDiagnosticsScreen(account: account, store: store) }
                    NavigationLink("Geri bildirim gönder") { PhoneFeedbackForm(account: account, store: store) }
                    CrashReportsLink(center: crashReports)
                } header: {
                    Text("Uygulama")
                } footer: {
                    Text("Arayüz dili iPhone Ayarları › \(appName) › Dil'den değişir. Dil satırı yoksa önce iPhone Ayarları › Genel › Dil ve Bölge'ye ikinci bir dil ekle.")
                }
            }
            .phoneTabSwipe(router: router, isEnabled: true)
            .navigationTitle("Ayarlar")
            .navigationDestination(for: PhoneSettingsRoute.self) { (route: PhoneSettingsRoute) in
                switch route {
                case .account:
                    PhoneAccountScreen(account: account, isMeetingInFlight: isMeetingInFlight, store: store)
                }
            }
        }
    }
}

/// Takvim: varsayılan kapalı; açılınca iOS izni sorar. İzin yoksa nedeni ve iPhone Ayarları'na giden düğme görünür.
/// Takvim açıkken toplantıdan 1 dk önce hatırlatma açılabilir (bildirim izni o an sorulur).
private struct CalendarSettingsSection: View {
    let calendar: PhoneCalendar
    @AppStorage(PhoneSettingsKey.calendarEnabled) private var isEnabled: Bool = false
    @AppStorage(PhoneSettingsKey.meetingReminders) private var remindersEnabled: Bool = false
    /// İzin isteniyor (iOS sorusu açık).
    @State private var isRequesting: Bool = false
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        Section {
            Toggle("Takvimi kullan", isOn: Binding<Bool>(
                get: { isEnabled },
                set: { (enabled: Bool) -> Void in
                    guard enabled else {
                        calendar.disable()
                        return
                    }
                    isRequesting = true
                    Task {
                        await calendar.enable()
                        isRequesting = false
                    }
                }
            ))
            .disabled(isRequesting)
            switch calendar.state {
            case .denied:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Takvime erişim izni yok. iPhone Ayarları › Gizlilik ve Güvenlik › Takvimler'den Gistsmith'e tam erişim ver.", systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Button("Ayarlar'ı aç") { openURL(url) }
                    }
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .off:
                EmptyView()
            case .on:
                Toggle("Toplantıdan 1 dk önce hatırlat", isOn: Binding<Bool>(
                    get: { remindersEnabled },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            Task { await calendar.enableReminders() }
                        } else {
                            calendar.disableReminders()
                        }
                    }
                ))
                if let problem = calendar.reminderProblem {
                    Label(problem, systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Takvim")
        } footer: {
            Text("Sıradaki toplantılar Kayıt'ta görünür; kayıt toplantının adını ve kişilerini alır.")
        }
    }
}

/// Çok satırlı metin ayarı (tanıma sözlüğü, kendi şablonun): üstte kısa açıklama, altında kart içinde düzenleyici; her
/// değişiklik hemen saklanır (`save`; açılınca `load` okunur).
private struct PhoneTextSettingScreen: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    let load: @MainActor () -> String
    let save: @MainActor (String) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(help)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .appFont(size: 16, weight: .regular)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(20)
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            text = load()
            isFocused = true
        }
        .onChange(of: text) { (_: String, value: String) in
            save(value)
        }
    }
}

/// Görünüm satırı: vurgu renginde simge, tema adı ve yazı tipi; dokununca Görünüm ayarları açılır.
private struct PhoneAppearanceRow: View {
    let theme: String
    let accent: String
    @AppStorage(PhoneSettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue

    var body: some View {
        let accentColor: Color = (PanelAccent(rawValue: accent) ?? PanelAppearance.standard.accent).color
        HStack(spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Tema, renk ve yazı")
                Text(verbatim: [
                    (AppTheme(rawValue: theme) ?? .system).displayName,
                    fontChoiceName(choice: AppFontChoice.parse(storage: fontDesign) ?? PanelAppearance.standard.fontChoice),
                ].joined(separator: " · "))
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Uygulamanın şu anki arayüz dilinin kendi dilindeki adı ("Türkçe", "English"). Saf değildir: paketin dil seçimini okur.
private func interfaceLanguageName() -> String {
    let code: String = Bundle.main.preferredLocalizations.first ?? "tr"
    let locale: Locale = Locale(identifier: code)
    return locale.localizedString(forLanguageCode: code).map { $0.capitalized(with: locale) } ?? code
}
