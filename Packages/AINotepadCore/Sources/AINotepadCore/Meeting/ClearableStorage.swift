import AINotepadWatchLink
import AVFoundation
import Foundation
import os

private let clearableLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ClearableStorage")

/// A failed local recording the iPhone's "Clear storage" quick action may delete.
public struct ClearableRecording: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A failed meeting with nothing written whose audio was deleted or cannot be read (`clearableFailedMeetings`).
        case meeting
        /// An Apple Watch recording the iPhone could not import and whose inbox audio cannot be read (the only copy on the
        /// iPhone).
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

/// Meetings "Clear storage" might delete, before their audio is looked at: processing failed or was interrupted and the
/// meeting holds nothing written (no note, no transcript text, no own notes, no highlights). Excluded: the sample
/// meeting and locked meetings (recording, processing, note being written: `locked`). Pure function.
public func clearableCandidateMeetings(records: [MeetingRecord], locked: Set<String>) -> [MeetingRecord] {
    records.filter { (record: MeetingRecord) -> Bool in
        let failed: Bool = record.status == .failed || record.status == .interrupted
        let hasWriting: Bool = record.note != nil
            || !(record.myNotes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (record.liveSegments + record.finalSegments).contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !(record.highlights ?? []).isEmpty
        return failed && !hasWriting && !record.isSampleMeeting && !locked.contains(record.id)
    }
}

/// The candidates "Clear storage" offers: only those that can never give a note, because their audio was deleted
/// (`audioDeleted`, which sync carries) or this device's recordings cannot be read (`unreadableAudioIDs`: folders that
/// `meetingAudioOnDisk` finds `.unreadable`; a folder without recordings is not one, the meeting may have been recorded
/// on another device). The failure's kind does not count: a meeting that failed on an expired subscription, a used-up
/// allowance or missing AI consent still has readable audio, so it stays out and "Process again" works once that is
/// fixed. Pure function.
public func clearableFailedMeetings(candidates: [MeetingRecord], unreadableAudioIDs: Set<String>) -> [MeetingRecord] {
    candidates.filter { (record: MeetingRecord) -> Bool in
        record.audioDeleted || unreadableAudioIDs.contains(record.id)
    }
}

/// What a meeting's folder holds for processing.
public enum MeetingAudioOnDisk: Sendable, Equatable {
    /// A processing checkpoint (the final pass's result), or a recording that opens with audio in it.
    case readable
    /// Recordings are here but none opens or holds audio, and there is no checkpoint: this device's recording can never
    /// give a note.
    case unreadable
    /// No recording and no checkpoint. Says nothing about the meeting: one recorded on another device (sync carries no
    /// audio) may be processable there.
    case absent
}

/// Reads a meeting's folder: a processing checkpoint, and the recordings ("me"/"others", `.m4a` or `.caf`) opened for
/// reading the same way processing opens them (`convertToM4A`). Reads the disk; an unreadable recording is logged.
public func meetingAudioOnDisk(directory: URL) -> MeetingAudioOnDisk {
    let manager: FileManager = FileManager.default
    if manager.fileExists(atPath: directory.appending(path: processingCheckpointFileName).path) {
        return .readable
    }
    let recordings: [URL] = ["me", "others"]
        .flatMap { (name: String) -> [URL] in ["m4a", "caf"].map { (ext: String) -> URL in directory.appending(path: "\(name).\(ext)") } }
        .filter { (url: URL) -> Bool in manager.fileExists(atPath: url.path) }
    guard !recordings.isEmpty else {
        return .absent
    }
    return recordings.contains(where: recordingHoldsAudio) ? .readable : .unreadable
}

/// Whether a recording opens for reading (the way processing opens it) and holds audio. Reads the disk; an unreadable
/// recording is logged.
public func recordingHoldsAudio(url: URL) -> Bool {
    do {
        let file: AVAudioFile = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        return file.length > 0
    } catch {
        clearableLogger.warning("Recording cannot be read, file: \(url.lastPathComponent, privacy: .public), error: \(String(describing: error), privacy: .public)")
        return false
    }
}

/// Everything "Clear storage" offers, meetings first (newest first), then failed Watch imports. The caller passes only
/// Watch imports whose audio cannot be read: one that failed for the allowance, the network or a full disk still has
/// good audio and imports with "Try again". Pure function.
public func clearableRecordings(meetings: [MeetingRecord], failedWatchImports: [WatchFailedImport]) -> [ClearableRecording] {
    let meetingItems: [ClearableRecording] = meetings
        .sorted { (left: MeetingRecord, right: MeetingRecord) -> Bool in left.startedAt > right.startedAt }
        .map { (record: MeetingRecord) -> ClearableRecording in ClearableRecording(id: record.id, kind: .meeting, title: record.title) }
    let watchItems: [ClearableRecording] = failedWatchImports.map { (failed: WatchFailedImport) -> ClearableRecording in
        ClearableRecording(id: failed.id, kind: .watchRecording, title: failed.title)
    }
    return meetingItems + watchItems
}
