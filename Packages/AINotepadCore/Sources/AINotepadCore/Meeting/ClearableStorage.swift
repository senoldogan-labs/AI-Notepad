import AINotepadWatchLink
import Foundation

/// A failed local recording the iPhone's "Clear storage" quick action may delete.
public struct ClearableRecording: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A meeting whose processing failed before anything was written (no note, no transcript, no own notes).
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

/// Meetings "Clear storage" may delete: processing failed or was interrupted and the meeting holds nothing written —
/// no note, no transcript text, no own notes, no highlights. Excluded: the sample meeting, locked meetings (recording,
/// processing, note being written: `locked`) and failures the app still retries by itself (transient, attempts left,
/// audio kept). Saved notes and transcripts are never in this list. Pure function.
public func clearableFailedMeetings(records: [MeetingRecord], locked: Set<String>) -> [MeetingRecord] {
    records.filter { (record: MeetingRecord) -> Bool in
        let failed: Bool = record.status == .failed || record.status == .interrupted
        let hasWriting: Bool = record.note != nil
            || !(record.myNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (record.liveSegments + record.finalSegments).contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !(record.highlights ?? []).isEmpty
        let retriesBySelf: Bool = record.status == .failed && record.failureKind == .transient && !record.audioDeleted
            && (record.automaticRetries?.count ?? 0) < automaticRetryLimit
        return failed && !hasWriting && !retriesBySelf && !record.isSampleMeeting && !locked.contains(record.id)
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
