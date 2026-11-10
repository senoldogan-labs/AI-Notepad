import Foundation

/// Notun önceki bir sürümü: yerine yenisi yazıldığı an, neden değiştiği ("Not yenilendi", "Düzenlendi: özeti kısalt")
/// ve o anki not.
public struct NoteVersion: Sendable, Equatable, Codable {
    public let savedAt: Date
    public let reason: String
    public let note: MeetingNote

    public init(savedAt: Date, reason: String, note: MeetingNote) {
        self.savedAt = savedAt
        self.reason = reason
        self.note = note
    }
}

/// Bir toplantıda saklanan en fazla önceki not sürümü.
public let noteHistoryLimit: Int = 10

/// Not geçmişi hataları.
public enum NoteHistoryError: Error, Equatable {
    /// İstenen sürüm geçmişte yok (geçmiş bu arada değişmiş olabilir).
    case versionNotFound(index: Int, count: Int)
}

/// `updated` kaydına `previous` kaydın notunu en yeni sürüm olarak ekler (yeniden eskiye, en fazla `noteHistoryLimit`).
/// Önceki not yoksa ya da not değişmediyse `updated` olduğu gibi döner. Saf fonksiyondur.
public func withNoteVersion(updated: MeetingRecord, previous: MeetingRecord, reason: String, savedAt: Date) -> MeetingRecord {
    guard let old = previous.note, old != updated.note else {
        return updated
    }
    let versions: [NoteVersion] = [NoteVersion(savedAt: savedAt, reason: reason, note: old)] + (updated.noteHistory ?? [])
    return updated.with(noteHistory: Array(versions.prefix(noteHistoryLimit)))
}

/// Geçmişteki `index`. sürümü geri yükler: o sürüm geçmişten çıkar, şimdiki not geçmişe eklenir (geri yükleme de geri
/// alınabilir). Görev işaretleri benzer görevlere taşınır. Sürüm yoksa `versionNotFound`. Saf fonksiyondur.
public func restoringNoteVersion(record: MeetingRecord, index: Int, reason: String, savedAt: Date) throws -> MeetingRecord {
    let versions: [NoteVersion] = record.noteHistory ?? []
    guard versions.indices.contains(index) else {
        throw NoteHistoryError.versionNotFound(index: index, count: versions.count)
    }
    let remaining: [NoteVersion] = versions.enumerated()
        .filter { (item: (offset: Int, element: NoteVersion)) -> Bool in item.offset != index }
        .map { (item: (offset: Int, element: NoteVersion)) -> NoteVersion in item.element }
    let restored: MeetingRecord = withCarriedTaskMarks(old: record, new: record.with(note: versions[index].note)).with(noteHistory: remaining)
    return withNoteVersion(updated: restored, previous: record, reason: reason, savedAt: savedAt)
}

/// Menüde sürümün satırı: değiştirildiği an ve neden ("27 Eki 14:05 · Düzenlendi: özeti kısalt"). Saf fonksiyondur.
public func noteVersionTitle(version: NoteVersion, locale: Locale) -> String {
    let date: String = version.savedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    return "\(date) · \(version.reason)"
}

/// Applies a note edit ("shorten the summary") onto `fresh`, the meeting as it is on disk when the 30–300 s edit
/// finished. Anything written meanwhile (a synced note, names, task marks from the iPhone) is kept: only the note is
/// replaced, task and send marks are carried from `fresh` to the edited note (`withJobMarks`), and the note on disk
/// enters the history. Pure function.
public func withEditedNote(fresh: MeetingRecord, edited: MeetingNote, reason: String, savedAt: Date) -> MeetingRecord {
    withNoteVersion(updated: withJobMarks(old: fresh, result: fresh.with(note: edited)), previous: fresh, reason: reason, savedAt: savedAt)
}

/// Applies a note rewrite (`regenerateNote`: new names, template or own notes) onto `fresh`, the meeting as it is on
/// disk when the rewrite finished. `start` is the record the rewrite was written from: its template and own notes are
/// the rewrite's inputs and are kept. `result` is the rewrite's outcome: its status and failure message are applied; its
/// note replaces the one on disk only when the rewrite wrote a new one (a failed rewrite returns `start`'s note, which
/// must not overwrite a newer note on disk). A replaced note on disk enters the history; task and send marks are
/// carried from `fresh` (`withJobMarks`). Pure function.
public func withRewrittenNote(fresh: MeetingRecord, start: MeetingRecord, result: MeetingRecord, reason: String, savedAt: Date) -> MeetingRecord {
    let withTemplate: MeetingRecord = start.template.map { (template: NoteTemplate) -> MeetingRecord in fresh.with(template: template) } ?? fresh
    let inputs: MeetingRecord = start.myNotes.map { (notes: String) -> MeetingRecord in withTemplate.with(myNotes: notes) } ?? withTemplate
    guard let note = result.note, result.note != start.note else {
        return withOutcome(record: inputs, outcome: result)
    }
    let rewritten: MeetingRecord = withOutcome(record: withJobMarks(old: inputs, result: inputs.with(note: note)), outcome: result)
    return withNoteVersion(updated: rewritten, previous: fresh, reason: reason, savedAt: savedAt)
}

/// `record` with the processing outcome of `outcome`: its status and failure message, and for a failure also its kind
/// (`with(status:failureMessage:)` clears the kind; the automatic retry reads it). Pure function.
func withOutcome(record: MeetingRecord, outcome: MeetingRecord) -> MeetingRecord {
    guard outcome.status == .failed, let message = outcome.failureMessage else {
        return record.with(status: outcome.status, failureMessage: outcome.failureMessage)
    }
    return record.failed(message: message, kind: outcome.failureKind)
}
