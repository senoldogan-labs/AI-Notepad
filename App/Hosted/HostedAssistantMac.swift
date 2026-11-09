import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// Mac'te yapay zekâ asistanı erişiminin uygulamaya bağlandığı yer ve Ayarlar › Bağlantılar'daki bölümü (bkz.
// `HostedAssistantCenter`).

/// Asistan erişiminin Mac uygulamasına bağları (menü çubuğu simgesine eklenir: ana pencere kapalıyken de çalışır).
struct HostedAssistantMacBindings: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .onAppear {
                HostedAssistantCenter.shared.attach(hooks: HostedAssistantHooks(announceConnection: { (name: String) -> Void in
                    ToastCenter.shared.show(kind: .info, title: String(localized: "\(name) artık toplantılarını okuyabilir."), detail: nil, action: nil)
                }))
            }
            .onChange(of: hostedSyncScopeKey(account: HostedAccount.shared), initial: true) { (_: HostedSyncScopeKey, scopeKey: HostedSyncScopeKey) in
                Task {
                    await HostedAssistantCenter.shared.update(scopeKey: scopeKey)
                    observe()
                }
            }
            .onChange(of: model.meetings) { (_: [MeetingRecord], _: [MeetingRecord]) in
                observe()
            }
            .onChange(of: HostedSyncCenter.shared.meetingsRecordedElsewhere) { (_: Set<String>, _: Set<String>) in
                observe()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
                HostedAssistantCenter.shared.appBecameActive()
            }
    }

    /// Diskten ilk okuma bitmeden boş liste verilmez (yoksa kopyadaki her toplantı silinirdi).
    private func observe() {
        guard model.meetingsLoaded else {
            return
        }
        HostedAssistantCenter.shared.observe(meetings: model.meetings, recordedElsewhere: HostedSyncCenter.shared.meetingsRecordedElsewhere, userName: model.userName)
    }
}

/// Ayarlar › Bağlantılar'daki "Yapay zekâ asistanı erişimi" kartı. Kapalı (varsayılan) başlıkta durum özeti (kapalı,
/// açık ve bağlı asistan sayısı, kabul edilmeyen toplantılar) ve açma oku; açılınca varsayılan kapalı anahtar ve açık
/// rıza metni, açıkken bağlayıcı adresi, Claude ve ChatGPT'ye ekleme adımları, bağlı asistanlar (bağlantıyı kes),
/// sunucunun kabul etmediği toplantılar ("Yeniden dene"), bu Mac'in yüklemesi ve "bu cihazın toplantılarını kaldır".
/// Açık/kapalı yalnızca bu görünüm yaşadıkça hatırlanır. Sunucu özelliği sunmuyorsa (ve hesapta açık değilse) görünmez.
/// Kapatma ve kaldırma satır içinde onaylanır (açılır pencere yok).
struct HostedAssistantSettingsSection: View {
    @State private var center: HostedAssistantCenter = .shared
    @State private var isExpanded: Bool = launchExpandsAssistantAccess(arguments: CommandLine.arguments)
    @State private var confirmingOff: Bool = false
    @State private var confirmingRemove: Bool = false
    @State private var copied: Bool = false

    var body: some View {
        Group {
            if center.availability == .available || center.isOn {
                SettingsCard {
                    headerRow
                    if isExpanded {
                        expandedRows
                    }
                }
                .padding(.top, 26)
            }
        }
        // Ayarlar açılınca sunucudan yeniden sorulur (bağlantılar, başka cihazdaki değişiklik).
        .task { await center.refresh() }
    }

    /// Kabul edilmeyen toplantılar (bu Mac yüklüyorken).
    private var refused: AssistantUploadProgress? {
        guard center.isOn, !center.isDeviceExcluded, let progress = center.progress, progress.rejected > 0 else {
            return nil
        }
        return progress
    }

    /// Başlık: marka kutusu, ad, durum özeti, (varsa) kabul edilmeyen toplantılar ve açma oku; bütün satır basılabilir.
    private var headerRow: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 12) {
                IntegrationTile(style: IntegrationTileStyle(mark: .symbol("sparkles"), palette: .violet, seed: "asistan"), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yapay zekâ asistanı erişimi")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    assistantAccessSummary(isOn: center.isOn, grants: center.grants.count)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    if let refused {
                        Label {
                            assistantRefusedText(progress: refused).foregroundStyle(Theme.ink)
                        } icon: {
                            Image(systemName: NoticeSeverity.attention.symbol).foregroundStyle(NoticeSeverity.attention.tint)
                        }
                        .appFont(size: 12, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(isExpanded ? LocalizedStringKey("Ayrıntıları gizler") : LocalizedStringKey("Ayrıntıları gösterir")))
    }

    @ViewBuilder
    private var expandedRows: some View {
        toggleRow
        // Kabul edilmeyen toplantılar anahtarın hemen altında: açınca ilk görülen sorun.
        if let refused {
            refusedRow(progress: refused)
        }
        if center.isOn {
            addressRow
            stepsRow(title: Text("Claude'a ekle"), steps: [
                Text("Claude'da Ayarlar › Bağlayıcılar'ı aç ve \"Özel bağlayıcı ekle\"yi seç."),
                Text("Ad olarak \(appName) yaz, yukarıdaki adresi yapıştır ve ekle."),
                Text("\"Bağlan\"a bas, \(appName) hesabınla giriş yap ve izin ver."),
            ])
            stepsRow(title: Text("ChatGPT'ye ekle"), steps: [
                Text("ChatGPT'de Ayarlar › Uygulamalar ve Bağlayıcılar › Gelişmiş ayarlar'da geliştirici modunu aç."),
                Text("\"Oluştur\"a bas, ad olarak \(appName) yaz, adresi yapıştır ve kimlik doğrulamada OAuth'u seç."),
                Text("Kaydet, \(appName) hesabınla giriş yap ve izin ver."),
            ])
            grantRows
            deviceRow
        }
    }

    /// Sunucunun kabul etmediği toplantılar: sayı, kısa neden ve "Yeniden dene" (toplantı değişince zaten denenir).
    private func refusedRow(progress: AssistantUploadProgress) -> some View {
        SettingsRow(icon: "exclamationmark.arrow.circlepath", title: assistantRefusedText(progress: progress)) {
            Text("Bu toplantılar asistanlara açık değil. Toplantı değişince kendiliğinden yeniden denenir.")
        } control: {
            Button("Yeniden dene") { Task { await center.retryRejected() } }
        }
    }

    private var toggleRow: some View {
        SettingsRow(icon: "sparkles", title: Text("Yapay zekâ asistanları toplantı notlarımı okuyabilsin")) {
            Text("Varsayılan olarak kapalı. Açarsan notlarının şifreli bir kopyası (asla ses değil) AB'de saklanır; böylece bağladığın asistanlar onları okuyabilir. Kapatırsan hemen silinir (yedeklerden 30 gün içinde).")
            Text("Sunucularımız bu kopyayı teknik olarak okuyabilir (saklanırken şifreli, uçtan uca değil). Bir asistanın okudukları o sağlayıcının politikalarına tabidir. Başka araçları (e-posta, web) olan asistanlar toplantıda söylenenlerle yönlendirilebilir.")
            if let notice = center.notice {
                NoticeText(notice, severity: .info)
            }
            if let error = center.actionError {
                NoticeText(error, severity: .error)
            }
            if confirmingOff {
                NoticeText("Kapatınca kopya hemen silinir ve bağlı asistanların hepsinin bağlantısı kesilir (yedeklerden 30 gün içinde). Toplantıların cihazlarında kalır.", severity: .attention)
            }
        } control: {
            HStack(spacing: 8) {
                if confirmingOff {
                    Button("Vazgeç") { confirmingOff = false }
                    Button("Kapat ve kopyayı sil", role: .destructive) {
                        confirmingOff = false
                        Task { await center.turnOff() }
                    }
                    .disabled(center.isChanging)
                } else {
                    Toggle("Yapay zekâ asistanları toplantı notlarımı okuyabilsin", isOn: Binding<Bool>(
                        get: { center.isOn },
                        set: { (enabled: Bool) -> Void in
                            if enabled {
                                Task { await center.turnOn() }
                            } else {
                                confirmingOff = true
                            }
                        }
                    ))
                    .settingsToggle()
                    .disabled(center.isChanging)
                }
            }
        }
    }

    private var addressRow: some View {
        SettingsRow(icon: "link", title: Text("Bağlayıcı adresi")) {
            Text(verbatim: hostedAssistantConnectorURL)
                .appMonoFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Text("Asistanında özel bağlayıcı olarak ekle; girişte \(appName) hesabını seçersin.")
        } control: {
            Button(copied ? LocalizedStringKey("Kopyalandı") : LocalizedStringKey("Kopyala")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hostedAssistantConnectorURL, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
    }

    private func stepsRow(title: Text, steps: [Text]) -> some View {
        SettingsStackedRow(icon: "list.number", title: title) {
            EmptyView()
        } content: {
            ForEach(Array(steps.enumerated()), id: \.offset) { (index: Int, step: Text) in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                    step
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .appFont(size: 12, weight: .regular)
            }
        }
    }

    @ViewBuilder
    private var grantRows: some View {
        if center.grants.isEmpty {
            SettingsRow(icon: "person.crop.circle.badge.questionmark", title: Text("Bağlı asistan yok")) {
                Text("Yukarıdaki adımlarla bir asistan bağladığında burada görünür.")
            } control: {
                EmptyView()
            }
        } else {
            ForEach(center.grants) { (grant: HostedAssistantGrant) in
                SettingsRow(icon: grant.verified ? "checkmark.seal" : "exclamationmark.triangle", title: Text(verbatim: assistantGrantDisplayName(grant: grant))) {
                    if !grant.verified {
                        NoticeText("Doğrulanmamış uygulama. Bu bağlantıyı sen kurmadıysan kes.", severity: .attention)
                    }
                    Text("Bağlandı: \(grant.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))")
                    if let lastUsedAt = grant.lastUsedAt {
                        Text("Son kullanım: \(lastUsedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))")
                    }
                    if let heavyReadAt = grant.heavyReadAt {
                        NoticeText("\(heavyReadAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))) civarında bir saatte 100'den fazla toplantı okudu.", severity: .attention)
                    }
                } control: {
                    Button("Bağlantıyı kes", role: .destructive) {
                        Task { await center.disconnect(grant: grant) }
                    }
                }
            }
        }
    }

    private var deviceRow: some View {
        SettingsRow(icon: "laptopcomputer", title: Text("Bu Mac'in toplantıları")) {
            if center.isDeviceExcluded {
                Text("Bu Mac'in toplantıları asistanlara açık değil; diğer cihazlarının toplantıları kopyada kalır.")
            } else {
                deviceStatus
            }
            if let copyMeetings = center.copyMeetings {
                Text("Kopyada toplam \(copyMeetings) toplantı (bütün cihazlarından).")
            }
            if confirmingRemove {
                NoticeText("Bu Mac'in yüklediği toplantılar kopyadan hemen silinir ve bu Mac yüklemeyi bırakır. Toplantıların bu Mac'te kalır.", severity: .attention)
            }
        } control: {
            HStack(spacing: 8) {
                if center.isDeviceExcluded {
                    Button("Yeniden ekle") { center.includeThisDevice() }
                } else if confirmingRemove {
                    Button("Vazgeç") { confirmingRemove = false }
                    Button("Kaldır", role: .destructive) {
                        confirmingRemove = false
                        Task { await center.removeThisDevice() }
                    }
                    .disabled(center.isChanging)
                } else {
                    if case .failed = center.uploadStatus {
                        Button("Yeniden dene") { center.retryNow() }
                    }
                    Button("Bu cihazın toplantılarını kaldır…") { confirmingRemove = true }
                        .disabled(center.isChanging)
                }
            }
        }
    }

    @ViewBuilder
    private var deviceStatus: some View {
        switch center.uploadStatus {
        case .failed(let message, let retryAt):
            NoticeText(message, severity: .attention)
            if let retryAt {
                Text("Kendiliğinden yeniden denenecek: \(retryAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale())))")
            }
        case .idle, .uploading:
            if let progress = center.progress {
                if progress.isComplete {
                    // Kabul edilmeyenler güncel sayılmaz (ayrı satırda).
                    Text("Bu Mac'teki \(progress.uploaded) toplantının kopyası güncel.")
                } else {
                    Text("Yükleniyor, en yeniden eskiye: \(progress.uploaded + progress.rejected) / \(progress.total) toplantı")
                    ProgressView(value: Double(progress.uploaded + progress.rejected), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                }
            } else {
                Text("Toplantıların işlenince ya da düzenlenince yüklenir; silinen toplantı kopyadan da silinir.")
            }
        }
    }
}
