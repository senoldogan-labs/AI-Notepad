import AINotepadCore
import AINotepadUI
import Foundation

// Lists the iPhone screens derive from the whole meeting archive (named meetings, date sections, the user's tasks, a
// meeting's transcript). `PhoneStore` memoizes them on these inputs: SwiftUI evaluates a screen's `body` many times
// (every navigation, layout and observed change), and rebuilding them on each pass froze the app with a large archive.

/// Input of `PhoneStore.namedMeetings`.
struct PhoneNamedMeetingsInput: Sendable, Equatable {
    let records: [MeetingRecord]
    let userName: String
}

/// `namedRecords` output: the named list and the per-meeting cache the next naming starts from.
struct PhoneNamedMeetings: Sendable {
    let records: [MeetingRecord]
    let cache: NamedRecordsCache
}

/// Input of `PhoneStore.meetingSections`: the listed meetings, the day (Today / Yesterday move with it) and the
/// interface language (month titles).
struct PhoneMeetingSectionsInput: Sendable, Equatable {
    let records: [MeetingRecord]
    let day: Date
    let localeIdentifier: String
}

/// Input of `PhoneStore.folders`.
struct PhoneFoldersInput: Sendable, Equatable {
    let records: [MeetingRecord]
    let saved: [String]
}

/// Input of `PhoneStore.askScopeMenu`.
struct PhoneAskScopeMenuInput: Sendable, Equatable {
    let context: AskScope
    let selected: AskScope
    let records: [MeetingRecord]
    let folders: [FolderSummary]
    let userName: String
}

/// Input of `PhoneStore.taskLists`: the named meetings and the day (overdue / today buckets move with it).
struct PhoneTaskListsInput: Sendable, Equatable {
    let records: [MeetingRecord]
    let day: Date
}

/// The user's tasks across the archive (`myTasks`, newest meeting first), split into open and done; the open ones
/// grouped by due day (`groupedByDueDay`).
struct PhoneTaskLists: Sendable {
    let all: [(record: MeetingRecord, task: NoteTask)]
    let open: [(record: MeetingRecord, task: NoteTask)]
    let done: [(record: MeetingRecord, task: NoteTask)]
    let openGroups: [TaskDueGroup]

    /// Open tasks by urgency (overdue, today, the next 7 days, later, undated): `openTasksByUrgency`.
    var openByUrgency: [DatedTask] {
        openGroups.flatMap(\.tasks)
    }
}

/// The task lists of named meetings (see `PhoneTaskLists`). Pure function.
func phoneTaskLists(namedRecords: [MeetingRecord], now: Date, calendar: Calendar) -> PhoneTaskLists {
    let all: [(record: MeetingRecord, task: NoteTask)] = myTasks(namedRecords: namedRecords)
    let open: [(record: MeetingRecord, task: NoteTask)] = all.filter { !isTaskDone(record: $0.record, task: $0.task) }
    let done: [(record: MeetingRecord, task: NoteTask)] = all.filter { isTaskDone(record: $0.record, task: $0.task) }
    return PhoneTaskLists(all: all, open: open, done: done, openGroups: groupedByDueDay(items: open, now: now, calendar: calendar))
}

/// A meeting page's transcript: reading paragraphs (`transcriptParagraphs`) and the segments skipped for being in
/// another language than the meeting's fixed one (`skippedLanguageSegments`).
struct PhoneMeetingTranscript: Sendable {
    let paragraphs: [TranscriptParagraph]
    let skipped: [StoredSegment]
}

/// The transcript a meeting page shows (see `PhoneMeetingTranscript`). Pure function.
func phoneMeetingTranscript(record: MeetingRecord) -> PhoneMeetingTranscript {
    PhoneMeetingTranscript(paragraphs: transcriptParagraphs(record: record), skipped: skippedLanguageSegments(record: record))
}

/// The transcript caches with `cache` stored under `id`; when that would exceed `limit` meetings, the others are
/// dropped first (the open page's entry stays). Pure function.
func retainingTranscriptCaches(
    caches: [String: MemoCache<MeetingRecord, PhoneMeetingTranscript>], id: String, cache: MemoCache<MeetingRecord, PhoneMeetingTranscript>, limit: Int
) -> [String: MemoCache<MeetingRecord, PhoneMeetingTranscript>] {
    let kept: [String: MemoCache<MeetingRecord, PhoneMeetingTranscript>] = caches[id] == nil && caches.count >= limit ? [:] : caches
    return kept.merging([id: cache]) { (_: MemoCache<MeetingRecord, PhoneMeetingTranscript>, new: MemoCache<MeetingRecord, PhoneMeetingTranscript>) -> MemoCache<MeetingRecord, PhoneMeetingTranscript> in new }
}
