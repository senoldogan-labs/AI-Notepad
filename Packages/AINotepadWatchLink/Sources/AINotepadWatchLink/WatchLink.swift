import Foundation

// The shared language of the iPhone app and the Apple Watch app (WatchConnectivity). The iPhone owns the account and
// every server call; the Watch only sees the snapshot below and sends requests. Nothing here is a secret. Every value
// crosses WatchConnectivity as JSON inside a one-key property-list dictionary (`watchPayloadKey`), so both sides decode
// the same Codable types and an unknown future case fails to decode instead of being misread.
// Design: docs/superpowers/specs/2026-11-08-apple-watch.md.

/// The dictionary key that carries the JSON payload in every WatchConnectivity message, user info and context.
public let watchPayloadKey: String = "gistsmith.v1"

/// The metadata key of a recording's file transfer that carries the transfer's token (a UUID string, JSON-encoded): the
/// Watch matches the transfer's end and the iPhone's "could not keep it" to the transfer it queued last, never to an
/// older one of the same recording.
public let watchTransferTokenKey: String = "gistsmith.transfer"

/// Phase of the iPhone's recording as the Watch shows it.
public enum WatchPhoneRecordingPhase: String, Codable, Sendable, Equatable {
    /// Microphone and server session are opening.
    case starting
    case recording
    /// Paused by the user, or by an interruption (call, alarm) on the iPhone.
    case paused
    /// Microphone closed; the last sections are being finished.
    case finishing
}

/// The iPhone's running recording.
public struct WatchPhoneRecording: Codable, Sendable, Equatable {
    /// `RecordingID.rawValue`: commands from the Watch name this recording, so a stale button never touches a newer one.
    public let recordingID: String
    public let phase: WatchPhoneRecordingPhase
    /// Meeting title (calendar event) or empty when the recording has no title yet.
    public let title: String
    /// Wall-clock start of the timer (recording start pushed forward by completed pauses); nil while starting.
    public let timerStart: Date?
    /// Where the timer stopped (pause or "End"); nil while it runs.
    public let timerStoppedAt: Date?

    public init(recordingID: String, phase: WatchPhoneRecordingPhase, title: String, timerStart: Date?, timerStoppedAt: Date?) {
        self.recordingID = recordingID
        self.phase = phase
        self.title = title
        self.timerStart = timerStart
        self.timerStoppedAt = timerStoppedAt
    }
}

/// An upcoming calendar meeting (from the iPhone's calendar, only when the user turned the calendar on there).
public struct WatchMeeting: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(id: String, title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }
}

/// One of the user's open tasks.
public struct WatchTask: Codable, Sendable, Equatable, Identifiable {
    public let meetingID: String
    /// `taskKey(task:)` of the stored task: mark-done names the task by it.
    public let taskKey: String
    public let text: String
    /// The meeting the task came from.
    public let meetingTitle: String
    /// Due date as written in the note ("Friday", "2026-11-14"); nil when none.
    public let due: String?

    public init(meetingID: String, taskKey: String, text: String, meetingTitle: String, due: String?) {
        self.meetingID = meetingID
        self.taskKey = taskKey
        self.text = text
        self.meetingTitle = meetingTitle
        self.due = due
    }

    public var id: String { meetingID + "|" + taskKey }
}

/// What the iPhone tells the Watch (latest state wins: `updateApplicationContext`).
public struct WatchSnapshot: Codable, Sendable, Equatable {
    /// Signed in on the iPhone (the Watch records and asks only for a signed-in account).
    public let signedIn: Bool
    /// Opaque tag of the signed-in account (`watchAccountTag`); the Watch stamps its recordings with it and the iPhone
    /// imports a recording only into the account it was made for. Nil when signed out.
    public let accountTag: String?
    public let recording: WatchPhoneRecording?
    /// Today's meetings that have not ended, soonest first.
    public let meetings: [WatchMeeting]
    /// The calendar is turned on on the iPhone (an empty `meetings` then means "nothing today").
    public let calendarOn: Bool
    /// Open tasks, most urgent first.
    public let tasks: [WatchTask]
    /// Longest meeting the account may record (minutes); a Watch recording stops itself there. Nil when unknown.
    public let maxMeetingMinutes: Int?
    /// Gistsmith is open on the iPhone: only then can the iPhone open its microphone for a new recording.
    public let phoneAppOpen: Bool
    /// Where the Watch recordings the iPhone knows about are, by recording ID (`watchImportReports`): the Watch deletes
    /// its copy only when the iPhone holds the recording, never on the transfer's end alone.
    public let imports: [WatchImportReport]
    /// Recording with the Watch's microphone is switched on for this account (the server's `watchRecording`). Off: the
    /// Watch offers only the iPhone's recording; recordings already made are still sent and imported. Nil while the
    /// iPhone has not read the account yet (`watchMergedSnapshot` keeps the Watch's last known value).
    public let watchRecordingEnabled: Bool?

    public init(
        signedIn: Bool, accountTag: String?, recording: WatchPhoneRecording?, meetings: [WatchMeeting], calendarOn: Bool, tasks: [WatchTask],
        maxMeetingMinutes: Int?, phoneAppOpen: Bool, imports: [WatchImportReport], watchRecordingEnabled: Bool?
    ) {
        self.signedIn = signedIn
        self.accountTag = accountTag
        self.recording = recording
        self.meetings = meetings
        self.calendarOn = calendarOn
        self.tasks = tasks
        self.maxMeetingMinutes = maxMeetingMinutes
        self.phoneAppOpen = phoneAppOpen
        self.imports = imports
        self.watchRecordingEnabled = watchRecordingEnabled
    }

    /// Before the iPhone has ever answered, and after sign-out: nothing of the account stays on the Watch.
    public static let signedOut: WatchSnapshot = WatchSnapshot(
        signedIn: false, accountTag: nil, recording: nil, meetings: [], calendarOn: false, tasks: [], maxMeetingMinutes: nil, phoneAppOpen: false,
        imports: [], watchRecordingEnabled: false
    )
}

/// Where one Watch recording is on the iPhone, as the snapshot tells the Watch.
public enum WatchImportStatus: Codable, Sendable, Equatable {
    /// The iPhone holds the audio (in its inbox, waiting for its account, importing) or has imported it: the Watch copy
    /// can go.
    case held
    /// Held, but the import failed: the Watch offers "Try again" and "Delete". `reason` is in the user's language.
    case failed(title: String, reason: String)
    /// The transfer `transferToken` reached the iPhone but could not be kept there (no space): the Watch keeps its copy
    /// and shows `reason` next to "Send again".
    case notReceived(transferToken: String, reason: String)
}

/// One Watch recording's status on the iPhone, named by its recording ID.
public struct WatchImportReport: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let status: WatchImportStatus

    public init(id: String, status: WatchImportStatus) {
        self.id = id
        self.status = status
    }
}

/// A Watch recording the iPhone holds but could not import (too long for the plan, unreadable audio), as the Watch and
/// the iPhone list it (`watchFailedImports`).
public struct WatchFailedImport: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Why, in the user's language.
    public let reason: String

    public init(id: String, title: String, reason: String) {
        self.id = id
        self.title = title
        self.reason = reason
    }
}

/// A request from the Watch.
public enum WatchRequest: Codable, Sendable, Equatable {
    /// Start recording on the iPhone (only granted while Gistsmith is open there: iOS does not let a background app
    /// open the microphone).
    case startPhoneRecording
    case pausePhoneRecording(recordingID: String)
    case resumePhoneRecording(recordingID: String)
    case stopPhoneRecording(recordingID: String)
    /// Mark a task done (sent as queued user info: delivered when the iPhone is reachable). Never un-marks.
    case completeTask(meetingID: String, taskKey: String)
    /// Try a failed import again (`WatchSnapshot.failedImports`).
    case retryImport(recordingID: String)
    /// Delete a failed import's audio from the iPhone.
    case deleteImport(recordingID: String)
    /// Send the snapshot again (the Watch app opened).
    case refresh
}

/// The iPhone's answer to a `WatchRequest` sent as a message.
public enum WatchReply: Codable, Sendable, Equatable {
    case done
    /// Gistsmith is not open on the iPhone, so the iPhone cannot open its microphone.
    case phoneAppNotOpen
    /// Not signed in on the iPhone.
    case signedOut
    /// The recording the command named is no longer the running one.
    case recordingChanged
    /// The request failed; `reason` is shown as is (already in the user's language).
    case failed(reason: String)
}

/// Metadata of a Watch recording sent to the iPhone with the audio file (`transferFile`).
public struct WatchRecordingInfo: Codable, Sendable, Equatable, Identifiable {
    /// Unique per recording (UUID); the iPhone imports one recording once.
    public let id: String
    /// Meeting title chosen on the Watch; empty for a new note.
    public let title: String
    public let startedAt: Date
    public let durationSec: Double
    /// `WatchSnapshot.accountTag` at the start: the account the recording belongs to.
    public let accountTag: String
    /// A call, Siri or low battery ended the recording before "End": the note covers only the recorded part.
    public let interrupted: Bool

    public init(id: String, title: String, startedAt: Date, durationSec: Double, accountTag: String, interrupted: Bool) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSec = durationSec
        self.accountTag = accountTag
        self.interrupted = interrupted
    }
}

/// Errors decoding a WatchConnectivity payload.
public enum WatchLinkError: Error, Equatable {
    /// The dictionary has no `watchPayloadKey` data (another app version or a corrupt transfer).
    case missingPayload
}

/// Encodes a value as the one-key dictionary sent over WatchConnectivity. Pure function.
public func watchPayload<Value: Encodable>(value: Value) throws -> [String: Data] {
    [watchPayloadKey: try watchEncoder().encode(value)]
}

/// Decodes the value from a payload's data (`dictionary[watchPayloadKey] as? Data`, narrowed by the adapter). Pure function.
public func watchValue<Value: Decodable>(type: Value.Type, data: Data?) throws -> Value {
    guard let data else {
        throw WatchLinkError.missingPayload
    }
    return try watchDecoder().decode(type, from: data)
}

private func watchEncoder() -> JSONEncoder {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = .sortedKeys
    return encoder
}

private func watchDecoder() -> JSONDecoder {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
}
