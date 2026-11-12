import Foundation

/// A job's final write of a meeting: the record with the pending marks already merged (`mergingPendingMeetingMarks`),
/// the snapshot of those marks, the meeting's folder, the job attempt and the write ticket claimed when the record was
/// assembled.
public struct MeetingCommitRequest: Sendable {
    public let record: MeetingRecord
    public let marks: PendingMeetingMarks
    public let directory: URL
    public let workID: UUID
    public let ticket: MeetingWriteTicket

    public init(record: MeetingRecord, marks: PendingMeetingMarks, directory: URL, workID: UUID, ticket: MeetingWriteTicket) {
        self.record = record
        self.marks = marks
        self.directory = directory
        self.workID = workID
        self.ticket = ticket
    }
}

/// Proof that `meeting.json` now holds the record of a commit and with it these marks.
public struct MeetingCommitReceipt: Sendable, Equatable {
    public let meetingID: String
    public let workID: UUID
    public let persistedMarks: PendingMeetingMarks
}

/// The outcome of a commit that did not throw.
public enum MeetingCommitOutcome: Sendable, Equatable {
    /// The record is on disk; only now may the caller acknowledge `persistedMarks`, announce the result or delete
    /// recovery evidence.
    case persisted(MeetingCommitReceipt)
    /// A newer write of the same file came first: nothing was written and nothing may be acknowledged.
    case superseded
}

/// Writes the job's final record. Returns `persisted` only after `saveMeeting(record:directory:ticket:)` confirmed the
/// write; a superseded ticket returns `superseded`, and a failed write throws. In both failure cases the caller keeps
/// its pending marks and recovery data. Callable from any thread.
public func commitMeetingWork(request: MeetingCommitRequest) throws -> MeetingCommitOutcome {
    guard try saveMeeting(record: request.record, directory: request.directory, ticket: request.ticket) else {
        return .superseded
    }
    return .persisted(MeetingCommitReceipt(meetingID: request.record.id, workID: request.workID, persistedMarks: request.marks))
}
