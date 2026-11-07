import Foundation

/// Aramada eşleşmenin bulunduğu yer (sonuç satırında eşleşen cümleyle gösterilir).
public enum MeetingSearchField: Sendable, Equatable {
    case title
    case note
    case task
    case myNotes
    case speaker
    case transcript
}

/// Bir toplantının arama sonucu: eşleşen alan, eşleşen cümle ve (transkriptte) toplantıdaki anı.
public struct MeetingSearchHit: Sendable, Equatable, Identifiable {
    public let meetingID: String
    public let field: MeetingSearchField
    /// Eşleşen cümle (en çok `searchSnippetLength` karakter); başlık ya da konuşmacı adı eşleşmesinde nil.
    public let snippet: String?
    /// Transkriptteki eşleşmenin toplantı başından saniyesi; transkript dışı eşleşmede nil.
    public let startSec: Double?

    public var id: String { meetingID }

    public init(meetingID: String, field: MeetingSearchField, snippet: String?, startSec: Double?) {
        self.meetingID = meetingID
        self.field = field
        self.snippet = snippet
        self.startSec = startSec
    }
}

/// Bir toplantının aramaya hazırlanmış metni: katlanmış (`searchFolded`) tek metin ve hangi kayıttan üretildiği.
/// Kayıt değişmedikçe yeniden katlanmaz (500 toplantıda tuş başına bütün transkriptleri katlamak saniyeyi aşıyordu).
public struct MeetingSearchEntry: Sendable {
    let record: MeetingRecord
    let folded: String
}

/// Toplantı kimliğine göre aramaya hazırlanmış metinler (bkz. `refreshedSearchIndex`).
public struct MeetingSearchIndex: Sendable {
    let entries: [String: MeetingSearchEntry]

    public static let empty: MeetingSearchIndex = MeetingSearchIndex(entries: [:])

    /// Dizindeki toplantı sayısı (testler ve günlük için).
    public var count: Int { entries.count }
}

/// Sonuç satırındaki cümlenin en çok uzunluğu.
public let searchSnippetLength: Int = 160

/// Aramanın tuş vuruşlarını beklediği süre: yazarken her harfte arama yapılmaz.
public let searchDebounce: Duration = .milliseconds(200)

/// Aramada alanları ayıran karakter (birim ayırıcı): kullanıcının sorgusunda bulunmaz, eşleşme iki alanın sınırını
/// aşamaz.
let searchFieldSeparator: String = "\u{1F}"

/// Toplantının aranan bütün alanları: başlık, not, görevler, kendi notların, konuşmacı adları, transkript ve
/// çevirileri. Saf fonksiyondur.
func searchFields(record: MeetingRecord) -> [String] {
    [record.title, record.note?.title ?? "", record.note?.summary ?? "", record.myNotes ?? ""]
        + (record.note?.decisions ?? [])
        + (record.note?.openQuestions ?? [])
        + (record.note?.tasks ?? []).flatMap { [$0.owner, $0.description] }
        + Array(record.speakerNames.values)
        + (record.liveSegments + record.finalSegments).map(\.text)
        + Array(record.translations.values)
}

/// Toplantının katlanmış arama metni. Saf fonksiyondur.
func foldedSearchText(record: MeetingRecord) -> String {
    searchFolded(searchFields(record: record).joined(separator: searchFieldSeparator))
}

/// Dizini toplantı listesine göre günceller: yalnız yeni ya da değişen toplantılar yeniden katlanır, listede olmayanlar
/// atılır. Kayıt karşılaştırması değişmeyen toplantıda paylaşılan depolamayla hızlıdır. Saf fonksiyondur.
public func refreshedSearchIndex(index: MeetingSearchIndex, records: [MeetingRecord]) -> MeetingSearchIndex {
    var entries: [String: MeetingSearchEntry] = [:]
    entries.reserveCapacity(records.count)
    for record in records {
        if let cached = index.entries[record.id], cached.record == record {
            entries[record.id] = cached
        } else {
            entries[record.id] = MeetingSearchEntry(record: record, folded: foldedSearchText(record: record))
        }
    }
    return MeetingSearchIndex(entries: entries)
}

/// Sorguyla eşleşen toplantılar `records` sırasıyla, her biri eşleşen cümlesiyle. Dizinde olmayan ya da dizindekinden
/// farklı toplantı yerinde katlanır (sonuç dizinin güncelliğine bağlı değildir). Boş sorgu boş liste verir. Büyük/küçük
/// harf, aksan ve ı/i duyarsızdır (`searchFolded`). Saf fonksiyondur.
public func searchMeetings(index: MeetingSearchIndex, records: [MeetingRecord], query: String) -> [MeetingSearchHit] {
    let needle: String = searchFolded(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !needle.isEmpty else {
        return []
    }
    return records.compactMap { (record: MeetingRecord) -> MeetingSearchHit? in
        let folded: String
        if let cached = index.entries[record.id], cached.record == record {
            folded = cached.folded
        } else {
            folded = foldedSearchText(record: record)
        }
        guard folded.range(of: needle, options: .literal) != nil else {
            return nil
        }
        return searchHit(record: record, needle: needle)
    }
}

/// Eşleşen toplantının sonuç satırı: önce başlık, sonra notun cümleleri, görevler, kendi notların, transkript
/// (zamanıyla, çevirisi de) ve konuşmacı adları. `needle` katlanmış sorgudur. Saf fonksiyondur.
func searchHit(record: MeetingRecord, needle: String) -> MeetingSearchHit {
    let matches: (String) -> Bool = { searchFolded($0).range(of: needle, options: .literal) != nil }
    if matches(record.title) || matches(record.note?.title ?? "") {
        return MeetingSearchHit(meetingID: record.id, field: .title, snippet: nil, startSec: nil)
    }
    let noteLines: [String] = [record.note?.summary ?? ""] + (record.note?.decisions ?? []) + (record.note?.openQuestions ?? [])
    if let sentence = noteLines.lazy.compactMap({ matchingSentence(text: $0, needle: needle) }).first {
        return MeetingSearchHit(meetingID: record.id, field: .note, snippet: sentence, startSec: nil)
    }
    if let task = (record.note?.tasks ?? []).first(where: { matches($0.description) || matches($0.owner) }) {
        return MeetingSearchHit(meetingID: record.id, field: .task, snippet: shortened(text: task.description), startSec: nil)
    }
    if let sentence = matchingSentence(text: record.myNotes ?? "", needle: needle) {
        return MeetingSearchHit(meetingID: record.id, field: .myNotes, snippet: sentence, startSec: nil)
    }
    // Gösterilen transkript: son geçiş varsa o, yoksa canlı bölümler.
    let segments: [StoredSegment] = record.finalSegments.isEmpty ? record.liveSegments : record.finalSegments
    for segment in segments + (record.finalSegments.isEmpty ? [] : record.liveSegments) {
        if let sentence = matchingSentence(text: segment.text, needle: needle)
            ?? record.translations[segment.key].flatMap({ matchingSentence(text: $0, needle: needle) })
        {
            return MeetingSearchHit(meetingID: record.id, field: .transcript, snippet: sentence, startSec: segment.startSec)
        }
    }
    return MeetingSearchHit(meetingID: record.id, field: .speaker, snippet: nil, startSec: nil)
}

/// Metnin katlanmış sorguyu içeren ilk cümlesi (`searchSnippetLength` karakterde kısaltılmış); yoksa nil. Cümle
/// bulunamazsa (ör. eşleşme iki cümleye yayılıyor) metnin kendisi. Saf fonksiyondur.
func matchingSentence(text: String, needle: String) -> String? {
    guard searchFolded(text).range(of: needle, options: .literal) != nil else {
        return nil
    }
    var found: String?
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { (sentence: String?, _: Range<String.Index>, _: Range<String.Index>, stop: inout Bool) in
        if let sentence, searchFolded(sentence).range(of: needle, options: .literal) != nil {
            found = sentence
            stop = true
        }
    }
    return shortened(text: (found ?? text).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Metin `searchSnippetLength` karakteri aşıyorsa kısaltılmış hâli ("…" ile). Saf fonksiyondur.
func shortened(text: String) -> String {
    text.count > searchSnippetLength ? String(text.prefix(searchSnippetLength - 1)) + "…" : text
}

/// Sorguyu içeren metinlerin sırası (transkriptte bul: paragraf ya da çevirisi); büyük/küçük harf, aksan ve ı/i
/// duyarsız. Boş sorgu boş liste verir. Saf fonksiyondur.
public func searchMatchingIndices(texts: [String], query: String) -> [Int] {
    let needle: String = searchFolded(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !needle.isEmpty else {
        return []
    }
    return texts.indices.filter { searchFolded(texts[$0]).range(of: needle, options: .literal) != nil }
}

/// Aramayı yeniden çalıştırmayı gerektiren değişikliklerin ucuz izi (görünümlerin `task(id:)` kimliği): başlık, not,
/// görevler, kendi notların, adlar ve transkriptin boyları. Bütün metni karşılaştırmadan değişikliği yakalar.
public struct MeetingSearchStamp: Sendable, Equatable {
    let id: String
    let title: String
    let noteLength: Int
    let myNotesLength: Int
    let speakerCount: Int
    let liveCount: Int
    let finalCount: Int
    let translationCount: Int
}

/// Toplantının arama izi (UTF-8 boyları sabit sürede okunur). Saf fonksiyondur.
public func searchStamp(record: MeetingRecord) -> MeetingSearchStamp {
    let note: MeetingNote? = record.note
    let noteLength: Int = (note?.title.utf8.count ?? -1) + (note?.summary.utf8.count ?? 0) + (note?.tasks.count ?? 0) + (note?.decisions.count ?? 0)
    return MeetingSearchStamp(
        id: record.id, title: record.title, noteLength: noteLength, myNotesLength: record.myNotes?.utf8.count ?? -1,
        speakerCount: record.speakerNames.count, liveCount: record.liveSegments.count, finalCount: record.finalSegments.count,
        translationCount: record.translations.count
    )
}

/// Toplantı aramasının önbelleği: katlanmış metinler toplantılar arasında saklanır, arama ana iş parçacığının dışında
/// çalışır (yazarken arayüz takılmaz). Görünümler sorguyu `searchDebounce` bekletip çağırır.
public actor MeetingSearchCache {
    private var index: MeetingSearchIndex = .empty

    public init() {}

    /// Dizini günceller ve sorguyla eşleşen toplantıları döndürür (bkz. `searchMeetings`).
    public func search(records: [MeetingRecord], query: String) -> [MeetingSearchHit] {
        index = refreshedSearchIndex(index: index, records: records)
        return searchMeetings(index: index, records: records, query: query)
    }
}
