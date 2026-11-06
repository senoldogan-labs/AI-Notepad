import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar (ana ekrandaki profil simgesinden; Mac'teki gruplarla aynı sırada, her satırda simge kutusu ve gerekirse tek
/// cümlelik açıklama): profil (ad), hesap (giriş yapan kimlik, plan, kullanım, çıkış, hesap silme), görünüm, bağlantılar (kanallar, görev araçları), dil, sen ve
/// konuşmacılar (tanıma sözlüğü, sesinden tanıma), takvim, kayıt (rıza hatırlatması, ses saklama), bildirimler, not,
/// canlı çeviri ve Sor (web araması), beceriler (SKILL.md), gizlilik (anonim kullanım istatistikleri, çökme raporları) ve
/// uygulama (kurulum, sürüm, tanılama, geri bildirim).
struct PhoneSettingsTab: View {
    let store: PhoneStore
    /// Sor: SKILL.md'den içe aktarılan beceriler onun tariflerine eklenir.
    let ask: PhoneAsk
    let calendar: PhoneCalendar
    let account: HostedAccount
    /// Hesabın verisine yazan bir iş sürüyor (bkz. `phoneOpenWriters`): çıkış ve hesap silme kapalı.
    let isMeetingInFlight: Bool
    let crashReports: CrashReportCenter
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
    @AppStorage(PhoneSettingsKey.customTemplateName) private var customTemplateName: String = ""
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
        List {
            CrashReportNotice(center: crashReports)
            Section {
                // Profil (ad; ileride unvan ve şirket) ve hesap (plan, kullanım, çıkış); ana ekrandaki engel
                // bildiriminin "Kullanımı gör"ü hesabı açar (`PhoneRouter.openAccount`).
                NavigationLink(value: PhoneRoute.profile) {
                    PhoneProfileRow(store: store, account: account)
                }
                NavigationLink(value: PhoneRoute.account) {
                    PhoneAccountRow(account: account)
                }
            } header: {
                Text("Hesap")
            }
            PhoneSyncSection()
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
                            PhoneSettingLabel(icon: "globe", title: Text("Arayüz dili"))
                        }
                    }
                    .tint(Theme.ink)
                    .accessibilityHint(Text("iPhone Ayarları'nı açar"))
                }
                PhoneSettingMenuRow(icon: "text.bubble", title: "Not ve çeviri dili", selection: $noteLanguage, options: ShareLanguage.allCases.map { (language: ShareLanguage) -> MenuPickerOption<String> in
                    MenuPickerOption(value: language.rawValue, label: Text(verbatim: language.nativeName))
                })
                PhoneSettingMenuRow(icon: "waveform", title: "Ana toplantı dili", selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> MenuPickerOption<String> in
                    MenuPickerOption(value: language.rawValue, label: Text(languageName(language: language)))
                })
            } header: {
                Text("Dil")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notlar, canlı çeviri ve Sor cevapları not ve çeviri dilinde yazılır.")
                    Text("Arayüz dili iPhone Ayarları › \(appName) › Dil'den değişir. Dil satırı yoksa önce iPhone Ayarları › Genel › Dil ve Bölge'ye ikinci bir dil ekle.")
                }
            }
            // Adın Profil'de (Hesap bölümünün ilk satırı).
            PhoneVoiceSettingsSection(voices: store.voices) {
                NavigationLink {
                    // Sözlük hesabındır (bkz. `PhoneStore.vocabulary`): aynı iPhone'daki başka hesap görmez.
                    PhoneTextSettingScreen(
                        title: "Tanıma sözlüğü",
                        help: "Doğru yazılması gereken adlar ve terimler; satır başına bir tane, en fazla 30.",
                        load: { () -> String in store.vocabulary },
                        save: { (value: String) -> Void in store.setVocabulary(text: value) }
                    )
                } label: {
                    LabeledContent {
                        Text("\(customVocabulary(text: store.vocabulary).count) terim")
                    } label: {
                        PhoneSettingLabel(icon: "character.book.closed", title: Text("Tanıma sözlüğü"))
                    }
                }
            }
            CalendarSettingsSection(calendar: calendar)
            Section {
                Toggle(isOn: $consentReminder) {
                    PhoneSettingLabel(icon: "hand.raised", title: Text("Kayıt başlarken haber vermeyi hatırlat")) {
                        Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur.")
                    }
                }
                PhoneSettingMenuRow(icon: "waveform.badge.minus", title: "Sesleri sakla", selection: $retentionDays, options: [7, 14, 30, 60, 90, 180, 365].map { (days: Int) -> MenuPickerOption<Int> in
                    MenuPickerOption(value: days, label: Text("\(days) gün"))
                })
                .onChange(of: retentionDays) { (_: Int, _: Int) in
                    store.applyRetention(now: Date())
                }
            } header: {
                Text("Kayıt")
            } footer: {
                Text("Süre dolunca ses silinir, not kalır; Teams/Zoom görüşmeleri için Mac'i kullan.")
            }
            NotificationSettingsSection()
            Section {
                PhoneSettingMenuRow(icon: "doc.text", title: "Not şablonu", selection: $noteTemplate, options: NoteTemplateKind.allCases.map { (kind: NoteTemplateKind) -> MenuPickerOption<String> in
                    MenuPickerOption(value: kind.rawValue, label: Text(verbatim: kind == .custom ? customTemplateDisplayName(name: customTemplateName) : kind.displayName))
                })
                if noteTemplate == NoteTemplateKind.custom.rawValue {
                    NavigationLink(value: PhoneRoute.customTemplate) {
                        LabeledContent {
                            Text(customTemplate.isEmpty ? LocalizedStringKey("Boş") : LocalizedStringKey("Yazıldı"))
                        } label: {
                            PhoneSettingLabel(icon: "pencil.line", title: Text("Kendi şablonun"))
                        }
                    }
                }
                NavigationLink(value: PhoneRoute.templateGallery) {
                    PhoneSettingLabel(icon: "square.grid.2x2", title: Text("Şablon galerisi")) {
                        Text("Hazır şablonlara göz at, kullan ya da kopyasını düzenle.")
                    }
                }
                Toggle(isOn: $templateFromTitle) {
                    PhoneSettingLabel(icon: "wand.and.stars", title: Text("Şablonu toplantı adına göre seç")) {
                        Text("Ad türü gösteriyorsa (ör. \"1:1\", \"Daily\", \"Mülakat\") o şablon kullanılır; kendi şablonun hep geçerli.")
                    }
                }
            } header: {
                Text("Not")
            } footer: {
                Text("Yeni notlar bu şablonla yazılır; eski bir notu ⋯ menüsünden yeniden yazabilirsin.")
            }
            Section {
                Toggle(isOn: Binding<Bool>(
                    get: { (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation },
                    set: { (enabled: Bool) -> Void in displayMode = (enabled ? DisplayMode.bilingual : .originalOnly).rawValue }
                )) {
                    PhoneSettingLabel(icon: "character.bubble", title: Text("Kayıt sırasında \(noteLanguageName) diline çevir"))
                }
                if (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation {
                    PhoneSettingMenuRow(icon: "rectangle.split.2x1", title: "Gösterim", selection: $displayMode, options: [
                        MenuPickerOption(value: DisplayMode.bilingual.rawValue, label: Text("İki dil (orijinal + \(noteLanguageName))")),
                        MenuPickerOption(value: DisplayMode.turkishOnly.rawValue, label: Text("Sadece \(noteLanguageName)")),
                    ])
                }
                Stepper(value: $missedMinutes, in: missedWindowMinutesRange) {
                    PhoneSettingLabel(icon: "clock.arrow.circlepath", title: Text("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler"))
                }
                Toggle(isOn: $askWebSearch) {
                    PhoneSettingLabel(icon: "magnifyingglass", title: Text("Sor'da web aramasına izin ver")) {
                        Text("Toplantılarda olmayan bilgi için cevap başına en çok 3 arama; sorgu Anthropic üzerinden arama sağlayıcısına gider.")
                    }
                }
            } header: {
                Text("Canlı çeviri ve Sor")
            } footer: {
                Text((DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation
                    ? "Cümleler kayıt sırasında \(noteLanguageName) diline çevrilir; ✦ özetler ve soruları yanıtlar."
                    : "Kayıtta yalnız orijinal metin görünür; \(noteLanguageName) not yine yazılır.")
            }
            PhoneSkillImportSection(ask: ask)
            Section {
                Toggle(isOn: $shareUsageStatistics) {
                    PhoneSettingLabel(icon: "chart.bar.xaxis", title: Text("Anonim kullanım istatistiklerini paylaş")) {
                        Text("Yalnızca kullanım sayıları paylaşılır; toplantı içeriği, ses ya da metin paylaşılmaz.")
                    }
                }
                .onChange(of: shareUsageStatistics) { (_: Bool, enabled: Bool) in
                    if !enabled {
                        HostedTelemetryCenter.shared.sharingDisabled()
                    }
                }
                if let privacy = phoneLegalURL(path: "privacy") {
                    Link(destination: privacy) {
                        PhoneSettingLabel(icon: "hand.raised.square", title: Text("Gizlilik politikası"))
                    }
                }
                CrashReportsLink(center: crashReports)
            } header: {
                Text("Gizlilik")
            }
            Section {
                // Mac'teki "Kurulumu yeniden aç": karşılama (ad, ana toplantı dili) baştan gösterilir. Kayıt ya da
                // işleme sürerken kapalı (karşılama tam ekran açılır).
                Button {
                    // Karşılama baştan açılır (kaldığı adım silinir).
                    UserDefaults.standard.removeObject(forKey: onboardingStepKey)
                    onboardingCompleted = false
                } label: {
                    PhoneSettingLabel(icon: "arrow.counterclockwise", title: Text("Kurulumu yeniden aç"))
                }
                .disabled(isMeetingInFlight)
                LabeledContent {
                    Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                } label: {
                    PhoneSettingLabel(icon: "info.circle", title: Text("Sürüm"))
                }
                LabeledContent {
                    Text(verbatim: "\(store.meetings.count)")
                } label: {
                    PhoneSettingLabel(icon: "list.bullet.rectangle", title: Text("Toplantılar"))
                }
                NavigationLink {
                    PhoneDiagnosticsScreen(account: account, store: store)
                } label: {
                    PhoneSettingLabel(icon: "stethoscope", title: Text("Tanılama"))
                }
                NavigationLink {
                    PhoneFeedbackForm(account: account, store: store)
                } label: {
                    PhoneSettingLabel(icon: "bubble.left.and.text.bubble.right", title: Text("Geri bildirim gönder"))
                }
            } header: {
                Text("Uygulama")
            }
        }
        .navigationTitle("Ayarlar")
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
            Toggle(isOn: Binding<Bool>(
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
            )) {
                PhoneSettingLabel(icon: "calendar", title: Text("Takvimi kullan"))
            }
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
                Toggle(isOn: Binding<Bool>(
                    get: { remindersEnabled },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            Task { await calendar.enableReminders() }
                        } else {
                            calendar.disableReminders()
                        }
                    }
                )) {
                    PhoneSettingLabel(icon: "bell", title: Text("Toplantıdan 1 dk önce hatırlat"))
                }
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

/// Bildirimler: not hazır, görev günü, haftalık özet ve kayıtsız hafta (her biri varsayılan açık). Açılan anahtar
/// bildirim iznini (sorulmadıysa) sorar, kapanan anahtar o türün bekleyen bildirimlerini hemen kaldırır. İzin yoksa
/// nedeni ve iPhone Ayarları'ndaki bildirim sayfasını açan düğme görünür.
private struct NotificationSettingsSection: View {
    @AppStorage(PhoneSettingsKey.notifyNoteReady) private var noteReady: Bool = true
    @AppStorage(PhoneSettingsKey.notifyTaskDue) private var taskDue: Bool = true
    @AppStorage(PhoneSettingsKey.notifyWeeklySummary) private var weeklySummary: Bool = true
    @AppStorage(PhoneSettingsKey.notifyInactive) private var inactive: Bool = true
    @Environment(\.openURL) private var openURL: OpenURLAction
    private let notifier: EngagementNotifier = .shared

    var body: some View {
        Section {
            if notifier.authorization == .denied {
                VStack(alignment: .leading, spacing: 8) {
                    Label(notificationMessage(error: NotificationError.denied), systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        Button("Ayarlar'ı aç") { openURL(url) }
                    }
                }
            }
            toggle(icon: "bell.badge", title: "Not hazır olunca bildir", help: "Uygulama kapalıyken not hazırlanınca; toplantıyı açar.", isOn: $noteReady, kind: .noteReady)
            toggle(icon: "checklist", title: "Görevin günü gelince hatırlat", help: "O gün 09:00'da; \"Tamamlandı\" ile işaretlenir.", isOn: $taskDue, kind: .taskDue)
            toggle(icon: "calendar.badge.clock", title: "Haftalık özet", help: "Pazartesi 09:00'da açık görevler ve toplantı sayısı.", isOn: $weeklySummary, kind: .weeklySummary)
            toggle(icon: "hourglass", title: "Bir hafta kayıt yoksa hatırlat", help: "Son kayıttan 7 gün sonra 10:00'da bir kez.", isOn: $inactive, kind: .inactive)
        } header: {
            Text("Bildirimler")
        } footer: {
            Text("Kilit ekranında görünebilir: yalnız toplantı adı, sayılar ve görev metni; konuşma metni yok.")
        }
        .task { await notifier.refreshAuthorization() }
    }

    private func toggle(icon: String, title: LocalizedStringKey, help: LocalizedStringKey, isOn: Binding<Bool>, kind: EngagementKind) -> some View {
        Toggle(isOn: isOn) {
            PhoneSettingLabel(icon: icon, title: Text(title)) {
                Text(help)
            }
        }
        .onChange(of: isOn.wrappedValue) { (_: Bool, enabled: Bool) in
            Task { await notifier.settingChanged(kind: kind, enabled: enabled) }
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
