import AINotepadCore
import AINotepadUI
import AuthenticationServices
import os
import SwiftUI
import UniformTypeIdentifiers

private let phoneConnectionsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneConnections")

/// Ayarlar › Bağlantılar satırı: bağlı yer ve araç sayısı; dokununca bağlantılar açılır.
struct PhoneConnectionsRow: View {
    @Environment(PhoneIntegrations.self) private var integrations: PhoneIntegrations

    var body: some View {
        NavigationLink {
            PhoneConnectionsScreen()
        } label: {
            LabeledContent("Kanallar ve görev araçları", value: "\(integrations.destinations.count + integrations.taskTrackers.count)")
        }
    }
}

/// Bağlantılar › Klasör (Mac'teki "Klasör (Obsidian, iCloud)" kartı): Dosyalar'dan seçilen klasöre (iCloud Drive,
/// Obsidian kasası, iPhone'umda…) not Markdown dosyası olarak yazılır; "Klasöre yaz" açıkken not hazır olunca ve her
/// değişince kendiliğinden.
private struct PhoneMarkdownFolderSection: View {
    @Environment(PhoneIntegrations.self) private var integrations: PhoneIntegrations
    @State private var isPicking: Bool = false
    /// Klasör seçilemedi ya da ayar saklanamadı: nedeni bölümün altında.
    @State private var status: String?

    var body: some View {
        Section {
            LabeledContent {
                Text(verbatim: integrations.markdownFolderName ?? String(localized: "Markdown dosyası olarak"))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Label("Klasör (Obsidian, iCloud)", systemImage: "folder.fill")
            }
            Button(integrations.markdownFolderName == nil ? "Seç…" : "Değiştir") { isPicking = true }
            if integrations.markdownFolderName != nil {
                Toggle("Klasöre yaz", isOn: Binding<Bool>(
                    get: { integrations.markdownAutoExport },
                    set: { (enabled: Bool) -> Void in status = integrations.setMarkdownAutoExport(enabled: enabled) }
                ))
            }
            if let status {
                NoticeText(status, severity: .error)
                    .appFont(size: 13, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text("\"Klasöre yaz\" açıkken not hazır olunca ve her değişince bu klasöre yazılır; eski notları toplantının ⋯ menüsünden kaydet.")
        }
        .fileImporter(isPresented: $isPicking, allowedContentTypes: [.folder]) { (result: Result<URL, any Error>) in
            switch result {
            case .success(let url):
                status = integrations.chooseMarkdownFolder(url: url)
            case .failure(let error):
                phoneConnectionsLogger.error("Klasör seçilemedi, hata: \(String(describing: error), privacy: .private)")
                status = String(localized: "Klasör seçilemedi: \(userFacingMessage(error: error))")
            }
        }
    }
}

/// Kurulumun durumu (Mac'teki `ChannelSetup`; kanal seçimi ve adres yapıştırma iPhone'da ayrı sayfadadır).
private enum PhoneChannelSetup: Equatable {
    case idle
    /// Uygulama içi tarayıcıda giriş bekleniyor.
    case signingIn(String)
    case working(String)
    case done(String)
    case failed(String)
}

/// Kurulumda açılan sayfa: girişten sonra kanal seçimi (`replacing`: kanalı değiştirilen hedef), webhook adresi ya da
/// Zoom adresi ve anahtarı.
private enum PhoneConnectionSheet: Identifiable {
    case channels(ChannelSignIn, [ChannelOption], replacing: String?)
    case webhook
    case zoom

    var id: String {
        switch self {
        case .channels(let signIn, _, let replacing): "kanal.\(signIn.service.rawValue).\(replacing ?? "yeni")"
        case .webhook: "webhook"
        case .zoom: "zoom"
        }
    }
}

/// Kurulum sonucunun kendiliğinden kaybolma süresi: başarı 3,5 sn, hata 5 sn; diğer durumlar kalır. Saf fonksiyondur.
private func phoneSetupFadeDelay(setup: PhoneChannelSetup) -> Duration? {
    switch setup {
    case .done: .seconds(3.5)
    case .failed: .seconds(5)
    case .idle, .signingIn, .working: nil
    }
}

/// Bağlantılar (Mac'teki Ayarlar › Bağlantılar): notun gittiği yerler (Slack, Teams, Discord, Notion, Zoom Team Chat,
/// webhook; her birinde otomatik gönderim ayrı) ve görev araçları (Linear, Jira). Girişler uygulama içi tarayıcıda.
struct PhoneConnectionsScreen: View {
    @Environment(PhoneIntegrations.self) private var integrations: PhoneIntegrations
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession: WebAuthenticationSession
    @State private var setup: PhoneChannelSetup = .idle
    @State private var sheet: PhoneConnectionSheet?
    @State private var selectedChannelID: String = ""
    @State private var manualAddress: String = ""
    @State private var zoomToken: String = ""
    /// Notion ile görev araçlarının girişleri (yerel dönüşlü uygulama içi tarayıcı); ikisi aynı anda sürebilir.
    @State private var notionBrowser: PhoneMCPSignIn = PhoneMCPSignIn()
    @State private var trackerBrowser: PhoneMCPSignIn = PhoneMCPSignIn()
    /// Süren Notion girişi: "Vazgeç" bunu iptal eder.
    @State private var notionSignIn: Task<Void, Never>?
    /// Bağlanan görev aracı ve süren girişi.
    @State private var connectingTracker: MCPService?
    @State private var trackerSignIn: Task<Void, Never>?
    @State private var trackerStatus: String?

    var body: some View {
        List {
            if !integrations.problems.isEmpty {
                Section {
                    PhoneDismissibleErrorList(messages: integrations.problems) { integrations.dismissProblems() }
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(integrations.destinations) { (destination: NoteDestination) in
                    destinationRow(destination: destination)
                }
                setupStatus
                ForEach(DestinationKind.allCases) { (kind: DestinationKind) in
                    addRow(kind: kind)
                }
            } header: {
                Text("Notların gittiği yerler")
            } footer: {
                Text("Otomatik gönderim açık yerlere, açtıktan sonra biten toplantıların notu hazır olunca gider; eski notlar toplantının ⋯ menüsünden elle gönderilir.")
            }
            PhoneMarkdownFolderSection()
            Section {
                ForEach([MCPService.linear, MCPService.atlassian], id: \.self) { (service: MCPService) in
                    trackerRow(service: service)
                }
                if let trackerStatus {
                    Text(verbatim: trackerStatus)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
            } header: {
                Text("Görev araçları")
            } footer: {
                Text("Toplantının ⋯ menüsünden görevleri Linear ya da Jira'da iş olarak açar.")
            }
        }
        .navigationTitle("Bağlantılar")
        .navigationBarTitleDisplayMode(.inline)
        .task { await integrations.load() }
        .task(id: setup) { await fadeSetupResult(shown: setup) }
        .sheet(item: $sheet) { (shown: PhoneConnectionSheet) in
            switch shown {
            case .channels(let signIn, let options, let replacing):
                PhoneChannelPicker(service: signIn.service, options: options, selection: $selectedChannelID) {
                    sheet = nil
                } onConnect: {
                    sheet = nil
                    choose(signIn: signIn, options: options, replacing: replacing)
                }
            case .webhook:
                PhoneAddressEntry(kind: .webhook, address: $manualAddress, token: $zoomToken) {
                    sheet = nil
                } onConnect: {
                    sheet = nil
                    connectWebhook()
                }
            case .zoom:
                PhoneAddressEntry(kind: .zoom, address: $manualAddress, token: $zoomToken) {
                    sheet = nil
                } onConnect: {
                    sheet = nil
                    connectZoom()
                }
            }
        }
    }

    // MARK: Satırlar

    /// Bağlı hedef: marka kutusu, ad ve kanal (ya da "yeniden bağlan" uyarısı), ⋯ menüsünde dene, kanalı değiştir,
    /// yeniden bağlan ve kaldır; altında otomatik gönderim.
    private func destinationRow(destination: NoteDestination) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PhoneBrandTile(kind: destinationKind(destination: destination), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: destinationName(destination: destination))
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    if destination.needsReconnect {
                        NoticeText("Oturumun süresi doldu; yeniden bağlan", severity: .attention)
                            .appFont(size: 13, weight: .regular)
                    } else {
                        Text(verbatim: destinationDetail(destination: destination))
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Deneme mesajı gönder", systemImage: "paperplane") { Task { await test(destinationID: destination.id) } }
                        .disabled(isBusy)
                    if case .account(let connection) = destination.target, !destination.needsReconnect {
                        Button("Kanalı değiştir", systemImage: "arrow.left.arrow.right") {
                            Task { await changeChannel(destinationID: destination.id, service: connection.service) }
                        }
                        .disabled(isBusy)
                    }
                    if destination.needsReconnect {
                        Button("Yeniden bağlan", systemImage: "arrow.clockwise") { reconnect(destination: destination) }
                            .disabled(isBusy)
                    }
                    Divider()
                    Button("Kaldır", systemImage: "trash", role: .destructive) { Task { await integrations.removeDestination(id: destination.id) } }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Diğer işlemler")
            }
            Toggle("Otomatik gönder", isOn: Binding<Bool>(
                get: { destination.autoSend },
                set: { (enabled: Bool) -> Void in Task { await integrations.setAutoSend(destinationID: destination.id, enabled: enabled) } }
            ))
            .appFont(size: 14, weight: .regular)
        }
        .padding(.vertical, 4)
    }

    /// Ekleme satırı: servis, kısa açıklama ve eylem ("Bağlan", adresle bağlananlarda "Yapıştır", bağlıysa "Ekle").
    private func addRow(kind: DestinationKind) -> some View {
        let count: Int = integrations.destinations.filter { destinationKind(destination: $0) == kind }.count
        let action: LocalizedStringKey = count > 0 ? "Ekle" : (kind == .zoom || kind == .webhook ? "Yapıştır" : "Bağlan")
        return Button {
            start(kind: kind)
        } label: {
            HStack(spacing: 12) {
                PhoneBrandTile(kind: kind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: kindName(kind: kind))
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text(kindDetail(kind: kind))
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(action)
                    .appFont(size: 14, weight: .semibold)
            }
        }
        .disabled(isBusy)
    }

    @ViewBuilder
    private var setupStatus: some View {
        switch setup {
        case .idle:
            EmptyView()
        case .signingIn(let name):
            HStack(spacing: 10) {
                ProgressView()
                Text("Açılan pencerede \(name) hesabınla giriş yap ve izin ver.")
                    .appFont(size: 13, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let notionSignIn {
                    Button("Vazgeç") { notionSignIn.cancel() }
                        .buttonStyle(.borderless)
                }
            }
        case .working(let message):
            // Gönderim sürerken sakin bir nabız; yalnızca bu durumda çizilir.
            Label {
                Text(message)
            } icon: {
                Image(systemName: "paperplane").symbolEffect(.pulse)
            }
            .appFont(size: 13, weight: .regular)
        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.ink)
                .transition(.opacity)
        case .failed(let message):
            NoticeText(message, severity: .error)
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    /// Görev aracı: bağlıysa takım/proje seçimi ve ⋯ menüsünde kaldır; değilse "Bağlan" (girişte "Vazgeç").
    @ViewBuilder
    private func trackerRow(service: MCPService) -> some View {
        let tile: PhoneBrandTile = PhoneBrandTile(tracker: service, size: 34)
        let detail: LocalizedStringKey = service == .linear ? "Takımındaki işler" : "Jira projesindeki işler"
        if let tracker = integrations.taskTrackers.first(where: { $0.service == service }) {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: service.displayName)
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    PhoneTrackerTargetPicker(tracker: tracker)
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Kaldır", systemImage: "trash", role: .destructive) { Task { await integrations.removeTracker(id: tracker.id) } }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Diğer işlemler")
            }
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: service.displayName)
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text(detail)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                if connectingTracker == service, let trackerSignIn {
                    Button("Vazgeç") { trackerSignIn.cancel() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.muted)
                }
                Button(connectingTracker == service ? "İzin bekleniyor…" : "Bağlan") { connect(service: service) }
                    .buttonStyle(.borderless)
                    .appFont(size: 14, weight: .semibold)
                    .disabled(connectingTracker != nil)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Kurulum

    /// Giriş, gönderim ya da deneme sürüyor: ikinci bir kurulum başlamasın.
    private var isBusy: Bool {
        switch setup {
        case .signingIn, .working: true
        case .idle, .done, .failed: false
        }
    }

    /// Sonuç mesajı bir süre sonra yumuşakça kaybolur; daha yeni bir durum gelince zamanlayıcı yeniden başlar.
    private func fadeSetupResult(shown: PhoneChannelSetup) async {
        guard let delay = phoneSetupFadeDelay(setup: shown) else {
            return
        }
        do {
            try await Task.sleep(for: delay)
        } catch {
            // Yalnızca iptal: yeni bir durum geldi.
            return
        }
        guard setup == shown else {
            return
        }
        withAnimation(.easeOut(duration: 0.4)) { setup = .idle }
    }

    private func start(kind: DestinationKind) {
        manualAddress = ""
        zoomToken = ""
        switch kind {
        case .zoom:
            sheet = .zoom
        case .webhook:
            sheet = .webhook
        case .notion:
            notionSignIn = Task { await connectNotion() }
        case .slack, .teams, .discord:
            if let service = kind.channelService {
                Task { await signIn(service: service, replacing: nil) }
            }
        }
    }

    private func reconnect(destination: NoteDestination) {
        switch destination.target {
        case .account(let connection): Task { await signIn(service: connection.service, replacing: destination.id) }
        case .notion: notionSignIn = Task { await reconnectNotion(destinationID: destination.id) }
        case .webhook, .discordSignIn: return
        }
    }

    /// Uygulama içi tarayıcıda giriş (PKCE); Discord'da kanal orada seçilir ve eklenir, Slack ve Teams'te kanal listesi
    /// gelir. `replacing` verilirse (yeniden bağlan) yeni bağlantı o hedefin yerine geçer. Pencere kapatılırsa vazgeçilir.
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
            let callback: URL = try await webAuthenticationSession.authenticate(
                using: channelAuthorizeURL(service: service, clientID: clientID, pkce: pkce, state: state),
                callback: .customScheme(oauthCallbackScheme), preferredBrowserSession: nil, additionalHeaderFields: [:]
            )
            let code: String = try oauthCallbackCode(service: service, url: callback, expectedState: state)
            switch service {
            case .discord:
                let url: URL = try await exchangeDiscordCode(code: code, verifier: pkce.verifier, clientID: clientID)
                // Girişle oluşturulan webhook: hedef kaldırılınca Discord'da da silinir.
                let destination: NoteDestination = try await integrations.addDestination(target: .discordSignIn(url))
                await test(destinationID: destination.id)
            case .slack:
                await showChannels(signIn: try await exchangeSlackCode(code: code, verifier: pkce.verifier, clientID: clientID), replacing: replacing)
            case .teams:
                await showChannels(signIn: try await exchangeTeamsCode(code: code, verifier: pkce.verifier, clientID: clientID), replacing: replacing)
            }
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            setup = .idle
        } catch {
            phoneConnectionsLogger.error("Kanal girişi başarısız, servis: \(service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func showChannels(signIn: ChannelSignIn, replacing: String?) async {
        do {
            let options: [ChannelOption] = try await listChannels(signIn: signIn)
            // Kanal önceden seçilmez: notlar yanlışlıkla herkesin gördüğü #genel'e gitmesin.
            selectedChannelID = ""
            setup = .idle
            sheet = .channels(signIn, options, replacing: replacing)
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
                    try await integrations.replaceDestinationTarget(id: replacing, target: .account(connection))
                    await test(destinationID: replacing)
                } else {
                    let destination: NoteDestination = try await integrations.addDestination(target: .account(connection))
                    await test(destinationID: destination.id)
                }
            } catch {
                setup = .failed(userFacingMessage(error: error))
            }
        }
    }

    /// Kayıtlı oturumla kanalları yeniden listeler (yeniden giriş gerekmez).
    private func changeChannel(destinationID: String, service: ChannelService) async {
        setup = .working(String(localized: "Kanallar okunuyor…"))
        do {
            let result: (signIn: ChannelSignIn, options: [ChannelOption]) = try await integrations.channelOptions(destinationID: destinationID)
            selectedChannelID = ""
            setup = .idle
            sheet = .channels(result.signIn, result.options, replacing: destinationID)
        } catch {
            setup = .failed(userFacingMessage(error: error))
        }
    }

    private func connectNotion() async {
        setup = .signingIn("Notion")
        defer { notionSignIn = nil }
        do {
            try await integrations.connectNotion(browser: notionBrowser)
            setup = .done(String(localized: "Notion bağlandı; notlar özel sayfalarına yeni sayfa olarak gider."))
        } catch is CancellationError {
            setup = .idle
        } catch {
            phoneConnectionsLogger.error("Notion girişi başarısız, hata: \(String(describing: error), privacy: .private)")
            setup = .failed(userFacingMessage(error: error))
        }
    }

    /// Notion oturumu bitti: aynı hedefin bağlantısı yenilenir (ayarı ve gönderim geçmişi korunur).
    private func reconnectNotion(destinationID: String) async {
        setup = .signingIn("Notion")
        defer { notionSignIn = nil }
        do {
            try await integrations.reconnectNotion(destinationID: destinationID, browser: notionBrowser)
            setup = .done(String(localized: "Notion yeniden bağlandı."))
        } catch is CancellationError {
            setup = .idle
        } catch {
            phoneConnectionsLogger.error("Notion yeniden bağlanamadı, hata: \(String(describing: error), privacy: .private)")
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
                let destination: NoteDestination = try await integrations.addDestination(target: .webhook(url))
                await test(destinationID: destination.id)
            } catch {
                setup = .failed(userFacingMessage(error: error))
            }
        }
    }

    private func test(destinationID: String) async {
        let name: String = integrations.destinations.first { $0.id == destinationID }.map { destinationName(destination: $0) } ?? ""
        setup = .working(String(localized: "Deneme mesajı gönderiliyor…"))
        if let error = await integrations.sendTestNote(destinationID: destinationID) {
            setup = .failed(error)
        } else {
            setup = .done(String(localized: "\(name) bağlandı; deneme mesajı gönderildi."))
        }
    }

    private func connect(service: MCPService) {
        connectingTracker = service
        trackerStatus = nil
        trackerSignIn = Task {
            defer {
                connectingTracker = nil
                trackerSignIn = nil
            }
            do {
                try await integrations.connectTracker(service: service, browser: trackerBrowser)
                trackerStatus = String(localized: "\(service.displayName) bağlandı.")
            } catch is CancellationError {
                trackerStatus = nil
            } catch {
                trackerStatus = userFacingMessage(error: error)
            }
        }
    }
}

/// Ekleme satırındaki ad (Mac'teki kartlarla aynı). Saf fonksiyondur.
private func kindName(kind: DestinationKind) -> String {
    switch kind {
    case .slack: "Slack"
    case .teams: "Microsoft Teams"
    case .discord: "Discord"
    case .notion: "Notion"
    case .zoom: "Zoom Team Chat"
    case .webhook: String(localized: "Webhook adresi")
    }
}

/// Ekleme satırındaki kısa açıklama (Mac'teki kartlarla aynı). Saf fonksiyondur.
private func kindDetail(kind: DestinationKind) -> LocalizedStringKey {
    switch kind {
    case .slack: "Kendi adınla, seçtiğin kanala"
    case .teams: "İş ya da okul hesabı (kişisel hesaplar desteklenmiyor)"
    case .discord: "Sunucu ve kanalı Discord'da seç"
    case .notion: "Her toplantı için yeni sayfa"
    case .zoom: "Kanalda /inc connect yaz, adresi ve anahtarı yapıştır"
    case .webhook: "Zapier, Make, n8n, Teams iş akışı"
    }
}

/// Servis kutusu (Mac'teki `BrandTile`): uygulamanın pastel film gradyanı üstünde servisin kendi logosu, koyu mürekkep
/// renginde.
private struct PhoneBrandTile: View {
    private enum Mark {
        case logo(String)
        /// Yazıdan oluşan geniş logo (Zoom): kutuyu daha çok doldurur.
        case wordmark(String)
        case symbol(String)
    }

    private let mark: Mark
    private let palette: FilmPalette
    private let seed: String
    let size: CGFloat

    init(kind: DestinationKind, size: CGFloat) {
        let style: (mark: Mark, palette: FilmPalette) = switch kind {
        case .slack: (.logo("brand-slack"), .rose)
        case .teams: (.logo("brand-microsoftteams"), .violet)
        case .discord: (.logo("brand-discord"), .ocean)
        case .notion: (.logo("brand-notion"), .coral)
        case .zoom: (.wordmark("brand-zoom"), .ocean)
        case .webhook: (.symbol("bolt.horizontal.fill"), .mint)
        }
        mark = style.mark
        palette = style.palette
        seed = kind.rawValue
        self.size = size
    }

    init(tracker: MCPService, size: CGFloat) {
        let style: (mark: Mark, palette: FilmPalette, seed: String) = switch tracker {
        case .linear: (.logo("brand-linear"), .violet, "linear")
        case .atlassian: (.logo("brand-jira"), .ocean, "jira")
        case .notion: (.logo("brand-notion"), .coral, "notion")
        }
        mark = style.mark
        palette = style.palette
        seed = style.seed
        self.size = size
    }

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            switch mark {
            case .logo(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.46, height: size * 0.46)
            case .wordmark(let name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.76, height: size * 0.76)
            case .symbol(let name):
                Image(systemName: name).appFont(size: size * 0.4, weight: .semibold)
            }
        }
        .foregroundStyle(Color.black.opacity(0.8))
        .frame(width: size, height: size)
        .background { FilmGradient(seed: "marka-\(seed)", palette: palette) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.2)))
        .accessibilityHidden(true)
    }
}

/// Girişten sonra notların gideceği kanalın seçimi (Slack kanalları, Teams'te "Takım › Kanal"). Kanal önceden seçilmez.
private struct PhoneChannelPicker: View {
    let service: ChannelService
    let options: [ChannelOption]
    @Binding var selection: String
    let onCancel: @MainActor () -> Void
    let onConnect: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options) { (option: ChannelOption) in
                        Button {
                            selection = option.id
                        } label: {
                            HStack {
                                Text(verbatim: option.name)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if option.id == selection {
                                    Image(systemName: "checkmark")
                                        .appFont(size: 14, weight: .semibold)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Notlar hangi kanala gitsin?")
                }
            }
            .navigationTitle(Text(verbatim: service.displayName))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bağla", action: onConnect)
                        .disabled(!options.contains { $0.id == selection })
                }
            }
        }
    }
}

/// Adresle bağlanan hedef: webhook adresi (Zapier, Make, n8n, Teams iş akışı) ya da Zoom adresi ve doğrulama anahtarı.
private struct PhoneAddressEntry: View {
    let kind: DestinationKind
    @Binding var address: String
    @Binding var token: String
    let onCancel: @MainActor () -> Void
    let onConnect: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if kind == .zoom {
                        TextField("Zoom adresi", text: $address, prompt: Text(verbatim: "https://integrations.zoom.us/chat/webhooks/incomingwebhook/…"))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Doğrulama anahtarı", text: $token, prompt: Text("Doğrulama anahtarı"))
                    } else {
                        TextField("Webhook adresi", text: $address, prompt: Text(verbatim: "https://hooks.zapier.com/…"))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(kindDetail(kind: kind))
                }
            }
            .navigationTitle(Text(verbatim: kindName(kind: kind)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bağla", action: onConnect)
                        .disabled(address.isEmpty || (kind == .zoom && token.isEmpty))
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Görev aracının hedefi (Linear takımı, Jira projesi): araçtaki gerçek seçenekler menüde. Tek seçenek varsa yalnızca
/// adı görünür; hedef boşsa ilk seçenek kullanılır ve öyle gösterilir. Seçenekler okunamazsa neden ve "Yeniden dene".
private struct PhoneTrackerTargetPicker: View {
    let tracker: TaskTracker
    @Environment(PhoneIntegrations.self) private var integrations: PhoneIntegrations
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
                            Task { await integrations.setTrackerTarget(id: tracker.id, target: name) }
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
            } else if let current {
                targetLabel(noun: noun, name: current)
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    NoticeText(errorMessage, severity: .attention)
                        .appFont(size: 12, weight: .regular)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Yeniden dene", systemImage: "arrow.clockwise") { Task { await load() } }
                        .buttonStyle(.borderless)
                        .appFont(size: 13, weight: .medium)
                }
            } else {
                ProgressView()
            }
        }
        .task(id: tracker.id) { await load() }
    }

    private func targetLabel(noun: LocalizedStringKey, name: String) -> some View {
        HStack(spacing: 4) {
            Text(noun).foregroundStyle(Theme.muted)
            Text(verbatim: name).lineLimit(1)
        }
        .appFont(size: 13, weight: .medium)
    }

    private func load() async {
        errorMessage = nil
        do {
            options = try await integrations.trackerTargets(id: tracker.id)
        } catch {
            errorMessage = userFacingMessage(error: error)
        }
    }
}
