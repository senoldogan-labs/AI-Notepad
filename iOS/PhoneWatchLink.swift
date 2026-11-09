import AINotepadCore
import AINotepadWatchLink
import Foundation
import os
import UIKit
import WatchConnectivity
import WidgetKit

/// The iPhone's side of the Apple Watch app (WatchConnectivity; design in
/// docs/superpowers/specs/2026-11-08-apple-watch.md). A thin adapter: the snapshot the Watch sees is derived from the
/// recorder's single state, the calendar, the tasks and the account (`watchPhoneRecording`, `watchMeetings`,
/// `watchTasks`); commands go to the existing `PhoneRecorder` and `PhoneStore` methods. The Watch never talks to the
/// server and holds no secret. Watch recordings land in a durable inbox (`Application Support/WatchInbox`) before the
/// delegate returns and are imported only into the account they were made for, once each.
@MainActor
final class PhoneWatchLink: NSObject {
    nonisolated private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "WatchLink")
    /// Open tasks sent to the Watch (most urgent first).
    private static let taskLimit: Int = 20
    /// Meetings sent to the Watch.
    private static let meetingLimit: Int = 6
    /// Task text and meeting titles are cut here (the Watch shows two lines).
    private static let textLimit: Int = 120
    /// Changes are pushed after this pause, so a burst (a note written, a calendar refresh) sends one snapshot.
    private static let pushDelaySec: Double = 1
    /// Imported Watch recording IDs kept to skip a repeated transfer.
    private static let importedLedgerLimit: Int = 200
    private static let importedLedgerKey: String = "watchImportedRecordingIDs"
    /// Imported IDs the Watch is told about (it deletes its copies of these).
    private static let confirmedImportLimit: Int = 50
    /// Watch recordings that could not be imported (ID → reason): kept in the inbox, retried or deleted from the Watch.
    private static let failuresKey: String = "watchImportFailures"

    private let sessions: PhoneSessionHost
    private let calendar: PhoneCalendar
    private let account: HostedAccount
    /// Nil when this iPhone does not support WatchConnectivity.
    private let session: WCSession?
    /// Gistsmith is in the foreground (only then can a new iPhone recording start from the Watch).
    private var appIsActive: Bool = false
    private var lastPushed: WatchSnapshot?
    private var pushTask: Task<Void, Never>?
    private var isDrainingInbox: Bool = false
    /// A recording arrived (or the account changed) during a pass: one more pass follows.
    private var inboxNeedsAnotherPass: Bool = false
    private var notificationTokens: [NSObjectProtocol] = []
    /// The recordings in the inbox (read at launch and after every change).
    private var inbox: [WatchRecordingInfo] = []

    init(sessions: PhoneSessionHost, calendar: PhoneCalendar, account: HostedAccount) {
        self.sessions = sessions
        self.calendar = calendar
        self.account = account
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    /// Starts the link at launch (also a background launch by the Watch): activates the session, follows the app's
    /// foreground state and the snapshot's inputs, and imports recordings left in the inbox.
    func start() {
        guard let session else {
            Self.logger.info("WatchConnectivity is not supported on this device")
            return
        }
        session.delegate = self
        session.activate()
        appIsActive = UIApplication.shared.applicationState == .active
        let center: NotificationCenter = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] (_: Notification) in
                MainActor.assumeIsolated { self?.appActivityChanged(isActive: true) }
            },
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] (_: Notification) in
                MainActor.assumeIsolated { self?.appActivityChanged(isActive: false) }
            },
        ]
        refreshInbox()
        observeSnapshot()
        drainInbox()
    }

    private func appActivityChanged(isActive: Bool) {
        appIsActive = isActive
        schedulePush()
        if isActive {
            drainInbox()
        }
    }

    // MARK: Snapshot

    /// The snapshot from the current state. Signed out (or no account loaded): the empty snapshot, so nothing of the
    /// account stays on the Watch.
    private func currentSnapshot() -> WatchSnapshot {
        guard let accountTag = loadedAccountTag() else {
            return .signedOut
        }
        let accountSession: PhoneAccountSession = sessions.session
        let recorder: PhoneRecorder = accountSession.recorder
        let store: PhoneStore = accountSession.store
        let now: Date = Date()
        let calendarOn: Bool = calendar.state == .on
        let openTasks: [DatedTask] = openTasksByUrgency(items: myTasks(meetings: store.meetings, userName: store.userName), now: now, calendar: Calendar.current)
        let entitlements: HostedEntitlements? = if case .signedIn(let entitlements) = account.state { entitlements } else { nil }
        return WatchSnapshot(
            signedIn: true, accountTag: accountTag,
            recording: watchPhoneRecording(state: recorder.state, title: recorder.recordingCalendarMeeting?.title ?? ""),
            meetings: calendarOn ? watchMeetings(meetings: calendar.meetings, now: now, calendar: Calendar.current, limit: Self.meetingLimit) : [],
            calendarOn: calendarOn,
            tasks: watchTasks(items: openTasks, limit: Self.taskLimit, maxChars: Self.textLimit),
            maxMeetingMinutes: entitlements?.meetingMaxMinutes, phoneAppOpen: appIsActive,
            receivedRecordingIDs: inbox.map(\.id) + importedLedger().suffix(Self.confirmedImportLimit),
            failedImports: inbox.compactMap { (info: WatchRecordingInfo) -> WatchFailedImport? in
                guard info.accountTag == accountTag, let reason = failures()[info.id] else {
                    return nil
                }
                return WatchFailedImport(id: info.id, title: info.title, reason: reason)
            },
            // Nil until the account is read (launch, offline): the Watch keeps its last known value (`watchMergedSnapshot`).
            watchRecordingEnabled: entitlements.map(hostedWatchRecordingEnabled(entitlements:))
        )
    }

    /// The loaded account's key (an irreversible hash of the user ID) while signed in; nil otherwise.
    private func loadedAccountTag() -> String? {
        guard !account.requiresSignIn, case .loaded(let accountKey) = account.dataState else {
            return nil
        }
        return accountKey
    }

    /// Re-reads the snapshot whenever one of its observable inputs changes (recorder state, meetings, calendar, account).
    private func observeSnapshot() {
        withObservationTracking {
            _ = currentSnapshot()
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedulePush()
                self?.observeSnapshot()
            }
        }
    }

    private func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.pushDelaySec))
            } catch {
                // A newer change replaced this push.
                return
            }
            self?.pushSnapshot()
        }
    }

    /// Sends the snapshot when it changed. A change of the iPhone recording goes as complication user info when a
    /// Gistsmith complication is on the watch face (the Watch wakes and redraws it); everything else as application
    /// context (latest wins). An account change also retries the inbox (recordings waiting for that account).
    private func pushSnapshot() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            return
        }
        let snapshot: WatchSnapshot = currentSnapshot()
        guard snapshot != lastPushed else {
            return
        }
        let previous: WatchSnapshot? = lastPushed
        do {
            let payload: [String: Data] = try watchPayload(value: snapshot)
            let recordingChanged: Bool = previous?.recording?.phase != snapshot.recording?.phase || previous?.recording?.recordingID != snapshot.recording?.recordingID
            if recordingChanged, session.isComplicationEnabled, session.remainingComplicationUserInfoTransfers > 0 {
                session.transferCurrentComplicationUserInfo(payload)
            }
            try session.updateApplicationContext(payload)
            lastPushed = snapshot
        } catch {
            Self.logger.error("Watch snapshot could not be sent, error: \(String(describing: error), privacy: .public)")
        }
        if previous?.accountTag != snapshot.accountTag {
            drainInbox()
        }
    }

    // MARK: Requests

    /// Runs a request from the Watch and returns the reply. Recording commands name the recording they were pressed for:
    /// a stale button never touches a newer recording (`RecorderTarget.recording`).
    private func handle(request: WatchRequest) async -> WatchReply {
        guard loadedAccountTag() != nil else {
            return .signedOut
        }
        let recorder: PhoneRecorder = sessions.session.recorder
        switch request {
        case .startPhoneRecording:
            // iOS refuses the microphone to a background app (AVAudioSession cannotStartRecording).
            guard appIsActive else {
                return .phoneAppNotOpen
            }
            Task { await recorder.start() }
            return .done
        case .pausePhoneRecording(let recordingID):
            guard let id = runningRecording(recordingID: recordingID) else {
                return .recordingChanged
            }
            recorder.pause(target: .recording(id))
            return .done
        case .resumePhoneRecording(let recordingID):
            guard let id = runningRecording(recordingID: recordingID) else {
                return .recordingChanged
            }
            recorder.resume(target: .recording(id))
            return .done
        case .stopPhoneRecording(let recordingID):
            guard let id = runningRecording(recordingID: recordingID) else {
                return .recordingChanged
            }
            recorder.stop(target: .recording(id))
            return .done
        case .completeTask(let meetingID, let taskKey):
            let store: PhoneStore = sessions.session.store
            // A background launch by the Watch: the account's meetings are read first.
            if !store.isLoaded {
                store.loadIdentity()
                await store.reloadAndWait()
            }
            store.completeTaskFromNotification(meetingID: meetingID, taskKey: taskKey)
            return .done
        case .retryImport(let recordingID):
            setFailure(recordingID: recordingID, reason: nil)
            drainInbox()
            return .done
        case .deleteImport(let recordingID):
            // Only a failed import of this account can be deleted from the Watch.
            guard isValidWatchRecordingID(id: recordingID), failures()[recordingID] != nil,
                  let info = inbox.first(where: { $0.id == recordingID }), info.accountTag == loadedAccountTag() else {
                return .done
            }
            removeInboxEntry(id: recordingID)
            setFailure(recordingID: recordingID, reason: nil)
            refreshInbox()
            schedulePush()
            return .done
        case .refresh:
            lastPushed = nil
            pushSnapshot()
            // The Watch also asks after a transfer finished: recordings that arrived while the app slept are imported
            // (and confirmed in the next snapshot).
            drainInbox()
            return .done
        }
    }

    private func runningRecording(recordingID: String) -> RecordingID? {
        let id: RecordingID = RecordingID(rawValue: recordingID)
        return sessions.session.recorder.recordingID == id ? id : nil
    }

    // MARK: Watch recordings

    /// The inbox for Watch recordings in the app's container (not account-scoped: each file names its account).
    nonisolated private static func inboxDirectory() throws -> URL {
        let directory: URL = URL.applicationSupportDirectory.appending(path: "WatchInbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Imports the inbox's recordings that belong to the loaded account; others wait for their account. One pass at a
    /// time.
    private func drainInbox() {
        guard !isDrainingInbox else {
            inboxNeedsAnotherPass = true
            return
        }
        isDrainingInbox = true
        Task {
            repeat {
                inboxNeedsAnotherPass = false
                await importInbox()
            } while inboxNeedsAnotherPass
            isDrainingInbox = false
        }
    }

    private func refreshInbox() {
        do {
            let contents: WatchInboxContents = try readWatchInbox(inbox: try Self.inboxDirectory())
            for metadata in contents.unreadable {
                Self.logger.error("Watch inbox entry could not be read, file left alone: \(metadata.lastPathComponent, privacy: .public)")
            }
            inbox = contents.entries
        } catch {
            Self.logger.error("Watch inbox could not be read, error: \(String(describing: error), privacy: .public)")
        }
    }

    private func importInbox() async {
        refreshInbox()
        for info in inbox {
            switch watchImportDecision(info: info, loadedAccountTag: loadedAccountTag(), importedIDs: Set(importedLedger())) {
            case .wait:
                Self.logger.info("Watch recording waits for its account, recording: \(info.id, privacy: .public)")
            case .duplicate:
                Self.logger.info("Watch recording already imported, recording: \(info.id, privacy: .public)")
                removeInboxEntry(id: info.id)
            case .importNow where failures()[info.id] != nil:
                // Failed before: waits for "Try again" or "Delete" on the Watch.
                break
            case .importNow:
                await importEntry(info: info)
            }
        }
        refreshInbox()
        schedulePush()
    }

    private func importEntry(info: WatchRecordingInfo) async {
        let title: String = info.title.isEmpty ? String(localized: "Apple Watch kaydı") : info.title
        do {
            let recorder: PhoneRecorder = sessions.session.recorder
            // Marked imported before the long upload and processing: if iOS ends the app during them, the next launch
            // finds the meeting queued and never imports the same audio a second time. Only after the meeting was
            // saved: a failed save throws, and the inbox and Watch copies stay.
            try await importWatchInboxEntry(
                inbox: try Self.inboxDirectory(), id: info.id,
                importAudio: { (audio: URL) async throws -> Void in
                    try await recorder.importWatchRecording(url: audio, title: title, startedAt: info.startedAt)
                },
                markImported: { (id: String) -> Void in self.remember(importedID: id) }
            )
            removeInboxEntry(id: info.id)
            await recorder.runQueue()
        } catch HostedClientError.notSignedIn {
            // Signed out while importing: the recording waits for its account.
            Self.logger.info("Watch recording waits for sign-in, recording: \(info.id, privacy: .public)")
        } catch {
            // The inbox holds the only copy: it stays, the reason shows on the Watch with "Try again" and "Delete" (and in
            // the iPhone's import list).
            Self.logger.error("Watch recording could not be imported, recording: \(info.id, privacy: .public), error: \(String(describing: error), privacy: .public)")
            setFailure(recordingID: info.id, reason: watchImportFailureMessage(error: error))
        }
    }

    private func removeInboxEntry(id: String) {
        do {
            try removeWatchInboxEntry(inbox: try Self.inboxDirectory(), id: id)
        } catch {
            Self.logger.error("Watch inbox entry could not be removed, recording: \(id, privacy: .public), error: \(String(describing: error), privacy: .public)")
        }
    }

    private func importedLedger() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.importedLedgerKey) ?? []
    }

    private func failures() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: Self.failuresKey) as? [String: String]) ?? [:]
    }

    /// Records (or with nil clears) why a Watch recording could not be imported.
    private func setFailure(recordingID: String, reason: String?) {
        var current: [String: String] = failures()
        current[recordingID] = reason
        UserDefaults.standard.set(current, forKey: Self.failuresKey)
    }

    private func remember(importedID: String) {
        let ledger: [String] = importedLedger() + [importedID]
        UserDefaults.standard.set(Array(ledger.suffix(Self.importedLedgerLimit)), forKey: Self.importedLedgerKey)
    }
}

extension PhoneWatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error {
            Self.logger.error("WatchConnectivity activation failed, error: \(String(describing: error), privacy: .public)")
        }
        Task { @MainActor in
            self.lastPushed = nil
            self.pushSnapshot()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Switching to another watch: the session is activated again for the new one.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastPushed = nil
            self.pushSnapshot()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let data: Data? = message[watchPayloadKey] as? Data
        let handler: WatchReplyHandler = WatchReplyHandler(send: replyHandler)
        let reply: @Sendable (WatchReply) -> Void = { (value: WatchReply) in
            do {
                handler.send(try watchPayload(value: value))
            } catch {
                Self.logger.error("Watch reply could not be encoded, error: \(String(describing: error), privacy: .public)")
            }
        }
        let request: WatchRequest
        do {
            request = try watchValue(type: WatchRequest.self, data: data)
        } catch {
            Self.logger.error("Watch request could not be decoded, error: \(String(describing: error), privacy: .public)")
            reply(.failed(reason: String(localized: "iPhone'daki Gistsmith'i güncelle.")))
            return
        }
        Task { @MainActor in
            reply(await self.handle(request: request))
        }
    }

    /// Messages without a reply (the Watch's `refresh`, sent when it opens and after a recording's transfer finished).
    /// Without this method WatchConnectivity drops them ("does not implement delegate method", seen in the paired
    /// Simulator), so the iPhone would not push the snapshot that lets the Watch delete its confirmed copies.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let data: Data? = message[watchPayloadKey] as? Data
        do {
            let request: WatchRequest = try watchValue(type: WatchRequest.self, data: data)
            Task { @MainActor in
                _ = await self.handle(request: request)
            }
        } catch {
            Self.logger.error("Watch message could not be decoded, error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Queued requests (marking a task done): delivered even when the Watch app sent them while the iPhone was away.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let data: Data? = userInfo[watchPayloadKey] as? Data
        do {
            let request: WatchRequest = try watchValue(type: WatchRequest.self, data: data)
            Task { @MainActor in
                _ = await self.handle(request: request)
            }
        } catch {
            Self.logger.error("Watch user info could not be decoded, error: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        do {
            let info: WatchRecordingInfo = try storeWatchRecording(file: file.fileURL, payload: file.metadata?[watchPayloadKey] as? Data, inbox: try Self.inboxDirectory())
            Self.logger.info("Watch recording received, recording: \(info.id, privacy: .public), seconds: \(Int(info.durationSec), privacy: .public)")
            Task { @MainActor in
                self.drainInbox()
            }
        } catch {
            Self.logger.error("Watch recording could not be stored, error: \(String(describing: error), privacy: .public)")
        }
    }
}

/// WatchConnectivity's reply block, carried to the main actor where the request runs. The block itself is not marked
/// Sendable in the SDK, but WatchConnectivity documents that it may be called from any thread, exactly once.
private struct WatchReplyHandler: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}

/// Why a Watch recording could not be imported, as the Watch shows it next to "Try again". A recording longer than the
/// account's meeting allowance is kept, not cut: it can be tried again once the allowance renews (the generic file
/// message would say to split the file, which nobody can do on a watch).
func watchImportFailureMessage(error: any Error) -> String {
    switch error {
    case HostedImportError.longerThanMeetingAllowance(let durationMinutes, let maxMinutes):
        String(localized: "Kayıt \(durationMinutes) dakika; şu an en çok \(maxMinutes) dakikalık bir toplantı işlenebilir. Süre hakkın yenilenince yeniden dene.")
    default:
        mediaImportMessage(error: error)
    }
}
