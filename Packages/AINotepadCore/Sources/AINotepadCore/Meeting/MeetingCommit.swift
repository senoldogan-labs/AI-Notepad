import Foundation

/// An external action that already happened for a meeting while a job held its lock (processing, note edit or rewrite):
/// the note went to a destination, tasks were created in a tracker, a task was added to Reminders. The mark waits in
/// memory until the job's result is saved, so the job's result does not overwrite it.
public enum PendingMeetingMark: Sendable, Equatable {
    /// The note was sent; `keys` are the destination's ID and its device-independent send key.
    case sent(keys: [String])
    /// These tasks were created in this tracker.
    case tasksSent(tracker: TaskTracker, tasks: [NoteTask])
    /// The task was added to Reminders.
    case reminded(task: NoteTask)
}

/// One pending mark with the identity its acknowledgement uses: a save acknowledges exactly the entries it wrote.
public struct PendingMeetingMarkEntry: Sendable, Equatable {
    public let id: UUID
    public let mark: PendingMeetingMark

    public init(id: UUID, mark: PendingMeetingMark) {
        self.id = id
        self.mark = mark
    }
}

/// A meeting's pending marks in arrival order. Reading them does not consume them: only a confirmed save acknowledges
/// the snapshot it wrote (`acknowledgingPersistedMeetingMarks`), so a failed save keeps them for the next write.
public struct PendingMeetingMarks: Sendable, Equatable {
    public let entries: [PendingMeetingMarkEntry]

    public init(entries: [PendingMeetingMarkEntry]) {
        self.entries = entries
    }

    public static let none: PendingMeetingMarks = PendingMeetingMarks(entries: [])

    public var isEmpty: Bool {
        entries.isEmpty
    }

    /// The marks with one more entry at the end. Pure function.
    public func adding(id: UUID, mark: PendingMeetingMark) -> PendingMeetingMarks {
        PendingMeetingMarks(entries: entries + [PendingMeetingMarkEntry(id: id, mark: mark)])
    }

    /// Every destination key of the pending sent marks (the automatic-send planner skips them).
    public var sentDestinationKeys: Set<String> {
        Set(entries.flatMap { (entry: PendingMeetingMarkEntry) -> [String] in
            if case .sent(let keys) = entry.mark {
                return keys
            }
            return []
        })
    }
}

/// The record with the pending marks applied, in the order the app has always written them: sent marks (sorted), then
/// tracker marks in arrival order, then Reminders marks. Applying marks that are already on the record changes
/// nothing, so a retained snapshot can be applied again after a failed save. Pure function.
public func mergingPendingMeetingMarks(record: MeetingRecord, marks: PendingMeetingMarks) -> MeetingRecord {
    let withSent: MeetingRecord = marks.sentDestinationKeys.sorted().reduce(record) { (result: MeetingRecord, key: String) -> MeetingRecord in
        result.markingSent(destinationID: key)
    }
    let withTasks: MeetingRecord = marks.entries.reduce(withSent) { (result: MeetingRecord, entry: PendingMeetingMarkEntry) -> MeetingRecord in
        guard case .tasksSent(let tracker, let tasks) = entry.mark else {
            return result
        }
        return markingTasksSent(record: result, tracker: tracker, tasks: tasks)
    }
    return marks.entries.reduce(withTasks) { (result: MeetingRecord, entry: PendingMeetingMarkEntry) -> MeetingRecord in
        guard case .reminded(let task) = entry.mark else {
            return result
        }
        return markingReminded(record: result, task: task)
    }
}

/// The destination IDs whose sent mark a persisted snapshot carries: the first key of each sent mark is the destination's
/// own ID (the second, when present, its device-independent send key). A send's "receipt pending" flag for these
/// destinations can be cleared once the snapshot is on disk. Pure function.
public func persistedSentDestinationIDs(marks: PendingMeetingMarks) -> [String] {
    marks.entries.compactMap { (entry: PendingMeetingMarkEntry) -> String? in
        if case .sent(let keys) = entry.mark {
            return keys.first
        }
        return nil
    }
}

/// The pending marks left after a save confirmed `persisted`: only the entries of that snapshot are removed, so marks
/// that arrived after the snapshot was taken stay pending. Pure function.
public func acknowledgingPersistedMeetingMarks(pending: PendingMeetingMarks, persisted: PendingMeetingMarks) -> PendingMeetingMarks {
    let written: Set<UUID> = Set(persisted.entries.map(\.id))
    return PendingMeetingMarks(entries: pending.entries.filter { (entry: PendingMeetingMarkEntry) -> Bool in !written.contains(entry.id) })
}
