import Foundation

// The iPhone's side of a Watch recording's import, as one explicit state machine per recording: the adapter
// (`PhoneWatchLink`) persists the records, feeds every event through `watchImportNext` and derives what the Watch is
// told (`watchImportReports`) from them, so no Bool or side dictionary can disagree with the stage.

/// Where one Watch recording is on the iPhone.
public enum WatchImportStage: Codable, Sendable, Equatable {
    /// In the inbox, not tried yet (also after "Try again").
    case received
    /// In the inbox for an account that is not loaded (signed out, or another account): imported once it is.
    case waitingForAccount
    /// Being imported now.
    case importing
    /// The import failed; the audio stays in the inbox until "Try again" or "Delete" (on the Watch or the iPhone).
    /// `reason` is in the user's language.
    case failed(reason: String)
    /// Imported: the meeting is saved (the ledger has it) and the inbox entry goes.
    case imported
    /// Deleted by the user after a failed import: the inbox entry goes.
    case deleted
    /// The transfer `transferToken` arrived but could not be kept in the inbox (no space); the Watch keeps its copy.
    case notStored(transferToken: String, reason: String)
}

/// What happened to a Watch recording on the iPhone.
public enum WatchImportEvent: Sendable, Equatable {
    /// Its transfer was stored in the inbox (also a repeated transfer).
    case stored
    /// Its transfer `transferToken` arrived but could not be stored.
    case storeFailed(transferToken: String, reason: String)
    /// An inbox pass looked at it (`watchImportDecision` for the loaded account).
    case checked(WatchImportDecision)
    /// The meeting was saved.
    case importSucceeded
    /// The import failed for `reason`.
    case importFailed(reason: String)
    /// The account was signed out during the import: it waits for its account.
    case importNeedsSignIn
    /// "Try again".
    case retryRequested
    /// "Delete".
    case deleteRequested
}

/// The stage after `event`. Only an inbox pass starts an import, and only from received or waiting; a failure stays
/// until "Try again" or "Delete" (never retried in a loop); only a failed import can be deleted. Pure function.
public func watchImportNext(stage: WatchImportStage, event: WatchImportEvent) -> WatchImportStage {
    switch (stage, event) {
    case (.imported, _):
        return .imported
    case (.received, .stored), (.waitingForAccount, .stored), (.notStored, .stored), (.deleted, .stored):
        return .received
    case (.received, .storeFailed(let token, let reason)), (.waitingForAccount, .storeFailed(let token, let reason)),
         (.notStored, .storeFailed(let token, let reason)), (.deleted, .storeFailed(let token, let reason)):
        return .notStored(transferToken: token, reason: reason)
    // An inbox pass only checks entries that are in the inbox: a recording marked not stored whose earlier copy is still
    // there is imported (or waits) like any other, never stranded.
    case (.received, .checked(.importNow)), (.waitingForAccount, .checked(.importNow)), (.notStored, .checked(.importNow)):
        return .importing
    case (.received, .checked(.wait)), (.waitingForAccount, .checked(.wait)), (.notStored, .checked(.wait)):
        return .waitingForAccount
    case (.received, .checked(.duplicate)), (.waitingForAccount, .checked(.duplicate)), (.failed, .checked(.duplicate)), (.notStored, .checked(.duplicate)):
        return .imported
    case (.importing, .importSucceeded):
        return .imported
    case (.importing, .importFailed(let reason)):
        return .failed(reason: reason)
    case (.importing, .importNeedsSignIn):
        return .waitingForAccount
    case (.failed, .retryRequested):
        return .received
    case (.failed, .deleteRequested):
        return .deleted
    case (.received, _), (.waitingForAccount, _), (.importing, _), (.failed, _), (.deleted, _), (.notStored, _):
        return stage
    }
}

/// One recording's stage as the iPhone stores it (oldest first).
public struct WatchImportRecord: Codable, Sendable, Equatable {
    public let id: String
    public let stage: WatchImportStage

    public init(id: String, stage: WatchImportStage) {
        self.id = id
        self.stage = stage
    }
}

/// Recordings the iPhone could not keep that it still reports to the Watch: older ones are dropped (the Watch's own
/// "Send again" still works for them).
public let watchNotStoredLimit: Int = 20

/// A recording's stage: `.received` when nothing is stored for it (a new inbox entry). Pure function.
public func watchImportStage(records: [WatchImportRecord], id: String) -> WatchImportStage {
    records.last { $0.id == id }?.stage ?? .received
}

/// The records after `event` for recording `id`. A record that reaches `.imported` or `.deleted` is dropped (the ledger
/// keeps imported IDs); the changed record moves to the end. Pure function.
public func watchImportRecords(records: [WatchImportRecord], id: String, event: WatchImportEvent) -> [WatchImportRecord] {
    let next: WatchImportStage = watchImportNext(stage: watchImportStage(records: records, id: id), event: event)
    let others: [WatchImportRecord] = records.filter { $0.id != id }
    switch next {
    case .imported, .deleted:
        return others
    case .received, .waitingForAccount, .importing, .failed, .notStored:
        return others + [WatchImportRecord(id: id, stage: next)]
    }
}

/// The records at launch: an import cut off by the app being stopped starts again (`.importing` → `.received`; the
/// ledger skips one that was already saved). Pure function.
public func watchImportRecordsAtLaunch(records: [WatchImportRecord]) -> [WatchImportRecord] {
    records.map { (record: WatchImportRecord) -> WatchImportRecord in
        record.stage == .importing ? WatchImportRecord(id: record.id, stage: .received) : record
    }
}

/// The records worth keeping for the current inbox: every stage of a recording still in the inbox, and the last
/// `notStoredLimit` transfers that could not be stored (those have no inbox entry). Stages of recordings that left the
/// inbox are dropped, so nothing leaks. Pure function.
public func watchImportRecordsPruned(records: [WatchImportRecord], inboxIDs: Set<String>, notStoredLimit: Int) -> [WatchImportRecord] {
    let notStored: [String] = records.compactMap { (record: WatchImportRecord) -> String? in
        guard !inboxIDs.contains(record.id), case .notStored = record.stage else {
            return nil
        }
        return record.id
    }
    let keptNotStored: Set<String> = Set(notStored.suffix(notStoredLimit))
    return records.filter { inboxIDs.contains($0.id) || keptNotStored.contains($0.id) }
}

/// What the Watch is told about its recordings, by recording ID: inbox entries are held (failed ones of the loaded
/// account `accountTag` with their title and reason), the last imported ones (`importedIDs`) are held, and transfers that
/// could not be stored carry their token and reason. Pure function.
public func watchImportReports(
    inbox: [WatchRecordingInfo], records: [WatchImportRecord], importedIDs: [String], accountTag: String
) -> [WatchImportReport] {
    let inboxIDs: Set<String> = Set(inbox.map(\.id))
    let inboxReports: [WatchImportReport] = inbox.map { (info: WatchRecordingInfo) -> WatchImportReport in
        if info.accountTag == accountTag, case .failed(let reason) = watchImportStage(records: records, id: info.id) {
            return WatchImportReport(id: info.id, status: .failed(title: info.title, reason: reason))
        }
        return WatchImportReport(id: info.id, status: .held)
    }
    let importedReports: [WatchImportReport] = importedIDs.filter { !inboxIDs.contains($0) }.map { WatchImportReport(id: $0, status: .held) }
    let notStoredReports: [WatchImportReport] = records.compactMap { (record: WatchImportRecord) -> WatchImportReport? in
        guard !inboxIDs.contains(record.id), case .notStored(let token, let reason) = record.stage else {
            return nil
        }
        return WatchImportReport(id: record.id, status: .notReceived(transferToken: token, reason: reason))
    }
    return inboxReports + importedReports + notStoredReports
}

/// The reply to "Start on iPhone", decided before the start runs: done when a recording is already running or starting
/// (`recorderIdle` false; the request changes nothing), the reason when the iPhone refuses to start (`refusal`: trial
/// ended, consent missing, plan, no space), else done (the start begins; it does not wait for the microphone and the
/// server, which can outlast WatchConnectivity's reply timeout, and a later failure shows on the iPhone while the
/// snapshot keeps no recording). The Watch never hears "done" for a start the iPhone refused. Pure function.
public func watchStartReply(recorderIdle: Bool, refusal: String?) -> WatchReply {
    guard recorderIdle, let refusal else {
        return .done
    }
    return .failed(reason: refusal)
}
