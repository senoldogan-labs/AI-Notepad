import Foundation

/// Önceki ilgili bir toplantıdan açık (tamamlanmamış) görev: kayıt başlarken hatırlatma olarak gösterilir.
public struct RelatedOpenTask: Sendable, Equatable, Identifiable {
    public let meetingID: String
    /// Kaynak toplantının başlığı (notun başlığı, yoksa kaydınki).
    public let meetingTitle: String
    public let meetingStartedAt: Date
    /// Görev, konuşmacı adları uygulanmış (`namedRecord`).
    public let task: NoteTask

    public init(meetingID: String, meetingTitle: String, meetingStartedAt: Date, task: NoteTask) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.task = task
    }

    /// Görev anahtarı toplantılar arasında yinelenebilir: kimlik toplantıyla birlikte.
    public var id: String { meetingID + "|" + task.trackingKey }
}

/// Takvim etkinliği kimliğinden dizinin kimliği: kimlik "<etkinlik>-<başlangıç saniyesi>" biçimindedir (tekrarlayan
/// etkinliğin her tekrarı aynı etkinlik kimliğini taşır); sondaki sayı atılır. Biçime uymayan kimlik olduğu gibi döner.
/// Saf fonksiyondur.
public func calendarSeriesID(eventID: String) -> String {
    guard let dash = eventID.lastIndex(of: "-") else {
        return eventID
    }
    let suffix: Substring = eventID[eventID.index(after: dash)...]
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), dash > eventID.startIndex else {
        return eventID
    }
    return String(eventID[..<dash])
}

/// Başlık karşılaştırması için sadeleştirilmiş metin (küçük harf, boşluklar tekil). Saf fonksiyondur.
private func simplifiedTitle(text: String) -> String {
    text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// Kayıt bu takvim toplantısıyla ilgili mi (brifingin "bu kişilerle ya da bu konuda" ölçüsünün yerel karşılığı):
/// yalnız takvime bağlanmış kayıtlar sayılır (bağlanmamış kayıtların başlığı genel "Toplantı"dır); aynı dizinin önceki
/// bir tekrarı, aynı başlık ya da katılımcıların en az yarısı (büyük olan listeye göre, en az bir kişi) ortak. Saf
/// fonksiyondur.
public func isRelatedMeeting(record: MeetingRecord, meeting: CalendarMeeting) -> Bool {
    guard let eventID = record.calendarEventID else {
        return false
    }
    if calendarSeriesID(eventID: eventID) == calendarSeriesID(eventID: meeting.id) {
        return true
    }
    let title: String = simplifiedTitle(text: meeting.title)
    if !title.isEmpty, simplifiedTitle(text: record.title) == title {
        return true
    }
    let current: Set<String> = Set(meeting.attendees.map { simplifiedTitle(text: $0) }.filter { !$0.isEmpty })
    let earlier: Set<String> = Set((record.attendees ?? []).map { simplifiedTitle(text: $0) }.filter { !$0.isEmpty })
    let shared: Int = current.intersection(earlier).count
    return shared > 0 && shared * 2 >= max(current.count, earlier.count)
}

/// Kayıt başlarken gösterilecek açık görevler: `before`dan önce başlamış ilgili toplantıların (`isRelatedMeeting`)
/// tamamlanmamış görevleri; yeni toplantı önce, toplantı içinde kullanıcıya düşenler önce (notun sırasıyla). Konuşmacı
/// adları uygulanır (`namedRecord`). Ağ ya da model çağrısı yoktur: yalnız yerel kayıtlar. Saf fonksiyondur.
public func relatedOpenTasks(meeting: CalendarMeeting, records: [MeetingRecord], userName: String, before: Date) -> [RelatedOpenTask] {
    records
        .filter { $0.startedAt < before && $0.note != nil && isRelatedMeeting(record: $0, meeting: meeting) }
        .sorted { $0.startedAt > $1.startedAt }
        .flatMap { (stored: MeetingRecord) -> [RelatedOpenTask] in
            let record: MeetingRecord = namedRecord(record: stored, userName: userName)
            let open: [NoteTask] = (record.note?.tasks ?? []).filter { !isTaskDone(record: record, task: $0) }
            let ordered: [NoteTask] = open.filter(\.isMine) + open.filter { !$0.isMine }
            return ordered.map { (task: NoteTask) -> RelatedOpenTask in
                RelatedOpenTask(meetingID: record.id, meetingTitle: record.note?.title ?? record.title, meetingStartedAt: record.startedAt, task: task)
            }
        }
}
