import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar: hesap (giriş yapan kimlik, plan, kullanım, çıkış, hesap silme), görünüm, kayıt (rıza hatırlatması, ses
/// saklama), takvim, toplantı dili ve ad, gizlilik (anonim kullanım istatistikleri), sürüm.
struct PhoneSettingsTab: View {
    let store: PhoneStore
    let calendar: PhoneCalendar
    let account: HostedAccount
    /// Kayıt ya da işleme sürüyor: çıkış ve hesap silme kapalı.
    let isMeetingInFlight: Bool
    let crashReports: CrashReportCenter
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    @AppStorage(PhoneSettingsKey.userName) private var userName: String = ""
    @AppStorage(PhoneSettingsKey.consentReminder) private var consentReminder: Bool = true
    @AppStorage(PhoneSettingsKey.audioRetentionDays) private var retentionDays: Int = 30
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(PhoneSettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(shareUsageStatisticsDefaultsKey) private var shareUsageStatistics: Bool = true
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue
    @AppStorage(PhoneSettingsKey.noteTemplate) private var noteTemplate: String = NoteTemplateKind.general.rawValue
    @AppStorage(PhoneSettingsKey.customTemplate) private var customTemplate: String = ""
    @AppStorage(PhoneSettingsKey.customVocabulary) private var vocabulary: String = ""
    @AppStorage(PhoneSettingsKey.missedWindowMinutes) private var missedMinutes: Int = 3
    @Environment(\.openURL) private var openURL: OpenURLAction

    var body: some View {
        // Seçili not dilinin adı (arayüz dilinde): çeviri ayarlarında geçer.
        let noteLanguageName: String = phoneStoredNoteLanguage(value: noteLanguage).interfaceName
        NavigationStack {
            List {
                CrashReportNotice(center: crashReports)
                Section {
                    NavigationLink {
                        PhoneAccountScreen(account: account, isMeetingInFlight: isMeetingInFlight)
                    } label: {
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
                    Toggle("Kayıt başlarken haber vermeyi hatırlat", isOn: $consentReminder)
                    Picker("Sesleri sakla", selection: $retentionDays) {
                        ForEach([7, 14, 30, 60, 90, 180, 365], id: \.self) { (days: Int) in
                            Text("\(days) gün").tag(days)
                        }
                    }
                    .onChange(of: retentionDays) { (_: Int, _: Int) in
                        store.applyRetention(now: Date())
                    }
                } header: {
                    PhoneHintHeader(
                        title: Text("Kayıt"),
                        hint: Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur. Süre dolunca ses dosyaları silinir, metin ve not kalır; yarıda kalan ya da başarısız toplantının sesi iki kat süre saklanır. Telefondaki Teams/Zoom görüşmeleri kaydedilemez (iOS izin vermez); onlar için Mac'i kullan.")
                    )
                }
                CalendarSettingsSection(calendar: calendar)
                Section {
                    Picker("Ana toplantı dili", selection: $primaryLanguage) {
                        ForEach(MeetingLanguage.allCases, id: \.rawValue) { (language: MeetingLanguage) in
                            Text(languageName(language: language)).tag(language.rawValue)
                        }
                    }
                    Picker("Not ve çeviri dili", selection: $noteLanguage) {
                        ForEach(ShareLanguage.allCases, id: \.rawValue) { (language: ShareLanguage) in
                            Text(verbatim: language.nativeName).tag(language.rawValue)
                        }
                    }
                    // Etiketli satır: ad yazılınca alan yalnızca adı gösteriyor, neyin adı olduğu anlaşılmıyordu.
                    PhoneHintRow(hint: Text("Toplantı notunda sana düşen görevleri ayırmak için kullanılır.")) {
                        LabeledContent {
                            TextField("Adın", text: $userName, prompt: Text("İsteğe bağlı"))
                                .multilineTextAlignment(.trailing)
                                .textContentType(.givenName)
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                        } label: {
                            Text("Adın")
                        }
                    }
                } header: {
                    PhoneHintHeader(
                        title: Text("Toplantı"),
                        hint: Text("Toplantı notları, canlı çeviri ve Sor cevapları not ve çeviri dilinde yazılır. Önceki notlar yazıldıkları dilde kalır.")
                    )
                }
                Section {
                    Toggle("Kayıt sırasında \(noteLanguageName) diline çevir", isOn: Binding<Bool>(
                        get: { (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation },
                        set: { (enabled: Bool) -> Void in displayMode = (enabled ? DisplayMode.bilingual : .originalOnly).rawValue }
                    ))
                    if (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation {
                        Picker("Gösterim", selection: $displayMode) {
                            Text("İki dil (orijinal + \(noteLanguageName))").tag(DisplayMode.bilingual.rawValue)
                            Text("Sadece \(noteLanguageName)").tag(DisplayMode.turkishOnly.rawValue)
                        }
                    }
                    Stepper(value: $missedMinutes, in: missedWindowMinutesRange) {
                        Text("\"Ne kaçırdım?\" son \(missedMinutes) dakikayı özetler")
                    }
                } header: {
                    PhoneHintHeader(
                        title: Text("Canlı metin"),
                        hint: Text((DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation
                            ? "Her cümle kayıt sırasında \(noteLanguageName) diline çevrilir; toplantı zaten bu dildeyse çevrilmez. Kayıtta ✦ düğmesi son dakikaları özetler ve toplantıya soru sordurur."
                            : "Kayıt sırasında çeviri yapılmaz, yalnızca orijinal metin görünür; toplantı bitince \(noteLanguageName) not yine hazırlanır. Kayıtta ✦ düğmesi son dakikaları özetler ve toplantıya soru sordurur.")
                    )
                }
                Section {
                    Picker("Not şablonu", selection: $noteTemplate) {
                        ForEach(NoteTemplateKind.allCases, id: \.self) { (kind: NoteTemplateKind) in
                            Text(verbatim: kind.displayName).tag(kind.rawValue)
                        }
                    }
                    if noteTemplate == NoteTemplateKind.custom.rawValue {
                        NavigationLink {
                            PhoneTextSettingScreen(
                                title: "Kendi şablonun", key: PhoneSettingsKey.customTemplate,
                                help: "Notta neyin öne çıkmasını istediğini yaz. Örnek: “Riskleri ayrı bir paragrafta say, her kararın gerekçesini yaz.”"
                            )
                        } label: {
                            LabeledContent("Kendi şablonun", value: customTemplate.isEmpty ? String(localized: "Boş") : String(localized: "Yazıldı"))
                        }
                    }
                    NavigationLink {
                        PhoneTextSettingScreen(
                            title: "Tanıma sözlüğü", key: PhoneSettingsKey.customVocabulary,
                            help: "Konuşma tanımanın doğru yazması gereken adlar, şirket ve ürün adları, kısaltmalar; satır başına bir tane (2–40 karakter, en fazla 5 sözcük; en fazla 30 kullanılır). Canlı metinde ve kayıt bitince yapılan son geçişte uygulanır. Toplantılarda verdiğin konuşmacı adları ve sözlük terimleri zaten kendiliğinden eklenir."
                        )
                    } label: {
                        LabeledContent("Tanıma sözlüğü", value: String(localized: "\(customVocabulary(text: vocabulary).count) terim"))
                    }
                } header: {
                    PhoneHintHeader(
                        title: Text("Not"),
                        hint: Text("Yeni toplantıların notu bu türe göre yazılır; bir toplantının notunu sonradan başka şablonla yeniden yazabilirsin (⋯ menüsü).")
                    )
                }
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
                    PhoneHintHeader(
                        title: Text("Gizlilik"),
                        hint: Text("Günlük güvenilirlik ve özellik kullanımı sayıları, ilk açılış ve giriş adımları; toplantı içeriği, ses ya da metin içermez.")
                    )
                }
                Section {
                    // Arayüz dili iOS'ta uygulama başına iPhone Ayarları'ndan seçilir (Mac'te uygulamanın içinden).
                    if let settings = URL(string: UIApplication.openSettingsURLString) {
                        Button {
                            openURL(settings)
                        } label: {
                            LabeledContent("Arayüz dili", value: interfaceLanguageName())
                        }
                        .tint(Theme.ink)
                    }
                    LabeledContent("Sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Toplantılar", value: "\(store.meetings.count)")
                    NavigationLink("Geri bildirim gönder") { PhoneFeedbackForm() }
                    CrashReportsLink(center: crashReports)
                } header: {
                    PhoneHintHeader(
                        title: Text("Uygulama"),
                        hint: Text("Arayüz dili iPhone Ayarları › \(appName) › Dil bölümünden değişir.")
                    )
                }
            }
            .navigationTitle("Ayarlar")
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
            PhoneHintHeader(
                title: Text("Takvim"),
                hint: Text("Kayıt ekranında sıradaki toplantılar görünür; süren bir toplantıda başlattığın kayıt onun adını ve katılımcılarını alır (adlar tanımaya da yardım eder). Hatırlatmadaki \"Dinlemeye başla\" kaydı hemen başlatır.")
            )
        }
    }
}

/// Çok satırlı metin ayarı (tanıma sözlüğü, kendi şablonun): kart içinde düzenleyici, açıklama sağ üstteki ipucunda;
/// her değişiklik hemen saklanır.
private struct PhoneTextSettingScreen: View {
    let title: LocalizedStringKey
    let key: String
    let help: LocalizedStringKey
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                InfoHint(Text(help))
            }
        }
        .onAppear {
            text = UserDefaults.standard.string(forKey: key) ?? ""
            isFocused = true
        }
        .onChange(of: text) { (_: String, value: String) in
            UserDefaults.standard.set(value, forKey: key)
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
