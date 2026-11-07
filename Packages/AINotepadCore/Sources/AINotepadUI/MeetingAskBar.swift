import AINotepadCore
import SwiftUI

/// Toplantı sayfasının altında yüzen "Bir şey sor" çubuğu (Mac ve iPhone): solda transkript çekmecesi düğmesi, ortada
/// soru alanı, sağda tarifler ve gönder/durdur. Soru alanına girince ya da bir cevap gelince üstünde bir panel açılır:
/// bu toplantının sohbeti (cevaplar kaynaklarıyla, devam soruları önceki cevapları bağlam alır) ve hazır eylemler
/// (takip e-postası, aksiyonlar, kısaca, notu uzat).
public struct MeetingAskBar: View {
    let exchanges: [ArchiveExchange]
    let isAnswering: Bool
    let quickActions: [MeetingQuickAction]
    let recipes: [Recipe]
    /// Not şu an yeniden yazılıyor ("Notu uzat" ya da notu sorarak düzenleme).
    let isEditingNote: Bool
    let isTranscriptOpen: Bool
    /// Sohbet panelinin en çok yüksekliği (sayfanın yaklaşık %45'i: panel sayfayı örtmesin).
    let conversationMaxHeight: CGFloat
    let onAsk: @MainActor (String, String?) -> Void
    let onQuickAction: @MainActor (MeetingQuickAction) -> Void
    let onStop: @MainActor () -> Void
    let onClear: @MainActor () -> Void
    let onRegenerate: @MainActor () -> Void
    let onOpenSource: @MainActor (ArchivePassage) -> Void
    let onSaveRecipe: @MainActor (String) -> Void
    let onToggleTranscript: @MainActor () -> Void
    @State private var draft: String = ""
    /// Sohbet paneli açık: sayfa tutar, transkript çekmecesiyle aynı anda açık olmaz (biri açılınca öteki kapanır).
    @Binding private var isExpanded: Bool
    @FocusState private var isFocused: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        exchanges: [ArchiveExchange], isAnswering: Bool, quickActions: [MeetingQuickAction], recipes: [Recipe], isEditingNote: Bool, isTranscriptOpen: Bool,
        isPanelOpen: Binding<Bool>, conversationMaxHeight: CGFloat,
        onAsk: @escaping @MainActor (String, String?) -> Void, onQuickAction: @escaping @MainActor (MeetingQuickAction) -> Void, onStop: @escaping @MainActor () -> Void,
        onClear: @escaping @MainActor () -> Void, onRegenerate: @escaping @MainActor () -> Void, onOpenSource: @escaping @MainActor (ArchivePassage) -> Void,
        onSaveRecipe: @escaping @MainActor (String) -> Void, onToggleTranscript: @escaping @MainActor () -> Void
    ) {
        self.exchanges = exchanges
        self.isAnswering = isAnswering
        self.quickActions = quickActions
        self.recipes = recipes
        self.isEditingNote = isEditingNote
        self.isTranscriptOpen = isTranscriptOpen
        self._isExpanded = isPanelOpen
        self.conversationMaxHeight = conversationMaxHeight
        self.onAsk = onAsk
        self.onQuickAction = onQuickAction
        self.onStop = onStop
        self.onClear = onClear
        self.onRegenerate = onRegenerate
        self.onOpenSource = onOpenSource
        self.onSaveRecipe = onSaveRecipe
        self.onToggleTranscript = onToggleTranscript
    }

    public var body: some View {
        VStack(spacing: 8) {
            if isExpanded {
                panel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bar
        }
        .frame(maxWidth: 700)
        .animation(.smooth(duration: 0.25), value: isExpanded)
        .onChange(of: exchanges.count) { (old: Int, new: Int) -> Void in
            // Yeni soru (kaynak kutusundaki "Sor" da) paneli açar.
            if new > old {
                isExpanded = true
            }
        }
        .onChange(of: isFocused) { (_: Bool, focused: Bool) -> Void in
            if focused {
                isExpanded = true
            }
        }
    }

    /// Alttaki çubuk.
    private var bar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                // Çekmece açılırken sohbet paneli kapanır (ikisi birlikte sayfayı örterdi).
                if !isTranscriptOpen {
                    isFocused = false
                    isExpanded = false
                }
                onToggleTranscript()
            } label: {
                Image(systemName: "text.bubble")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(isTranscriptOpen ? appearance.accent.color : Theme.ink)
                    .frame(width: 34, height: 34)
                    .background(isTranscriptOpen ? appearance.accent.color.opacity(0.14) : Theme.soft, in: Circle())
                    .frame(minWidth: minimumHitSize, minHeight: minimumHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .linkPointer(isEnabled: true)
            .accessibilityLabel(isTranscriptOpen ? Text("Transkripti kapat") : Text("Transkripti aç"))
            .hoverHint(isTranscriptOpen ? "Transkripti kapat" : "Transkripti aç", alignment: .leading, edge: .top)
            TextField("Bu toplantıya bir şey sor", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isFocused)
                .appFont(size: 14, weight: .regular)
                .padding(.vertical, 8)
                .onSubmit { submit() }
                #if os(macOS)
                .onExitCommand {
                    isFocused = false
                    isExpanded = false
                }
                #endif
            if !recipes.isEmpty {
                Menu {
                    ForEach(recipes) { (recipe: Recipe) in
                        Button(recipe.title, systemImage: recipe.symbol) { onAsk(recipe.prompt, recipe.title) }
                    }
                } label: {
                    Image(systemName: "wand.and.stars")
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 34)
                        .frame(minWidth: minimumHitSize, minHeight: minimumHitSize)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(isAnswering)
                .accessibilityLabel(Text("Tarif uygula"))
                .hoverHint("Bu toplantıya tarif uygula", alignment: .trailing, edge: .top)
            }
            sendButton
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 23, style: .continuous).strokeBorder(Theme.line)
        }
        .overlay {
            if isAnswering {
                ThinkingRing(shape: RoundedRectangle(cornerRadius: 23, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        if isAnswering {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 34, height: 34)
                    .background(Theme.primary, in: Circle())
                    .frame(minWidth: minimumHitSize, minHeight: minimumHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Durdur"))
        } else {
            let canSend: Bool = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .appFont(size: 14, weight: .bold)
                    .foregroundStyle(canSend ? Theme.onPrimary : Theme.muted)
                    .frame(width: 34, height: 34)
                    .background(canSend ? Theme.primary : Theme.soft, in: Circle())
                    .frame(minWidth: minimumHitSize, minHeight: minimumHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel(Text("Sor"))
        }
    }

    /// Çubuğun üstündeki panel: başlık satırı (yeni sohbet, kapat), sohbet ve hazır eylemler.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelHeader
            if exchanges.isEmpty {
                Text("Kararlar, görevler ya da kimin ne dediği: cevap bu toplantının notundan ve transkriptinden, kaynağıyla gelir.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                conversation
            }
            if isEditingNote {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    ShimmerText(text: Text("Not düzenleniyor…"))
                        .appFont(size: 13, weight: .medium)
                }
            }
            quickActionChips
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line)
        }
    }

    private var panelHeader: some View {
        HStack(spacing: 8) {
            Label("Bu toplantıya sor", systemImage: "sparkle")
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            if !exchanges.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(Text("Yeni sohbet"))
                .hoverHint("Yeni sohbet", alignment: .trailing, edge: .bottom)
            }
            Button {
                isFocused = false
                isExpanded = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.hoverPlain)
            .accessibilityLabel(Text("Paneli kapat"))
            .hoverHint("Paneli kapat", alignment: .trailing, edge: .bottom)
        }
        .appFont(size: 12, weight: .semibold)
    }

    /// Sohbet: sorular ve cevaplar; akan cevap izlenir.
    private var conversation: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(exchanges) { (exchange: ArchiveExchange) in
                        exchangeView(exchange: exchange)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: conversationMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo(exchanges.last?.id, anchor: .bottom) }
            .onChange(of: exchanges.last?.answer.text) { (_: String?, _: String?) -> Void in
                proxy.scrollTo(exchanges.last?.id, anchor: .bottom)
            }
        }
    }

    private func exchangeView(exchange: ArchiveExchange) -> some View {
        let regenerate: (@MainActor () -> Void)? = exchange.id == exchanges.last?.id ? onRegenerate : nil
        return ExchangeView(exchange: exchange, onOpen: onOpenSource, onSaveRecipe: onSaveRecipe, onRegenerate: regenerate, onAskMeetings: nil)
            .id(exchange.id)
    }

    /// Hazır eylemler: çipler.
    private var quickActionChips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(quickActions) { (action: MeetingQuickAction) in
                Button {
                    onQuickAction(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.soft, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .linkPointer(isEnabled: true)
                .disabled(isAnswering || isEditingNote)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func submit() {
        let question: String = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAnswering else {
            return
        }
        onAsk(question, nil)
        draft = ""
    }
}

/// Transkript çekmecesi (Mac ve iPhone): çubuğun üstünden kayarak açılır. Arama, konuşmacı balonları (sen sağda vurgu
/// renginde, diğerleri solda kendi renklerinde), zamanlar; zamana tıklayınca oradan çalar. Kaynak kutusundan gelinince
/// o paragrafa kayar ve kısa süre vurgulanır.
public struct TranscriptDrawer: View {
    let paragraphs: [TranscriptParagraph]
    let speakerNames: [Int: String]
    /// Kayılacak ve vurgulanacak paragraf (kaynak kutusundan).
    let focusID: String?
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    let onClose: @MainActor () -> Void
    @State private var query: String = ""
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        paragraphs: [TranscriptParagraph], speakerNames: [Int: String], focusID: String?, canPlay: Bool, onPlay: @escaping @MainActor (Double) -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.paragraphs = paragraphs
        self.speakerNames = speakerNames
        self.focusID = focusID
        self.canPlay = canPlay
        self.onPlay = onPlay
        self.onClose = onClose
    }

    public var body: some View {
        let shown: [TranscriptParagraph] = transcriptMatches(paragraphs: paragraphs, query: query)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Transkript")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.muted)
                    TextField("Transkriptte ara", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Text(verbatim: "\(shown.count)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                }
                .appFont(size: 13, weight: .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.soft, in: Capsule())
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.hoverPlain)
                .appFont(size: 12, weight: .semibold)
                .accessibilityLabel(Text("Transkripti kapat"))
            }
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if shown.isEmpty {
                            Text(paragraphs.isEmpty ? "Bu toplantının metni yok" : "Eşleşen söz yok")
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        }
                        ForEach(shown) { (paragraph: TranscriptParagraph) in
                            bubble(paragraph: paragraph)
                                .id(paragraph.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onAppear { scroll(proxy: proxy, to: focusID) }
                .onChange(of: focusID) { (_: String?, id: String?) -> Void in scroll(proxy: proxy, to: id) }
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.card)
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line)
        }
    }

    private func scroll(proxy: ScrollViewProxy, to id: String?) {
        guard let id else {
            return
        }
        // Liste çizildikten sonra kaysın (ilk açılışta kimlik henüz yerleşmemiş olur).
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        }
    }

    /// Konuşmacı balonu: kullanıcınınki sağda vurgu renginde, diğerleri solda; üstte ad ve zaman.
    private func bubble(paragraph: TranscriptParagraph) -> some View {
        let isMe: Bool = paragraph.speaker == .me && paragraph.person == nil
        let color: Color = paragraph.person.map { personColor(person: $0) } ?? appearance.accent.color
        let isFocused: Bool = paragraph.id == focusID
        return VStack(alignment: isMe ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: paragraphLabel(paragraph: paragraph, speakerNames: speakerNames))
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(isMe ? Theme.ink : color)
                Button {
                    onPlay(paragraph.startSec)
                } label: {
                    HStack(spacing: 3) {
                        if canPlay {
                            Image(systemName: "play.fill").appFont(size: 7, weight: .bold)
                        }
                        Text(verbatim: timestamp(seconds: paragraph.startSec)).monospacedDigit()
                    }
                    .appFont(size: 11, weight: .medium)
                    .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .linkPointer(isEnabled: canPlay)
                .accessibilityLabel(Text("Buradan dinle"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(paragraph.text)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                if let translated = paragraph.turkish {
                    Text(translated)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isMe ? appearance.accent.color.opacity(0.12) : Theme.soft,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isFocused ? appearance.accent.color : Color.clear, lineWidth: 1.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .padding(isMe ? .leading : .trailing, 40)
    }
}

/// Dokunma hedefinin en küçük boyu: iPhone'da 44 pt (Apple HIG), Mac'te çizildiği kadar.
#if os(iOS)
let minimumHitSize: CGFloat = 44
#else
let minimumHitSize: CGFloat = 0
#endif

/// Sayfanın altındaki sohbet paneli ya da transkript çekmecesinin en çok yüksekliği: sayfanın %45'i, en çok `cap`
/// (sayfa yüksekliği henüz ölçülmediyse `cap`). Saf fonksiyondur.
public func bottomPanelMaxHeight(pageHeight: CGFloat, cap: CGFloat) -> CGFloat {
    pageHeight > 0 ? min(cap, (pageHeight * 0.45).rounded()) : cap
}

/// İçeriği kendi gövdesinde kuran kap: içerikte okunan gözlenen değerler (ör. akan Sor cevabı) yalnız bu kabı yeniden
/// çizer, onu kuran sayfayı değil. Toplantı sayfası her cevap parçasında bütün transkripti yeniden hesaplamasın diye.
public struct ObservationScope<Content: View>: View {
    let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        content()
    }
}
