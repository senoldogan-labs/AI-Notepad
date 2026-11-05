import Foundation

// Mac <-> iPhone sync, phase 1 (text only). Design: docs/superpowers/specs/2026-11-03-mac-iphone-sync-options.md §8.
// Every synced object is a small JSON payload (`SyncCoding`), encrypted end to end on the device (`SyncCrypto`) and
// stored by the server as an opaque blob (`server/src/sync.ts`). Audio, screen snapshots and voiceprints stay on the
// device that recorded them.

/// Kinds of synced objects; the same list as the server's `syncObjectKinds` (`ServerParityTests`).
public enum SyncObjectKind: String, Sendable, Codable, CaseIterable {
    /// What the user changes on a meeting: title, note and its history, own notes, task marks, folder, speaker names…
    case meetingState = "meeting.state"
    /// What processing writes once: transcript segments, translations, language (rarely changes).
    case meetingContent = "meeting.content"
    /// One Ask conversation.
    case askChat = "ask.chat"
    /// The people book (`People.json`).
    case people
    /// Account preferences: saved folders, the user's Ask recipes and the settings that follow the account.
    case prefs
}

/// Server limits mirrored by the client so it can refuse before uploading (`ServerParityTests` compares them).
public enum SyncLimits {
    /// Largest encrypted object (bytes); the server answers `payload_too_large` above it.
    public static let objectMaxBytes: Int = 2_097_152
    /// Live objects per account.
    public static let accountMaxObjects: Int = 20_000
    /// Stored bytes per account.
    public static let accountMaxBytes: Int = 104_857_600
    /// Most changes per page of the change feed.
    public static let changesMaxLimit: Int = 1000
    /// Largest key envelope (base64 characters).
    public static let envelopeMaxChars: Int = 4096
}

/// Version of every payload below; a device that reads a newer one stops instead of guessing (`SyncPayloadError`).
public let syncPayloadSchema: Int = 1

/// Field names with a per-field change time in `MeetingSyncState.fieldClocks` (last writer wins when both devices
/// changed the same field). Speaker names use `speakerNames.<person>`.
public enum MeetingSyncField {
    public static let title: String = "title"
    public static let folder: String = "folder"
    public static let template: String = "template"
    public static let attendees: String = "attendees"
    public static let calendarEventID: String = "calendarEventID"
    public static let note: String = "note"
    public static let myNotes: String = "myNotes"

    /// Clock key of one speaker name.
    public static func speakerName(person: Int) -> String {
        "speakerNames.\(person)"
    }
}

/// `meeting.state`: the part of a `MeetingRecord` people edit, on any device. Status, failure, notice and times are
/// written only by the device that recorded the meeting (`originDeviceID`).
public struct MeetingSyncState: Sendable, Equatable, Codable {
    public let schema: Int
    /// The meeting's folder name on the recording device (`MeetingRecord.id`, `yyyyMMdd-HHmmss`); encrypted.
    public let meetingID: String
    /// The `meeting.content` object of this meeting.
    public let contentObjectID: String
    /// Sync device id of the device that recorded the meeting and holds its audio.
    public let originDeviceID: String
    public let startedAt: Date
    public let endedAt: Date?
    public let status: MeetingStatus
    public let failureMessage: String?
    public let notice: String?
    public let title: String
    public let note: MeetingNote?
    public let noteHistory: [NoteVersion]?
    public let sharedNotes: [String: MeetingNote]?
    public let myNotes: String?
    public let speakerNames: [Int: String]
    public let completedTasks: [String]?
    public let remindedTasks: [String]?
    public let folder: String?
    public let highlights: [Highlight]?
    public let attendees: [String]?
    public let calendarEventID: String?
    public let template: NoteTemplate?
    public let sentDestinationIDs: [String]?
    public let sentTaskKeys: [String: [String]]?
    public let notesSentAt: Date?
    public let webhookSentAt: Date?
    /// The recording device deleted the audio (phase 1: audio never leaves that device).
    public let audioDeleted: Bool
    /// Field name (`MeetingSyncField`) → when this device last changed it.
    public let fieldClocks: [String: Date]

    public init(
        schema: Int, meetingID: String, contentObjectID: String, originDeviceID: String, startedAt: Date, endedAt: Date?, status: MeetingStatus,
        failureMessage: String?, notice: String?, title: String, note: MeetingNote?, noteHistory: [NoteVersion]?, sharedNotes: [String: MeetingNote]?,
        myNotes: String?, speakerNames: [Int: String], completedTasks: [String]?, remindedTasks: [String]?, folder: String?, highlights: [Highlight]?,
        attendees: [String]?, calendarEventID: String?, template: NoteTemplate?, sentDestinationIDs: [String]?, sentTaskKeys: [String: [String]]?,
        notesSentAt: Date?, webhookSentAt: Date?, audioDeleted: Bool, fieldClocks: [String: Date]
    ) {
        self.schema = schema
        self.meetingID = meetingID
        self.contentObjectID = contentObjectID
        self.originDeviceID = originDeviceID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.failureMessage = failureMessage
        self.notice = notice
        self.title = title
        self.note = note
        self.noteHistory = noteHistory
        self.sharedNotes = sharedNotes
        self.myNotes = myNotes
        self.speakerNames = speakerNames
        self.completedTasks = completedTasks
        self.remindedTasks = remindedTasks
        self.folder = folder
        self.highlights = highlights
        self.attendees = attendees
        self.calendarEventID = calendarEventID
        self.template = template
        self.sentDestinationIDs = sentDestinationIDs
        self.sentTaskKeys = sentTaskKeys
        self.notesSentAt = notesSentAt
        self.webhookSentAt = webhookSentAt
        self.audioDeleted = audioDeleted
        self.fieldClocks = fieldClocks
    }

    /// Copy with new field clocks.
    func with(fieldClocks newClocks: [String: Date]) -> MeetingSyncState {
        MeetingSyncState(
            schema: schema, meetingID: meetingID, contentObjectID: contentObjectID, originDeviceID: originDeviceID, startedAt: startedAt,
            endedAt: endedAt, status: status, failureMessage: failureMessage, notice: notice, title: title, note: note, noteHistory: noteHistory,
            sharedNotes: sharedNotes, myNotes: myNotes, speakerNames: speakerNames, completedTasks: completedTasks, remindedTasks: remindedTasks,
            folder: folder, highlights: highlights, attendees: attendees, calendarEventID: calendarEventID, template: template,
            sentDestinationIDs: sentDestinationIDs, sentTaskKeys: sentTaskKeys, notesSentAt: notesSentAt, webhookSentAt: webhookSentAt,
            audioDeleted: audioDeleted, fieldClocks: newClocks
        )
    }

    /// Copy with the meeting's identity (folder name, content object, recording device) of another version: a local
    /// folder may be named differently (`-2` suffix) from the recording device's.
    func with(meetingID newMeetingID: String, contentObjectID newContentID: String, originDeviceID newOrigin: String) -> MeetingSyncState {
        MeetingSyncState(
            schema: schema, meetingID: newMeetingID, contentObjectID: newContentID, originDeviceID: newOrigin, startedAt: startedAt,
            endedAt: endedAt, status: status, failureMessage: failureMessage, notice: notice, title: title, note: note, noteHistory: noteHistory,
            sharedNotes: sharedNotes, myNotes: myNotes, speakerNames: speakerNames, completedTasks: completedTasks, remindedTasks: remindedTasks,
            folder: folder, highlights: highlights, attendees: attendees, calendarEventID: calendarEventID, template: template,
            sentDestinationIDs: sentDestinationIDs, sentTaskKeys: sentTaskKeys, notesSentAt: notesSentAt, webhookSentAt: webhookSentAt,
            audioDeleted: audioDeleted, fieldClocks: fieldClocks
        )
    }
}

/// `meeting.content`: what processing produced. Voiceprints are not synced in phase 1 (they stay on the recording
/// device; the owner decided against syncing biometric data for now).
public struct MeetingSyncContent: Sendable, Equatable, Codable {
    public let schema: Int
    public let language: MeetingLanguage?
    public let fixedLanguage: MeetingLanguage?
    public let engine: RecordingEngine?
    public let meNeedsFinalPass: Bool?
    public let liveSegments: [StoredSegment]
    public let finalSegments: [StoredSegment]
    public let translations: [String: String]

    public init(
        schema: Int, language: MeetingLanguage?, fixedLanguage: MeetingLanguage?, engine: RecordingEngine?, meNeedsFinalPass: Bool?,
        liveSegments: [StoredSegment], finalSegments: [StoredSegment], translations: [String: String]
    ) {
        self.schema = schema
        self.language = language
        self.fixedLanguage = fixedLanguage
        self.engine = engine
        self.meNeedsFinalPass = meNeedsFinalPass
        self.liveSegments = liveSegments
        self.finalSegments = finalSegments
        self.translations = translations
    }
}

/// The two synced parts of one meeting.
public struct MeetingSyncParts: Sendable, Equatable {
    public let state: MeetingSyncState
    public let content: MeetingSyncContent
}

/// `people`: the people book.
public struct PeopleSyncPayload: Sendable, Equatable, Codable {
    public let schema: Int
    public let book: PeopleBook

    public init(schema: Int, book: PeopleBook) {
        self.schema = schema
        self.book = book
    }
}

/// `ask.chat`: one Ask conversation.
public struct AskChatSyncPayload: Sendable, Equatable, Codable {
    public let schema: Int
    public let conversation: AskConversation

    public init(schema: Int, conversation: AskConversation) {
        self.schema = schema
        self.conversation = conversation
    }
}

/// `prefs`: account preferences shared by the devices.
public struct SyncPrefs: Sendable, Equatable, Codable {
    public let schema: Int
    /// Saved folder names (folders also come from meetings; see `meetingFolders`).
    public let folders: [String]
    /// The user's own Ask recipes (built-in ones are not synced).
    public let recipes: [Recipe]
    /// The user's settings that follow the account (`syncedSettingKeys`), by key, each with its change time; nil when
    /// there are none. Added without a schema bump: the field is optional (an older payload decodes as nil, and nil is
    /// not encoded, so such a payload's bytes are unchanged) and an older app ignores it when decoding. An older app
    /// re-uploads its prefs without it; the merge reads a missing map as "no information", never as "deleted", and the
    /// next newer device restores it (`mergeSyncedSettings`).
    public let settings: [String: SyncedSetting]?

    public init(schema: Int, folders: [String], recipes: [Recipe], settings: [String: SyncedSetting]?) {
        self.schema = schema
        self.folders = folders
        self.recipes = recipes
        self.settings = settings
    }
}

/// Splits a finished meeting into its synced parts. Voiceprints are left out (device-local in phase 1). `clocks` are
/// the state's field clocks (see `stampingChanges`). Pure function.
public func meetingSyncParts(record: MeetingRecord, contentObjectID: String, originDeviceID: String, clocks: [String: Date]) -> MeetingSyncParts {
    let state: MeetingSyncState = MeetingSyncState(
        schema: syncPayloadSchema, meetingID: record.id, contentObjectID: contentObjectID, originDeviceID: originDeviceID,
        startedAt: record.startedAt, endedAt: record.endedAt, status: record.status, failureMessage: record.failureMessage, notice: record.notice,
        title: record.title, note: record.note, noteHistory: record.noteHistory, sharedNotes: record.sharedNotes, myNotes: record.myNotes,
        speakerNames: record.speakerNames, completedTasks: record.completedTasks, remindedTasks: record.remindedTasks, folder: record.folder,
        highlights: record.highlights, attendees: record.attendees, calendarEventID: record.calendarEventID, template: record.template,
        sentDestinationIDs: record.sentDestinationIDs, sentTaskKeys: record.sentTaskKeys, notesSentAt: record.notesSentAt,
        webhookSentAt: record.webhookSentAt, audioDeleted: record.audioDeleted, fieldClocks: clocks
    )
    let content: MeetingSyncContent = MeetingSyncContent(
        schema: syncPayloadSchema, language: record.language, fixedLanguage: record.fixedLanguage, engine: record.engine,
        meNeedsFinalPass: record.meNeedsFinalPass, liveSegments: record.liveSegments, finalSegments: record.finalSegments,
        translations: record.translations
    )
    return MeetingSyncParts(state: state, content: content)
}

/// Rebuilds a meeting from its synced parts; `voiceprints` are this device's own (nil on a device that did not record
/// it). `joinedMeetingRecord(meetingSyncParts(record))` equals `record` except for voiceprints and the device-local
/// processing retry state (`failureKind`, `automaticRetries`). Pure function.
public func joinedMeetingRecord(state: MeetingSyncState, content: MeetingSyncContent, voiceprints: [Int: Voiceprint]?) -> MeetingRecord {
    MeetingRecord(
        id: state.meetingID, title: state.title, startedAt: state.startedAt, endedAt: state.endedAt, language: content.language, status: state.status,
        failureMessage: state.failureMessage, liveSegments: content.liveSegments, finalSegments: content.finalSegments,
        translations: content.translations, speakerNames: state.speakerNames, note: state.note, audioDeleted: state.audioDeleted,
        engine: content.engine, notice: state.notice, meNeedsFinalPass: content.meNeedsFinalPass, voiceprints: voiceprints,
        completedTasks: state.completedTasks, remindedTasks: state.remindedTasks, folder: state.folder, highlights: state.highlights,
        attendees: state.attendees, webhookSentAt: state.webhookSentAt, calendarEventID: state.calendarEventID, template: state.template,
        sharedNotes: state.sharedNotes, notesSentAt: state.notesSentAt, myNotes: state.myNotes, sentDestinationIDs: state.sentDestinationIDs,
        sentTaskKeys: state.sentTaskKeys, noteHistory: state.noteHistory, fixedLanguage: content.fixedLanguage
    )
}

/// Only finished meetings sync: recording, processing and offline-queued meetings live on their device until done.
/// Failed and interrupted meetings sync too (their text is useful; reprocessing stays on the recording device).
/// Pure function.
public func isSyncableMeeting(record: MeetingRecord) -> Bool {
    switch record.status {
    case .done, .failed, .interrupted:
        true
    case .recording, .processing, .queued:
        false
    }
}

/// The state's clocked field values, by `MeetingSyncField` key (nil-valued fields are present as "absent").
private func clockedValues(state: MeetingSyncState) throws -> [String: Data] {
    let encode: (any Encodable) throws -> Data = { (value: any Encodable) throws -> Data in try canonicalSyncJSON(value: AnyEncodableBox(value: value)) }
    var values: [String: Data] = [
        MeetingSyncField.title: try encode(state.title),
        MeetingSyncField.folder: try encode(state.folder),
        MeetingSyncField.template: try encode(state.template),
        MeetingSyncField.attendees: try encode(state.attendees),
        MeetingSyncField.calendarEventID: try encode(state.calendarEventID),
        MeetingSyncField.note: try encode(state.note),
        MeetingSyncField.myNotes: try encode(state.myNotes),
    ]
    for (person, name) in state.speakerNames {
        values[MeetingSyncField.speakerName(person: person)] = try encode(name)
    }
    return values
}

/// Wraps an existential so the canonical encoder can encode it (Optional encodes as `null`).
private struct AnyEncodableBox: Encodable {
    let value: any Encodable

    func encode(to encoder: any Encoder) throws {
        var container: any SingleValueEncodingContainer = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Stamps the fields that changed since `previous` (the last synced state) with `now`; unchanged fields keep their
/// clocks. A removed speaker name is a change too. With no previous state every present field is stamped. The clocks
/// break ties when two devices changed the same field (`mergeMeetingState`). Pure function.
public func stampingChanges(previous: MeetingSyncState?, updated: MeetingSyncState, now: Date) throws -> MeetingSyncState {
    let before: [String: Data] = try previous.map(clockedValues) ?? [:]
    let after: [String: Data] = try clockedValues(state: updated)
    var clocks: [String: Date] = previous?.fieldClocks ?? [:]
    for key in Set(before.keys).union(after.keys) where before[key] != after[key] {
        clocks[key] = now
    }
    return updated.with(fieldClocks: clocks)
}
