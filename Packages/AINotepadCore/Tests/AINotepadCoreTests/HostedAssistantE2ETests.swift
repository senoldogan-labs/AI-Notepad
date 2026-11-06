import Foundation
import Testing
@testable import AINotepadCore

// Local server (`wrangler dev`, development vars: `ASSISTANT_POLICY` on, local EU D1 and R2) only; prepared with
// `Process`, so macOS only. Enable with `AINOTEPAD_HOSTED_E2E=1` and `AINOTEPAD_HOSTED_BASE` (see `HostedE2ETests`).
#if os(macOS)

/// Runs SQL on the local EU assistant database (`wrangler d1 execute --local`; never production).
private func executeLocalAssistantD1(sql: String, json: Bool) throws -> Data {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "wrangler", "d1", "execute", "gistsmith-assistant-dev", "--local"] + (json ? ["--json"] : []) + ["--command", sql]
    process.currentDirectoryURL = serverDirectory()
    let output: Pipe = Pipe()
    process.standardOutput = output
    process.standardError = json ? FileHandle.nullDevice : output
    try process.run()
    let data: Data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HostedClientError.malformedResponse(path: "wrangler d1 execute gistsmith-assistant-dev", status: Int(process.terminationStatus), body: String(decoding: data, as: UTF8.self))
    }
    return data
}

private struct CountRow: Decodable {
    let count: Int
}

/// Rows of `assistant_meetings` for the user in the local EU database.
private func localAssistantMeetingRows(userID: String) throws -> Int {
    let data: Data = try executeLocalAssistantD1(sql: "SELECT COUNT(*) AS count FROM assistant_meetings WHERE user_id = '\(userID)';", json: true)
    return try JSONDecoder().decode([LocalD1Statement<CountRow>].self, from: data).first?.results.first?.count ?? -1
}

@Suite(.enabled(if: hostedE2EEnabled), .serialized) struct HostedAssistantE2ETests {
    // The app's assistant path against the local server: turning access on, the uploader's backfill (the sample meeting
    // stays out), the copy holding the meeting, a local delete removing it, a listed connection disconnected, and
    // turning off deleting the whole copy and moving to a new epoch (an upload prepared before is refused with 409 and
    // the uploader stops instead of uploading again).
    @Test func enableUploadDisableAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let refresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: refresh)
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
        let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(accessToken: "gecersiz", refreshToken: refresh, accessExpiresAt: Date.distantPast, userId: userID))
        let session: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
        _ = try await awaitingAuthLimit { try await session.validAccessToken() }
        let client: HostedAssistantClient = HostedAssistantClient(baseURL: baseURL, credentials: session)
        let deviceID: String = UUID().uuidString.lowercased()
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "assistant-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploader: AssistantUploader = AssistantUploader(client: client, file: AssistantLedgerFile(url: folder.appending(path: "ledger.json")), deviceID: deviceID)

        let initial: HostedAssistantSettings = try await client.settings()
        #expect(!initial.enabled)
        // Off: an upload is refused and the uploader does nothing.
        let off: AssistantPassReport = try await uploader.pass(records: [syncSampleRecord()], userName: "") { _ in }
        #expect(off.uploaded == 0 && !off.settings.enabled)

        let enabled: HostedAssistantSettings = try await client.setEnabled(enabled: true)
        #expect(enabled.enabled)
        let meeting: MeetingRecord = syncSampleRecord().with(title: "Budget \(UUID().uuidString)")
        let other: MeetingRecord = MeetingRecord(
            id: UUID().uuidString.lowercased(), title: "Standup", startedAt: meeting.startedAt.addingTimeInterval(-86_400), endedAt: meeting.startedAt.addingTimeInterval(-85_800),
            language: .english, status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: meeting.note,
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let sample: MeetingRecord = syncSampleRecord().with(title: "Sample").markedAsSample()
        // Meeting ids are UUIDs on the server; the sync sample's folder-name id is not, so give it one.
        let meetingID: String = UUID().uuidString.lowercased()
        let renamed: MeetingRecord = MeetingRecord(
            id: meetingID, title: meeting.title, startedAt: meeting.startedAt, endedAt: meeting.endedAt, language: meeting.language, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: meeting.speakerNames, note: meeting.note, audioDeleted: false, engine: .cloud,
            notice: nil, meNeedsFinalPass: nil
        ).with(myNotes: "Ask about Q3")
        let first: AssistantPassReport = try await uploader.pass(records: [other, renamed, sample], userName: "") { _ in }
        #expect(first.uploaded == 2)
        #expect(first.settings.meetings == 2)
        #expect(try localAssistantMeetingRows(userID: userID) == 2)

        // A local delete is propagated.
        let second: AssistantPassReport = try await uploader.pass(records: [renamed, sample], userName: "") { _ in }
        #expect(second.deleted == 1)
        #expect(second.settings.meetings == 1)

        // A connected assistant is listed and can be disconnected.
        let grantID: String = "e2e\(randomToken().prefix(20).filter { $0.isLetter || $0.isNumber })"
        _ = try executeLocalAssistantD1(sql: """
            INSERT INTO assistant_grants (user_id, grant_id, client_id, client_name, redirect_host, verified, created_at, epoch)
            VALUES ('\(userID)', '\(grantID)', 'client-e2e', 'Claude', 'claude.ai', 1, \(nowMs()), \(enabled.epoch));
            """, json: false)
        let grants: [HostedAssistantGrant] = try await client.grants()
        #expect(grants.map(\.grantId) == [grantID])
        #expect(grants.first.map(assistantGrantDisplayName) == "Claude")
        try await client.deleteGrant(grantID: grantID)
        #expect(try await client.grants().isEmpty)

        // Turning off deletes the copy at once and moves to a new epoch; an upload from the old epoch is refused.
        let disabled: HostedAssistantSettings = try await client.setEnabled(enabled: false)
        #expect(!disabled.enabled)
        #expect(disabled.meetings == 0)
        #expect(disabled.epoch > enabled.epoch)
        #expect(try localAssistantMeetingRows(userID: userID) == 0)
        await #expect(throws: HostedAssistantError.notEnabled) {
            try await client.putMeeting(meetingID: meetingID, upload: AssistantMeetingUpload(epoch: enabled.epoch, deviceId: deviceID, copy: try #require(assistantMeetingCopy(record: renamed, userName: ""))))
        }
        let afterOff: AssistantPassReport = try await uploader.pass(records: [renamed], userName: "") { _ in }
        #expect(afterOff.uploaded == 0 && !afterOff.settings.enabled)
        #expect(try await uploader.ledger() == .empty)

        // On again: the new epoch backfills; an upload naming the old epoch gets 409 epoch mismatch.
        let again: HostedAssistantSettings = try await client.setEnabled(enabled: true)
        await #expect(throws: HostedAssistantError.epochMismatch) {
            try await client.putMeeting(meetingID: meetingID, upload: AssistantMeetingUpload(epoch: enabled.epoch, deviceId: deviceID, copy: try #require(assistantMeetingCopy(record: renamed, userName: ""))))
        }
        let backfill: AssistantPassReport = try await uploader.pass(records: [renamed], userName: "") { _ in }
        #expect(backfill.uploaded == 1)
        #expect(try await uploader.ledger().epoch == again.epoch)
        // "Remove this device's meetings".
        #expect(try await client.deleteDevice(deviceID: deviceID) == 1)
        _ = try await client.setEnabled(enabled: false)
        #expect(try localAssistantMeetingRows(userID: userID) == 0)
    }
}

#endif
