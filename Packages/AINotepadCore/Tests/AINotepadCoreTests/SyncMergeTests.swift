import Foundation
import Testing
@testable import AINotepadCore

private let mac: String = "mac-device"
private let phone: String = "phone-device"
private let t0: Date = Date(timeIntervalSinceReferenceDate: 815_100_000)
private let t1: Date = t0.addingTimeInterval(60)
private let t2: Date = t0.addingTimeInterval(120)

/// The synced state of a record recorded on the Mac, stamped as changed at `at` against `previous`.
private func state(_ record: MeetingRecord, previous: MeetingSyncState?, at: Date) throws -> MeetingSyncState {
    try stampingChanges(
        previous: previous,
        updated: meetingSyncParts(record: record, contentObjectID: "content-1", originDeviceID: mac, clocks: previous?.fieldClocks ?? [:]).state,
        now: at
    )
}

private func merge(base: MeetingSyncState?, local: MeetingSyncState, remote: MeetingSyncState, device: String) -> MeetingStateMerge {
    mergeMeetingState(base: base, local: local, remote: remote, localDeviceID: device, conflictReason: "Changed on another device", myNotesSeparator: "-----")
}

@Suite struct SyncMergeTests {
    // iPhone completes one task while the Mac completes another and renames the meeting: everything is kept.
    @Test func independentEditsAreAllKept() throws {
        let record: MeetingRecord = syncSampleRecord()
        let base: MeetingSyncState = try state(record, previous: nil, at: t0)
        let tasks: [NoteTask] = record.note?.tasks ?? []
        let onPhone: MeetingSyncState = try state(togglingTask(record: record, task: tasks[0]).with(folder: "Board"), previous: base, at: t1)
        let onMac: MeetingSyncState = try state(record.with(title: "Budget review"), previous: base, at: t2)
        let merged: MeetingSyncState = merge(base: base, local: onPhone, remote: onMac, device: phone).state
        #expect(Set(merged.completedTasks ?? []) == Set(tasks.map { taskKey(task: $0) }))
        #expect(merged.title == "Budget review" && merged.note?.title == "Budget review")
        #expect(merged.folder == "Board")
        // Merging from the other side gives the same content.
        let mirrored: MeetingSyncState = merge(base: base, local: onMac, remote: onPhone, device: mac).state
        #expect(mirrored.title == merged.title && mirrored.folder == merged.folder && Set(mirrored.completedTasks ?? []) == Set(merged.completedTasks ?? []))
    }

    // Undoing a completed task on one device is not undone by the other device's unrelated edit.
    @Test func undoOnOneSideWins() throws {
        let record: MeetingRecord = syncSampleRecord()
        let base: MeetingSyncState = try state(record, previous: nil, at: t0)
        let done: [String] = record.completedTasks ?? []
        let undone: MeetingSyncState = try state(record.with(completedTasks: []), previous: base, at: t1)
        let renamed: MeetingSyncState = try state(record.with(folder: "Ops"), previous: base, at: t1)
        let merged: MeetingSyncState = merge(base: base, local: renamed, remote: undone, device: mac).state
        #expect(!done.isEmpty && merged.completedTasks == [])
        #expect(merged.folder == "Ops")
    }

    // Both devices changed the same field: the later change wins (clock), ties keep the local one.
    @Test func sameFieldTakesTheLaterChange() throws {
        let record: MeetingRecord = syncSampleRecord()
        let base: MeetingSyncState = try state(record, previous: nil, at: t0)
        let earlier: MeetingSyncState = try state(record.with(folder: "Early"), previous: base, at: t1)
        let later: MeetingSyncState = try state(record.with(folder: "Late"), previous: base, at: t2)
        #expect(merge(base: base, local: earlier, remote: later, device: mac).state.folder == "Late")
        #expect(merge(base: base, local: later, remote: earlier, device: mac).state.folder == "Late")
        let tie: MeetingSyncState = try state(record.with(folder: "Tie"), previous: base, at: t2)
        #expect(merge(base: base, local: tie, remote: later, device: mac).state.folder == "Tie")
        // Speaker names merge per person.
        let namedOnPhone: MeetingSyncState = try state(record.with(speakerNames: [2: "Aino", 3: "Mikko"]), previous: base, at: t1)
        let renamedOnMac: MeetingSyncState = try state(record.with(speakerNames: [2: "Aino K."]), previous: base, at: t2)
        #expect(merge(base: base, local: namedOnPhone, remote: renamedOnMac, device: phone).state.speakerNames == [2: "Aino K.", 3: "Mikko"])
    }

    // Two devices rewrote the note at once: the later rewrite is the note, the other is kept in the history (restorable),
    // and task marks follow the winning note's tasks (`carriedTaskKeys`).
    @Test func concurrentNoteRewritesKeepTheLoserInHistory() throws {
        let record: MeetingRecord = syncSampleRecord()
        let base: MeetingSyncState = try state(record, previous: nil, at: t0)
        let original: MeetingNote = try #require(record.note)
        let rewrittenTasks: [NoteTask] = [
            NoteTask(owner: "Sen", description: "Send the budget to Aino today", dueDate: nil, isMine: true),
            NoteTask(owner: "Konuşmacı 2", description: "Book the venue", dueDate: nil, isMine: false),
        ]
        let macNote: MeetingNote = MeetingNote(title: original.title, summary: "Mac rewrite", decisions: [], tasks: rewrittenTasks, glossary: [])
        let phoneNote: MeetingNote = MeetingNote(title: original.title, summary: "Phone rewrite", decisions: [], tasks: original.tasks, glossary: [])
        // The phone completes the first task on its (old-wording) note; the Mac rewrote the note later.
        let onPhone: MeetingSyncState = try state(togglingTask(record: record.with(note: phoneNote), task: original.tasks[0]), previous: base, at: t1)
        let onMac: MeetingSyncState = try state(record.with(note: macNote), previous: base, at: t2)
        let merged: MeetingSyncState = merge(base: base, local: onPhone, remote: onMac, device: phone).state
        #expect(merged.note?.summary == "Mac rewrite")
        let loser: NoteVersion = try #require(merged.noteHistory?.first)
        #expect(loser.note.summary == "Phone rewrite" && loser.reason == "Changed on another device" && loser.savedAt == t1)
        #expect((merged.noteHistory?.count ?? 0) <= noteHistoryLimit)
        #expect(merged.sharedNotes == nil)
        // The phone's "done" moved onto the rewritten wording of the same task; the base's mark still applies.
        #expect(Set(merged.completedTasks ?? []) == Set(rewrittenTasks.map { taskKey(task: $0) }))
    }

    // Sent marks are never lost (no double send), send times keep the first, audio deleted sticks; status comes from
    // the recording device.
    @Test func sendMarksUniteAndOwnerFieldsComeFromTheRecordingDevice() throws {
        let record: MeetingRecord = syncSampleRecord()
        let base: MeetingSyncState = try state(record, previous: nil, at: t0)
        let task: NoteTask = try #require(record.note?.tasks.first)
        let phoneRecord: MeetingRecord = record.markingSent(destinationID: "notion-1").markingTaskSent(trackerID: "linear", task: task)
            .with(notesSentAt: t2).with(status: .interrupted, failureMessage: "phone thinks so")
        let macRecord: MeetingRecord = record.markingSent(destinationID: "teams-1").with(notesSentAt: t1).withAudioDeleted().with(notice: "Final pass skipped")
        let onPhone: MeetingSyncState = try state(phoneRecord, previous: base, at: t1)
        let onMac: MeetingSyncState = try state(macRecord, previous: base, at: t1)
        for (local, remote, device) in [(onPhone, onMac, phone), (onMac, onPhone, mac)] {
            let merged: MeetingSyncState = merge(base: base, local: local, remote: remote, device: device).state
            #expect(Set(merged.sentDestinationIDs ?? []) == ["slack-1", "notion-1", "teams-1"])
            #expect(merged.sentTaskKeys == ["linear": [taskKey(task: task)]])
            #expect(merged.notesSentAt == t1)
            #expect(merged.audioDeleted)
            #expect(merged.status == .done && merged.failureMessage == nil && merged.notice == "Final pass skipped")
        }
    }

    @Test func ownNotesMergeByLines() {
        let base: String = "Ask about Q3\nCheck travel"
        // Edits in different places merge.
        #expect(mergeMyNotes(base: base, local: "Ask about Q3 and Q4\nCheck travel", remote: "Ask about Q3\nCheck travel\nCall Aino", separator: "---")
            == ("Ask about Q3 and Q4\nCheck travel\nCall Aino", false))
        // The same line changed differently: both kept around the separator, flagged.
        let conflict = mergeMyNotes(base: base, local: "Ask about Q3\nCheck hotels", remote: "Ask about Q3\nCheck flights", separator: "---")
        #expect(conflict == ("Ask about Q3\nCheck hotels\n---\nCheck flights", true))
        // One side unchanged, or both made the same change: no conflict.
        #expect(mergeMyNotes(base: base, local: base, remote: "New", separator: "---") == ("New", false))
        #expect(mergeMyNotes(base: base, local: "Same", remote: "Same", separator: "---") == ("Same", false))
        #expect(mergeMyNotes(base: base, local: nil, remote: base, separator: "---") == (nil, false))
        // Without a base everything differing is kept.
        #expect(mergeMyNotes(base: nil, local: "A", remote: "B", separator: "---") == ("A\n---\nB", true))
    }

    @Test func highlightsAndFoldersAreThreeWaySets() {
        let first: Highlight = Highlight(startSec: 10, endSec: nil)
        let second: Highlight = Highlight(startSec: 20, endSec: 30)
        let third: Highlight = Highlight(startSec: 40, endSec: nil)
        #expect(mergedOrderedSet(base: [first], local: [first, second], remote: [] as [Highlight]) == [second])
        #expect(mergedOrderedSet(base: [first], local: [first, second], remote: [first, third]) == [first, second, third])
        #expect(mergedOrderedSet(base: nil, local: [first], remote: [second]) == [first, second])
        #expect(mergedOrderedSet(base: nil as [Highlight]?, local: nil, remote: nil) == nil)
        let prefs: SyncPrefs = mergeSyncPrefs(
            base: SyncPrefs(schema: 1, folders: ["A", "B"], recipes: []),
            local: SyncPrefs(schema: 1, folders: ["A", "B", "C"], recipes: [Recipe(id: "r1", title: "Mine", prompt: "p", symbol: "s", isBuiltIn: false)]),
            remote: SyncPrefs(schema: 1, folders: ["B"], recipes: [])
        )
        #expect(prefs.folders == ["B", "C"] && prefs.recipes.map(\.id) == ["r1"])
    }

    @Test func peopleBookMergesAdditionsEditsAndRemovals() {
        let day: (Double) -> Date = { (offset: Double) -> Date in t0.addingTimeInterval(offset * 86_400) }
        let aino: SavedPerson = SavedPerson(name: "Aino", role: "PM", email: "", addedAt: day(0))
        let mikko: SavedPerson = SavedPerson(name: "Mikko", role: "", email: "", addedAt: day(0))
        let base: PeopleBook = PeopleBook(saved: [aino, mikko], removed: [])
        // Mac edits Aino's role and removes Mikko; iPhone adds Leena.
        let onMac: PeopleBook = removingPerson(book: addingPerson(book: base, person: SavedPerson(name: "Aino", role: "CTO", email: "", addedAt: day(0))), name: "Mikko", now: day(1))
        let onPhone: PeopleBook = addingPerson(book: base, person: SavedPerson(name: "Leena", role: "", email: "", addedAt: day(1)))
        let merged: PeopleBook = mergePeopleBook(base: base, local: onPhone, remote: onMac)
        #expect(merged.saved.map(\.name).sorted() == ["Aino", "Leena"])
        #expect(merged.saved.first { $0.name == "Aino" }?.role == "CTO")
        #expect(merged.removed.map(\.name) == ["Mikko"])
        // Re-added after the removal on the other device: the later action wins.
        let readded: PeopleBook = addingPerson(book: base, person: SavedPerson(name: "mikko", role: "", email: "", addedAt: day(2)))
        #expect(mergePeopleBook(base: base, local: readded, remote: onMac).saved.contains { $0.name.lowercased() == "mikko" })
    }

    @Test func askConversationsUniteTurns() {
        let turn: (String, Double) -> AskConversationTurn = { (question: String, offset: Double) -> AskConversationTurn in
            AskConversationTurn(
                id: UUID(), question: question, scopeMeetingIDs: [], scopeTitles: [], recipeTitle: nil, startedAt: t0.addingTimeInterval(offset),
                finishedAt: t0.addingTimeInterval(offset + 5), terms: [], readPassages: [], readScreens: nil, answer: "a", sources: []
            )
        }
        let first: AskConversationTurn = turn("First?", 0)
        let id: UUID = UUID()
        let local: AskConversation = AskConversation(id: id, createdAt: t0, updatedAt: t1, title: "First?", turns: [first, turn("Mac follow-up", 60)])
        let remote: AskConversation = AskConversation(id: id, createdAt: t0, updatedAt: t2, title: "First?", turns: [first, turn("Phone follow-up", 30)])
        let merged: AskConversation = mergeAskConversation(local: local, remote: remote)
        #expect(merged.turns.map(\.question) == ["First?", "Phone follow-up", "Mac follow-up"])
        #expect(merged.updatedAt == t2 && merged.createdAt == t0)
    }
}
