import AINotepadCore
import SwiftUI

/// Çubuğun transkript düğmesi (yalnız toplantı sayfasında): çekmece açık mı ve aç/kapat.
public struct AskBarTranscript {
    let isOpen: Bool
    let onToggle: @MainActor () -> Void

    public init(isOpen: Bool, onToggle: @escaping @MainActor () -> Void) {
        self.isOpen = isOpen
        self.onToggle = onToggle
    }
}

/// Sayfanın altında yüzen Sor çubuğu (Mac ve iPhone; toplantı sayfası ve Mac'te ⌘J paneli): solda (toplantı
/// sayfasında) transkript çekmecesi düğmesi, ortada soru alanı, sağda tarifler ve gönder/durdur. Soru alanına girince
/// ya da bir cevap gelince üstünde bir panel açılır: üstte kapsam çipi (bu toplantı, tüm toplantılar, klasör, kişi,
/// tarih aralığı), sohbet (cevaplar kaynaklarıyla, devam soruları önceki cevapları bağlam alır) ve kapsam bu toplantıyken
/// hazır eylemler (takip e-postası, aksiyonlar, kısaca, notu uzat).
public struct AskBar: View {
    let exchanges: [ArchiveExchange]
    let isAnswering: Bool
    /// Son cevabın altındaki devam soruları (`meetingFollowUpSuggestions`); dokununca sorulur.
    let followUps: [String]
    let quickActions: [MeetingQuickAction]
    let recipes: [Recipe]
    /// Not şu an yeniden yazılıyor ("Notu uzat" ya da notu sorarak düzenleme).
    let isEditingNote: Bool
    let scopeMenu: AskScopeMenu
    /// Boş sohbette selamlamadaki ad (`askFirstName`) ve soru alanının üstündeki öneriler (kullanıcının verisinden).
    let firstName: String
    let suggestions: [String]
    let transcript: AskBarTranscript?
    /// Sohbet panelinin en çok yüksekliği (sayfanın yaklaşık %45'i: panel sayfayı örtmesin).
    let conversationMaxHeight: CGFloat
    /// Panel büyütülünce sohbetin en çok yüksekliği (uzun cevap rahat okunsun; bkz. `enlargedConversationMaxHeight`).
    let enlargedConversationMaxHeight: CGFloat
    /// Arttıkça soru alanı odağı alır ve panel açılır (Mac'te ⌘J).
    let focusRequest: Int
    let onSelectScope: @MainActor (AskScope) -> Void
    let onAsk: @MainActor (String, String?) -> Void
    let onQuickAction: @MainActor (MeetingQuickAction) -> Void
    let onStop: @MainActor () -> Void
    let onClear: @MainActor () -> Void
    let onRegenerate: @MainActor () -> Void
    let onOpenSource: @MainActor (ArchivePassage) -> Void
    let onSaveRecipe: @MainActor (String) -> Void
    /// Kapsam dipnotundaki "Bunlara da sor": aynı soru sığmayan toplantılara sorulur; cevap sürerken nil.
    let onAskMeetings: (@MainActor ([String]) -> Void)?
    @State private var draft: String = ""
    /// Sohbet paneli açık: sayfa tutar, transkript çekmecesiyle aynı anda açık olmaz (biri açılınca öteki kapanır).
    @Binding private var isExpanded: Bool
    /// Panel büyütüldü: sohbet sayfanın çoğunu alır.
    @State private var isEnlarged: Bool = false
    @FocusState private var isFocused: Bool
    /// VoiceOver odağı: yeni sorunun cevabına geçer.
    @AccessibilityFocusState private var focusedExchangeID: UUID?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        exchanges: [ArchiveExchange], isAnswering: Bool, followUps: [String], quickActions: [MeetingQuickAction], recipes: [Recipe], isEditingNote: Bool,
        scopeMenu: AskScopeMenu, firstName: String, suggestions: [String], transcript: AskBarTranscript?, isPanelOpen: Binding<Bool>, conversationMaxHeight: CGFloat,
        enlargedConversationMaxHeight: CGFloat, focusRequest: Int,
        onSelectScope: @escaping @MainActor (AskScope) -> Void,
        onAsk: @escaping @MainActor (String, String?) -> Void, onQuickAction: @escaping @MainActor (MeetingQuickAction) -> Void, onStop: @escaping @MainActor () -> Void,
        onClear: @escaping @MainActor () -> Void, onRegenerate: @escaping @MainActor () -> Void, onOpenSource: @escaping @MainActor (ArchivePassage) -> Void,
        onSaveRecipe: @escaping @MainActor (String) -> Void, onAskMeetings: (@MainActor ([String]) -> Void)?
    ) {
        self.exchanges = exchanges
        self.isAnswering = isAnswering
        self.followUps = followUps
        self.quickActions = quickActions
        self.recipes = recipes
        self.isEditingNote = isEditingNote
        self.scopeMenu = scopeMenu
        self.firstName = firstName
        self.suggestions = suggestions
        self.transcript = transcript
        self._isExpanded = isPanelOpen
        self.conversationMaxHeight = conversationMaxHeight
        self.enlargedConversationMaxHeight = enlargedConversationMaxHeight
        self.focusRequest = focusRequest
        self.onSelectScope = onSelectScope
        self.onAsk = onAsk
        self.onQuickAction = onQuickAction
        self.onStop = onStop
        self.onClear = onClear
        self.onRegenerate = onRegenerate
        self.onOpenSource = onOpenSource
        self.onSaveRecipe = onSaveRecipe
        self.onAskMeetings = onAskMeetings
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
                #if os(iOS)
                // iPhone'da klavye iner: cevap ekranın klavyeye kalan küçük parçasına sıkışmasın.
                isFocused = false
                #endif
                focusedExchangeID = exchanges.last?.id
            }
        }
        .onChange(of: isFocused) { (_: Bool, focused: Bool) -> Void in
            if focused {
                isExpanded = true
                #if os(iOS)
                // Klavye açılınca büyütülmüş panel sığmaz (ekranın üstünden taşar): olağan boyuna döner.
                isEnlarged = false
                #endif
            }
        }
        .onChange(of: focusRequest) { (_: Int, _: Int) -> Void in
            isExpanded = true
            isFocused = true
        }
    }

    /// Alttaki çubuk.
    private var bar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let transcript {
                transcriptButton(transcript: transcript)
            } else {
                Image(systemName: "sparkle")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 34, height: 34)
                    .frame(minWidth: minimumHitSize, minHeight: minimumHitSize)
                    .accessibilityHidden(true)
            }
            // Tek satırken yazı düğmelerle aynı hizada (ortada) durur; uzayınca yukarı büyür, düğmeler altta kalır.
            TextField(askScopePlaceholder(scope: scopeMenu.selected), text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .focused($isFocused)
                .appFont(size: 14, weight: .regular)
                .padding(.vertical, 7)
                .frame(minHeight: max(minimumHitSize, 34), alignment: .center)
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
                .hoverHint("Tarif uygula", alignment: .trailing, edge: .top)
            }
            sendButton
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
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

    /// Transkript çekmecesini açıp kapatan düğme (toplantı sayfası).
    private func transcriptButton(transcript: AskBarTranscript) -> some View {
        let isTranscriptOpen: Bool = transcript.isOpen
        return Button {
            // Çekmece açılırken sohbet paneli kapanır (ikisi birlikte sayfayı örterdi).
            if !isTranscriptOpen {
                isFocused = false
                isExpanded = false
            }
            transcript.onToggle()
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
                AskGreeting(firstName: firstName, size: 20)
                    .padding(.vertical, 6)
                if !suggestions.isEmpty {
                    AskSuggestionRow(suggestions: suggestions) { (suggestion: String) -> Void in onAsk(suggestion, nil) }
                }
                Text(askScopeMeetingID(scope: scopeMenu.selected) != nil
                    ? "Kararlar, görevler ya da kimin ne dediği: cevap bu toplantının notundan ve transkriptinden, kaynağıyla gelir."
                    : "Kararlar, görevler ya da kimin ne dediği: cevap kapsamdaki toplantıların notlarından ve transkriptlerinden, kaynağıyla gelir.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                conversation
                // Klavye açıkken (iPhone) çipler gizlenir: klavyenin üstünde kalan az yer cevaba kalsın.
                if !isAnswering, !followUps.isEmpty, !isKeyboardUp {
                    followUpChips
                }
            }
            if isEditingNote {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    ShimmerText(text: Text("Not düzenleniyor…"))
                        .appFont(size: 13, weight: .medium)
                }
            }
            if !quickActions.isEmpty, !isKeyboardUp {
                quickActionChips
            }
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

    /// iPhone'da soru alanı odakta: klavye açık (Mac'te klavye ekranı örtmez).
    private var isKeyboardUp: Bool {
        #if os(iOS)
        isFocused
        #else
        false
        #endif
    }

    private var panelHeader: some View {
        HStack(spacing: headerSpacing) {
            // Kapsam adı kısalmasın: düğmeler dar kalır, çip önce yer alır.
            AskScopeChip(menu: scopeMenu, isEnabled: !isAnswering, onSelect: onSelectScope)
                .layoutPriority(1)
            Spacer(minLength: 4)
            // Klavye açıkken (iPhone) büyütme yerine klavyeyi indirme düğmesi: cevabı okumak için tek dokunuş (kaydırınca da
            // iner). Başlıkta en çok üç düğme kalır, kapsam çipi kısalmaz.
            if isKeyboardUp {
                Button {
                    isFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .frame(minWidth: headerHitWidth, minHeight: minimumHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(Text("Klavyeyi gizle"))
            } else if !exchanges.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.25)) { isEnlarged.toggle() }
                } label: {
                    Image(systemName: isEnlarged ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .frame(minWidth: headerHitWidth, minHeight: minimumHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(isEnlarged ? Text("Paneli küçült") : Text("Paneli büyüt"))
                .hoverHint(isEnlarged ? "Paneli küçült" : "Paneli büyüt", alignment: .trailing, edge: .bottom)
            }
            if !exchanges.isEmpty {
                Button {
                    // Yeni sohbet olağan boyda başlar (büyütme düğmesi boş sohbette görünmez).
                    isEnlarged = false
                    onClear()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .frame(minWidth: headerHitWidth, minHeight: minimumHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(Text("Yeni sohbet"))
                .hoverHint("Yeni sohbet", alignment: .trailing, edge: .bottom)
            }
            Button {
                isFocused = false
                isExpanded = false
                isEnlarged = false
            } label: {
                Image(systemName: "chevron.down")
                    .frame(minWidth: headerHitWidth, minHeight: minimumHitSize)
                    .contentShape(Rectangle())
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
            // Cevabı okurken kaydırmak klavyeyi indirir.
            .scrollDismissesKeyboard(.interactively)
            // Klavye açıkken çipler gizli: klavyenin üstünde kalan yerin çoğunu cevap alır (büyütülmüş paneldeki gibi).
            .frame(maxHeight: isEnlarged || isKeyboardUp ? enlargedConversationMaxHeight : conversationMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo(exchanges.last?.id, anchor: .bottom) }
            .onChange(of: exchanges.last?.answer.text) { (_: String?, _: String?) -> Void in
                proxy.scrollTo(exchanges.last?.id, anchor: .bottom)
            }
            // Yeni soru ve cevabın bitişi (hata satırı, kaynaklar, düğmeler) de görünsün: yalnız akan metin izlenirse
            // hatayla biten cevabın satırı sohbetin altında kesik kalıyordu.
            .onChange(of: exchanges.count) { (_: Int, _: Int) -> Void in
                proxy.scrollTo(exchanges.last?.id, anchor: .bottom)
            }
            .onChange(of: exchanges.last?.phase) { (_: ArchiveExchange.Phase?, _: ArchiveExchange.Phase?) -> Void in
                withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(exchanges.last?.id, anchor: .bottom) }
            }
        }
    }

    private func exchangeView(exchange: ArchiveExchange) -> some View {
        let regenerate: (@MainActor () -> Void)? = exchange.id == exchanges.last?.id ? onRegenerate : nil
        return ExchangeView(exchange: exchange, onOpen: onOpenSource, onSaveRecipe: onSaveRecipe, onRegenerate: regenerate, onAskMeetings: isAnswering ? nil : onAskMeetings)
            .id(exchange.id)
            .accessibilityFocused($focusedExchangeID, equals: exchange.id)
    }

    private var followUpChips: some View {
        AskFollowUpChips(questions: followUps) { (question: String) -> Void in onAsk(question, nil) }
            .disabled(isEditingNote)
    }

    private var quickActionChips: some View {
        AskQuickActionChips(actions: quickActions, isEnabled: !isAnswering && !isEditingNote, onRun: onQuickAction)
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

/// Devam soruları (Mac ve iPhone; toplantı çubuğu ve Sor sayfası): vurgu renginde çipler, dokununca sorulur.
public struct AskFollowUpChips: View {
    let questions: [String]
    let onAsk: @MainActor (String) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(questions: [String], onAsk: @escaping @MainActor (String) -> Void) {
        self.questions = questions
        self.onAsk = onAsk
    }

    public var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(questions, id: \.self) { (question: String) in
                Button {
                    onAsk(question)
                } label: {
                    Label(question, systemImage: "arrow.turn.down.right")
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(appearance.accent.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(appearance.accent.color.opacity(0.10), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .linkPointer(isEnabled: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Devam soruları"))
    }
}

/// Toplantının hazır eylemleri (Mac ve iPhone; kapsam bir toplantıyken): sade çipler.
public struct AskQuickActionChips: View {
    let actions: [MeetingQuickAction]
    let isEnabled: Bool
    let onRun: @MainActor (MeetingQuickAction) -> Void

    public init(actions: [MeetingQuickAction], isEnabled: Bool, onRun: @escaping @MainActor (MeetingQuickAction) -> Void) {
        self.actions = actions
        self.isEnabled = isEnabled
        self.onRun = onRun
    }

    public var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(actions) { (action: MeetingQuickAction) in
                Button {
                    onRun(action)
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
                .linkPointer(isEnabled: isEnabled)
                .disabled(!isEnabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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
        // Liste çizildikten sonra kaysın (ilk açılışta kimlik henüz yerleşmemiş olur). Paragraf en üstte durur: ortaya
        // kayınca üstteki paragrafın konuşmacı satırı kenarda yarım kesik görünüyordu.
        Task { @MainActor in
            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(id, anchor: .top) }
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
/// Panel başlığındaki simge düğmelerinin dokunma genişliği: yükseklik 44 pt, yan yana dört düğme kapsam çipini
/// kısaltmasın diye genişlik daha dar.
let headerHitWidth: CGFloat = 36
/// Panel başlığındaki öğelerin arası (iPhone'da dokunma alanları zaten boşluk bırakır).
let headerSpacing: CGFloat = 0
#else
let minimumHitSize: CGFloat = 0
let headerHitWidth: CGFloat = 0
let headerSpacing: CGFloat = 8
#endif

/// Büyütülen sohbet panelinde sohbetin en çok yüksekliği: sayfadan panelin başlığı, çipleri ve soru çubuğu (`chrome`)
/// çıkınca kalan, en az 160 pt (klavye açıkken de panel ekranın üstünden taşmasın). Saf fonksiyondur.
public func enlargedConversationMaxHeight(pageHeight: CGFloat, chrome: CGFloat) -> CGFloat {
    max(160, (pageHeight - chrome).rounded())
}

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
