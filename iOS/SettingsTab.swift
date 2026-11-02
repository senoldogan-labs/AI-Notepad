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

    var body: some View {
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
                    Text("Kayıt")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kayıttan önce katılımcılara haber vermek çoğu yerde yasal zorunluluktur. Süre dolunca ses dosyaları silinir, metin ve not kalır; yarıda kalan ya da başarısız toplantının sesi iki kat süre saklanır.")
                        // Kayıt ekranından taşındı: bilgi ana ekranı kalabalıklaştırıyordu.
                        Text("Telefondaki Teams/Zoom görüşmeleri kaydedilemez (iOS izin vermez); onlar için Mac'i kullan.")
                    }
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
                    TextField("Adın (notta senin görevlerin için)", text: $userName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Toplantı")
                } footer: {
                    Text("Toplantı notları, canlı çeviri ve Sor cevapları not ve çeviri dilinde yazılır; toplantı zaten bu dildeyse çevrilmez. Önceki notlar yazıldıkları dilde kalır.")
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
                    Text("Gizlilik")
                } footer: {
                    Text("Günlük güvenilirlik ve özellik kullanımı sayıları, ilk açılış ve giriş adımları; toplantı içeriği, ses ya da metin içermez.")
                }
                Section("Uygulama") {
                    LabeledContent("Sürüm", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                    LabeledContent("Toplantılar", value: "\(store.meetings.count)")
                    NavigationLink("Geri bildirim gönder") { PhoneFeedbackForm() }
                    CrashReportsLink(center: crashReports)
                }
            }
            .navigationTitle("Ayarlar")
        }
    }
}

/// Takvim: varsayılan kapalı; açılınca iOS izni sorar. İzin yoksa nedeni ve iPhone Ayarları'na giden düğme görünür.
private struct CalendarSettingsSection: View {
    let calendar: PhoneCalendar
    @AppStorage(PhoneSettingsKey.calendarEnabled) private var isEnabled: Bool = false
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
            case .off, .on:
                EmptyView()
            }
        } header: {
            Text("Takvim")
        } footer: {
            Text("Kayıt ekranında sıradaki toplantılar görünür; süren bir toplantıda başlattığın kayıt onun adını ve katılımcılarını alır (adlar tanımaya da yardım eder).")
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
