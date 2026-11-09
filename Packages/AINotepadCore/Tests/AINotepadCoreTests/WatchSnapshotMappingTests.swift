import AINotepadWatchLink
import Foundation
import Testing
@testable import AINotepadCore

@Suite struct WatchSnapshotMappingTests {
    private let base: Date = Date(timeIntervalSince1970: 1_800_000_000)
    private let id: RecordingID = RecordingID(rawValue: "rec-1")

    private func at(_ sec: Double) -> Date {
        base.addingTimeInterval(sec)
    }

    private func step(_ state: RecorderState, _ event: RecorderEvent) -> RecorderState {
        recorderStep(state: state, event: event, finishingLimitSec: 30).state
    }

    private func recording() -> RecorderState {
        [
            RecorderEvent.startRequested(id: id, micMuted: false), .awaitingCapture(id: id), .captureOpened(id: id, at: at(0)),
            .serverStarted(id: id, server: .online(meetingID: "m1")), .sessionStarted(id: id, at: at(1)),
        ].reduce(RecorderState.idle, step)
    }

    // Nothing recording: the Watch shows no iPhone recording (also after a failed start).
    @Test func idleAndFailedHaveNoRecording() {
        #expect(watchPhoneRecording(state: .idle, title: "") == nil)
        #expect(watchPhoneRecording(state: .failed(id), title: "") == nil)
    }

    // The timer starts at capture and moves forward by completed pauses; it stops at a pause and at "End".
    @Test func timerFollowsThePauseClock() {
        let running: RecorderState = recording()
        #expect(watchPhoneRecording(state: running, title: "Sync") == WatchPhoneRecording(
            recordingID: "rec-1", phase: .recording, title: "Sync", timerStart: at(0), timerStoppedAt: nil
        ))
        let paused: RecorderState = step(running, .pauseRequested(target: .current, at: at(60)))
        #expect(watchPhoneRecording(state: paused, title: "Sync")?.phase == .paused)
        #expect(watchPhoneRecording(state: paused, title: "Sync")?.timerStoppedAt == at(60))
        let resumed: RecorderState = step(paused, .resumeRequested(target: .current, at: at(90)))
        #expect(watchPhoneRecording(state: resumed, title: "Sync")?.timerStart == at(30))
        let finishing: RecorderState = step(resumed, .stopRequested(target: .current, at: at(120)))
        #expect(watchPhoneRecording(state: finishing, title: "Sync") == WatchPhoneRecording(
            recordingID: "rec-1", phase: .finishing, title: "Sync", timerStart: at(30), timerStoppedAt: at(120)
        ))
    }

    // An interruption (call) also shows as paused: the timer stops there.
    @Test func interruptionShowsAsPaused() {
        let interrupted: RecorderState = step(recording(), .interruptionChanged(interrupted: true, at: at(10)))
        #expect(watchPhoneRecording(state: interrupted, title: "")?.phase == .paused)
    }

    @Test func startingHasNoTimer() {
        let starting: RecorderState = step(.idle, .startRequested(id: id, micMuted: false))
        #expect(watchPhoneRecording(state: starting, title: "") == WatchPhoneRecording(
            recordingID: "rec-1", phase: .starting, title: "", timerStart: nil, timerStoppedAt: nil
        ))
    }

    // Running and later-today meetings, soonest first; ended ones and tomorrow's are left out.
    @Test func meetingsAreTodaysNotEnded() {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki")!
        let now: Date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 10))!
        let hour: TimeInterval = 3600
        let meetings: [CalendarMeeting] = [
            CalendarMeeting(id: "later", title: "Later", start: now + 3 * hour, end: now + 4 * hour, attendees: [], joinURL: nil),
            CalendarMeeting(id: "ended", title: "Ended", start: now - 2 * hour, end: now - hour, attendees: [], joinURL: nil),
            CalendarMeeting(id: "now", title: "Now", start: now - 600, end: now + 600, attendees: [], joinURL: nil),
            CalendarMeeting(id: "tomorrow", title: "Tomorrow", start: now + 20 * hour, end: now + 21 * hour, attendees: [], joinURL: nil),
        ]
        #expect(watchMeetings(meetings: meetings, now: now, calendar: calendar, limit: 5).map(\.id) == ["now", "later"])
        #expect(watchMeetings(meetings: meetings, now: now, calendar: calendar, limit: 1).map(\.id) == ["now"])
    }

    // Tasks keep their stored key (mark-done names it), the order and the limit; long text is cut.
    @Test func tasksCarryTheirKeyAndAreShortened() {
        let long: NoteTask = NoteTask(owner: "You", description: String(repeating: "a", count: 200), dueDate: "Friday", isMine: true)
        let short: NoteTask = NoteTask(owner: "You", description: "Send deck", dueDate: nil, isMine: true)
        let record: MeetingRecord = MeetingRecord(
            id: "m1", title: "Sync", startedAt: base, endedAt: nil, language: .english, status: .done,
            failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: MeetingNote(title: "Weekly sync", summary: "S", decisions: [], tasks: [long, short], glossary: []),
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let items: [DatedTask] = [DatedTask(record: record, task: short, due: nil), DatedTask(record: record, task: long, due: nil)]
        let tasks: [WatchTask] = watchTasks(items: items, limit: 5, maxChars: 80)
        #expect(tasks.map(\.taskKey) == [taskKey(task: short), taskKey(task: long)])
        #expect(tasks[0] == WatchTask(meetingID: "m1", taskKey: taskKey(task: short), text: "Send deck", meetingTitle: "Weekly sync", due: nil))
        #expect(tasks[1].text.count == 80)
        #expect(tasks[1].text.hasSuffix("…"))
        #expect(tasks[1].due == "Friday")
        #expect(watchTasks(items: items, limit: 1, maxChars: 80).count == 1)
    }
}
