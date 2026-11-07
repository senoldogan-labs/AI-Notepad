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

/// Ayarlar › Bağlantılar'daki "Yapay zekâ asistanı erişimi" satırı (Mac'teki kapalı kartın başlığı): durum özeti
/// (kapalı, açık ve bağlı asistan sayısı) ve varsa kabul edilmeyen toplantılar; dokununca sayfası açılır. Sunucu
/// özelliği sunmuyorsa (ve hesapta açık değilse) görünmez.
struct PhoneAssistantRow: View {
    @State private var center: HostedAssistantCenter = .shared

    var body: some View {
        Group {
            if center.availability == .available || center.isOn {
                NavigationLink(value: PhoneRoute.assistantAccess) {
                    PhoneSettingLabel(icon: "sparkles", title: Text("Yapay zekâ asistanı erişimi")) {
                        assistantAccessSummary(isOn: center.isOn, grants: center.grants.count)
                        if let refused = phoneRefusedUploads(center: center) {
                            Label {
                                assistantRefusedText(progress: refused).foregroundStyle(Theme.ink)
                            } icon: {
                                Image(systemName: NoticeSeverity.attention.symbol).foregroundStyle(NoticeSeverity.attention.tint)
                            }
                        }
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

/// Kabul edilmeyen toplantılar (bu iPhone yüklüyorken); yoksa nil.
@MainActor
private func phoneRefusedUploads(center: HostedAssistantCenter) -> AssistantUploadProgress? {
    guard center.isOn, !center.isDeviceExcluded, let progress = center.progress, progress.rejected > 0 else {
        return nil
    }
    return progress
}

/// Yapay zekâ asistanı erişimi sayfası: varsayılan kapalı anahtar ve rıza metni; açıkken bağlı asistanlar, sunucunun
/// kabul etmediği toplantılar ("Yeniden dene"), bu iPhone'un yüklemesi ve "bu cihazın toplantılarını kaldır"; bağlayıcı
/// adresi ve Claude ile ChatGPT'ye ekleme adımları "Nasıl bağlanır"ın altında, kapalı başlar (açık/kapalı yalnızca sayfa
/// açıkken hatırlanır). Kapatma ve kaldırma satır içinde onaylanır.
struct PhoneAssistantScreen: View {
    @State private var center: HostedAssistantCenter = .shared
    /// Bağlayıcı adresi ve ekleme adımları gösteriliyor.
    @State private var showsSetup: Bool = launchExpandsAssistantAccess(arguments: CommandLine.arguments)
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
                if let refused = phoneRefusedUploads(center: center) {
                    Section {
                        Label {
                            assistantRefusedText(progress: refused)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: NoticeSeverity.attention.symbol).foregroundStyle(NoticeSeverity.attention.tint)
                        }
                        Button("Yeniden dene") { Task { await center.retryRejected() } }
                    } footer: {
                        Text("Bu toplantılar asistanlara açık değil. Toplantı değişince kendiliğinden yeniden denenir.")
                    }
                }
                grantsSection
                deviceSection
                Section {
                    Button {
                        withAnimation(.smooth(duration: 0.2)) { showsSetup.toggle() }
                    } label: {
                        HStack {
                            Text("Nasıl bağlanır")
                                .foregroundStyle(Theme.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .appFont(size: 13, weight: .semibold)
                                .foregroundStyle(Theme.muted)
                                .rotationEffect(.degrees(showsSetup ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint(Text(showsSetup ? LocalizedStringKey("Ayrıntıları gizler") : LocalizedStringKey("Ayrıntıları gösterir")))
                }
            }
            if center.isOn, showsSetup {
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
                    .sensoryFeedback(.success, trigger: copied) { (_: Bool, new: Bool) -> Bool in new }
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
                Text("Aşağıdaki \"Nasıl bağlanır\" adımlarıyla bir asistan bağladığında burada görünür.")
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
                    Text("Bağlandı: \(grant.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    if let heavyReadAt = grant.heavyReadAt {
                        NoticeText("\(heavyReadAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))) civarında bir saatte 100'den fazla toplantı okudu.", severity: .attention)
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
                    // Kabul edilmeyenler güncel sayılmaz (ayrı bölümde).
                    Text("Bu iPhone'daki \(progress.uploaded) toplantının kopyası güncel.")
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Yükleniyor, en yeniden eskiye: \(progress.uploaded + progress.rejected) / \(progress.total) toplantı")
                        ProgressView(value: Double(progress.uploaded + progress.rejected), total: Double(max(progress.total, 1)))
                    }
                }
            } else {
                Text("Toplantıların işlenince ya da düzenlenince yüklenir; silinen toplantı kopyadan da silinir.")
            }
        }
    }
}
