import Foundation
import Testing
@testable import AINotepadCore

/// A finished meeting with every synced field filled.
func syncSampleRecord() -> MeetingRecord {
    let start: Date = Date(timeIntervalSinceReferenceDate: 815_000_000)
    let tasks: [NoteTask] = [
        NoteTask(owner: "Sen", description: "Send the budget to Aino", dueDate: "2026-11-10", isMine: true),
        NoteTask(owner: "Konuşmacı 2", description: "Book the venue", dueDate: nil, isMine: false),
    ]
    let note: MeetingNote = MeetingNote(title: "Budget sync", summary: "We agreed the budget.", decisions: ["Budget approved"], tasks: tasks, glossary: [GlossaryEntry(term: "Capex", meaning: "Investment")])
        .with(outline: [OutlineItem(startSec: 0, title: "Intro", summary: "Hello")])
        .with(language: .english)
    let segment: StoredSegment = StoredSegment(
        key: "final-0", speaker: .others, person: 2, startSec: 0, endSec: 4.5, text: "Let's approve the budget.",
        words: [StoredWord(text: "Let's", startSec: 0, endSec: 0.4)]
    ).with(spokenLanguage: "en")
    let base: MeetingRecord = MeetingRecord(
        id: "20261103-101500", title: "Budget sync", startedAt: start, endedAt: start.addingTimeInterval(1800), language: .english, status: .done,
        failureMessage: nil, liveSegments: [StoredSegment(key: "others-0", speaker: .others, person: 2, startSec: 0, endSec: 4.5, text: "Lets approve budget", words: nil)],
        finalSegments: [segment], translations: ["final-0": "Hyväksytään budjetti."], speakerNames: [2: "Aino"], note: note, audioDeleted: false,
        engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    return base
        .with(voiceprints: [2: Voiceprint(embedding: [0.1, 0.2], seconds: 30)])
        .with(completedTasks: [taskKey(task: tasks[1])])
        .with(folder: "Finance")
        .with(highlights: [Highlight(startSec: 10, endSec: nil)])
        .with(attendees: ["Aino"])
        .with(myNotes: "Ask about Q3\nCheck travel")
        .markingSent(destinationID: "slack-1")
        .with(noteHistory: [NoteVersion(savedAt: start.addingTimeInterval(1900), reason: "Edited", note: note.with(title: "Old"))])
}

@Suite struct SyncCodingTests {
    // Splitting a meeting and joining it back gives the same record; only the voiceprints (device-local in phase 1)
    // are left out of the synced parts.
    @Test func splitAndJoinRoundTrip() throws {
        let record: MeetingRecord = syncSampleRecord()
        let parts: MeetingSyncParts = meetingSyncParts(record: record, contentObjectID: "c-1", originDeviceID: "mac", clocks: [:])
        #expect(joinedMeetingRecord(state: parts.state, content: parts.content, voiceprints: record.voiceprints) == record)
        #expect(joinedMeetingRecord(state: parts.state, content: parts.content, voiceprints: nil).voiceprints == nil)
        let stateJSON: String = String(decoding: try canonicalSyncJSON(value: parts.state), as: UTF8.self)
        let contentJSON: String = String(decoding: try canonicalSyncJSON(value: parts.content), as: UTF8.self)
        #expect(!stateJSON.contains("voiceprint") && !contentJSON.contains("voiceprint") && !contentJSON.contains("embedding"))
    }

    // Payloads go through canonical JSON + zlib and back unchanged; encoding twice gives identical bytes.
    @Test func payloadEncodingIsStableAndRoundTrips() throws {
        let parts: MeetingSyncParts = meetingSyncParts(record: syncSampleRecord(), contentObjectID: "c-1", originDeviceID: "mac", clocks: ["title": Date(timeIntervalSinceReferenceDate: 1)])
        let encoded: Data = try encodeSyncPayload(value: parts.state)
        #expect(try encodeSyncPayload(value: parts.state) == encoded)
        #expect(try decodeSyncPayload(type: MeetingSyncState.self, data: encoded) == parts.state)
        #expect(try decodeSyncPayload(type: MeetingSyncContent.self, data: try encodeSyncPayload(value: parts.content)) == parts.content)
        // Decode → encode is byte-identical too (nothing reorders).
        let decoded: MeetingSyncState = try decodeSyncPayload(type: MeetingSyncState.self, data: encoded)
        #expect(try encodeSyncPayload(value: decoded) == encoded)
        let json: Data = try canonicalSyncJSON(value: parts.state)
        #expect(encoded.count < json.count)
    }

    // The exact bytes of a small payload: a change here changes every synced object (and older apps reading it).
    @Test func canonicalJSONGolden() throws {
        let content: MeetingSyncContent = MeetingSyncContent(
            schema: 1, language: .finnish, fixedLanguage: nil, engine: .local, meNeedsFinalPass: nil,
            liveSegments: [StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 1.5, endSec: 2, text: "Hei / moi", words: nil)],
            finalSegments: [], translations: ["me-0": "Hi"]
        )
        let json: String = String(decoding: try canonicalSyncJSON(value: content), as: UTF8.self)
        #expect(json == #"{"engine":"local","finalSegments":[],"language":"fi","liveSegments":[{"endSec":2,"key":"me-0","speaker":"me","startSec":1.5,"text":"Hei / moi"}],"schema":1,"translations":{"me-0":"Hi"}}"#)
        let people: PeopleSyncPayload = PeopleSyncPayload(schema: 1, book: PeopleBook(saved: [SavedPerson(name: "Aino", role: "", email: "", addedAt: Date(timeIntervalSinceReferenceDate: 10))], removed: []))
        #expect(String(decoding: try canonicalSyncJSON(value: people), as: UTF8.self) == #"{"book":{"removed":[],"saved":[{"addedAt":10,"email":"","name":"Aino","role":""}]},"schema":1}"#)
    }

    @Test func newerSchemaAndBadDataAreRefused() throws {
        let newer: Data = try encodeSyncPayload(value: SyncPrefs(schema: 2, folders: [], recipes: []))
        #expect(throws: SyncPayloadError.unsupportedSchema(found: 2, supported: 1)) { try decodeSyncPayload(type: SyncPrefs.self, data: newer) }
        let wrongShape: Data = try encodeSyncPayload(value: SyncPrefs(schema: 1, folders: ["A"], recipes: []))
        #expect(throws: SyncPayloadError.self) { try decodeSyncPayload(type: MeetingSyncState.self, data: wrongShape) }
        #expect(throws: SyncPayloadError.self) { try decodeSyncPayload(type: SyncPrefs.self, data: Data("not zlib".utf8)) }
    }

    @Test func onlyFinishedMeetingsSync() {
        let record: MeetingRecord = syncSampleRecord()
        #expect(isSyncableMeeting(record: record))
        #expect(isSyncableMeeting(record: record.with(status: .failed, failureMessage: "x")))
        #expect(!isSyncableMeeting(record: record.with(status: .recording, failureMessage: nil)))
        #expect(!isSyncableMeeting(record: record.with(status: .processing, failureMessage: nil)))
        #expect(!isSyncableMeeting(record: record.with(status: .queued, failureMessage: nil)))
    }

    @Test func stampingMarksOnlyChangedFields() throws {
        let t0: Date = Date(timeIntervalSinceReferenceDate: 100)
        let t1: Date = Date(timeIntervalSinceReferenceDate: 200)
        let first: MeetingSyncState = try stampingChanges(
            previous: nil, updated: meetingSyncParts(record: syncSampleRecord(), contentObjectID: "c", originDeviceID: "mac", clocks: [:]).state, now: t0
        )
        #expect(first.fieldClocks[MeetingSyncField.title] == t0 && first.fieldClocks[MeetingSyncField.speakerName(person: 2)] == t0)
        let renamed: MeetingRecord = syncSampleRecord().with(folder: "Ops").with(speakerNames: [:])
        let second: MeetingSyncState = try stampingChanges(
            previous: first, updated: meetingSyncParts(record: renamed, contentObjectID: "c", originDeviceID: "mac", clocks: first.fieldClocks).state, now: t1
        )
        #expect(second.fieldClocks[MeetingSyncField.folder] == t1)
        #expect(second.fieldClocks[MeetingSyncField.speakerName(person: 2)] == t1)
        #expect(second.fieldClocks[MeetingSyncField.title] == t0 && second.fieldClocks[MeetingSyncField.note] == t0)
    }
}
