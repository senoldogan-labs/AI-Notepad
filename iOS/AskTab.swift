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
            exchanges.append(ArchiveExchange(
                id: UUID(), question: trimmed, scopeMeetingIDs: meetingIDs, scopeTitles: [], recipeTitle: recipeTitle, startedAt: Date(),
                phase: .failed(reason), terms: [], passages: [], screens: 0, answer: ArchiveAnswer(text: "", sources: []), finishedAt: Date()
            ))
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
            exchanges.append(ArchiveExchange(
                id: id, question: trimmed, scopeMeetingIDs: meetingIDs, scopeTitles: [], recipeTitle: recipeTitle, startedAt: Date(),
                phase: .failed(userFacingMessage(error: error)), terms: [], passages: [], screens: 0, answer: ArchiveAnswer(text: "", sources: []), finishedAt: Date()
            ))
            return
        }
        exchanges.append(ArchiveExchange(
            id: id, question: trimmed, scopeMeetingIDs: scoped.map(\.id), scopeTitles: scoped.map { $0.note?.title ?? $0.title }, recipeTitle: recipeTitle, startedAt: Date(), phase: .understanding,
            terms: [], passages: [], screens: 0, answer: ArchiveAnswer(text: "", sources: []), finishedAt: nil
        ))
        isAnswering = true
        let records: [MeetingRecord] = store.meetings
        task = Task { [weak self] in
            do {
                let provider: LLMProvider = try phoneAccountLLMProvider()
                let onProgress: ArchiveProgressHandler = { [weak self] (progress: ArchiveProgress) -> Void in
                    await self?.apply(progress: progress, id: id)
                }
                // iPhone'da ekran görüntüsü alınmaz (başka uygulamaların ekranı yakalanamaz): Sor yalnız metni okur.
                if scoped.isEmpty {
                    _ = try await askArchive(
                        question: trimmed, history: history, records: records, userName: phoneUserName(), language: phoneNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars, screens: .off, now: Date(), onProgress: onProgress
                    )
                } else {
                    _ = try await askAboutMeetings(
                        question: trimmed, history: history, records: scoped, userName: phoneUserName(), language: phoneNoteLanguage(), llm: provider,
                        maxChars: noteLimits(provider: provider).archiveChars,
                        screens: .off, now: Date(), onProgress: onProgress
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
            switch progress {
            case .searchTerms(let terms):
                exchange.terms = terms
                exchange.phase = .searching
            case .passages(let passages):
                exchange.passages = passages
            case .screens(let count):
                exchange.screens = count
                exchange.phase = .writing
            case .answer(let answer):
                exchange.answer = answer
            }
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

/// Sor sekmesinin kökü: başlangıç durumu (tanıtım kartı, son sohbetler, örnek sorular) ve altta soru alanı. Sor baştan
/// sona tam ekrandır: sekme çubuğu gizli, sol üstteki geri Sor'a gelinen sekmeye döner. Soru gönderilince ya da bir
/// sohbet açılınca sohbet üstüne açılır; onun geri oku kökü getirir.
struct AskTab: View {
    let ask: PhoneAsk
    let store: PhoneStore
    @Bindable var router: PhoneRouter
    /// Not ve çeviri dili (Ayarlar): cevapların dili metinde adıyla geçer.
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    private let examples: [(symbol: String, text: String)] = [
        ("checklist", "Bana hangi görevler verildi?"),
        ("checkmark.seal", "Son toplantılarda alınan kararlar neler?"),
        ("eurosign.circle", "Bütçe hakkında neler konuşuldu?"),
        ("person.2", "Bu hafta kimlerle neler konuştum?"),
    ]

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
                        VStack(alignment: .leading, spacing: 28) {
                            PhoneErrorList(messages: [ask.historyError, ask.recipeError].compactMap { $0 })
                            intro
                            if hasRecent {
                                recent
                            }
                            examplesSection
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .safeAreaInset(edge: .bottom) {
                        AskComposer(
                            ask: ask, store: store, placeholder: "Sor… (@ toplantı, / tarif)", isAnswering: false,
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

    private var intro: some View {
        let minutes: Int = store.meetings.compactMap { meetingDurationMinutes(record: $0) }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .appFont(size: 20, weight: .medium)
                .foregroundStyle(Color.black.opacity(0.7))
            // Açık pastel gradyan: yazılar koyu mürekkep (Mac'teki Sor sayfası gibi).
            Text("Toplantılarına sor")
                .appFont(size: 28, weight: .regular)
                .tracking(-0.5)
                .foregroundStyle(Color.black.opacity(0.8))
            Text("Notların ve transkriptlerin (hangi dilde konuşulduysa) arasında arar, \(phoneStoredNoteLanguage(value: noteLanguage).interfaceName) cevaplar; her bilginin hangi toplantıdan geldiğini gösterir.")
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Color.black.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                PastelChip(text: String(localized: "\(store.meetings.count) toplantı"), systemImage: nil)
                PastelChip(text: String(localized: "\(max(0, minutes / 60)) sa \(minutes % 60) dk konuşma"), systemImage: nil)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { FilmGradient(seed: "ask", palette: .violet) }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .light)
    }

    /// Son sohbetler: varsa süren (kaydedilmemiş) sohbet, sonra en yeni saklanan sohbetler; "Tümünü gör" geçmişi açar.
    private var recent: some View {
        let conversations: [AskConversation] = Array(ask.conversations.prefix(recentLimit))
        return VStack(alignment: .leading, spacing: 12) {
            PhoneSectionHeader(title: "Son sohbetler", actionTitle: ask.conversations.isEmpty ? nil : "Tümünü gör") {
                router.askPath = [.history]
            }
            VStack(spacing: 0) {
                if let unsavedQuestion {
                    AskConversationRow(
                        title: unsavedQuestion,
                        subtitle: ask.isAnswering ? String(localized: "Cevaplanıyor…") : String(localized: "Şimdi"),
                        isAnswering: ask.isAnswering
                    ) {
                        router.askPath = [.conversation]
                    }
                    if !conversations.isEmpty {
                        Divider().padding(.leading, 62)
                    }
                }
                ForEach(Array(conversations.enumerated()), id: \.element.id) { (item: (offset: Int, element: AskConversation)) in
                    let conversation: AskConversation = item.element
                    AskConversationRow(
                        title: conversation.title,
                        subtitle: conversation.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())),
                        isAnswering: ask.isAnswering && ask.currentConversationID == conversation.id
                    ) {
                        openConversation(id: conversation.id)
                    }
                    if item.offset < conversations.count - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        }
    }

    private var examplesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            PhoneSectionHeader(title: "Örnek sorular", actionTitle: nil, action: nil)
            ForEach(Array(examples.enumerated()), id: \.element.text) { (item: (offset: Int, element: (symbol: String, text: String))) in
                ExampleQuestionCard(
                    symbol: item.element.symbol, question: LocalizedStringKey(item.element.text), hint: "Tüm toplantılarında arar",
                    palette: [FilmPalette.sunset, .rose, .sunset, .rose][item.offset % 4]
                ) {
                    startConversation(submission: AskSubmission(
                        question: String(localized: String.LocalizationValue(item.element.text)), meetingIDs: [], recipeTitle: nil
                    ))
                }
                .disabled(store.meetings.isEmpty)
            }
        }
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

/// Son sohbetler satırı: vurgu renginde sohbet simgesi (cevap sürerken bekleme göstergesi), başlık, tarih ve ok.
private struct AskConversationRow: View {
    let title: String
    let subtitle: String
    let isAnswering: Bool
    let onOpen: @MainActor () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: 12) {
                Group {
                    if isAnswering {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                            .appFont(size: 15, weight: .medium)
                            .foregroundStyle(.tint)
                    }
                }
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: title)
                        .appFont(size: 15, weight: .medium)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(verbatim: subtitle)
                        .appFont(size: 12, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Sohbet (tam ekran): soru-cevaplar (Mac'teki ile aynı görünüm) ve altta yalnızca devam sorusu alanı. Sekme çubuğu
/// gizlidir; sol üstteki geri kökü getirir (süren cevap durmaz), sağ üstteki "Yeni sohbet" sohbeti kapatıp köke döner.
private struct AskConversationView: View {
    let ask: PhoneAsk
    let store: PhoneStore
    let router: PhoneRouter

    private let bottomID: String = "ask-bottom"

    var body: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    PhoneErrorList(messages: [ask.historyError, ask.recipeError].compactMap { $0 })
                    ForEach(ask.exchanges) { (exchange: ArchiveExchange) in
                        ExchangeView(exchange: exchange) { (passage: ArchivePassage) -> Void in
                            router.open(meetingID: passage.meetingID)
                        } onSaveRecipe: { (question: String) -> Void in
                            ask.saveRecipe(question: question)
                        }
                        .id(exchange.id)
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: ask.exchanges.last?.id) { (_: UUID?, id: UUID?) in
                // Yeni devam sorusu: sorusu ekranın üstüne gelir, cevap altına akar.
                if ask.isAnswering, let id {
                    withAnimation(.smooth(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .onChange(of: ask.exchanges.last?.answer.text) { (_: String?, _: String?) in
                if ask.isAnswering {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            AskComposer(
                ask: ask, store: store, placeholder: "Devam sorusu sor…", isAnswering: ask.isAnswering,
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
        ask.conversations.first { $0.id == ask.currentConversationID }?.title ?? ask.exchanges.first?.question ?? ""
    }
}

/// Soru alanı ve üstünde `@` toplantı ya da "/" tarif önerileri: kökte yeni sohbet, sohbette devam sorusu gönderir.
private struct AskComposer: View {
    let ask: PhoneAsk
    let store: PhoneStore
    /// Etiketlenen toplantı yokken alanın ipucu.
    let placeholder: LocalizedStringKey
    /// Bu alanın sohbetinde cevap sürüyor: düğme durdurur.
    let isAnswering: Bool
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
                    withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
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
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background {
            // Kayan içerik alanın arkasında zemine doğru solar (alanın altı ve çevresi sakin kalır).
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                .padding(.top, -20)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
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
        // Etiket bu soruya aitti: sohbette sorunun üstünde kalır, soru alanından kalkar.
        withAnimation(.smooth(duration: 0.2)) { mentioned = [] }
        isFocused = false
    }
}

/// Sohbet geçmişi: yeniden eskiye sohbetler (başlık ve tarih); dokununca açılır, sola kaydırınca silinir.
private struct AskHistoryList: View {
    let ask: PhoneAsk
    let onOpen: @MainActor (UUID) -> Void

    var body: some View {
        List {
            ForEach(ask.conversations) { (conversation: AskConversation) in
                Button {
                    onOpen(conversation.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversation.title)
                            .appFont(size: 15, weight: ask.currentConversationID == conversation.id ? .semibold : .regular)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        Text(conversation.updatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))
                            .appFont(size: 12, weight: .regular)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions {
                    Button("Sil", role: .destructive) { ask.delete(conversationID: conversation.id) }
                }
            }
        }
        .overlay {
            if ask.conversations.isEmpty {
                PhoneEmptyState(symbol: "bubble.left.and.text.bubble.right", title: "Saklanan sohbet yok", message: "Sorduğun sorular burada saklanır.") {
                    EmptyView()
                }
            }
        }
        .navigationTitle("Geçmiş")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}
