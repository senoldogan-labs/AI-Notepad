import AINotepadCore
import AINotepadUI
import os
import SwiftUI

/// Arşiv sohbeti: soru-cevaplar ve süren cevap. Cevabı Mac'teki `askArchive` yazar (arama terimleri → parçalar → akan
/// cevap); devam soruları önceki cevapları bağlam alır; yapay zekâ çağrısı hesabın payından (sunucu üzerinden Claude).
/// Sohbetler her cevaptan sonra bu iPhone'da hesabın klasöründe saklanır ve geçmişten yeniden açılır.
@MainActor
@Observable
final class PhoneAsk {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneAsk")

    private(set) var exchanges: [ArchiveExchange] = []
    private(set) var isAnswering: Bool = false
    /// Saklanan sohbetler (yeniden eskiye; en fazla `askHistoryLimit`).
    private(set) var conversations: [AskConversation] = []
    /// Açık sohbetin kimliği: ilk cevap saklanınca atanır, "Yeni sohbet"te nil.
    private(set) var currentConversationID: UUID?
    /// Sohbet geçmişinin okunamama, saklanamama ya da silinememe nedeni.
    private(set) var historyError: String?
    @ObservationIgnored private let store: PhoneStore
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: PhoneStore) {
        self.store = store
    }

    /// Kullanıcının kaydettiği tarifler.
    private(set) var userRecipes: [Recipe] = []
    /// Tariflerin okunamama ya da saklanamama nedeni.
    private(set) var recipeError: String?

    /// Yerleşik ve kullanıcı tarifleri.
    var recipes: [Recipe] {
        builtInRecipes() + userRecipes
    }

    /// Kayıtlı tarifleri okur.
    func loadRecipes() {
        do {
            // Tarifler hesabındır (Mac'teki Gistsmith gibi): başka hesapla girince görünmez.
            userRecipes = try loadUserRecipes(defaults: try hostedActiveAccountDefaults())
        } catch {
            recipeError = userFacingMessage(error: error)
        }
    }

    /// Soruyu tarif olarak kaydeder.
    func saveRecipe(question: String) {
        store(recipes: userRecipes + [recipeFromQuestion(question: question, id: UUID().uuidString)])
    }

    /// Kullanıcı tarifini siler.
    func deleteRecipe(id: String) {
        store(recipes: userRecipes.filter { $0.id != id })
    }

    /// Agent Skill dosyalarını (`SKILL.md`, belge seçiciden) tarif olarak ekler (Mac'teki "SKILL.md içe aktar"); eklenenler
    /// ve okunamayanların nedeni döner. Seçicinin verdiği dosyalara erişim okuma süresince açılır.
    func importSkills(files: [URL]) -> SkillImportResult {
        let opened: [URL] = files.filter { $0.startAccessingSecurityScopedResource() }
        defer { opened.forEach { $0.stopAccessingSecurityScopedResource() } }
        let result: SkillImportResult = importSkillRecipes(files: files) { UUID().uuidString }
        if !result.recipes.isEmpty {
            store(recipes: userRecipes + result.recipes)
        }
        return result
    }

    private func store(recipes: [Recipe]) {
        do {
            try saveUserRecipes(recipes: recipes, defaults: try hostedActiveAccountDefaults())
            userRecipes = recipes
        } catch {
            recipeError = userFacingMessage(error: error)
        }
    }

    /// Soruyu arşive sorar; cevap akarak gelir. `meetingIDs` boş değilse yalnız o toplantılara (`@` ile etiketlenenler).
    func ask(question: String, meetingIDs: [String], recipeTitle: String?) {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else {
            return
        }
        // Hakkı yoksa (deneme bitti, abonelik sona erdi) soru gönderilmez, abonelik ekranı her seferinde açılır (Mac'teki
        // gibi; sunucunun reddi ekranı en çok on dakikada bir açar ve soru başarısız cevap olarak kalırdı).
        if HostedAccount.shared.requiresSubscription {
            HostedAccount.shared.requestSubscription()
            return
        }
        // Deneme ilk toplantıyla başlar: henüz toplantısı olmayan denemedeki hesap önce kayıt yapmalı (sunucu
        // çağrılmaz; diğer retler sunucunun hatasıyla gösterilir).
        if let reason = hostedAskUnavailableReason(account: HostedAccount.shared) {
            exchanges.append(failedExchange(id: UUID(), question: trimmed, scopeMeetingIDs: meetingIDs, recipeTitle: recipeTitle, reason: reason, at: Date()))
            return
        }
        recordFeatureUsage(feature: .ask)
        let history: [ArchiveTurn] = archiveHistory(exchanges: exchanges)
        let id: UUID = UUID()
        let scoped: [MeetingRecord]
        do {
            scoped = try archiveScope(records: store.meetings, meetingIDs: meetingIDs)
        } catch {
            // Etiketli toplantı silinmişse soru tüm arşive genişletilmez; soru ve neden sohbette görünür.
            exchanges.append(failedExchange(
                id: id, question: trimmed, scopeMeetingIDs: meetingIDs, recipeTitle: recipeTitle, reason: userFacingMessage(error: error), at: Date()
            ))
            return
        }
        exchanges.append(startedExchange(id: id, question: trimmed, scope: scoped, recipeTitle: recipeTitle, startedAt: Date()))
        isAnswering = true
        let records: [MeetingRecord] = store.meetings
        let userName: String = store.userName
        let profile: UserProfile = store.userProfile
        let webSearch: Bool = askWebSearchAllowed(defaults: UserDefaults.standard)
        task = Task { [weak self] in
            do {
                let provider: LLMProvider = try phoneAccountLLMProvider()
                let onProgress: ArchiveProgressHandler = { [weak self] (progress: ArchiveProgress) -> Void in
                    await self?.apply(progress: progress, id: id)
                }
                // iPhone'da ekran görüntüsü alınmaz (başka uygulamaların ekranı yakalanamaz): Sor yalnız metni okur.
                if scoped.isEmpty {
                    _ = try await askArchive(
                        question: trimmed, history: history, records: records, userName: userName, profile: profile, language: phoneNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars, screens: .off, webSearch: webSearch, now: Date(), onProgress: onProgress
                    )
                } else {
                    _ = try await askAboutMeetings(
                        question: trimmed, history: history, records: scoped, userName: userName, profile: profile, language: phoneNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars,
                        screens: .off, webSearch: webSearch, now: Date(), onProgress: onProgress
                    )
                }
                self?.finish(id: id, phase: .done)
                self?.saveConversation(exchangeID: id)
            } catch is CancellationError {
                self?.finish(id: id, phase: .stopped)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(id: id, phase: .stopped)
            } catch {
                Self.logger.error("Arşiv sorusu cevaplanamadı, hata: \(String(describing: error), privacy: .private)")
                self?.finish(id: id, phase: .failed(userFacingMessage(error: error)))
            }
        }
    }

    /// Akan cevabı durdurur; o ana kadar yazılan kalır.
    func stop() {
        task?.cancel()
    }

    /// Son soruyu (bitmiş, durdurulmuş ya da hatalı) aynı kapsam ve tarifle yeniden sorar; eski cevabın yerini yenisi
    /// alır. Soru gönderilemezse (abonelik ekranı açıldı) eski cevap yerinde kalır.
    func regenerate() {
        guard let last = regeneratableExchange(exchanges: exchanges) else {
            return
        }
        exchanges.removeLast()
        let remaining: Int = exchanges.count
        ask(question: last.question, meetingIDs: last.scopeMeetingIDs, recipeTitle: last.recipeTitle)
        if exchanges.count == remaining {
            exchanges.append(last)
        }
    }

    /// Sohbeti temizler (yeni konu: önceki cevaplar bağlam olmaz); önceki sohbet geçmişte kalır.
    func clear() {
        task?.cancel()
        exchanges = []
        currentConversationID = nil
        isAnswering = false
    }

    /// Saklanan sohbetleri okur (açılışta); okunamayan dosyalar loglanır ve sayısı gösterilir.
    func loadHistory() {
        do {
            let result: AskHistoryLoadResult = try loadAskConversations(directory: try AppPaths.askHistoryDirectory())
            conversations = result.conversations
            for failure in result.failures {
                Self.logger.error("Sohbet okunamadı, dosya: \(failure.file, privacy: .public), neden: \(failure.reason, privacy: .private)")
            }
            historyError = result.failures.isEmpty ? nil : String(localized: "Sohbet geçmişinden \(result.failures.count) sohbet okunamadı.")
        } catch {
            Self.logger.error("Sohbet geçmişi okunamadı, hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet geçmişi okunamadı: \(userFacingMessage(error: error))")
        }
    }

    /// Saklanan sohbeti açar; devam soruları onun cevaplarını bağlam alır. Süren cevap durdurulur.
    func open(conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            return
        }
        task?.cancel()
        exchanges = conversation.turns.map { (turn: AskConversationTurn) -> ArchiveExchange in archiveExchange(turn: turn) }
        currentConversationID = conversationID
        isAnswering = false
    }

    /// Sohbetin adını değiştirir (boş ya da aynı ad yok sayılır); sohbetin listedeki yeri değişmez.
    func rename(conversationID: UUID, title: String) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let renamed = renamedAskConversation(conversation: conversation, title: title, now: Date()) else {
            return
        }
        do {
            try saveAskConversation(conversation: renamed, directory: try AppPaths.askHistoryDirectory())
            conversations = upsertAskConversation(conversations: conversations, conversation: renamed)
        } catch {
            Self.logger.error("Sohbetin adı değiştirilemedi, sohbet: \(conversationID.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbetin adı değiştirilemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Sohbeti geçmişten siler; açık sohbetse sohbet boşalır.
    func delete(conversationID: UUID) {
        do {
            try deleteAskConversation(id: conversationID, directory: try AppPaths.askHistoryDirectory())
            conversations.removeAll { $0.id == conversationID }
            if currentConversationID == conversationID {
                clear()
            }
        } catch {
            Self.logger.error("Sohbet silinemedi, sohbet: \(conversationID.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet silinemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Bitmiş soruyla açık sohbeti saklar (ilk cevapta yeni sohbet olur); sınırı aşan en eski sohbetler silinir.
    private func saveConversation(exchangeID: UUID) {
        // Sohbet bu arada değiştiyse (yeni sohbet, başka sohbet açıldı) cevap bu sohbete ait değildir.
        guard exchanges.contains(where: { $0.id == exchangeID && $0.phase == .done }) else {
            return
        }
        let id: UUID = currentConversationID ?? UUID()
        let turns: [AskConversationTurn] = exchanges.compactMap { (exchange: ArchiveExchange) -> AskConversationTurn? in askTurn(exchange: exchange) }
        let conversation: AskConversation = askConversation(existing: conversations.first { $0.id == id }, id: id, turns: turns, now: Date())
        do {
            let directory: URL = try AppPaths.askHistoryDirectory()
            try saveAskConversation(conversation: conversation, directory: directory)
            currentConversationID = id
            conversations = upsertAskConversation(conversations: conversations, conversation: conversation)
            for old in askConversationsBeyondLimit(conversations: conversations, limit: askHistoryLimit) {
                try deleteAskConversation(id: old.id, directory: directory)
                conversations.removeAll { $0.id == old.id }
            }
        } catch {
            Self.logger.error("Sohbet saklanamadı, sohbet: \(id.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet saklanamadı: \(userFacingMessage(error: error))")
        }
    }

    private func finish(id: UUID, phase: ArchiveExchange.Phase) {
        // Sohbet bu arada temizlendi ya da değişti: yeni sorunun durumuna dokunulmaz.
        guard exchanges.contains(where: { $0.id == id }) else {
            return
        }
        update(id: id) {
            $0.phase = phase
            $0.finishedAt = Date()
        }
        isAnswering = false
    }

    private func apply(progress: ArchiveProgress, id: UUID) {
        update(id: id) { (exchange: inout ArchiveExchange) -> Void in
            exchange = applying(progress: progress, to: exchange)
        }
    }

    private func update(id: UUID, change: (inout ArchiveExchange) -> Void) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&exchanges[index])
    }
}

/// Sor sekmesinin gezinme hedefleri (`PhoneRouter.askPath`): sohbet (tam ekran, sekme çubuğu gizli) ve sohbet geçmişi.
enum AskRoute: Hashable {
    case conversation
    case history
}

/// Soru alanından gönderilen soru: metin, `@` ile etiketlenen toplantılar ve (tariften geldiyse) tarifin adı.
struct AskSubmission {
    let question: String
    let meetingIDs: [String]
    let recipeTitle: String?
}

/// Sor sekmesinin kökü: sakin başlangıç (başlık, örnek soru hapları, son sohbetler) ve altta soru alanı; web araması
/// ayarı Ayarlar'da. Sor baştan sona tam ekrandır: sekme çubuğu gizli, sol üstteki geri Sor'a gelinen sekmeye döner.
/// Soru gönderilince ya da bir sohbet açılınca sohbet üstüne açılır; onun geri oku kökü getirir.
struct AskTab: View {
    let ask: PhoneAsk
    let store: PhoneStore
    @Bindable var router: PhoneRouter

    /// Son sohbetlerde kaydedilmemiş (süren) sohbetin satır kimliği.
    private let currentChatID: String = "current"

    /// Kökte gösterilen en yeni sohbet sayısı; tümü geçmişte.
    private let recentLimit: Int = 3

    var body: some View {
        NavigationStack(path: $router.askPath) {
            Group {
                if isEmpty {
                    // Henüz toplantı ve sohbet yok: sorulacak bir şey yok, ortada kısa bir boş durum ve kayda geçiş.
                    PhoneEmptyScene(
                        symbol: "sparkle.magnifyingglass", palette: .violet, title: "Sorulacak toplantı yok",
                        message: "İlk toplantını kaydet; sonra notlarına buradan soru sor, cevap kaynağıyla gelsin."
                    ) {
                        Button("Kaydı başlat", systemImage: "mic.fill") { router.tab = .record }
                            .buttonStyle(.accentPill)
                            .controlSize(.large)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            PhoneErrorList(messages: [ask.historyError, ask.recipeError].compactMap { $0 })
                            AskStartHeader()
                            // Toplantı yokken örnek sorular boş cevap verirdi: yerine kısa bir satır.
                            if store.meetings.isEmpty {
                                Text("Sorulacak toplantı yok")
                                    .appFont(size: 14, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                            } else {
                                AskExampleChips(questions: askExampleQuestions) { (question: AskExampleQuestion) -> Void in
                                    startConversation(submission: AskSubmission(question: question.localized, meetingIDs: [], recipeTitle: nil))
                                }
                            }
                            if hasRecent {
                                AskRecentChats(
                                    chats: recentChats,
                                    onOpen: { (id: String) -> Void in openRecent(id: id) },
                                    onSeeAll: ask.conversations.isEmpty ? nil : { router.askPath = [.history] }
                                )
                                .padding(.top, 4)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        // İçerik soru alanına yapışmasın: alanın üstündeki dokunuş bir hapa ya da satıra değil boşluğa düşer.
                        .padding(.bottom, 40)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) {
                        AskComposer(
                            ask: ask, store: store, placeholder: "Sor… (@ toplantı, / tarif)", isAnswering: false, followUp: nil,
                            onSubmit: { (submission: AskSubmission) -> Void in startConversation(submission: submission) },
                            onStop: { ask.stop() }
                        )
                    }
                }
            }
            .phoneTabSwipe(router: router, isEnabled: true)
            .background(Theme.background)
            .navigationTitle("Sor")
            .navigationBarTitleDisplayMode(.inline)
            // Kökte de sekme çubuğu gizli (yalnız sohbette gizlemek yetmedi: Sor'u açan kullanıcı ilk bu ekranı görüyor).
            .toolbar(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // Sistem geri okuyla aynı renk (sohbet ve toplantı sayfasındaki geri gibi).
                    Button("Geri", systemImage: "chevron.left") { router.leaveAsk() }
                        .tint(Theme.ink)
                }
            }
            .navigationDestination(for: AskRoute.self) { (route: AskRoute) in
                switch route {
                case .conversation:
                    AskConversationView(ask: ask, store: store, router: router)
                case .history:
                    AskHistoryList(ask: ask) { (id: UUID) -> Void in
                        openConversation(id: id)
                    }
                }
            }
        }
    }

    /// Kaydedilmemiş (ilk cevabı süren ya da yarıda kalan) açık sohbet: son sohbetlerin başında "sohbete dön" satırı.
    private var unsavedQuestion: String? {
        ask.currentConversationID == nil ? ask.exchanges.first?.question : nil
    }

    private var hasRecent: Bool {
        unsavedQuestion != nil || !ask.conversations.isEmpty
    }

    /// Ne toplantı ne sohbet var: kök yalnız boş durumu gösterir.
    private var isEmpty: Bool {
        store.meetings.isEmpty && !hasRecent
    }

    /// Son sohbetler: varsa süren (kaydedilmemiş) sohbet, sonra en yeni saklanan sohbetler; tek satır ve göreli zaman.
    private var recentChats: [AskRecentChat] {
        let now: Date = Date()
        let current: [AskRecentChat] = unsavedQuestion.map { (question: String) -> [AskRecentChat] in
            [AskRecentChat(
                id: currentChatID, title: question,
                detail: ask.isAnswering ? String(localized: "Cevaplanıyor…") : String(localized: "Şimdi"), isAnswering: ask.isAnswering
            )]
        } ?? []
        let saved: [AskRecentChat] = ask.conversations.prefix(recentLimit - current.count).map { (conversation: AskConversation) -> AskRecentChat in
            AskRecentChat(
                id: conversation.id.uuidString, title: askConversationDisplayTitle(conversation: conversation),
                detail: askRecentChatTime(date: conversation.updatedAt, now: now),
                isAnswering: ask.isAnswering && ask.currentConversationID == conversation.id
            )
        }
        return current + saved
    }

    /// Son sohbetler satırı: süren sohbete döner ya da saklanan sohbeti açar.
    private func openRecent(id: String) {
        guard id != currentChatID else {
            router.askPath = [.conversation]
            return
        }
        guard let uuid = UUID(uuidString: id) else {
            preconditionFailure("Son sohbet kimliği UUID değil: \(id)")
        }
        openConversation(id: uuid)
    }

    /// Kökten gönderilen soru yeni sohbet başlatır (süren cevap durur; önceki sohbet geçmişte kalır) ve sohbeti açar.
    private func startConversation(submission: AskSubmission) {
        ask.clear()
        ask.ask(question: submission.question, meetingIDs: submission.meetingIDs, recipeTitle: submission.recipeTitle)
        router.askPath = [.conversation]
    }

    /// Saklanan sohbeti açar; zaten açık olan sohbet yeniden yüklenmez (süren cevabı kesilmez).
    private func openConversation(id: UUID) {
        if ask.currentConversationID != id || ask.exchanges.isEmpty {
            ask.open(conversationID: id)
        }
        router.askPath = [.conversation]
    }
}

/// Sohbet (tam ekran): soru-cevaplar (Mac'teki ile aynı görünüm) ve altta yalnızca devam sorusu alanı. Sekme çubuğu
/// gizlidir; sol üstteki geri kökü getirir (süren cevap durmaz), sağ üstteki "Yeni sohbet" sohbeti kapatıp köke döner.
private struct AskConversationView: View {
    let ask: PhoneAsk
    let store: PhoneStore
    let router: PhoneRouter

    private let bottomID: String = "ask-bottom"
    /// Sohbetin sonu görünüyor: akan cevap izlenir; yukarı kaydırınca izleme durur, "sona git" düğmesi çıkar.
    @State private var isFollowingAnswer: Bool = true

    var body: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PhoneErrorList(messages: [ask.historyError, ask.recipeError].compactMap { $0 })
                    ForEach(ask.exchanges) { (exchange: ArchiveExchange) in
                        ExchangeView(
                            exchange: exchange,
                            onOpen: { (passage: ArchivePassage) -> Void in
                                router.open(meetingID: passage.meetingID)
                            },
                            onSaveRecipe: { (question: String) -> Void in
                                ask.saveRecipe(question: question)
                            },
                            onRegenerate: exchange.id == ask.exchanges.last?.id ? { @MainActor () -> Void in ask.regenerate() } : nil
                        )
                        .id(exchange.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { (geometry: ScrollGeometry) -> Bool in
                isNearScrollBottom(geometry: geometry)
            } action: { (_: Bool, near: Bool) in
                isFollowingAnswer = near
            }
            .overlay(alignment: .bottom) {
                if !isFollowingAnswer, !ask.exchanges.isEmpty {
                    JumpToLatestButton {
                        withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.smooth(duration: 0.2), value: isFollowingAnswer)
            .onChange(of: ask.exchanges.last?.id) { (_: UUID?, id: UUID?) in
                // Yeni devam sorusu: sorusu ekranın üstüne gelir, cevap altına akar.
                if ask.isAnswering, let id {
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .onChange(of: ask.exchanges.last?.answer.text) { (_: String?, _: String?) in
                // Kullanıcı yukarı kaydırıp okuyorsa akan cevap onu aşağı çekmez.
                if ask.isAnswering, isFollowingAnswer {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            AskComposer(
                ask: ask, store: store, placeholder: "Devam sorusu sor…", isAnswering: ask.isAnswering,
                followUp: AskFollowUp(exchangeID: ask.exchanges.last?.id, scope: followUpScope(exchanges: ask.exchanges, records: store.meetings)),
                onSubmit: { (submission: AskSubmission) -> Void in
                    ask.ask(question: submission.question, meetingIDs: submission.meetingIDs, recipeTitle: submission.recipeTitle)
                },
                onStop: { ask.stop() }
            )
        }
        .background(Theme.background)
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Yeni sohbet", systemImage: "square.and.pencil") {
                    ask.clear()
                    router.askPath = []
                }
            }
        }
    }

    /// Başlık: saklanan sohbetin adı, henüz saklanmadıysa ilk soru.
    private var title: String {
        ask.conversations.first { $0.id == ask.currentConversationID }.map { askConversationDisplayTitle(conversation: $0) } ?? ask.exchanges.first?.question ?? ""
    }
}

/// Sohbetteki soru alanının devam kapsamı: sohbetin son sorusu (değişince kapsam yeniden yüklenir) ve onun `@`
/// toplantıları (`followUpScope`).
struct AskFollowUp {
    let exchangeID: UUID?
    let scope: [MeetingRecord]
}

/// Soru alanı ve üstünde `@` toplantı ya da "/" tarif önerileri: kökte yeni sohbet, sohbette devam sorusu gönderir.
private struct AskComposer: View {
    let ask: PhoneAsk
    let store: PhoneStore
    /// Etiketlenen toplantı yokken alanın ipucu.
    let placeholder: LocalizedStringKey
    /// Bu alanın sohbetinde cevap sürüyor: düğme durdurur.
    let isAnswering: Bool
    /// Sohbetteki alanda devam kapsamı: son soru `@` toplantılara sorulduysa etiketler alanda kalır (kaldırılabilir) ve
    /// devam sorusu da onlara gider. Kökte nil: gönderilince etiketler kalkar.
    let followUp: AskFollowUp?
    let onSubmit: @MainActor (AskSubmission) -> Void
    let onStop: @MainActor () -> Void
    @State private var question: String = ""
    /// Soru alanındaki seçim (kullanıcı imleci taşıyınca `cursor`'ı günceller); alan odakta değilken nil.
    @State private var selection: TextSelection?
    /// İmlecin konumu (UTF-16): `@` bahsi bunun önünde aranır. Yazınca düzenlemeden (`editedCursor`), imleç taşınınca
    /// seçimden güncellenir. iOS 26'da dikey `TextField` yazarken seçimi her zaman güncellemez ya da iç metninin indeksini
    /// bildirir; yalnız seçime bakınca gerçek iPhone'da `@` önerileri hiç açılmıyordu.
    @State private var cursor: Int?
    /// `@` ile etiketlenen toplantılar: soru yalnız onlara sorulur; soru gönderilince alandan kalkar.
    @State private var mentioned: [MeetingRecord] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if isMentioning, let cursor {
                // İmleç çizim anındaki haliyle alınır: dokunuş sırasında odak kaybolsa da doğru bahis silinir.
                MentionSuggestions(
                    candidates: mentionMatches,
                    highlighted: -1
                ) { (record: MeetingRecord) -> Void in
                    pick(record: record, cursor: cursor)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if isPickingRecipe {
                RecipeSuggestions(
                    recipes: recipeMatches, highlighted: -1
                ) { (recipe: Recipe) -> Void in
                    guard !isAnswering else {
                        return
                    }
                    onSubmit(AskSubmission(question: recipe.prompt, meetingIDs: mentioned.map(\.id), recipeTitle: recipe.title))
                    clearQuestion()
                    clearMentionsAfterSending()
                    isFocused = false
                } onDelete: { (recipe: Recipe) -> Void in
                    ask.deleteRecipe(id: recipe.id)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            field
        }
        .animation(.smooth(duration: 0.2), value: isMentioning || isPickingRecipe)
        .onChange(of: question) { (old: String, new: String) in
            if let edited = editedCursor(old: old, new: new) {
                cursor = edited
            }
        }
        .onChange(of: selection) { (_: TextSelection?, _: TextSelection?) in
            if let selected = selectionCursor {
                cursor = selected
            }
        }
        .onChange(of: followUp?.exchangeID, initial: true) { (_: UUID?, _: UUID?) in
            // Yeni soru, açılan sohbet ya da yeniden oluşturma: etiketler sohbetin son sorusunun kapsamına döner.
            if let followUp {
                mentioned = followUp.scope
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background {
            // Kayan içerik alanın arkasında zemine doğru solar (alanın altı ve çevresi sakin kalır).
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                .padding(.top, -20)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        // Alanın çevresi (kenar boşlukları) de bu görünümündür: arkasındaki örnek kartlara ya da sohbet içeriğine geçmez,
        // dokununca soru alanı odaklanır (gerçek iPhone'da alana basmaya çalışırken örnek soru açılıyordu).
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
        }
    }

    private var field: some View {
        let isEmpty: Bool = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            if !mentioned.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(mentioned, id: \.id) { (record: MeetingRecord) in
                            RemovableMentionChip(title: record.note?.title ?? record.title) {
                                withAnimation(.smooth(duration: 0.2)) { mentioned.removeAll { $0.id == record.id } }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    mentioned.isEmpty ? placeholder : "Etiketlenen toplantılara sor…",
                    text: $question, selection: $selection, axis: .vertical
                )
                .appFont(size: 16, weight: .regular)
                // Return yeni satır ekler (çok satırlı soru); gönderme sağdaki düğmeyle.
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.vertical, 8)
                Button {
                    if isAnswering {
                        onStop()
                    } else {
                        send()
                    }
                } label: {
                    Image(systemName: isAnswering ? "stop.fill" : "arrow.up")
                        .appFont(size: 14, weight: .bold)
                        .foregroundStyle(Theme.onPrimary)
                        .frame(width: 34, height: 34)
                        .background(isEmpty && !isAnswering ? Theme.muted.opacity(0.5) : Theme.primary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isEmpty && !isAnswering)
                .accessibilityLabel(isAnswering ? "Durdur" : "Sor")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Kutunun tamamı (yalnız yazı satırı değil) alanı odaklar; gönder düğmesi ve etiket çipleri kendi dokunuşunu alır.
        .contentShape(shape)
        .onTapGesture {
            isFocused = true
        }
        .background { shape.fill(Theme.card) }
        .overlay {
            if isAnswering {
                ThinkingRing(shape: shape)
            } else {
                shape.strokeBorder(Theme.line)
            }
        }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 4)
    }

    /// Seçimin gösterdiği imleç (UTF-16); alan odakta değilse, birden çok seçim varsa ya da seçim bu metne ait değilse nil
    /// (iOS 26 boş alanda iç metninden indeks bildirir).
    private var selectionCursor: Int? {
        guard let selection, case .selection(let range) = selection.indices else {
            return nil
        }
        return cursorOffset(text: question, index: range.upperBound)
    }

    /// İmlecin önündeki `@` bahsi; alan odakta değilse yok (klavye kapanınca öneriler de kapanır).
    private var mention: MentionQuery? {
        guard isFocused else {
            return nil
        }
        return cursor.flatMap { (cursor: Int) -> MentionQuery? in mentionQuery(text: question, cursor: cursor) }
    }

    /// `@` önerileri (en fazla 5); bahis yoksa boş.
    private var mentionMatches: [MeetingRecord] {
        guard let mention else {
            return []
        }
        return mentionCandidates(records: store.meetings, query: mention.query, excluding: mentioned.map(\.id), limit: 5)
    }

    /// "/" ile eşleşen tarifler; "/" yoksa boş.
    private var recipeMatches: [Recipe] {
        guard let query = recipeQuery(text: question) else {
            return []
        }
        return recipeCandidates(recipes: ask.recipes, query: query)
    }

    /// `@` önerileri açık: eşleşen toplantı var.
    private var isMentioning: Bool {
        !mentionMatches.isEmpty
    }

    /// "/" önerileri açık: eşleşen tarif var.
    private var isPickingRecipe: Bool {
        !recipeMatches.isEmpty
    }

    /// Toplantıyı etikete ekler; yazılan "@…" silinir, imleç onun yerine gelir.
    private func pick(record: MeetingRecord, cursor drawnCursor: Int) {
        guard let edit = removingMention(text: question, cursor: drawnCursor) else {
            preconditionFailure("Toplantı önerisi seçildi ama imlecin önünde @ bahsi yok")
        }
        withAnimation(.smooth(duration: 0.2)) { mentioned.append(record) }
        question = edit.text
        cursor = edit.cursor
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: edit.cursor, in: edit.text))
    }

    /// Soru alanını boşaltır; seçim de birlikte sıfırlanır: eski metnin indeksi boş metinde geçersizdir.
    private func clearQuestion() {
        question = ""
        selection = nil
        cursor = nil
    }

    private func send() {
        // Öneri seçilirken gönderilmez; eşleşen öneri yoksa soru olduğu gibi gider.
        guard !isAnswering, !isMentioning, !isPickingRecipe, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        // Hakkı yoksa soru alanı temizlenmez (abone olunca yeniden gönderilebilsin); abonelik ekranı açılır.
        if HostedAccount.shared.requiresSubscription {
            HostedAccount.shared.requestSubscription()
            return
        }
        onSubmit(AskSubmission(question: question, meetingIDs: mentioned.map(\.id), recipeTitle: nil))
        clearQuestion()
        clearMentionsAfterSending()
        isFocused = false
    }

    /// Kökte etiketler gönderilen soruya aitti: sohbette sorunun üstünde kalır, alandan kalkar. Sohbette kapsam devam
    /// sorularına taşınır: etiketler alanda kalır (kullanıcı kaldırana dek).
    private func clearMentionsAfterSending() {
        if followUp == nil {
            withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
        }
    }
}

/// Sohbet geçmişi: üstte arama alanı ve süzgeç menüsü (seçili süzgeç çip olur), altında yeniden eskiye sohbetler (tür
/// simgesi, başlık, tarih). Dokununca açılır; sola kaydırınca ya da basılı tutunca adı değiştirilir ya da silinir.
private struct AskHistoryList: View {
    let ask: PhoneAsk
    let onOpen: @MainActor (UUID) -> Void
    @State private var query: String = ""
    @State private var filter: AskHistoryFilter = .all
    /// Adı değiştirilen sohbet (ad sayfası açık).
    @State private var renaming: AskConversation?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shown: [AskConversation] = filteredAskConversations(conversations: ask.conversations, query: query, filter: filter)
        List {
            Section {
                if shown.isEmpty, !ask.conversations.isEmpty {
                    AskHistoryNoMatches(size: 15)
                        .padding(.vertical, 4)
                }
                ForEach(shown) { (conversation: AskConversation) in
                    Button {
                        onOpen(conversation.id)
                    } label: {
                        AskHistoryRowLabel(conversation: conversation, isSelected: ask.currentConversationID == conversation.id, titleSize: 15)
                            .padding(.vertical, 2)
                    }
                    .swipeActions {
                        Button("Sil", role: .destructive) { ask.delete(conversationID: conversation.id) }
                        Button("Adını değiştir") { renaming = conversation }
                            .tint(appearance.accent.color)
                    }
                    .contextMenu {
                        Button("Adını değiştir", systemImage: "pencil") { renaming = conversation }
                        Button("Sohbeti sil", systemImage: "trash", role: .destructive) { ask.delete(conversationID: conversation.id) }
                    }
                }
            } header: {
                if !ask.conversations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        AskHistorySearchBar(query: $query, filter: $filter, size: 15)
                        if filter != .all {
                            AskHistoryFilterChip(filter: filter, size: 13) { filter = .all }
                        }
                    }
                    .textCase(nil)
                    .padding(.bottom, 6)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if ask.conversations.isEmpty {
                PhoneEmptyState(symbol: "bubble.left.and.text.bubble.right", title: "Saklanan sohbet yok", message: "Sorduğun sorular burada saklanır.") {
                    EmptyView()
                }
            }
        }
        .sheet(item: $renaming) { (conversation: AskConversation) in
            PhoneTextEntrySheet(
                title: "Sohbetin adı", placeholder: "Ad", actionTitle: "Kaydet", initialText: askConversationDisplayTitle(conversation: conversation)
            ) { (title: String) -> Void in
                ask.rename(conversationID: conversation.id, title: title)
            }
        }
        .navigationTitle("Geçmiş")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
