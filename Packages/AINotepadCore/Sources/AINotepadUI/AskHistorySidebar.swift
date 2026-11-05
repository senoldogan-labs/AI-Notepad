import AINotepadCore
import SwiftUI

/// Mac'te Sor sayfasının solundaki sohbet geçmişi sütunu: başlık, arama alanı ve süzgeç menüsü, seçili süzgecin çipi ve
/// tam açıklaması, altında yeniden eskiye sohbetler (simge, başlık, tarih); açık sohbet gri hap. Üzerine gelince ad
/// değiştirme ve silme simgeleri çıkar; silmede ilk tık "Sil" onayına döner, ikinci tık siler (açılır pencere yok). Ad,
/// satırda yerinde düzenlenir (çift tıklama, kalem simgesi ya da sağ tık › "Yeniden adlandır").
public struct AskHistorySidebar: View {
    let conversations: [AskConversation]
    let selectedID: UUID?
    let onOpen: @MainActor (UUID) -> Void
    let onRename: @MainActor (UUID, String) -> Void
    let onDelete: @MainActor (UUID) -> Void
    @State private var query: String = ""
    @State private var filter: AskHistoryFilter = .all
    /// Adı yerinde düzenlenen sohbet.
    @State private var renamingID: UUID?

    public init(
        conversations: [AskConversation], selectedID: UUID?, onOpen: @escaping @MainActor (UUID) -> Void,
        onRename: @escaping @MainActor (UUID, String) -> Void, onDelete: @escaping @MainActor (UUID) -> Void
    ) {
        self.conversations = conversations
        self.selectedID = selectedID
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        let shown: [AskConversation] = filteredAskConversations(conversations: conversations, query: query, filter: filter)
        VStack(alignment: .leading, spacing: 0) {
            Text("GEÇMİŞ")
                .appFont(size: 11, weight: .semibold)
                .tracking(DesignTokens.labelTracking)
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                AskHistorySearchBar(query: $query, filter: $filter, size: 13)
                if filter != .all {
                    AskHistoryFilterChip(filter: filter, size: 12) { filter = .all }
                    Text(askHistoryFilterHelp(filter: filter))
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if shown.isEmpty {
                        AskHistoryNoMatches(size: 13)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                    }
                    ForEach(shown) { (conversation: AskConversation) in
                        AskHistorySidebarRow(
                            conversation: conversation, isSelected: selectedID == conversation.id,
                            isRenaming: Binding<Bool>(
                                get: { renamingID == conversation.id },
                                set: { (renaming: Bool) -> Void in renamingID = renaming ? conversation.id : nil }
                            ),
                            onOpen: { onOpen(conversation.id) },
                            onRename: { (title: String) -> Void in onRename(conversation.id, title) },
                            onDelete: { onDelete(conversation.id) }
                        )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)
        }
        .frame(width: 248)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }
}

/// Geçmişte bir sohbet satırı: simge, başlık (iki satıra kadar) ve son güncelleme tarihi; üzerine gelince ad değiştirme
/// ve silme. Ad değiştirilirken başlığın yerinde yazı alanı: Return kaydeder, Esc vazgeçer, alandan çıkınca kaydedilir.
public struct AskHistorySidebarRow: View {
    let conversation: AskConversation
    let isSelected: Bool
    @Binding var isRenaming: Bool
    let onOpen: @MainActor () -> Void
    let onRename: @MainActor (String) -> Void
    let onDelete: @MainActor () -> Void
    @State private var isHovering: Bool = false
    @State private var isConfirmingDelete: Bool = false
    @State private var draft: String = ""
    @FocusState private var isTitleFocused: Bool

    public init(
        conversation: AskConversation, isSelected: Bool, isRenaming: Binding<Bool>, onOpen: @escaping @MainActor () -> Void,
        onRename: @escaping @MainActor (String) -> Void, onDelete: @escaping @MainActor () -> Void
    ) {
        self.conversation = conversation
        self.isSelected = isSelected
        _isRenaming = isRenaming
        self.onOpen = onOpen
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if isRenaming {
                renameField
            } else {
                Button(action: onOpen) {
                    AskHistoryRowLabel(conversation: conversation, isSelected: isSelected, titleSize: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture(count: 2).onEnded { isRenaming = true })
                if isHovering || isConfirmingDelete {
                    actions
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onHover { (hovering: Bool) -> Void in
            isHovering = hovering
            if !hovering {
                isConfirmingDelete = false
            }
        }
        .contextMenu {
            Button("Yeniden adlandır", systemImage: "pencil") { isRenaming = true }
            Button("Sohbeti sil", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .onChange(of: isRenaming, initial: true) { (_: Bool, renaming: Bool) in
            if renaming {
                draft = askConversationDisplayTitle(conversation: conversation)
                isTitleFocused = true
            }
        }
    }

    private var renameField: some View {
        HStack(alignment: .center, spacing: 10) {
            AccentSymbolTile(symbol: askConversationSymbol(conversation: conversation), size: 28)
            TextField("Sohbetin adı", text: $draft)
                .textFieldStyle(.plain)
                .appFont(size: 13, weight: .regular)
                .focused($isTitleFocused)
                .onSubmit { finishRename() }
                #if os(macOS)
                .onExitCommand { isRenaming = false }
                #endif
                .onChange(of: isTitleFocused) { (_: Bool, focused: Bool) in
                    if !focused {
                        finishRename()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line))
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if !isConfirmingDelete {
                Button {
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                        .appFont(size: 11, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .frame(minWidth: 22, minHeight: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel("Yeniden adlandır")
            }
            Button {
                if isConfirmingDelete {
                    onDelete()
                } else {
                    isConfirmingDelete = true
                }
            } label: {
                Group {
                    if isConfirmingDelete {
                        Text("Sil").appFont(size: 11, weight: .semibold).foregroundStyle(.red)
                    } else {
                        Image(systemName: "trash").appFont(size: 11, weight: .medium).foregroundStyle(Theme.muted)
                    }
                }
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.hoverPlain)
            .accessibilityLabel("Sohbeti sil")
        }
    }

    /// Yazılan adı kaydeder (boş ya da aynı ad yok sayılır, bkz. `renamedAskConversation`) ve düzenlemeyi kapatır.
    private func finishRename() {
        guard isRenaming else {
            return
        }
        isRenaming = false
        onRename(draft)
    }
}
