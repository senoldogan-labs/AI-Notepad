import Foundation
import Testing
@testable import AINotepadCore

@Suite struct NoteHistoryTests {
    private func note(title: String) -> MeetingNote {
        MeetingNote(title: title, summary: "Özet \(title)", decisions: [], tasks: [], glossary: [])
    }

    private func record(note: MeetingNote?) -> MeetingRecord {
        MeetingRecord(
            id: "1", title: note?.title ?? "Toplantı", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: .finnish,
            status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: note,
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    // Not değişince eski not en yeni sürüm olarak başa eklenir; geçmiş en fazla 10 sürüm tutar (en eskisi düşer).
    @Test func previousNoteIsPushedNewestFirstAndCapped() {
        let start: MeetingRecord = record(note: note(title: "0"))
        let final: MeetingRecord = (1...12).reduce(start) { (current: MeetingRecord, step: Int) -> MeetingRecord in
            withNoteVersion(
                updated: current.with(note: note(title: "\(step)")), previous: current, reason: "Not yenilendi",
                savedAt: Date(timeIntervalSince1970: Double(step))
            )
        }
        #expect(final.note?.title == "12")
        #expect(final.noteHistory?.count == noteHistoryLimit)
        #expect(final.noteHistory?.map(\.note.title) == ["11", "10", "9", "8", "7", "6", "5", "4", "3", "2"])
        #expect(final.noteHistory?.first?.savedAt == Date(timeIntervalSince1970: 12))
    }

    // Not değişmediyse (ör. yenileme başarısız, eski not kaldı) ya da önceki not yoksa geçmiş değişmez.
    @Test func unchangedOrMissingNoteAddsNoVersion() {
        let current: MeetingRecord = record(note: note(title: "A"))
        #expect(withNoteVersion(updated: current, previous: current, reason: "Not yenilendi", savedAt: Date()).noteHistory == nil)
        let first: MeetingRecord = record(note: nil)
        let written: MeetingRecord = first.with(note: note(title: "A"))
        #expect(withNoteVersion(updated: written, previous: first, reason: "Tekrar işlendi", savedAt: Date()).noteHistory == nil)
    }

    // Geri yükleme seçilen sürümü not yapar, onu geçmişten çıkarır ve şimdiki notu geçmişe ekler: geri yükleme de geri
    // alınabilir.
    @Test func restoreIsItselfUndoable() throws {
        let original: MeetingRecord = record(note: note(title: "A"))
        let edited: MeetingRecord = withNoteVersion(
            updated: original.with(note: note(title: "B")), previous: original, reason: "Düzenlendi: özeti kısalt", savedAt: Date(timeIntervalSince1970: 1)
        )
        let restored: MeetingRecord = try restoringNoteVersion(record: edited, index: 0, reason: "Geri yüklendi", savedAt: Date(timeIntervalSince1970: 2))
        #expect(restored.note?.title == "A")
        #expect(restored.title == "A")
        #expect(restored.noteHistory == [NoteVersion(savedAt: Date(timeIntervalSince1970: 2), reason: "Geri yüklendi", note: note(title: "B"))])
        let again: MeetingRecord = try restoringNoteVersion(record: restored, index: 0, reason: "Geri yüklendi", savedAt: Date(timeIntervalSince1970: 3))
        #expect(again.note?.title == "B")
        #expect(again.noteHistory?.map(\.note.title) == ["A"])
    }

    // Olmayan sürüm sessizce yok sayılmaz: hangi sıranın istendiği ve geçmişin uzunluğu hatada.
    @Test func restoringMissingVersionThrows() {
        #expect(throws: NoteHistoryError.versionNotFound(index: 0, count: 0)) {
            try restoringNoteVersion(record: record(note: note(title: "A")), index: 0, reason: "Geri yüklendi", savedAt: Date())
        }
    }

    // Eski toplantı dosyalarında (geçmiş alanı yok) okuma bozulmaz; geçmiş kaydedilip geri okunur.
    @Test func historyRoundTripsAndOldFilesDecode() throws {
        let original: MeetingRecord = record(note: note(title: "A"))
        let edited: MeetingRecord = withNoteVersion(
            updated: original.with(note: note(title: "B")), previous: original, reason: "Not yenilendi", savedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded: MeetingRecord = try meetingDecoder().decode(MeetingRecord.self, from: encoder.encode(edited))
        #expect(decoded == edited)
        let old: MeetingRecord = try meetingDecoder().decode(MeetingRecord.self, from: encoder.encode(original))
        #expect(old.noteHistory == nil)
    }

    // The note on disk changed while the edit ran (sync or the iPhone wrote a newer note): the edit is applied onto the
    // disk record, that newer note enters the history and the marks set meanwhile are kept.
    @Test func editAppliesOntoNewerDiskNote() {
        let task: NoteTask = NoteTask(owner: "Sen", description: "Raporu gönder", dueDate: nil, isMine: true)
        let synced: MeetingNote = note(title: "B").with(title: "B", summary: "Özet B", decisions: [], tasks: [task], glossary: [])
        let start: MeetingRecord = record(note: note(title: "A"))
        let fresh: MeetingRecord = withNoteVersion(updated: start.with(note: synced), previous: start, reason: "Eşitlendi", savedAt: Date(timeIntervalSince1970: 1))
            .with(completedTasks: [taskKey(task: task)]).with(speakerNames: [1: "Ayşe"])
        let edited: MeetingNote = note(title: "C").with(title: "C", summary: "Özet C", decisions: [], tasks: [task], glossary: [])
        let saved: MeetingRecord = withEditedNote(fresh: fresh, edited: edited, reason: "Düzenlendi: kısalt", savedAt: Date(timeIntervalSince1970: 2))
        #expect(saved.note?.title == "C")
        #expect(saved.noteHistory?.map(\.note.title) == ["B", "A"])
        #expect(saved.noteHistory?.first?.reason == "Düzenlendi: kısalt")
        #expect(saved.completedTasks == [taskKey(task: task)])
        #expect(saved.speakerNames == [1: "Ayşe"])
    }

    // A rewrite applies its new note onto the disk record (the newer disk note enters the history) and keeps its own
    // notes, its input.
    @Test func rewriteAppliesOntoNewerDiskNote() {
        let start: MeetingRecord = record(note: note(title: "A")).with(myNotes: "benim notum")
        let fresh: MeetingRecord = record(note: note(title: "B"))
        let result: MeetingRecord = start.with(note: note(title: "C"))
        let saved: MeetingRecord = withRewrittenNote(fresh: fresh, start: start, result: result, reason: "Not yenilendi", savedAt: Date(timeIntervalSince1970: 2))
        #expect(saved.note?.title == "C")
        #expect(saved.myNotes == "benim notum")
        #expect(saved.noteHistory?.map(\.note.title) == ["B"])
    }

    // A failed rewrite returns the start note: the newer note on disk stays and only the failure message is applied.
    @Test func failedRewriteKeepsNewerDiskNote() {
        let start: MeetingRecord = record(note: note(title: "A"))
        let fresh: MeetingRecord = record(note: note(title: "B"))
        let result: MeetingRecord = start.with(status: .done, failureMessage: "Not yenilenemedi")
        let saved: MeetingRecord = withRewrittenNote(fresh: fresh, start: start, result: result, reason: "Not yenilendi", savedAt: Date(timeIntervalSince1970: 2))
        #expect(saved.note?.title == "B")
        #expect(saved.failureMessage == "Not yenilenemedi")
        #expect(saved.noteHistory == nil)
    }

    // A rewrite of a meeting without a note fails transiently: the failure keeps its kind, so the automatic retry still
    // picks the meeting up.
    @Test func failedRewriteKeepsFailureKind() {
        let start: MeetingRecord = record(note: nil)
        let result: MeetingRecord = start.failed(message: "Not oluşturulamadı", kind: .transient)
        let saved: MeetingRecord = withRewrittenNote(fresh: record(note: nil), start: start, result: result, reason: "Not yenilendi", savedAt: Date(timeIntervalSince1970: 2))
        #expect(saved.status == .failed)
        #expect(saved.failureKind == .transient)
        #expect(saved.failureMessage == "Not oluşturulamadı")
    }
}
