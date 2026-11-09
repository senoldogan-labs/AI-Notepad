import AINotepadWatchLink
import AVFoundation
import Foundation
import Testing
@testable import AINotepadWatch

/// The Watch recorder against the real audio stack of the watchOS Simulator (its microphone may deliver silence): the
/// capture is a readable 16 kHz mono PCM CAF of the recorded length, also when the app is killed mid-recording, and its
/// compressed copy is the AAC 16 kHz mono `.m4a` the iPhone imports (`WatchRecordingImportTests` covers the iPhone's
/// side). Needs the microphone allowed for the app (the first UI test run answers the prompt).
@MainActor
@Suite(.serialized) struct WatchRecorderTests {
    /// Collects why the system stopped a recording.
    @MainActor
    final class StopLog {
        private(set) var reasons: [WatchSystemStop] = []

        func append(reason: WatchSystemStop) {
            reasons.append(reason)
        }
    }

    private func temporaryFile(ext: String) -> URL {
        URL.temporaryDirectory.appending(path: UUID().uuidString + "." + ext)
    }

    /// Checks a file: codec, rate, channels and length (seconds within `expectedSec` ± 0.8).
    private func expectAudio(url: URL, formatID: AudioFormatID, expectedSec: Double) async throws {
        let file: AVAudioFile = try AVAudioFile(forReading: url)
        let format: AVAudioFormat = file.fileFormat
        #expect(format.streamDescription.pointee.mFormatID == formatID)
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        let seconds: Double = Double(file.length) / format.sampleRate
        #expect(abs(seconds - expectedSec) < 0.8, "recorded \(seconds) s, expected about \(expectedSec) s")
        let duration: CMTime = try await AVURLAsset(url: url).load(.duration)
        #expect(abs(duration.seconds - expectedSec) < 0.8)
    }

    // "End": the capture is closed, and its compressed copy is the AAC `.m4a` that is sent, of the same length.
    @Test func endClosesTheCaptureAndCompressesIt() async throws {
        let capture: URL = temporaryFile(ext: "caf")
        let recorder: WatchRecorder = WatchRecorder()
        try await recorder.start(file: capture, limitSec: nil)
        try await Task.sleep(for: .seconds(2))
        recorder.stop()
        try await expectAudio(url: capture, formatID: kAudioFormatLinearPCM, expectedSec: 2)
        let sent: URL = temporaryFile(ext: "m4a")
        let seconds: Double = try await WatchRecorder.compress(capture: capture, output: sent)
        #expect(abs(seconds - 2) < 0.8)
        try await expectAudio(url: sent, formatID: kAudioFormatMPEG4AAC, expectedSec: seconds)
        // Smaller than the capture. A 2 s `.m4a` is mostly its ~25 KB header; over 20 s the same settings measure 32 kbps
        // (~14 MB per hour) against the capture's 256 kbps.
        let captureBytes: Int = try #require(try capture.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let sentBytes: Int = try #require(try sent.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(sentBytes < captureBytes, "sent \(sentBytes) bytes, capture \(captureBytes) bytes")
        try FileManager.default.removeItem(at: capture)
        try FileManager.default.removeItem(at: sent)
    }

    // The app killed mid-recording: the capture as it is on disk before `stop()` (a copy taken while recording) is
    // readable and holds what was recorded, so the next launch can send it. AAC in `.m4a` (the earlier format) was not:
    // "dta?" (no index) in the same Simulator.
    @Test func captureCutOffMidRecordingIsReadable() async throws {
        let capture: URL = temporaryFile(ext: "caf")
        let recorder: WatchRecorder = WatchRecorder()
        try await recorder.start(file: capture, limitSec: nil)
        try await Task.sleep(for: .seconds(3))
        let cutOff: URL = temporaryFile(ext: "caf")
        try FileManager.default.copyItem(at: capture, to: cutOff)
        recorder.stop()
        let seconds: Double = try WatchRecorder.recordedSeconds(capture: cutOff)
        #expect(seconds > 2, "the cut-off capture holds \(seconds) s")
        let sent: URL = temporaryFile(ext: "m4a")
        #expect(try await WatchRecorder.compress(capture: cutOff, output: sent) > 2)
        for url in [capture, cutOff, sent] {
            try FileManager.default.removeItem(at: url)
        }
    }

    // The account's limit ends the recording by itself; the model is told (not marked interrupted) and the file is valid.
    @Test func limitEndsAndClosesTheFile() async throws {
        let capture: URL = temporaryFile(ext: "caf")
        let recorder: WatchRecorder = WatchRecorder()
        let log: StopLog = StopLog()
        recorder.onSystemStop = { (reason: WatchSystemStop) in log.append(reason: reason) }
        try await recorder.start(file: capture, limitSec: 1.5)
        try await Task.sleep(for: .seconds(WatchRecorder.watchdogSec + 2))
        #expect(log.reasons == [.limitReached])
        // The watchdog's first check after the limit ends it.
        try await expectAudio(url: capture, formatID: kAudioFormatLinearPCM, expectedSec: WatchRecorder.watchdogSec)
        // A late "End" after the limit does nothing.
        recorder.stop()
        #expect(log.reasons == [.limitReached])
        try FileManager.default.removeItem(at: capture)
    }

    // What is sent matches the iPhone's import (AAC 16 kHz mono 32 kbps, ~14 MB per hour).
    @Test func sentSettingsMatchTheImport() {
        #expect(WatchRecorder.sentSettings[AVFormatIDKey] == Int(kAudioFormatMPEG4AAC))
        #expect(WatchRecorder.sentSettings[AVSampleRateKey] == 16_000)
        #expect(WatchRecorder.sentSettings[AVNumberOfChannelsKey] == 1)
        #expect(WatchRecorder.sentSettings[AVEncoderBitRateKey] == 32_000)
        #expect(WatchRecorder.settings[AVFormatIDKey] == Int(kAudioFormatLinearPCM))
    }
}
