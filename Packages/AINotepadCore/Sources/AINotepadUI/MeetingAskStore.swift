import AINotepadCore
import Foundation
import Observation
import os

/// Toplantı sayfasındaki "Bir şey sor" çubuğunun sohbetleri (Mac ve iPhone): her toplantının kendi sohbeti, uygulama
/// açık kaldıkça sürer (sayfadan çıkıp dönünce yerinde). Cevabı platformun Sor hattı yazar (`MeetingAskAnswer`: hesap
/// ve abonelik denetimi, sağlayıcı, ekran görüntüsü planı orada); burada yalnız soruların durumu tutulur. Devam soruları
/// aynı toplantıdaki önceki cevapları bağlam alır.
@MainActor
@Observable
public final class MeetingAskStore {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MeetingAsk")

    /// Toplantı kimliği → sohbetin soruları (eskiden yeniye).
    public private(set) var chats: [String: [ArchiveExchange]] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    public init() {}

    /// Toplantının sohbeti.
    public func exchanges(meetingID: String) -> [ArchiveExchange] {
        chats[meetingID] ?? []
    }

    /// Toplantıda bir soru cevaplanıyor (yenisi sorulamaz, durdurulabilir).
    public func isAnswering(meetingID: String) -> Bool {
        exchanges(meetingID: meetingID).last.map { [.understanding, .searching, .writing].contains($0.phase) } ?? false
    }

    /// Sorulmadan başarısız olan soru (Sor kullanılamıyor): soru ve neden sohbette görünür.
    public func fail(record: MeetingRecord, question: String, recipeTitle: String?, reason: String) {
        chats[record.id] = exchanges(meetingID: record.id) + [
            failedExchange(id: UUID(), question: question, scopeMeetingIDs: [record.id], recipeTitle: recipeTitle, reason: reason, at: Date()),
        ]
    }

    /// Soruyu bu toplantıya sorar; ilerleyiş ve akan cevap sohbete yazılır. Boş soru ya da süren cevap varken yok sayılır.
    public func ask(record: MeetingRecord, question: String, recipeTitle: String?, answer: @escaping MeetingAskAnswer) {
        let trimmed: String = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingID: String = record.id
        guard !trimmed.isEmpty, !isAnswering(meetingID: meetingID) else {
            return
        }
        let history: [ArchiveTurn] = archiveHistory(exchanges: exchanges(meetingID: meetingID))
        let id: UUID = UUID()
        chats[meetingID] = exchanges(meetingID: meetingID) + [startedExchange(id: id, question: trimmed, scope: [record], recipeTitle: recipeTitle, startedAt: Date())]
        tasks[meetingID] = Task { [weak self] in
            let onProgress: ArchiveProgressHandler = { [weak self] (progress: ArchiveProgress) -> Void in
                await self?.update(meetingID: meetingID, id: id) { (exchange: inout ArchiveExchange) -> Void in
                    exchange = applying(progress: progress, to: exchange)
                }
            }
            do {
                try await answer(trimmed, history, onProgress)
                self?.finish(meetingID: meetingID, id: id, phase: .done)
            } catch is CancellationError {
                self?.finish(meetingID: meetingID, id: id, phase: .stopped)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(meetingID: meetingID, id: id, phase: .stopped)
            } catch {
                Self.logger.error("Toplantı sorusu cevaplanamadı, hata: \(String(describing: error), privacy: .private)")
                self?.finish(meetingID: meetingID, id: id, phase: .failed(userFacingMessage(error: error)))
            }
        }
    }

    /// Akan cevabı durdurur; o ana kadar yazılan kalır.
    public func stop(meetingID: String) {
        tasks[meetingID]?.cancel()
    }

    /// Toplantının sohbetini temizler (yeni konu: önceki cevaplar bağlam olmaz).
    public func clear(meetingID: String) {
        tasks[meetingID]?.cancel()
        tasks[meetingID] = nil
        chats[meetingID] = nil
    }

    /// Son soruyu (bitmiş, durdurulmuş ya da hatalı) yeniden sormak için: sohbetten çıkarıp döndürür; çalışan soru
    /// ya da boş sohbette nil. Yeniden sorulamazsa (abonelik teklifi açıldı) `restore` ile geri konur.
    public func takeLastForRegenerate(meetingID: String) -> ArchiveExchange? {
        guard let last = regeneratableExchange(exchanges: exchanges(meetingID: meetingID)) else {
            return nil
        }
        chats[meetingID] = Array(exchanges(meetingID: meetingID).dropLast())
        return last
    }

    /// `takeLastForRegenerate` ile çıkarılan soruyu yerine koyar.
    public func restore(exchange: ArchiveExchange, meetingID: String) {
        chats[meetingID] = exchanges(meetingID: meetingID) + [exchange]
    }

    private func finish(meetingID: String, id: UUID, phase: ArchiveExchange.Phase) {
        update(meetingID: meetingID, id: id) { (exchange: inout ArchiveExchange) -> Void in
            exchange.phase = phase
            exchange.finishedAt = Date()
        }
    }

    private func update(meetingID: String, id: UUID, change: (inout ArchiveExchange) -> Void) {
        // Sohbet bu arada temizlendiyse soru artık yok: dokunulmaz.
        guard var exchanges = chats[meetingID], let index = exchanges.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&exchanges[index])
        chats[meetingID] = exchanges
    }
}

/// Toplantı sorusunu cevaplayan platform hattı: soru, önceki turlar ve ilerleyiş bildirimi. Cevap bildirimlerle
/// sohbete yazılır; hata fırlatırsa soru hatalı biter.
public typealias MeetingAskAnswer = @MainActor (String, [ArchiveTurn], @escaping ArchiveProgressHandler) async throws -> Void
