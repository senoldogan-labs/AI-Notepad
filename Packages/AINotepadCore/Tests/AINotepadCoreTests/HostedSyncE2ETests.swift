import CryptoKit
import Foundation
import Testing
@testable import AINotepadCore

// Local server (`wrangler dev`) only; prepared with `Process`, so macOS only. Enable with `AINOTEPAD_HOSTED_E2E=1` and
// `AINOTEPAD_HOSTED_BASE` (see `HostedE2ETests`).
#if os(macOS)

/// A second session (refresh family) of an existing local user: the account's second device.
private func insertDeviceSession(userID: String, refreshToken: String) throws {
    let hash: String = SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    let now: Int = nowMs()
    let familyID: String = "e2e-\(UUID().uuidString.lowercased())"
    try executeLocalD1(sql: [
        "INSERT INTO refresh_families (id, user_id, created_at) VALUES ('\(familyID)', '\(userID)', \(now));",
        "INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES ('\(hash)', '\(familyID)', \(now), \(now + 24 * 3_600_000));",
    ].joined(separator: " "))
}

/// One simulated device: its own session and sync client, sharing the account.
private struct SyncDevice {
    let client: HostedSyncClient
    let deviceID: String
}

private func device(baseURL: URL, userID: String, refreshToken: String) async throws -> SyncDevice {
    let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(accessToken: "gecersiz", refreshToken: refreshToken, accessExpiresAt: Date.distantPast, userId: userID))
    let session: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
    _ = try await awaitingAuthLimit { try await session.validAccessToken() }
    let deviceID: String = UUID().uuidString.lowercased()
    return SyncDevice(client: HostedSyncClient(baseURL: baseURL, credentials: session, deviceID: deviceID), deviceID: deviceID)
}

/// `sync_objects` row as the server stores it.
private struct ObjectRow: Decodable, Equatable {
    let object_id: String
    let kind: String
    let rev: Int
    let size: Int
    let deleted: Int
}

/// Every byte under the local server's persisted state (D1 SQLite files and R2 blobs) contains none of `markers`.
private func localServerStateContainsNone(of markers: [String]) throws -> Bool {
    let state: URL = serverDirectory().appending(path: ".wrangler/state", directoryHint: .isDirectory)
    let files: [URL] = (FileManager.default.enumerator(at: state, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL]) ?? []
    #expect(!files.isEmpty, "wrangler dev keeps its local state under server/.wrangler/state")
    for file in files where (try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        let data: Data = try Data(contentsOf: file)
        if markers.contains(where: { data.range(of: Data($0.utf8)) != nil }) {
            Issue.record("Plaintext found in server state: \(file.lastPathComponent)")
            return false
        }
    }
    return true
}

/// Seals and uploads a payload; returns the new revision.
private func upload<Value: Encodable>(
    device: SyncDevice, value: Value, key: SyncAccountKey, userID: String, objectID: String, kind: SyncObjectKind, baseRevision: UInt64
) async throws -> UInt64 {
    let blob: Data = try sealSyncObject(payload: try encodeSyncPayload(value: value), accountKey: key, userID: userID, objectID: objectID, kind: kind, baseRevision: baseRevision)
    return try await device.client.put(objectID: objectID, kind: kind, baseRevision: baseRevision, blob: blob)
}

/// Downloads, verifies and decodes an object.
private func download<Value: Decodable>(device: SyncDevice, type: Value.Type, key: SyncAccountKey, userID: String, objectID: String) async throws -> (value: Value, revision: UInt64) {
    let object: HostedSyncObject = try await device.client.object(objectID: objectID)
    let payload: Data = try openSyncObject(blob: object.blob, accountKey: key, userID: userID, objectID: objectID, kind: object.kind, servedRevision: object.revision)
    return (try decodeSyncPayload(type: type, data: payload), object.revision)
}

@Suite(.enabled(if: hostedE2EEnabled), .serialized) struct HostedSyncE2ETests {
    // The Mac records a meeting and syncs it; the iPhone (same account, its own session) gets the key through the
    // recovery envelope, reads the meeting, and both edit it at once: the Mac's stale write conflicts, it merges
    // three-way and wins the retry, and the iPhone sees both edits. Then a delete reaches the iPhone as a tombstone and
    // opting out wipes the server copy. Throughout, the server's D1 and R2 state never contain the meeting's text.
    @Test func meetingSyncsBetweenTwoDevicesAsCiphertextAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let macRefresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: macRefresh)
        let phoneRefresh: String = randomToken()
        try insertDeviceSession(userID: userID, refreshToken: phoneRefresh)
        // A started trial may write (DEVICECHECK_POLICY is off locally).
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
        let mac: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: macRefresh)
        let phone: SyncDevice = try await device(baseURL: baseURL, userID: userID, refreshToken: phoneRefresh)

        // Unique plaintext that must never reach the server.
        let marker: String = "Secret-\(UUID().uuidString)"
        let record: MeetingRecord = syncSampleRecord().with(title: "Budget \(marker)").with(myNotes: "Notes \(marker)")
        let tasks: [NoteTask] = try #require(record.note?.tasks)

        // Mac: turns sync on, uploads the meeting, stores a recovery envelope.
        let key: SyncAccountKey = newSyncAccountKey()
        let enabled: HostedSyncAccount = try await mac.client.enable(keyID: key.keyID)
        #expect(enabled.enabled && enabled.keyId == key.keyID)
        let stateID: String = newSyncObjectID()
        let contentID: String = newSyncObjectID()
        let parts: MeetingSyncParts = meetingSyncParts(record: record, contentObjectID: contentID, originDeviceID: mac.deviceID, clocks: [:])
        let base: MeetingSyncState = try stampingChanges(previous: nil, updated: parts.state, now: Date())
        let stateRev: UInt64 = try await upload(device: mac, value: base, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: 0)
        _ = try await upload(device: mac, value: parts.content, key: key, userID: userID, objectID: contentID, kind: .meetingContent, baseRevision: 0)
        let code: SyncRecoveryCode = newSyncRecoveryCode()
        try await mac.client.putEnvelope(envelopeID: newSyncObjectID(), kind: .recovery, ciphertext: try sealRecoveryEnvelope(accountKey: key, code: code, userID: userID))
        // The phone's own key loses the race to turn sync on.
        await #expect(throws: HostedSyncError.keyMismatch) { _ = try await phone.client.enable(keyID: newSyncAccountKey().keyID) }

        // iPhone: recovers the key with the code, reads the change feed and the meeting.
        let envelope: HostedSyncEnvelope = try #require(try await phone.client.envelopes().first { $0.kind == .recovery })
        let phoneKey: SyncAccountKey = try openRecoveryEnvelope(envelope: try #require(Data(base64Encoded: envelope.ciphertext)), code: code, userID: userID)
        #expect(phoneKey == key)
        let feed: HostedSyncChanges = try await phone.client.changes(since: 0, epoch: nil, limit: 500)
        #expect(Set(feed.changes.map(\.objectId)) == [stateID, contentID] && feed.keyId == key.keyID && !feed.hasMore)
        let phoneState: (value: MeetingSyncState, revision: UInt64) = try await download(device: phone, type: MeetingSyncState.self, key: phoneKey, userID: userID, objectID: stateID)
        let phoneContent: (value: MeetingSyncContent, revision: UInt64) = try await download(device: phone, type: MeetingSyncContent.self, key: phoneKey, userID: userID, objectID: contentID)
        var expected: MeetingRecord = record
        expected = expected.with(voiceprints: nil)
        #expect(joinedMeetingRecord(state: phoneState.value, content: phoneContent.value, voiceprints: nil) == expected)

        // Both edit at once: the phone completes a task and syncs first; the Mac moves it to a folder from the old base.
        let phoneRecord: MeetingRecord = togglingTask(record: joinedMeetingRecord(state: phoneState.value, content: phoneContent.value, voiceprints: nil), task: tasks[0])
        let phoneEdit: MeetingSyncState = try stampingChanges(
            previous: phoneState.value,
            updated: meetingSyncParts(record: phoneRecord, contentObjectID: contentID, originDeviceID: mac.deviceID, clocks: phoneState.value.fieldClocks).state,
            now: Date()
        )
        let phoneRev: UInt64 = try await upload(device: phone, value: phoneEdit, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: phoneState.revision)
        let macEdit: MeetingSyncState = try stampingChanges(
            previous: base, updated: meetingSyncParts(record: record.with(folder: "Board"), contentObjectID: contentID, originDeviceID: mac.deviceID, clocks: base.fieldClocks).state,
            now: Date()
        )
        await #expect(throws: HostedSyncError.conflict(objectID: stateID)) {
            _ = try await upload(device: mac, value: macEdit, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: stateRev)
        }
        let remote: (value: MeetingSyncState, revision: UInt64) = try await download(device: mac, type: MeetingSyncState.self, key: key, userID: userID, objectID: stateID)
        #expect(remote.revision == phoneRev)
        let merged: MeetingStateMerge = mergeMeetingState(base: base, local: macEdit, remote: remote.value, localDeviceID: mac.deviceID, conflictReason: "Changed on another device", myNotesSeparator: "---")
        let mergedRev: UInt64 = try await upload(device: mac, value: merged.state, key: key, userID: userID, objectID: stateID, kind: .meetingState, baseRevision: remote.revision)

        // The phone pulls from its cursor and sees both edits.
        let next: HostedSyncChanges = try await phone.client.changes(since: feed.cursor, epoch: feed.epoch, limit: 500)
        #expect(next.changes.map(\.rev).last == mergedRev)
        let final: MeetingSyncState = try await download(device: phone, type: MeetingSyncState.self, key: key, userID: userID, objectID: stateID).value
        #expect(final.folder == "Board" && Set(final.completedTasks ?? []) == Set(tasks.map { taskKey(task: $0) }))

        // What the server holds: opaque ids, fixed kinds, sizes; the blobs start with GSY1 and hold no plaintext.
        let rows: [ObjectRow] = try localD1Rows(sql: "SELECT object_id, kind, rev, size, deleted FROM sync_objects WHERE user_id = '\(userID)' ORDER BY rev;", as: ObjectRow.self)
        #expect(Set(rows.map(\.kind)) == ["meeting.state", "meeting.content"])
        let blob: Data = try await phone.client.object(objectID: contentID).blob
        #expect(blob.prefix(4) == Data("GSY1".utf8) && blob.range(of: Data("approve the budget".utf8)) == nil)
        #expect(try localServerStateContainsNone(of: [marker, "approve the budget", "Ask about Q3"]))

        // The Mac deletes the meeting: the phone sees a tombstone and the blob is gone.
        let deletedRev: UInt64 = try await mac.client.delete(objectID: contentID, baseRevision: try await mac.client.object(objectID: contentID).revision)
        let afterDelete: HostedSyncChanges = try await phone.client.changes(since: next.cursor, epoch: next.epoch, limit: 500)
        #expect(afterDelete.changes.contains { $0.objectId == contentID && $0.deleted && $0.rev == deletedRev })
        await #expect(throws: HostedSyncError.objectNotFound(objectID: contentID)) { _ = try await phone.client.object(objectID: contentID) }

        // Opting out removes the whole server copy; the old cursor no longer works.
        #expect(try await phone.client.disableAndWipe() == 1)
        #expect(try await mac.client.account().enabled == false)
        await #expect(throws: HostedSyncError.notEnabled) { _ = try await mac.client.changes(since: 0, epoch: nil, limit: 10) }
        #expect(try localD1Rows(sql: "SELECT object_id, kind, rev, size, deleted FROM sync_objects WHERE user_id = '\(userID)';", as: ObjectRow.self).isEmpty)
    }
}

#endif
