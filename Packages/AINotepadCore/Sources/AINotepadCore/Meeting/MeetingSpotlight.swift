import Foundation

// What of a meeting goes into the system search (Spotlight, and Siri through the linked app entity): its title, date,
// people, the note's summary and its tasks. Never the transcript, the audio, the screens or the user's own notes: the
// index stays small and holds only what the note already shows at a glance. The sample meeting never goes in
// (`realMeetings`). Everything here is pure; the CoreSpotlight adapter lives in the apps.

/// One meeting as it is indexed.
public struct SpotlightMeetingEntry: Sendable, Equatable {
    /// The meeting's id (folder name): the indexed item's identifier, opened when the result is chosen.
    public let id: String
    public let title: String
    public let startedAt: Date
    public let endedAt: Date?
    /// Calendar attendees and the names given to speakers, without duplicates, in that order.
    public let people: [String]
    /// The note's summary; empty while there is no note.
    public let summary: String
    /// The note's tasks as `Owner: what (due)` lines.
    public let tasks: [String]
    /// The meeting's folder; nil without one.
    public let folder: String?

    public init(id: String, title: String, startedAt: Date, endedAt: Date?, people: [String], summary: String, tasks: [String], folder: String?) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.people = people
        self.summary = summary
        self.tasks = tasks
        self.folder = folder
    }

    /// The text under the title in a result: the summary, then the tasks, one per line.
    public var contentDescription: String {
        ([summary] + tasks).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Search keywords: people and folder.
    public var keywords: [String] {
        people + [folder].compactMap { $0 }
    }
}

/// Index entries of the meetings, in the given order: the sample meeting is left out, speaker labels in the note become
/// the given names (`namedRecord`). Pure function.
public func spotlightMeetingEntries(records: [MeetingRecord], userName: String) -> [SpotlightMeetingEntry] {
    realMeetings(records: records).map { (stored: MeetingRecord) -> SpotlightMeetingEntry in
        let record: MeetingRecord = namedRecord(record: stored, userName: userName)
        let named: [String] = record.speakerNames.keys.sorted().compactMap { record.speakerNames[$0] }
        let people: [String] = ((record.attendees ?? []) + named)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { (unique: inout [String], name: String) -> Void in
                if !unique.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    unique.append(name)
                }
            }
        let tasks: [String] = (record.note?.tasks ?? []).map { (task: NoteTask) -> String in
            let line: String = task.owner.isEmpty ? task.description : "\(task.owner): \(task.description)"
            return task.dueDate.map { "\(line) (\($0))" } ?? line
        }
        return SpotlightMeetingEntry(
            id: record.id, title: record.note?.title ?? record.title, startedAt: record.startedAt, endedAt: record.endedAt, people: people,
            summary: record.note?.summary ?? "", tasks: tasks, folder: record.folder
        )
    }
}

/// What to change in the index to go from what was indexed to the current entries.
public struct SpotlightIndexPlan: Sendable, Equatable {
    /// New or changed entries.
    public let upserts: [SpotlightMeetingEntry]
    /// Ids no longer among the entries (deleted, moved to Recently Deleted, another account's).
    public let deletions: [String]

    public init(upserts: [SpotlightMeetingEntry], deletions: [String]) {
        self.upserts = upserts
        self.deletions = deletions
    }

    public var isEmpty: Bool {
        upserts.isEmpty && deletions.isEmpty
    }
}

/// The changes from `indexed` (id → what was last written) to `current`. Unchanged entries are not written again;
/// deletions are sorted. Pure function.
public func spotlightIndexPlan(indexed: [String: SpotlightMeetingEntry], current: [SpotlightMeetingEntry]) -> SpotlightIndexPlan {
    let currentIDs: Set<String> = Set(current.map(\.id))
    return SpotlightIndexPlan(
        upserts: current.filter { indexed[$0.id] != $0 },
        deletions: indexed.keys.filter { !currentIDs.contains($0) }.sorted()
    )
}
