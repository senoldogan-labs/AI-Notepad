import Foundation

/// "Hangisi sendin?" kartındaki seçenek: adı verilmemiş konuşmacı ve tanınsın diye söylediği ilk cümle.
public struct UserSpeakerCandidate: Sendable, Equatable, Identifiable {
    public let person: Int
    /// Konuşmacının ilk anlamlı cümlesi (kısaltılmış); bulunamazsa boş.
    public let sample: String

    public init(person: Int, sample: String) {
        self.person = person
        self.sample = sample
    }

    public var id: Int { person }
}

/// Örnek cümlenin en uzun hali (karakter).
private let sampleLimit: Int = 70

/// Yüz yüze toplantıda (transkriptte "Sen" yok; kullanıcı da "Konuşmacı N") notta görev varken hiçbiri kullanıcının
/// değilse kullanıcının hangi konuşmacı olduğu sorulur: görevleri Görevlerim'e ancak o zaman düşer (konuşmacıya
/// kullanıcının adı verilince; bkz. `namedTask`). Adı verilmemiş konuşmacılar numara sırasıyla döner; kullanıcı zaten bir
/// konuşmacıysa, "Sen" konuştuysa, görev yoksa ya da görevlerden biri kullanıcınınsa boş. Saf fonksiyondur.
public func userSpeakerCandidates(record: MeetingRecord, userName: String) -> [UserSpeakerCandidate] {
    // Önce ucuz koşullar: Görevlerim bunu her toplantı için sorar; transkript yalnız gerekince okunur.
    let tasks: [NoteTask] = namedTasks(record: record, userName: userName)
    guard !tasks.isEmpty, !tasks.contains(where: \.isMine),
          !record.speakerNames.values.contains(where: { isUserName(name: $0, userName: userName) }) else {
        return []
    }
    let segments: [StoredSegment] = meetingSegments(record: record)
    guard !segments.contains(where: { $0.speaker == .me }) else {
        return []
    }
    let persons: [Int] = Array(Set(segments.compactMap(\.person))).sorted()
    return persons.filter { record.speakerNames[$0] == nil }.map { (person: Int) -> UserSpeakerCandidate in
        UserSpeakerCandidate(person: person, sample: speakerSample(segments: segments.filter { $0.person == person }))
    }
}

/// Konuşmacının en az dört sözcüklü ilk bölümü (yoksa en uzun bölümü), `sampleLimit` karakterde kesilmiş. Saf fonksiyondur.
private func speakerSample(segments: [StoredSegment]) -> String {
    let texts: [String] = segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let wordCount: (String) -> Int = { (text: String) -> Int in text.split(whereSeparator: \.isWhitespace).count }
    let chosen: String = texts.first { wordCount($0) >= 4 } ?? texts.max { $0.count < $1.count } ?? ""
    guard chosen.count > sampleLimit else {
        return chosen
    }
    let cut: Substring = chosen.prefix(sampleLimit)
    let atWord: Substring = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
    return atWord.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) + "…"
}
