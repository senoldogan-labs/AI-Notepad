import Foundation

/// The file, in the user's (account's) data folder, that lists the note sends whose sent mark is not yet on disk.
public let pendingDeliveryReceiptsFileName: String = "PendingDeliveryReceipts.json"

/// A note send that may have reached its destination while its sent mark is not yet in `meeting.json`. It is written
/// before the note leaves (`deliverNote`) and removed when the send failed or its mark is durably on disk. An entry left
/// by an earlier launch therefore means the process ended between the delivery and the mark: the note may have arrived,
/// so it must not be sent again automatically, and the user is told (`reconcilingPendingDeliveryReceipts`).
public struct PendingDeliveryReceipt: Codable, Sendable, Equatable {
    public let meetingID: String
    public let destinationID: String
    /// The keys the sent mark writes: the destination's ID and its device-independent send key.
    public let markKeys: [String]
    /// The destination's name and the meeting's title when the send started, for the notice after a restart (the
    /// destination may have been removed since).
    public let destinationName: String
    public let meetingTitle: String
    /// The app launch that started the send: only entries of an earlier launch are reconciled.
    public let launchID: UUID
    public let startedAt: Date

    public init(
        meetingID: String, destinationID: String, markKeys: [String], destinationName: String, meetingTitle: String, launchID: UUID, startedAt: Date
    ) {
        self.meetingID = meetingID
        self.destinationID = destinationID
        self.markKeys = markKeys
        self.destinationName = destinationName
        self.meetingTitle = meetingTitle
        self.launchID = launchID
        self.startedAt = startedAt
    }
}

/// The on-disk shape of the receipts file.
private struct PendingDeliveryReceiptsFile: Codable {
    let version: Int
    let receipts: [PendingDeliveryReceipt]
}

private let pendingDeliveryReceiptsVersion: Int = 1

/// What the meeting's file says about a receipt's sent mark.
public enum PendingReceiptRecordState: Sendable, Equatable {
    /// `meeting.json` was read; these are its sent destination keys.
    case found(sentKeys: Set<String>)
    /// The meeting has no `meeting.json` any more (deleted): there is nothing left to send.
    case missing
    /// The file exists but could not be read: nothing is decided until it can be.
    case unreadable
}

/// The receipts after a launch reconciliation: `remaining` stay in the file, `uncertain` became uncertain sends that the
/// user is shown and that the automatic send skips.
public struct PendingReceiptReconciliation: Sendable, Equatable {
    public let remaining: [PendingDeliveryReceipt]
    public let uncertain: [PendingDeliveryReceipt]
}

/// The receipts with `receipt` added; an earlier entry of the same meeting and destination is replaced. Pure function.
public func addingPendingDeliveryReceipt(receipts: [PendingDeliveryReceipt], receipt: PendingDeliveryReceipt) -> [PendingDeliveryReceipt] {
    removingPendingDeliveryReceipt(receipts: receipts, meetingID: receipt.meetingID, destinationID: receipt.destinationID) + [receipt]
}

/// The receipts without the entry of this meeting and destination (the send failed, or its mark is on disk). Pure
/// function.
public func removingPendingDeliveryReceipt(receipts: [PendingDeliveryReceipt], meetingID: String, destinationID: String) -> [PendingDeliveryReceipt] {
    receipts.filter { (receipt: PendingDeliveryReceipt) -> Bool in !(receipt.meetingID == meetingID && receipt.destinationID == destinationID) }
}

/// The receipts left after a confirmed save of `meetingID` wrote `persisted` (P01a's commit acknowledgement): the
/// entries whose destination is among the persisted sent marks are removed. Pure function.
public func removingPersistedDeliveryReceipts(receipts: [PendingDeliveryReceipt], meetingID: String, persisted: PendingMeetingMarks) -> [PendingDeliveryReceipt] {
    let written: Set<String> = persisted.sentDestinationKeys
    return receipts.filter { (receipt: PendingDeliveryReceipt) -> Bool in !(receipt.meetingID == meetingID && written.contains(receipt.destinationID)) }
}

/// The `meeting|destination` keys of the receipts: the automatic send skips them while they are pending. Pure function.
public func pendingDeliveryReceiptKeys(receipts: [PendingDeliveryReceipt]) -> Set<String> {
    Set(receipts.map { (receipt: PendingDeliveryReceipt) -> String in
        meetingDestinationKey(meetingID: receipt.meetingID, destinationID: receipt.destinationID)
    })
}

/// Reconciles the receipts an earlier launch left behind. An entry of `currentLaunch` belongs to a send of this process
/// and stays. For an earlier one: a sent mark on disk (any of its keys) or a deleted meeting clears it; a meeting without
/// the mark makes it uncertain (the note may have arrived; it is shown, never resent automatically, never dropped
/// silently); an unreadable or unlisted meeting keeps it for the next reconciliation. Pure function.
public func reconcilingPendingDeliveryReceipts(
    receipts: [PendingDeliveryReceipt], currentLaunch: UUID, records: [String: PendingReceiptRecordState]
) -> PendingReceiptReconciliation {
    var remaining: [PendingDeliveryReceipt] = []
    var uncertain: [PendingDeliveryReceipt] = []
    for receipt in receipts {
        guard receipt.launchID != currentLaunch else {
            remaining.append(receipt)
            continue
        }
        switch records[receipt.meetingID] {
        case .found(let sentKeys):
            if sentKeys.isDisjoint(with: receipt.markKeys) {
                uncertain.append(receipt)
            }
        case .missing:
            break
        case .unreadable, nil:
            remaining.append(receipt)
        }
    }
    return PendingReceiptReconciliation(remaining: remaining, uncertain: uncertain)
}

/// The notice for a send that an earlier launch left without a sent mark. Pure function.
public func interruptedDeliveryMessage(receipt: PendingDeliveryReceipt) -> String {
    String(localized: "\(receipt.destinationName): “\(receipt.meetingTitle)” notu gönderilirken uygulama kapandı, not gitmiş olabilir. Kendiliğinden yeniden gönderilmeyecek; hedefi kontrol et, gerekirse notu toplantı sayfasından yeniden gönder.")
}

/// The receipts file in a data folder (`AppPaths.userDataDirectory()`). Pure function.
public func pendingDeliveryReceiptsFile(userDataDirectory: URL) -> URL {
    userDataDirectory.appending(path: pendingDeliveryReceiptsFileName, directoryHint: .notDirectory)
}

/// Reads the receipts; a missing file means none. A file that cannot be read or decoded throws `StorageError.readFailed`.
public func loadPendingDeliveryReceipts(file: URL) throws -> [PendingDeliveryReceipt] {
    guard FileManager.default.fileExists(atPath: file.path) else {
        return []
    }
    do {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PendingDeliveryReceiptsFile.self, from: Data(contentsOf: file)).receipts
    } catch {
        throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Writes the receipts atomically (an empty list removes the file). A failed write throws `StorageError.writeFailed`.
public func savePendingDeliveryReceipts(receipts: [PendingDeliveryReceipt], file: URL) throws {
    do {
        guard !receipts.isEmpty else {
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(PendingDeliveryReceiptsFile(version: pendingDeliveryReceiptsVersion, receipts: receipts)).write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// What the meeting folder's `meeting.json` says about sent marks: `missing` when the file is gone. A file that exists
/// but cannot be read throws its `StorageError`; the caller logs it and reconciles the receipt as `unreadable`.
public func pendingReceiptRecordState(directory: URL) throws -> PendingReceiptRecordState {
    guard FileManager.default.fileExists(atPath: directory.appending(path: meetingFileName).path) else {
        return .missing
    }
    return .found(sentKeys: Set(try loadMeeting(directory: directory).sentDestinationIDs ?? []))
}
