import AINotepadWatchLink
import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

/// The iPhone's side of a Watch recording, end to end without WatchConnectivity (its `transferFile` does not run in the
/// Simulator): the file arrives as WatchConnectivity hands it over (a temporary file plus the metadata payload), is
/// moved into the inbox, read back, decided on (account, duplicate) and imported through the same core path as
/// `PhoneRecorder.importWatchRecording` (`importMediaAudio` + `importedMeetingRecord` with the Watch's title and start).
@Suite(.serialized) struct WatchRecordingImportTests {
    private let startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)

    /// A Watch recording as the Watch sends it: AAC, 16 kHz, mono, 32 kbps in an `.m4a` container. Made with the same
    /// async conversion `MediaImportTests` uses (a synchronous AAC encode inside these async tests stalled the whole
    /// parallel test run on the CI runner).
    private func watchRecordingFile(directory: URL, name: String) async throws -> URL {
        let fixture: URL = try #require(Bundle.module.url(forResource: "fi-dialog", withExtension: "wav", subdirectory: "Fixtures"))
        let url: URL = directory.appending(path: name)
        _ = try await importMediaAudio(source: fixture, destination: url)
        return url
    }

    private func info(id: String, accountTag: String) -> WatchRecordingInfo {
        WatchRecordingInfo(id: id, title: "Weekly sync", startedAt: startedAt, durationSec: 12, accountTag: accountTag, interrupted: false)
    }

    // A recording reaches the inbox, is imported into its account with the Watch's title and start, then is skipped as a
    // duplicate when the same transfer arrives again.
    @Test func receivedRecordingIsImportedOnceIntoItsAccount() async throws {
        let directory: URL = try temporaryDirectory()
        let inbox: URL = directory.appending(path: "WatchInbox")
        let id: String = UUID().uuidString
        let delivered: URL = try await watchRecordingFile(directory: directory, name: "wc-temporary-copy.m4a")
        let payload: Data? = try watchPayload(value: info(id: id, accountTag: "account-a"))[watchPayloadKey]

        let stored: WatchRecordingInfo = try storeWatchRecording(file: delivered, payload: payload, inbox: inbox)
        #expect(stored == info(id: id, accountTag: "account-a"))
        // WatchConnectivity deletes its copy when the delegate returns: the inbox must own the file by then.
        #expect(!FileManager.default.fileExists(atPath: delivered.path))

        let contents: WatchInboxContents = try readWatchInbox(inbox: inbox)
        #expect(contents.entries == [stored])
        #expect(contents.unreadable.isEmpty)
        #expect(watchImportDecision(info: stored, loadedAccountTag: nil, importedIDs: []) == .wait)
        #expect(watchImportDecision(info: stored, loadedAccountTag: "account-b", importedIDs: []) == .wait)
        #expect(watchImportDecision(info: stored, loadedAccountTag: "account-a", importedIDs: []) == .importNow)

        let meeting: URL = directory.appending(path: "meeting", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let audio: URL = watchInboxAudioURL(inbox: inbox, id: id)
        let duration: Double = try await importMediaAudio(source: audio, destination: meeting.appending(path: "others.m4a"))
        let expected: Double = Double(try loadFixture(name: "fi-dialog").count) / 16_000
        #expect(abs(duration - expected) < 0.3)
        let record: MeetingRecord = importedMeetingRecord(
            id: "watch-import", source: audio, startedAt: stored.startedAt, durationSec: duration, engine: .cloud, template: .general
        )
        .with(title: stored.title)
        #expect(record.title == "Weekly sync")
        #expect(record.startedAt == startedAt)
        #expect(abs(try #require(record.endedAt).timeIntervalSince(startedAt) - expected) < 0.3)
        #expect(record.status == .processing)

        try removeWatchInboxEntry(inbox: inbox, id: id)
        #expect(try readWatchInbox(inbox: inbox).entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: audio.path))

        // The Watch sends it again (it had not seen the confirmation yet): the ledger skips it.
        let again: URL = try await watchRecordingFile(directory: directory, name: "wc-temporary-copy-2.m4a")
        let repeated: WatchRecordingInfo = try storeWatchRecording(file: again, payload: payload, inbox: inbox)
        #expect(watchImportDecision(info: repeated, loadedAccountTag: "account-a", importedIDs: [id]) == .duplicate)
    }

    // A Watch recording longer than the meeting's allowance (the Watch's limit was stale) is cut at the allowance
    // instead of being refused whole.
    @Test func longRecordingIsCutAtTheAllowance() async throws {
        let directory: URL = try temporaryDirectory()
        let audio: URL = try await watchRecordingFile(directory: directory, name: "long.m4a")
        let full: Double = Double(try loadFixture(name: "fi-dialog").count) / 16_000
        let limit: Double = (full / 2).rounded(.down)
        let cut: MediaImportPrefix = try await importMediaAudioPrefix(source: audio, destination: directory.appending(path: "cut.m4a"), maxSec: limit)
        #expect(abs(cut.durationSec - limit) < 0.05)
        #expect(cut.wasCut)
        let file: AVAudioFile = try AVAudioFile(forReading: directory.appending(path: "cut.m4a"))
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - limit) < 0.2)
        // A limit above the length keeps everything and is not reported as a cut (a Watch recording that stopped itself
        // at the limit gets no "longer than the allowance" notice).
        let whole: MediaImportPrefix = try await importMediaAudioPrefix(source: audio, destination: directory.appending(path: "whole.m4a"), maxSec: full + 60)
        #expect(abs(whole.durationSec - full) < 0.3)
        #expect(!whole.wasCut)
    }

    // A transfer whose ID is not a UUID, whose metadata is missing, or whose file is empty is refused and the system's
    // copy is left where it is (nothing reaches the inbox).
    @Test func malformedTransfersAreRefused() async throws {
        let directory: URL = try temporaryDirectory()
        let inbox: URL = directory.appending(path: "WatchInbox")
        let delivered: URL = try await watchRecordingFile(directory: directory, name: "copy.m4a")
        #expect(throws: WatchInboxError.invalidRecordingID) {
            try storeWatchRecording(file: delivered, payload: try watchPayload(value: info(id: "../escape", accountTag: "a"))[watchPayloadKey], inbox: inbox)
        }
        #expect(throws: WatchLinkError.missingPayload) {
            try storeWatchRecording(file: delivered, payload: nil, inbox: inbox)
        }
        let empty: URL = directory.appending(path: "empty.m4a")
        try Data().write(to: empty)
        #expect(throws: WatchInboxError.emptyAudio) {
            try storeWatchRecording(file: empty, payload: try watchPayload(value: info(id: UUID().uuidString, accountTag: "a"))[watchPayloadKey], inbox: inbox)
        }
        #expect(FileManager.default.fileExists(atPath: delivered.path))
        #expect(try readWatchInbox(inbox: inbox).entries.isEmpty)
    }

    // Metadata that cannot be read, or whose audio is missing, is reported and never imported.
    @Test func brokenInboxEntriesAreNotListed() throws {
        let directory: URL = try temporaryDirectory()
        let inbox: URL = directory.appending(path: "WatchInbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let orphanID: String = UUID().uuidString
        try #require(try watchPayload(value: info(id: orphanID, accountTag: "a"))[watchPayloadKey]).write(to: watchInboxMetadataURL(inbox: inbox, id: orphanID))
        try Data("not json".utf8).write(to: inbox.appending(path: UUID().uuidString + ".json"))
        let contents: WatchInboxContents = try readWatchInbox(inbox: inbox)
        #expect(contents.entries.isEmpty)
        #expect(contents.unreadable.count == 2)
    }
}
