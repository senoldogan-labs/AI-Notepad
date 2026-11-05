import AINotepadCore
import SwiftUI

// Sor sohbet geçmişi (Mac'te Sor sayfasının solundaki sütun, iPhone'da "Geçmiş" ekranı): arama alanı ve tek süzgeç
// menüsü, satırlarda sohbetin türünü gösteren vurgu renkli simge, başlık ve tarih. Süzme ve ad değiştirme
// `AskHistory.swift`'teki saf fonksiyonlardadır; buradaki görünümler yalnız çizer.

/// Sohbetin simgesi: web kaynaklı cevabı varsa küre, `@` ile toplantılara sorulduysa @, tariften başladıysa sihirli
/// değnek, yoksa (tüm arşive sorulan) iki konuşma balonu. Saf fonksiyondur.
public func askConversationSymbol(conversation: AskConversation) -> String {
    if askConversationUsedWeb(conversation: conversation) {
        return "globe"
    }
    if askConversationAskedMeetings(conversation: conversation) {
        return "at"
    }
    if conversation.turns.first?.recipeTitle != nil {
        return "wand.and.stars"
    }
    return "bubble.left.and.text.bubble.right"
}

/// Süzgecin menüdeki ve çipteki adı.
public func askHistoryFilterTitle(filter: AskHistoryFilter) -> LocalizedStringKey {
    switch filter {
    case .all: "Tüm sohbetler"
    case .meetings: "Toplantıya sorulanlar"
    case .web: "Web'den cevaplananlar"
    }
}

/// Süzgecin simgesi (satırlardaki sohbet simgeleriyle aynı).
public func askHistoryFilterSymbol(filter: AskHistoryFilter) -> String {
    switch filter {
    case .all: "bubble.left.and.text.bubble.right"
    case .meetings: "at"
    case .web: "globe"
    }
}

/// Süzgecin tam açıklaması (Mac'te çipin altında satır içi).
public func askHistoryFilterHelp(filter: AskHistoryFilter) -> LocalizedStringKey {
    switch filter {
    case .all: "Saklanan tüm sohbetler, en son güncellenen önce."
    case .meetings: "Yalnız @ ile belirli toplantılara sorulan sohbetler."
    case .web: "Yalnız cevabında web sayfası kaynak gösterilen sohbetler."
    }
}

/// Geçmiş satırının içeriği: vurgu renkli tür simgesi, başlık (iki satıra kadar) ve son güncellenme tarihi.
public struct AskHistoryRowLabel: View {
    let conversation: AskConversation
    let isSelected: Bool
    /// Başlığın punto değeri; tarih ve simge buna göre (Mac 13, iPhone 15).
    let titleSize: CGFloat

    public init(conversation: AskConversation, isSelected: Bool, titleSize: CGFloat) {
        self.conversation = conversation
        self.isSelected = isSelected
        self.titleSize = titleSize
    }

    public var body: some View {
        HStack(alignment: .top, spacing: titleSize * 0.75) {
            AccentSymbolTile(symbol: askConversationSymbol(conversation: conversation), size: (titleSize * 2.15).rounded())
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: askConversationDisplayTitle(conversation: conversation))
                    .appFont(size: titleSize, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(conversation.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                    .appFont(size: titleSize - 2, weight: .regular)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Geçmişin arama alanı ve sağında süzgeç menüsü (Mac ve iPhone aynı): beyaz alan, ince çerçeve; süzgeç seçiliyken menü
/// simgesi vurgu renginde doludur.
public struct AskHistorySearchBar: View {
    @Binding var query: String
    @Binding var filter: AskHistoryFilter
    /// Yazının punto değeri (Mac 13, iPhone 15).
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(query: Binding<String>, filter: Binding<AskHistoryFilter>, size: CGFloat) {
        _query = query
        _filter = filter
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .appFont(size: size - 1, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
                TextField("Sohbetlerde ara", text: $query)
                    .textFieldStyle(.plain)
                    .appFont(size: size, weight: .regular)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .appFont(size: size - 1, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Aramayı temizle")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, size * 0.55)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            Menu {
                Picker(selection: $filter) {
                    ForEach(AskHistoryFilter.allCases, id: \.self) { (option: AskHistoryFilter) in
                        Label(askHistoryFilterTitle(filter: option), systemImage: askHistoryFilterSymbol(filter: option)).tag(option)
                    }
                } label: {
                    Text("Sohbetleri süz")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .appFont(size: size + 5, weight: .regular)
                    .foregroundStyle(appearance.accent.color)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Sohbetleri süz")
            .accessibilityValue(Text(askHistoryFilterTitle(filter: filter)))
        }
    }
}

/// Seçili süzgeç (tümü değilken): vurgu renkli çip, dokununca süzgeç kalkar.
public struct AskHistoryFilterChip: View {
    let filter: AskHistoryFilter
    let size: CGFloat
    let onClear: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(filter: AskHistoryFilter, size: CGFloat, onClear: @escaping @MainActor () -> Void) {
        self.filter = filter
        self.size = size
        self.onClear = onClear
    }

    public var body: some View {
        Button(action: onClear) {
            HStack(spacing: 5) {
                Image(systemName: askHistoryFilterSymbol(filter: filter))
                    .appFont(size: size - 1, weight: .semibold)
                Text(askHistoryFilterTitle(filter: filter))
                    .appFont(size: size, weight: .medium)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .appFont(size: size - 3, weight: .bold)
                    .opacity(0.7)
            }
            .foregroundStyle(appearance.accent.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(appearance.accent.color.opacity(0.11), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkPointer(isEnabled: true)
        .accessibilityLabel(Text(askHistoryFilterTitle(filter: filter)))
        .accessibilityHint(Text("Süzgeci kaldırır"))
    }
}

/// Aramaya ya da süzgece uyan sohbet yok: kısa, sakin bir satır.
public struct AskHistoryNoMatches: View {
    let size: CGFloat

    public init(size: CGFloat) {
        self.size = size
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Eşleşen sohbet yok")
                .appFont(size: size, weight: .medium)
                .foregroundStyle(Theme.ink)
            Text("Aramayı ya da süzgeci değiştir.")
                .appFont(size: size - 1, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
