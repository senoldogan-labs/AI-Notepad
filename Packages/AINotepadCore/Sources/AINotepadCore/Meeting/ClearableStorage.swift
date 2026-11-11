import AINotepadWatchLink
import Foundation

/// A failed local recording the iPhone's "Clear storage" quick action may delete.
public struct ClearableRecording: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A meeting whose processing failed for good, or whose audio is gone, with nothing written (`clearableFailedMeetings`).
        case meeting
        /// An Apple Watch recording the iPhone could not import (its inbox audio is the only copy on the iPhone).
        case watchRecording
    }

    public let id: String
    public let kind: Kind
    public let title: String

    public init(id: String, kind: Kind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

/// Meetings "Clear storage" may delete: processing failed for good (a permanent failure: the audio could not be
/// converted, held no speech, or the request was refused), or failed or was interrupted and no audio is left — and the
/// meeting holds nothing written: no note, no transcript text, no own notes, no highlights. Interrupted meetings and
/// transient or unknown failures that still have their audio are left alone: "Process again" can still recover them.
/// Also excluded: the sample meeting and locked meetings (recording, processing, note being written: `locked`). Saved
/// notes and transcripts are never in this list. Pure function.
public func clearableFailedMeetings(records: [MeetingRecord], locked: Set<String>) -> [MeetingRecord] {
    records.filter { (record: MeetingRecord) -> Bool in
        let failed: Bool = record.status == .failed || record.status == .interrupted
        let unrecoverable: Bool = record.audioDeleted || (record.status == .failed && record.failureKind == .permanent)
        let hasWriting: Bool = record.note != nil
            || !(record.myNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (record.liveSegments + record.finalSegments).contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !(record.highlights ?? []).isEmpty
        return failed && unrecoverable && !hasWriting && !record.isSampleMeeting && !locked.contains(record.id)
    }
}

/// Everything "Clear storage" offers, meetings first (newest first), then failed Watch imports. Pure function.
public func clearableRecordings(meetings: [MeetingRecord], failedWatchImports: [WatchFailedImport]) -> [ClearableRecording] {
    let meetingItems: [ClearableRecording] = meetings
        .sorted { (left: MeetingRecord, right: MeetingRecord) -> Bool in left.startedAt > right.startedAt }
        .map { (record: MeetingRecord) -> ClearableRecording in ClearableRecording(id: record.id, kind: .meeting, title: record.title) }
    let watchItems: [ClearableRecording] = failedWatchImports.map { (failed: WatchFailedImport) -> ClearableRecording in
        ClearableRecording(id: failed.id, kind: .watchRecording, title: failed.title)
    }
    return meetingItems + watchItems
}
