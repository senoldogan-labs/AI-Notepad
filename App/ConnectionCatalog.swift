import AINotepadCore
import AINotepadUI
import SwiftUI

// Ayarlar › Bağlantılar'ın Mac ve iPhone'da ortak içeriği: listedeki her entegrasyonun adı, tek satır açıklaması, marka
// kutusu, ayrıntı sayfasındaki "İçerir" kartları ve "nasıl kullanılır" (gizlilik) satırları, satırdaki durum rozeti.
// Ekranlar platformun kendi dosyasında (App/ConnectionsSettings.swift, iOS/PhoneConnectionsScreen.swift).

/// Bağlantılar listesindeki bir entegrasyon. iPhone'da Mac'e özgü olanlar (Apple Notlar, yerel yapay zekâ uygulamaları)
/// listelenmez (bkz. `IntegrationGroup.phoneKinds`).
enum IntegrationKind: String, CaseIterable, Identifiable, Hashable {
    case slack
    case teams
    case discord
    case notion
    case zoom
    case webhook
    case appleNotes = "apple-notes"
    case folder
    case linear
    case jira
    case claudeDesktop = "claude"
    case cursor
    case vsCode = "vscode"

    var id: String { rawValue }

    /// Not hedefi türü (Slack, Teams, Discord, Notion, Zoom, webhook); diğerlerinde nil.
    var destinationKind: DestinationKind? {
        switch self {
        case .slack: .slack
        case .teams: .teams
        case .discord: .discord
        case .notion: .notion
        case .zoom: .zoom
        case .webhook: .webhook
        case .appleNotes, .folder, .linear, .jira, .claudeDesktop, .cursor, .vsCode: nil
        }
    }

    /// Görev aracı (Linear, Jira); diğerlerinde nil.
    var trackerService: MCPService? {
        switch self {
        case .linear: .linear
        case .jira: .atlassian
        case .slack, .teams, .discord, .notion, .zoom, .webhook, .appleNotes, .folder, .claudeDesktop, .cursor, .vsCode: nil
        }
    }

    /// Bu Mac'e bağlanan yerel yapay zekâ uygulaması (MCP); diğerlerinde nil.
    var mcpClient: MCPClient? {
        switch self {
        case .claudeDesktop: .claudeDesktop
        case .cursor: .cursor
        case .vsCode: .vsCode
        case .slack, .teams, .discord, .notion, .zoom, .webhook, .appleNotes, .folder, .linear, .jira: nil
        }
    }

    var name: String {
        switch self {
        case .slack: "Slack"
        case .teams: "Microsoft Teams"
        case .discord: "Discord"
        case .notion: "Notion"
        case .zoom: "Zoom Team Chat"
        case .webhook: String(localized: "Webhook adresi")
        case .appleNotes: String(localized: "Apple Notlar")
        case .folder: String(localized: "Klasör (Obsidian, iCloud)")
        case .linear: "Linear"
        case .jira: "Jira"
        case .claudeDesktop: MCPClient.claudeDesktop.displayName
        case .cursor: MCPClient.cursor.displayName
        case .vsCode: MCPClient.vsCode.displayName
        }
    }

    /// Listedeki ve ayrıntı sayfasındaki tek satırlık açıklama.
    var summary: LocalizedStringKey {
        switch self {
        case .slack: "Kendi adınla, seçtiğin kanala"
        case .teams: "İş ya da okul hesabı (kişisel hesaplar desteklenmiyor)"
        case .discord: "Sunucu ve kanalı Discord'da seç"
        case .notion: "Her toplantı için yeni sayfa"
        case .zoom: "Kanalda /inc connect yaz, adresi ve anahtarı yapıştır"
        case .webhook: "Zapier, Make, n8n, Teams iş akışı"
        case .appleNotes: "\"\(appName)\" klasörüne, hesap gerekmez"
        case .folder: "Markdown dosyası olarak"
        case .linear: "Takımındaki işler"
        case .jira: "Jira projesindeki işler"
        case .claudeDesktop, .cursor, .vsCode: "Toplantılarını arayıp okur"
        }
    }

    /// Ayrıntı sayfasındaki "İçerir" kartları. Saf fonksiyondur.
    var features: [IntegrationFeature] {
        switch self {
        case .slack, .teams, .discord, .zoom:
            [.autoSend, .tasksFirst, .catchUp, .manyChannels]
        case .webhook:
            [.autoSend, .structured, .catchUp, .manyChannels]
        case .notion:
            [.notionPage, .autoSend, .catchUp]
        case .appleNotes:
            [.appleNotesFolder, .autoSend]
        case .folder:
            [.markdown, .keepsUpdated]
        case .linear, .jira:
            [.openIssues, .chooseTarget]
        case .claudeDesktop, .cursor, .vsCode:
            [.searchMeetings, .readNotes, .screens]
        }
    }

    /// "<Ad> nasıl kullanılır" satırları. Saf fonksiyondur.
    var privacy: [IntegrationPrivacyPoint] {
        switch self {
        case .slack, .teams, .discord, .notion:
            [.noteOnly, .signInAtService, .manualUnlessAuto, .removeAnytime]
        case .zoom, .webhook:
            [.noteOnly, .addressOnlyForNotes, .manualUnlessAuto, .removeAnytime]
        case .appleNotes:
            [.notesOnThisMac, .stopAnytime]
        case .folder:
            [.onlyChosenFolder, .stopAnytime]
        case .linear, .jira:
            [.officialSignIn, .tasksToProvider, .onlyWhenYouSend]
        case .claudeDesktop, .cursor, .vsCode:
            [.readOnly, .appProvider, .runsOnThisMac]
        }
    }

    /// Marka kutusunun işareti, gradyan ailesi ve tohumu.
    var tileStyle: IntegrationTileStyle {
        switch self {
        case .slack: IntegrationTileStyle(mark: .logo("brand-slack"), palette: .rose, seed: "slack")
        case .teams: IntegrationTileStyle(mark: .logo("brand-microsoftteams"), palette: .violet, seed: "teams")
        case .discord: IntegrationTileStyle(mark: .logo("brand-discord"), palette: .ocean, seed: "discord")
        case .notion: IntegrationTileStyle(mark: .logo("brand-notion"), palette: .coral, seed: "notion")
        case .zoom: IntegrationTileStyle(mark: .wordmark("brand-zoom"), palette: .ocean, seed: "zoom")
        case .webhook: IntegrationTileStyle(mark: .symbol("bolt.horizontal.fill"), palette: .mint, seed: "webhook")
        case .appleNotes: IntegrationTileStyle(mark: .symbol("note.text"), palette: .coral, seed: "apple-notlar")
        case .folder: IntegrationTileStyle(mark: .symbol("folder.fill"), palette: .ocean, seed: "klasor")
        case .linear: IntegrationTileStyle(mark: .logo("brand-linear"), palette: .violet, seed: "linear")
        case .jira: IntegrationTileStyle(mark: .logo("brand-jira"), palette: .ocean, seed: "jira")
        case .claudeDesktop: IntegrationTileStyle(mark: .logo("brand-claude"), palette: .sunset, seed: "claude")
        case .cursor: IntegrationTileStyle(mark: .logo("brand-cursor"), palette: .mint, seed: "cursor")
        case .vsCode: IntegrationTileStyle(mark: .logo("brand-visualstudiocode"), palette: .ocean, seed: "vscode")
        }
    }
}

extension DestinationKind {
    /// Listedeki entegrasyonu.
    var integrationKind: IntegrationKind {
        switch self {
        case .slack: .slack
        case .teams: .teams
        case .discord: .discord
        case .notion: .notion
        case .zoom: .zoom
        case .webhook: .webhook
        }
    }
}

/// Bağlantılar listesinin bölümleri (sırasıyla).
enum IntegrationGroup: CaseIterable {
    case destinations
    case taskTools
    case aiApps

    var title: LocalizedStringKey {
        switch self {
        case .destinations: "Notların gittiği yerler"
        case .taskTools: "Görev araçları"
        case .aiApps: "Yapay zekâ uygulamaları"
        }
    }

    /// Mac'teki bölümün entegrasyonları.
    var macKinds: [IntegrationKind] {
        switch self {
        case .destinations: [.slack, .teams, .discord, .notion, .zoom, .webhook, .appleNotes, .folder]
        case .taskTools: [.linear, .jira]
        case .aiApps: [.claudeDesktop, .cursor, .vsCode]
        }
    }

    /// iPhone'daki bölümün entegrasyonları (Apple Notlar ve yerel yapay zekâ uygulamaları Mac'te).
    var phoneKinds: [IntegrationKind] {
        macKinds.filter { $0 != .appleNotes && $0.mcpClient == nil }
    }
}

/// "İçerir" kartı: simge, başlık ve tek satır açıklama.
enum IntegrationFeature: Hashable {
    case autoSend
    case tasksFirst
    case catchUp
    case manyChannels
    case structured
    case notionPage
    case appleNotesFolder
    case markdown
    case keepsUpdated
    case openIssues
    case chooseTarget
    case searchMeetings
    case readNotes
    case screens

    var symbol: String {
        switch self {
        case .autoSend: "paperplane"
        case .tasksFirst: "checklist"
        case .catchUp: "arrow.clockwise"
        case .manyChannels: "square.stack"
        case .structured: "curlybraces"
        case .notionPage: "doc.text"
        case .appleNotesFolder: "folder"
        case .markdown: "doc.plaintext"
        case .keepsUpdated: "arrow.triangle.2.circlepath"
        case .openIssues: "checklist"
        case .chooseTarget: "person.2"
        case .searchMeetings: "magnifyingglass"
        case .readNotes: "doc.text.magnifyingglass"
        case .screens: "photo.on.rectangle"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .autoSend: "Otomatik gönderim"
        case .tasksFirst: "Önce görevler"
        case .catchUp: "Kaçan gönderim yok"
        case .manyChannels: "Birden çok kanal"
        case .structured: "Yapılandırılmış veri"
        case .notionPage: "Her toplantıya bir sayfa"
        case .appleNotesFolder: "Kendi klasöründe"
        case .markdown: "Markdown dosyası"
        case .keepsUpdated: "Güncel kalır"
        case .openIssues: "Görevleri iş olarak aç"
        case .chooseTarget: "Takım ya da proje seç"
        case .searchMeetings: "Toplantılarını ara"
        case .readNotes: "Notları ve transkriptleri oku"
        case .screens: "Ekran görüntüleri"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .autoSend: "Not hazır olunca kendiliğinden gider"
        case .tasksFirst: "Görevler, kararlar ve özet tek mesajda"
        case .catchUp: "Ağ yokken kaçanlar sonra kendiliğinden gider"
        case .manyChannels: "Her birinin otomatik gönderimi ayrı"
        case .structured: "Görevler ve kararlar ayrı alanlarda da gelir"
        case .notionPage: "Not, Notion'da yeni sayfa olarak açılır"
        case .appleNotesFolder: "Notlar uygulamasında ayrı bir klasörde toplanır"
        case .markdown: "Obsidian ve her metin düzenleyiciyle açılır"
        case .keepsUpdated: "Not değişince dosya da güncellenir"
        case .openIssues: "Toplantının görevleri tek tıkla iş olur"
        case .chooseTarget: "İşlerin açılacağı yeri sen seçersin"
        case .searchMeetings: "Toplantılarını listeler ve arar"
        case .readNotes: "Sorularını kendi toplantılarınla yanıtlar"
        case .screens: "Paylaşılan ekranların görüntülerini de görür"
        }
    }
}

/// "<Ad> nasıl kullanılır" satırı: küçük simge ve tek cümle.
enum IntegrationPrivacyPoint: Hashable {
    case noteOnly
    case signInAtService
    case addressOnlyForNotes
    case manualUnlessAuto
    case removeAnytime
    case notesOnThisMac
    case onlyChosenFolder
    case stopAnytime
    case officialSignIn
    case tasksToProvider
    case onlyWhenYouSend
    case readOnly
    case appProvider
    case runsOnThisMac

    var symbol: String {
        switch self {
        case .noteOnly: "lock.shield"
        case .signInAtService: "key"
        case .addressOnlyForNotes: "link"
        case .manualUnlessAuto: "hand.raised"
        case .removeAnytime: "trash"
        case .notesOnThisMac: "laptopcomputer"
        case .onlyChosenFolder: "folder"
        case .stopAnytime: "pause.circle"
        case .officialSignIn: "key"
        case .tasksToProvider: "sparkles"
        case .onlyWhenYouSend: "hand.raised"
        case .readOnly: "eye"
        case .appProvider: "sparkles"
        case .runsOnThisMac: "laptopcomputer"
        }
    }

    var text: LocalizedStringKey {
        switch self {
        case .noteOnly: "Yalnızca not gider; ses, transkript ve ekran görüntüleri gitmez."
        case .signInAtService: "İzni servisin kendi giriş sayfasında verirsin; şifren bize gelmez."
        case .addressOnlyForNotes: "Yapıştırdığın adres yalnızca not göndermek için kullanılır."
        case .manualUnlessAuto: "Otomatik gönderim kapalıyken yalnızca senin gönderdiğin notlar gider."
        case .removeAnytime: "İstediğin an kaldırabilirsin; bağlantı uygulamadan silinir."
        case .notesOnThisMac: "Notlar uygulamasına bu Mac'te yazılır; hesap gerekmez."
        case .onlyChosenFolder: "Yalnızca seçtiğin klasöre yazılır."
        case .stopAnytime: "Kapatınca yeni notlar yazılmaz; yazılanlar yerinde kalır."
        case .officialSignIn: "Resmi bağlantıyla, tarayıcıda izin vererek kurulur; API anahtarı gerekmez."
        case .tasksToProvider: "İşleri yapay zekâ sağlayıcın açar; görev metinleri ona gider."
        case .onlyWhenYouSend: "Yalnızca sen gönderince iş açılır; kendiliğinden bir şey açılmaz."
        case .readOnly: "Yalnızca okur, hiçbir şey değiştirmez."
        case .appProvider: "Okuduğunu kendi yapay zekâ sağlayıcısına gönderir."
        case .runsOnThisMac: "Bu Mac'te çalışır; Kaldır ile yapılandırmasından çıkar."
        }
    }
}

/// Servisin işareti: kendi logosu (görsel kataloğunda, tek renk şablon), yazıdan oluşan geniş logo ya da sistem simgesi.
enum IntegrationMark {
    case logo(String)
    /// Yazıdan oluşan geniş logo (Zoom): kutuyu daha çok doldurur.
    case wordmark(String)
    case symbol(String)
}

struct IntegrationTileStyle {
    let mark: IntegrationMark
    let palette: FilmPalette
    let seed: String
}

/// Servis kutusu: uygulamanın pastel film gradyanı üstünde servisin kendi logosu, koyu mürekkep renginde.
struct IntegrationTile: View {
    let style: IntegrationTileStyle
    let size: CGFloat

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            switch style.mark {
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
        .background { FilmGradient(seed: "marka-\(style.seed)", palette: style.palette) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.2)))
        .accessibilityHidden(true)
    }
}

/// Listedeki satırın durumu.
enum IntegrationStatus: Equatable {
    case notConnected
    /// Bağlı (birden çok hedef olabilir).
    case connected(count: Int)
    /// Oturumu biten bağlantı var: yeniden bağlanmalı.
    case needsReconnect
    /// Yerel uygulama bu Mac'te yüklü değil.
    case notInstalled
    /// Durum okunamadı (ör. uygulamanın yapılandırma dosyası bozuk); nedeni entegrasyonun sayfasında yazar.
    case unreadable
}

/// Not hedefi türünün durumu: oturumu biten varsa "yeniden bağlan", yoksa bağlı sayısı. Saf fonksiyondur.
func destinationIntegrationStatus(kind: DestinationKind, destinations: [NoteDestination]) -> IntegrationStatus {
    let matching: [NoteDestination] = destinations.filter { destinationKind(destination: $0) == kind }
    if matching.contains(where: \.needsReconnect) {
        return .needsReconnect
    }
    return matching.isEmpty ? .notConnected : .connected(count: matching.count)
}

/// Satırın sağındaki durum rozeti: bağlıysa vurgu renginde "Bağlı" (birden çoksa sayısı), yeniden bağlanmalıysa uyarı
/// renginde; bağlı değilse hiçbir şey.
struct IntegrationStatusPill: View {
    let status: IntegrationStatus
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        switch status {
        case .notConnected:
            EmptyView()
        case .connected(let count):
            pill(text: count > 1 ? Text("\(count) bağlı") : Text("Bağlı"), tint: appearance.accent.color)
        case .needsReconnect:
            pill(text: Text("Yeniden bağlan"), tint: NoticeSeverity.attention.tint)
        case .unreadable:
            pill(text: Text("Okunamadı"), tint: NoticeSeverity.attention.tint)
        case .notInstalled:
            Text("Yüklü değil")
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(Theme.muted)
        }
    }

    private func pill(text: Text, tint: Color) -> some View {
        text
            .appFont(size: 12, weight: .semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

/// Yapay zekâ asistanı erişiminin tek satırlık özeti (kapalı başlıkta ve iPhone'daki satırda): kapalı, açık ve bağlı
/// asistan sayısı. Saf fonksiyondur.
func assistantAccessSummary(isOn: Bool, grants: Int) -> Text {
    guard isOn else {
        return Text("Kapalı")
    }
    return grants == 0 ? Text("Açık, bağlı asistan yok") : Text("Açık, \(grants) asistan bağlı")
}

/// `--baglanti <ad>` başlatma argümanı (görsel kontrol): Bağlantılar açılınca o entegrasyonun sayfası açık başlar; ad
/// `IntegrationKind` değeri (ör. `slack`). Yoksa ya da tanınmazsa nil. Saf fonksiyondur.
func launchIntegration(arguments: [String]) -> IntegrationKind? {
    guard let index = arguments.firstIndex(of: "--baglanti"), arguments.indices.contains(index + 1) else {
        return nil
    }
    return IntegrationKind(rawValue: arguments[index + 1])
}

/// `--asistan-acik` başlatma argümanı (görsel kontrol): yapay zekâ asistanı erişimi açık (genişletilmiş) başlar. Saf
/// fonksiyondur.
func launchExpandsAssistantAccess(arguments: [String]) -> Bool {
    arguments.contains("--asistan-acik")
}

/// Sunucunun kabul etmediği toplantıların açıklaması (sayı ve kısa neden). Saf fonksiyondur.
func assistantRefusedText(progress: AssistantUploadProgress) -> Text {
    switch progress.rejectionReason {
    case .tooLarge: Text("\(progress.rejected) toplantı kabul edilmedi: notu asistan kopyası için çok büyük.")
    case .invalid: Text("\(progress.rejected) toplantı kabul edilmedi: sunucu notu geçersiz buldu.")
    case nil: Text("\(progress.rejected) toplantı kabul edilmedi.")
    }
}
