import Foundation

// Shared-folder payloads and the pure decisions of publishing, membership and rotation (design:
// docs/superpowers/specs/2026-11-08-shared-folders.md). The cryptography is in `SharedFolderCrypto.swift`, the HTTP
// adapter in `HostedSharedFolderClient.swift` and the steps that tie them together in `SharedFolderService.swift`.

/// Limits mirrored from the server (`server/src/sharedFolders.ts`; `ServerParityTests`).
public enum SharedFolderLimits {
    public static let maxOwnedFolders: Int = 20
    public static let maxMemberships: Int = 100
    public static let maxMembers: Int = 50
    public static let maxOpenInvites: Int = 20
    public static let maxItems: Int = 1000
    public static let inviteTTLDays: Int = 7
}

/// Folder metadata, sealed under the newest epoch (the server never sees the name).
public struct SharedFolderMeta: Sendable, Equatable, Codable {
    public let v: Int
    /// The owner's local folder name; the publisher matches its folder by it.
    public let name: String
    public let ownerName: String
    /// Transcripts are shared too (off by default).
    public let includeTranscript: Bool

    public init(name: String, ownerName: String, includeTranscript: Bool) {
        v = 1
        self.name = name
        self.ownerName = ownerName
        self.includeTranscript = includeTranscript
    }
}

/// One shared note: the same payload as a share link (`SharedNotePayload`), plus the meeting's start for sorting.
public struct SharedFolderItemPayload: Sendable, Equatable, Codable {
    public let v: Int
    /// Milliseconds since 1970.
    public let startedAtMs: Int64
    public let note: SharedNotePayload

    public init(startedAt: Date, note: SharedNotePayload) {
        v = 1
        startedAtMs = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
        self.note = note
    }

    public var startedAt: Date { Date(timeIntervalSince1970: Double(startedAtMs) / 1000) }
}

/// Canonical JSON (sorted keys): the same note always gives the same bytes and content tag. Pure function.
func canonicalJSON<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

/// The payload of a meeting for a shared folder: the original note (never a translation), the transcript only when
/// the folder includes transcripts; nil without a note and for the sample meeting. Pure function.
public func sharedFolderItemPayload(record: MeetingRecord, includeTranscript: Bool) -> SharedFolderItemPayload? {
    guard let note = record.note, !record.isSampleMeeting else {
        return nil
    }
    let transcript: [TranscriptParagraph]? = includeTranscript ? transcriptParagraphs(record: record) : nil
    return SharedFolderItemPayload(startedAt: record.startedAt, note: sharedNotePayload(record: record, note: note, language: nil, transcript: transcript))
}

// MARK: - Publishing

/// A note the publisher would share: its item id and content tag.
public struct SharedFolderLocalItem: Sendable, Equatable {
    public let itemID: String
    public let tag: String

    public init(itemID: String, tag: String) {
        self.itemID = itemID
        self.tag = tag
    }
}

/// An item the server has.
public struct SharedFolderRemoteItem: Sendable, Equatable, Decodable {
    public let itemId: String
    public let keyEpoch: Int
    public let tag: String
    public let size: Int
    public let rev: Int
}

/// What a publishing pass does.
public struct SharedFolderPublishPlan: Sendable, Equatable {
    public let uploads: [String]
    public let deletes: [String]
}

/// Upload the local notes whose tag differs from the server's (or that the server lacks); delete only items this
/// device published (`ledger`) whose note is no longer in the folder. Items another device published stay. Pure.
public func sharedFolderPublishPlan(local: [SharedFolderLocalItem], remote: [SharedFolderRemoteItem], ledger: Set<String>) -> SharedFolderPublishPlan {
    let remoteTags: [String: String] = Dictionary(remote.map { ($0.itemId, $0.tag) }, uniquingKeysWith: { (first: String, _: String) -> String in first })
    let localIDs: Set<String> = Set(local.map(\.itemID))
    return SharedFolderPublishPlan(
        uploads: local.filter { remoteTags[$0.itemID] != $0.tag }.map(\.itemID),
        deletes: remote.map(\.itemId).filter { ledger.contains($0) && !localIDs.contains($0) }.sorted()
    )
}

// MARK: - Membership and rotation

/// A verified acceptance: the invite's proof matched the keys and user id the server reported.
public struct SharedFolderAcceptance: Sendable, Equatable {
    public let member: SharedFolderRosterMember

    public init(member: SharedFolderRosterMember) {
        self.member = member
    }
}

/// The roster change an owner device must make.
public enum SharedFolderRosterAction: Sendable, Equatable {
    case none
    /// Add verified acceptances at the current epoch.
    case activate(members: [SharedFolderRosterMember], added: [String])
    /// A new epoch for `members` (someone left, was removed or the server asked for a rotation).
    case rotate(members: [SharedFolderRosterMember])
}

/// Decides the next roster change. Members of the signed roster the server no longer has as active (they left or were
/// deleted), members being removed and `needsRotation` force a rotation; verified acceptances join in the same change.
/// Pure function.
public func sharedFolderRosterAction(
    roster: SharedFolderRoster, serverActiveIDs: Set<String>, needsRotation: Bool, removing: Set<String>, acceptances: [SharedFolderAcceptance]
) -> SharedFolderRosterAction {
    let gone: Set<String> = Set(roster.members.map(\.memberId)).subtracting(serverActiveIDs)
    let kept: [SharedFolderRosterMember] = roster.members.filter { !gone.contains($0.memberId) && !removing.contains($0.memberId) }
    let rosterIDs: Set<String> = Set(roster.members.map(\.memberId))
    let added: [SharedFolderRosterMember] = acceptances.map(\.member).filter { !rosterIDs.contains($0.memberId) && !removing.contains($0.memberId) }
    if needsRotation || !gone.isEmpty || !removing.intersection(rosterIDs).isEmpty {
        return .rotate(members: kept + added)
    }
    if !added.isEmpty {
        return .activate(members: roster.members + added, added: added.map(\.memberId))
    }
    return .none
}

// MARK: - Version pins

/// The highest key epoch and roster version this device has seen for a folder (rollback protection).
public struct SharedFolderVersionPin: Sendable, Equatable, Codable {
    public let epoch: Int
    public let rosterVersion: Int

    public init(epoch: Int, rosterVersion: Int) {
        self.epoch = epoch
        self.rosterVersion = rosterVersion
    }
}

/// The pin after seeing `epoch` and `rosterVersion`; older than the stored pin is `staleVersion`. Pure function.
public func advancedSharedFolderPin(stored: SharedFolderVersionPin?, epoch: Int, rosterVersion: Int) throws -> SharedFolderVersionPin {
    if let stored {
        guard epoch >= stored.epoch else {
            throw SharedFolderCryptoError.staleVersion(seen: stored.epoch, served: epoch)
        }
        guard rosterVersion >= stored.rosterVersion else {
            throw SharedFolderCryptoError.staleVersion(seen: stored.rosterVersion, served: rosterVersion)
        }
    }
    return SharedFolderVersionPin(epoch: epoch, rosterVersion: rosterVersion)
}

/// Folder caches to keep after a successful list: only folders still listed. An unavailable list (`available: false`,
/// the server switch is off) keeps everything. Pure function.
public func sharedFolderCachesToKeep(cached: Set<String>, listed: Set<String>, available: Bool) -> Set<String> {
    available ? cached.intersection(listed) : cached
}
