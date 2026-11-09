import Foundation

// Pure decisions shared by the Watch app, its widgets and the iPhone side.

/// How a Watch recording that reached the iPhone is handled.
public enum WatchImportDecision: Sendable, Equatable {
    /// Import it into the loaded account now.
    case importNow
    /// Keep it in the iPhone's inbox: no account is loaded, or the loaded account is not the one it was made for. It is
    /// imported once that account is loaded again (never into another account).
    case wait
    /// Already imported (a repeated transfer): drop the copy.
    case duplicate
}

/// Decides what to do with a received Watch recording. `loadedAccountTag`: the account whose data is loaded on the
/// iPhone (nil when signed out); `importedIDs`: recordings already imported. Pure function.
public func watchImportDecision(info: WatchRecordingInfo, loadedAccountTag: String?, importedIDs: Set<String>) -> WatchImportDecision {
    if importedIDs.contains(info.id) {
        return .duplicate
    }
    guard let loadedAccountTag, loadedAccountTag == info.accountTag else {
        return .wait
    }
    return .importNow
}

/// Longest a Watch recording may run: the account's longest meeting; nil when the iPhone has not said (the iPhone still
/// checks at import). Pure function.
public func watchRecordingLimitSec(maxMeetingMinutes: Int?) -> TimeInterval? {
    maxMeetingMinutes.map { (minutes: Int) -> TimeInterval in TimeInterval(minutes) * 60 }
}

/// Meetings that have not ended at `now`, soonest first (the snapshot may be hours old). Pure function.
public func watchUpcomingMeetings(meetings: [WatchMeeting], now: Date) -> [WatchMeeting] {
    meetings.filter { $0.end > now }.sorted { $0.start < $1.start }
}

/// The meeting to offer first: one running now, else the next one today. Pure function.
public func watchNextMeeting(meetings: [WatchMeeting], now: Date) -> WatchMeeting? {
    watchUpcomingMeetings(meetings: meetings, now: now).first
}

/// "Start on iPhone" is offered only when it can work: signed in, nothing recording there, and Gistsmith open on the
/// iPhone (iOS refuses the microphone to a background app). Pure function.
public func watchCanStartOnPhone(snapshot: WatchSnapshot) -> Bool {
    snapshot.signedIn && snapshot.recording == nil && snapshot.phoneAppOpen
}

/// Tasks still shown on the Watch: the snapshot's open tasks minus those marked done on the Watch and not yet reflected
/// by a newer snapshot. Pure function.
public func watchVisibleTasks(tasks: [WatchTask], markedDone: Set<String>) -> [WatchTask] {
    tasks.filter { !markedDone.contains($0.id) }
}

/// Task IDs marked done on the Watch that the iPhone's snapshot still lists as open (the mark is still on its way); the
/// rest are dropped so the set does not grow. Pure function.
public func watchPendingDoneMarks(markedDone: Set<String>, snapshotTasks: [WatchTask]) -> Set<String> {
    markedDone.intersection(Set(snapshotTasks.map(\.id)))
}

/// A recording made on the Watch, as its own app keeps it until the iPhone has it.
public struct WatchLocalRecording: Codable, Sendable, Equatable, Identifiable {
    public let info: WatchRecordingInfo
    public let state: WatchLocalRecordingState

    public init(info: WatchRecordingInfo, state: WatchLocalRecordingState) {
        self.info = info
        self.state = state
    }

    public var id: String { info.id }
}

/// Where a finished Watch recording is on its way to the iPhone.
public enum WatchLocalRecordingState: String, Codable, Sendable, Equatable {
    /// Saved on the Watch; the capture is being compressed for the transfer.
    case preparing
    /// Saved on the Watch; the transfer is queued (the iPhone may be away).
    case waiting
    /// The transfer finished; the copy stays until the iPhone's snapshot confirms it holds the recording.
    case sent
    /// The last transfer failed; "Send again" queues it again.
    case failed
}

/// The snapshot the Watch keeps when a new one arrives. The iPhone sends `watchRecordingEnabled` and
/// `maxMeetingMinutes` as nil while it has not read the account from the server yet (just launched, offline); for the
/// same account the Watch then keeps what it knew, so the Record button does not vanish offline. Pure function.
public func watchMergedSnapshot(previous: WatchSnapshot, incoming: WatchSnapshot) -> WatchSnapshot {
    guard incoming.signedIn, previous.signedIn, incoming.accountTag == previous.accountTag else {
        return incoming
    }
    return WatchSnapshot(
        signedIn: incoming.signedIn, accountTag: incoming.accountTag, recording: incoming.recording, meetings: incoming.meetings,
        calendarOn: incoming.calendarOn, tasks: incoming.tasks, maxMeetingMinutes: incoming.maxMeetingMinutes ?? previous.maxMeetingMinutes,
        phoneAppOpen: incoming.phoneAppOpen, receivedRecordingIDs: incoming.receivedRecordingIDs, failedImports: incoming.failedImports,
        watchRecordingEnabled: incoming.watchRecordingEnabled ?? previous.watchRecordingEnabled
    )
}

/// Recording on the Watch is offered: signed in and switched on for the account (unknown counts as off). Pure function.
public func watchCanRecord(snapshot: WatchSnapshot) -> Bool {
    snapshot.signedIn && snapshot.watchRecordingEnabled == true
}

/// Shortest allowance worth starting a Watch recording for: below it the account's remaining time would end the
/// recording almost at once.
public let watchRecordingMinimumAllowanceMinutes: Int = 2

/// The account has too little meeting time left to start a Watch recording (unknown: the iPhone checks at import).
/// Pure function.
public func watchAllowanceTooShort(maxMeetingMinutes: Int?) -> Bool {
    maxMeetingMinutes.map { (minutes: Int) -> Bool in minutes < watchRecordingMinimumAllowanceMinutes } ?? false
}

/// Recording IDs come from the other device and become file names: only a UUID is accepted. Pure function.
public func isValidWatchRecordingID(id: String) -> Bool {
    UUID(uuidString: id) != nil
}

/// Local recordings the iPhone confirms it holds (its snapshot lists them): their Watch copies can be deleted. Pure
/// function.
public func watchRecordingsConfirmedByPhone(recordings: [WatchLocalRecording], snapshot: WatchSnapshot) -> [String] {
    let received: Set<String> = Set(snapshot.receivedRecordingIDs)
    return recordings.map(\.id).filter { received.contains($0) }
}

/// The file name of a Watch recording's audio as it is sent (AAC `.m4a`, named by the recording's ID): the same on both
/// devices. Pure function.
public func watchRecordingFileName(id: String) -> String {
    id + ".m4a"
}

/// The file the Watch records into: 16-bit PCM in CAF. Unlike AAC in `.m4a` (index written only at `stop()`), a CAF file
/// cut off by the app being killed stays readable up to the last write (checked in the watchOS Simulator), so a crash,
/// a dead battery or a force quit never costs the meeting. It is compressed to `watchRecordingFileName` after End.
/// Pure function.
public func watchCaptureFileName(id: String) -> String {
    id + ".caf"
}

/// What the complication and Smart Stack widget show, most important first.
public enum WatchGlanceContent: Codable, Sendable, Equatable {
    /// Recording on the Watch: timer from `timerStart`, stopped at `pausedAt` when paused.
    case watchRecording(timerStart: Date, pausedAt: Date?)
    case phoneRecording(WatchPhoneRecording)
    case nextMeeting(WatchMeeting)
    /// Nothing running and no meeting ahead: a tap starts a note.
    case idle
}

/// The Watch's running recording as the glance needs it.
public struct WatchGlanceRecording: Codable, Sendable, Equatable {
    /// Wall-clock start of the timer (start pushed forward by completed pauses).
    public let timerStart: Date
    public let pausedAt: Date?

    public init(timerStart: Date, pausedAt: Date?) {
        self.timerStart = timerStart
        self.pausedAt = pausedAt
    }
}

/// What the widget extension reads from the shared App Group: only what the glances draw (no task text).
public struct WatchGlanceState: Codable, Sendable, Equatable {
    public let watchRecording: WatchGlanceRecording?
    public let phoneRecording: WatchPhoneRecording?
    /// Upcoming meetings of today (title and time only).
    public let meetings: [WatchMeeting]
    public let signedIn: Bool

    public init(watchRecording: WatchGlanceRecording?, phoneRecording: WatchPhoneRecording?, meetings: [WatchMeeting], signedIn: Bool) {
        self.watchRecording = watchRecording
        self.phoneRecording = phoneRecording
        self.meetings = meetings
        self.signedIn = signedIn
    }

    public static let empty: WatchGlanceState = WatchGlanceState(watchRecording: nil, phoneRecording: nil, meetings: [], signedIn: false)
}

/// The glance state for a snapshot and the Watch's own recording. Pure function.
public func watchGlanceState(snapshot: WatchSnapshot, watchRecording: WatchGlanceRecording?) -> WatchGlanceState {
    WatchGlanceState(watchRecording: watchRecording, phoneRecording: snapshot.recording, meetings: snapshot.meetings, signedIn: snapshot.signedIn)
}

/// The glance: a Watch recording beats the iPhone's recording, which beats the next meeting. Pure function.
public func watchGlanceContent(state: WatchGlanceState, now: Date) -> WatchGlanceContent {
    if let recording = state.watchRecording {
        return .watchRecording(timerStart: recording.timerStart, pausedAt: recording.pausedAt)
    }
    if let recording = state.phoneRecording {
        return .phoneRecording(recording)
    }
    if let meeting = watchNextMeeting(meetings: state.meetings, now: now) {
        return .nextMeeting(meeting)
    }
    return .idle
}

// MARK: Recording safety on the Watch

/// Free space a Watch recording needs before it starts: four hours of the PCM capture (~115 MB per hour) plus its
/// compressed copy (~14 MB per hour). A full disk would end the recording mid-meeting.
public let watchRecordingMinimumFreeBytes: Int64 = 520_000_000

/// A recording may start with `availableBytes` free on the Watch. Pure function.
public func watchHasRoomToRecord(availableBytes: Int64) -> Bool {
    availableBytes >= watchRecordingMinimumFreeBytes
}

/// Battery level (0…1) at which a running Watch recording is ended and saved: further down the Watch may switch to
/// Power Reserve and stop the app with an unclosed (unreadable) file.
public let watchRecordingLowBatteryLevel: Float = 0.05

/// The Watch's battery as the recorder sees it.
public enum WatchBatteryState: Sendable, Equatable {
    /// Battery level unknown (monitoring off, or the Simulator).
    case unknown
    /// On the charger (charging or full): never ends a recording.
    case charging
    /// Running on battery at `level` (0…1).
    case discharging(level: Float)
}

/// A running Watch recording must end now so what was recorded is saved before the battery runs out. Pure function.
public func watchShouldEndForBattery(battery: WatchBatteryState) -> Bool {
    switch battery {
    case .unknown, .charging:
        false
    case .discharging(let level):
        level <= watchRecordingLowBatteryLevel
    }
}

/// Recordings whose transfer must be prepared or queued again: preparing, waiting or failed ones that WatchConnectivity
/// no longer has queued (`queuedFileNames`: file names of the outstanding transfers). Sent ones wait for the iPhone's
/// confirmation (a manual "Send again" covers a transfer the iPhone lost). Pure function.
public func watchRecordingsToRequeue(recordings: [WatchLocalRecording], queuedFileNames: Set<String>) -> [WatchRecordingInfo] {
    recordings
        .filter { $0.state != .sent && !queuedFileNames.contains(watchRecordingFileName(id: $0.id)) }
        .map(\.info)
}

// MARK: The iPhone's inbox for Watch recordings

/// Errors of the iPhone's inbox for Watch recordings.
public enum WatchInboxError: Error, Equatable {
    /// The recording's ID is not a UUID (it would become a file name).
    case invalidRecordingID
    /// The transferred file holds no data.
    case emptyAudio
}

/// The recordings in the inbox, and the metadata files that could not be read (left alone; the adapter logs them).
public struct WatchInboxContents: Sendable, Equatable {
    /// Readable entries with their audio in place, oldest recording first.
    public let entries: [WatchRecordingInfo]
    /// Metadata files that could not be decoded, whose name does not match their recording ID, or whose audio is missing.
    public let unreadable: [URL]

    public init(entries: [WatchRecordingInfo], unreadable: [URL]) {
        self.entries = entries
        self.unreadable = unreadable
    }
}

/// The metadata file of an inbox entry (next to its audio). Pure function.
public func watchInboxMetadataURL(inbox: URL, id: String) -> URL {
    inbox.appending(path: id + ".json")
}

/// The audio file of an inbox entry. Pure function.
public func watchInboxAudioURL(inbox: URL, id: String) -> URL {
    inbox.appending(path: watchRecordingFileName(id: id))
}

/// Moves a transferred Watch recording into `inbox` with its metadata next to it and returns the metadata. `file` is
/// WatchConnectivity's temporary copy and `payload` its metadata's `watchPayloadKey` data. It must run before
/// `session(_:didReceive:)` returns: the system deletes the temporary file then. A repeated transfer replaces the entry
/// (the import ledger skips a recording already imported).
public func storeWatchRecording(file: URL, payload: Data?, inbox: URL) throws -> WatchRecordingInfo {
    let info: WatchRecordingInfo = try watchValue(type: WatchRecordingInfo.self, data: payload)
    // The ID becomes a file name: only a UUID is accepted.
    guard isValidWatchRecordingID(id: info.id) else {
        throw WatchInboxError.invalidRecordingID
    }
    let size: Int = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0 else {
        throw WatchInboxError.emptyAudio
    }
    let manager: FileManager = FileManager.default
    try manager.createDirectory(at: inbox, withIntermediateDirectories: true)
    let audio: URL = watchInboxAudioURL(inbox: inbox, id: info.id)
    if manager.fileExists(atPath: audio.path) {
        try manager.removeItem(at: audio)
    }
    try manager.moveItem(at: file, to: audio)
    // The metadata is written last: an entry is listed only once its audio is in place.
    try watchPayload(value: info)[watchPayloadKey]?.write(to: watchInboxMetadataURL(inbox: inbox, id: info.id), options: .atomic)
    return info
}

/// Reads the inbox: every metadata file whose recording ID is a UUID matching its name and whose audio is in place.
/// Oldest recording first.
public func readWatchInbox(inbox: URL) throws -> WatchInboxContents {
    let manager: FileManager = FileManager.default
    guard manager.fileExists(atPath: inbox.path) else {
        return WatchInboxContents(entries: [], unreadable: [])
    }
    let metadataFiles: [URL] = try manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var entries: [WatchRecordingInfo] = []
    var unreadable: [URL] = []
    for metadata in metadataFiles {
        let info: WatchRecordingInfo
        do {
            info = try watchValue(type: WatchRecordingInfo.self, data: try Data(contentsOf: metadata))
        } catch {
            unreadable.append(metadata)
            continue
        }
        let matches: Bool = isValidWatchRecordingID(id: info.id) && metadata.deletingPathExtension().lastPathComponent == info.id
        if matches, manager.fileExists(atPath: watchInboxAudioURL(inbox: inbox, id: info.id).path) {
            entries.append(info)
        } else {
            unreadable.append(metadata)
        }
    }
    return WatchInboxContents(entries: entries.sorted { $0.startedAt < $1.startedAt }, unreadable: unreadable)
}

/// Deletes an inbox entry: audio first, then metadata, so a half-removed entry is never listed.
public func removeWatchInboxEntry(inbox: URL, id: String) throws {
    let manager: FileManager = FileManager.default
    for url in [watchInboxAudioURL(inbox: inbox, id: id), watchInboxMetadataURL(inbox: inbox, id: id)] where manager.fileExists(atPath: url.path) {
        try manager.removeItem(at: url)
    }
}

/// Imports one inbox entry and only then records it as imported. `importAudio` gets the entry's audio, creates and
/// saves the meeting, and must throw when any step fails, the save included. `markImported` (the ledger the Watch reads
/// to delete its own copy) runs only after it returns, so a failed import leaves the inbox audio, the only copy on the
/// iPhone, and the Watch's copy in place. The caller removes the inbox entry after this returns. Rethrows the import's
/// error.
@MainActor
public func importWatchInboxEntry(
    inbox: URL, id: String, importAudio: @MainActor (URL) async throws -> Void, markImported: @MainActor (String) -> Void
) async throws {
    try await importAudio(watchInboxAudioURL(inbox: inbox, id: id))
    markImported(id)
}

/// How long a "Record on Watch" request (Control Center, Action button) waits for the app to come to the front.
public let watchPendingStartWindowSec: TimeInterval = 120

/// A pending "Record on Watch" request still counts at `now`: made within `watchPendingStartWindowSec` (an old one must
/// never start a recording the next time the app opens). Pure function.
public func watchPendingStartIsFresh(requestedAt: Date, now: Date) -> Bool {
    let age: TimeInterval = now.timeIntervalSince(requestedAt)
    return age >= 0 && age <= watchPendingStartWindowSec
}
