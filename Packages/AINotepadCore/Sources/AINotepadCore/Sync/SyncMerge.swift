import Foundation

// Three-way merges for sync conflicts (doc §8.4). `base` is the last version both devices agreed on (the device keeps
// it next to the local copy); `local` is this device's unsynced version, `remote` the server's newer one. A field that
// only one side changed takes that side; a field both changed takes the later change (`fieldClocks`), preferring
// `local` on a tie so the merge is deterministic (the merged result is uploaded and the other device adopts it). With no
// base (lost), sets are united and differing fields go to the later clock.

/// Result of merging two versions of a meeting's state.
public struct MeetingStateMerge: Sendable, Equatable {
    public let state: MeetingSyncState
    /// Both devices edited the same lines of the user's own notes: both versions were kept with `myNotesSeparator`
    /// between them; the app tells the user ("edited on two devices").
    public let myNotesConflicted: Bool
}

/// Which side a three-way pick took.
private enum MergeSide {
    case local
    case remote
}

/// Three-way pick of one value: the side that changed it, or the later clock when both did. Pure function.
private func pickSide<Value: Equatable>(base: Value?, local: Value, remote: Value, localClock: Date, remoteClock: Date, hasBase: Bool) -> MergeSide {
    if local == remote {
        return .local
    }
    if hasBase, let base {
        if local == base {
            return .remote
        }
        if remote == base {
            return .local
        }
    }
    return remoteClock > localClock ? .remote : .local
}

/// Three-way merge of an ordered set: additions of both sides are kept (local order first), an element either side
/// removed since `base` is removed. All nil stays nil. Pure function.
func mergedOrderedSet<Element: Equatable>(base: [Element]?, local: [Element]?, remote: [Element]?) -> [Element]? {
    guard local != nil || remote != nil || base != nil else {
        return nil
    }
    let baseItems: [Element] = base ?? []
    let localItems: [Element] = local ?? []
    let remoteItems: [Element] = remote ?? []
    let removed: [Element] = baseItems.filter { !localItems.contains($0) || !remoteItems.contains($0) }
    return (localItems + remoteItems).reduce(into: [Element]()) { (result: inout [Element], item: Element) -> Void in
        if !result.contains(item), !removed.contains(item) {
            result.append(item)
        }
    }
}

/// Union of ordered sets (for marks that must never be lost, like "sent to Linear"); all nil stays nil. Pure function.
private func unitedOrderedSet(lists: [[String]?]) -> [String]? {
    let present: [[String]] = lists.compactMap { $0 }
    guard !present.isEmpty else {
        return nil
    }
    return present.joined().reduce(into: [String]()) { (result: inout [String], item: String) -> Void in
        if !result.contains(item) {
            result.append(item)
        }
    }
}

/// Task keys of a version, moved onto the merged note's tasks: unchanged notes keep their keys, a rewritten note's
/// marks follow the most similar task (`carriedTaskKeys`). Pure function.
private func keysOnNote(keys: [String]?, from note: MeetingNote?, to merged: MeetingNote?) -> [String]? {
    guard let keys else {
        return nil
    }
    if note?.tasks == merged?.tasks {
        return keys
    }
    return carriedTaskKeys(oldTasks: note?.tasks ?? [], newTasks: merged?.tasks ?? [], keys: keys)
}

/// Note history of both sides (and the losing note of a conflict), newest first, without repeats, at most
/// `noteHistoryLimit`. Pure function.
private func mergedNoteHistory(local: [NoteVersion]?, remote: [NoteVersion]?, loser: NoteVersion?) -> [NoteVersion]? {
    guard local != nil || remote != nil || loser != nil else {
        return nil
    }
    let all: [NoteVersion] = (local ?? []) + (remote ?? []) + (loser.map { [$0] } ?? [])
    let unique: [NoteVersion] = all.reduce(into: [NoteVersion]()) { (result: inout [NoteVersion], version: NoteVersion) -> Void in
        if !result.contains(version) {
            result.append(version)
        }
    }
    return Array(unique.sorted { $0.savedAt > $1.savedAt }.prefix(noteHistoryLimit))
}

/// Three-way merge of the user's own notes by lines (`mergedLines`); returns the text and whether both edited the same
/// lines. Pure function.
public func mergeMyNotes(base: String?, local: String?, remote: String?, separator: String) -> (text: String?, conflicted: Bool) {
    if local == remote {
        return (local, false)
    }
    if let base {
        if local == base {
            return (remote, false)
        }
        if remote == base {
            return (local, false)
        }
    }
    let lines: (String?) -> [String] = { (text: String?) -> [String] in
        text.map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) } ?? []
    }
    let merged: (lines: [String], conflicted: Bool) = mergedLines(base: lines(base), local: lines(local), remote: lines(remote), separator: separator)
    let text: String = merged.lines.joined(separator: "\n")
    return (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text, merged.conflicted)
}

/// Longest common subsequence as index pairs (`a` index → `b` index). Pure function.
private func commonLines(a: [String], b: [String]) -> [Int: Int] {
    let rows: Int = a.count
    let columns: Int = b.count
    var lengths: [[Int]] = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
    for row in stride(from: rows - 1, through: 0, by: -1) {
        for column in stride(from: columns - 1, through: 0, by: -1) {
            lengths[row][column] = a[row] == b[column] ? lengths[row + 1][column + 1] + 1 : max(lengths[row + 1][column], lengths[row][column + 1])
        }
    }
    var pairs: [Int: Int] = [:]
    var row: Int = 0
    var column: Int = 0
    while row < rows, column < columns {
        if a[row] == b[column] {
            pairs[row] = column
            row += 1
            column += 1
        } else if lengths[row + 1][column] >= lengths[row][column + 1] {
            row += 1
        } else {
            column += 1
        }
    }
    return pairs
}

/// Largest line-count product the line merge compares (~16 MB of table); bigger texts keep both versions.
private let maxMergeCells: Int = 4_000_000

/// diff3 over lines: the base lines both sides kept are anchors; between anchors a chunk only one side changed takes
/// that side, identical changes are taken once, different changes keep both (local, `separator`, remote) and mark the
/// result conflicted. Pure function.
func mergedLines(base: [String], local: [String], remote: [String], separator: String) -> (lines: [String], conflicted: Bool) {
    guard base.count * max(local.count, remote.count) <= maxMergeCells else {
        return (local + [separator] + remote, true)
    }
    let toLocal: [Int: Int] = commonLines(a: base, b: local)
    let toRemote: [Int: Int] = commonLines(a: base, b: remote)
    var output: [String] = []
    var conflicted: Bool = false
    var baseIndex: Int = 0
    var localIndex: Int = 0
    var remoteIndex: Int = 0
    let resolve: (ArraySlice<String>, ArraySlice<String>, ArraySlice<String>) -> [String] = {
        (baseChunk: ArraySlice<String>, localChunk: ArraySlice<String>, remoteChunk: ArraySlice<String>) -> [String] in
        if localChunk.elementsEqual(baseChunk) {
            return Array(remoteChunk)
        }
        if remoteChunk.elementsEqual(baseChunk) || localChunk.elementsEqual(remoteChunk) {
            return Array(localChunk)
        }
        conflicted = true
        return Array(localChunk) + [separator] + Array(remoteChunk)
    }
    while true {
        let anchor: Int? = (baseIndex..<base.count).first { toLocal[$0] != nil && toRemote[$0] != nil }
        guard let anchor, let localAnchor = toLocal[anchor], let remoteAnchor = toRemote[anchor] else {
            output += resolve(base[baseIndex...], local[localIndex...], remote[remoteIndex...])
            return (output, conflicted)
        }
        output += resolve(base[baseIndex..<anchor], local[localIndex..<localAnchor], remote[remoteIndex..<remoteAnchor])
        output.append(base[anchor])
        baseIndex = anchor + 1
        localIndex = localAnchor + 1
        remoteIndex = remoteAnchor + 1
    }
}

/// Earliest of the dates (a "sent at" mark: the first send counts). Pure function.
private func earliest(_ dates: Date?...) -> Date? {
    dates.compactMap { $0 }.min()
}

/// Three-way merge of a meeting's state (doc §8.4):
/// - title, folder, template, attendees, calendar event, each speaker name: the side that changed it; both → later
///   clock;
/// - note: same rule; when both rewrote it the losing note goes into `noteHistory` (`conflictReason`, its clock as the
///   time) so the user can restore it, and the shared-language copies are dropped;
/// - own notes: line merge (`mergeMyNotes`), both versions kept with `myNotesSeparator` when the same lines changed;
/// - completed tasks and highlights: three-way sets (undo on either device wins over the base); reminded tasks, sent
///   destinations and sent task keys: union (a send is never forgotten, so nothing is sent twice); send times: the
///   earliest. Task keys first move onto the merged note's tasks (`carriedTaskKeys`), like `mergingConflictVersions`;
/// - status, failure, notice and end time: the recording device's version (`originDeviceID`); audio deleted: either.
/// Pure function.
public func mergeMeetingState(
    base: MeetingSyncState?, local: MeetingSyncState, remote: MeetingSyncState, localDeviceID: String, conflictReason: String, myNotesSeparator: String
) -> MeetingStateMerge {
    let hasBase: Bool = base != nil
    let clock: (MeetingSyncState, String) -> Date = { (state: MeetingSyncState, field: String) -> Date in state.fieldClocks[field] ?? .distantPast }
    func pick<Value: Equatable>(_ field: String, _ value: (MeetingSyncState) -> Value) -> Value {
        let side: MergeSide = pickSide(
            base: base.map(value), local: value(local), remote: value(remote), localClock: clock(local, field), remoteClock: clock(remote, field),
            hasBase: hasBase
        )
        return side == .local ? value(local) : value(remote)
    }

    // Note: the later rewrite wins; a real conflict keeps the loser in the history.
    let noteSide: MergeSide = pickSide(
        base: base.map(\.note), local: local.note, remote: remote.note, localClock: clock(local, MeetingSyncField.note),
        remoteClock: clock(remote, MeetingSyncField.note), hasBase: hasBase
    )
    let bothRewrote: Bool = local.note != remote.note && (base.map { $0.note != local.note && $0.note != remote.note } ?? true)
    let losingState: MeetingSyncState = noteSide == .local ? remote : local
    let loser: NoteVersion? = bothRewrote
        ? losingState.note.map { NoteVersion(savedAt: clock(losingState, MeetingSyncField.note), reason: conflictReason, note: $0) }
        : nil
    let title: String = pick(MeetingSyncField.title) { $0.title }
    let chosenNote: MeetingNote? = noteSide == .local ? local.note : remote.note
    let note: MeetingNote? = chosenNote.map { $0.title == title ? $0 : $0.with(title: title) }
    let sharedNotes: [String: MeetingNote]? = {
        if bothRewrote || note != chosenNote {
            return nil
        }
        if local.note == remote.note {
            let united: [String: MeetingNote] = (remote.sharedNotes ?? [:]).merging(local.sharedNotes ?? [:]) { (_: MeetingNote, mine: MeetingNote) -> MeetingNote in mine }
            return local.sharedNotes == nil && remote.sharedNotes == nil ? nil : united
        }
        return noteSide == .local ? local.sharedNotes : remote.sharedNotes
    }()

    // Speaker names: one pick per person.
    let people: Set<Int> = Set(local.speakerNames.keys).union(remote.speakerNames.keys).union(base.map { Array($0.speakerNames.keys) } ?? [])
    let speakerNames: [Int: String] = people.reduce(into: [Int: String]()) { (result: inout [Int: String], person: Int) -> Void in
        if let name = pick(MeetingSyncField.speakerName(person: person), { $0.speakerNames[person] }) {
            result[person] = name
        }
    }

    let myNotes: (text: String?, conflicted: Bool) = mergeMyNotes(base: base?.myNotes, local: local.myNotes, remote: remote.myNotes, separator: myNotesSeparator)
    let onNote: (MeetingSyncState?, [String]?) -> [String]? = { (state: MeetingSyncState?, keys: [String]?) -> [String]? in
        keysOnNote(keys: keys, from: state?.note, to: note)
    }
    let completedTasks: [String]? = mergedOrderedSet(
        base: onNote(base, base?.completedTasks), local: onNote(local, local.completedTasks), remote: onNote(remote, remote.completedTasks)
    )
    let remindedTasks: [String]? = unitedOrderedSet(lists: [onNote(local, local.remindedTasks), onNote(remote, remote.remindedTasks)])
    let trackers: [String] = unitedOrderedSet(lists: [local.sentTaskKeys.map { Array($0.keys).sorted() }, remote.sentTaskKeys.map { Array($0.keys).sorted() }]) ?? []
    let sentTaskKeys: [String: [String]]? = local.sentTaskKeys == nil && remote.sentTaskKeys == nil
        ? nil
        : Dictionary(uniqueKeysWithValues: trackers.map { (tracker: String) -> (String, [String]) in
            (tracker, unitedOrderedSet(lists: [onNote(local, local.sentTaskKeys?[tracker]), onNote(remote, remote.sentTaskKeys?[tracker])]) ?? [])
        })
    let owner: MeetingSyncState = local.originDeviceID == localDeviceID ? local : remote
    let clocks: [String: Date] = local.fieldClocks.merging(remote.fieldClocks) { max($0, $1) }

    let merged: MeetingSyncState = MeetingSyncState(
        schema: syncPayloadSchema, meetingID: local.meetingID, contentObjectID: local.contentObjectID, originDeviceID: local.originDeviceID,
        startedAt: owner.startedAt, endedAt: owner.endedAt, status: owner.status, failureMessage: owner.failureMessage, notice: owner.notice,
        title: title, note: note, noteHistory: mergedNoteHistory(local: local.noteHistory, remote: remote.noteHistory, loser: loser),
        sharedNotes: sharedNotes, myNotes: myNotes.text, speakerNames: speakerNames, completedTasks: completedTasks, remindedTasks: remindedTasks,
        folder: pick(MeetingSyncField.folder) { $0.folder }, highlights: mergedOrderedSet(base: base?.highlights, local: local.highlights, remote: remote.highlights),
        attendees: pick(MeetingSyncField.attendees) { $0.attendees }, calendarEventID: pick(MeetingSyncField.calendarEventID) { $0.calendarEventID },
        template: pick(MeetingSyncField.template) { $0.template },
        sentDestinationIDs: unitedOrderedSet(lists: [local.sentDestinationIDs, remote.sentDestinationIDs]), sentTaskKeys: sentTaskKeys,
        notesSentAt: earliest(local.notesSentAt, remote.notesSentAt), webhookSentAt: earliest(local.webhookSentAt, remote.webhookSentAt),
        audioDeleted: local.audioDeleted || remote.audioDeleted, fieldClocks: clocks
    )
    return MeetingStateMerge(state: merged, myNotesConflicted: myNotes.conflicted)
}

/// Keyed three-way merge of records (by `key`): an entry only one side added, changed or removed follows that side;
/// both changed → `local`. Order: local entries, then remote additions. Pure function.
private func mergedKeyed<Item: Equatable>(base: [Item]?, local: [Item], remote: [Item], key: (Item) -> String) -> [Item] {
    func find(_ items: [Item], _ wanted: String) -> Item? {
        items.first { key($0) == wanted }
    }
    let keys: [String] = (local + remote + (base ?? [])).map(key).reduce(into: [String]()) { (result: inout [String], item: String) -> Void in
        if !result.contains(item) {
            result.append(item)
        }
    }
    return keys.compactMap { (wanted: String) -> Item? in
        let localItem: Item? = find(local, wanted)
        let remoteItem: Item? = find(remote, wanted)
        let baseItem: Item?? = base.map { find($0, wanted) }
        if localItem == remoteItem {
            return localItem
        }
        if let baseItem, localItem == baseItem {
            return remoteItem
        }
        if let baseItem, remoteItem == baseItem {
            return localItem
        }
        return localItem ?? remoteItem
    }
}

/// Three-way merge of the people book: saved people and removals by name (case-insensitive), each following the side
/// that changed it; a name that ends up both saved and removed keeps the later of the two (added vs removed). Pure
/// function.
public func mergePeopleBook(base: PeopleBook?, local: PeopleBook, remote: PeopleBook) -> PeopleBook {
    let saved: [SavedPerson] = mergedKeyed(base: base?.saved, local: local.saved, remote: remote.saved) { $0.name.lowercased() }
    let removed: [RemovedPerson] = mergedKeyed(base: base?.removed, local: local.removed, remote: remote.removed) { $0.name.lowercased() }
    let removedAt: (String) -> Date? = { (name: String) -> Date? in removed.first { $0.name.lowercased() == name.lowercased() }?.removedAt }
    let keptSaved: [SavedPerson] = saved.filter { (person: SavedPerson) -> Bool in removedAt(person.name).map { person.addedAt > $0 } ?? true }
    let keptRemoved: [RemovedPerson] = removed.filter { (entry: RemovedPerson) -> Bool in
        !keptSaved.contains { $0.name.lowercased() == entry.name.lowercased() }
    }
    return PeopleBook(saved: keptSaved, removed: keptRemoved)
}

/// Merges two versions of an Ask conversation: turns are append-only, so both sides' turns are kept once (by id) in
/// the order they were asked. Pure function.
public func mergeAskConversation(local: AskConversation, remote: AskConversation) -> AskConversation {
    let turns: [AskConversationTurn] = (local.turns + remote.turns)
        .reduce(into: [AskConversationTurn]()) { (result: inout [AskConversationTurn], turn: AskConversationTurn) -> Void in
            if !result.contains(where: { $0.id == turn.id }) {
                result.append(turn)
            }
        }
        .sorted { $0.startedAt < $1.startedAt }
    let first: AskConversation = remote.createdAt < local.createdAt ? remote : local
    return AskConversation(id: local.id, createdAt: first.createdAt, updatedAt: max(local.updatedAt, remote.updatedAt), title: first.title, turns: turns)
}

/// Three-way merge of the shared preferences: folders as an ordered set, the user's recipes by id. Pure function.
public func mergeSyncPrefs(base: SyncPrefs?, local: SyncPrefs, remote: SyncPrefs) -> SyncPrefs {
    SyncPrefs(
        schema: syncPayloadSchema,
        folders: mergedOrderedSet(base: base?.folders, local: local.folders, remote: remote.folders) ?? [],
        recipes: mergedKeyed(base: base?.recipes, local: local.recipes, remote: remote.recipes) { $0.id }
    )
}
