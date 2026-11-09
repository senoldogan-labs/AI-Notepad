import AINotepadWatchLink
import Foundation

// The iPhone's side of the Apple Watch snapshot: what the Watch sees is derived from the recorder's single state
// (`RecorderState`), the calendar and the tasks; nothing here keeps state of its own.

/// The iPhone's recording as the Watch shows it; nil when nothing is recording (idle or the last start failed). An
/// interruption pause counts as paused (the timer stops there). Pure function.
public func watchPhoneRecording(state: RecorderState, title: String) -> WatchPhoneRecording? {
    switch state {
    case .idle, .failed:
        return nil
    case .starting(let starting):
        return WatchPhoneRecording(recordingID: starting.id.rawValue, phase: .starting, title: title, timerStart: nil, timerStoppedAt: nil)
    case .recording(let recording):
        return WatchPhoneRecording(
            recordingID: recording.id.rawValue, phase: recording.pause.isPaused ? .paused : .recording, title: title,
            timerStart: recording.clock.timerStart(startedAt: recording.startedAt), timerStoppedAt: recording.clock.pausedAt
        )
    case .finishing(let finishing):
        return WatchPhoneRecording(
            recordingID: finishing.id.rawValue, phase: .finishing, title: title,
            timerStart: finishing.clock.timerStart(startedAt: finishing.startedAt), timerStoppedAt: finishing.stoppedAt
        )
    }
}

/// Calendar meetings running at `now` or starting later today, soonest first, at most `limit`. Pure function.
public func watchMeetings(meetings: [CalendarMeeting], now: Date, calendar: Calendar, limit: Int) -> [WatchMeeting] {
    meetings
        .filter { $0.end > now && ($0.start <= now || calendar.isDate($0.start, inSameDayAs: now)) }
        .sorted { $0.start < $1.start }
        .prefix(limit)
        .map { WatchMeeting(id: $0.id, title: $0.title, start: $0.start, end: $0.end) }
}

/// The user's open tasks for the Watch, in the given (urgency) order, at most `limit`; long task text is cut at
/// `maxChars` with an ellipsis (the Watch shows two lines). Pure function.
public func watchTasks(items: [DatedTask], limit: Int, maxChars: Int) -> [WatchTask] {
    items.prefix(limit).map { (item: DatedTask) -> WatchTask in
        WatchTask(
            meetingID: item.record.id, taskKey: taskKey(task: item.task), text: shortenedWatchText(text: item.task.description, maxChars: maxChars),
            meetingTitle: shortenedWatchText(text: item.record.note?.title ?? item.record.title, maxChars: maxChars), due: item.task.dueDate
        )
    }
}

/// Text cut at `maxChars` characters with an ellipsis. Pure function.
private func shortenedWatchText(text: String, maxChars: Int) -> String {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > maxChars else {
        return trimmed
    }
    return String(trimmed.prefix(maxChars - 1)).trimmingCharacters(in: .whitespaces) + "…"
}
