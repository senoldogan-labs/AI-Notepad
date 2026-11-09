#if DEBUG
import AINotepadWatchLink
import Foundation

// Debug-only launch arguments for checking the Watch screens in the Simulator (its `transferFile` does not run there, and
// no T3 device tool drives watchOS):
//   --ornek                sample iPhone snapshot (signed in, iPhone recording, today's meetings, tasks, a failed import)
//                          and two recordings on the Watch; WatchConnectivity is not activated, so nothing overwrites it
//   --ornek-kapali         the same with Watch recording switched off by the server
//   --ornek-kayit          starts a real Watch recording at launch (the Simulator's microphone)
//   --ekran gorevler|iphone  opens that screen

/// The launch arguments above.
struct WatchDemoOptions: Equatable {
    let sample: Bool
    let recordingDisabled: Bool
    let startRecording: Bool
    let screen: String?

    static let current: WatchDemoOptions = options(arguments: CommandLine.arguments)

    /// Reads the options from the launch arguments. Pure function.
    static func options(arguments: [String]) -> WatchDemoOptions {
        let screen: String? = arguments.firstIndex(of: "--ekran").flatMap { (index: Int) -> String? in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let disabled: Bool = arguments.contains("--ornek-kapali")
        return WatchDemoOptions(
            sample: arguments.contains("--ornek") || disabled, recordingDisabled: disabled, startRecording: arguments.contains("--ornek-kayit"),
            screen: screen
        )
    }
}

/// The sample snapshot (`--ornek`). Pure function.
func watchDemoSnapshot(now: Date, recordingEnabled: Bool) -> WatchSnapshot {
    let calendar: Calendar = Calendar.current
    let hour: (Int, Int) -> Date = { (h: Int, m: Int) -> Date in
        calendar.date(bySettingHour: h, minute: m, second: 0, of: now) ?? now
    }
    return WatchSnapshot(
        signedIn: true, accountTag: "demo",
        recording: WatchPhoneRecording(recordingID: "demo-rec", phase: .recording, title: "Design review", timerStart: now.addingTimeInterval(-1_384), timerStoppedAt: nil),
        meetings: [
            WatchMeeting(id: "m1", title: "Weekly sync with the product team", start: hour(14, 0), end: now.addingTimeInterval(3_600)),
            WatchMeeting(id: "m2", title: "Customer call: Northwind", start: hour(16, 30), end: now.addingTimeInterval(7_200)),
        ],
        calendarOn: true,
        tasks: [
            WatchTask(meetingID: "a", taskKey: "1", text: "Send the revised pricing deck to Northwind", meetingTitle: "Customer call", due: "Friday"),
            WatchTask(meetingID: "a", taskKey: "2", text: "Book the usability study room", meetingTitle: "Design review", due: nil),
            WatchTask(meetingID: "b", taskKey: "3", text: "Draft the Q1 hiring plan", meetingTitle: "Weekly sync", due: "2026-11-14"),
        ],
        maxMeetingMinutes: 240, phoneAppOpen: true,
        imports: [WatchImportReport(id: UUID().uuidString, status: .failed(title: "Board prep", reason: "No connection. Try again when you're online."))],
        watchRecordingEnabled: recordingEnabled
    )
}

/// The sample recordings on the Watch (`--ornek`). Pure function.
func watchDemoRecordings(now: Date) -> [WatchLocalRecording] {
    [
        WatchLocalRecording(
            info: WatchRecordingInfo(id: UUID().uuidString, title: "1:1 with Sam", startedAt: now.addingTimeInterval(-7_200), durationSec: 1_710, accountTag: "demo", interrupted: false),
            state: .queued(transferToken: "demo")
        ),
        WatchLocalRecording(
            info: WatchRecordingInfo(id: UUID().uuidString, title: "", startedAt: now.addingTimeInterval(-3_600), durationSec: 642, accountTag: "demo", interrupted: true),
            state: .rejected(reason: "iPhone couldn't keep the recording. Free up space on iPhone and send again from the watch.")
        ),
    ]
}
#endif
