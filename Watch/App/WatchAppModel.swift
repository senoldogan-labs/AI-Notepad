import AINotepadWatchLink
import Foundation
import Observation
import os
import WatchConnectivity

/// What went wrong last (shown once on the screen that caused it).
struct WatchProblem: Equatable, Identifiable {
    let id: UUID
    let message: String
}

/// The Watch app's state and its link to the iPhone (WatchConnectivity). The iPhone is the only source of account
/// data: its snapshot is kept here (and only the glance part in the App Group), commands go to it, and recordings made
/// here are sent to it and deleted once it has them. Signing out on the iPhone clears everything of the account here;
/// recordings not yet sent stay (they carry their account and the iPhone imports them only into it).
@MainActor
@Observable
final class WatchAppModel: NSObject {
    static let shared: WatchAppModel = WatchAppModel()

    nonisolated private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.watch", category: "Model")
    private static let snapshotKey: String = "snapshot"
    private static let markedDoneKey: String = "markedDone"
    private static let doneOutboxKey: String = "doneMarkOutbox"
    /// Done marks kept for an account that is not shown now (`watchDoneMarksAdding`).
    private static let doneOutboxLimit: Int = 100
    private static let recordingsKey: String = "recordings"
    /// ID of the recording running now (cleared when it is finished and listed).
    private static let runningRecordingKey: String = "runningRecording"

    /// The iPhone's last snapshot (`.signedOut` until the iPhone answers once).
    private(set) var snapshot: WatchSnapshot
    /// Tasks marked done here by a build before the outbox and not yet reflected by a newer snapshot.
    private(set) var markedDone: Set<String>
    /// Tasks marked done here, each with its account, until a snapshot of that account no longer lists them; sent again
    /// whenever the session activates or the iPhone becomes reachable (`watchDoneMarksToSend`).
    private(set) var doneOutbox: [WatchDoneMark]
    /// Finished recordings waiting to reach the iPhone.
    private(set) var recordings: [WatchLocalRecording]
    /// The recording running on the Watch.
    private(set) var active: WatchActiveRecording?
    /// A start is in progress (permission prompt, audio session).
    private(set) var isStarting: Bool = false
    /// The iPhone is reachable now (commands need it; queued transfers do not).
    private(set) var isPhoneReachable: Bool = false
    /// The command to the iPhone on its way; only its own reply or error ends it (`watchSendAfterAnswer`).
    private(set) var sendingRequestID: UUID?
    /// The app's scene is active (the microphone can start only then).
    @ObservationIgnored private var isActive: Bool = false
    var problem: WatchProblem?

    @ObservationIgnored private let recorder: WatchRecorder = WatchRecorder()
    /// Recordings whose capture is being compressed now (one compression per recording).
    @ObservationIgnored private var compressing: Set<String> = []
    @ObservationIgnored private let session: WCSession = WCSession.default

    override private init() {
        let defaults: UserDefaults = UserDefaults.standard
        snapshot = Self.decoded(type: WatchSnapshot.self, data: defaults.data(forKey: Self.snapshotKey)) ?? .signedOut
        markedDone = Set(defaults.stringArray(forKey: Self.markedDoneKey) ?? [])
        doneOutbox = Self.decoded(type: [WatchDoneMark].self, data: defaults.data(forKey: Self.doneOutboxKey)) ?? []
        recordings = Self.decoded(type: [WatchLocalRecording].self, data: defaults.data(forKey: Self.recordingsKey)) ?? []
        super.init()
        recorder.onSystemStop = { [weak self] (reason: WatchSystemStop) in
            self?.finishAfterSystemStop(reason: reason)
        }
        recoverCutOffRecording()
        // The glance never shows a timer of a recording that is no longer running (after a crash).
        refreshGlance()
    }

    private func finishAfterSystemStop(reason: WatchSystemStop) {
        finishRecording(interrupted: reason != .limitReached)
        let message: String = switch reason {
        case .limitReached:
            String(localized: "Toplantı süre hakkına ulaşıldı; kayıt bitirildi ve iPhone'a gidecek.")
        case .interrupted:
            String(localized: "Kayıt bir arama ya da Siri yüzünden bitti; kaydedilen kısım iPhone'a gidecek.")
        case .lowBattery:
            String(localized: "Pil azaldığı için kayıt bitirildi; kaydedilen kısım iPhone'a gidecek.")
        case .failed:
            String(localized: "Kayıt beklenmedik biçimde durdu; kaydedilen kısım iPhone'a gidecek.")
        }
        problem = WatchProblem(id: UUID(), message: message)
        watchNotifyRecordingEnded(message: message)
    }

    /// A recording cut off by the app being stopped mid-way (a crash, the battery running out, a force quit) never
    /// reached the list. Its CAF capture keeps what was written, so it is listed as interrupted and sent like any other;
    /// only a capture that cannot be read is deleted, and the user is told either way. No other file is touched.
    private func recoverCutOffRecording() {
        guard let data = UserDefaults.standard.data(forKey: Self.runningRecordingKey) else {
            return
        }
        UserDefaults.standard.removeObject(forKey: Self.runningRecordingKey)
        guard let running = Self.decoded(type: WatchRecordingInfo.self, data: data), isValidWatchRecordingID(id: running.id),
              !recordings.contains(where: { $0.id == running.id }) else {
            return
        }
        let capture: URL
        do {
            capture = try recordingFiles(id: running.id).capture
        } catch {
            Self.logger.error("Watch recordings directory could not be opened, error: \(String(describing: error), privacy: .public)")
            return
        }
        do {
            let seconds: Double = try WatchRecorder.recordedSeconds(capture: capture)
            guard seconds > 0 else {
                throw WatchRecorderError.recorderRefused
            }
            let info: WatchRecordingInfo = WatchRecordingInfo(
                id: running.id, title: running.title, startedAt: running.startedAt, durationSec: seconds, accountTag: running.accountTag, interrupted: true
            )
            recordings.append(WatchLocalRecording(info: info, state: .compressing))
            persist()
            Self.logger.info("Cut-off Watch recording recovered, recording: \(running.id, privacy: .public), seconds: \(Int(seconds), privacy: .public)")
            problem = WatchProblem(id: UUID(), message: String(localized: "Önceki saat kaydı yarıda kesildi; kaydedilen kısım iPhone'a gidecek."))
        } catch {
            Self.logger.error("Cut-off Watch recording cannot be read, recording: \(running.id, privacy: .public), error: \(String(describing: error), privacy: .public)")
            do {
                if FileManager.default.fileExists(atPath: capture.path) {
                    try FileManager.default.removeItem(at: capture)
                }
            } catch {
                Self.logger.error("Unreadable Watch capture could not be deleted, error: \(String(describing: error), privacy: .public)")
            }
            problem = WatchProblem(id: UUID(), message: String(localized: "Önceki saat kaydı yarıda kesildi ve kaydedilemedi."))
        }
    }

    /// Activates WatchConnectivity (at launch, also a background launch for a transfer).
    func activate() {
        #if DEBUG
        let demo: WatchDemoOptions = WatchDemoOptions.current
        if demo.sample {
            // Simulator check (WatchDemo.swift): sample data in memory only, WatchConnectivity stays off.
            snapshot = watchDemoSnapshot(now: Date(), recordingEnabled: !demo.recordingDisabled)
            recordings = watchDemoRecordings(now: Date())
            if demo.startRecording {
                startWatchRecording(title: "Design review")
            }
            return
        }
        if demo.startRecording {
            startWatchRecording(title: "")
        }
        #endif
        guard WCSession.isSupported() else {
            Self.logger.error("WatchConnectivity is not supported")
            return
        }
        session.delegate = self
        session.activate()
    }

    /// True while WatchConnectivity still has content to deliver (a background task waits for it).
    var hasContentPending: Bool {
        session.hasContentPending
    }

    // MARK: Snapshot

    /// The open tasks shown (marked-done ones hidden at once).
    var visibleTasks: [WatchTask] {
        watchVisibleTasks(tasks: snapshot.tasks, markedDone: watchHiddenTaskIDs(markedDone: markedDone, outbox: doneOutbox, snapshotAccountTag: snapshot.accountTag))
    }

    /// A command to the iPhone is on its way.
    var isSending: Bool {
        sendingRequestID != nil
    }

    private func apply(snapshot incoming: WatchSnapshot) {
        let newSnapshot: WatchSnapshot = watchMergedSnapshot(previous: snapshot, incoming: incoming)
        let accountChanged: Bool = newSnapshot.accountTag != snapshot.accountTag
        snapshot = newSnapshot
        markedDone = watchPendingDoneMarks(markedDone: markedDone, snapshotTasks: newSnapshot.tasks)
        doneOutbox = watchDoneMarksAfterSnapshot(outbox: doneOutbox, snapshot: newSnapshot)
        // A transfer the iPhone could not keep shows the iPhone's reason (only the transfer the report names).
        recordings = watchRecordingsAfterReports(recordings: recordings, reports: newSnapshot.imports)
        // The iPhone holds these recordings safely now: the Watch copies go (with any transfer still queued).
        for recordingID in watchRecordingsHeldByPhone(recordings: recordings, reports: newSnapshot.imports) {
            cancelTransfers(recordingID: recordingID)
            remove(recordingID: recordingID)
        }
        persist()
        refreshGlance()
        // Marks made for this account while another one was shown go now.
        if accountChanged {
            sendPendingDoneMarks()
        }
    }

    /// Stores the snapshot (signed out: nothing of the account) and the marks.
    private func persist() {
        #if DEBUG
        // The Simulator's sample data (WatchDemo.swift) stays in memory: it must never reach a later real launch.
        guard !WatchDemoOptions.current.sample else {
            return
        }
        #endif
        let defaults: UserDefaults = UserDefaults.standard
        do {
            defaults.set(try watchPayload(value: snapshot)[watchPayloadKey], forKey: Self.snapshotKey)
            defaults.set(try watchPayload(value: recordings)[watchPayloadKey], forKey: Self.recordingsKey)
        } catch {
            Self.logger.error("Watch state could not be saved, error: \(String(describing: error), privacy: .public)")
        }
        defaults.set(Array(markedDone), forKey: Self.markedDoneKey)
        do {
            defaults.set(try watchPayload(value: doneOutbox)[watchPayloadKey], forKey: Self.doneOutboxKey)
        } catch {
            Self.logger.error("Watch done marks could not be saved, error: \(String(describing: error), privacy: .public)")
        }
    }

    private func refreshGlance() {
        let recording: WatchGlanceRecording? = active.map { WatchGlanceRecording(timerStart: $0.startedAt, pausedAt: nil) }
        saveWatchGlance(state: watchGlanceState(snapshot: snapshot, watchRecording: recording))
    }

    private static func decoded<Value: Decodable>(type: Value.Type, data: Data?) -> Value? {
        guard let data else {
            return nil
        }
        do {
            return try watchValue(type: type, data: data)
        } catch {
            // An older format: the iPhone sends a fresh snapshot on the next contact.
            logger.error("Stored Watch state could not be read, error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: Recording on the Watch

    /// Starts recording on the Watch under `title` (empty: a new note). Needs a linked, signed-in iPhone account with
    /// Watch recording switched on: the recording belongs to that account.
    func startWatchRecording(title: String) {
        guard active == nil, !isStarting else {
            return
        }
        guard snapshot.signedIn, let accountTag = snapshot.accountTag else {
            problem = WatchProblem(id: UUID(), message: String(localized: "Önce iPhone'da Gistsmith'i aç ve giriş yap."))
            return
        }
        guard watchCanRecord(snapshot: snapshot) else {
            problem = WatchProblem(id: UUID(), message: String(localized: "Saatte kayıt henüz açılmadı. Şimdilik iPhone'da kaydet."))
            return
        }
        guard !watchAllowanceTooShort(maxMeetingMinutes: snapshot.maxMeetingMinutes) else {
            problem = WatchProblem(id: UUID(), message: String(localized: "Bu ay için toplantı süren bitti; kayıt başlamadı."))
            return
        }
        isStarting = true
        Task {
            defer { isStarting = false }
            let id: String = UUID().uuidString
            do {
                let file: URL = try WatchRecorder.recordingsDirectory().appending(path: watchCaptureFileName(id: id))
                try await recorder.start(file: file, limitSec: watchRecordingLimitSec(maxMeetingMinutes: snapshot.maxMeetingMinutes))
                let started: WatchActiveRecording = WatchActiveRecording(id: id, title: title, accountTag: accountTag, startedAt: Date(), file: file)
                active = started
                // Kept while it runs: if the app is killed, the next launch lists what the capture holds.
                let running: WatchRecordingInfo = WatchRecordingInfo(
                    id: id, title: title, startedAt: started.startedAt, durationSec: 0, accountTag: accountTag, interrupted: true
                )
                UserDefaults.standard.set(try watchPayload(value: running)[watchPayloadKey], forKey: Self.runningRecordingKey)
                refreshGlance()
                watchRequestStopNotifications()
            } catch WatchRecorderError.microphoneDenied {
                problem = WatchProblem(id: UUID(), message: String(localized: "Mikrofon izni yok. Saatte Ayarlar › Gizlilik › Mikrofon'dan Gistsmith'e izin ver."))
            } catch WatchRecorderError.notEnoughSpace {
                problem = WatchProblem(id: UUID(), message: String(localized: "Saatte yer kalmadı. Yer açıp yeniden dene."))
            } catch {
                Self.logger.error("Watch recording could not start, error: \(String(describing: error), privacy: .public)")
                problem = WatchProblem(id: UUID(), message: String(localized: "Kayıt başlamadı. Başka bir uygulama mikrofonu kullanıyor olabilir; yeniden dene."))
            }
        }
    }

    /// "End": the capture is closed, listed and sent. A message wakes the iPhone app now, while the Watch is reachable,
    /// so it is running when the file arrives.
    func endWatchRecording() {
        recorder.stop()
        finishRecording(interrupted: false)
        requestRefresh()
    }

    private func finishRecording(interrupted: Bool) {
        guard let active else {
            return
        }
        self.active = nil
        let info: WatchRecordingInfo = WatchRecordingInfo(
            id: active.id, title: active.title, startedAt: active.startedAt, durationSec: active.activeSec(now: Date()), accountTag: active.accountTag,
            interrupted: interrupted
        )
        recordings.append(WatchLocalRecording(info: info, state: .compressing))
        persist()
        UserDefaults.standard.removeObject(forKey: Self.runningRecordingKey)
        refreshGlance()
        prepareAndTransfer(info: info)
    }

    private func recordingFiles(id: String) throws -> (capture: URL, sent: URL) {
        let directory: URL = try WatchRecorder.recordingsDirectory()
        return (directory.appending(path: watchCaptureFileName(id: id)), directory.appending(path: watchRecordingFileName(id: id)))
    }

    /// Sends a recording: compresses its capture first when the `.m4a` is not there yet (the capture is deleted once
    /// the compressed copy is in place). A recording with neither file stays "Couldn't send" for the user to delete.
    private func prepareAndTransfer(info: WatchRecordingInfo) {
        guard !compressing.contains(info.id) else {
            return
        }
        let files: (capture: URL, sent: URL)
        do {
            files = try recordingFiles(id: info.id)
        } catch {
            Self.logger.error("Watch recordings directory could not be opened, error: \(String(describing: error), privacy: .public)")
            advance(recordingID: info.id, event: .preparationFailed)
            return
        }
        let manager: FileManager = FileManager.default
        if manager.fileExists(atPath: files.sent.path) {
            transfer(info: info)
            return
        }
        guard manager.fileExists(atPath: files.capture.path) else {
            Self.logger.error("Watch recording audio is missing, recording: \(info.id, privacy: .public)")
            advance(recordingID: info.id, event: .preparationFailed)
            return
        }
        compressing.insert(info.id)
        advance(recordingID: info.id, event: .compressionStarted)
        Task {
            defer { compressing.remove(info.id) }
            var compressed: Double?
            var failure: (any Error)?
            do {
                compressed = try await WatchRecorder.compress(capture: files.capture, output: files.sent)
            } catch {
                failure = error
            }
            // Deleted while it was being compressed: whatever the compression left (the capture, a whole or partial
            // `.m4a`) goes too, so no audio of a deleted recording stays on the Watch.
            guard recordings.contains(where: { $0.id == info.id }) else {
                for leftover in [files.capture, files.sent] where FileManager.default.fileExists(atPath: leftover.path) {
                    do {
                        try FileManager.default.removeItem(at: leftover)
                    } catch {
                        Self.logger.error("Audio of a recording deleted during compression could not be removed, recording: \(info.id, privacy: .public), error: \(String(describing: error), privacy: .public)")
                    }
                }
                return
            }
            guard let seconds = compressed else {
                Self.logger.error("Watch recording could not be compressed, recording: \(info.id, privacy: .public), error: \(String(describing: failure), privacy: .public)")
                advance(recordingID: info.id, event: .preparationFailed)
                return
            }
            do {
                try FileManager.default.removeItem(at: files.capture)
            } catch {
                Self.logger.error("Watch recording capture could not be removed after compression, recording: \(info.id, privacy: .public), error: \(String(describing: error), privacy: .public)")
                advance(recordingID: info.id, event: .preparationFailed)
                return
            }
            Self.logger.info("Watch recording compressed, recording: \(info.id, privacy: .public), seconds: \(Int(seconds), privacy: .public)")
            transfer(info: info)
        }
    }

    /// Queues the recording's `.m4a` for the iPhone (delivered when it is near, also after either app quits) under a new
    /// transfer token: the transfer's end and the iPhone's report count only for this token. An earlier queued transfer
    /// of the same recording is cancelled first, so a retry never sends it twice. Before activation nothing is queued:
    /// the recording shows "Connecting to iPhone" (not "Preparing") and `requeueLostTransfers` queues it once the session
    /// is active.
    private func transfer(info: WatchRecordingInfo) {
        guard session.activationState == .activated else {
            advance(recordingID: info.id, event: .sessionInactive)
            return
        }
        cancelTransfers(recordingID: info.id)
        let token: String = UUID().uuidString
        do {
            var metadata: [String: Data] = try watchPayload(value: info)
            metadata[watchTransferTokenKey] = try watchPayload(value: token)[watchPayloadKey]
            session.transferFile(try recordingFiles(id: info.id).sent, metadata: metadata)
            advance(recordingID: info.id, event: .queued(transferToken: token))
        } catch {
            Self.logger.error("Watch recording could not be queued, error: \(String(describing: error), privacy: .public)")
            advance(recordingID: info.id, event: .preparationFailed)
        }
    }

    /// "Send again" for a failed transfer, or one the iPhone has not confirmed (the iPhone skips a repeat).
    func retry(recordingID: String) {
        guard let recording = recordings.first(where: { $0.id == recordingID }) else {
            return
        }
        prepareAndTransfer(info: recording.info)
        requestRefresh()
    }

    /// Deletes a recording that has not reached the iPhone (the audio is gone).
    func delete(recordingID: String) {
        cancelTransfers(recordingID: recordingID)
        remove(recordingID: recordingID)
    }

    /// Cancels the queued transfers of a recording, named by the recording ID in their metadata.
    private func cancelTransfers(recordingID: String) {
        guard session.activationState == .activated else {
            return
        }
        for transfer in session.outstandingFileTransfers where Self.transferIdentity(metadata: transfer.file.metadata)?.recordingID == recordingID {
            transfer.cancel()
        }
    }

    /// The recording ID and token of a file transfer, read from its metadata; nil when the metadata cannot be read. A
    /// transfer queued by the first Watch build has no token: its token is empty (`watchTransferState(legacy:)`).
    nonisolated static func transferIdentity(metadata: [String: Any]?) -> WatchTransferIdentity? {
        do {
            let info: WatchRecordingInfo = try watchValue(type: WatchRecordingInfo.self, data: metadata?[watchPayloadKey] as? Data)
            let tokenData: Data? = metadata?[watchTransferTokenKey] as? Data
            let token: String = try tokenData.map { (data: Data) -> String in try watchValue(type: String.self, data: data) } ?? ""
            return WatchTransferIdentity(recordingID: info.id, token: token)
        } catch {
            logger.error("Watch transfer metadata could not be read, error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func remove(recordingID: String) {
        recordings.removeAll { $0.id == recordingID }
        persist()
        do {
            let files: (capture: URL, sent: URL) = try recordingFiles(id: recordingID)
            for file in [files.capture, files.sent] where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            Self.logger.error("Watch recording file could not be deleted, error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Moves one recording's transfer state (`watchTransferNext`) and stores the list.
    private func advance(recordingID: String, event: WatchTransferEvent) {
        recordings = recordings.map { (recording: WatchLocalRecording) -> WatchLocalRecording in
            recording.id == recordingID ? WatchLocalRecording(info: recording.info, state: watchTransferNext(state: recording.state, event: event)) : recording
        }
        persist()
    }

    /// At activation and whenever the app opens: recordings not compressed yet, whose transfer is no longer queued (the
    /// app quit before queuing) or whose last transfer failed are prepared and queued again. WatchConnectivity does not
    /// retry a failed transfer itself.
    private func requeueLostTransfers() {
        guard session.activationState == .activated else {
            return
        }
        let queued: Set<String> = Set(session.outstandingFileTransfers.compactMap { Self.transferIdentity(metadata: $0.file.metadata)?.token })
        for info in watchRecordingsToRequeue(recordings: recordings, queuedTokens: queued) {
            prepareAndTransfer(info: info)
        }
    }

    // MARK: Commands to the iPhone

    /// Sends a command to the iPhone and waits for its reply; a reply other than "done" is shown as a problem.
    func send(request: WatchRequest) {
        guard session.activationState == .activated, session.isReachable else {
            problem = WatchProblem(id: UUID(), message: String(localized: "iPhone'a ulaşılamıyor. Yakında ve açık olduğundan emin ol."))
            return
        }
        let payload: [String: Data]
        do {
            payload = try watchPayload(value: request)
        } catch {
            Self.logger.error("Watch request could not be encoded, error: \(String(describing: error), privacy: .public)")
            return
        }
        Self.sendMessage(session: session, payload: payload, model: self, requestID: beginRequest())
    }

    /// Starts a new request (it replaces one still waiting, whose late answer is then ignored) and returns its ID.
    func beginRequest() -> UUID {
        let requestID: UUID = UUID()
        sendingRequestID = requestID
        return requestID
    }

    /// Sends the message from outside the main actor: WatchConnectivity calls the reply and error blocks on a
    /// background queue, and a block written inside this `@MainActor` class would be main-actor isolated, which the
    /// Swift 6 runtime traps on (it crashed the app in the paired Simulator). The results go back to the main actor.
    nonisolated private static func sendMessage(session: WCSession, payload: [String: Data], model: WatchAppModel, requestID: UUID) {
        session.sendMessage(payload, replyHandler: replyHandler(model: model, requestID: requestID), errorHandler: errorHandler(model: model, requestID: requestID))
    }

    /// The reply block: called by WatchConnectivity on its own queue (`WatchModelIsolationTests` calls it from a
    /// background queue). It reads plain values there and hands them to the main actor, bound to `requestID`.
    nonisolated static func replyHandler(model: WatchAppModel, requestID: UUID) -> @Sendable ([String: Any]) -> Void {
        { (reply: [String: Any]) in
            let data: Data? = reply[watchPayloadKey] as? Data
            Task { @MainActor in
                model.finishSend(requestID: requestID, replyData: data)
            }
        }
    }

    /// The error block, like `replyHandler(model:requestID:)`.
    nonisolated static func errorHandler(model: WatchAppModel, requestID: UUID) -> @Sendable (any Error) -> Void {
        { (error: any Error) in
            let description: String = String(describing: error)
            Task { @MainActor in
                model.failSend(requestID: requestID, errorDescription: description)
            }
        }
    }

    /// Ends the request `requestID` with its reply; a late reply of an older request changes nothing.
    private func finishSend(requestID: UUID, replyData: Data?) {
        let transition: WatchSendTransition = watchSendAfterAnswer(sendingRequestID: sendingRequestID, answeredRequestID: requestID)
        sendingRequestID = transition.sendingRequestID
        guard transition.publishes else {
            Self.logger.info("Late reply of an earlier Watch request ignored")
            return
        }
        do {
            handle(reply: try watchValue(type: WatchReply.self, data: replyData))
        } catch {
            Self.logger.error("iPhone reply could not be read, error: \(String(describing: error), privacy: .public)")
            problem = WatchProblem(id: UUID(), message: String(localized: "iPhone'daki Gistsmith'i güncelle."))
        }
    }

    private func failSend(requestID: UUID, errorDescription: String) {
        let transition: WatchSendTransition = watchSendAfterAnswer(sendingRequestID: sendingRequestID, answeredRequestID: requestID)
        sendingRequestID = transition.sendingRequestID
        Self.logger.error("iPhone request failed, error: \(errorDescription, privacy: .public)")
        guard transition.publishes else {
            return
        }
        problem = WatchProblem(id: UUID(), message: String(localized: "iPhone'a ulaşılamıyor. Yakında ve açık olduğundan emin ol."))
    }

    private func handle(reply: WatchReply) {
        switch reply {
        case .done:
            return
        case .phoneAppNotOpen:
            problem = WatchProblem(id: UUID(), message: String(localized: "iPhone'da Gistsmith'i aç ya da kaydı saatte başlat."))
        case .signedOut:
            problem = WatchProblem(id: UUID(), message: String(localized: "Önce iPhone'da Gistsmith'i aç ve giriş yap."))
        case .recordingChanged:
            problem = WatchProblem(id: UUID(), message: String(localized: "iPhone'daki kayıt değişti."))
        case .accountChanged:
            // The iPhone sends the loaded account's snapshot with this reply.
            problem = WatchProblem(id: UUID(), message: String(localized: "iPhone'daki hesap değişti. Yeniden dene."))
        case .failed(let reason):
            problem = WatchProblem(id: UUID(), message: reason)
        }
    }

    /// Marks a task done for the account shown: hidden at once; the mark stays in the outbox and reaches the iPhone when
    /// it is near (queued), also when the session was not active yet.
    func completeTask(task: WatchTask) {
        guard let accountTag = snapshot.accountTag else {
            return
        }
        let mark: WatchDoneMark = WatchDoneMark(meetingID: task.meetingID, taskKey: task.taskKey, accountTag: accountTag)
        doneOutbox = watchDoneMarksAdding(outbox: doneOutbox, mark: mark, limit: Self.doneOutboxLimit)
        persist()
        sendPendingDoneMarks()
    }

    /// Queues the outbox marks of the account shown that are not queued already (`watchDoneMarksToSend`). Called when a
    /// mark is made, when the session activates, when the iPhone becomes reachable, when the app opens and when the
    /// account shown changes.
    private func sendPendingDoneMarks() {
        guard session.activationState == .activated else {
            return
        }
        let queued: Set<WatchDoneMark> = Set(session.outstandingUserInfoTransfers.compactMap { (transfer: WCSessionUserInfoTransfer) -> WatchDoneMark? in
            Self.doneMark(userInfo: transfer.userInfo)
        })
        for mark in watchDoneMarksToSend(outbox: doneOutbox, snapshotAccountTag: snapshot.accountTag, queued: queued) {
            do {
                session.transferUserInfo(try watchPayload(value: mark.request))
            } catch {
                Self.logger.error("Task mark could not be encoded, error: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The done mark a queued user info carries; nil for anything else.
    private static func doneMark(userInfo: [String: Any]) -> WatchDoneMark? {
        do {
            return watchDoneMark(request: try watchValue(type: WatchRequest.self, data: userInfo[watchPayloadKey] as? Data))
        } catch {
            logger.error("Queued Watch user info could not be read, error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func receive(payload data: Data?) {
        do {
            apply(snapshot: try watchValue(type: WatchSnapshot.self, data: data))
        } catch {
            Self.logger.error("iPhone snapshot could not be read, error: \(String(describing: error), privacy: .public)")
        }
    }
}

extension WatchAppModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        if let error {
            Self.logger.error("WatchConnectivity activation failed, error: \(String(describing: error), privacy: .public)")
        }
        let context: Data? = session.receivedApplicationContext[watchPayloadKey] as? Data
        let reachable: Bool = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if context != nil {
                self.receive(payload: context)
            }
            self.requeueLostTransfers()
            self.sendPendingDoneMarks()
            if reachable {
                self.requestRefresh()
            }
        }
    }

    /// The app opened: a pending "Record on Watch" starts, failed or lost transfers are queued again and the iPhone is
    /// asked for a fresh snapshot.
    func appBecameActive() {
        isActive = true
        startPendingRecordingIfActive()
        requeueLostTransfers()
        sendPendingDoneMarks()
        requestRefresh()
    }

    func appLeftForeground() {
        isActive = false
    }

    /// Starts the recording a "Record on Watch" control asked for, once the app is on screen; a stale request is dropped.
    func startPendingRecordingIfActive() {
        guard isActive else {
            return
        }
        let defaults: UserDefaults
        do {
            defaults = try watchGroupDefaults()
        } catch {
            Self.logger.error("App Group is not available, error: \(String(describing: error), privacy: .public)")
            return
        }
        guard let requestedAt = defaults.object(forKey: watchPendingStartKey) as? Date else {
            return
        }
        defaults.removeObject(forKey: watchPendingStartKey)
        if watchPendingStartIsFresh(requestedAt: requestedAt, now: Date()) {
            startWatchRecording(title: "")
        }
    }

    /// Asks the iPhone for a fresh snapshot. A message from the Watch also wakes the iPhone app in the background
    /// (WatchConnectivity), which then receives the queued recordings and confirms them in its snapshot; background
    /// transfers alone may wait until the iPhone app runs.
    func requestRefresh() {
        guard session.activationState == .activated, session.isReachable else {
            return
        }
        do {
            Self.sendRefresh(session: session, payload: try watchPayload(value: WatchRequest.refresh))
        } catch {
            Self.logger.error("Refresh request could not be encoded, error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Outside the main actor for the same reason as `sendMessage(session:payload:model:)`.
    nonisolated private static func sendRefresh(session: WCSession, payload: [String: Data]) {
        session.sendMessage(payload, replyHandler: nil) { (error: any Error) in
            logger.info("Refresh request failed, error: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable: Bool = session.isReachable
        Task { @MainActor in
            self.isPhoneReachable = reachable
            if reachable {
                self.sendPendingDoneMarks()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data: Data? = applicationContext[watchPayloadKey] as? Data
        Task { @MainActor in
            self.receive(payload: data)
        }
    }

    /// Complication user info: the iPhone's recording started or stopped (the glance is redrawn).
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let data: Data? = userInfo[watchPayloadKey] as? Data
        Task { @MainActor in
            self.receive(payload: data)
        }
    }

    /// A transfer ended. It is matched by the recording ID and token in its metadata: a cancelled older transfer of the
    /// same recording that reports late changes nothing (`watchTransferNext`).
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        guard let identity = Self.transferIdentity(metadata: fileTransfer.file.metadata) else {
            return
        }
        let failure: String? = error.map { String(describing: $0) }
        Task { @MainActor in
            if let failure {
                Self.logger.error("Watch recording transfer failed, recording: \(identity.recordingID, privacy: .public), error: \(failure, privacy: .public)")
                self.advance(recordingID: identity.recordingID, event: .transferFailed(transferToken: identity.token))
            } else {
                // Delivered; the copy stays until the iPhone's snapshot lists the recording as held. The message wakes
                // the iPhone app so it takes the file now rather than the next time it is opened.
                self.advance(recordingID: identity.recordingID, event: .transferFinished(transferToken: identity.token))
                self.requestRefresh()
            }
        }
    }
}

/// Which recording and which of its transfers a WatchConnectivity file transfer is (from its metadata).
struct WatchTransferIdentity: Sendable, Equatable {
    let recordingID: String
    let token: String
}
