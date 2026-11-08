import Foundation
import Testing
@testable import AINotepadCore

@Suite struct MeetingSpotlightTests {
    private let base: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(id: String, daysAgo: Double, tasks: [NoteTask]) -> MeetingRecord {
        MeetingRecord(
            id: id, title: "Kayıt \(id)", startedAt: base.addingTimeInterval(-daysAgo * 86400), endedAt: nil, language: .finnish, status: .done,
            failureMessage: nil, liveSegments: [StoredSegment(key: "k", speaker: .others, person: 1, startSec: 0, endSec: 2, text: "gizli transkript", words: nil)],
            finalSegments: [], translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Not \(id)", summary: "Özet \(id)", decisions: [], tasks: tasks, glossary: []),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    // Başlık, kişiler (katılımcılar ve verilen adlar, tekrarsız), özet ve görevler girer; transkript ve örnek toplantı girmez.
    @Test func entriesCarryNoteAtAGlanceOnly() {
        let real: MeetingRecord = record(id: "a", daysAgo: 1, tasks: [NoteTask(owner: "Aino", description: "Teklifi gönder", dueDate: "Cuma", isMine: false)])
            .with(attendees: ["Aino", "  ", "Mikko"])
            .with(speakerNames: [2: "Liisa", 1: "aino"])
            .with(folder: "Satış")
        let sample: MeetingRecord = record(id: "s", daysAgo: 0, tasks: []).markedAsSample()
        let entries: [SpotlightMeetingEntry] = spotlightMeetingEntries(records: [sample, real], userName: "Şenol")
        #expect(entries.map(\.id) == ["a"])
        let entry: SpotlightMeetingEntry = entries[0]
        #expect(entry.title == "Not a")
        #expect(entry.people == ["Aino", "Mikko", "Liisa"])
        #expect(entry.tasks == ["Aino: Teklifi gönder (Cuma)"])
        #expect(entry.keywords == ["Aino", "Mikko", "Liisa", "Satış"])
        #expect(entry.contentDescription == "Özet a\nAino: Teklifi gönder (Cuma)")
        #expect(!entry.contentDescription.contains("gizli"))
    }

    // Değişmeyen yeniden yazılmaz; kaybolan silinir.
    @Test func planWritesOnlyChanges() {
        let entries: [SpotlightMeetingEntry] = spotlightMeetingEntries(records: [record(id: "a", daysAgo: 1, tasks: []), record(id: "b", daysAgo: 2, tasks: [])], userName: "")
        let indexed: [String: SpotlightMeetingEntry] = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        #expect(spotlightIndexPlan(indexed: indexed, current: entries).isEmpty)
        let renamed: [SpotlightMeetingEntry] = spotlightMeetingEntries(records: [record(id: "a", daysAgo: 1, tasks: []).with(title: "Yeni")], userName: "")
        let plan: SpotlightIndexPlan = spotlightIndexPlan(indexed: indexed, current: renamed)
        #expect(plan.deletions == ["b"])
        #expect(plan.upserts.map(\.title) == ["Yeni"])
        let withTask: [SpotlightMeetingEntry] = spotlightMeetingEntries(
            records: [record(id: "a", daysAgo: 1, tasks: [NoteTask(owner: "Sen", description: "Ara", dueDate: nil, isMine: true)])], userName: ""
        )
        #expect(spotlightIndexPlan(indexed: indexed, current: withTask).upserts.map(\.id) == ["a"])
        #expect(spotlightIndexPlan(indexed: [:], current: entries).upserts.count == 2)
    }

    // Açık görevler: yeniden eskiye, bitenler ve başkasının görevleri yok; kimlik toplantıya geri çözülür.
    @Test func openTasksNewestFirst() {
        let mine: NoteTask = NoteTask(owner: "Sen", description: "Bütçeyi yaz", dueDate: nil, isMine: true)
        let done: NoteTask = NoteTask(owner: "Sen", description: "Ara", dueDate: nil, isMine: true)
        let theirs: NoteTask = NoteTask(owner: "Aino", description: "Sun", dueDate: nil, isMine: false)
        let old: MeetingRecord = record(id: "old", daysAgo: 5, tasks: [mine, done, theirs]).with(completedTasks: [taskKey(task: done)])
        let new: MeetingRecord = record(id: "new", daysAgo: 1, tasks: [NoteTask(owner: "Sen", description: "Demo", dueDate: "Pazartesi", isMine: true)])
        let sample: MeetingRecord = record(id: "s", daysAgo: 0, tasks: [mine]).markedAsSample()
        let tasks: [ShortcutTask] = openShortcutTasks(records: [old, sample, new], userName: "Şenol")
        #expect(tasks.map(\.description) == ["Demo", "Bütçeyi yaz"])
        #expect(tasks.map(\.meetingID) == ["new", "old"])
        #expect(tasks[0].dueDate == "Pazartesi")
        #expect(shortcutTaskMeetingID(taskID: tasks[1].id) == "old")
        #expect(shortcutTaskMeetingID(taskID: "no-separator") == nil)
        #expect(shortcutTaskMeetingID(taskID: "/key") == nil)
        #expect(shortcutTaskMeetingID(taskID: "id/") == nil)
    }

    // Siri'nin okuyacağı cevapta işaretler ve kaynak rozetleri yok; maddeler satır olur.
    @Test func plainAnswerDropsMarksAndCitations() {
        let answer: String = "**Bütçe** onaylandı [1][2].\n\n- Aino teklifi *cuma* gönderecek [3]\n- Demo [web](https://x.y) [w1]"
        #expect(plainAnswerText(text: answer) == "Bütçe onaylandı.\nAino teklifi cuma gönderecek\nDemo web")
    }

    // Toplantı seçici: örnek toplantı yok, yeniden eskiye, sorguyla süzülür.
    @Test func meetingPickerSkipsSample() {
        let records: [MeetingRecord] = [record(id: "a", daysAgo: 3, tasks: []), record(id: "b", daysAgo: 1, tasks: []), record(id: "s", daysAgo: 0, tasks: []).markedAsSample()]
        #expect(shortcutMeetings(records: records, query: "").map(\.id) == ["b", "a"])
        #expect(shortcutMeetings(records: records, query: "özet a").map(\.id) == ["a"])
    }
}
