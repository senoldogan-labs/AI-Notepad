import Foundation

/// Not maddesinin kaynakları: maddenin transkriptte geçtiği yerler, yerel ve belirlenimci olarak bulunur (dil modeli
/// çağrılmaz, transkript cihazdan çıkmaz). Toplantı sayfasında maddenin büyütecine tıklayınca "Transkriptten"
/// açılır: tek satır bağlam ve en çok `noteSourceMaxQuotes` alıntı.

/// Bir alıntı: transkript paragrafı ve maddeyle en çok örtüşen bir iki cümlesi.
public struct NoteSourceQuote: Sendable, Equatable, Identifiable {
    public let paragraph: TranscriptParagraph
    /// Gösterilen kısım: paragrafın maddeyle en çok örtüşen cümlesi (kısaysa sonrakiyle), en çok
    /// `noteSourceExcerptChars` karakter. Eşleşme yalnız çeviride ise çeviriden.
    public let excerpt: String

    public var id: String {
        paragraph.id
    }

    public init(paragraph: TranscriptParagraph, excerpt: String) {
        self.paragraph = paragraph
        self.excerpt = excerpt
    }
}

/// Bağlam satırı: en iyi alıntının geçtiği konu akışı bölümü (varsa) ve onun çevresindeki alıntıların zaman aralığı
/// ("Fiyatlandırma konuşulurken, 10:12–10:48").
public struct NoteSourceContext: Sendable, Equatable {
    /// En iyi alıntının düştüğü konu akışı bölümünün başlığı; konu akışı yoksa nil.
    public let topic: String?
    public let startSec: Double
    public let endSec: Double

    public init(topic: String?, startSec: Double, endSec: Double) {
        self.topic = topic
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Maddenin kaynakları: alıntılar zaman sırasıyla; hiç bulunamadıysa alıntı yok ve bağlam nil.
public struct NoteSources: Sendable, Equatable {
    public let context: NoteSourceContext?
    public let quotes: [NoteSourceQuote]

    public init(context: NoteSourceContext?, quotes: [NoteSourceQuote]) {
        self.context = context
        self.quotes = quotes
    }
}

/// Bir maddeye gösterilen en çok alıntı.
public let noteSourceMaxQuotes: Int = 3
/// Alıntının en uzun hali (karakter).
let noteSourceExcerptChars: Int = 280
/// Seçilen alıntının puanı en iyinin en az bu oranı olmalı (zayıf, tek ortak sözcüklü paragraflar gösterilmesin).
let noteSourceRelativeFloor: Double = 0.5
/// BM25 sabitleri: terim sıklığının doygunluğu ve uzunluk düzeltmesi.
private let bm25K1: Double = 1.2
private let bm25B: Double = 0.75
/// Komşu paragrafın puanından alınan pay: ilgili paragrafların yanındaki paragraf öne geçer (konu birkaç paragraf sürer).
private let neighborShare: Double = 0.3
/// Ardışık iki terimin paragrafta da ardışık geçmesinin (öbek) ek puanı, iki terimin idf ortalamasının katı.
private let phraseBonus: Double = 0.6
/// Maddenin anı (karar ve açık konuların "[12:34]"i, konu akışı bölümünün başı) varsa anın çevresi öne geçer; etki bu
/// süreyle (saniye) azalır.
private let anchorDecaySec: Double = 120
/// Anın en çok etkisi: tam anındaki paragrafın puanı (1 + bu) katına çıkar.
private let anchorWeight: Double = 1.0

/// Maddenin transkriptteki kaynakları. Madde ve paragraflar aynı sözcük köklerine indirgenir (`searchTokens`, ilk 5
/// harf: Fince ve Türkçe ekler eşleşmeyi bozmasın); paragraflar BM25 ile puanlanır (paragrafın not dilindeki çevirisi
/// de okunur: not başka dilde yazıldıysa eşleşme çeviriden gelir), maddedeki ardışık terimler paragrafta da ardışıksa
/// öbek puanı eklenir, komşu paragrafın puanının bir payı eklenir ve maddenin anı varsa anın çevresi öne geçer. En
/// iyinin `noteSourceRelativeFloor` oranını geçen en çok `noteSourceMaxQuotes` paragraf zaman sırasıyla döner. Sözcük
/// eşleşmesi yoksa ve an varsa anın paragrafı tek alıntıdır; o da yoksa alıntı yok. Saf fonksiyondur.
public func noteSources(text: String, anchorSec: Double?, paragraphs: [TranscriptParagraph], outline: [OutlineItem]) -> NoteSources {
    let queryStems: [String] = sourceStems(text: text)
    let uniqueStems: [String] = Array(Set(queryStems)).sorted()
    let documents: [[String]] = paragraphs.map { (paragraph: TranscriptParagraph) -> [String] in
        sourceStems(text: paragraph.text) + sourceStems(text: paragraph.turkish ?? "")
    }
    let idf: [String: Double] = inverseFrequencies(stems: uniqueStems, documents: documents)
    let averageLength: Double = max(1, Double(documents.map(\.count).reduce(0, +)) / Double(max(1, documents.count)))
    let lexical: [Double] = documents.map { (document: [String]) -> Double in
        bm25(document: document, stems: uniqueStems, idf: idf, averageLength: averageLength)
            + phraseScore(document: document, query: queryStems, idf: idf)
    }
    let smoothed: [Double] = lexical.indices.map { (index: Int) -> Double in
        let previous: Double = index > 0 ? lexical[index - 1] : 0
        let next: Double = index + 1 < lexical.count ? lexical[index + 1] : 0
        // Yalnız kendi eşleşmesi olan paragraf komşudan pay alır: hiç ortak sözcüğü olmayan paragraf alıntı olmasın.
        return lexical[index] > 0 ? lexical[index] + neighborShare * max(previous, next) : 0
    }
    let scored: [(index: Int, score: Double)] = smoothed.enumerated().map { (item: (offset: Int, element: Double)) -> (index: Int, score: Double) in
        (item.offset, item.element * anchorFactor(paragraph: paragraphs[item.offset], anchorSec: anchorSec))
    }
    let top: Double = scored.map(\.score).max() ?? 0
    let chosen: [Int]
    if top > 0 {
        chosen = scored
            .filter { $0.score >= top * noteSourceRelativeFloor }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(noteSourceMaxQuotes)
            .map(\.index)
    } else if let anchorSec, let index = anchorParagraphIndex(paragraphs: paragraphs, anchorSec: anchorSec) {
        chosen = [index]
    } else {
        chosen = []
    }
    let quotes: [NoteSourceQuote] = chosen.sorted().map { (index: Int) -> NoteSourceQuote in
        NoteSourceQuote(paragraph: paragraphs[index], excerpt: sourceExcerpt(paragraph: paragraphs[index], stems: uniqueStems, idf: idf))
    }
    let best: TranscriptParagraph? = chosen.first.map { paragraphs[$0] }
    return NoteSources(context: best.map { sourceContext(best: $0, quotes: quotes, outline: outline) }, quotes: quotes)
}

/// Metnin arama kökleri sırasıyla (öbek eşleşmesi için yinelenenler korunur). Saf fonksiyondur.
func sourceStems(text: String) -> [String] {
    searchTokens(text: text).map { String($0.prefix(5)) }
}

/// Köklerin BM25 idf'si: az paragrafta geçen kök çok puan alır (`log(1 + (N - n + 0.5) / (n + 0.5))`, hep pozitif).
/// Saf fonksiyondur.
private func inverseFrequencies(stems: [String], documents: [[String]]) -> [String: Double] {
    let count: Double = Double(documents.count)
    return stems.reduce(into: [String: Double]()) { (result: inout [String: Double], stem: String) -> Void in
        let containing: Double = Double(documents.filter { $0.contains(stem) }.count)
        result[stem] = log(1 + (count - containing + 0.5) / (containing + 0.5))
    }
}

/// Paragrafın BM25 puanı. Saf fonksiyondur.
private func bm25(document: [String], stems: [String], idf: [String: Double], averageLength: Double) -> Double {
    let length: Double = Double(document.count)
    return stems.reduce(0) { (total: Double, stem: String) -> Double in
        let frequency: Double = Double(document.filter { $0 == stem }.count)
        guard frequency > 0, let weight = idf[stem] else {
            return total
        }
        return total + weight * frequency * (bm25K1 + 1) / (frequency + bm25K1 * (1 - bm25B + bm25B * length / averageLength))
    }
}

/// Maddedeki ardışık kök çiftlerinden paragrafta da ardışık geçenlerin ek puanı. Saf fonksiyondur.
private func phraseScore(document: [String], query: [String], idf: [String: Double]) -> Double {
    guard query.count > 1, document.count > 1 else {
        return 0
    }
    let documentPairs: Set<String> = Set(zip(document, document.dropFirst()).map { "\($0.0) \($0.1)" })
    return zip(query, query.dropFirst()).reduce(0) { (total: Double, pair: (String, String)) -> Double in
        guard pair.0 != pair.1, documentPairs.contains("\(pair.0) \(pair.1)") else {
            return total
        }
        return total + phraseBonus * ((idf[pair.0] ?? 0) + (idf[pair.1] ?? 0)) / 2
    }
}

/// Anın etkisi: an yoksa 1; varsa paragrafın ana uzaklığıyla azalan 1…(1 + `anchorWeight`). Saf fonksiyondur.
private func anchorFactor(paragraph: TranscriptParagraph, anchorSec: Double?) -> Double {
    guard let anchorSec else {
        return 1
    }
    let distance: Double = max(0, max(paragraph.startSec - anchorSec, anchorSec - paragraph.endSec))
    return 1 + anchorWeight * exp(-distance / anchorDecaySec)
}

/// Anın düştüğü paragraf: anı kapsayan, yoksa andan sonra başlayan ilk, o da yoksa son paragraf. Saf fonksiyondur.
private func anchorParagraphIndex(paragraphs: [TranscriptParagraph], anchorSec: Double) -> Int? {
    paragraphs.firstIndex { $0.startSec <= anchorSec && anchorSec <= $0.endSec }
        ?? paragraphs.firstIndex { $0.startSec >= anchorSec }
        ?? (paragraphs.isEmpty ? nil : paragraphs.count - 1)
}

/// Paragrafın maddeyle en çok örtüşen cümlesi (kısaysa sonrakiyle birlikte): önce asıl metinde, eşleşme yalnız
/// çevirideyse çeviride aranır; hiç eşleşmezse asıl metnin başı. En çok `noteSourceExcerptChars`. Saf fonksiyondur.
func sourceExcerpt(paragraph: TranscriptParagraph, stems: [String], idf: [String: Double]) -> String {
    let candidates: [String] = [paragraph.text] + (paragraph.turkish.map { [$0] } ?? [])
    for text in candidates {
        let sentences: [String] = sourceSentences(text: text)
        let scores: [Double] = sentences.map { (sentence: String) -> Double in
            Set(sourceStems(text: sentence)).reduce(0) { $0 + (stems.contains($1) ? idf[$1] ?? 0 : 0) }
        }
        if let best = scores.indices.max(by: { scores[$0] != scores[$1] ? scores[$0] < scores[$1] : $0 > $1 }), scores[best] > 0 {
            let withNext: String = sentences[best].count < 80 && best + 1 < sentences.count
                ? sentences[best] + " " + sentences[best + 1]
                : sentences[best]
            return clipped(text: withNext, maxChars: noteSourceExcerptChars)
        }
    }
    return clipped(text: paragraph.text, maxChars: noteSourceExcerptChars)
}

/// Metnin cümleleri (kırpılmış, boşlar atılmış); cümle bulunamazsa metnin tamamı. Saf fonksiyondur.
func sourceSentences(text: String) -> [String] {
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { (substring: String?, _: Range<String.Index>, _: Range<String.Index>, _: inout Bool) -> Void in
        if let sentence = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
            sentences.append(sentence)
        }
    }
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return sentences.isEmpty ? (trimmed.isEmpty ? [] : [trimmed]) : sentences
}

/// Uzun metin sözcük sınırında kesilip "…" ile biter. Saf fonksiyondur.
private func clipped(text: String, maxChars: Int) -> String {
    guard text.count > maxChars else {
        return text
    }
    let head: Substring = text.prefix(maxChars)
    let cut: Substring = head.lastIndex(of: " ").map { head[..<$0] } ?? head
    return cut.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
}

/// Bağlam: en iyi alıntının (`best`) düştüğü konu akışı bölümü ve ona `sourceContextWindowSec` içindeki alıntıların
/// kapsadığı aralık (toplantının başka yerindeki alıntılar aralığı bütün toplantıya yaymasın). Saf fonksiyondur.
private func sourceContext(best: TranscriptParagraph, quotes: [NoteSourceQuote], outline: [OutlineItem]) -> NoteSourceContext {
    let near: [TranscriptParagraph] = quotes.map(\.paragraph).filter { abs($0.startSec - best.startSec) <= sourceContextWindowSec }
    let topic: OutlineItem? = outline
        .sorted { $0.startSec < $1.startSec }
        .last { $0.startSec <= best.startSec + 1 }
    return NoteSourceContext(
        topic: topic?.title, startSec: near.map(\.startSec).min() ?? best.startSec, endSec: near.map(\.endSec).max() ?? best.endSec
    )
}

/// Bağlam aralığına giren alıntıların en iyi alıntıya en çok uzaklığı (saniye).
let sourceContextWindowSec: Double = 180

/// Notun özeti madde madde: her cümle ayrı madde (kaynağı ayrı bulunsun). Saf fonksiyondur.
public func noteSummaryBullets(summary: String) -> [String] {
    summary
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .flatMap { (line: String) -> [String] in
            // Model bazen özeti madde işaretli yazar: işaret atılır.
            let body: String = line.replacing(/^[-•*]\s+/, with: "")
            return sourceSentences(text: body)
        }
}

/// Transkript çekmecesindeki arama: metninde ya da çevirisinde sorgu geçen paragraflar (büyük/küçük harf, aksan ve ı/i
/// duyarsız; bkz. `searchFolded`), sırası korunur; boş sorgu hepsini döndürür. Saf fonksiyondur.
public func transcriptMatches(paragraphs: [TranscriptParagraph], query: String) -> [TranscriptParagraph] {
    let needle: String = searchFolded(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !needle.isEmpty else {
        return paragraphs
    }
    return paragraphs.filter { (paragraph: TranscriptParagraph) -> Bool in
        searchFolded(paragraph.text).contains(needle) || searchFolded(paragraph.turkish ?? "").contains(needle)
    }
}
