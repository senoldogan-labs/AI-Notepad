import AINotepadWatchLink
import AVFoundation
import Foundation
import os
import WatchKit

/// The running recording on the Watch. There is no pause on the Watch: the audio background mode keeps an app running
/// only while it records, so a paused recording with the wrist down would be suspended (and could be ended by the
/// system) — End and a new recording are the reliable way.
struct WatchActiveRecording: Equatable {
    let id: String
    let title: String
    let accountTag: String
    let startedAt: Date
    /// The capture file (`watchCaptureFileName`).
    let file: URL

    /// Recorded seconds at `now`.
    func activeSec(now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }
}

/// Errors starting a Watch recording.
enum WatchRecorderError: Error, Equatable {
    /// The user has not allowed the microphone (Settings › Privacy on the Watch).
    case microphoneDenied
    /// Less free space than `watchRecordingMinimumFreeBytes`.
    case notEnoughSpace(availableBytes: Int64)
    /// The volume did not report its free space.
    case freeSpaceUnknown
    /// No audio buffer could be allocated to compress the capture.
    case compressionBufferUnavailable
    /// AVAudioRecorder refused to start (another app holds the microphone).
    case recorderRefused
}

/// Why the system ended a Watch recording before "End" (the recording is kept and sent, marked interrupted unless the
/// limit was reached).
enum WatchSystemStop: Equatable {
    /// The account's longest meeting was reached (the recorder's watchdog).
    case limitReached
    /// A call, Siri, an alarm or another app took the microphone. watchOS does not let a background app restart the
    /// microphone (Apple Frameworks Engineer, developer forums thread 750432), so the recording ends.
    case interrupted
    /// The battery reached `watchRecordingLowBatteryLevel`.
    case lowBattery
    /// The encoder failed or the audio system restarted.
    case failed
}

/// The Watch's microphone (AVAudioRecorder): 16-bit PCM, mono, 16 kHz in CAF (about 115 MB per hour), which stays
/// readable if the app is killed mid-recording; after End it is compressed to AAC 32 kbps `.m4a` (~14 MB per hour) for
/// the transfer (`compress`). The session starts in the foreground and keeps running in the background with the `audio`
/// background mode (`UIBackgroundModes`). A call, Siri, low battery or the limit ends it; what was recorded is kept.
/// Design and sources: docs/superpowers/specs/2026-11-08-apple-watch.md › "Recording on the Watch".
@MainActor
final class WatchRecorder: NSObject {
    nonisolated private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.watch", category: "Recorder")
    /// The capture: PCM needs `.caf` (AVAudioRecorder picks the container from the file extension).
    static let settings: [String: Int] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
    ]
    /// What is sent to the iPhone (the iPhone's own recording format): AAC, 16 kHz, mono, 32 kbps in `.m4a`.
    nonisolated static let sentSettings: [String: Int] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]
    /// How often the running recording is checked against its limit and the battery (a timer in a running
    /// background-audio app is cheap). The limit may be passed by up to this much.
    static let watchdogSec: TimeInterval = 5

    private var recorder: AVAudioRecorder?
    private var observerTokens: [NSObjectProtocol] = []
    private var watchdog: Timer?
    /// Called when the system ended the recording (limit, interruption, battery, failure); the model finishes it.
    var onSystemStop: (@MainActor (_ reason: WatchSystemStop) -> Void)?

    /// Directory of finished and running recordings (kept until the iPhone has them).
    static func recordingsDirectory() throws -> URL {
        let directory: URL = URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Free space for new files on the Watch (bytes), read on the recordings directory (created first: Application
    /// Support does not exist on a fresh install).
    static func availableBytes() throws -> Int64 {
        let values: URLResourceValues = try recordingsDirectory().resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacity else {
            throw WatchRecorderError.freeSpaceUnknown
        }
        return Int64(capacity)
    }

    /// Seconds of audio in a capture file, also one cut off by the app being killed (CAF keeps what was written).
    nonisolated static func recordedSeconds(capture: URL) throws -> Double {
        let file: AVAudioFile = try AVAudioFile(forReading: capture)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Compresses a capture to the `.m4a` that is sent (`sentSettings`) and returns its seconds. Written to a temporary
    /// name and moved into place at the end, so an interrupted compression never leaves a half file under the sent
    /// name; it runs again from the capture. Runs off the main actor.
    nonisolated static func compress(capture: URL, output: URL) async throws -> Double {
        try await Task.detached(priority: .utility) {
            try compressNow(capture: capture, output: output)
        }.value
    }

    nonisolated private static func compressNow(capture: URL, output: URL) throws -> Double {
        let manager: FileManager = FileManager.default
        let partial: URL = output.deletingLastPathComponent().appending(path: output.deletingPathExtension().lastPathComponent + ".part.m4a")
        if manager.fileExists(atPath: partial.path) {
            try manager.removeItem(at: partial)
        }
        let input: AVAudioFile = try AVAudioFile(forReading: capture)
        let format: AVAudioFormat = input.processingFormat
        let writer: AVAudioFile = try AVAudioFile(
            forWriting: partial, settings: sentSettings, commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 10) else {
            throw WatchRecorderError.compressionBufferUnavailable
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 {
                break
            }
            try writer.write(from: buffer)
        }
        writer.close()
        if manager.fileExists(atPath: output.path) {
            try manager.removeItem(at: output)
        }
        try manager.moveItem(at: partial, to: output)
        return Double(input.length) / input.fileFormat.sampleRate
    }

    /// Starts recording into `file`; stops itself after `limitSec` when given. Must run while the app is in the
    /// foreground: watchOS starts a background audio session only from the foreground.
    func start(file: URL, limitSec: TimeInterval?) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw WatchRecorderError.microphoneDenied
        }
        let available: Int64 = try Self.availableBytes()
        guard watchHasRoomToRecord(availableBytes: available) else {
            throw WatchRecorderError.notEnoughSpace(availableBytes: available)
        }
        let session: AVAudioSession = AVAudioSession.sharedInstance()
        // `.playAndRecord` is the configuration Apple's engineers confirm keeps recording with the wrist down
        // (developer forums thread 750432); nothing is played.
        try session.setCategory(.playAndRecord, mode: .default)
        try session.setActive(true)
        let recorder: AVAudioRecorder
        do {
            recorder = try AVAudioRecorder(url: file, settings: Self.settings)
        } catch {
            // The microphone session does not stay open after a failed start.
            deactivateAfterFailedStart(session: session)
            throw error
        }
        recorder.delegate = self
        // `record(forDuration:)` is not used: in the watchOS 26.5 Simulator it neither stopped nor closed the file at the
        // limit (WatchRecorderTests); the watchdog below ends the recording on the recorded time instead.
        let started: Bool = recorder.prepareToRecord() && recorder.record()
        guard started else {
            recorder.delegate = nil
            recorder.stop()
            recorder.deleteRecording()
            deactivateAfterFailedStart(session: session)
            throw WatchRecorderError.recorderRefused
        }
        self.recorder = recorder
        observeSystem(session: session)
        startWatchdog(limitSec: limitSec)
        WKInterfaceDevice.current().play(.start)
    }

    /// Follows interruptions (a call, Siri) and an audio system restart: either ends the recording, the file is closed.
    private func observeSystem(session: AVAudioSession) {
        let center: NotificationCenter = NotificationCenter.default
        observerTokens = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] (notification: Notification) in
                let typeValue: UInt? = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began: Bool = typeValue.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
                let reasonValue: UInt? = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
                MainActor.assumeIsolated {
                    guard began else {
                        return
                    }
                    Self.logger.info("Watch recording interrupted, reason: \(reasonValue.map(String.init) ?? "none", privacy: .public)")
                    self?.finishAfterSystemStop(reason: .interrupted)
                }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] (_: Notification) in
                MainActor.assumeIsolated {
                    Self.logger.error("Audio services were reset during a Watch recording")
                    self?.finishAfterSystemStop(reason: .failed)
                }
            },
        ]
    }

    /// Every `watchdogSec`: the recorded time (pauses excluded, `AVAudioRecorder.currentTime`) against the account's
    /// limit, and the battery against `watchRecordingLowBatteryLevel`. Either ends the recording and saves it.
    private func startWatchdog(limitSec: TimeInterval?) {
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.watchdogSec, repeats: true) { [weak self] (_: Timer) in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else {
                    return
                }
                if let limitSec, recorder.currentTime >= limitSec {
                    Self.logger.info("Watch recording reached the meeting limit, seconds: \(Int(limitSec), privacy: .public)")
                    self.finishAfterSystemStop(reason: .limitReached)
                } else if watchShouldEndForBattery(battery: Self.batteryState(device: WKInterfaceDevice.current())) {
                    Self.logger.info("Watch recording ended for low battery")
                    self.finishAfterSystemStop(reason: .lowBattery)
                }
            }
        }
    }

    private static func batteryState(device: WKInterfaceDevice) -> WatchBatteryState {
        switch device.batteryState {
        case .charging, .full:
            .charging
        case .unplugged:
            .discharging(level: device.batteryLevel)
        case .unknown:
            .unknown
        @unknown default:
            .unknown
        }
    }

    /// Releases the session after a failed start; its own error is only logged so the start's error is the one shown.
    private func deactivateAfterFailedStart(session: AVAudioSession) {
        do {
            try session.setActive(false)
        } catch {
            Self.logger.error("Audio session could not be released after a failed start, error: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops and closes the file (the user pressed End). `stop()` writes the file's index synchronously.
    func stop() {
        guard recorder != nil else {
            return
        }
        release()
        WKInterfaceDevice.current().play(.stop)
    }

    private func finishAfterSystemStop(reason: WatchSystemStop) {
        guard recorder != nil else {
            return
        }
        release()
        WKInterfaceDevice.current().play(.stop)
        onSystemStop?(reason)
    }

    private func release() {
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
        observerTokens = []
        watchdog?.invalidate()
        watchdog = nil
        WKInterfaceDevice.current().isBatteryMonitoringEnabled = false
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            Self.logger.error("Audio session could not be released, error: \(String(describing: error), privacy: .public)")
        }
    }
}

extension WatchRecorder: AVAudioRecorderDelegate {
    /// The recording stopped without "End" or the watchdog (the delegate is detached before either stops it): the system
    /// stopped the recorder. Whatever was written is closed and kept.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Self.logger.error("Watch recorder stopped by the system, successfully: \(flag, privacy: .public)")
        Task { @MainActor in
            self.finishAfterSystemStop(reason: .failed)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Self.logger.error("Watch recording encoder failed, error: \(String(describing: error), privacy: .public)")
        Task { @MainActor in
            self.finishAfterSystemStop(reason: .failed)
        }
    }
}
