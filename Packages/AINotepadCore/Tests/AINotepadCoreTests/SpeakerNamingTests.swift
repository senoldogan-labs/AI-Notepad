import Foundation
import Testing
@testable import AINotepadCore

@Suite struct SpeakerNamingTests {
    private let names: [Int: String] = [1: "Şenol", 2: "Julia"]

    private func record(note: MeetingNote, speakerNames: [Int: String]) -> MeetingRecord {
        MeetingRecord(
            id: "20261103-100000", title: note.title, startedAt: Date(timeIntervalSince1970: 1_793_000_000), endedAt: nil, language: .english,
            status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: speakerNames,
            note: note, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    private let note: MeetingNote = MeetingNote(
        title: "Roadmap with Speaker 2",
        summary: "Speaker 1 and Speaker 2 agreed on the plan; Speaker 12 joined late.",
        decisions: ["Konuşmacı 2'nin önerisi kabul edildi."],
        tasks: [
            NoteTask(owner: "Speaker 1", description: "Send the deck, as requested by Speaker 2", dueDate: "Friday", isMine: false),
            NoteTask(owner: "Speaker 3", description: "Book the room", dueDate: nil, isMine: false),
        ],
        glossary: [GlossaryEntry(term: "Speaker 2", meaning: "Owner of the plan: Speaker 2")]
    )
    .with(outline: [OutlineItem(startSec: 30, title: "Speaker 2 opens", summary: "Speaker 2 explains the goal.")])
    .with(language: .english)

    // Every label form models write is replaced; a longer number or word around the label is not.
    @Test func replacesLabelsWithWordBoundaries() {
        #expect(namingSpeakers(text: "Speaker 1 met Speaker 12 and speaker 2.", speakerNames: names) == "Şenol met Speaker 12 and Julia.")
        #expect(namingSpeakers(text: "Konuşmacı 2'nin görevi, Konuşmacı 1 onayladı", speakerNames: names) == "Julia'nin görevi, Şenol onayladı")
        #expect(namingSpeakers(text: "Puhuja 2 ja Sprecher 1", speakerNames: names) == "Julia ja Şenol")
        #expect(namingSpeakers(text: "由发言人2负责", speakerNames: names) == "由Julia负责")
        #expect(namingSpeakers(text: "Loudspeaker 1 is broken; Speaker 21 too", speakerNames: names) == "Loudspeaker 1 is broken; Speaker 21 too")
        #expect(namingSpeakers(text: "Speaker 3 stays generic", speakerNames: names) == "Speaker 3 stays generic")
        #expect(namingSpeakers(text: "Speaker 1", speakerNames: [:]) == "Speaker 1")
        // Blank names leave the label; names with template characters are inserted literally.
        #expect(namingSpeakers(text: "Speaker 1, Speaker 2", speakerNames: [1: " ", 2: "$1 \\Bo"]) == "Speaker 1, $1 \\Bo")
    }

    // The prompt's label word of every note language is recognized.
    @Test func recognizesEveryNoteLanguageWord() {
        for language in ShareLanguage.allCases {
            let word: String = speakerLabelWord(language: language)
            #expect(namingSpeakers(text: "\(word) 2", speakerNames: names) == "Julia", "\(language)")
        }
    }

    // Every text of the note is named; topic flow times, language, glossary terms and unnamed speakers stay.
    @Test func namesEveryNoteField() {
        let named: MeetingNote = namedNote(note: note, speakerNames: names, userName: "")
        #expect(named.title == "Roadmap with Julia")
        #expect(named.summary == "Şenol and Julia agreed on the plan; Speaker 12 joined late.")
        #expect(named.decisions == ["Julia'nin önerisi kabul edildi."])
        #expect(named.tasks.map(\.owner) == ["Şenol", "Speaker 3"])
        #expect(named.tasks[0].description == "Send the deck, as requested by Julia")
        #expect(named.glossary == [GlossaryEntry(term: "Speaker 2", meaning: "Owner of the plan: Julia")])
        #expect(named.outline == [OutlineItem(startSec: 30, title: "Julia opens", summary: "Julia explains the goal.")])
        #expect(named.language == .english)
    }

    // A task whose owner is now the user's name counts as the user's; its marks keep matching the stored task.
    @Test func namedOwnerMakesTaskMine() throws {
        let stored: MeetingRecord = record(note: note, speakerNames: names)
        let shown: MeetingRecord = namedRecord(record: stored, userName: "Şenol Doğan")
        let task: NoteTask = try #require(shown.note?.tasks.first)
        #expect(task.isMine)
        #expect(task.trackingKey == taskKey(task: note.tasks[0]))
        #expect(shown.note?.tasks[1].isMine == false)
        // Toggling with the shown task marks the stored task.
        let done: MeetingRecord = togglingTask(record: stored, task: task)
        #expect(isTaskDone(record: done, task: note.tasks[0]))
        #expect(isTaskDone(record: namedRecord(record: done, userName: "Şenol Doğan"), task: task))
        // The stored note keeps its labels; encoding the shown note does not leak the stored key.
        #expect(stored.note == note)
        let encoded: String = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
        #expect(!encoded.contains("storedKey"))
        // Tasks tab, filter and "your tasks" use the same rule.
        #expect(myTasks(meetings: [stored], userName: "şenol").map(\.task.owner) == ["Şenol"])
        #expect(myTasks(meetings: [stored], userName: "Mikko").isEmpty)
        #expect(filterMeetings(records: [stored], listFilter: .myTasks, userName: "Şenol") == [stored])
        #expect(filterMeetings(records: [stored], listFilter: .myTasks, userName: "").isEmpty)
    }

    // Renaming again or removing a name shows the new state; shared-language versions are named too.
    @Test func renamingAndSharedVersions() {
        let stored: MeetingRecord = record(note: note, speakerNames: names)
            .with(sharedNotes: ["fi": MeetingNote(title: "T", summary: "Puhuja 2 esitteli.", decisions: [], tasks: [], glossary: [])])
        #expect(namedRecord(record: stored, userName: "").sharedNotes?["fi"]?.summary == "Julia esitteli.")
        let renamed: MeetingRecord = stored.with(speakerNames: renamingSpeakers(names: names, edits: [2: "Aino"]))
        #expect(namedRecord(record: renamed, userName: "").note?.summary.contains("Aino agreed") == true)
        let unnamed: MeetingRecord = stored.with(speakerNames: renamingSpeakers(names: names, edits: [1: "", 2: ""]))
        #expect(namedRecord(record: unnamed, userName: "").note == note)
        // Naming twice changes nothing.
        let once: MeetingRecord = namedRecord(record: stored, userName: "Şenol")
        #expect(namedRecord(record: once, userName: "Şenol") == once)
    }

    // The cached list naming shows exactly what naming each meeting does, and follows renames, note and user name changes.
    @Test func cachedNamingMatchesNamingEachMeeting() {
        let named: MeetingRecord = record(note: note, speakerNames: names)
        let unnamed: MeetingRecord = MeetingRecord(
            id: "20261103-110000", title: "Plain", startedAt: Date(timeIntervalSince1970: 1_793_004_000), endedAt: nil, language: .english,
            status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: note, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let first: (records: [MeetingRecord], cache: NamedRecordsCache) = namedRecords(records: [named, unnamed], userName: "Şenol", cache: .empty)
        #expect(first.records == namedRecords(records: [named, unnamed], userName: "Şenol"))
        #expect(namedRecords(records: [named, unnamed], userName: "Şenol", cache: first.cache).records == first.records)
        let renamed: MeetingRecord = named.with(speakerNames: renamingSpeakers(names: names, edits: [2: "Aino"]))
        let edited: MeetingRecord = unnamed.with(note: MeetingNote(title: "Speaker 1 only", summary: "", decisions: [], tasks: [], glossary: []))
        for (records, userName) in [([renamed, edited], "Şenol"), ([named, unnamed], "Julia"), ([unnamed], "Şenol")] {
            #expect(namedRecords(records: records, userName: userName, cache: first.cache).records == namedRecords(records: records, userName: userName))
        }
        #expect(myTasks(namedRecords: first.records).map(\.task.owner) == myTasks(meetings: [named, unnamed], userName: "Şenol").map(\.task.owner))
    }

    @Test func userNameMatching() {
        #expect(isUserName(name: "şenol", userName: "Şenol Doğan"))
        #expect(isUserName(name: "Şenol Doğan", userName: "şenol doğan"))
        #expect(!isUserName(name: "Doğan", userName: "Şenol Doğan"))
        #expect(!isUserName(name: "Şenol", userName: ""))
        #expect(!isUserName(name: "", userName: "Şenol"))
    }

    // The note prompt asks for the deterministic label in the note language; the shared version maps it to the target.
    @Test func promptsAskForFixedLabel() throws {
        let segment: StoredSegment = StoredSegment(key: "final-0", speaker: .others, person: 2, startSec: 0, endSec: 3, text: "Hei", words: nil)
        let request: LLMRequest = try #require(meetingNoteRequest(
            segments: [segment], speakerNames: [:], userName: "Şenol", template: .general, myNotes: "", language: .german, screens: []
        ))
        #expect(request.system.contains("\"Sprecher N\""))
        let shared: LLMRequest = sharedNoteRequest(note: note, language: .finnish, userName: "Şenol")
        #expect(shared.system.contains("\"Speaker 2\"") && shared.system.contains("\"Puhuja N\""))
    }
}
