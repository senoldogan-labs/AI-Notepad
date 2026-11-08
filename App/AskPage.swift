import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Toplantılarıma sor: sohbet geçmişinin ve toplantılar arası soruların evi. Soru alanının üstündeki kapsam çipi soruyu
/// tüm toplantılara, bir toplantıya, klasöre, kişiye ya da tarih aralığına sorar; kapsam bir toplantıysa hazır eylemler
/// ve devam soruları da görünür. Toplantı sayfasında, klasörde ya da kişide sorulan sohbetler de geçmişte kapsamıyla
/// görünür ve açılınca o kapsamla sürer. Sohbet, sade bir LLM akışı gibi: çalışırken tek satır
/// parıltılı "Düşünüyor…", cevap akarak yumuşakça gelir, altında küçük ve kapalı "Kaynaklar" ve "nasıl cevaplandı"
/// satırları; metindeki [1] işaretleri toplantıyı açar. Devam soruları önceki cevapları bağlam alır. Boşken sakin
/// başlık, örnek soru hapları ve son sohbetler. Sohbetler saklanır; "Geçmiş" soldaki ince sütunda açılır (yeniden aç, sil).
///
/// Soru alanı: Enter gönderir, Shift+Enter yeni satır. `@` yazınca alanın üstünde toplantı önerileri açılır (yazdıkça
/// süzülür; ↑/↓ gezinir, Tab ya da Enter seçer, Esc kapatır); seçilen toplantı alanda kaldırılabilir etiket olur ve soru
/// yalnız etiketli toplantılara sorulur; etiketler devam sorularında da kalır (kaldırılana dek). Boş alanda ↑ son soruyu
/// düzenlemeye getirir; öneri kapalıyken Esc alanı ve etiketleri temizler.
struct AskPage: View {
    let model: AppModel
    let router: MainWindowRouter
    /// Hiç toplantı yokken boş sayfadaki "Kaydı başlat".
    let onStartRecording: @MainActor () -> Void
    @State private var question: String = ""
    /// Soru alanında imlecin konumu (UTF-16): `@` bahsi imlecin önünde aranır.
    @State private var cursor: Int = 0
    /// `@` ile etiketlenen toplantılar: soru yalnız onlara sorulur; soru gönderilince alandan kalkar.
    @State private var mentioned: [MeetingRecord] = []
    /// `@` ya da "/" önerilerinde klavyeyle seçili satır.
    @State private var highlighted: Int = 0
    /// Esc ile kapatılan `@` bahsinin başlangıcı: aynı bahiste öneriler yeniden açılmaz (yeni `@` açar).
    @State private var dismissedMentionStart: Int?
    /// "/" önerileri Esc ile kapatıldı: soru "/" ile başladıkça yeniden açılmaz.
    @State private var isRecipeDismissed: Bool = false
    @State private var isFocused: Bool = false
    /// Arttıkça soru alanı odağı alır.
    @State private var focusRequest: Int = 0
    /// Sohbetin sonu görünüyor: akan cevap izlenir; kullanıcı yukarı kaydırınca izleme durur, "sona git" düğmesi çıkar.
    @State private var isFollowingAnswer: Bool = true
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// Soldaki sohbet geçmişi sütunu açık (düğmesi pencerenin üst çubuğunda).
    @AppStorage(SettingsKey.askHistoryVisible) private var isShowingHistory: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            if isShowingHistory, !model.askConversations.isEmpty {
                AskHistoryColumn(model: model) { (id: UUID) -> Void in
                    // Etiketler açılan sohbetin son sorusunun kapsamına döner (`followUpScope`).
                    model.openConversation(id: id, context: .allMeetings)
                    mentioned = followUpScope(exchanges: exchanges, records: model.meetings)
                    focusRequest += 1
                }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            chat
        }
        .animation(.smooth(duration: 0.25), value: isShowingHistory)
        #if DEBUG
        .task { await applyDemoDraft() }
        #endif
    }

    private var chat: some View {
        VStack(spacing: 0) {
            // "Yeni sohbet" sabit bir üst satırda: kaydırılan sohbetin üstüne binmez (önceden köşede yüzüyordu ve sağa
            // hizalı soru balonunu örtüyordu).
            if hasCornerButtons {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button("Yeni sohbet", systemImage: "square.and.pencil") {
                        model.askChats.clear(context: .allMeetings)
                        mentioned = []
                        focusRequest += 1
                    }
                    .controlSize(.small)
                    .hoverHint("Önceki cevaplar bağlam olmaz; bu sohbet geçmişte kalır", alignment: .trailing, edge: .bottom)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            }
            ScrollViewReader { (proxy: ScrollViewProxy) in
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        if exchanges.isEmpty {
                            AskIntro(
                                hasMeetings: !model.meetings.isEmpty, firstName: askFirstName(userName: model.userName),
                                recent: recentChats,
                                onStartRecording: onStartRecording,
                                onImport: {
                                    router.section = .meetings
                                    chooseMediaToImport(model: model)
                                },
                                onOpenChat: { (id: String) -> Void in openRecentChat(id: id) },
                                onSeeAll: { isShowingHistory = true }
                            )
                        }
                        ForEach(exchanges) { (exchange: ArchiveExchange) in
                            ExchangeView(
                                exchange: exchange,
                                onOpen: { (passage: ArchivePassage) -> Void in
                                    // Toplantı kaynağın anında açılır: transkript çekmecesi o paragrafta (not kaynağında özet).
                                    router.openingSource = passage
                                    router.selectedMeetingID = passage.meetingID
                                    // Listedeki süzgeç (arama, klasör) açılan toplantıyı gizlemesin.
                                    router.searchQuery = ""
                                    router.folderFilter = nil
                                    router.section = .meetings
                                },
                                onSaveRecipe: { (question: String) -> Void in
                                    model.saveRecipe(question: question)
                                },
                                onRegenerate: regenerateAction(exchange: exchange),
                                onAskMeetings: askMeetingsAction(exchange: exchange)
                            )
                            .id(exchange.id)
                            .transition(.opacity.combined(with: .offset(y: 12)))
                        }
                        if !isAnswering, !followUps.isEmpty {
                            AskFollowUpChips(questions: followUps) { (question: String) -> Void in
                                model.askQuestion(context: .allMeetings, question: question, scope: scope, mentionIDs: [], recipeTitle: nil)
                            }
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .animation(.smooth(duration: 0.35), value: exchanges.map(\.id))
                    .padding(.horizontal, 40)
                    .padding(.top, hasCornerButtons ? 12 : 28)
                    .padding(.bottom, 16)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .scrollBottomProbe()
                }
                .scrollIndicators(.hidden)
                // Alt kenara 120 pt'den yakınsa sohbetin sonu görünüyor, akan cevap izlenir.
                .onScrollNearBottom(threshold: 120) { (near: Bool) in
                    isFollowingAnswer = near
                }
                // Cevap akarken alt kenar izlenir (yeni satırlar görünür kalsın); kullanıcı yukarı kaydırıp okuyorsa izlenmez.
                .onChange(of: exchanges.last?.answer.text) { (_: String?, _: String?) in
                    if isAnswering, isFollowingAnswer {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                // Cevap bitince altına gelen kapsam dipnotu ve düğmeler de görünsün (izleniyorsa).
                .onChange(of: exchanges.last?.phase) { (_: ArchiveExchange.Phase?, phase: ArchiveExchange.Phase?) in
                    if isFollowingAnswer, phase.map({ ![.understanding, .searching, .writing].contains($0) }) == true {
                        withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                }
                .overlay(alignment: .bottom) {
                    // Yukarı kaydırılmışken sohbetin sonuna dönüş (cevap akarken de).
                    if !isFollowingAnswer, !exchanges.isEmpty {
                        JumpToLatestButton {
                            withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                        }
                        .padding(.bottom, 10)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .animation(.smooth(duration: 0.2), value: isFollowingAnswer)
                .onChange(of: exchanges.last?.id) { (_: UUID?, last: UUID?) in
                    if let last {
                        withAnimation(.smooth(duration: 0.35)) { proxy.scrollTo(last, anchor: .top) }
                    }
                }
            }
            VStack(spacing: 8) {
                if isMentioning {
                    MentionSuggestions(candidates: suggestions, highlighted: highlightedIndex(count: suggestions.count)) { (record: MeetingRecord) -> Void in
                        pick(record: record)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if isPickingRecipe {
                    RecipeSuggestions(recipes: recipeMatches, highlighted: highlightedIndex(count: recipeMatches.count)) { (recipe: Recipe) -> Void in
                        run(recipe: recipe)
                    } onDelete: { (recipe: Recipe) -> Void in
                        model.deleteRecipe(id: recipe.id)
                        // Liste kısaldı: seçili satır listenin dışında kalmasın.
                        highlighted = 0
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !quickActions.isEmpty, !isAnswering {
                    AskQuickActionChips(actions: quickActions, isEnabled: !isAnswering) { (action: MeetingQuickAction) -> Void in run(action: action) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let unavailableReason {
                    Label(unavailableReason, systemImage: "info.circle")
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Boş sohbette soru alanının üstünde kullanıcının verisinden öneriler (dünkü toplantı, sözler, son kişi).
                if exchanges.isEmpty, mentioned.isEmpty, question.isEmpty, unavailableReason == nil {
                    let suggestions: [String] = askSuggestions(scope: scope, records: model.meetings, userName: model.userName, now: Date(), calendar: Calendar.current, limit: 4).map { askSuggestionText(suggestion: $0) }

                    if !suggestions.isEmpty {
                        AskSuggestionRow(suggestions: suggestions) { (suggestion: String) -> Void in
                            model.askQuestion(context: .allMeetings, question: suggestion, scope: scope, mentionIDs: [], recipeTitle: nil)
                        }
                    }
                }
                composer
                Text("Enter gönderir · Shift+Enter yeni satır · @ toplantı seç")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.muted.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .animation(.smooth(duration: 0.2), value: isMentioning || isPickingRecipe)
            .padding(.horizontal, 40)
            .padding(.bottom, 14)
            .frame(maxWidth: 780)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: question) { (_: String, _: String) in
            highlighted = 0
            resetDismissedSuggestions()
        }
        .onChange(of: cursor) { (_: Int, _: Int) in
            // İmleç başka bir bahse geçince liste değişir: seçili satır baştan başlar.
            highlighted = 0
            resetDismissedSuggestions()
        }
        .onChange(of: exchanges.last?.id, initial: true) { (_: UUID?, _: UUID?) in
            // Devam kapsamı: sohbetin son sorusu `@` toplantılara sorulduysa etiketler alanda kalır (kaldırılabilir) ve
            // devam sorusu da onlara gider; yeni sohbette ve açılan sohbette son sorunun kapsamına döner.
            mentioned = followUpScope(exchanges: exchanges, records: model.meetings)
        }
        .onChange(of: router.askFocusRequest) { (_: Int, _: Int) in
            // ⌘J: Sor sayfasındayken soru alanı odaklanır.
            focusRequest += 1
        }
    }

    /// Sor sayfasının sohbeti (bağlamı tüm toplantılar; kapsamı çipten değişir).
    private var exchanges: [ArchiveExchange] {
        model.askChats.exchanges(context: .allMeetings)
    }

    private var isAnswering: Bool {
        model.askChats.isAnswering(context: .allMeetings)
    }

    /// Çipte seçili kapsam: sonraki soru buna sorulur.
    private var scope: AskScope {
        model.askChats.scope(context: .allMeetings)
    }

    /// Kapsam bir toplantıysa onun hazır eylemleri (takip e-postası, aksiyonlar, kısaca, notu uzat); yoksa boş.
    private var quickActions: [MeetingQuickAction] {
        guard let id = askScopeMeetingID(scope: scope), model.meetings.first(where: { $0.id == id })?.note != nil else {
            return []
        }
        return meetingQuickActions(recipes: model.recipes)
    }

    /// Kapsam bir toplantıysa son cevabın altındaki devam soruları (o toplantının notundan).
    private var followUps: [String] {
        let note: MeetingNote? = askScopeMeetingID(scope: scope).flatMap { (id: String) -> MeetingNote? in model.meetings.first { $0.id == id }?.note }
        return model.askChats.followUps(context: .allMeetings, note: note)
    }

    /// Hazır eylem: tarif kapsamdaki toplantıya sorulur, "Notu uzat" o toplantının notunu yeniden yazar.
    private func run(action: MeetingQuickAction) {
        guard let id = askScopeMeetingID(scope: scope) else {
            return
        }
        switch action.kind {
        case .ask(let prompt, let recipeTitle):
            model.askQuestion(context: .allMeetings, question: prompt, scope: scope, mentionIDs: [], recipeTitle: recipeTitle)
        case .editNote(let instruction):
            model.editNote(meetingID: id, instruction: instruction)
        }
    }

    /// "Toplantı ekle": alanın sonuna "@" yazar ve alanı odaklar; toplantı önerileri açılır.
    private func startMention() {
        let needsSpace: Bool = !question.isEmpty && question.last?.isWhitespace == false
        question += needsSpace ? " @" : "@"
        cursor = question.utf16.count
        focusRequest += 1
    }

    /// Akan cevabı durdurur; o ana kadar yazılan kalır.
    private func stopAnswer() {
        model.askChats.stop(context: .allMeetings)
    }

    private let bottomID: String = "ask-bottom"

    /// Boş sayfadaki son sohbetler (en fazla 6, yeniden eskiye; toplantı sayfasında, klasörde ya da kişide sorulanlar da),
    /// her biri kapsamıyla; tümü soldaki "Geçmiş" sütununda.
    private var recentChats: [AskRecentChat] {
        let now: Date = Date()
        return model.askConversations.prefix(6).map { (conversation: AskConversation) -> AskRecentChat in
            AskRecentChat(
                id: conversation.id.uuidString, title: askConversationDisplayTitle(conversation: conversation),
                detail: askRecentChatDetail(conversation: conversation, now: now), isAnswering: model.askChats.isAnswering(conversationID: conversation.id)
            )
        }
    }

    /// Son sohbetlerden biri açılır (geçmiş sütunundaki gibi); soru alanı odağı alır.
    private func openRecentChat(id: String) {
        guard let uuid = UUID(uuidString: id) else {
            preconditionFailure("Son sohbet kimliği UUID değil: \(id)")
        }
        model.openConversation(id: uuid, context: .allMeetings)
        mentioned = followUpScope(exchanges: exchanges, records: model.meetings)
        focusRequest += 1
    }

    /// Sohbetin son sorusunda "Yeniden oluştur" / "Tekrar dene": aynı soru aynı kapsamla yeniden sorulur; diğer sorularda
    /// ve Sor kullanılamıyorken yok.
    private func regenerateAction(exchange: ArchiveExchange) -> (@MainActor () -> Void)? {
        guard exchange.id == exchanges.last?.id, unavailableReason == nil else {
            return nil
        }
        return { model.regenerateAnswer(context: .allMeetings) }
    }

    /// Kapsam dipnotundaki "Bunlara da sor": aynı soru (ya da tarif) sığmayan toplantılara `@` ile sorulur; cevap sürerken
    /// ve Sor kullanılamıyorken yok.
    private func askMeetingsAction(exchange: ArchiveExchange) -> (@MainActor ([String]) -> Void)? {
        guard !isAnswering, unavailableReason == nil else {
            return nil
        }
        return { (meetingIDs: [String]) -> Void in
            model.askQuestion(context: .allMeetings, question: exchange.question, scope: exchange.scope, mentionIDs: meetingIDs, recipeTitle: exchange.recipeTitle)
        }
    }

    /// Sor şu an kullanılamıyorsa nedeni (sunucu çağrılmadan): abonelikte denemesi henüz başlamamış hesap toplantı dışı
    /// yapay zekâyı kullanamaz (sunucu `trial_not_started` derdi).
    private var unavailableReason: String? {
        #if HOSTED_EDITION
        hostedAskUnavailableReason(account: .shared)
        #else
        nil
        #endif
    }

    /// Üst satırda "Yeni sohbet" düğmesi var mı.
    private var hasCornerButtons: Bool {
        !exchanges.isEmpty
    }

    /// Soru alanının yer tutucusu (ve VoiceOver etiketi).
    private var placeholder: String {
        if !mentioned.isEmpty {
            return String(localized: "Etiketlenen toplantılara sor…")
        }
        return exchanges.isEmpty || scope != .allMeetings ? askScopePlaceholder(scope: scope) : String(localized: "Devam sorusu sor…")
    }

    private var composer: some View {
        let isEmpty: Bool = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            // Kapsam çipi: soru hangi toplantılara sorulur; `@` etiketi varken soru yalnız etiketlilere gider.
            if mentioned.isEmpty {
                AskScopeChip(
                    menu: askScopeMenu(context: .allMeetings, selected: scope, records: model.meetings, folders: model.folders, userName: model.userName),
                    isEnabled: !isAnswering
                ) { (selected: AskScope) -> Void in
                    model.askChats.select(scope: selected, context: .allMeetings)
                    focusRequest += 1
                }
                .padding(.top, 2)
            }
            if !mentioned.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(mentioned, id: \.id) { (record: MeetingRecord) in
                        RemovableMentionChip(title: record.note?.title ?? record.title) {
                            withAnimation(.smooth(duration: 0.2)) { mentioned.removeAll { $0.id == record.id } }
                            focusRequest += 1
                        }
                    }
                }
                .padding(.top, 4)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Etiketlenen toplantılar")
            }
            HStack(alignment: .bottom, spacing: 10) {
                // Toplantı ekle: alana "@" yazar, toplantı önerileri açılır (soru yalnız seçilen toplantılara gider).
                Button(action: startMention) {
                    Image(systemName: "at")
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 32)
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(Text("Toplantı ekle"))
                .hoverHint("Toplantı ekle (@)", alignment: .leading, edge: .top)
                AskInputField(
                    text: $question, cursor: $cursor, accessibilityLabel: placeholder, font: askInputFont(appearance: appearance, size: 15),
                    textColor: NSColor(Theme.ink), maxLines: 6, focusRequest: focusRequest
                ) { (focused: Bool) -> Void in
                    isFocused = focused
                } onCommand: { (command: AskInputCommand) -> Bool in
                    handle(command: command)
                }
                .overlay(alignment: .topLeading) {
                    if question.isEmpty {
                        Text(placeholder)
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 6)
                if isAnswering {
                    Button(action: stopAnswer) {
                        Image(systemName: "stop.fill")
                            .appFont(size: 11, weight: .bold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 32, height: 32)
                            .background(Theme.primary, in: Circle())
                    }
                    .buttonStyle(.hoverCapsule)
                    // ⌘. (macOS'te işi durdurmanın alışılmış kısayolu); alan odakta değilken Esc de durdurur (aşağıda).
                    .keyboardShortcut(".", modifiers: .command)
                    .background {
                        Button("Cevabı durdur", action: stopAnswer)
                            .keyboardShortcut(.cancelAction)
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Durdur")
                    .hoverHint("Cevabı durdur (⌘. ya da Esc)", alignment: .trailing, edge: .top)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .appFont(size: 13, weight: .bold)
                            .foregroundStyle(Theme.onPrimary)
                            .frame(width: 32, height: 32)
                            .background(isEmpty ? Theme.muted.opacity(0.5) : Theme.primary, in: Circle())
                    }
                    .buttonStyle(.hoverCapsule)
                    .disabled(isEmpty || unavailableReason != nil)
                    .accessibilityLabel("Sor")
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(Theme.card, in: shape)
        .overlay {
            // Ajan çalışırken çerçevede yavaş dönen renkli ışık.
            if isAnswering {
                ThinkingRing(shape: shape)
            } else {
                shape.strokeBorder(isFocused ? Theme.ink.opacity(0.18) : Theme.line)
            }
        }
        .shadow(color: .black.opacity(0.07), radius: 18, y: 6)
        .animation(.smooth(duration: 0.25), value: isAnswering)
    }

    /// Soru alanının tuş komutu; true dönerse işlendi (işlenmeyen ↑/↓ imleci taşır, Tab odağı geçirir).
    private func handle(command: AskInputCommand) -> Bool {
        switch command {
        case .submit:
            submit()
            return true
        case .moveUp:
            guard isMentioning || isPickingRecipe else {
                return recallLastQuestion()
            }
            moveHighlight(by: -1)
            return true
        case .moveDown:
            guard isMentioning || isPickingRecipe else {
                return false
            }
            moveHighlight(by: 1)
            return true
        case .complete:
            let candidates: [MeetingRecord] = suggestions
            guard !candidates.isEmpty else {
                return false
            }
            pick(record: candidates[highlightedIndex(count: candidates.count)])
            return true
        case .cancel:
            return cancel()
        }
    }

    /// Enter: öneri açıksa seçili satırı seçer (soru gönderilmez), değilse soruyu gönderir.
    private func submit() {
        let candidates: [MeetingRecord] = suggestions
        let recipes: [Recipe] = recipeMatches
        if !candidates.isEmpty {
            pick(record: candidates[highlightedIndex(count: candidates.count)])
        } else if !recipes.isEmpty {
            run(recipe: recipes[highlightedIndex(count: recipes.count)])
        } else {
            send()
        }
    }

    private func send() {
        // Öneri seçilirken gönderilmez; eşleşen öneri yoksa ("@Mikko ne dedi?") soru olduğu gibi gider.
        guard !isAnswering, !isMentioning, !isPickingRecipe, unavailableReason == nil,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        #if HOSTED_EDITION
        // Hakkı yoksa soru alanı temizlenmez (abone olunca yeniden gönderilebilsin); teklif açılır.
        if HostedAccount.shared.requiresSubscription {
            HostedAccount.shared.requestSubscription()
            return
        }
        #endif
        model.askQuestion(context: .allMeetings, question: question, scope: scope, mentionIDs: mentioned.map(\.id), recipeTitle: nil)
        clearQuestion()
    }

    /// Gönderilen sorunun metnini boşaltır; etiketler kalır (devam soruları aynı toplantılara gider; bkz. `followUpScope`).
    private func clearQuestion() {
        cursor = 0
        question = ""
        highlighted = 0
    }

    /// Soru alanını ve etiketleri boşaltır (Esc).
    private func clearInput() {
        clearQuestion()
        withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
    }

    /// Boş alanda ↑: sohbetteki son soru düzenlemeye gelir (imleç sonda). Alan doluysa ya da soru yoksa işlenmez.
    private func recallLastQuestion() -> Bool {
        guard question.isEmpty, let last = lastAskedQuestion(exchanges: exchanges) else {
            return false
        }
        cursor = last.utf16.count
        question = last
        return true
    }

    /// Esc: önce açık öneriyi kapatır (yazılan metin kalır), öneri yoksa alanı ve etiketleri temizler.
    private func cancel() -> Bool {
        if isMentioning, let mention = mentionQuery(text: question, cursor: cursor) {
            dismissedMentionStart = mention.start
            return true
        }
        if isPickingRecipe {
            isRecipeDismissed = true
            return true
        }
        // Cevap akarken Esc önce cevabı durdurur (yazılan devam sorusu silinmez).
        if isAnswering {
            model.askChats.stop(context: .allMeetings)
            return true
        }
        guard !question.isEmpty || !mentioned.isEmpty else {
            return false
        }
        clearInput()
        return true
    }

    /// Kapatılan öneri, bahsi ya da "/" silinince unutulur (yeniden yazılınca açılsın).
    private func resetDismissedSuggestions() {
        if let dismissed = dismissedMentionStart, mentionQuery(text: question, cursor: cursor)?.start != dismissed {
            dismissedMentionStart = nil
        }
        if isRecipeDismissed, recipeQuery(text: question) == nil {
            isRecipeDismissed = false
        }
    }

    /// `@` önerileri açık: imlecin önünde (Esc ile kapatılmamış) bahse eşleşen toplantı var.
    private var isMentioning: Bool {
        !suggestions.isEmpty
    }

    /// "/" önerileri açık: eşleşen tarif var.
    private var isPickingRecipe: Bool {
        !recipeMatches.isEmpty
    }

    /// "/" ile eşleşen tarifler; "/" yoksa ya da Esc ile kapatıldıysa boş.
    private var recipeMatches: [Recipe] {
        guard !isRecipeDismissed, let query = recipeQuery(text: question) else {
            return []
        }
        return recipeCandidates(recipes: model.recipes, query: query)
    }

    /// Tarifi çalıştırır: etiketli toplantılar varsa onlara, yoksa tüm arşive.
    private func run(recipe: Recipe) {
        guard !isAnswering, unavailableReason == nil else {
            return
        }
        model.askQuestion(context: .allMeetings, question: recipe.prompt, scope: scope, mentionIDs: mentioned.map(\.id), recipeTitle: recipe.title)
        clearQuestion()
    }

    /// `@` önerileri (en fazla 6): imlecin önündeki bahse eşleşen toplantılar; bahis yoksa ya da Esc ile kapatıldıysa boş.
    private var suggestions: [MeetingRecord] {
        guard let mention = mentionQuery(text: question, cursor: cursor), mention.start != dismissedMentionStart else {
            return []
        }
        return mentionCandidates(records: model.meetings, query: mention.query, excluding: mentioned.map(\.id), limit: 6)
    }

    /// Toplantıyı etikete ekler; yazılan "@…" silinir, imleç onun yerine gelir.
    private func pick(record: MeetingRecord) {
        guard let edit = removingMention(text: question, cursor: cursor) else {
            preconditionFailure("Toplantı önerisi seçildi ama imlecin önünde @ bahsi yok")
        }
        withAnimation(.smooth(duration: 0.2)) { mentioned.append(record) }
        cursor = edit.cursor
        question = edit.text
        highlighted = 0
        focusRequest += 1
    }

    private func moveHighlight(by step: Int) {
        let count: Int = isMentioning ? suggestions.count : recipeMatches.count
        highlighted = (highlightedIndex(count: count) + step + count) % count
    }

    /// Açık listedeki (`count` > 0 satır) vurgulu satır: liste açıkken kısalırsa (toplantı silindi, eşitlemeyle gitti)
    /// son satıra iner; Enter ve Tab listenin dışını seçmez.
    private func highlightedIndex(count: Int) -> Int {
        min(highlighted, count - 1)
    }

    #if DEBUG
    /// Tanıtım modunda (`--tanitim-soru`, `--tanitim-etiket`) soru alanına taslak ve etiketler yazılır (görsel kontrol).
    private func applyDemoDraft() async {
        guard isDemoMode, let draft = demoAskDraft(arguments: CommandLine.arguments) else {
            return
        }
        for _ in 0..<40 where model.meetings.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
        }
        mentioned = Array(mentionCandidates(records: model.meetings, query: "", excluding: [], limit: draft.chips))
        cursor = draft.question.utf16.count
        question = draft.question
    }
    #endif
}

/// Sohbet geçmişi: soldaki ince sütun (arama, süzgeç, ad değiştirme ve silme; bkz. `AskHistorySidebar`).
private struct AskHistoryColumn: View {
    let model: AppModel
    let onOpen: @MainActor (UUID) -> Void

    var body: some View {
        AskHistorySidebar(
            conversations: model.askConversations, selectedID: model.askChats.conversationID(context: .allMeetings), onOpen: onOpen,
            onRename: { (id: UUID, title: String) -> Void in model.renameConversation(id: id, title: title) },
            onDelete: { (id: UUID) -> Void in model.deleteConversation(id: id) }
        )
    }
}

/// Boş sayfa (sohbet açık değilken): ortada selamlama ve varsa son sohbetler (kapsamlarıyla); öneriler soru alanının
/// üstünde. Hiç toplantı yokken kısa bir boş durum (öneriler boş cevap verirdi). Web araması ayarı Ayarlar › Canlı çeviri ve Sor'da.
private struct AskIntro: View {
    let hasMeetings: Bool
    /// Selamlamadaki ad (`askFirstName`).
    let firstName: String
    let recent: [AskRecentChat]
    /// Hiç toplantı yokken: kaydı başlatır ya da ses/video dosyası içe aktarır (ilk toplantı buradan da gelir).
    let onStartRecording: @MainActor () -> Void
    let onImport: @MainActor () -> Void
    let onOpenChat: @MainActor (String) -> Void
    /// "Tümünü gör": soldaki geçmiş sütununu açar.
    let onSeeAll: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            AskGreeting(firstName: firstName, size: 30)
                .padding(.top, 36)
                .padding(.bottom, 8)
            if !hasMeetings {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Henüz sorulacak toplantı yok")
                            .appFont(size: 14, weight: .medium)
                            .foregroundStyle(Theme.ink)
                        Text("İlk toplantını kaydet ya da içe aktar; sonra burada sorarsın.")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button("Kaydı başlat", systemImage: "record.circle", action: onStartRecording)
                            .buttonStyle(.accentPill)
                        Button("İçe aktar", systemImage: "square.and.arrow.down", action: onImport)
                    }
                    .controlSize(.small)
                }
            }
            if !recent.isEmpty {
                AskRecentChats(chats: recent, onOpen: onOpenChat, onSeeAll: onSeeAll)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .padding(.top, 20)
    }
}
