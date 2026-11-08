import Foundation

// Data behind the Shortcuts/Siri actions ("What are my tasks", "Open meeting"): which meetings and tasks they offer and
// how a task is named across launches. The sample meeting is never offered (`realMeetings`). Pure functions; the
// App Intents types live in the apps.

/// How many meetings the meeting picker suggests before anything is typed.
public let shortcutSuggestedMeetingCount: Int = 12

/// An open task of the user's, as Shortcuts and Siri show it.
public struct ShortcutTask: Sendable, Equatable, Identifiable {
    /// Stable across launches: meeting id and task key (`shortcutTaskID`).
    public let id: String
    public let meetingID: String
    public let meetingTitle: String
    public let meetingStartedAt: Date
    public let description: String
    /// Due date as the note says it ("Friday", "12 May"); nil without one.
    public let dueDate: String?

    public init(id: String, meetingID: String, meetingTitle: String, meetingStartedAt: Date, description: String, dueDate: String?) {
        self.id = id
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.meetingStartedAt = meetingStartedAt
        self.description = description
        self.dueDate = dueDate
    }
}

/// Separator between the meeting id and the task key in a task's id. A meeting id is a folder name and never holds it.
private let shortcutTaskIDSeparator: Character = "/"

/// A task's id: `<meeting id>/<task key>`. Pure function.
public func shortcutTaskID(meetingID: String, taskKey: String) -> String {
    "\(meetingID)\(shortcutTaskIDSeparator)\(taskKey)"
}

/// The meeting id of a task's id; nil when it is not one. Pure function.
public func shortcutTaskMeetingID(taskID: String) -> String? {
    guard let separator = taskID.firstIndex(of: shortcutTaskIDSeparator), separator != taskID.startIndex,
          taskID.index(after: separator) != taskID.endIndex else {
        return nil
    }
    return String(taskID[..<separator])
}

/// The user's open (not done) tasks, newest meeting first, in the note's order within a meeting; speaker labels become
/// the given names. Pure function.
public func openShortcutTasks(records: [MeetingRecord], userName: String) -> [ShortcutTask] {
    let newestFirst: [MeetingRecord] = realMeetings(records: records).sorted { $0.startedAt > $1.startedAt }
    return myTasks(meetings: newestFirst, userName: userName)
        .filter { !isTaskDone(record: $0.record, task: $0.task) }
        .map { (item: (record: MeetingRecord, task: NoteTask)) -> ShortcutTask in
            ShortcutTask(
                id: shortcutTaskID(meetingID: item.record.id, taskKey: taskKey(task: item.task)), meetingID: item.record.id,
                meetingTitle: item.record.note?.title ?? item.record.title, meetingStartedAt: item.record.startedAt, description: item.task.description,
                dueDate: item.task.dueDate
            )
        }
}

/// Meetings offered by the picker: real meetings matching `query` (`filterMeetings`; empty query: all), newest first.
/// Pure function.
public func shortcutMeetings(records: [MeetingRecord], query: String) -> [MeetingRecord] {
    filterMeetings(records: realMeetings(records: records), query: query).sorted { $0.startedAt > $1.startedAt }
}

/// An Ask answer as plain text for Siri to read and Shortcuts to pass on: Markdown marks and source markers (`[2]`,
/// `[w1]`) are dropped, list items become lines, a table becomes its cells separated by " · ". Pure function.
public func plainAnswerText(text: String) -> String {
    plainBlocks(blocks: parseMarkdown(text: text)).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Lines of the blocks. Pure function.
private func plainBlocks(blocks: [MarkdownBlock]) -> [String] {
    blocks.flatMap { (block: MarkdownBlock) -> [String] in
        switch block {
        case .heading(_, let content), .paragraph(let content):
            return [plainInlines(inlines: content)]
        case .list(_, _, let items):
            return items.flatMap { plainBlocks(blocks: $0) }
        case .code(_, let text):
            return [text]
        case .table(let header, _, let rows):
            return ([header] + rows).map { $0.map { plainInlines(inlines: $0) }.joined(separator: " · ") }
        case .quote(let inner):
            return plainBlocks(blocks: inner)
        case .rule:
            return []
        }
    }
    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// Text of inline elements without marks or source markers; spaces left by a removed marker collapse. Pure function.
private func plainInlines(inlines: [MarkdownInline]) -> String {
    let text: String = inlines.map { (inline: MarkdownInline) -> String in
        switch inline {
        case .text(let text), .code(let text): text
        case .strong(let children), .emphasis(let children), .strikethrough(let children): plainInlines(inlines: children)
        case .link(let label, _): plainInlines(inlines: label)
        case .citation, .webCitation: ""
        case .lineBreak: " "
        }
    }
    .joined()
    return text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        .replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ,", with: ",")
}
