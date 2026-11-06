import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit

// iPhone'da yapay zekâ asistanı erişiminin uygulamaya bağlandığı yer, Ayarlar › Bağlantılar'daki satırı ve sayfası
// (Mac'teki `HostedAssistantMacBindings` ve `HostedAssistantSettingsSection` ile aynı davranış; bkz.
// `HostedAssistantCenter`). Yükleme uygulama öndeyken yapılır; arkaya geçince yarıda kalan iş diskteki defterden sürer.

/// Asistan erişiminin iPhone uygulamasına bağları (kök görünüme eklenir).
struct PhoneAssistantBindings: ViewModifier {
    let account: HostedAccount
    let session: PhoneAccountSession
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        let store: PhoneStore = session.store
        content
            .onChange(of: hostedSyncScopeKey(account: account), initial: true) { (_: HostedSyncScopeKey, scopeKey: HostedSyncScopeKey) in
                HostedAssistantCenter.shared.attach(hooks: HostedAssistantHooks(announceConnection: { (name: String) -> Void in
                    store.reportSyncNotice(message: String(localized: "\(name) artık toplantılarını okuyabilir."))
                }))
                Task {
                    await HostedAssistantCenter.shared.update(scopeKey: scopeKey)
                    observe(store: store)
                }
            }
            .onChange(of: store.meetings) { (_: [MeetingRecord], _: [MeetingRecord]) in
                observe(store: store)
            }
            .onChange(of: HostedSyncCenter.shared.meetingsRecordedElsewhere) { (_: Set<String>, _: Set<String>) in
                observe(store: store)
            }
            .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
                if phase == .active {
                    HostedAssistantCenter.shared.appBecameActive()
                }
            }
    }

    /// Diskten ilk okuma bitmeden boş liste verilmez (yoksa kopyadaki her toplantı silinirdi).
    private func observe(store: PhoneStore) {
        guard store.isLoaded else {
            return
        }
        HostedAssistantCenter.shared.observe(meetings: store.meetings, recordedElsewhere: HostedSyncCenter.shared.meetingsRecordedElsewhere, userName: store.userName)
    }
}

/// Ayarlar › Bağlantılar'daki "Yapay zekâ asistanı erişimi" satırı (açık/kapalı); dokununca sayfası açılır. Sunucu
/// özelliği sunmuyorsa (ve hesapta açık değilse) görünmez.
struct PhoneAssistantRow: View {
    @State private var center: HostedAssistantCenter = .shared

    var body: some View {
        Group {
            if center.availability == .available || center.isOn {
                NavigationLink(value: PhoneRoute.assistantAccess) {
                    LabeledContent {
                        Text(center.isOn ? LocalizedStringKey("Etkin") : LocalizedStringKey("Kapalı"))
                    } label: {
                        PhoneSettingLabel(icon: "sparkles", title: Text("Yapay zekâ asistanı erişimi"))
                    }
                }
            }
        }
        .task {
            if center.availability != .available {
                await center.refresh()
            }
        }
    }
}

/// Yapay zekâ asistanı erişimi sayfası: varsayılan kapalı anahtar ve rıza metni; açıkken bağlayıcı adresi, Claude ve
/// ChatGPT'ye ekleme adımları, bağlı asistanlar, bu iPhone'un yüklemesi ve "bu cihazın toplantılarını kaldır".
/// Kapatma ve kaldırma satır içinde onaylanır.
struct PhoneAssistantScreen: View {
    @State private var center: HostedAssistantCenter = .shared
    @State private var confirmingOff: Bool = false
    @State private var confirmingRemove: Bool = false
    @State private var copied: Bool = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: Binding<Bool>(
                    get: { center.isOn },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            Task { await center.turnOn() }
                        } else {
                            confirmingOff = true
                        }
                    }
                )) {
                    PhoneSettingLabel(icon: "sparkles", title: Text("Yapay zekâ asistanları toplantı notlarımı okuyabilsin"))
                }
                .disabled(center.isChanging || confirmingOff)
                if confirmingOff {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kopya hemen silinir ve bütün asistanların bağlantısı kesilir (yedeklerden 30 gün içinde). Toplantıların cihazlarında kalır.")
                            .appFont(size: 13, weight: .regular)
                        HStack {
                            Button("Vazgeç") { confirmingOff = false }
                                .buttonStyle(.borderless)
                            Spacer()
                            Button("Kapat ve kopyayı sil", role: .destructive) {
                                confirmingOff = false
                                Task { await center.turnOff() }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                if let notice = center.notice {
                    NoticeText(notice, severity: .info)
                }
                if let error = center.actionError {
                    NoticeText(error, severity: .error)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Varsayılan olarak kapalı. Açarsan notlarının şifreli bir kopyası (asla ses değil) AB'de saklanır; böylece bağladığın asistanlar onları okuyabilir. Kapatırsan hemen silinir (yedeklerden 30 gün içinde).")
                    Text("Sunucularımız bu kopyayı teknik olarak okuyabilir (saklanırken şifreli, uçtan uca değil). Bir asistanın okudukları o sağlayıcının politikalarına tabidir. Başka araçları (e-posta, web) olan asistanlar toplantıda söylenenlerle yönlendirilebilir.")
                }
            }
            if center.isOn {
                Section {
                    Text(verbatim: hostedAssistantConnectorURL)
                        .font(.system(size: 14, design: .monospaced))
                        .textSelection(.enabled)
                    Button(copied ? LocalizedStringKey("Kopyalandı") : LocalizedStringKey("Adresi kopyala")) {
                        UIPasteboard.general.string = hostedAssistantConnectorURL
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    }
                } header: {
                    Text("Bağlayıcı adresi")
                } footer: {
                    Text("Asistanında özel bağlayıcı olarak ekle; girişte \(appName) hesabını seçersin.")
                }
                stepsSection(title: Text("Claude'a ekle"), steps: [
                    Text("Claude'da Ayarlar › Bağlayıcılar'ı aç ve \"Özel bağlayıcı ekle\"yi seç."),
                    Text("Ad olarak \(appName) yaz, yukarıdaki adresi yapıştır ve ekle."),
                    Text("\"Bağlan\"a bas, \(appName) hesabınla giriş yap ve izin ver."),
                ])
                stepsSection(title: Text("ChatGPT'ye ekle"), steps: [
                    Text("ChatGPT'de Ayarlar › Uygulamalar ve Bağlayıcılar › Gelişmiş ayarlar'da geliştirici modunu aç."),
                    Text("\"Oluştur\"a bas, ad olarak \(appName) yaz, adresi yapıştır ve kimlik doğrulamada OAuth'u seç."),
                    Text("Kaydet, \(appName) hesabınla giriş yap ve izin ver."),
                ])
                grantsSection
                deviceSection
            }
        }
        .navigationTitle("Yapay zekâ asistanı erişimi")
        .navigationBarTitleDisplayMode(.inline)
        .task { await center.refresh() }
    }

    private func stepsSection(title: Text, steps: [Text]) -> some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { (index: Int, step: Text) in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    step
                        .fixedSize(horizontal: false, vertical: true)
                }
                .appFont(size: 15, weight: .regular)
            }
        } header: {
            title
        }
    }

    private var grantsSection: some View {
        Section {
            if center.grants.isEmpty {
                Text("Yukarıdaki adımlarla bir asistan bağladığında burada görünür.")
                    .foregroundStyle(Theme.muted)
            }
            ForEach(center.grants) { (grant: HostedAssistantGrant) in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label {
                            Text(verbatim: assistantGrantDisplayName(grant: grant))
                        } icon: {
                            Image(systemName: grant.verified ? "checkmark.seal" : "exclamationmark.triangle")
                        }
                        Spacer()
                        Button("Bağlantıyı kes", role: .destructive) {
                            Task { await center.disconnect(grant: grant) }
                        }
                        .buttonStyle(.borderless)
                    }
                    if !grant.verified {
                        NoticeText("Doğrulanmamış uygulama. Bu bağlantıyı sen kurmadıysan kes.", severity: .attention)
                            .appFont(size: 13, weight: .regular)
                    }
                    Text("Bağlandı: \(grant.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    if let heavyReadAt = grant.heavyReadAt {
                        NoticeText("\(heavyReadAt.formatted(date: .abbreviated, time: .shortened)) civarında bir saatte 100'den fazla toplantı okudu.", severity: .attention)
                            .appFont(size: 13, weight: .regular)
                    }
                }
            }
        } header: {
            Text("Bağlı asistanlar")
        }
    }

    private var deviceSection: some View {
        Section {
            if center.isDeviceExcluded {
                Text("Bu iPhone'un toplantıları asistanlara açık değil; diğer cihazlarının toplantıları kopyada kalır.")
                Button("Yeniden ekle") { center.includeThisDevice() }
            } else {
                deviceStatus
                if confirmingRemove {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bu iPhone'un yüklediği toplantılar kopyadan hemen silinir ve bu iPhone yüklemeyi bırakır. Toplantıların bu iPhone'da kalır.")
                            .appFont(size: 13, weight: .regular)
                        HStack {
                            Button("Vazgeç") { confirmingRemove = false }
                                .buttonStyle(.borderless)
                            Spacer()
                            Button("Kaldır", role: .destructive) {
                                confirmingRemove = false
                                Task { await center.removeThisDevice() }
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } else {
                    Button("Bu cihazın toplantılarını kaldır…", role: .destructive) { confirmingRemove = true }
                        .disabled(center.isChanging)
                }
            }
        } header: {
            Text("Bu iPhone'un toplantıları")
        } footer: {
            if let copyMeetings = center.copyMeetings {
                Text("Kopyada toplam \(copyMeetings) toplantı (bütün cihazlarından).")
            }
        }
    }

    @ViewBuilder
    private var deviceStatus: some View {
        switch center.uploadStatus {
        case .failed(let message, _):
            NoticeText(message, severity: .attention)
            Button("Yeniden dene") { center.retryNow() }
        case .idle, .uploading:
            if let progress = center.progress {
                if progress.isComplete {
                    Text("Bu iPhone'daki \(progress.total) toplantının kopyası güncel.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Yükleniyor, en yeniden eskiye: \(progress.uploaded) / \(progress.total) toplantı")
                        ProgressView(value: Double(progress.uploaded), total: Double(max(progress.total, 1)))
                    }
                }
            } else {
                Text("Toplantıların işlenince ya da düzenlenince yüklenir; silinen toplantı kopyadan da silinir.")
            }
        }
    }
}
