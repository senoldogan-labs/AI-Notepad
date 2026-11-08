import AINotepadCore
import Foundation
import Observation
import os

/// Bir Sor alanının sohbeti: seçili kapsam (sonraki soru buna sorulur), sorular, geçmişteki kimliği (ilk cevap
/// saklanınca atanır; "Yeni sohbet"te nil) ve örnek toplantıya soru sorulup sorulmadığı (öyleyse sohbet hiç saklanmaz:
/// Sor geçmişi hesapla eşitlenir, örnek toplantı eşitlemeye girmez).
public struct AskChat: Equatable, Sendable {
    public var scope: AskScope
    public var exchanges: [ArchiveExchange]
    public var conversationID: UUID?
    public var askedSampleMeeting: Bool

    public init(scope: AskScope, exchanges: [ArchiveExchange], conversationID: UUID?, askedSampleMeeting: Bool) {
        self.scope = scope
        self.exchanges = exchanges
        self.conversationID = conversationID
        self.askedSampleMeeting = askedSampleMeeting
    }
}

/// Sor'un tek motoru (Mac ve iPhone; Sor sayfası, toplantı sayfasının çubuğu, ⌘J paneli, klasör ve kişi sayfalarından
/// açılan Sor): her Sor alanının (bağlamın) kendi sohbeti vardır. Bağlam alanın varsayılan kapsamıdır (Sor sayfası tüm
/// toplantılar, toplantı sayfası o toplantı, klasör ve kişi kendisi); sohbetin kapsamı çipten değiştirilebilir, her soru
/// o anki kapsamıyla saklanır. Her bitmiş (ya da yazılırken durdurulmuş) cevaptan sonra sohbet Sor geçmişine yazılır
/// (`AskSave`; platform saklar, hesapla eşitlenir); toplantı sayfası açılınca toplantının son sohbeti geri gelir
/// (`resume`). Cevabı platformun Sor hattı yazar (`AskAnswer`: sağlayıcı, ekran görüntüsü planı orada; abonelik ve hesap
/// denetimi soru gönderilmeden önce platformda); burada yalnız sohbetlerin durumu tutulur.
@MainActor
@Observable
public final class AskStore {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Ask")

    /// Bağlam → sohbet.
    public private(set) var chats: [AskScope: AskChat] = [:]
    @ObservationIgnored private var tasks: [AskScope: Task<Void, Never>] = [:]
    /// Bağlamda süren cevabın saklama hattı (`ask`'a verilen); cevap bitince ya da sohbetten ayrılınca kalkar.
    @ObservationIgnored private var saves: [AskScope: AskSave] = [:]
    /// Sohbetinden ayrılırken durdurulup saklanan sorular: görevlerinin geç gelen ilerlemesi ve sonucu (iptal) yok
    /// sayılır; tur, sohbet yeniden açılınca da durduğu gibi kalır ve ikinci kez saklanmaz.
    @ObservationIgnored private var retiredExchangeIDs: Set<UUID> = []

    public init() {}

    /// Bağlamın sohbeti; hiç açılmadıysa kapsamı bağlamın kendisi olan boş sohbet.
    public func chat(context: AskScope) -> AskChat {
        chats[context] ?? AskChat(scope: context, exchanges: [], conversationID: nil, askedSampleMeeting: false)
    }

    /// Bağlamın sohbetinin soruları (eskiden yeniye).
    public func exchanges(context: AskScope) -> [ArchiveExchange] {
        chat(context: context).exchanges
    }

    /// Bağlamın sohbetinde seçili kapsam (sonraki soru buna sorulur).
    public func scope(context: AskScope) -> AskScope {
        chat(context: context).scope
    }

    /// Kapsam çipinden seçilen kapsam: sohbet sürer (önceki cevaplar bağlam kalır), sonraki soru yeni kapsama sorulur.
    public func select(scope: AskScope, context: AskScope) {
        var updated: AskChat = chat(context: context)
        updated.scope = scope
        chats[context] = updated
    }

    /// Bağlamın sohbetinin geçmişteki kimliği (henüz saklanmadıysa nil).
    public func conversationID(context: AskScope) -> UUID? {
        chat(context: context).conversationID
    }

    /// Bağlamda bir soru cevaplanıyor (yenisi sorulamaz, durdurulabilir).
    public func isAnswering(context: AskScope) -> Bool {
        exchanges(context: context).last.map { [.understanding, .searching, .writing].contains($0.phase) } ?? false
    }

    /// Geçmişteki sohbet şu an bir bağlamda cevaplanıyor (geçmiş listesinde "Cevaplanıyor…").
    public func isAnswering(conversationID: UUID) -> Bool {
        chats.contains { $0.value.conversationID == conversationID && isAnswering(context: $0.key) }
    }

    /// Son cevabın altındaki devam soruları (bkz. `meetingFollowUpSuggestions`): kapsam bir toplantıysa ve son soru
    /// bitmişse o toplantının notundan; diğer kapsamlarda yok.
    public func followUps(context: AskScope, note: MeetingNote?) -> [String] {
        let current: AskChat = chat(context: context)
        guard askScopeMeetingID(scope: current.scope) != nil else {
            return []
        }
        return meetingFollowUpSuggestions(note: note, askedQuestions: current.exchanges.map(\.question), lastAnswerFinished: current.exchanges.last?.phase == .done)
    }

    /// Toplantı sayfası açılınca toplantının saklı son sohbetini (`latestMeetingConversation`) geri getirir. Bu oturumda
    /// sohbet zaten açıldıysa (soru soruldu, "Yeni sohbet" denildi, kapsam değişti) ya da o sohbet başka bir alanda
    /// açıksa dokunulmaz. Toplantı dışı bağlamlarda bir şey yapmaz.
    public func resume(context: AskScope, conversations: [AskConversation]) {
        guard chats[context] == nil, let meetingID = askScopeMeetingID(scope: context),
              let saved = latestMeetingConversation(conversations: conversations, meetingID: meetingID),
              !chats.values.contains(where: { $0.conversationID == saved.id }) else {
            return
        }
        chats[context] = AskChat(scope: context, exchanges: saved.turns.map { archiveExchange(turn: $0) }, conversationID: saved.id, askedSampleMeeting: false)
    }

    /// Saklanan sohbeti bağlamda açar, kendi kapsamıyla (`askConversationScope`); devam soruları onun cevaplarını bağlam
    /// alır. Bağlamda süren cevap durur. Aynı sohbet başka bir bağlamda açıksa oradan kalkar: iki alan aynı sohbeti
    /// birbirinin üstüne yazmasın.
    public func open(conversation: AskConversation, context: AskScope) {
        // Sohbet geçmişteki kopyasından kurulur (başka cihazdan eşitlenen turlar da onda). Sohbet bir alanda açık ve cevabı
        // akıyorsa `leave` cevabı durdurup saklar; çağıranın kopyası ondan eskidir, durdurulan tur eklenir (yoksa sonraki
        // soru sohbeti o tur olmadan yeniden yazardı). Örnek toplantıya soru sorulmuş sohbette tur saklanmadığından eklenmez.
        var stopped: [ArchiveExchange] = []
        for other in chats.filter({ $0.value.conversationID == conversation.id }).map(\.key) {
            let wasAnswering: Bool = isAnswering(context: other)
            leave(context: other)
            if wasAnswering, let open = chats[other], !open.askedSampleMeeting, let last = open.exchanges.last {
                stopped.append(last)
            }
            if other != context {
                chats[other] = nil
            }
        }
        leave(context: context)
        let saved: [ArchiveExchange] = conversation.turns.map { archiveExchange(turn: $0) }
        let missing: [ArchiveExchange] = stopped.filter { (exchange: ArchiveExchange) -> Bool in !saved.contains { $0.id == exchange.id } }
        chats[context] = AskChat(
            scope: askConversationScope(conversation: conversation), exchanges: saved + missing, conversationID: conversation.id, askedSampleMeeting: false
        )
    }

    /// Bağlamın sohbetini temizler (yeni konu: önceki cevaplar bağlam olmaz; kapsam bağlamınkine döner); eski sohbet
    /// geçmişte kalır. Cevap sürüyorsa durur ve o ana kadar yazılanla saklanır (ör. toplantı sayfasından tarif
    /// çalıştırılınca Sor sayfasında akan cevap kaybolmaz).
    public func clear(context: AskScope) {
        leave(context: context)
        chats[context] = AskChat(scope: context, exchanges: [], conversationID: nil, askedSampleMeeting: false)
    }

    /// Silinen sohbet açık olduğu alanlardan kalkar; süren cevabı saklanmaz (sohbet silindi).
    public func forget(conversationID: UUID) {
        for (context, chat) in chats where chat.conversationID == conversationID {
            tasks[context]?.cancel()
            tasks[context] = nil
            saves[context] = nil
            chats[context] = AskChat(scope: context, exchanges: [], conversationID: nil, askedSampleMeeting: false)
        }
    }

    /// Bağlamın sohbetinden ayrılırken (temizleme, başka sohbet açma) süren cevabı durdurur; o ana kadar yazılan cevap
    /// "durduruldu" olarak sohbete işlenir ve sohbet saklanır (`stop` ile aynı sonuç). Görevin geç gelen ilerlemesi ve
    /// sonucu yok sayılır (`retiredExchangeIDs`): sohbet aynı alanda yeniden açılsa da tur durduğu gibi kalır.
    private func leave(context: AskScope) {
        let task: Task<Void, Never>? = tasks[context]
        let save: AskSave? = saves[context]
        tasks[context] = nil
        saves[context] = nil
        task?.cancel()
        guard isAnswering(context: context), let save, let running = exchanges(context: context).last else {
            return
        }
        finish(context: context, id: running.id, phase: .stopped)
        persist(context: context, exchangeID: running.id, save: save)
        retiredExchangeIDs.insert(running.id)
    }

    /// Sorulmadan başarısız olan soru (Sor kullanılamıyor): soru ve neden sohbette görünür.
    public func fail(context: AskScope, question: String, scope: AskScope, mentionIDs: [String], recipeTitle: String?, reason: String) {
        let exchange: ArchiveExchange = failedExchange(
            id: UUID(), question: question.trimmingCharacters(in: .whitespacesAndNewlines), scope: mentionIDs.isEmpty ? scope : .allMeetings,
            scopeMeetingIDs: mentionIDs.isEmpty ? askScopeMeetingID(scope: scope).map { [$0] } ?? [] : mentionIDs, recipeTitle: recipeTitle, reason: reason, at: Date()
        )
        append(exchange: exchange, context: context)
    }

    /// Soruyu `scope` kapsamına (`mentionIDs` doluysa yalnız o toplantılara) sorar; ilerleyiş ve akan cevap sohbete
    /// yazılır, cevap bitince (ya da yazılırken durdurulunca) sohbet `save` ile saklanır (yalnız örnek toplantıya
    /// sorulan saklanmaz: Sor geçmişi hesapla eşitlenir). Kapsamda toplantı yoksa ya da etiketli toplantı silindiyse soru
    /// sorulmaz, nedeni sohbette görünür. Boş soru ya da bağlamda süren cevap varken yok sayılır.
    public func ask(
        context: AskScope, question: String, scope: AskScope, mentionIDs: [String], recipeTitle: String?, records: [MeetingRecord], answer: @escaping AskAnswer,
        save: @escaping AskSave
    ) {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering(context: context) else {
            return
        }
        let target: [MeetingRecord]?
        do {
            target = try askTargetMeetings(scope: scope, mentionIDs: mentionIDs, records: records, now: Date(), calendar: Calendar.current)
        } catch {
            // Kapsam sessizce tüm arşive genişlemez: soru ve neden sohbette görünür.
            Self.logger.error("Sorunun kapsamı kurulamadı, hata: \(String(describing: error), privacy: .private)")
            fail(context: context, question: trimmed, scope: scope, mentionIDs: mentionIDs, recipeTitle: recipeTitle, reason: userFacingMessage(error: error))
            return
        }
        let asked: AskScope = mentionIDs.isEmpty ? scope : .allMeetings
        // Etiket: `@` ile seçilenler; kapsam tek toplantıysa o toplantı (eski sürümler toplantı sohbetini böyle tanır).
        let tagged: [MeetingRecord] = !mentionIDs.isEmpty || askScopeMeetingID(scope: scope) != nil ? target ?? [] : []
        // Örnek toplantı (karşılamadaki deneme) yalnız kendisi seçilince okunur (`askScopeMeetings`); okunacaksa sohbet
        // bundan sonra saklanmaz (önceki ve sonraki turlarıyla).
        let readsSample: Bool = (target ?? []).contains(where: \.isSampleMeeting)
        let history: [ArchiveTurn] = archiveHistory(exchanges: exchanges(context: context))
        let id: UUID = UUID()
        append(exchange: startedExchange(id: id, question: trimmed, scope: asked, tagged: tagged, recipeTitle: recipeTitle, startedAt: Date()), context: context)
        if readsSample {
            var marked: AskChat = chat(context: context)
            marked.askedSampleMeeting = true
            chats[context] = marked
        }
        let request: AskTarget = AskTarget(question: trimmed, history: history, meetings: target)
        saves[context] = save
        tasks[context] = Task { [weak self] in
            let onProgress: ArchiveProgressHandler = { [weak self] (progress: ArchiveProgress) -> Void in
                await self?.update(context: context, id: id) { (exchange: inout ArchiveExchange) -> Void in
                    exchange = applying(progress: progress, to: exchange)
                }
            }
            do {
                try await answer(request, onProgress)
                self?.finish(context: context, id: id, phase: .done)
            } catch is CancellationError {
                self?.finish(context: context, id: id, phase: .stopped)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(context: context, id: id, phase: .stopped)
            } catch {
                Self.logger.error("Soru cevaplanamadı, hata: \(String(describing: error), privacy: .private)")
                self?.finish(context: context, id: id, phase: .failed(userFacingMessage(error: error)))
            }
            self?.persist(context: context, exchangeID: id, save: save)
            self?.answerEnded(context: context, exchangeID: id)
        }
    }

    /// Cevap bitti: bağlamda hâlâ bu soru sürüyorsa görevi ve saklama hattını bırakır.
    private func answerEnded(context: AskScope, exchangeID: UUID) {
        guard chat(context: context).exchanges.last?.id == exchangeID else {
            return
        }
        tasks[context] = nil
        saves[context] = nil
    }

    /// Bağlamdaki sorunun cevabını bekler (Kısayollar ve Siri).
    public func waitForAnswer(context: AskScope) async {
        await tasks[context]?.value
    }

    /// Akan cevabı durdurur; o ana kadar yazılan kalır.
    public func stop(context: AskScope) {
        tasks[context]?.cancel()
    }

    /// Son soruyu (bitmiş, durdurulmuş ya da hatalı) yeniden sormak için: sohbetten çıkarıp döndürür; çalışan soru
    /// ya da boş sohbette nil. Yeniden sorulamazsa (abonelik teklifi açıldı) `restore` ile geri konur.
    public func takeLastForRegenerate(context: AskScope) -> ArchiveExchange? {
        guard let last = regeneratableExchange(exchanges: exchanges(context: context)) else {
            return nil
        }
        var updated: AskChat = chat(context: context)
        updated.exchanges = Array(updated.exchanges.dropLast())
        chats[context] = updated
        return last
    }

    /// `takeLastForRegenerate` ile çıkarılan (ya da tanıtım için hazır) soruyu sohbetin sonuna koyar.
    public func restore(exchange: ArchiveExchange, context: AskScope) {
        append(exchange: exchange, context: context)
    }

    private func append(exchange: ArchiveExchange, context: AskScope) {
        var updated: AskChat = chat(context: context)
        updated.exchanges += [exchange]
        chats[context] = updated
    }

    /// Sohbetin saklanabilir sorularını saklatır (sohbet kimliği ilk saklanışta atanır). Sohbet bu arada temizlendiyse
    /// ya da başka sohbet açıldıysa cevap bu sohbete ait değildir; saklanacak tur yoksa (cevap gelmeden durduruldu,
    /// hata) yazılmaz. Sohbette örnek toplantıya soru sorulduysa hiç yazılmaz: Sor geçmişi hesapla eşitlenir.
    private func persist(context: AskScope, exchangeID: UUID, save: AskSave) {
        var current: AskChat = chat(context: context)
        guard !retiredExchangeIDs.contains(exchangeID), !current.askedSampleMeeting, current.exchanges.contains(where: { $0.id == exchangeID && askTurn(exchange: $0) != nil }) else {
            return
        }
        let id: UUID = current.conversationID ?? UUID()
        current.conversationID = id
        chats[context] = current
        save(id, current.exchanges)
    }

    private func finish(context: AskScope, id: UUID, phase: ArchiveExchange.Phase) {
        update(context: context, id: id) { (exchange: inout ArchiveExchange) -> Void in
            exchange.phase = phase
            exchange.finishedAt = Date()
        }
    }

    private func update(context: AskScope, id: UUID, change: (inout ArchiveExchange) -> Void) {
        // Sohbet bu arada temizlendiyse soru artık yok, sohbetinden ayrılırken durdurulduysa tamam: dokunulmaz.
        guard !retiredExchangeIDs.contains(id), var current = chats[context], let index = current.exchanges.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&current.exchanges[index])
        chats[context] = current
    }
}

/// Soruyu cevaplayan platform hattı: okunacak toplantılar ve bağlam, ilerleyiş bildirimi. Cevap bildirimlerle sohbete
/// yazılır; hata fırlatırsa soru hatalı biter.
public typealias AskAnswer = @MainActor (AskTarget, @escaping ArchiveProgressHandler) async throws -> Void

/// Sohbeti Sor geçmişine yazan platform hattı: sohbetin kimliği ve soruları (bitmemişler `askTurn` ile atlanır).
public typealias AskSave = @MainActor (UUID, [ArchiveExchange]) -> Void
