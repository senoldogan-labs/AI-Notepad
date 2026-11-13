import Foundation

/// Konuşma tanımaya verilen anahtar terimler (ElevenLabs `keyterms`, Deepgram `keyterm`): toplantılarda geçen adlar ve
/// önemli terimler doğru yazılsın (Fince adlar, kurum içi terimler). Sırayla: kullanıcının adı, son toplantılarda
/// verilen konuşmacı adları, son notların sözlük terimleri. İki servisin kurallarına uyacak biçimde temizlenir (en çok
/// 5 kelime, en çok 40 karakter, `< > { } [ ] \` yok, virgül/noktalı virgül yok — Deepgram bunları tek terim sayar);
/// büyük/küçük harf duyarsız tekilleştirilir, en fazla `limit` terim. Saf fonksiyondur.
public func meetingKeyterms(records: [MeetingRecord], userName: String, limit: Int) -> [String] {
    // The sample meeting's fictional names and terms would bias real recordings.
    let meetings: [MeetingRecord] = realMeetings(records: records)
    let names: [String] = meetings.flatMap { (record: MeetingRecord) -> [String] in
        record.speakerNames.keys.sorted().compactMap { record.speakerNames[$0] }
    }
    let glossary: [String] = meetings.flatMap { (record: MeetingRecord) -> [String] in
        record.note?.glossary.map(\.term) ?? []
    }
    let candidates: [String] = [userName] + names + glossary
    return candidates
        .compactMap(sanitizedKeyterm)
        .reduce(into: [String]()) { (result: inout [String], term: String) -> Void in
            if !result.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
                result.append(term)
            }
        }
        .prefix(limit)
        .map { $0 }
}

/// Kayda verilen tanıma terimleri (Mac ve iPhone aynı): kullanıcının adı ve tanıma sözlüğü öne, sonra kayıtlı kişiler,
/// en sona son toplantılardan gelen adlar ve sözlük terimleri; sınırda önce toplantılardan gelenler düşer. Takvim
/// katılımcıları `keytermsWithAttendees` ile ayrıca öne eklenir. Saf fonksiyondur.
public func recognitionKeyterms(userName: String, vocabulary: String, savedPeople: [String], records: [MeetingRecord], limit: Int) -> [String] {
    keytermsWithAttendees(
        attendees: [userName] + customVocabulary(text: vocabulary) + savedPeople,
        keyterms: meetingKeyterms(records: records, userName: userName, limit: limit),
        limit: limit
    )
}

/// Terimi servis kurallarına göre temizler; uymuyorsa nil. Saf fonksiyondur.
func sanitizedKeyterm(_ text: String) -> String? {
    let forbidden: CharacterSet = CharacterSet(charactersIn: "<>{}[]\\,;:\n\r\t")
    let cleaned: String = text.components(separatedBy: forbidden).joined(separator: " ")
        .split(separator: " ").joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count >= 2, cleaned.count <= 40, cleaned.split(separator: " ").count <= 5 else {
        return nil
    }
    return cleaned
}
