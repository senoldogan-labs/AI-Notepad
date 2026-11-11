import AINotepadCore
import AINotepadUI
import os
import SwiftUI

/// Sor (iPhone): sohbetler `AskStore`'da (Mac'le aynı motor; Sor sayfası, toplantı sayfasının çubuğu, klasör ve kişi
/// sayfalarından açılan Sor), cevabı `answerAskTarget` yazar (arama terimleri → parçalar → akan cevap); yapay zekâ
/// çağrısı hesabın payından (sunucu üzerinden Claude). Sohbetler her cevaptan sonra bu iPhone'da hesabın klasöründe
/// saklanır ve geçmişten yeniden açılır.
@MainActor
@Observable
final class PhoneAsk {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneAsk")

    /// Sor alanlarının sohbetleri (bağlam → sohbet; bkz. `AskStore`).
    let chats: AskStore = AskStore()
    /// Saklanan sohbetler (yeniden eskiye; en fazla `askHistoryLimit`).
    private(set) var conversations: [AskConversation] = []
    /// Sohbet geçmişinin okunamama, saklanamama ya da silinememe nedeni.
    private(set) var historyError: String?
    @ObservationIgnored private let store: PhoneStore

    init(store: PhoneStore) {
        self.store = store
    }

    /// Bir Sor alanında (`context`) cevap sürüyor.
    var isAnsweringAny: Bool {
        chats.chats.keys.contains { chats.isAnswering(context: $0) }
    }

    /// Soruyu bir Sor alanından (`context`) `scope` kapsamına sorar; `mentionIDs` doluysa yalnız o toplantılara (`@`).
    /// Hakkı yoksa abonelik ekranı açılır (Mac'teki gibi), deneme başlamadıysa neden sohbette. Süren cevap varken yeni
    /// soru sorulmaz (kullanım da sayılmaz). iPhone ekran görüntüsü almaz; "Notta fotoğrafları kullan" açıksa okunan
    /// parçalar konuşulurken çekilen fotoğraflar soruyla gider.
    func ask(context: AskScope, question: String, scope: AskScope, mentionIDs: [String], recipeTitle: String?) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !chats.isAnswering(context: context) else {
            return
        }
        // Without consent to the AI disclosure nothing is sent: the reason stays in the chat and the disclosure opens.
        guard HostedAIConsentCenter.shared.isGranted else {
            chats.fail(context: context, question: question, scope: scope, mentionIDs: mentionIDs, recipeTitle: recipeTitle, reason: hostedAIConsentRequiredMessage())
            HostedAIConsentCenter.shared.requestPrompt()
            return
        }
        if HostedAccount.shared.requiresSubscription {
            HostedAccount.shared.requestSubscription()
            return
        }
        // Deneme ilk toplantıyla başlar: henüz toplantısı olmayan denemedeki hesap önce kayıt yapmalı (sunucu
        // çağrılmaz; diğer retler sunucunun hatasıyla gösterilir).
        if let reason = hostedAskUnavailableReason(account: HostedAccount.shared) {
            chats.fail(context: context, question: question, scope: scope, mentionIDs: mentionIDs, recipeTitle: recipeTitle, reason: reason)
            return
        }
        recordFeatureUsage(feature: .ask)
        let records: [MeetingRecord] = store.meetings
        let userName: String = store.userName
        let profile: UserProfile = store.userProfile
        let webSearch: Bool = askWebSearchAllowed(defaults: UserDefaults.standard)
        let noteLanguage: ShareLanguage = phoneNoteLanguage()
        let store: PhoneStore = self.store
        chats.ask(
            context: context, question: question, scope: scope, mentionIDs: mentionIDs, recipeTitle: recipeTitle, records: records
        ) { (target: AskTarget, onProgress: @escaping ArchiveProgressHandler) async throws -> Void in
            let screens: ArchiveScreensPlan = try phoneAskScreensPlan(store: store, records: target.meetings ?? records)
            let provider: LLMProvider = try phoneAccountLLMProvider()
            // Cevap sorunun dilinde (İngilizce soruya Türkçe notlardan da İngilizce); anlaşılmazsa arayüz dili.
            let answerLanguage: ShareLanguage = askAnswerLanguage(question: target.question, history: target.history, interfaceLanguage: interfaceShareLanguage())
            _ = try await answerAskTarget(
                target: target, archive: records, userName: userName, profile: profile, noteLanguage: noteLanguage, answerLanguage: answerLanguage,
                provider: provider, screens: screens, webSearch: webSearch, onProgress: onProgress
            )
        } save: { [weak self] (id: UUID, exchanges: [ArchiveExchange]) -> Void in
            // Sohbet Sor geçmişine yazılır (Mac'le eşitlenir, Sor'da da açılır); toplantı sayfası yeniden açılınca geri gelir.
            self?.storeConversation(id: id, exchanges: exchanges)
        }
    }

    /// Sor alanının son sorusunu aynı kapsam, etiketler ve tarifle yeniden sorar; sorulamazsa (abonelik ekranı açıldı)
    /// eski cevap yerinde kalır.
    func regenerate(context: AskScope) {
        guard let last = chats.takeLastForRegenerate(context: context) else {
            return
        }
        let remaining: Int = chats.exchanges(context: context).count
        ask(context: context, question: last.question, scope: last.scope, mentionIDs: exchangeMentionIDs(exchange: last), recipeTitle: last.recipeTitle)
        if chats.exchanges(context: context).count == remaining {
            chats.restore(exchange: last, context: context)
        }
    }

    /// Yeni bir sohbette soruyu Sor sayfasında sorar (ana ekrandaki soru, brifing, tarif): süren cevap durur, önceki sohbet
    /// geçmişte kalır.
    func startConversation(question: String, scope: AskScope, mentionIDs: [String], recipeTitle: String?) {
        chats.clear(context: .allMeetings)
        chats.select(scope: scope, context: .allMeetings)
        ask(context: .allMeetings, question: question, scope: scope, mentionIDs: mentionIDs, recipeTitle: recipeTitle)
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

    /// Kısayollar ve Siri: soruyu Sor sayfasında yeni bir sohbette bütün toplantılara sorar ve cevabı bekler (sohbet geçmişte
    /// kalır). Sorulamazsa (abonelik, deneme, süren başka soru) ya da cevap yarıda kalırsa nedeni hata olarak döner;
    /// abonelik ekranı açılmaz (uygulama arka planda olabilir).
    func askForIntent(question: String) async throws -> String {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingIntentError.askFailed(reason: String(localized: "Soru boş."))
        }
        // Siri, Shortcuts and the keyboard's Ask: nothing is sent without consent; the reason says where to give it.
        guard HostedAIConsentCenter.shared.isGranted else {
            throw MeetingIntentError.askFailed(reason: hostedAIConsentRequiredMessage())
        }
        if HostedAccount.shared.requiresSubscription {
            throw MeetingIntentError.askFailed(reason: String(localized: "Sor için abonelik gerekiyor; uygulamayı açıp bir plan seç."))
        }
        if let reason = hostedAskUnavailableReason(account: HostedAccount.shared) {
            throw MeetingIntentError.askFailed(reason: reason)
        }
        guard !chats.isAnswering(context: .allMeetings) else {
            throw MeetingIntentError.askFailed(reason: String(localized: "Sor'da başka bir soru cevaplanıyor; o bitince yeniden dene."))
        }
        // Her soru yeni sohbette: Sor sayfasında açık kalan (başka kapsamlı olabilen) sohbetin turları modele bağlam
        // gitmez ve Siri turu o sohbete yazılmaz; eski sohbet geçmişte kalır.
        chats.clear(context: .allMeetings)
        let before: Int = chats.exchanges(context: .allMeetings).count
        ask(context: .allMeetings, question: trimmed, scope: .allMeetings, mentionIDs: [], recipeTitle: nil)
        guard chats.exchanges(context: .allMeetings).count > before, let id = chats.exchanges(context: .allMeetings).last?.id else {
            throw MeetingIntentError.askFailed(reason: String(localized: "Soru gönderilemedi."))
        }
        // Bekleyen iş iptal edilirse (klavyeden gelen soru bırakıldı ya da arka plan süresi doldu) soru da durur: Sor
        // alanı meşgul kalmaz, sonraki soru hemen sorulabilir.
        let chats: AskStore = chats
        await withTaskCancellationHandler {
            await chats.waitForAnswer(context: .allMeetings)
        } onCancel: {
            Task { @MainActor in
                chats.stop(context: .allMeetings)
            }
        }
        try Task.checkCancellation()
        guard let exchange = chats.exchanges(context: .allMeetings).first(where: { $0.id == id }) else {
            throw MeetingIntentError.askFailed(reason: String(localized: "Soru gönderilemedi."))
        }
        switch exchange.phase {
        case .done:
            return exchange.answer.text
        case .failed(let reason):
            throw MeetingIntentError.askFailed(reason: reason)
        case .understanding, .searching, .writing, .stopped:
            throw MeetingIntentError.askFailed(reason: String(localized: "Cevap yarıda kaldı."))
        }
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

    #if DEBUG
    /// `--ask-gecmis` (yalnız Debug, görsel kontrol): saklanan sohbet yoksa geçmiş sayfası örnek sohbetlerle dolar (yalnız
    /// bellekte; diske yazılmaz, eşitlenmez).
    func showSampleHistory(now: Date) {
        guard conversations.isEmpty else {
            return
        }
        conversations = sampleAskConversations(now: now)
    }
    #endif

    /// Saklanan sohbeti Sor alanında kendi kapsamıyla açar; devam soruları onun cevaplarını bağlam alır. Süren cevap
    /// durdurulur.
    func open(conversationID: UUID, context: AskScope) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
            return
        }
        chats.open(conversation: conversation, context: context)
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
            chats.forget(conversationID: conversationID)
        } catch {
            Self.logger.error("Sohbet silinemedi, sohbet: \(conversationID.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet silinemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Sohbeti bitmiş sorularıyla Sor geçmişine yazar (Sor sekmesi ve toplantı sayfasının sohbeti); sınırı aşan en eski
    /// sohbetler silinir. Saklanamazsa neden geçmişin hatasında görünür ve false döner.
    @discardableResult
    private func storeConversation(id: UUID, exchanges: [ArchiveExchange]) -> Bool {
        let turns: [AskConversationTurn] = exchanges.compactMap { (exchange: ArchiveExchange) -> AskConversationTurn? in askTurn(exchange: exchange) }
        guard !turns.isEmpty else {
            return false
        }
        let conversation: AskConversation = askConversation(existing: conversations.first { $0.id == id }, id: id, turns: turns, now: Date())
        do {
            let directory: URL = try AppPaths.askHistoryDirectory()
            try saveAskConversation(conversation: conversation, directory: directory)
            conversations = upsertAskConversation(conversations: conversations, conversation: conversation)
            for old in askConversationsBeyondLimit(conversations: conversations, limit: askHistoryLimit) {
                try deleteAskConversation(id: old.id, directory: directory)
                conversations.removeAll { $0.id == old.id }
            }
        } catch {
            Self.logger.error("Sohbet saklanamadı, sohbet: \(id.uuidString, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            historyError = String(localized: "Sohbet saklanamadı: \(userFacingMessage(error: error))")
            return false
        }
        return true
    }
}

/// Soru alanından gönderilen soru: metin, `@` ile etiketlenen toplantılar ve (tariften geldiyse) tarifin adı.
struct AskSubmission {
    let question: String
    let meetingIDs: [String]
    let recipeTitle: String?
}

/// Sor (ana ekrandaki "Bir şey sor"): sakin başlangıç (başlık, örnek soru hapları, son sohbetler) ve altta soru alanı;
/// web araması ayarı Ayarlar'da. Soru gönderilince ya da bir sohbet açılınca sohbet üstüne açılır; onun geri oku buraya,
/// buranın geri oku ana ekrana döner.
struct AskTab: View {
    let ask: PhoneAsk
    let store: PhoneStore
    let router: PhoneRouter

    /// Son sohbetlerde kaydedilmemiş (süren) sohbetin satır kimliği.
    private let currentChatID: String = "current"

    /// Kökte gösterilen en yeni sohbet sayısı (toplantıda, klasörde ya da kişide sorulanlar da); tümü geçmişte.
    private let recentLimit: Int = 5
    /// Kökteki soru alanının kapsamı (yeni sohbet buna sorulur; çipten değişir).
    @State private var rootScope: AskScope = .allMeetings

    var body: some View {
        Group {
            if isEmpty {
                // Henüz toplantı ve sohbet yok: sorulacak bir şey yok, ortada kısa bir boş durum ve kayda geçiş.
                PhoneEmptyScene(
                    symbol: "sparkle.magnifyingglass", palette: .violet, title: "Sorulacak toplantı yok",
                    message: "İlk toplantını kaydet; sonra notlarına buradan soru sor, cevap kaynağıyla gelsin."
                ) {
                    Button("Kaydı başlat", systemImage: "mic.fill") { router.showHome() }
                        .buttonStyle(.accentPill)
                        .controlSize(.large)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        PhoneErrorList(messages: [ask.historyError, ask.recipeError].compactMap { $0 })
                        AskGreeting(firstName: askFirstName(userName: store.userName), size: 28)
                            .padding(.top, 48)
                            .padding(.bottom, 12)
                        // Toplantı yokken öneriler boş cevap verirdi: yerine kısa bir satır.
                        if store.meetings.isEmpty {
                            Text("Sorulacak toplantı yok")
                                .appFont(size: 14, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity)
                        }
                        if hasRecent {
                            AskRecentChats(
                                chats: recentChats,
                                onOpen: { (id: String) -> Void in openRecent(id: id) },
                                onSeeAll: ask.conversations.isEmpty ? nil : { router.isAskHistoryOpen = true }
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
                // Selamlamanın arkasında durgun pastel gradyan (sayfanın zeminine solar).
                .background(alignment: .top) {
                    AskBackdrop()
                        .frame(height: 400)
                        .ignoresSafeArea(edges: .top)
                }
                .safeAreaInset(edge: .bottom) {
                    AskComposer(
                        ask: ask, store: store, placeholder: askComposerPlaceholder(scope: rootScope), isAnswering: false, followUp: nil,
                        suggestions: askSuggestions(scope: rootScope, records: store.meetings, userName: store.userName, now: Date(), calendar: Calendar.current, limit: 4).map { askSuggestionText(suggestion: $0) },
                        scopeMenu: askScopeMenu(context: .allMeetings, selected: rootScope, records: store.meetings, folders: store.folders, userName: store.userName),
                        onSelectScope: { (scope: AskScope) -> Void in rootScope = scope },
                        onSubmit: { (submission: AskSubmission) -> Void in startConversation(submission: submission) },
                        onStop: { ask.chats.stop(context: .allMeetings) }
                    )
                }
            }
        }
        .background(Theme.background)
        .navigationTitle("Sor")
        .navigationBarTitleDisplayMode(.inline)
        // Tam ekran Sor: sol üstte kapat, sağ üstte geçmiş.
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Kapat", systemImage: "xmark") { router.closeAsk() }
            }
            if !ask.conversations.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Geçmiş", systemImage: "clock.arrow.circlepath") { router.isAskHistoryOpen = true }
                }
            }
        }
    }

    /// Kaydedilmemiş (ilk cevabı süren ya da yarıda kalan) açık sohbet: son sohbetlerin başında "sohbete dön" satırı.
    private var unsavedQuestion: String? {
        ask.chats.conversationID(context: .allMeetings) == nil ? ask.chats.exchanges(context: .allMeetings).first?.question : nil
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
        let isAnswering: Bool = ask.chats.isAnswering(context: .allMeetings)
        let current: [AskRecentChat] = unsavedQuestion.map { (question: String) -> [AskRecentChat] in
            [AskRecentChat(
                id: currentChatID, title: question,
                detail: isAnswering ? String(localized: "Cevaplanıyor…") : String(localized: "Şimdi"), isAnswering: isAnswering
            )]
        } ?? []
        let saved: [AskRecentChat] = ask.conversations.prefix(recentLimit - current.count).map { (conversation: AskConversation) -> AskRecentChat in
            AskRecentChat(
                id: conversation.id.uuidString, title: askConversationDisplayTitle(conversation: conversation),
                detail: askRecentChatDetail(conversation: conversation, now: now),
                isAnswering: ask.chats.isAnswering(conversationID: conversation.id)
            )
        }
        return current + saved
    }

    /// Son sohbetler satırı: süren sohbete döner ya da saklanan sohbeti açar.
    private func openRecent(id: String) {
        guard id != currentChatID else {
            router.openAskConversation()
            return
        }
        guard let uuid = UUID(uuidString: id) else {
            preconditionFailure("Son sohbet kimliği UUID değil: \(id)")
        }
        openConversation(id: uuid)
    }

    /// Kökten gönderilen soru yeni sohbet başlatır (süren cevap durur; önceki sohbet geçmişte kalır) ve sohbeti açar.
    private func startConversation(submission: AskSubmission) {
        ask.startConversation(question: submission.question, scope: rootScope, mentionIDs: submission.meetingIDs, recipeTitle: submission.recipeTitle)
        rootScope = .allMeetings
        router.openAskConversation()
    }

    /// Saklanan sohbeti açar.
    private func openConversation(id: UUID) {
        openAskConversation(ask: ask, router: router, id: id)
    }
}

/// Saklanan sohbeti açar (Sor'un üstünde; geçmiş sayfası kapanır); zaten açık olan sohbet yeniden yüklenmez (süren
/// cevabı kesilmez).
@MainActor
private func openAskConversation(ask: PhoneAsk, router: PhoneRouter, id: UUID) {
    if ask.chats.conversationID(context: .allMeetings) != id || ask.chats.exchanges(context: .allMeetings).isEmpty {
        ask.open(conversationID: id, context: .allMeetings)
    }
    router.openAskConversation()
}

#if DEBUG
/// Geçmiş sayfasının görsel kontrolü için örnek sohbetler (bugün, bu hafta, bu ay ve daha önce), yeniden eskiye.
private func sampleAskConversations(now: Date) -> [AskConversation] {
    let samples: [(question: String, answer: String, hoursAgo: Double)] = [
        ("What happened in the pricing review?", "**Maria** proposed moving the Pro plan to €14 [1]; the team agreed to test it with new sign-ups first.", 0.2),
        ("What do I owe people this week?", "You have three open tasks: send the Q3 deck to Mikko, review the hiring plan and book the offsite venue [2].", 5),
        ("Summarise the investor update", "Revenue grew 18% month over month; churn stayed under 2%. Next round planned for spring [1].", 52),
        ("Who raised concerns about the launch date?", "Anna and Jussi both asked for two more weeks of QA before the public launch [3].", 24 * 9),
        ("Decisions from the design offsite", "The team chose the warm ember palette, dropped animated backgrounds and agreed on one note layout for Mac and iPhone.", 24 * 40),
    ]
    return samples.map { (sample: (question: String, answer: String, hoursAgo: Double)) -> AskConversation in
        let at: Date = now.addingTimeInterval(-sample.hoursAgo * 3600)
        let turn: AskConversationTurn = AskConversationTurn(
            id: UUID(), question: sample.question, scopeMeetingIDs: [], scopeTitles: [], recipeTitle: nil, startedAt: at, finishedAt: at,
            terms: [], readPassages: [], readScreens: nil, answer: sample.answer, sources: [], webSources: nil, webQueries: nil,
            webSearchNotice: nil, skippedMeetings: nil, wasStopped: nil, scope: .allMeetings
        )
        return askConversation(existing: nil, id: UUID(), turns: [turn], now: at)
    }
}
#endif

/// Sor'un sohbet geçmişini alttan açılan sayfada sunar (`PhoneRouter.isAskHistoryOpen`); sohbete dokununca sayfa kapanır ve
/// sohbet Sor'un üstünde açılır.
struct AskHistorySheetHost: ViewModifier {
    let ask: PhoneAsk
    @Bindable var router: PhoneRouter

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $router.isAskHistoryOpen) {
                AskHistorySheet(ask: ask) { (id: UUID) -> Void in
                    openAskConversation(ask: ask, router: router, id: id)
                }
            }
    }
}

/// Sohbet: soru-cevaplar (Mac'teki ile aynı görünüm) ve altta kapsam çipiyle soru alanı. Bağlam Sor sayfasıysa sol
/// üstteki geri Sor'u getirir (süren cevap durmaz), sağ üstteki "Yeni sohbet" sohbeti kapatıp Sor'a döner; klasörden ya
/// da kişiden açılan Sor'da (bağlam o kapsam) "Yeni sohbet" sohbeti burada boşaltır. Kapsam bir toplantıysa hazır
/// eylemler ve devam soruları da görünür.
struct AskConversationView: View {
    let ask: PhoneAsk
    let store: PhoneStore
    let router: PhoneRouter
    /// Sor alanının bağlamı (bkz. `AskStore`).
    let context: AskScope

    private let bottomID: String = "ask-bottom"
    /// Sohbetin sonu görünüyor: akan cevap izlenir; yukarı kaydırınca izleme durur, "sona git" düğmesi çıkar.
    @State private var isFollowingAnswer: Bool = true

    private var exchanges: [ArchiveExchange] {
        ask.chats.exchanges(context: context)
    }

    private var isAnswering: Bool {
        ask.chats.isAnswering(context: context)
    }

    private var scope: AskScope {
        ask.chats.scope(context: context)
    }

    /// Kapsamdaki toplantının notu (kapsam bir toplantıysa): hazır eylemler ve devam soruları ondan.
    private var scopeNote: MeetingNote? {
        askScopeMeetingID(scope: scope).flatMap { (id: String) -> MeetingNote? in store.meetings.first { $0.id == id }?.note }
    }

    var body: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PhoneErrorList(messages: [ask.historyError, ask.recipeError].compactMap { $0 })
                    if exchanges.isEmpty {
                        intro
                    }
                    ForEach(exchanges) { (exchange: ArchiveExchange) in
                        ExchangeView(
                            exchange: exchange,
                            onOpen: { (passage: ArchivePassage) -> Void in
                                router.open(source: passage)
                            },
                            onSaveRecipe: { (question: String) -> Void in
                                ask.saveRecipe(question: question)
                            },
                            onRegenerate: exchange.id == exchanges.last?.id ? { @MainActor () -> Void in ask.regenerate(context: context) } : nil,
                            // Kapsam dipnotundaki "Bunlara da sor": aynı soru sığmayan toplantılara `@` ile sorulur.
                            onAskMeetings: isAnswering ? nil : { @MainActor (meetingIDs: [String]) -> Void in
                                ask.ask(context: context, question: exchange.question, scope: exchange.scope, mentionIDs: meetingIDs, recipeTitle: exchange.recipeTitle)
                            }
                        )
                        .id(exchange.id)
                    }
                    let followUps: [String] = ask.chats.followUps(context: context, note: scopeNote)
                    if !isAnswering, !followUps.isEmpty {
                        AskFollowUpChips(questions: followUps) { (question: String) -> Void in
                            ask.ask(context: context, question: question, scope: scope, mentionIDs: [], recipeTitle: nil)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            // Boş sohbette (klasörden ya da kişiden açılan Sor) selamlamanın arkasında durgun pastel gradyan.
            .background(alignment: .top) {
                if exchanges.isEmpty {
                    AskBackdrop()
                        .frame(height: 400)
                        .ignoresSafeArea(edges: .top)
                }
            }
            .onScrollGeometryChange(for: Bool.self) { (geometry: ScrollGeometry) -> Bool in
                isNearScrollBottom(geometry: geometry)
            } action: { (_: Bool, near: Bool) in
                isFollowingAnswer = near
            }
            .overlay(alignment: .bottom) {
                if !isFollowingAnswer, !exchanges.isEmpty {
                    JumpToLatestButton {
                        withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    }
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.smooth(duration: 0.2), value: isFollowingAnswer)
            .onChange(of: exchanges.last?.id) { (_: UUID?, id: UUID?) in
                // Yeni devam sorusu: sorusu ekranın üstüne gelir, cevap altına akar.
                if isAnswering, let id {
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .onChange(of: exchanges.last?.answer.text) { (_: String?, _: String?) in
                // Kullanıcı yukarı kaydırıp okuyorsa akan cevap onu aşağı çekmez.
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
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if scopeNote != nil, !isAnswering {
                    AskQuickActionChips(actions: meetingQuickActions(recipes: ask.recipes), isEnabled: !isAnswering) { (action: MeetingQuickAction) -> Void in
                        run(action: action)
                    }
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                AskComposer(
                    ask: ask, store: store,
                    placeholder: exchanges.isEmpty || scope != .allMeetings ? askComposerPlaceholder(scope: scope) : String(localized: "Devam sorusu sor…"),
                    isAnswering: isAnswering,
                    followUp: AskFollowUp(exchangeID: exchanges.last?.id, scope: followUpScope(exchanges: exchanges, records: store.meetings)),
                    suggestions: exchanges.isEmpty ? askSuggestions(scope: scope, records: store.meetings, userName: store.userName, now: Date(), calendar: Calendar.current, limit: 4).map { askSuggestionText(suggestion: $0) } : [],
                    scopeMenu: askScopeMenu(context: context, selected: scope, records: store.meetings, folders: store.folders, userName: store.userName),
                    onSelectScope: { (selected: AskScope) -> Void in ask.chats.select(scope: selected, context: context) },
                    onSubmit: { (submission: AskSubmission) -> Void in
                        ask.ask(context: context, question: submission.question, scope: scope, mentionIDs: submission.meetingIDs, recipeTitle: submission.recipeTitle)
                    },
                    onStop: { ask.chats.stop(context: context) }
                )
            }
        }
        .background(Theme.background)
        .navigationTitle(Text(verbatim: title))
        .navigationBarTitleDisplayMode(.inline)
        // Tam ekran Sor: sol üstte kapat (Sor kapanır, gelinen sayfa kalır), sağ üstte geçmiş ve yeni sohbet.
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Kapat", systemImage: "xmark") { router.closeAsk() }
            }
            if !ask.conversations.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Geçmiş", systemImage: "clock.arrow.circlepath") { router.isAskHistoryOpen = true }
                }
            }
            if !exchanges.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Yeni sohbet", systemImage: "square.and.pencil") {
                        ask.chats.clear(context: context)
                        if context == .allMeetings {
                            router.returnToAsk()
                        }
                    }
                }
            }
        }
    }

    /// Boş sohbet (klasörden ya da kişiden açılan Sor): selamlama ve ne okunduğu; öneriler soru alanının üstünde.
    private var intro: some View {
        VStack(spacing: 12) {
            AskGreeting(firstName: askFirstName(userName: store.userName), size: 28)
            Text("Kararlar, görevler ya da kimin ne dediği: cevap kapsamdaki toplantıların notlarından ve transkriptlerinden, kaynağıyla gelir.")
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 48)
    }

    /// Hazır eylem: tarif kapsamdaki toplantıya sorulur, "Notu uzat" o toplantının notunu yeniden yazar.
    private func run(action: MeetingQuickAction) {
        guard let meetingID = askScopeMeetingID(scope: scope) else {
            return
        }
        switch action.kind {
        case .ask(let prompt, let recipeTitle):
            ask.ask(context: context, question: prompt, scope: scope, mentionIDs: [], recipeTitle: recipeTitle)
        case .editNote(let instruction):
            Task { await store.editNote(meetingID: meetingID, instruction: instruction) }
        }
    }

    /// Başlık: saklanan sohbetin adı, henüz saklanmadıysa ilk soru, boşsa kapsamın adı.
    private var title: String {
        ask.conversations.first { $0.id == ask.chats.conversationID(context: context) }.map { askConversationDisplayTitle(conversation: $0) }
            ?? exchanges.first?.question ?? askScopeTitle(scope: scope, context: context, meetingTitle: nil)
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
    /// Etiketlenen toplantı yokken alanın ipucu (kapsama göre).
    let placeholder: String
    /// Bu alanın sohbetinde cevap sürüyor: düğme durdurur.
    let isAnswering: Bool
    /// Sohbetteki alanda devam kapsamı: son soru `@` toplantılara sorulduysa etiketler alanda kalır (kaldırılabilir) ve
    /// devam sorusu da onlara gider. Kökte nil: gönderilince etiketler kalkar.
    let followUp: AskFollowUp?
    /// Boş sohbette alanın üstünde yana kayan öneriler (kullanıcının verisinden); dokununca sorulur.
    let suggestions: [String]
    /// Alanın üstündeki kapsam çipi (etiket yokken görünür).
    let scopeMenu: AskScopeMenu
    let onSelectScope: @MainActor (AskScope) -> Void
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
    /// Sesle soru (mikrofon düğmesi); uygulamada tek, bu alan `dictationOwner` kimliğiyle kullanır.
    @Environment(AskDictation.self) private var askDictation: AskDictation
    @Environment(PhoneRecorder.self) private var recorder: PhoneRecorder
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @State private var dictationOwner: UUID = UUID()

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
            } else if question.isEmpty, mentioned.isEmpty, !isAnswering, !suggestions.isEmpty {
                AskSuggestionRow(suggestions: suggestions) { (suggestion: String) -> Void in
                    // Hakkı yoksa abonelik ekranı açılır (soru gönderilmez).
                    if HostedAccount.shared.requiresSubscription {
                        HostedAccount.shared.requestSubscription()
                        return
                    }
                    cancelDictation()
                    onSubmit(AskSubmission(question: suggestion, meetingIDs: [], recipeTitle: nil))
                }
            }
            field
        }
        .animation(.smooth(duration: 0.2), value: isMentioning || isPickingRecipe)
        .animation(.smooth(duration: 0.2), value: askDictation.phase(owner: dictationOwner))
        // Sayfadan çıkınca ya da uygulama arkaya geçince dinleme bırakılır (mikrofon açık kalmaz). Yalnız arka plan:
        // izin penceresi, Denetim Merkezi ve bildirim perdesi sahneyi `.inactive` yapar, dinleme onlarda sürer.
        .onDisappear { cancelDictation() }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            if phase == .background {
                cancelDictation()
            }
        }
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
        // Üstte kapsam çipi ya da etiketler; altta sıradan bir yazı alanı gibi tek satır: toplantı ekle (@), soru ve
        // gönder/durdur. Yazı düğmelerle aynı satırda ortalanır; çok satırlı soru yukarı doğru büyür, düğmeler altta kalır.
        return VStack(alignment: .leading, spacing: 2) {
            if mentioned.isEmpty {
                AskScopeChip(menu: scopeMenu, isEnabled: !isAnswering, onSelect: onSelectScope)
                    .padding(.top, 4)
                    .padding(.leading, 6)
            } else {
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
                .padding(.horizontal, 6)
            }
            AskDictationStatus(dictation: askDictation, owner: dictationOwner)
            HStack(alignment: .bottom, spacing: 2) {
                // Toplantı ekle: alana "@" yazar, toplantı önerileri açılır (soru yalnız seçilen toplantılara gider).
                Button {
                    let needsSpace: Bool = !question.isEmpty && question.last?.isWhitespace == false
                    question += needsSpace ? " @" : "@"
                    cursor = question.utf16.count
                    isFocused = true
                } label: {
                    Image(systemName: "at")
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 34, height: 34)
                        .background(Theme.soft, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Toplantı ekle"))
                TextField(
                    mentioned.isEmpty ? placeholder : String(localized: "Etiketlenen toplantılara sor…"),
                    text: $question, selection: $selection, axis: .vertical
                )
                .appFont(size: 16, weight: .regular)
                // VoiceOver names the field once text replaces the placeholder.
                .accessibilityLabel(Text("Soru"))
                // Return yeni satır ekler (çok satırlı soru); gönderme sağdaki düğmeyle.
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 11)
                .frame(minHeight: 44, alignment: .center)
                // Sesle sor: söylenen soru alana gelir (gönderilmez); kayıt sürerken mikrofon toplantıdadır. Cihaz içi
                // dikte (`DictationTranscriber`) iOS 26 ister; daha eski sistemde düğme yok.
                if #available(iOS 26, *) {
                    AskMicButton(
                        dictation: askDictation, owner: dictationOwner, isMeetingActive: recorder.state.activeID != nil,
                        diameter: 34, minTapSize: 44, idleBackground: Theme.soft
                    ) { (text: String) -> Void in
                        question = askQuestionAppending(question: question, dictated: text)
                        cursor = question.utf16.count
                        selection = nil
                        isFocused = true
                    }
                }
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
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isEmpty && !isAnswering)
                .accessibilityLabel(isAnswering ? "Durdur" : "Sor")
            }
        }
        .padding(6)
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
    /// Süren sesle soru bırakılır (gönderilen soruya sonradan metin eklenmez).
    private func clearQuestion() {
        cancelDictation()
        question = ""
        selection = nil
        cursor = nil
    }

    /// Bu alanın sesle sorusu sürüyorsa ya da notu varsa bırakılır.
    private func cancelDictation() {
        if askDictation.owner == dictationOwner {
            askDictation.cancel()
        }
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

/// Sohbet geçmişi (alttan açılan sayfa; yarım ve tam boy): sol üstte kapat, sağ üstte süzgeç menüsü (seçili süzgeç
/// listenin başında çip olur), Bugün, Bu hafta, Bu ay ve Daha önce bölümlerinde yeniden eskiye sohbetler (kalın başlık,
/// son cevabın önizlemesi, göreli zaman) ve altta arama alanı (iOS 26+; iOS 18'de başlığın altında). Arama ve süzme
/// `filteredAskConversations`, bölümler `askHistorySections` ile. Dokununca sohbet açılır; sola kaydırınca ya da basılı
/// tutunca adı değiştirilir ya da silinir.
private struct AskHistorySheet: View {
    let ask: PhoneAsk
    let onOpen: @MainActor (UUID) -> Void
    @State private var query: String = ""
    @State private var filter: AskHistoryFilter = .all
    /// Adı değiştirilen sohbet (ad sayfası açık).
    @State private var renaming: AskConversation?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        let shown: [AskConversation] = filteredAskConversations(conversations: ask.conversations, query: query, filter: filter)
        let now: Date = Date()
        NavigationStack {
            List {
                if let error = ask.historyError {
                    PhoneErrorList(messages: [error])
                        .modifier(AskHistoryPlainRow())
                }
                if filter != .all {
                    AskHistoryFilterChip(filter: filter, size: 13) { filter = .all }
                        .modifier(AskHistoryPlainRow())
                }
                if shown.isEmpty, !ask.conversations.isEmpty {
                    AskHistoryNoMatches(size: 15)
                        .modifier(AskHistoryPlainRow())
                }
                ForEach(askHistorySections(conversations: shown, now: now, calendar: Calendar.current)) { (section: AskHistorySection) in
                    Section {
                        ForEach(section.conversations) { (conversation: AskConversation) in
                            row(conversation: conversation, now: now)
                        }
                    } header: {
                        AskHistorySectionHeader(period: section.period, size: 13)
                            .textCase(nil)
                            .padding(.top, 6)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .scrollDismissesKeyboard(.interactively)
            .overlay {
                if ask.conversations.isEmpty {
                    PhoneEmptyState(symbol: "bubble.left.and.text.bubble.right", title: "Saklanan sohbet yok", message: "Sorduğun sorular burada saklanır.") {
                        EmptyView()
                    }
                }
            }
            .navigationTitle("Sohbet geçmişi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CloseToolbarButton { dismiss() }
                }
                if !ask.conversations.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        filterMenu
                    }
                }
            }
            .searchable(text: $query, prompt: Text("Sohbetlerde ara"))
            .searchFieldInBottomBar()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .sheet(item: $renaming) { (conversation: AskConversation) in
            PhoneTextEntrySheet(
                title: "Sohbetin adı", placeholder: "Ad", actionTitle: "Kaydet", initialText: askConversationDisplayTitle(conversation: conversation)
            ) { (title: String) -> Void in
                ask.rename(conversationID: conversation.id, title: title)
            }
        }
    }

    private func row(conversation: AskConversation, now: Date) -> some View {
        Button {
            onOpen(conversation.id)
        } label: {
            AskHistoryPreviewRow(
                conversation: conversation, preview: askConversationPreview(conversation: conversation),
                time: askRecentChatTime(date: conversation.updatedAt, now: now),
                isSelected: ask.chats.conversationID(context: .allMeetings) == conversation.id
            )
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 9, leading: 20, bottom: 9, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Theme.background)
        .swipeActions {
            Button("Sil", role: .destructive) { ask.delete(conversationID: conversation.id) }
            Button("Adını değiştir") { renaming = conversation }
                .tint(appearance.accent.systemLabelFill)
        }
        .contextMenu {
            Button("Adını değiştir", systemImage: "pencil") { renaming = conversation }
            Button("Sohbeti sil", systemImage: "trash", role: .destructive) { ask.delete(conversationID: conversation.id) }
        }
    }

    /// Süzgeç menüsü: tüm sohbetler, toplantıya sorulanlar, web'den cevaplananlar; seçili süzgeçte simge dolu.
    private var filterMenu: some View {
        Menu {
            Picker(selection: $filter) {
                ForEach(AskHistoryFilter.allCases, id: \.self) { (option: AskHistoryFilter) in
                    Label(askHistoryFilterTitle(filter: option), systemImage: askHistoryFilterSymbol(filter: option)).tag(option)
                }
            } label: {
                Text("Sohbetleri süz")
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sohbetleri süz", systemImage: filter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityValue(Text(askHistoryFilterTitle(filter: filter)))
    }
}

/// Geçmiş sayfasında sohbet satırı olmayan öğe (hata, süzgeç çipi, eşleşme yok): çizgisiz, sayfanın zemininde.
private struct AskHistoryPlainRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Theme.background)
    }
}
