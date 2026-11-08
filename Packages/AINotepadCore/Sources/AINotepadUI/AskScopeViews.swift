import AINotepadCore
import SwiftUI

// Sor'un kapsam çipi (Mac ve iPhone'daki her Sor alanının üstünde) ve kapsamın adları: çip seçili kapsamı gösterir,
// dokununca menü açılır (bulunulan yerin kapsamı, tüm toplantılar, toplantının klasörü ve kişileri, tarih aralıkları,
// alt menülerde bütün klasörler ve kişiler); kapsam tüm toplantılar değilse yanındaki ✕ tek dokunuşla tüm toplantılara
// genişletir.

/// Kapsamın simgesi. Saf fonksiyondur.
public func askScopeSymbol(scope: AskScope) -> String {
    switch scope {
    case .allMeetings: "square.stack.3d.up"
    case .meeting: "doc.text"
    case .folder: "folder"
    case .person: "person"
    case .lastDays: "calendar"
    }
}

/// Kapsamın çipte, menüde ve geçmişte görünen adı, arayüz dilinde: toplantı kapsamı bulunulan toplantıysa "Bu
/// toplantı", değilse toplantının başlığı (`meetingTitle`; bilinmiyorsa "Bir toplantı").
@MainActor
public func askScopeTitle(scope: AskScope, context: AskScope, meetingTitle: String?) -> String {
    switch scope {
    case .allMeetings:
        return String(localized: "Tüm toplantılar")
    case .meeting:
        guard scope != context, let meetingTitle else {
            return scope == context ? String(localized: "Bu toplantı") : String(localized: "Bir toplantı")
        }
        return meetingTitle
    case .folder(let name), .person(let name):
        return name
    case .lastDays(let days):
        return String(localized: "Son \(days) gün")
    }
}

/// Soru alanının yer tutucusu (ve VoiceOver etiketi), kapsama göre; teknik ipucu (`@`, `/`) yok.
@MainActor
public func askScopePlaceholder(scope: AskScope) -> String {
    switch scope {
    case .allMeetings:
        return String(localized: "Toplantılarına bir şey sor…")
    case .meeting:
        return String(localized: "Bu toplantıya bir şey sor")
    case .folder(let name):
        return String(localized: "\(name) klasöründeki toplantılara sor…")
    case .person(let name):
        return String(localized: "\(name) ile toplantılarına sor…")
    case .lastDays(let days):
        return String(localized: "Son \(days) günün toplantılarına sor…")
    }
}

/// Sohbetin geçmişteki kapsam etiketi: son turun kapsamı; toplantı kapsamında toplantının başlığı (turda saklı).
@MainActor
public func askConversationScopeTitle(conversation: AskConversation) -> String {
    let scope: AskScope = askConversationScope(conversation: conversation)
    return askScopeTitle(scope: scope, context: .allMeetings, meetingTitle: conversation.turns.last?.scopeTitles.first)
}

/// Kapsam çipinin seçenekleri: menünün ilk bölümü (`askScopeOptions`) ve alt menülerdeki klasörler ve kişiler.
public struct AskScopeMenu: Equatable, Sendable {
    /// Bulunulan yerin kapsamı (varsayılan; "Bu toplantı" adı buna göre).
    public let context: AskScope
    public let selected: AskScope
    public let options: [AskScope]
    public let folders: [String]
    public let people: [String]
    /// Toplantı kapsamlarının başlıkları (kimlik → başlık).
    public let meetingTitles: [String: String]

    public init(context: AskScope, selected: AskScope, options: [AskScope], folders: [String], people: [String], meetingTitles: [String: String]) {
        self.context = context
        self.selected = selected
        self.options = options
        self.folders = folders
        self.people = people
        self.meetingTitles = meetingTitles
    }
}

/// Kapsam çipinin seçenekleri: bulunulan yer, seçili kapsam, toplantının klasörü ve kişileri, tarih aralıkları; alt
/// menülerde toplantısı olan klasörler (ada göre) ve kişiler (en çok 12, son görülen önce). Saf fonksiyondur.
public func askScopeMenu(context: AskScope, selected: AskScope, records: [MeetingRecord], folders: [FolderSummary], userName: String) -> AskScopeMenu {
    let contextMeeting: MeetingRecord? = askScopeMeetingID(scope: context).flatMap { (id: String) -> MeetingRecord? in records.first { $0.id == id } }
    let options: [AskScope] = askScopeOptions(context: context, selected: selected, contextMeeting: contextMeeting, userName: userName)
    let titles: [String: String] = Dictionary(
        options.compactMap(askScopeMeetingID(scope:)).compactMap { (id: String) -> (String, String)? in
            records.first { $0.id == id }.map { (id, $0.note?.title ?? $0.title) }
        }
    ) { (first: String, _: String) -> String in first }
    return AskScopeMenu(
        context: context, selected: selected, options: options, folders: folders.filter { $0.count > 0 }.map(\.name),
        people: askScopePeople(records: records, userName: userName, limit: 12), meetingTitles: titles
    )
}

/// Kapsam çipi: vurgu renginde soluk kapsül (simge, kapsamın adı, aşağı ok), dokununca kapsam menüsü; kapsam tüm
/// toplantılar değilse yanında tek dokunuşla tüm toplantılara genişleten ✕.
public struct AskScopeChip: View {
    let menu: AskScopeMenu
    let isEnabled: Bool
    let onSelect: @MainActor (AskScope) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(menu: AskScopeMenu, isEnabled: Bool, onSelect: @escaping @MainActor (AskScope) -> Void) {
        self.menu = menu
        self.isEnabled = isEnabled
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 4) {
            Menu {
                Section {
                    ForEach(menu.options, id: \.self) { (scope: AskScope) in
                        option(scope: scope)
                    }
                }
                if !menu.folders.isEmpty {
                    Menu {
                        ForEach(menu.folders, id: \.self) { (name: String) in
                            option(scope: .folder(name: name))
                        }
                    } label: {
                        Label("Klasörler", systemImage: "folder")
                    }
                }
                if !menu.people.isEmpty {
                    Menu {
                        ForEach(menu.people, id: \.self) { (name: String) in
                            option(scope: .person(name: name))
                        }
                    } label: {
                        Label("Kişiler", systemImage: "person.2")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: askScopeSymbol(scope: menu.selected))
                        .appFont(size: 11, weight: .semibold)
                        .accessibilityHidden(true)
                    Text(verbatim: chipTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .appFont(size: 8, weight: .bold)
                        .accessibilityHidden(true)
                }
                .appFont(size: 12, weight: .medium)
                .foregroundStyle(appearance.accent.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(appearance.accent.color.opacity(0.10), in: Capsule())
                .contentShape(Capsule())
                .frame(minHeight: minimumHitSize)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("Sorunun kapsamı: \(title(scope: menu.selected))"))
            .hoverHint("Kapsamı değiştir", alignment: .leading, edge: .top)
            if menu.selected != .allMeetings {
                Button {
                    onSelect(.allMeetings)
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 9, weight: .bold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 20)
                        .background(Theme.soft, in: Circle())
                        .frame(minWidth: minimumHitSize, minHeight: minimumHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkPointer(isEnabled: isEnabled)
                .accessibilityLabel(Text("Tüm toplantılara genişlet"))
                .hoverHint("Tüm toplantılara genişlet", alignment: .leading, edge: .top)
            }
        }
        .disabled(!isEnabled)
    }

    /// Çipteki ad: kapsam bulunulan yerin kapsamıysa "Otomatik" (tüm toplantılar bağlamında yalnız o, başka yerde
    /// yanında kapsamın adı); seçilmiş kapsamda kapsamın adı.
    private var chipTitle: String {
        guard menu.selected == menu.context else {
            return title(scope: menu.selected)
        }
        let automatic: String = String(localized: "Otomatik")
        return menu.context == .allMeetings ? automatic : "\(automatic) · \(title(scope: menu.selected))"
    }

    private func title(scope: AskScope) -> String {
        askScopeTitle(scope: scope, context: menu.context, meetingTitle: askScopeMeetingID(scope: scope).flatMap { menu.meetingTitles[$0] })
    }

    private func option(scope: AskScope) -> some View {
        Button {
            onSelect(scope)
        } label: {
            if scope == menu.selected {
                Label(title(scope: scope), systemImage: "checkmark")
            } else {
                Label(title(scope: scope), systemImage: askScopeSymbol(scope: scope))
            }
        }
    }
}

/// Önerinin arayüz dilindeki sorusu (dokununca sorulan metin).
@MainActor
public func askSuggestionText(suggestion: AskSuggestion) -> String {
    switch suggestion {
    case .yesterday:
        return String(localized: "Dün ne konuştuk?")
    case .promises:
        return String(localized: "Kime ne söz verdim?")
    case .lastMeeting(let title):
        return String(localized: "\(title) toplantısında ne kararlaştırıldı?")
    case .lastPerson(let name):
        return String(localized: "\(name) ile en son ne konuştuk?")
    case .attention:
        return String(localized: "Neye dikkat etmeliyim?")
    }
}

/// Selamlamadaki ad: kullanıcının adının ilk kelimesi (boşsa boş). Saf fonksiyondur.
public func askFirstName(userName: String) -> String {
    userName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
}

/// Boş Sor'un selamlaması (Mac ve iPhone): ortada büyük, sıcak tek satır ("Merhaba Şenol, ne sormak istersin?"); ad
/// bilinmiyorsa yalnız soru. Uygulamanın yazı tipiyle, üstünde vurgu renginde küçük bir parıltı.
public struct AskGreeting: View {
    let firstName: String
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(firstName: String, size: CGFloat) {
        self.firstName = firstName
        self.size = size
    }

    public var body: some View {
        VStack(spacing: size * 0.4) {
            Image(systemName: "sparkle")
                .appFont(size: size * 0.8, weight: .semibold)
                .foregroundStyle(appearance.accent.color)
                .accessibilityHidden(true)
            Group {
                if firstName.isEmpty {
                    Text("Ne sormak istersin?")
                } else {
                    Text("Merhaba \(firstName), ne sormak istersin?")
                }
            }
            .appFont(size: size, weight: .semibold)
            .tracking(-0.4)
            .foregroundStyle(Theme.ink)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Soru alanının üstünde yana kayan öneri çipleri (Mac ve iPhone): kullanıcının verisinden sorular; dokununca sorulur.
public struct AskSuggestionRow: View {
    let suggestions: [String]
    let onPick: @MainActor (String) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(suggestions: [String], onPick: @escaping @MainActor (String) -> Void) {
        self.suggestions = suggestions
        self.onPick = onPick
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { (suggestion: String) in
                    Button {
                        onPick(suggestion)
                    } label: {
                        Text(verbatim: suggestion)
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Theme.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(appearance.accent.color.opacity(0.28)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .linkPointer(isEnabled: true)
                }
            }
            .padding(2)
        }
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Öneriler"))
    }
}
