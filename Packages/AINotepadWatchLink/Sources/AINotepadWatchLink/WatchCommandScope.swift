import Foundation

// Which account a Watch command belongs to, and the Watch's side of it: done marks that wait for their account's
// iPhone, and replies bound to the request that asked. The account tag is `WatchSnapshot.accountTag` (an irreversible
// hash of the user ID), never a token or an email.

/// What the iPhone does with a Watch command (`watchCommandDecision`).
public enum WatchCommandDecision: Sendable, Equatable {
    case execute
    /// Tagged for another account than the loaded one: refused with `WatchReply.accountChanged` and a fresh snapshot.
    case refuseOtherAccount
    /// Untagged (a Watch build before the tag) and its owner cannot be proved from the payload: refused with a fresh
    /// snapshot, never run under the loaded account.
    case refuseUnscoped
}

/// Decides whether a Watch command runs for the loaded account. A tagged command runs only for its own account. An
/// untagged one runs only when its recording ID proves the owner: pause/resume/stop name the iPhone's running recording
/// (the handler checks that, and that recording belongs to the loaded session), and an import's retry/delete name an
/// inbox recording whose own account tag (`importAccountTag`, nil when the inbox does not hold it) is the loaded one.
/// A task mark or a start says nothing about its account, so untagged it is refused. Read-only `refresh` always runs.
/// Pure function.
public func watchCommandDecision(request: WatchRequest, loadedAccountTag: String, importAccountTag: String?) -> WatchCommandDecision {
    let tag: String?
    let ownerProvedWithoutTag: Bool
    switch request {
    case .refresh:
        return .execute
    case .startPhoneRecording(let accountTag):
        tag = accountTag
        ownerProvedWithoutTag = false
    case .completeTask(_, _, let accountTag):
        tag = accountTag
        ownerProvedWithoutTag = false
    case .pausePhoneRecording(_, let accountTag), .resumePhoneRecording(_, let accountTag), .stopPhoneRecording(_, let accountTag):
        tag = accountTag
        ownerProvedWithoutTag = true
    case .retryImport(_, let accountTag), .deleteImport(_, let accountTag):
        tag = accountTag
        ownerProvedWithoutTag = importAccountTag == loadedAccountTag
    }
    guard let tag else {
        return ownerProvedWithoutTag ? .execute : .refuseUnscoped
    }
    return tag == loadedAccountTag ? .execute : .refuseOtherAccount
}

/// A task marked done on the Watch, waiting until a snapshot of its own account no longer lists the task.
public struct WatchDoneMark: Codable, Sendable, Hashable {
    public let meetingID: String
    public let taskKey: String
    /// `WatchSnapshot.accountTag` of the snapshot the task was marked in.
    public let accountTag: String

    public init(meetingID: String, taskKey: String, accountTag: String) {
        self.meetingID = meetingID
        self.taskKey = taskKey
        self.accountTag = accountTag
    }

    /// `WatchTask.id` of the marked task.
    public var taskID: String { meetingID + "|" + taskKey }

    /// The queued request that carries this mark.
    public var request: WatchRequest { .completeTask(meetingID: meetingID, taskKey: taskKey, accountTag: accountTag) }
}

/// The mark a queued request carries; nil for any other request and for an untagged mark. Pure function.
public func watchDoneMark(request: WatchRequest) -> WatchDoneMark? {
    guard case .completeTask(let meetingID, let taskKey, let accountTag?) = request else {
        return nil
    }
    return WatchDoneMark(meetingID: meetingID, taskKey: taskKey, accountTag: accountTag)
}

/// The outbox with `mark` added once, keeping the newest `limit` marks (marks of an account that never comes back must
/// not grow it forever). Pure function.
public func watchDoneMarksAdding(outbox: [WatchDoneMark], mark: WatchDoneMark, limit: Int) -> [WatchDoneMark] {
    guard !outbox.contains(mark) else {
        return outbox
    }
    return Array((outbox + [mark]).suffix(limit))
}

/// Marks to queue now: those of the account the iPhone shows (another account's iPhone would refuse them) that are not
/// queued already. Sent again after a delivery the iPhone could not act on; marking done twice changes nothing. Pure
/// function.
public func watchDoneMarksToSend(outbox: [WatchDoneMark], snapshotAccountTag: String?, queued: Set<WatchDoneMark>) -> [WatchDoneMark] {
    guard let snapshotAccountTag else {
        return []
    }
    return outbox.filter { $0.accountTag == snapshotAccountTag && !queued.contains($0) }
}

/// The outbox after a snapshot: a snapshot of a mark's own account that no longer lists the task acknowledges it; a
/// snapshot of another account (or signed out) keeps it for when its account is back. Pure function.
public func watchDoneMarksAfterSnapshot(outbox: [WatchDoneMark], snapshot: WatchSnapshot) -> [WatchDoneMark] {
    guard snapshot.signedIn, let accountTag = snapshot.accountTag else {
        return outbox
    }
    let open: Set<String> = Set(snapshot.tasks.map(\.id))
    return outbox.filter { $0.accountTag != accountTag || open.contains($0.taskID) }
}

/// Task IDs hidden on the Watch: the marks made before the outbox (`markedDone`) and the outbox marks of the account
/// shown. Pure function.
public func watchHiddenTaskIDs(markedDone: Set<String>, outbox: [WatchDoneMark], snapshotAccountTag: String?) -> Set<String> {
    markedDone.union(outbox.filter { $0.accountTag == snapshotAccountTag }.map(\.taskID))
}

/// The Watch's command state after a reply or an error for `answeredRequestID`.
public struct WatchSendTransition: Sendable, Equatable {
    /// The request still waiting for its answer; nil when none.
    public let sendingRequestID: UUID?
    /// The answer belongs to the request in flight: its reply or error is shown.
    public let publishes: Bool

    public init(sendingRequestID: UUID?, publishes: Bool) {
        self.sendingRequestID = sendingRequestID
        self.publishes = publishes
    }
}

/// Only the answer of the request in flight ends it and is shown; a late answer of an older request changes nothing.
/// Pure function.
public func watchSendAfterAnswer(sendingRequestID: UUID?, answeredRequestID: UUID) -> WatchSendTransition {
    guard sendingRequestID == answeredRequestID else {
        return WatchSendTransition(sendingRequestID: sendingRequestID, publishes: false)
    }
    return WatchSendTransition(sendingRequestID: nil, publishes: true)
}
