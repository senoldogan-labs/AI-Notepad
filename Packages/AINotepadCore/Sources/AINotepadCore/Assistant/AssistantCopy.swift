import CryptoKit
import Foundation

// Yapay zekâ asistanı erişimi (tasarım docs/superpowers/specs/2026-11-05-remote-mcp.md): kullanıcı açınca her toplantının
// not kopyası (başlık, tarih, süre, klasör, katılımcılar, not ve kendi notları; asla metin dökümü, ses, ekran görüntüsü
// ya da ses izi) sunucuya yüklenir; bağlanan asistanlar mcp.gistsmith.com üzerinden okur. Bu dosya kopyanın
// saf hâlidir: toplantıdan sunucunun şemasına (`server/src/assistant/projection.ts`) izdüşüm, sınırlar ve parmak izi.

/// Sunucunun kabul ettiği en büyük istek gövdesi (`projectionMaxBytes`).
public let assistantUploadMaxBytes: Int = 512 * 1024

/// Bir görevin kopyadaki hâli (`projectionTaskSchema`).
public struct AssistantTaskCopy: Sendable, Equatable, Codable {
    public let owner: String
    public let description: String
    public let dueDate: String?
    public let isMine: Bool
    public let done: Bool

    public init(owner: String, description: String, dueDate: String?, isMine: Bool, done: Bool) {
        self.owner = owner
        self.description = description
        self.dueDate = dueDate
        self.isMine = isMine
        self.done = done
    }

    private enum CodingKeys: String, CodingKey {
        case owner, description, dueDate, isMine, done
    }

    // Sunucu şeması `dueDate`i boş olsa da ister (`nullable`, `optional` değil): nil `null` yazılır.
    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(owner, forKey: .owner)
        try container.encode(description, forKey: .description)
        try container.encode(dueDate, forKey: .dueDate)
        try container.encode(isMine, forKey: .isMine)
        try container.encode(done, forKey: .done)
    }
}

/// Konu akışının bir bölümü.
public struct AssistantOutlineCopy: Sendable, Equatable, Codable {
    public let startSec: Double
    public let title: String
    public let summary: String
}

/// Sözlükteki bir terim.
public struct AssistantGlossaryCopy: Sendable, Equatable, Codable {
    public let term: String
    public let meaning: String
}

/// Notun kopyadaki hâli (`projectionNoteSchema`).
public struct AssistantNoteCopy: Sendable, Equatable, Codable {
    public let title: String
    public let summary: String
    public let decisions: [String]
    public let tasks: [AssistantTaskCopy]
    public let outline: [AssistantOutlineCopy]
    public let glossary: [AssistantGlossaryCopy]
    public let openQuestions: [String]?
}

/// Bir toplantının asistanlara açılan kopyası (`meetingProjectionSchema`): yalnız not ve toplantının kendi alanları.
public struct AssistantMeetingCopy: Sendable, Equatable, Codable {
    public let title: String
    /// ISO 8601, saat dilimiyle.
    public let startedAt: String
    public let durationSec: Int
    public let folder: String?
    public let attendees: [String]
    public let language: String?
    public let note: AssistantNoteCopy?
    public let myNotes: String?

    private enum CodingKeys: String, CodingKey {
        case title, startedAt, durationSec, folder, attendees, language, note, myNotes
    }

    // Boş alanlar `null` yazılır: sunucu şeması bu alanları her zaman ister.
    public func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(durationSec, forKey: .durationSec)
        try container.encode(folder, forKey: .folder)
        try container.encode(attendees, forKey: .attendees)
        try container.encode(language, forKey: .language)
        try container.encode(note, forKey: .note)
        try container.encode(myNotes, forKey: .myNotes)
    }
}

/// `PUT /v1/assistant/meetings/:id` gövdesi: kopya, hazırlandığı dönem (epoch) ve yükleyen cihaz.
public struct AssistantMeetingUpload: Sendable, Equatable, Encodable {
    public let epoch: Int64
    public let deviceId: String
    public let copy: AssistantMeetingCopy

    public init(epoch: Int64, deviceId: String, copy: AssistantMeetingCopy) {
        self.epoch = epoch
        self.deviceId = deviceId
        self.copy = copy
    }

    private enum CodingKeys: String, CodingKey {
        case epoch, deviceId
    }

    // Sunucu düz bir nesne bekler: kopyanın alanları epoch ve deviceId ile aynı düzeyde.
    public func encode(to encoder: any Encoder) throws {
        try copy.encode(to: encoder)
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(deviceId, forKey: .deviceId)
    }
}

/// Toplantı kopyaya girer mi: örnek toplantı asla; kayıt ya da işleme süren toplantı henüz değil; notu da kendi notu
/// da olmayan (ör. başarısız) toplantı gereksiz. Saf fonksiyondur.
public func isAssistantUploadable(record: MeetingRecord) -> Bool {
    guard !record.isSampleMeeting, isSyncableMeeting(record: record) else {
        return false
    }
    let hasMyNotes: Bool = !(record.myNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return record.note != nil || hasMyNotes
}

/// Metnin en fazla `maxUTF16` UTF-16 birimlik başı (sunucu sınırları JavaScript dize uzunluğudur); karakter ortadan
/// bölünmez. Saf fonksiyondur.
func assistantCut(text: String, maxUTF16: Int) -> String {
    guard text.utf16.count > maxUTF16 else {
        return text
    }
    var count: Int = 0
    var end: String.Index = text.startIndex
    for index in text.indices {
        let size: Int = text[index].utf16.count
        if count + size > maxUTF16 {
            break
        }
        count += size
        end = text.index(after: index)
    }
    return String(text[..<end])
}

/// Saat dilimli ISO 8601 (ör. `2026-11-06T09:30:00Z`). Saf fonksiyondur.
func assistantTimestamp(date: Date) -> String {
    date.formatted(.iso8601)
}

/// Toplantının asistan kopyası (sunucu şemasının sınırlarına kırpılmış); kopyaya girmeyen toplantıda nil
/// (`isAssistantUploadable`). Notta konuşmacı adları uygulanır (`namedRecord`; asistan "Konuşmacı 2" değil adı
/// görür), görevlerin tamamlandı işareti toplantıdan gelir. Saf fonksiyondur.
public func assistantMeetingCopy(record: MeetingRecord, userName: String) -> AssistantMeetingCopy? {
    guard isAssistantUploadable(record: record) else {
        return nil
    }
    let named: MeetingRecord = namedRecord(record: record, userName: userName)
    let note: AssistantNoteCopy? = named.note.map { (note: MeetingNote) -> AssistantNoteCopy in
        AssistantNoteCopy(
            title: assistantCut(text: note.title, maxUTF16: 300),
            summary: assistantCut(text: note.summary, maxUTF16: 40_000),
            decisions: note.decisions.prefix(200).map { assistantCut(text: $0, maxUTF16: 4000) },
            tasks: note.tasks.prefix(300).map { (task: NoteTask) -> AssistantTaskCopy in
                AssistantTaskCopy(
                    owner: assistantCut(text: task.owner, maxUTF16: 200), description: assistantCut(text: task.description, maxUTF16: 4000),
                    dueDate: task.dueDate.map { assistantCut(text: $0, maxUTF16: 100) }, isMine: task.isMine, done: isTaskDone(record: record, task: task)
                )
            },
            outline: (note.outline ?? []).prefix(200).map { (item: OutlineItem) -> AssistantOutlineCopy in
                AssistantOutlineCopy(
                    startSec: min(max(item.startSec.isFinite ? item.startSec : 0, 0), 86_400), title: assistantCut(text: item.title, maxUTF16: 300),
                    summary: assistantCut(text: item.summary, maxUTF16: 4000)
                )
            },
            glossary: note.glossary.prefix(300).map { AssistantGlossaryCopy(term: assistantCut(text: $0.term, maxUTF16: 200), meaning: assistantCut(text: $0.meaning, maxUTF16: 2000)) },
            openQuestions: note.openQuestions.map { $0.prefix(200).map { assistantCut(text: $0, maxUTF16: 4000) } }
        )
    }
    let folder: String? = record.folder.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : assistantCut(text: $0, maxUTF16: 120) }
    let attendees: [String] = (record.attendees ?? [])
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .prefix(200)
        .map { assistantCut(text: $0, maxUTF16: 200) }
    let duration: TimeInterval = (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt)
    let myNotes: String? = record.myNotes.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : assistantCut(text: $0, maxUTF16: 100_000) }
    return AssistantMeetingCopy(
        title: assistantCut(text: record.title.trimmingCharacters(in: .whitespacesAndNewlines), maxUTF16: 300), startedAt: assistantTimestamp(date: record.startedAt),
        durationSec: Int(min(max(duration.isFinite ? duration : 0, 0), 86_400).rounded()), folder: folder, attendees: attendees,
        language: record.language?.rawValue, note: note, myNotes: myNotes
    )
}

/// Kopyanın parmak izi: kanonik JSON'un SHA-256'sı (onaltılık). Yüklenen hâlle aynıysa yeniden yüklenmez. Saf
/// fonksiyondur.
public func assistantFingerprint(copy: AssistantMeetingCopy) throws -> String {
    SHA256.hash(data: try canonicalSyncJSON(value: copy)).map { String(format: "%02x", $0) }.joined()
}
