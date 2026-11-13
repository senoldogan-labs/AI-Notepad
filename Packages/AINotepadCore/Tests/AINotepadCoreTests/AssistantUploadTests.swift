import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

/// A meeting at `startedAt` (seconds since 1970) with the sync sample's note.
private func meeting(id: String, startedAt: Double) -> MeetingRecord {
    let base: MeetingRecord = syncSampleRecord()
    return MeetingRecord(
        id: id, title: "Meeting \(id)", startedAt: Date(timeIntervalSince1970: startedAt), endedAt: Date(timeIntervalSince1970: startedAt + 600), language: .english,
        status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: base.note, audioDeleted: false,
        engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

/// What the fake server saw and what it answers next.
private struct FakeAssistantState {
    var settings: HostedAssistantSettings
    var stored: [String: AssistantMeetingUpload] = [:]
    var calls: [String] = []
    /// Upload answers this error once, then succeeds (`nil`: always succeeds).
    var failNextUpload: HostedAssistantError?
    /// Settings after `failNextUpload` fired (another device turned the feature off and on).
    var settingsAfterFailure: HostedAssistantSettings?
    /// Meeting ids the server refuses with `invalid_body`.
    var invalid: Set<String> = []
}

/// In-memory `/v1/assistant` that checks the epoch like the server does.
private final class FakeAssistantServer: HostedAssistantAPI {
    let state: Mutex<FakeAssistantState>
    /// Runs before each upload (outside the lock), e.g. to press "retry" while a pass is uploading.
    let beforePut: Mutex<(@Sendable () async -> Void)?> = Mutex(nil)

    init(settings: HostedAssistantSettings) {
        state = Mutex(FakeAssistantState(settings: settings))
    }

    func settings() async throws -> HostedAssistantSettings {
        state.withLock { (state: inout FakeAssistantState) -> HostedAssistantSettings in
            state.calls.append("settings")
            return HostedAssistantSettings(enabled: state.settings.enabled, epoch: state.settings.epoch, meetings: state.stored.count, maxMeetings: 5000)
        }
    }

    func setEnabled(enabled: Bool) async throws -> HostedAssistantSettings {
        state.withLock { (state: inout FakeAssistantState) -> HostedAssistantSettings in
            if !enabled, state.settings.enabled {
                state.stored = [:]
                state.settings = HostedAssistantSettings(enabled: false, epoch: state.settings.epoch + 1, meetings: 0, maxMeetings: 5000)
            } else if enabled {
                state.settings = HostedAssistantSettings(enabled: true, epoch: state.settings.epoch, meetings: state.stored.count, maxMeetings: 5000)
            }
            return state.settings
        }
    }

    func putMeeting(meetingID: String, upload: AssistantMeetingUpload) async throws {
        if let hook = beforePut.withLock({ (hook: inout (@Sendable () async -> Void)?) -> (@Sendable () async -> Void)? in
            defer { hook = nil }
            return hook
        }) {
            await hook()
        }
        try state.withLock { (state: inout FakeAssistantState) throws -> Void in
            state.calls.append("put \(meetingID)")
            if let failure = state.failNextUpload {
                state.failNextUpload = nil
                if let next = state.settingsAfterFailure {
                    state.settings = next
                    state.stored = [:]
                }
                throw failure
            }
            if state.invalid.contains(meetingID) {
                throw HostedAPIError(code: .invalidBody, rawCode: "invalid_body", status: 400, serverMessage: "bad", path: "/v1/assistant/meetings/:id")
            }
            guard state.settings.enabled else {
                throw HostedAssistantError.notEnabled
            }
            guard upload.epoch == state.settings.epoch else {
                throw HostedAssistantError.epochMismatch
            }
            state.stored[meetingID] = upload
        }
    }

    func deleteMeeting(meetingID: String) async throws {
        state.withLock { (state: inout FakeAssistantState) -> Void in
            state.calls.append("delete \(meetingID)")
            state.stored[meetingID] = nil
        }
    }

    func grants() async throws -> [HostedAssistantGrant] {
        []
    }

    func deleteGrant(grantID: String) async throws {}

    func deleteDevice(deviceID: String) async throws -> Int {
        state.withLock { (state: inout FakeAssistantState) -> Int in
            let mine: [String] = state.stored.filter { $0.value.deviceId == deviceID }.map(\.key)
            for id in mine {
                state.stored[id] = nil
            }
            return mine.count
        }
    }
}

/// Collects progress callbacks.
private final class ProgressLog: Sendable {
    let values: Mutex<[AssistantUploadProgress]> = Mutex([])

    func add(progress: AssistantUploadProgress) {
        values.withLock { $0.append(progress) }
    }
}

private func temporaryLedger() -> AssistantLedgerFile {
    AssistantLedgerFile(url: FileManager.default.temporaryDirectory.appending(path: "assistant-\(UUID().uuidString)/ledger.json", directoryHint: .notDirectory))
}

private let deviceID: String = "6f1c1b7e-8a8a-4c4c-9d9d-1e1e1e1e1e1e"

@Suite struct AssistantCopyTests {
    // The copy holds the note with speaker names, done marks and the meeting's own fields; never transcript text.
    @Test func copyProjectsNoteOnly() throws {
        let record: MeetingRecord = syncSampleRecord()
        let copy: AssistantMeetingCopy = try #require(assistantMeetingCopy(record: record, userName: "Mehmet"))
        #expect(copy.title == "Budget sync")
        #expect(copy.durationSec == 1800)
        #expect(copy.folder == "Finance")
        #expect(copy.attendees == ["Aino"])
        #expect(copy.language == "en")
        #expect(copy.myNotes == "Ask about Q3\nCheck travel")
        let note: AssistantNoteCopy = try #require(copy.note)
        #expect(note.decisions == ["Budget approved"])
        #expect(note.tasks.map(\.done) == [false, true])
        #expect(note.tasks[1].owner == "Aino")
        #expect(note.outline.map(\.title) == ["Intro"])
        let json: String = String(decoding: try JSONEncoder().encode(AssistantMeetingUpload(epoch: 3, deviceId: deviceID, copy: copy)), as: UTF8.self)
        #expect(!json.contains("Let's approve the budget"))
        #expect(!json.contains("Hyväksytään"))
        #expect(json.contains("\"epoch\":3"))
        #expect(json.contains("\"deviceId\":\"\(deviceID)\""))
        // Present-but-null fields: the server schema requires every key.
        let bare: MeetingRecord = meeting(id: "a", startedAt: 0)
        let bareJSON: String = String(decoding: try JSONEncoder().encode(try #require(assistantMeetingCopy(record: bare, userName: ""))), as: UTF8.self)
        #expect(bareJSON.contains("\"folder\":null"))
        #expect(bareJSON.contains("\"myNotes\":null"))
        #expect(bareJSON.contains("\"dueDate\":null"))
    }

    // The sample meeting, meetings still recording or processing, and meetings without any note stay out.
    @Test func sampleAndUnfinishedMeetingsStayOut() {
        let record: MeetingRecord = syncSampleRecord()
        #expect(assistantMeetingCopy(record: record.markedAsSample(), userName: "") == nil)
        #expect(assistantMeetingCopy(record: record.with(status: .processing, failureMessage: nil), userName: "") == nil)
        let empty: MeetingRecord = MeetingRecord(
            id: "x", title: "x", startedAt: Date(), endedAt: nil, language: nil, status: .failed, failureMessage: "no audio", liveSegments: [], finalSegments: [],
            translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        #expect(assistantMeetingCopy(record: empty, userName: "") == nil)
    }

    // Texts are cut to the server's limits by UTF-16 length without splitting a character.
    @Test func cutRespectsUTF16() {
        #expect(assistantCut(text: "abc", maxUTF16: 5) == "abc")
        #expect(assistantCut(text: "ab😀c", maxUTF16: 3) == "ab")
        #expect(assistantCut(text: "ab😀c", maxUTF16: 4) == "ab😀")
    }

    // An edit changes the fingerprint; the same content keeps it.
    @Test func fingerprintFollowsContent() throws {
        let record: MeetingRecord = syncSampleRecord()
        let first: String = try assistantFingerprint(copy: try #require(assistantMeetingCopy(record: record, userName: "")))
        let same: String = try assistantFingerprint(copy: try #require(assistantMeetingCopy(record: record, userName: "")))
        let edited: String = try assistantFingerprint(copy: try #require(assistantMeetingCopy(record: record.with(myNotes: "Changed"), userName: "")))
        #expect(first == same)
        #expect(first != edited)
    }
}

@Suite struct AssistantPlanTests {
    // Backfill goes newest first; deleted meetings are removed; unchanged and rejected-unchanged ones are skipped.
    @Test func planOrdersNewestFirstAndPropagatesDeletes() throws {
        let local: [AssistantLocalMeeting] = try assistantLocalMeetings(records: [meeting(id: "old", startedAt: 100), meeting(id: "new", startedAt: 300), meeting(id: "mid", startedAt: 200)], userName: "")
        let fresh: AssistantUploadPlan = assistantUploadPlan(local: local, ledger: AssistantUploadLedger(epoch: 1, uploaded: [:], rejected: [:], rejectionReasons: [:], forgetGeneration: 0))
        #expect(fresh.uploads == ["new", "mid", "old"])
        #expect(fresh.deletions.isEmpty)
        let mid: String = try #require(local.first { $0.id == "mid" }).fingerprint
        let old: String = try #require(local.first { $0.id == "old" }).fingerprint
        let ledger: AssistantUploadLedger = AssistantUploadLedger(epoch: 1, uploaded: ["mid": mid, "gone": "x", "new": "stale"], rejected: ["old": old], rejectionReasons: ["old": .tooLarge], forgetGeneration: 0)
        let plan: AssistantUploadPlan = assistantUploadPlan(local: local, ledger: ledger)
        #expect(plan.uploads == ["new"])
        #expect(plan.deletions == ["gone"])
        #expect(assistantUploadProgress(local: local, ledger: ledger) == AssistantUploadProgress(uploaded: 1, rejected: 1, rejectionReason: .tooLarge, total: 3))
    }

    // A new epoch forgets every upload (backfill again); off empties the ledger; same epoch keeps it.
    @Test func epochDecidesLedger() {
        let ledger: AssistantUploadLedger = AssistantUploadLedger(epoch: 2, uploaded: ["a": "f"], rejected: ["b": "g"], rejectionReasons: ["b": .invalid], forgetGeneration: 0)
        #expect(assistantLedger(ledger: ledger, settings: HostedAssistantSettings(enabled: true, epoch: 2, meetings: 1, maxMeetings: 5000)) == ledger)
        #expect(assistantLedger(ledger: ledger, settings: HostedAssistantSettings(enabled: true, epoch: 3, meetings: 0, maxMeetings: 5000))
            == AssistantUploadLedger(epoch: 3, uploaded: [:], rejected: [:], rejectionReasons: [:], forgetGeneration: 0))
        #expect(assistantLedger(ledger: ledger, settings: HostedAssistantSettings(enabled: false, epoch: 3, meetings: 0, maxMeetings: 5000)) == .empty)
    }

    // A grant is new only against a known baseline; the first listing is the baseline.
    @Test func newGrantsNeedABaseline() {
        let grant: HostedAssistantGrant = HostedAssistantGrant(
            grantId: "g1", clientName: "Claude", redirectHost: "claude.ai", verified: true, createdAt: Date(), lastUsedAt: nil, heavyReadAt: nil
        )
        #expect(newAssistantGrants(known: nil, current: [grant]).isEmpty)
        #expect(newAssistantGrants(known: [], current: [grant]) == [grant])
        #expect(newAssistantGrants(known: ["g1"], current: [grant]).isEmpty)
        #expect(assistantGrantDisplayName(grant: grant) == "Claude")
        let unverified: HostedAssistantGrant = HostedAssistantGrant(
            grantId: "g2", clientName: "Claude", redirectHost: "evil.example", verified: false, createdAt: Date(), lastUsedAt: nil, heavyReadAt: nil
        )
        #expect(assistantGrantDisplayName(grant: unverified) == "evil.example")
    }

    // Server grant timestamps carry milliseconds.
    @Test func grantDatesParse() {
        #expect(assistantDate(text: "2026-11-06T09:30:00.123Z") != nil)
        #expect(assistantDate(text: "2026-11-06T09:30:00Z") != nil)
        #expect(assistantDate(text: "yesterday") == nil)
    }
}

@Suite struct AssistantUploaderTests {
    // Backfill uploads newest first, a second pass does nothing, an edit uploads once, a local delete is propagated and
    // the ledger on disk survives a new uploader (an app restart).
    @Test func uploaderBackfillsEditsAndDeletes() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let records: [MeetingRecord] = [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200), syncSampleRecord().markedAsSample()]
        let log: ProgressLog = ProgressLog()
        let first: AssistantPassReport = try await AssistantUploader(client: server, file: file, deviceID: deviceID).pass(records: records, userName: "") { log.add(progress: $0) }
        #expect(first.uploaded == 2)
        #expect(first.progress == AssistantUploadProgress(uploaded: 2, rejected: 0, rejectionReason: nil, total: 2))
        #expect(first.settings.meetings == 2)
        #expect(server.state.withLock { $0.calls.filter { $0.hasPrefix("put") } } == ["put b", "put a"])
        #expect(log.values.withLock { $0 }.first == AssistantUploadProgress(uploaded: 0, rejected: 0, rejectionReason: nil, total: 2))
        #expect(server.state.withLock { $0.stored.keys.sorted() } == ["a", "b"])

        let restarted: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        let idle: AssistantPassReport = try await restarted.pass(records: records, userName: "") { _ in }
        #expect(idle.uploaded == 0 && idle.deleted == 0)

        let edited: [MeetingRecord] = [meeting(id: "a", startedAt: 100).with(myNotes: "New line")]
        let changed: AssistantPassReport = try await restarted.pass(records: edited, userName: "") { _ in }
        #expect(changed.uploaded == 1)
        #expect(changed.deleted == 1)
        #expect(server.state.withLock { $0.stored.keys.sorted() } == ["a"])
        #expect(server.state.withLock { $0.stored["a"]?.copy.myNotes } == "New line")
    }

    // Turned off and on elsewhere mid-pass: the 409 rereads the settings and the whole copy is uploaded again in the
    // new epoch.
    @Test func epochMismatchRestartsInNewEpoch() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let records: [MeetingRecord] = [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)]
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        _ = try await uploader.pass(records: [records[0]], userName: "") { _ in }
        server.state.withLock { (state: inout FakeAssistantState) -> Void in
            state.failNextUpload = .epochMismatch
            state.settingsAfterFailure = HostedAssistantSettings(enabled: true, epoch: 2, meetings: 0, maxMeetings: 5000)
        }
        let report: AssistantPassReport = try await uploader.pass(records: records, userName: "") { _ in }
        #expect(report.uploaded == 2)
        #expect(try await uploader.ledger().epoch == 2)
        #expect(server.state.withLock { $0.stored.values.map(\.epoch) } == [2, 2])
    }

    // Turned off elsewhere: the ledger empties and nothing is uploaded.
    @Test func turnedOffElsewhereEmptiesLedger() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        _ = try await uploader.pass(records: [meeting(id: "a", startedAt: 100)], userName: "") { _ in }
        _ = try await server.setEnabled(enabled: false)
        let report: AssistantPassReport = try await uploader.pass(records: [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)], userName: "") { _ in }
        #expect(!report.settings.enabled)
        #expect(report.uploaded == 0)
        #expect(try await uploader.ledger() == .empty)
    }

    // A copy the server refuses as invalid is skipped (not retried forever) until the meeting changes.
    @Test func refusedCopyWaitsForAChange() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        server.state.withLock { $0.invalid = ["a"] }
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        let records: [MeetingRecord] = [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)]
        let first: AssistantPassReport = try await uploader.pass(records: records, userName: "") { _ in }
        #expect(first.rejected == 1 && first.uploaded == 1)
        // Refused is not up to date: counted apart, with its reason, and nothing is left to upload.
        #expect(first.progress == AssistantUploadProgress(uploaded: 1, rejected: 1, rejectionReason: .invalid, total: 2))
        #expect(first.progress.isComplete)
        let second: AssistantPassReport = try await uploader.pass(records: records, userName: "") { _ in }
        #expect(second.rejected == 0 && second.uploaded == 0)
        #expect(second.progress.rejected == 1)
        server.state.withLock { $0.invalid = [] }
        let changed: AssistantPassReport = try await uploader.pass(records: [records[0].with(myNotes: "fixed"), records[1]], userName: "") { _ in }
        #expect(changed.uploaded == 1)
        #expect(changed.progress == AssistantUploadProgress(uploaded: 2, rejected: 0, rejectionReason: nil, total: 2))
    }

    // "Retry" forgets the refusals: the next pass uploads the unchanged meeting again.
    @Test func retryRejectedUploadsAgain() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        server.state.withLock { $0.invalid = ["a"] }
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        let records: [MeetingRecord] = [meeting(id: "a", startedAt: 100)]
        _ = try await uploader.pass(records: records, userName: "") { _ in }
        server.state.withLock { $0.invalid = [] }
        try await uploader.retryRejected()
        let retried: AssistantPassReport = try await uploader.pass(records: records, userName: "") { _ in }
        #expect(retried.uploaded == 1)
        #expect(retried.progress == AssistantUploadProgress(uploaded: 1, rejected: 0, rejectionReason: nil, total: 1))
        #expect(try await uploader.ledger().rejectionReasons.isEmpty)
    }

    // "Retry" pressed while a pass is uploading is not undone by that pass writing its in-memory ledger.
    @Test func retryDuringPassSticks() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        server.state.withLock { $0.invalid = ["a"] }
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        _ = try await uploader.pass(records: [meeting(id: "a", startedAt: 100)], userName: "") { _ in }
        server.state.withLock { $0.invalid = [] }
        server.beforePut.withLock { $0 = { try? await uploader.retryRejected() } }
        _ = try await uploader.pass(records: [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)], userName: "") { _ in }
        #expect(try await uploader.ledger().rejected.isEmpty)
        let next: AssistantPassReport = try await uploader.pass(records: [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)], userName: "") { _ in }
        #expect(next.uploaded == 1)
        #expect(next.progress == AssistantUploadProgress(uploaded: 2, rejected: 0, rejectionReason: nil, total: 2))
    }

    // Mixed reasons give no single reason; ledgers written before reasons existed still read.
    @Test func rejectionReasonsAndOldLedgers() throws {
        let local: [AssistantLocalMeeting] = try assistantLocalMeetings(records: [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)], userName: "")
        let prints: [String: String] = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0.fingerprint) })
        let mixed: AssistantUploadLedger = AssistantUploadLedger(epoch: 1, uploaded: [:], rejected: prints, rejectionReasons: ["a": .tooLarge, "b": .invalid], forgetGeneration: 0)
        #expect(assistantUploadProgress(local: local, ledger: mixed) == AssistantUploadProgress(uploaded: 0, rejected: 2, rejectionReason: nil, total: 2))
        let old: Data = Data(#"{"epoch":1,"rejected":{"a":"f"},"uploaded":{}}"#.utf8)
        let decoded: AssistantUploadLedger = try JSONDecoder().decode(AssistantUploadLedger.self, from: old)
        #expect(decoded == AssistantUploadLedger(epoch: 1, uploaded: [:], rejected: ["a": "f"], rejectionReasons: [:], forgetGeneration: 0))
        #expect(assistantRejectionReason(error: HostedAssistantError.copyTooLarge(meetingID: "a", byteCount: 1)) == .tooLarge)
        #expect(assistantRejectionReason(error: HostedAssistantError.quotaExceeded) == nil)
    }

    // "Remove this device's meetings": the server drops them and the ledger forgets them but keeps the epoch.
    @Test func forgetUploadsKeepsEpoch() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 4, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        _ = try await uploader.pass(records: [meeting(id: "a", startedAt: 100)], userName: "") { _ in }
        #expect(try await server.deleteDevice(deviceID: deviceID) == 1)
        try await uploader.forgetUploads()
        #expect(try await uploader.ledger() == AssistantUploadLedger(epoch: 4, uploaded: [:], rejected: [:], rejectionReasons: [:], forgetGeneration: 1))
    }

    // The audit's ordering: "remove this device" forgets the ledger while a pass waits on an upload. The pass must not
    // write its old ledger back (the next pass, after "add this device again", would think nothing needs uploading).
    @Test func forgetDuringPassIsNotUndone() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        let records: [MeetingRecord] = [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)]
        _ = try await uploader.pass(records: [records[0]], userName: "") { _ in }
        server.beforePut.withLock { $0 = { try? await uploader.forgetUploads() } }
        await #expect(throws: AssistantUploaderError.ledgerForgotten) { _ = try await uploader.pass(records: records, userName: "") { _ in } }
        #expect(try await uploader.ledger() == AssistantUploadLedger(epoch: 1, uploaded: [:], rejected: [:], rejectionReasons: [:], forgetGeneration: 1))
        // Nothing after the forget was uploaded except the one already on its way.
        #expect(server.state.withLock { $0.calls.filter { $0.hasPrefix("put") } } == ["put a", "put b"])
        let again: AssistantPassReport = try await uploader.pass(records: records, userName: "") { _ in }
        #expect(again.uploaded == 2)
    }

    // P18: a pass on a superseded uploader (the account was switched away and back, so the app made a new uploader for
    // the same ledger file) is still waiting on an upload when the new uploader forgets the ledger (turn off, "remove
    // this device"). The old pass must not write its ledger back: the forget is recorded in the file, not only in the
    // uploader that made it.
    @Test func forgottenEpochCannotRestoreAssistantLedger() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let superseded: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        let current: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        let records: [MeetingRecord] = [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)]
        _ = try await superseded.pass(records: [records[0]], userName: "") { _ in }
        server.beforePut.withLock { $0 = { try? await current.forgetUploads() } }
        await #expect(throws: AssistantUploaderError.ledgerForgotten) { _ = try await superseded.pass(records: records, userName: "") { _ in } }
        let afterForget: AssistantUploadLedger = try await current.ledger()
        #expect(afterForget.epoch == 1)
        #expect(afterForget.uploaded.isEmpty)
        #expect(afterForget.rejected.isEmpty)
        // Only the upload already on its way when the forget came was made.
        #expect(server.state.withLock { $0.calls.filter { $0.hasPrefix("put") } } == ["put a", "put b"])
        // The current uploader starts over and uploads everything again.
        let again: AssistantPassReport = try await current.pass(records: records, userName: "") { _ in }
        #expect(again.uploaded == 2)
        // The superseded uploader, used again later, sees the forget too and does not trust its old view.
        let late: AssistantPassReport = try await superseded.pass(records: records, userName: "") { _ in }
        #expect(late.uploaded == 0)
    }

    // Account deletion removes the ledger file (`HostedAssistantCenter.forgetAfterAccountDeletion`) while a pass waits on
    // an upload: the pass must not write the deleted account's ledger back.
    @Test func removedLedgerFileIsNotRecreatedByARunningPass() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 1, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        let records: [MeetingRecord] = [meeting(id: "a", startedAt: 100), meeting(id: "b", startedAt: 200)]
        _ = try await uploader.pass(records: [records[0]], userName: "") { _ in }
        let url: URL = file.url
        server.beforePut.withLock { $0 = { try? FileManager.default.removeItem(at: url) } }
        await #expect(throws: AssistantUploaderError.ledgerForgotten) { _ = try await uploader.pass(records: records, userName: "") { _ in } }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // A ledger file written by an app version without the forget generation (and without refusal reasons) still reads
    // as generation 0, keeps its uploads, is forgotten to generation 1, and the file then carries the new field.
    @Test func oldLedgerFileWithoutForgetGenerationReadsAndForgets() async throws {
        let server: FakeAssistantServer = FakeAssistantServer(settings: HostedAssistantSettings(enabled: true, epoch: 3, meetings: 0, maxMeetings: 5000))
        let file: AssistantLedgerFile = temporaryLedger()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let local: [AssistantLocalMeeting] = try assistantLocalMeetings(records: [meeting(id: "a", startedAt: 100)], userName: "")
        let oldFormat: String = #"{"epoch":3,"rejected":{},"uploaded":{"a":"\#(local[0].fingerprint)"}}"#
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(oldFormat.utf8).write(to: file.url)
        let uploader: AssistantUploader = AssistantUploader(client: server, file: file, deviceID: deviceID)
        #expect(try await uploader.ledger() == AssistantUploadLedger(epoch: 3, uploaded: ["a": local[0].fingerprint], rejected: [:], rejectionReasons: [:], forgetGeneration: 0))
        // The old ledger is trusted as it is: nothing to upload.
        let idle: AssistantPassReport = try await uploader.pass(records: [meeting(id: "a", startedAt: 100)], userName: "") { _ in }
        #expect(idle.uploaded == 0)
        try await uploader.forgetUploads()
        #expect(try await uploader.ledger() == AssistantUploadLedger(epoch: 3, uploaded: [:], rejected: [:], rejectionReasons: [:], forgetGeneration: 1))
        #expect(try String(decoding: Data(contentsOf: file.url), as: UTF8.self).contains(#""forgetGeneration":1"#))
    }
}
