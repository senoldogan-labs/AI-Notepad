import Foundation
import os

private let transcriptTranslationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "TranscriptTranslation")

// Toplantı sonu çevirisi: son geçiş transkripti, okuma parçaları (`readingPieces`) tek tek not diline çevrilir.
//
// Neden: canlı çeviri kaba canlı metinden yapılır (duyma hataları: "autopen" → "euro pen", "CENTCOM" → "sitcom") ve
// birimleri son geçiş bölümleriyle örtüşmez. Önceden canlı çeviriler en çok örtüştükleri son geçiş bölümüne taşınıyordu;
// tek kişinin iki dakikalık konuşması tek son geçiş bölümü olduğundan bütün çeviriler bölümün ilk okuma parçasına
// yığılıyor, sonraki parçalar çevirisiz kalıyordu. Şimdi her okuma parçası, son geçişin düzgün metninden, çevresiyle
// birlikte (önceki/sonraki parçalar, konuşmacılar, adlar) çevrilir ve çevirisi kendi anahtarına yazılır.

/// Toplantı sonu çevirisinin bir isteği: art arda çevrilecek parçalar ve yalnızca bağlam için çevresi.
public struct TranscriptTranslationBatch: Sendable, Equatable {
    /// Çevrilecek okuma parçaları (sırayla).
    public let pieces: [StoredSegment]
    /// İlk parçadan hemen önceki parçalar (bağlam; çevrilmez).
    public let before: [StoredSegment]
    /// Son parçadan hemen sonraki parçalar (bağlam; çevrilmez).
    public let after: [StoredSegment]

    public init(pieces: [StoredSegment], before: [StoredSegment], after: [StoredSegment]) {
        self.pieces = pieces
        self.before = before
        self.after = after
    }
}

/// Bir istekte çevrilen en çok kaynak metin (karakter): ~600 token kaynak, ~1,2 K token Türkçe çıktı. Daha büyük
/// istek çıktı sınırına ve tek hatada daha çok parçanın yeniden çevrilmesine yol açar; daha küçüğü sistem istemini
/// (~700 token) daha çok tekrarlar.
public let transcriptTranslationBatchCharacters: Int = 2_400
/// Bağlam olarak verilen önceki parça sayısı (zamirler, kim kime ne diyor).
public let transcriptTranslationContextBefore: Int = 3
/// Bağlam olarak verilen sonraki parça sayısı (yarım kalan cümlenin devamı).
public let transcriptTranslationContextAfter: Int = 1
/// Aynı anda gönderilen istek sayısı: 4 saatlik toplantı (~90 istek) birkaç dakikada biter, sağlayıcı hız sınırına
/// takılmaz.
let transcriptTranslationParallelRequests: Int = 4

/// Toplantının okuma parçaları (sayfadaki paragrafları kuranlar, zamana göre sıralı). Saf fonksiyondur.
public func transcriptReadingPieces(record: MeetingRecord) -> [StoredSegment] {
    meetingSegments(record: record).flatMap { (segment: StoredSegment) -> [StoredSegment] in readingPieces(segment: segment) }
}

/// Son geçiş bölümünün anahtarı mı ("Diğerleri" `final-N`, "Sen" `me-final-N`; okuma parçasında `….k`). Canlı
/// bölümlerin (`others-N`, `me-N`) canlı çevirisi kalır: onlar canlı çeviri birimleriyle aynı bölümlerdir.
public func isFinalPassKey(key: String) -> Bool {
    key.hasPrefix("final-") || key.hasPrefix("me-final-")
}

/// Toplantı sonunda çevrilecek parçalar: son geçiş okuma parçalarından harf içerenler; dili (parçanın algılanan dili,
/// yoksa toplantının dili) not diliyle aynı olanlar (zaten okunacak dildeki sözler) atlanır. Karışık dilli toplantıda
/// (Türkçe toplantıda İngilizce konuşan konuk) yalnızca başka dildeki parçalar çevrilir. Saf fonksiyondur.
public func transcriptTranslationPieces(record: MeetingRecord, language: ShareLanguage) -> [StoredSegment] {
    let target: String? = language.meetingLanguage?.rawValue
    return transcriptReadingPieces(record: record).filter { (piece: StoredSegment) -> Bool in
        isFinalPassKey(key: piece.key)
            && piece.text.contains { $0.isLetter }
            && (target == nil || (piece.spokenLanguage ?? record.language?.rawValue) != target)
    }
}

/// Toplantı sonu çevirisi gerekiyor mu: kullanıcı toplantıyı çevirili izledi (canlı çeviri ya da önceki toplantı sonu
/// çevirisi var, ya da çevrilemeyen parça kaldı). Canlı çeviriyi kapatan kullanıcının toplantısı çevrilmez (istemediği
/// maliyet). Toplantının ana dili not diliyle aynı olsa da çevrilir: hangi parçaların başka dilde olduğuna
/// `transcriptTranslationPieces` parça parça bakar (karışık dilli toplantıdaki konuk). Saf fonksiyondur.
public func wantsTranscriptTranslation(record: MeetingRecord) -> Bool {
    record.translations.values.contains { !$0.isEmpty } || !(record.failedTranslationKeys ?? []).isEmpty
}

/// Parçaları isteklere böler: `all` içinde (toplantının bütün okuma parçaları, "Sen" dahil) art arda gelen parçalar,
/// istek başına en çok `maxCharacters` kaynak metin (tek parça bundan uzunsa tek başına bir istek). Arada çevrilmeyen
/// bir parça (ör. "Sen"in sözü ya da not dilindeki söz) varsa yeni istek başlar: istekteki parçalar kesintisiz konuşma
/// olsun, aradaki söz bağlamda görünsün. Her isteğin bağlamı `all` içindeki komşularıdır. Saf fonksiyondur.
public func transcriptTranslationBatches(
    pieces: [StoredSegment], all: [StoredSegment], maxCharacters: Int, contextBefore: Int, contextAfter: Int
) -> [TranscriptTranslationBatch] {
    let positions: [String: Int] = Dictionary(all.enumerated().map { ($0.element.key, $0.offset) }) { (first: Int, _: Int) -> Int in first }
    let groups: [[StoredSegment]] = pieces.reduce(into: [[StoredSegment]]()) { (groups: inout [[StoredSegment]], piece: StoredSegment) -> Void in
        let adjacent: Bool = groups.last?.last.flatMap { positions[$0.key] }.map { $0 + 1 == positions[piece.key] } ?? false
        if adjacent, let current = groups.last, current.reduce(0, { $0 + $1.text.count }) + piece.text.count <= maxCharacters {
            groups[groups.count - 1].append(piece)
        } else {
            groups.append([piece])
        }
    }
    return groups.compactMap { (group: [StoredSegment]) -> TranscriptTranslationBatch? in
        guard let first = group.first, let last = group.last else {
            return nil
        }
        let start: Int = positions[first.key] ?? 0
        let end: Int = positions[last.key] ?? (all.count - 1)
        return TranscriptTranslationBatch(
            pieces: group,
            before: Array(all[max(0, start - contextBefore)..<min(start, all.count)]),
            after: Array(all[min(end + 1, all.count)..<min(end + 1 + contextAfter, all.count)])
        )
    }
}

/// Toplantı sonu çevirisinin JSON şeması: her parça için kimlik ve çeviri.
let transcriptTranslationSchema: String = """
{"type":"object","properties":{"ceviriler":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"ceviri":{"type":"string"}},"required":["id","ceviri"],"additionalProperties":false}}},"required":["ceviriler"],"additionalProperties":false}
"""

/// Parçanın istemdeki konuşmacısı: verilen ad, yoksa etiket. Saf fonksiyondur.
private func translationSpeaker(segment: StoredSegment, speakerNames: [Int: String]) -> String {
    if let person = segment.person, let name = speakerNames[person], !name.isEmpty {
        return name
    }
    return promptSpeakerLabel(speaker: segment.speaker, person: segment.person)
}

/// Bağlam satırları: `[mm:ss] Konuşmacı: metin`. Saf fonksiyondur.
private func translationContextLines(segments: [StoredSegment], speakerNames: [Int: String]) -> String {
    segments.isEmpty
        ? "(yok)"
        : segments.map { "[\(timestamp(seconds: $0.startSec))] \(translationSpeaker(segment: $0, speakerNames: speakerNames)): \($0.text)" }.joined(separator: "\n")
}

/// Toplantı sonu çevirisi isteği (not diline): parçalar 1'den numaralanır, yanıt `transcriptTranslationSchema`
/// biçimindedir (bkz. `parseTranscriptTranslations`). `terms` toplantıda geçen adlar ve terimlerdir (yazımları korunur).
/// Üslup canlı çeviriyle aynıdır (`translationRequest`): kelimesi kelimesine değil, anlam ve niyet. Saf fonksiyondur.
public func transcriptTranslationRequest(
    batch: TranscriptTranslationBatch, speakerNames: [Int: String], terms: [String], language: ShareLanguage
) -> LLMRequest {
    let pieces: String = batch.pieces.enumerated().map { (item: (offset: Int, element: StoredSegment)) -> String in
        let speaker: String = translationSpeaker(segment: item.element, speakerNames: speakerNames)
            .replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")
        return "<parca id=\"\(item.offset + 1)\" konusmaci=\"\(speaker)\" zaman=\"\(timestamp(seconds: item.element.startSec))\">\n\(item.element.text)\n</parca>"
    }
    .joined(separator: "\n")
    let termList: String = terms.isEmpty ? "(yok)" : terms.joined(separator: ", ")
    let sourceCharacters: Int = batch.pieces.reduce(0) { $0 + $1.text.count }
    return LLMRequest(
        purpose: .transcriptTranslation,
        tier: .fast,
        system: """
        Bir toplantının transkriptini çeviriyorsun (hedef dil: \(language.promptName)). Her <parca> içinde konuşanın
        söylemek istediğini, \(language.promptName) konuşan biri toplantıda nasıl söylerse öyle aktar: kelimesi kelimesine
        değil, anlam ve niyet olarak. Parçanın tamamı zaten bu dildeyse olduğu gibi yaz; değilse hiçbir kısmını kaynak
        dilde bırakma (özel adlar ve kısaltmalar hariç).
        Kurallar:
        - Niyeti koru: soru soru, rica rica, öneri öneri kalsın; verilen söz ya da görevde kim, ne, ne zaman eksiksiz olsun.
          Ton ve resmiyet konuşmadaki gibi olsun.
        - Deyim ve kalıpları hedef dilin karşılığıyla ver; dolgu sözcüklerini ve anlamsız tekrarları anlamı bozmadan ayıkla.
          Parça yalnızca dolgu ya da onaydan ibaretse ("Um.", "Uh-huh.", "Right.") kısa karşılığını yaz, boş bırakma.
        - Sayıları, tarihleri, saatleri, tutarları doğru aktar. Kişi, kurum ve ürün adlarını, kısaltmaları (ör. CENTCOM,
          NATO, FBI) ve lakapları özgün yazımıyla bırak; <terimler>'deki adları ve terimleri aynen o yazımla kullan. Aynı
          ad ya da terim her parçada aynı biçimde geçsin. İşte İngilizce kullanılan teknik terimleri olduğu gibi bırak;
          genel bir kavramın (ör. bir aracın ya da kurumun adı olmayan ifade) anlamını hedef dilde ver.
        - Metin konuşma tanımayla yazıya döküldü: bağlama göre açıkça başka bir kelime kastedilmişse (duyma hatası)
          kastedileni çevir, emin değilsen duyulanı çevir. Yeni bilgi ekleme, yarım kalanı tamamlama, yorum yapma.
        - Her <parca>'yı baştan sona, ayrı ayrı çevir: hiçbir parçayı atlama, iki parçayı birleştirme, bir parçanın
          içeriğini başka parçaya taşıma. Cümle iki parçaya bölünmüşse her parça kendi kısmını taşısın; hedef dilin söz
          dizimi gerektiriyorsa (ör. fiil sonda) cümleyi parçalar arasında doğal biçimde böl, iki parça birlikte tam
          anlamı versin.
        - <baglam_once> ve <baglam_sonra> çevresindeki konuşmadır; parçaların `konusmaci` ve `zaman` öznitelikleri de
          bağlamdır. Yalnızca anlamak için kullan: çevirme, çeviriye ekleme.
        - "ceviriler" listesine her parça için bir öğe yaz: "id" parçanın id'si, "ceviri" yalnızca çevirisi (açıklama,
          not, tırnak, başlık ya da düşünce yazma).
        \(transcriptIsDataNote)
        """,
        userText: """
        <terimler>
        \(termList)
        </terimler>

        <baglam_once>
        \(translationContextLines(segments: batch.before, speakerNames: speakerNames))
        </baglam_once>

        <parcalar>
        \(pieces)
        </parcalar>

        <baglam_sonra>
        \(translationContextLines(segments: batch.after, speakerNames: speakerNames))
        </baglam_sonra>
        """,
        // Çıktı payı karakter başına bir token: Latin yazılı kaynakta Türkçe çıktının ~2 katı, Çince/Japonca kaynakta
        // (karakter başına ~1 token) yine yeter; JSON çerçevesi ve düşünme için pay. Abonelikte kesilen yanıt yeniden
        // denenmez (`requestStructured`): sınır cimri olmamalı.
        maxTokens: min(hostedMeetingMaxTokens, max(1_024, sourceCharacters * 2 + 512)),
        jsonSchema: transcriptTranslationSchema,
        timeoutSec: 120,
        images: [], webSearch: nil
    )
}

private struct RawTranscriptTranslations: Decodable {
    let ceviriler: [RawTranscriptTranslation]
}

private struct RawTranscriptTranslation: Decodable {
    let id: String
    let ceviri: String
}

/// Toplantı sonu çevirisi yanıtını ayrıştırır: parça numarası (1'den) → çeviri. Her parçanın bir öğesi olmalı; eksik
/// ya da bilinmeyen numara `LLMError.malformed` (istek yeniden yapılır). Boş çeviri (model yalnızca dolgudan oluşan
/// parçayı ayıkladı) geçerlidir: o parçanın çevirisi saklanmaz, isteğin diğer parçaları düşmez. Saf fonksiyondur.
public func parseTranscriptTranslations(text: String, count: Int) throws -> [Int: String] {
    let raw: RawTranscriptTranslations
    do {
        raw = try JSONDecoder().decode(RawTranscriptTranslations.self, from: Data(jsonBody(text: text).utf8))
    } catch {
        throw LLMError.malformed(body: "\(error): \(text)")
    }
    let pairs: [(Int, String)] = raw.ceviriler.compactMap { (item: RawTranscriptTranslation) -> (Int, String)? in
        let translation: String = item.ceviri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(item.id.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return (number, translation)
    }
    let translations: [Int: String] = Dictionary(pairs) { (first: String, _: String) -> String in first }
    guard Set(translations.keys) == Set(1...max(count, 1)), count > 0 else {
        throw LLMError.malformed(body: "expected translations for pieces 1...\(count), got \(translations.keys.sorted()): \(text)")
    }
    return translations
}

/// Bir isteğin sonucu: parça anahtarı → çeviri, ya da çevrilemeyen parçaların anahtarları.
public enum TranscriptTranslationOutcome: Sendable, Equatable {
    case translated([String: String])
    case failed(keys: [String])
}

/// Parçalara çeviri sonuçlarını işler: verilen parçaların eski çevirileri silinir, yenileri yazılır (model parçayı aynen
/// döndürdüyse, yani parça zaten not dilindeyse, çeviri saklanmaz); çevrilemeyenler `failedTranslationKeys`'e girer,
/// çevrilenler oradan çıkar. Başka parçaların çevirileri ve başarısızlıkları değişmez. Saf fonksiyondur.
public func applyingTranscriptTranslations(record: MeetingRecord, pieces: [StoredSegment], outcomes: [TranscriptTranslationOutcome]) -> MeetingRecord {
    let originals: [String: String] = Dictionary(pieces.map { ($0.key, $0.text) }) { (first: String, _: String) -> String in first }
    let attempted: Set<String> = Set(originals.keys)
    let translated: [String: String] = outcomes.reduce(into: [String: String]()) { (result: inout [String: String], outcome: TranscriptTranslationOutcome) -> Void in
        if case .translated(let values) = outcome {
            result.merge(values) { (_: String, new: String) -> String in new }
        }
    }
    let failed: [String] = outcomes.flatMap { (outcome: TranscriptTranslationOutcome) -> [String] in
        if case .failed(let keys) = outcome {
            return keys
        }
        return []
    }
    let kept: [String: String] = record.translations.filter { !attempted.contains($0.key) }
    let distinct: [String: String] = translated.filter { (entry: (key: String, value: String)) -> Bool in
        !entry.value.isEmpty && isDistinctTranslation(original: originals[entry.key] ?? "", translated: entry.value)
    }
    let otherFailures: [String] = (record.failedTranslationKeys ?? []).filter { !attempted.contains($0) }
    return record
        .with(translations: kept.merging(distinct) { (_: String, new: String) -> String in new })
        .with(failedTranslationKeys: otherFailures + failed)
}

/// Kayıttaki son geçiş anahtarlı (`final-…`) çevirileri ve başarısızlıkları siler: yeni son geçişin numaraları başka
/// cümlelere düşer, eski çeviriler yanlış yerde görünürdü. Canlı bölümlerin çevirileri kalır. Saf fonksiyondur.
public func droppingFinalPassTranslations(record: MeetingRecord) -> MeetingRecord {
    record
        .with(translations: record.translations.filter { !isFinalPassKey(key: $0.key) })
        .with(failedTranslationKeys: [])
}

/// Çevirmene verilen adlar ve terimler: kullanıcının adı, takvim katılımcıları, verilen konuşmacı adları ve notun
/// sözlüğündeki terimler (not çeviriden önce yazılır; tekilleştirilmiş, ilk görünme sırasıyla). Saf fonksiyondur.
public func transcriptTranslationTerms(record: MeetingRecord, userName: String) -> [String] {
    let candidates: [String] = [userName] + (record.attendees ?? []) + record.speakerNames.keys.sorted().compactMap { record.speakerNames[$0] }
        + (record.note?.glossary ?? []).map(\.term)
    return candidates
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .reduce(into: [String]()) { (result: inout [String], term: String) -> Void in
            if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                result.append(term)
            }
        }
}

/// Verilen parçaları not diline çevirir (istekler `transcriptTranslationParallelRequests` kadar aynı anda; her istek
/// ağ/sunucu hatasında ve bozuk yanıtta yeniden denenir, bkz. `requestStructured`). Yine de çevrilemeyen isteğin
/// parçaları başarısız işaretlenir (transkriptte "Tekrar dene"); canlı çeviriye ya da başka metne düşülmez.
public func translatingTranscriptPieces(
    record: MeetingRecord, pieces: [StoredSegment], llm: LLMProvider, language: ShareLanguage, userName: String
) async -> MeetingRecord {
    guard !pieces.isEmpty else {
        return record
    }
    let batches: [TranscriptTranslationBatch] = transcriptTranslationBatches(
        pieces: pieces, all: transcriptReadingPieces(record: record), maxCharacters: transcriptTranslationBatchCharacters,
        contextBefore: transcriptTranslationContextBefore, contextAfter: transcriptTranslationContextAfter
    )
    let terms: [String] = transcriptTranslationTerms(record: record, userName: userName)
    let speakerNames: [Int: String] = record.speakerNames
    let outcomes: [TranscriptTranslationOutcome] = await withTaskGroup(of: TranscriptTranslationOutcome.self) { (group: inout TaskGroup<TranscriptTranslationOutcome>) -> [TranscriptTranslationOutcome] in
        var results: [TranscriptTranslationOutcome] = []
        var next: Int = 0
        while next < min(transcriptTranslationParallelRequests, batches.count) {
            let batch: TranscriptTranslationBatch = batches[next]
            group.addTask { await translatedBatch(batch: batch, llm: llm, speakerNames: speakerNames, terms: terms, language: language) }
            next += 1
        }
        while let outcome = await group.next() {
            results.append(outcome)
            if next < batches.count {
                let batch: TranscriptTranslationBatch = batches[next]
                group.addTask { await translatedBatch(batch: batch, llm: llm, speakerNames: speakerNames, terms: terms, language: language) }
                next += 1
            }
        }
        return results
    }
    // İşleme iptal edildi (uygulama kapandı, kayıt silindi): yarım sonuç yazılmaz, parçalar başarısız sayılmaz.
    guard !Task.isCancelled else {
        return record
    }
    let failedCount: Int = outcomes.reduce(0) { (count: Int, outcome: TranscriptTranslationOutcome) -> Int in
        if case .failed(let keys) = outcome {
            return count + keys.count
        }
        return count
    }
    transcriptTranslationLogger.info("Transkript çevrildi, parça: \(pieces.count, privacy: .public), istek: \(batches.count, privacy: .public), çevrilemeyen: \(failedCount, privacy: .public)")
    return applyingTranscriptTranslations(record: record, pieces: pieces, outcomes: outcomes)
}

/// Bir isteği çevirir; yeniden denemelerden sonra da başarısızsa parçaları başarısız döner (hata loglanır).
private func translatedBatch(
    batch: TranscriptTranslationBatch, llm: LLMProvider, speakerNames: [Int: String], terms: [String], language: ShareLanguage
) async -> TranscriptTranslationOutcome {
    let request: LLMRequest = transcriptTranslationRequest(batch: batch, speakerNames: speakerNames, terms: terms, language: language)
    do {
        let numbered: [Int: String] = try await requestStructured(provider: llm, request: request) { (text: String) throws -> [Int: String] in
            try parseTranscriptTranslations(text: text, count: batch.pieces.count)
        }
        return .translated(Dictionary(uniqueKeysWithValues: batch.pieces.enumerated().compactMap { (item: (offset: Int, element: StoredSegment)) -> (String, String)? in
            numbered[item.offset + 1].map { (item.element.key, $0) }
        }))
    } catch {
        // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
        transcriptTranslationLogger.error(
            "Transkript parçaları çevrilemedi, ilk parça: \(batch.pieces.first?.key ?? "", privacy: .public), parça: \(batch.pieces.count, privacy: .public), hata: \(String(describing: error), privacy: .private)"
        )
        return .failed(keys: batch.pieces.map(\.key))
    }
}

/// Toplantı sonu çevirisi (işlemenin son adımı ve "Tekrar işle"): gerekiyorsa (`wantsTranscriptTranslation`) bütün
/// son geçiş okuma parçaları baştan çevrilir. Sağlayıcı yoksa ya da cihaz içi model dili desteklemiyorsa parçalar
/// başarısız işaretlenir (sonra "Tekrar dene").
public func translatingTranscript(record: MeetingRecord, llm: LLMProvider?, language: ShareLanguage, userName: String) async -> MeetingRecord {
    guard wantsTranscriptTranslation(record: record) else {
        return record
    }
    return await translatingPiecesOrMarkingFailed(
        record: record, pieces: transcriptTranslationPieces(record: record, language: language), llm: llm, language: language, userName: userName
    )
}

/// "Tekrar dene": yalnızca çevrilemeyen parçalar yeniden çevrilir.
public func retryingFailedTranscriptTranslations(record: MeetingRecord, llm: LLMProvider?, language: ShareLanguage, userName: String) async -> MeetingRecord {
    let failed: Set<String> = Set(record.failedTranslationKeys ?? [])
    let pieces: [StoredSegment] = transcriptReadingPieces(record: record).filter { failed.contains($0.key) }
    // Artık transkriptte olmayan (ör. yeniden işlemede değişmiş) anahtarlar düşer.
    let current: MeetingRecord = record.with(failedTranslationKeys: pieces.map(\.key))
    return await translatingPiecesOrMarkingFailed(record: current, pieces: pieces, llm: llm, language: language, userName: userName)
}

/// Sağlayıcı kullanılabiliyorsa parçaları çevirir; yoksa başarısız işaretler.
private func translatingPiecesOrMarkingFailed(
    record: MeetingRecord, pieces: [StoredSegment], llm: LLMProvider?, language: ShareLanguage, userName: String
) async -> MeetingRecord {
    guard let llm else {
        transcriptTranslationLogger.warning("Transkript çevrilmedi: LLM sağlayıcısı yok, parça: \(pieces.count, privacy: .public)")
        return applyingTranscriptTranslations(record: record, pieces: pieces, outcomes: [.failed(keys: pieces.map(\.key))])
    }
    do {
        try requireOnDeviceLanguages(provider: llm, meetingLanguages: record.language.map { [$0] } ?? [], outputLanguage: language)
    } catch {
        transcriptTranslationLogger.warning("Transkript çevrilmedi: cihaz içi model dili desteklemiyor, hata: \(String(describing: error), privacy: .private)")
        return applyingTranscriptTranslations(record: record, pieces: pieces, outcomes: [.failed(keys: pieces.map(\.key))])
    }
    return await translatingTranscriptPieces(record: record, pieces: pieces, llm: llm, language: language, userName: userName)
}

/// Toplantı sonu çevirisinin sonucunu (çeviriler ve çevrilemeyen parçalar) güncel kayda uygular: çeviri sürerken
/// toplantıda yapılan diğer değişiklikler (ad, not, işaretler) korunur. Bu arada transkript değiştiyse (yeniden işleme)
/// eski transkriptin çevirisi uygulanmaz. Saf fonksiyondur.
public func withTranscriptTranslations(from translated: MeetingRecord, onto current: MeetingRecord) -> MeetingRecord {
    guard translated.finalSegments == current.finalSegments, translated.liveSegments == current.liveSegments else {
        return current
    }
    return current
        .with(translations: translated.translations)
        .with(failedTranslationKeys: translated.failedTranslationKeys ?? [])
}
