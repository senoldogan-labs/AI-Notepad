import AINotepadCore
import AINotepadUI
import AppKit
import AuthenticationServices
import os
import SwiftUI
import UniformTypeIdentifiers

// Ayarlar › Bağlantılar (Mac): entegrasyonların listesi ve her birinin ayrıntı sayfası. Ortak içerik (adlar,
// açıklamalar, "İçerir" kartları, "nasıl kullanılır" satırları, marka kutusu) App/ConnectionCatalog.swift'te; iPhone'daki
// karşılığı iOS/PhoneConnectionsScreen.swift.

private let channelSettingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Settings")

/// Bağlantılar: üstte (abonelik sürümünde) yapay zekâ asistanı erişimi, altında bölümlere ayrılmış entegrasyon listesi
/// (notların gittiği yerler, görev araçları, yapay zekâ uygulamaları) ve gelişmiş (beceriler, elle MCP yapılandırması).
/// Bir satıra basınca o entegrasyonun sayfası açılır; "‹ Bağlantılar" listeye döner.
struct ConnectionSettings: View {
    let model: AppModel
    @State private var selected: IntegrationKind? = launchIntegration(arguments: CommandLine.arguments)
    @State private var showsAdvanced: Bool = false
    /// Yerel yapay zekâ uygulamalarının durumu (yapılandırma dosyasından okunur; henüz okunmadıysa yok).
    @State private var mcpStatuses: [MCPClient: IntegrationStatus] = [:]
    /// Yapılandırması okunamayan yerel yapay zekâ uygulamalarının nedeni (satırda açıklamanın yerinde gösterilir).
    @State private var mcpProblems: [MCPClient: String] = [:]

    var body: some View {
        Group {
            if let selected {
                IntegrationDetail(model: model, kind: selected) {
                    withAnimation(.smooth(duration: 0.2)) { self.selected = nil }
                }
                .id(selected)
                .transition(.opacity)
            } else {
                list
                    .transition(.opacity)
            }
        }
        .task { await model.loadDestinations() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if HOSTED_EDITION
            // Çevrimiçi asistanlar (Claude, ChatGPT): sunucu sunmuyorsa görünmez (bkz. `HostedAssistantSettingsSection`).
            HostedAssistantSettingsSection()
            #endif
            ForEach(IntegrationGroup.allCases, id: \.self) { (group: IntegrationGroup) in
                ConnectionSectionHeader(title: group.title, subtitle: group.macSubtitle)
                IntegrationListCard(kinds: group.macKinds, status: status(kind:), problem: problem(kind:)) { (kind: IntegrationKind) -> Void in
                    withAnimation(.smooth(duration: 0.2)) { selected = kind }
                }
            }
            Button {
                withAnimation(.smooth(duration: 0.25)) { showsAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .appFont(size: 11, weight: .semibold)
                        .rotationEffect(.degrees(showsAdvanced ? 90 : 0))
                    Text("Gelişmiş: beceriler ve elle MCP yapılandırması").appFont(size: 12, weight: .semibold)
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .padding(.top, 30)
            if showsAdvanced {
                VStack(alignment: .leading, spacing: 0) {
                    SkillSettings(model: model)
                    MCPSettings()
                }
                .transition(.opacity)
            }
        }
        .task { refreshMCPStatuses() }
    }

    /// Listedeki satırın durumu.
    private func status(kind: IntegrationKind) -> IntegrationStatus {
        if let destination = kind.destinationKind {
            return destinationIntegrationStatus(kind: destination, destinations: model.destinations)
        }
        if let service = kind.trackerService {
            return model.taskTrackers.contains { $0.service == service } ? .connected(count: 1) : .notConnected
        }
        if let client = kind.mcpClient {
            return mcpStatuses[client] ?? .notConnected
        }
        switch kind {
        case .appleNotes:
            return model.appleNotesAutoSend ? .connected(count: 1) : .notConnected
        case .folder:
            return model.markdownFolder.isEmpty ? .notConnected : .connected(count: 1)
        case .slack, .teams, .discord, .notion, .zoom, .webhook, .linear, .jira, .claudeDesktop, .cursor, .vsCode:
            return .notConnected
        }
    }

    /// Satırda açıklamanın yerinde gösterilen sorun (yapılandırması okunamayan uygulamanın nedeni); yoksa nil.
    private func problem(kind: IntegrationKind) -> String? {
        kind.mcpClient.flatMap { mcpProblems[$0] }
    }

    /// Yerel yapay zekâ uygulamalarının yapılandırmasını okur. Okunamayan uygulamanın satırında uyarı rozeti
    /// ("Okunamadı") ve açıklamanın yerinde nedeni görünür.
    private func refreshMCPStatuses() {
        var statuses: [MCPClient: IntegrationStatus] = [:]
        var problems: [MCPClient: String] = [:]
        for client in MCPClient.allCases {
            do {
                statuses[client] = try mcpClientStatus(client: client)
            } catch {
                channelSettingsLogger.warning("Yapay zekâ uygulamasının yapılandırması okunamadı, uygulama: \(client.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                statuses[client] = .unreadable
                problems[client] = userFacingMessage(error: error)
            }
        }
        mcpStatuses = statuses
        mcpProblems = problems
    }
}

private extension IntegrationGroup {
    /// Mac'teki bölüm başlığının altındaki tek satır.
    var macSubtitle: LocalizedStringKey {
        switch self {
        case .destinations: "Not hazır olunca kanallara, Notion'a, Apple Notlar'a ya da klasöre gider."
        case .taskTools: "Görevleri tek tıkla Linear ya da Jira'da iş olarak aç."
        case .aiApps: "Claude, Cursor ve VS Code toplantılarını arayıp okuyabilir."
        }
    }
}

/// Bağlantı bölümünün başlığı ve tek satır açıklaması.
private struct ConnectionSectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .appFont(size: 12, weight: .semibold)
                .foregroundStyle(Theme.muted)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 4)
        .padding(.top, 26)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bağlantı kartı: beyaz yüzey, ince çerçeve; satırlar arasında metnin hizasından başlayan ince çizgi.
private struct ConnectionCardSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if #available(macOS 15.0, *) {
            Group(subviews: content) { (rows: SubviewsCollection) in
                card(rows: rows)
            }
        } else {
            LegacySubviews(of: content) { (rows: _VariadicView.Children) in
                card(rows: rows)
            }
        }
    }

    @ViewBuilder
    private func card<Rows: ViewRows>(rows: Rows) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { (item: (offset: Int, element: Rows.Element)) in
                    if item.offset > 0 {
                        SettingsDivider().padding(.leading, 62)
                    }
                    item.element
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.line))
        }
    }
}

/// Bölümün entegrasyonları tek kartta, satır satır.
private struct IntegrationListCard: View {
    let kinds: [IntegrationKind]
    let status: (IntegrationKind) -> IntegrationStatus
    let problem: (IntegrationKind) -> String?
    let open: (IntegrationKind) -> Void

    var body: some View {
        ConnectionCardSurface {
            ForEach(kinds) { (kind: IntegrationKind) in
                IntegrationListRow(kind: kind, status: status(kind), problem: problem(kind)) { open(kind) }
            }
        }
    }
}

/// Liste satırı: marka kutusu, ad, tek satır açıklama (sorun varsa onun yerine nedeni), durum rozeti ve sağda ok;
/// bütün satır basılabilir.
private struct IntegrationListRow: View {
    let kind: IntegrationKind
    let status: IntegrationStatus
    let problem: String?
    let action: () -> Void
    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IntegrationTile(style: kind.tileStyle, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: kind.name)
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    if let problem {
                        NoticeText(problem, severity: .attention)
                            .appFont(size: 12, weight: .regular)
                            .lineLimit(2)
                    } else {
                        Text(kind.summary)
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                IntegrationStatusPill(status: status)
                Image(systemName: "chevron.right")
                    .appFont(size: 11, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Theme.soft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { (hovering: Bool) in isHovering = hovering }
        .accessibilityElement(children: .combine)
    }
}

/// Entegrasyon sayfasının düzeni: geri dönüş, büyük marka kutusu, ad, durum ve açıklama, sağda ana eylem; altında
/// bağlantının kendi durumu (bağlı hedefler, ayarlar, kurulum adımı), "İçerir" kartları ve "<Ad> nasıl kullanılır".
private struct IntegrationPage<Primary: View, Status: View>: View {
    let kind: IntegrationKind
    let status: IntegrationStatus
    /// Giriş ya da gönderim sürerken geri dönülmez (sonucu sayfada görünür).
    let isBackDisabled: Bool
    let onBack: () -> Void
    let primary: Primary
    let state: Status
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    init(
        kind: IntegrationKind, status: IntegrationStatus, isBackDisabled: Bool, onBack: @escaping () -> Void,
        @ViewBuilder primary: () -> Primary, @ViewBuilder state: () -> Status
    ) {
        self.kind = kind
        self.status = status
        self.isBackDisabled = isBackDisabled
        self.onBack = onBack
        self.primary = primary()
        self.state = state()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").appFont(size: 11, weight: .semibold)
                    Text("Bağlantılar").appFont(size: 12, weight: .semibold)
                }
                .foregroundStyle(Theme.muted)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .disabled(isBackDisabled)
            .padding(.top, 22)
            HStack(alignment: .center, spacing: 16) {
                IntegrationTile(style: kind.tileStyle, size: 60)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: kind.name)
                            .appFont(size: 20, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                        IntegrationStatusPill(status: status)
                    }
                    Text(kind.summary)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                primary
                    .fixedSize()
            }
            .padding(.top, 16)
            VStack(alignment: .leading, spacing: 10) {
                state
            }
            .padding(.top, 18)
            pageSectionTitle(Text("İçerir"))
            // İki ya da dört kart iki sütunda (üçlü satırda tek kart kalmasın), diğerleri üç sütunda.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: kind.features.count % 2 == 0 ? 2 : 3), spacing: 12) {
                ForEach(kind.features, id: \.self) { (feature: IntegrationFeature) in
                    featureCard(feature: feature)
                }
            }
            pageSectionTitle(Text("\(kind.name) nasıl kullanılır"))
            ConnectionCardSurface {
                ForEach(kind.privacy, id: \.self) { (point: IntegrationPrivacyPoint) in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: point.symbol)
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.muted)
                            .frame(width: 34)
                            .accessibilityHidden(true)
                        Text(point.text)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
        }
    }

    private func pageSectionTitle(_ title: Text) -> some View {
        title
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(Theme.muted)
            .padding(.leading, 4)
            .padding(.top, 26)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func featureCard(feature: IntegrationFeature) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return VStack(alignment: .leading, spacing: 8) {
            Image(systemName: feature.symbol)
                .appFont(size: 14, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                .frame(width: 30, height: 30)
                .background(appearance.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            Text(feature.title)
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(Theme.ink)
            Text(feature.detail)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.line))
    }
}

/// Entegrasyonun sayfası: türüne göre kurulum ve ayarları.
private struct IntegrationDetail: View {
    let model: AppModel
    let kind: IntegrationKind
    let onBack: () -> Void

    var body: some View {
        if let destination = kind.destinationKind {
            DestinationDetail(model: model, kind: kind, channelKind: destination, onBack: onBack)
        } else if let service = kind.trackerService {
            TrackerDetail(model: model, kind: kind, service: service, onBack: onBack)
        } else if let client = kind.mcpClient {
            MCPClientDetail(kind: kind, client: client, onBack: onBack)
        } else if kind == .appleNotes {
            AppleNotesDetail(model: model, onBack: onBack)
        } else {
            FolderDetail(model: model, onBack: onBack)
        }
    }
}

/// "Bağlı" durumu (kurulum sonucu): mürekkep renginde onay simgesi ve metin.
private struct ConnectedLabel: View {
    let text: Text

    var body: some View {
        Label {
            text
        } icon: {
            Image(systemName: "checkmark.circle.fill")
        }
        .foregroundStyle(Theme.ink)
    }
}

/// Kanal kurulumunun durumu.
private enum ChannelSetup: Equatable {
    case idle
    /// Tarayıcıda giriş bekleniyor.
    case signingIn(String)
    /// Giriş tamam; yazılacak kanal seçiliyor (`replacing`: kanalı değiştirilen hedef).
    case choosing(ChannelSignIn, [ChannelOption], replacing: String?)
    /// Webhook adresi yapıştırılıyor.
    case pasting
    /// Zoom adresi ve doğrulama anahtarı yapıştırılıyor.
    case pastingZoom
    case working(String)
    case done(String)
    case failed(String)
}

/// Kurulum sonucunun kendiliğinden kaybolma süresi: başarı 3,5 sn, hata 5 sn; diğer durumlar kalır. Saf fonksiyondur.
private func channelSetupFadeDelay(setup: ChannelSetup) -> Duration? {
    switch setup {
    case .done: .seconds(3.5)
    case .failed: .seconds(5)
    case .idle, .signingIn, .choosing, .pasting, .pastingZoom, .working: nil
    }
}

/// Not hedefinin sayfası (Slack, Teams, Discord, Notion, Zoom, webhook): bu türden bağlı hedefler (her birinin
/// kendiliğinden gönderimi, dene, kanalı değiştir, yeniden bağlan, kaldır), "Bağlan" ya da "Ekle" ve kurulum adımı.
/// Aynı türden birden çok hedef bağlı olabilir.
private struct DestinationDetail: View {
    let model: AppModel
    let kind: IntegrationKind
    let channelKind: DestinationKind
    let onBack: () -> Void
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var setup: ChannelSetup = .idle
    /// Tarayıcıda süren Notion girişi: "Vazgeç" bunu iptal eder (yerel dönüş dinleyicisi kapanır).
    @State private var notionSignIn: Task<Void, Never>?
    @State private var selectedChannelID: String = ""
    @State private var manualAddress: String = ""
    @State private var zoomToken: String = ""

    private var connected: [NoteDestination] {
        model.destinations.filter { destinationKind(destination: $0) == channelKind }
    }

    var body: some View {
        IntegrationPage(
            kind: kind, status: destinationIntegrationStatus(kind: channelKind, destinations: model.destinations),
            isBackDisabled: isBusy, onBack: onBack
        ) {
            if connected.isEmpty {
                Button(channelKind.channelService == nil && channelKind != .notion ? "Yapıştır" : "Bağlan") { start() }
                    .buttonStyle(.pillPrimary)
                    .disabled(isBusy)
            } else {
                Button("Ekle", systemImage: "plus") { start() }
                    .buttonStyle(.pill)
                    .disabled(isBusy)
                    .hoverHint("Başka bir kanal ya da hesap ekle", alignment: .trailing, edge: .bottom)
            }
        } state: {
            setupStatus
            if !connected.isEmpty {
                ConnectionCardSurface {
                    ForEach(connected) { (destination: NoteDestination) in
                        destinationRow(destination: destination)
                    }
                }
            }
        }
        .task(id: setup) { await fadeSetupResult(shown: setup) }
    }

    /// Bağlı hedef: marka kutusu, ad ve kanal (ya da "yeniden bağlan" uyarısı), otomatik gönderim; dene, kanalı
    /// değiştir ve kaldır ⋯ menüsünde.
    private func destinationRow(destination: NoteDestination) -> some View {
        HStack(spacing: 12) {
            IntegrationTile(style: kind.tileStyle, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: destinationName(destination: destination))
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                if destination.needsReconnect {
                    NoticeText("Oturumun süresi doldu; yeniden bağlan", severity: .attention)
                        .appFont(size: 12, weight: .regular)
                } else {
                    Text(verbatim: destinationDetail(destination: destination))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if destination.needsReconnect {
                Button("Yeniden bağlan") {
                    switch destination.target {
                    case .account(let connection): Task { await signIn(service: connection.service, replacing: destination.id) }
                    case .notion: notionSignIn = Task { await reconnectNotion(destinationID: destination.id) }
                    case .webhook, .discordSignIn: return
                    }
                }
                .buttonStyle(.pillPrimary)
                .controlSize(.small)
                .disabled(isBusy)
            }
            Text("Otomatik gönder")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
            Toggle("Otomatik gönder", isOn: Binding<Bool>(
                get: { destination.autoSend },
                set: { (enabled: Bool) -> Void in Task { await model.setAutoSend(destinationID: destination.id, enabled: enabled) } }
            ))
            .settingsToggle()
            .hoverHint("Not hazır olunca kendiliğinden gönder", alignment: .trailing, edge: .bottom)
            Menu {
                Button("Deneme mesajı gönder", systemImage: "paperplane") { Task { await test(destinationID: destination.id) } }
                    .disabled(isBusy)
                if case .account(let connection) = destination.target, !destination.needsReconnect {
                    Button("Kanalı değiştir", systemImage: "arrow.left.arrow.right") {
                        Task { await changeChannel(destinationID: destination.id, service: connection.service) }
                    }
                    .disabled(isBusy)
                }
                Divider()
                Button("Kaldır", systemImage: "trash", role: .destructive) { Task { await model.removeDestination(id: destination.id) } }
            } label: {
                Image(systemName: "ellipsis").frame(width: 16, height: 16)
            }
            .menuStyle(.button)
            .buttonStyle(.hoverCapsule)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Diğer işlemler")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch setup {
        case .idle:
            EmptyView()
        case .signingIn(let name):
            statusPanel {
                ProgressView().controlSize(.small)
                Text("Açılan pencerede \(name) hesabınla giriş yap ve izin ver.").appFont(size: 13, weight: .regular)
                Spacer()
                if let notionSignIn {
                    Button("Vazgeç") { notionSignIn.cancel() }
                }
            }
        case .choosing(let signIn, let options, let replacing):
            statusPanel {
                Text("Notlar hangi kanala gitsin?").appFont(size: 13, weight: .medium)
                // Değer de uygulamanın yazı tipinde (sistemin açılır düğmesi sistem yazısında çiziyordu).
                SettingsMenu(selection: $selectedChannelID, options: [("", Text("Kanal seç"))] + options.map { (option: ChannelOption) -> (String, Text) in
                    (option.id, Text(verbatim: option.name))
                })
                .frame(maxWidth: 280, alignment: .leading)
                .accessibilityLabel("Kanal")
                Spacer()
                Button("Vazgeç") { setup = .idle }.buttonStyle(.hoverPlain).foregroundStyle(Theme.muted)
                Button("Bağla") { choose(signIn: signIn, options: options, replacing: replacing) }
                    .buttonStyle(.pillPrimary)
                    .disabled(!options.contains { $0.id == selectedChannelID })
            }
        case .pasting:
            statusPanel {
                TextField("Webhook adresi", text: $manualAddress, prompt: Text(verbatim: "https://hooks.zapier.com/…"))
                    .textFieldStyle(.roundedBorder)
                Button("Vazgeç") { setup = .idle }.buttonStyle(.hoverPlain).foregroundStyle(Theme.muted)
                Button("Bağla") { connectWebhook() }
                    .buttonStyle(.pillPrimary)
                    .disabled(manualAddress.isEmpty)
            }
        case .pastingZoom:
            statusPanel {
                TextField("Zoom adresi", text: $manualAddress, prompt: Text(verbatim: "https://integrations.zoom.us/chat/webhooks/incomingwebhook/…"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Doğrulama anahtarı", text: $zoomToken, prompt: Text("Doğrulama anahtarı"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Button("Vazgeç") { setup = .idle }.buttonStyle(.hoverPlain).foregroundStyle(Theme.muted)
                Button("Bağla") { connectZoom() }
                    .buttonStyle(.pillPrimary)
                    .disabled(manualAddress.isEmpty || zoomToken.isEmpty)
            }
        case .working(let message):
            // Gönderim sürerken sakin bir nabız; yalnızca bu durumda çizilir, boştayken hiçbir şey kıpırdamaz.
            Label {
                Text(message)
            } icon: {
                Image(systemName: "paperplane").symbolEffect(.pulse)
            }
            .appFont(size: 13, weight: .regular)
        case .done(let message):
            ConnectedLabel(text: Text(message))
                .appFont(size: 13, weight: .medium)
                .transition(.opacity)
        case .failed(let message):
            NoticeText(message, severity: .error)
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    /// Sonuç mesajı (başarı ya da hata) bir süre sonra kendiliğinden yumuşakça kaybolur. Daha yeni bir durum gelince
    /// görev iptal olur, zamanlayıcı yeniden başlar.
    private func fadeSetupResult(shown: ChannelSetup) async {
        guard let delay = channelSetupFadeDelay(setup: shown) else {
            return
        }
        do {
            try await Task.sleep(for: delay)
        } catch {
            // Yalnızca iptal: yeni bir durum geldi, eski mesajın zamanlayıcısı bir şey silmez.
            return
        }
        guard setup == shown else {
            return
        }
        withAnimation(.easeOut(duration: 0.4)) { setup = .idle }
    }

    private func statusPanel(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10) {
            content()
        }
        .padding(12)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Giriş, kanal seçimi ya da gönderim sürüyor: ikinci bir kurulum başlamasın, sayfadan çıkılmasın.
    private var isBusy: Bool {
        switch setup {
        case .signingIn, .working, .choosing: true
        case .idle, .pasting, .pastingZoom, .done, .failed: false
        }
    }

    private func start() {
        manualAddress = ""
        zoomToken = ""
        switch channelKind {
        case .zoom:
            setup = .pastingZoom
        case .webhook:
            setup = .pasting
        case .notion:
            notionSignIn = Task { await connectNotion() }
        case .slack, .teams, .discord:
            if let service = channelKind.channelService {
                Task { await signIn(service: service, replacing: nil) }
            }
        }
    }

    /// Tarayıcıda giriş (PKCE); Discord'da kanal orada seçilir ve eklenir, Slack ve Teams'te kanal listesi gelir.
    /// `replacing` verilirse (yeniden bağlan) yeni bağlantı o hedefin yerine geçer. Pencere kapatılırsa vazgeçilir.
    private func signIn(service: ChannelService, replacing: String?) async {
        let clientID: String = channelClientID(service: service)
        guard !clientID.isEmpty else {
            setup = .failed(userFacingMessage(error: ChannelAuthError.notConfigured(service: service)))
            return
        }
        let pkce: PKCEPair = makePKCEPair()
        let state: String = makeOAuthState()
        setup = .signingIn(service.displayName)
        do {
            let authorizeURL: URL = channelAuthorizeURL(service: service, clientID: clientID, pkce: pkce, state: state)
            let callback: URL
            if #available(macOS 14.4, *) {
                callback = try await webAuthenticationSession.authenticate(
                    using: authorizeURL, callback: .customScheme(oauthCallbackScheme), preferredBrowserSession: nil, additionalHeaderFields: [:]
                )
            } else {
                // macOS 14.2–14.3: aynı tarayıcı girişi, geri dönüş adresi şemasıyla.
                callback = try await webAuthenticationSession.authenticate(
                    using: authorizeURL, callbackURLScheme: oauthCallbackScheme, preferredBrowserSession: nil
                )
            }
            let code: String = try oauthCallbackCode(service: service, url: callback, expectedState: state)
            switch service {
            case .discord:
                let url: URL = try await exchangeDiscordCode(code: code, verifier: pkce.verifier, clientID: clientID)
                // Girişle oluşturulan webhook: hedef kaldırılınca Discord'da da silinir (yapıştırılan adresler silinmez).
                let destination: NoteDestination = try await model.addDestination(target: .discordSignIn(url))
                await test(destinationID: destination.id)
            case .slack:
                await showChannels(signIn: try await exchangeSlackCode(code: code, verifier: pkce.verifier, clientID: clientID), replacing: replacing)
            case .teams:
                await showChannels(signIn: try await exchangeTeamsCode(code: code, verifier: pkce.verifier, clientID: clientID), replacing: replacing)
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            setup = .idle
        } catch {
            channelSettingsLogger.error("Kanal girişi başarısız, servis: \(service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func showChannels(signIn: ChannelSignIn, replacing: String?) async {
        do {
            let options: [ChannelOption] = try await listChannels(signIn: signIn)
            // Kanal önceden seçilmez: notlar yanlışlıkla herkesin gördüğü #genel'e gitmesin.
            selectedChannelID = ""
            setup = .choosing(signIn, options, replacing: replacing)
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    /// Seçilen kanalla bağlantıyı yeni hedef olarak ekler (ya da değiştirilen hedefin yerine koyar) ve dener.
    private func choose(signIn: ChannelSignIn, options: [ChannelOption], replacing: String?) {
        guard let option = options.first(where: { $0.id == selectedChannelID }) else {
            return
        }
        let connection: ChannelConnection = ChannelConnection(service: signIn.service, tokens: signIn.tokens, workspace: signIn.workspace, channel: option)
        Task {
            do {
                if let replacing {
                    try await model.replaceDestinationTarget(id: replacing, target: .account(connection))
                    await test(destinationID: replacing)
                } else {
                    let destination: NoteDestination = try await model.addDestination(target: .account(connection))
                    await test(destinationID: destination.id)
                }
            } catch {
                setup = .failed(userFacingMessage(error: error))
            }
        }
    }

    /// Kayıtlı oturumla kanalları yeniden listeler (yeniden giriş gerekmez).
    private func changeChannel(destinationID: String, service: ChannelService) async {
        setup = .signingIn(service.displayName)
        do {
            let result: (signIn: ChannelSignIn, options: [ChannelOption]) = try await model.channelOptions(destinationID: destinationID)
            selectedChannelID = ""
            setup = .choosing(result.signIn, result.options, replacing: destinationID)
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func connectNotion() async {
        setup = .signingIn("Notion")
        defer { notionSignIn = nil }
        do {
            try await model.connectNotion()
            setup = .done(String(localized: "Notion bağlandı; notlar özel sayfalarına yeni sayfa olarak gider."))
        } catch is CancellationError {
            setup = .idle
        } catch {
            channelSettingsLogger.error("Notion girişi başarısız, hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
        }
    }

    /// Notion oturumu bitti: aynı hedefin bağlantısı yenilenir (ayarı ve gönderim geçmişi korunur).
    private func reconnectNotion(destinationID: String) async {
        setup = .signingIn("Notion")
        defer { notionSignIn = nil }
        do {
            try await model.reconnectNotion(destinationID: destinationID)
            setup = .done(String(localized: "Notion yeniden bağlandı."))
        } catch is CancellationError {
            setup = .idle
        } catch {
            channelSettingsLogger.error("Notion yeniden bağlanamadı, hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func connectWebhook() {
        do {
            addWebhook(url: try webhookURL(text: manualAddress))
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func connectZoom() {
        do {
            addWebhook(url: try zoomWebhookURL(address: manualAddress, token: zoomToken))
            zoomToken = ""
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func addWebhook(url: URL) {
        Task {
            do {
                let destination: NoteDestination = try await model.addDestination(target: .webhook(url))
                await test(destinationID: destination.id)
            } catch {
                setup = .failed(userFacingMessage(error: error))
            }
        }
    }

    private func test(destinationID: String) async {
        let name: String = model.destinations.first { $0.id == destinationID }.map { destinationName(destination: $0) } ?? ""
        setup = .working(String(localized: "Deneme mesajı gönderiliyor…"))
        if let error = await model.sendTestNote(destinationID: destinationID) {
            setup = .failed(error)
        } else {
            setup = .done(String(localized: "\(name) bağlandı; deneme mesajı gönderildi."))
        }
    }
}

/// Apple Notlar'ın sayfası: kendiliğinden gönderim anahtarı. Açılınca izin penceresi çıksın ve doğru çalıştığı görülsün
/// diye son not gönderilir; gönderilemezse ayar yeniden kapanır.
private struct AppleNotesDetail: View {
    let model: AppModel
    let onBack: () -> Void
    @State private var notesStatus: String?

    var body: some View {
        IntegrationPage(
            kind: .appleNotes, status: model.appleNotesAutoSend ? .connected(count: 1) : .notConnected, isBackDisabled: false, onBack: onBack
        ) {
            if !model.appleNotesAutoSend {
                Button("Bağlan") { setNotesAutoSend(enabled: true) }
                    .buttonStyle(.pillPrimary)
            }
        } state: {
            if model.appleNotesAutoSend {
                ConnectionCardSurface {
                    settingRow(title: Text("Apple Notlar'a gönder"), detail: notesStatus.map { Text(verbatim: $0) }) {
                        Toggle("Apple Notlar'a gönder", isOn: Binding<Bool>(
                            get: { model.appleNotesAutoSend },
                            set: { (enabled: Bool) -> Void in setNotesAutoSend(enabled: enabled) }
                        ))
                        .settingsToggle()
                    }
                }
            } else if let notesStatus {
                NoticeText(notesStatus, severity: .error)
                    .appFont(size: 13, weight: .regular)
            }
        }
    }

    private func setNotesAutoSend(enabled: Bool) {
        model.setAppleNotesAutoSend(enabled: enabled)
        guard enabled, let latest = model.meetings.first(where: { $0.note != nil }) else {
            return
        }
        Task {
            let error: String? = await model.sendToAppleNotes(meetingID: latest.id)
            notesStatus = error ?? String(localized: "Son not Notlar'a yazıldı.")
            if error != nil {
                model.setAppleNotesAutoSend(enabled: false)
            }
        }
    }
}

/// Klasörün sayfası (Obsidian, iCloud): seçilen klasöre not Markdown dosyası olarak yazılır; "Klasöre yaz" açıkken
/// kendiliğinden.
private struct FolderDetail: View {
    let model: AppModel
    let onBack: () -> Void
    @State private var folderStatus: String?

    var body: some View {
        let markdownFolder: String = model.markdownFolder
        IntegrationPage(
            kind: .folder, status: markdownFolder.isEmpty ? .notConnected : .connected(count: 1), isBackDisabled: false, onBack: onBack
        ) {
            if markdownFolder.isEmpty {
                Button("Seç…") { chooseFolder() }
                    .buttonStyle(.pillPrimary)
            } else {
                Button("Değiştir") { chooseFolder() }
                    .buttonStyle(.pill)
            }
        } state: {
            if !markdownFolder.isEmpty {
                ConnectionCardSurface {
                    settingRow(title: Text(verbatim: (markdownFolder as NSString).abbreviatingWithTildeInPath), detail: folderStatus.map { Text(verbatim: $0) }) {
                        HStack(spacing: 8) {
                            Text("Klasöre yaz")
                                .appFont(size: 12, weight: .regular)
                                .foregroundStyle(Theme.muted)
                            Toggle("Klasöre yaz", isOn: Binding<Bool>(
                                get: { model.markdownAutoExport },
                                set: { (enabled: Bool) -> Void in model.setMarkdownAutoExport(enabled: enabled) }
                            ))
                            .settingsToggle()
                        }
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        guard let url = pickMarkdownFolder() else {
            return
        }
        model.setMarkdownFolder(path: url.path)
        model.setMarkdownAutoExport(enabled: true)
        // Notu olan toplantı yoksa (yeni kurulum, notlar hâlâ hazırlanıyor) yazılan bir şey yoktur: öyle söylenir.
        guard let latest = model.meetings.first(where: { $0.note != nil }) else {
            folderStatus = String(localized: "Klasör seçildi; notlar hazır olunca buraya yazılır.")
            return
        }
        folderStatus = model.exportToFolder(meetingID: latest.id) ?? String(localized: "Son not klasöre yazıldı.")
    }
}

/// Sayfadaki ayar satırı: başlık, isteğe bağlı soluk açıklama ve sağda denetim.
@MainActor
private func settingRow(title: Text, detail: Text?, @ViewBuilder control: () -> some View) -> some View {
    HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
            title
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                detail
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        Spacer(minLength: 8)
        control()
            .fixedSize()
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
}

/// Görev aracının sayfası (Linear, Jira): tek tıkla bağlanma (MCP, tarayıcıda izin; API anahtarı gerekmez), görevlerin
/// açılacağı takım ya da proje, kaldırma.
private struct TrackerDetail: View {
    let model: AppModel
    let kind: IntegrationKind
    let service: MCPService
    let onBack: () -> Void
    @State private var status: String?
    @State private var isConnecting: Bool = false
    /// Tarayıcıda süren giriş: "Vazgeç" bunu iptal eder.
    @State private var signIn: Task<Void, Never>?

    var body: some View {
        let tracker: TaskTracker? = model.taskTrackers.first { $0.service == service }
        IntegrationPage(kind: kind, status: tracker == nil ? .notConnected : .connected(count: 1), isBackDisabled: isConnecting, onBack: onBack) {
            if tracker == nil {
                HStack(spacing: 6) {
                    if isConnecting, let signIn {
                        Button("Vazgeç") { signIn.cancel() }
                            .buttonStyle(.hoverPlain)
                            .foregroundStyle(Theme.muted)
                    }
                    Button(isConnecting ? "İzin bekleniyor…" : "Bağlan") { connect() }
                        .buttonStyle(.pillPrimary)
                        .disabled(isConnecting)
                }
            }
        } state: {
            if let tracker {
                ConnectionCardSurface {
                    settingRow(title: Text(service == .linear ? "Takımındaki işler" : "Jira projesindeki işler"), detail: nil) {
                        HStack(spacing: 6) {
                            TrackerTargetPicker(model: model, tracker: tracker)
                            Menu {
                                Button("Kaldır", systemImage: "trash", role: .destructive) { Task { await model.removeTracker(id: tracker.id) } }
                            } label: {
                                Image(systemName: "ellipsis").frame(width: 16, height: 16)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.hoverCapsule)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .accessibilityLabel("Diğer işlemler")
                        }
                    }
                }
            }
            if let status {
                Text(status)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() {
        isConnecting = true
        status = nil
        signIn = Task {
            defer {
                isConnecting = false
                signIn = nil
            }
            do {
                try await model.connectTracker(service: service)
                status = String(localized: "\(service.displayName) bağlandı.")
            } catch is CancellationError {
                status = nil
            } catch {
                status = userFacingMessage(error: error)
            }
        }
    }
}

/// Yapılandırmaya yazılacak uygulama yolu; uygulama geçici konumdan çalışıyorsa hata.
private func mcpAppExecutablePath() throws -> String {
    guard let path = Bundle.main.executablePath else {
        throw MCPConfigError.writeFailed(path: Bundle.main.bundlePath, reason: "uygulamanın çalıştırılabilir dosyası bulunamadı")
    }
    return try mcpExecutablePath(executablePath: path)
}

/// Yerel yapay zekâ uygulamasının bu Mac'teki durumu (yüklü değil, bağlı ya da değil); yapılandırması okunamazsa hata.
private func mcpClientStatus(client: MCPClient) throws -> IntegrationStatus {
    guard FileManager.default.fileExists(atPath: client.applicationPath) else {
        return .notInstalled
    }
    let config: JSONValue = try readMCPConfig(file: client.configFile(home: FileManager.default.homeDirectoryForCurrentUser))
    let connected: Bool = isMCPServerConnected(config: config, client: client, executablePath: try mcpAppExecutablePath(), serverName: mcpServerName(appName: appName))
    return connected ? .connected(count: 1) : .notConnected
}

/// Bir yapay zekâ uygulamasının sayfası (Claude, Cursor, VS Code): yüklüyse "Bağla" ya da (bağlıysa) ⋯ › "Kaldır".
/// Bağlayınca uygulamanın yapılandırma dosyasına bu uygulama eklenir (diğer ayarlar korunur); uygulama yeniden açılınca
/// görünür.
private struct MCPClientDetail: View {
    let kind: IntegrationKind
    let client: MCPClient
    let onBack: () -> Void
    @State private var status: IntegrationStatus = .notConnected
    @State private var errorMessage: String?
    @State private var justConnected: Bool = false

    /// Uygulamanın MCP yapılandırma dosyası.
    private var configFile: URL {
        client.configFile(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    var body: some View {
        IntegrationPage(kind: kind, status: status, isBackDisabled: false, onBack: onBack) {
            switch status {
            case .notInstalled:
                EmptyView()
            case .unreadable:
                // Bozuk yapılandırma üstüne yazılmaz (kullanıcının diğer ayarları kaybolmasın): dosya gösterilir,
                // düzeltilince yeniden okunur.
                HStack(spacing: 8) {
                    if FileManager.default.fileExists(atPath: configFile.path) {
                        Button("Finder'da göster") { NSWorkspace.shared.activateFileViewerSelecting([configFile]) }
                            .buttonStyle(.pill)
                    }
                    Button("Yeniden dene") { refresh() }
                        .buttonStyle(.pillPrimary)
                }
            case .connected, .needsReconnect:
                Menu {
                    Button("Kaldır", systemImage: "trash", role: .destructive) { disconnect() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 16, height: 16)
                }
                .menuStyle(.button)
                .buttonStyle(.hoverCapsule)
                .menuIndicator(.hidden)
                .accessibilityLabel("Diğer işlemler")
            case .notConnected:
                Button("Bağla") { connect() }
                    .buttonStyle(.pillPrimary)
            }
        } state: {
            Group {
                if status == .notInstalled {
                    Text("Bu Mac'te yüklü değil").foregroundStyle(Theme.muted)
                } else if let errorMessage {
                    NoticeText(errorMessage, severity: .error)
                } else if justConnected {
                    ConnectedLabel(text: Text("Bağlandı — uygulamayı yeniden aç"))
                }
            }
            .appFont(size: 13, weight: .regular)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.smooth(duration: 0.2), value: status)
        .task { refresh() }
    }

    private func refresh() {
        do {
            status = try mcpClientStatus(client: client)
            errorMessage = nil
        } catch {
            status = .unreadable
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func connect() {
        do {
            try connectMCPClient(client: client, executablePath: try mcpAppExecutablePath(), serverName: mcpServerName(appName: appName), home: FileManager.default.homeDirectoryForCurrentUser)
            justConnected = true
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }

    private func disconnect() {
        do {
            try disconnectMCPClient(client: client, serverName: mcpServerName(appName: appName), home: FileManager.default.homeDirectoryForCurrentUser)
            justConnected = false
            refresh()
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

/// Notların Markdown olarak yazılacağı klasörü sorar (Ayarlar › Bağlantılar ve toplantıdaki "Klasöre Markdown kaydet");
/// vazgeçilirse nil.
@MainActor
func pickMarkdownFolder() -> URL? {
    let panel: NSOpenPanel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = String(localized: "Seç")
    panel.message = String(localized: "Notların Markdown olarak yazılacağı klasör (ör. Obsidian kasası)")
    guard panel.runModal() == .OK, let url = panel.url else {
        return nil
    }
    return url
}

/// Görev aracının hedefi (Linear takımı, Jira projesi): araçtaki gerçek seçenekler menüde. Tek seçenek varsa yalnızca
/// adı görünür (seçilecek bir şey yok); hedef boşsa ilk seçenek kullanılır ve öyle gösterilir. Seçenekler okunamazsa
/// neden ve "Yeniden dene" görünür.
private struct TrackerTargetPicker: View {
    let model: AppModel
    let tracker: TaskTracker
    @State private var options: [String]?
    @State private var errorMessage: String?

    var body: some View {
        let noun: LocalizedStringKey = tracker.service == .atlassian ? "Proje" : "Takım"
        let current: String? = tracker.target.isEmpty ? options?.first : tracker.target
        Group {
            if let options, options.count > 1 {
                Menu {
                    ForEach(options, id: \.self) { (name: String) in
                        Button {
                            Task { await model.setTrackerTarget(id: tracker.id, target: name) }
                        } label: {
                            if name == current {
                                Label(name, systemImage: "checkmark")
                            } else {
                                Text(verbatim: name)
                            }
                        }
                    }
                } label: {
                    targetLabel(noun: noun, name: current ?? "")
                }
                .menuStyle(.button)
                .buttonStyle(.pill)
                .controlSize(.small)
                .fixedSize()
            } else if let current {
                targetLabel(noun: noun, name: current)
                    .foregroundStyle(Theme.muted)
            } else if let errorMessage {
                Button("Yeniden dene", systemImage: "arrow.clockwise") { Task { await load() } }
                    .controlSize(.small)
                    .hoverHint(verbatim: errorMessage, alignment: .trailing, edge: .bottom)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: tracker.id) { await load() }
    }

    private func targetLabel(noun: LocalizedStringKey, name: String) -> some View {
        HStack(spacing: 4) {
            Text(noun).foregroundStyle(Theme.muted)
            Text(verbatim: name).lineLimit(1)
        }
        .appFont(size: 12, weight: .medium)
    }

    private func load() async {
        errorMessage = nil
        do {
            options = try await model.trackerTargets(id: tracker.id)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}

/// Agent Skills: Claude ve diğer araçlar için yazılmış becerileri (`SKILL.md`) Sor'da "/" tarifi olarak kullanma.
private struct SkillSettings: View {
    let model: AppModel
    @State private var status: String?

    var body: some View {
        SettingsGroup(title: Text("Beceriler (Agent Skills)")) {
            SettingsRow(icon: "square.and.arrow.down", title: Text("SKILL.md içe aktar")) {
                Text("Claude ve diğer yapay zekâ araçları için yazılmış beceriler Sor'da \"/\" ile tarif olarak çalışır (ör. haftalık özet, takip e-postası).")
            } control: {
                Button("İçe aktar…") { importSkills() }
            }
        } footer: {
            if let status {
                Text(status)
            }
        }
    }

    private func importSkills() {
        let panel: NSOpenPanel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.prompt = String(localized: "İçe aktar")
        panel.message = String(localized: "Agent Skill dosyalarını (SKILL.md) seç")
        guard panel.runModal() == .OK else {
            return
        }
        status = skillImportSummary(result: model.importSkills(files: panel.urls))
    }
}

/// JSON metin değeri: tırnak ve ters bölü kaçışlanır (tırnak ya da ters bölü içeren yol yapılandırmayı bozmasın).
/// Saf fonksiyondur.
private func jsonStringLiteral(text: String) -> String {
    "\"" + text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
}

/// İstemcinin MCP yapılandırması: sunucu adı sürüme özgüdür (bkz. `mcpServerName(appName:)`), tek tıkla bağlamanın
/// yazdığıyla aynıdır. Saf fonksiyondur.
func mcpClientConfig(executablePath: String, serverName: String) -> String {
    """
    {
      "mcpServers": {
        \(jsonStringLiteral(text: serverName)): {
          "command": \(jsonStringLiteral(text: executablePath)),
          "args": ["--mcp"]
        }
      }
    }
    """
}

/// Yerel MCP sunucusu: Claude Desktop, ChatGPT ya da başka MCP istemcisinin toplantı arşivini sorgulaması için
/// yapılandırma (uygulama `--mcp` ile pencere açmadan çalışır; istemci yalnızca okur ve okuduğunu kendi yapay zekâ
/// sağlayıcısına gönderir).
private struct MCPSettings: View {
    @State private var copied: Bool = false

    var body: some View {
        // Elle kopyalanan yapılandırma da uygulamanın gerçek yolunu gösterir (uygulama paketi her zaman bir çalıştırılabilir içerir).
        let config: String = mcpClientConfig(
            executablePath: Bundle.main.executableURL?.path ?? Bundle.main.bundlePath, serverName: mcpServerName(appName: appName)
        )
        SettingsGroup(title: Text("Diğer MCP istemcileri")) {
            SettingsStackedRow(icon: "curlybraces", title: Text("Elle yapılandırma")) {
                SettingsMoreText(
                    summary: Text("Yapılandırmayı istemcinin MCP ayarlarına ekle; istemci yalnızca okur."),
                    details: Text("Bu yapılandırmayı istemcinin MCP ayarlarına (Claude Desktop: Ayarlar › Geliştirici › Yapılandırmayı düzenle) ekle. İstemci toplantılarını listeler, arar, notları, transkriptleri ve paylaşılan ekranların görüntülerini okur; yalnızca okur, hiçbir şey değiştirmez. Okunanlar istemcinin yapay zekâ sağlayıcısına (ör. Anthropic, OpenAI) gönderilir.")
                )
            } content: {
                Text(config)
                    .appFont(size: 12, weight: .regular)
                    .monospaced()
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button(copied ? "Kopyalandı" : "Yapılandırmayı kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(config, forType: .string)
                    copied = true
                }
            }
        }
    }
}
