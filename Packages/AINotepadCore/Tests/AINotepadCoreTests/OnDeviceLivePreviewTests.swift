import AVFoundation
import Darwin
import Foundation
import Testing
@testable import AINotepadCore

/// Gives every speech segment a fixed text, or fails every segment (to test the hybrid session without a model).
private struct ScriptedEngine: TranscriptionEngine {
    let text: String?

    func detectLanguage(samples: [Float]) async throws -> [String: Float] {
        ["fi": -0.1]
    }

    func transcribe(samples: [Float], language: MeetingLanguage) async throws -> String {
        guard let text else {
            throw AppleSpeechError.previewUnavailable(language: language.rawValue)
        }
        return text
    }
}

private let finnishSpeech: AppleSpeechChoice = AppleSpeechChoice(kind: .dictation, localeIdentifier: "fi_FI")

private func sessionConfig(directory: URL, speakers: Set<Speaker>, lateSpeakers: Set<Speaker>) -> HybridLiveSessionConfig {
    HybridLiveSessionConfig(
        speakers: speakers, lateSpeakers: lateSpeakers,
        local: LiveSessionConfig(
            languageMode: .fixed(.finnish), segmenter: .live, recordingDirectory: directory,
            partialIntervalSec: 1000, minPartialSpeechSec: 1.0, languageLockAfterSec: 30, candidateLanguages: [.finnish]
        ),
        maxPendingAudioSec: 300,
        cloudFailure: .switchToLocal
    )
}

private func refusedSource() -> DeepgramLiveSource {
    let refused: HostedAPIError = HostedAPIError(code: .deepgramUnavailable, rawCode: "deepgram_unavailable", status: 503, serverMessage: "", path: "/v1/live/deepgram-token")
    return DeepgramLiveSource(
        language: .finnish, keyterms: [], options: DeepgramListenOptions(model: "nova-3", optOutOfModelImprovement: true),
        onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in }
    ) { () async throws -> String in
        throw refused
    }
}

/// The preview engine with the session's local settings and a scripted text.
private func scriptedPreview(directory: URL, text: String?) -> OnDevicePreviewEngine {
    OnDevicePreviewEngine(
        local: sessionConfig(directory: directory, speakers: [], lateSpeakers: []).local,
        engine: { () async throws -> any TranscriptionEngine in ScriptedEngine(text: text) }
    )
}

private func finals(events: [LiveSessionEvent]) -> [LiveSegment] {
    events.reduce([]) { (current: [LiveSegment], event: LiveSessionEvent) -> [LiveSegment] in
        applyEvent(transcript: current, event: event)
    }.filter(\.isFinal)
}

@Suite struct OnDeviceLivePreviewRouteTests {
    // "Diğerleri" (re-transcribed by the final pass) goes on the device only for a user in the rollout whose device is
    // ready; "Sen" (saved as its live text) always follows the server.
    @Test func routesPreviewTrackOnDeviceOnlyWhenReadyAndInRollout() {
        let ready: OnDeviceLiveSupport = .ready(finnishSpeech)
        #expect(hostedLiveRoutes(serverEngine: .deepgram, inRollout: true, support: ready) == HostedLiveRoutes(me: .cloud, others: .onDevice(finnishSpeech)))
        #expect(hostedLiveRoutes(serverEngine: .deepgram, inRollout: false, support: ready) == HostedLiveRoutes(me: .cloud, others: .cloud))
        #expect(hostedLiveRoutes(serverEngine: .whisperKit, inRollout: true, support: ready) == HostedLiveRoutes(me: .local, others: .onDevice(finnishSpeech)))
        #expect(hostedLiveRoutes(serverEngine: .whisperKit, inRollout: false, support: ready) == HostedLiveRoutes(me: .local, others: .local))
        for support in [OnDeviceLiveSupport.modelNotInstalled(finnishSpeech), .unsupportedLanguage, .requiresNewerSystem] {
            #expect(hostedLiveRoutes(serverEngine: .deepgram, inRollout: true, support: support) == HostedLiveRoutes(me: .cloud, others: .cloud))
            #expect(hostedLiveRoutes(serverEngine: .whisperKit, inRollout: true, support: support) == HostedLiveRoutes(me: .local, others: .local))
        }
    }

    @Test func supportFromDeviceFacts() {
        #expect(onDeviceLiveSupport(systemSupported: false, choice: finnishSpeech, installed: true) == .requiresNewerSystem)
        #expect(onDeviceLiveSupport(systemSupported: true, choice: nil, installed: true) == .unsupportedLanguage)
        #expect(onDeviceLiveSupport(systemSupported: true, choice: finnishSpeech, installed: false) == .modelNotInstalled(finnishSpeech))
        #expect(onDeviceLiveSupport(systemSupported: true, choice: finnishSpeech, installed: true) == .ready(finnishSpeech))
    }

    // Telemetry counts "unavailable" only for users in the rollout, and only a supported language's missing model is
    // installed for next time.
    @Test func unavailableAndInstallOnlyInRollout() {
        #expect(onDeviceLiveUnavailable(inRollout: false, support: .unsupportedLanguage) == nil)
        #expect(onDeviceLiveUnavailable(inRollout: true, support: .ready(finnishSpeech)) == nil)
        #expect(onDeviceLiveUnavailable(inRollout: true, support: .requiresNewerSystem) == .requiresNewerSystem)
        #expect(onDeviceModelToInstall(inRollout: true, support: .modelNotInstalled(finnishSpeech)) == finnishSpeech)
        #expect(onDeviceModelToInstall(inRollout: false, support: .modelNotInstalled(finnishSpeech)) == nil)
        #expect(onDeviceModelToInstall(inRollout: true, support: .unsupportedLanguage) == nil)
    }

    // The tracks per route, the cloud fallback and the diagnostics place.
    @Test func tracksFallbackAndPlace() {
        let mac: HostedLiveRoutes = HostedLiveRoutes(me: .cloud, others: .onDevice(finnishSpeech))
        #expect(cloudSpeakers(routes: mac, liveSpeakers: [.me, .others]) == [.me])
        #expect(onDeviceSpeakers(routes: mac, liveSpeakers: [.me, .others]) == [.others])
        // In-person mode and iPhone record only "Diğerleri": no cloud stream at all.
        #expect(cloudSpeakers(routes: mac, liveSpeakers: [.others]).isEmpty)
        #expect(routesAfterCloudFallback(routes: mac) == HostedLiveRoutes(me: .local, others: .onDevice(finnishSpeech)))
        #expect(hostedLivePlace(routes: mac, liveSpeakers: [.me, .others]) == .deviceAndCloud)
        #expect(hostedLivePlace(routes: mac, liveSpeakers: [.others]) == .device)
        #expect(hostedLivePlace(routes: HostedLiveRoutes(me: .cloud, others: .cloud), liveSpeakers: [.me, .others]) == .cloud)
        #expect(hostedLivePlace(routes: HostedLiveRoutes(me: .local, others: .local), liveSpeakers: []) == .device)
    }

    // An older server has no `liveOnDevice`: not in the rollout (and decoding still works).
    @Test func entitlementsRolloutFieldIsOptional() throws {
        let json: String = #"""
        {"userId":"u","plan":"trial","trialMeetingsTotal":3,"trialMeetingsLeft":1,"accountTrialMeetingsLeft":1,"deviceTrialMeetingsLeft":null,
         "monthlyHoursUsed":0,"monthlyHoursCap":10,"liveEngine":"deepgram","subscription":null}
        """#
        let old: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(json.utf8))
        #expect(!hostedLiveOnDevice(entitlements: old))
        let withField: String = json.replacingOccurrences(of: #""liveEngine":"deepgram","#, with: #""liveEngine":"deepgram","liveOnDevice":true,"#)
        #expect(hostedLiveOnDevice(entitlements: try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(withField.utf8))))
    }

    // Three failed finals in a row stop a speaker's local live text visibly, once; a success resets the run, and a
    // success after the stop reports the recovery with the stop's message (the error line goes).
    @Test func consecutiveLocalFailuresStopOnceAndRecover() {
        func final(_ index: Int, _ speaker: Speaker, failed: String?) -> LiveSessionEvent {
            .segment(LiveSegment(id: SegmentID(speaker: speaker, index: index), startSec: 0, endSec: 1, text: failed == nil ? "hei" : "", isFinal: true, failureMessage: failed, person: nil))
        }
        let events: [LiveSessionEvent] = [
            final(0, .others, failed: "x"), final(1, .others, failed: "x"), final(2, .others, failed: nil),
            final(3, .others, failed: "x"), final(4, .me, failed: "y"), final(5, .others, failed: "x"), final(6, .others, failed: "z"),
            final(7, .others, failed: "z"), .languageLocked(.finnish), final(8, .others, failed: nil), final(9, .others, failed: nil),
        ]
        var tracks: [Speaker: LocalTrackHealth] = [:]
        var reports: [LiveSessionEvent] = []
        for event in events {
            let step: LocalTracksStep = localTracksStep(tracks: tracks, event: event, threshold: localFailureThreshold)
            tracks = step.tracks
            reports += step.report.map { [$0] } ?? []
        }
        #expect(reports == [.streamFailed(speaker: .others, message: "z"), .streamRecovered(speaker: .others, message: "z")])
        #expect(tracks == [.others: .healthy, .me: .failing(consecutive: 1)])
    }

    // Every health × outcome of one final segment (threshold 3, and 1 for the immediate stop).
    @Test func localTrackTransitions() {
        #expect(localTrackStep(health: .healthy, failure: nil, threshold: 3) == LocalTrackStep(health: .healthy, report: nil))
        #expect(localTrackStep(health: .healthy, failure: "x", threshold: 3) == LocalTrackStep(health: .failing(consecutive: 1), report: nil))
        #expect(localTrackStep(health: .healthy, failure: "x", threshold: 1) == LocalTrackStep(health: .stopped(message: "x"), report: .stopped(message: "x")))
        #expect(localTrackStep(health: .failing(consecutive: 1), failure: nil, threshold: 3) == LocalTrackStep(health: .healthy, report: nil))
        #expect(localTrackStep(health: .failing(consecutive: 1), failure: "x", threshold: 3) == LocalTrackStep(health: .failing(consecutive: 2), report: nil))
        #expect(localTrackStep(health: .failing(consecutive: 2), failure: "y", threshold: 3) == LocalTrackStep(health: .stopped(message: "y"), report: .stopped(message: "y")))
        #expect(localTrackStep(health: .stopped(message: "y"), failure: "z", threshold: 3) == LocalTrackStep(health: .stopped(message: "y"), report: nil))
        #expect(localTrackStep(health: .stopped(message: "y"), failure: nil, threshold: 3) == LocalTrackStep(health: .healthy, report: .recovered(message: "y")))
    }

    // The live text state: a stop hides "written on this device" and a recovery brings it back; the cloud fallback moves
    // cloud tracks to the local engine and keeps the stops (one value, so route and flag never drift).
    @Test func liveTextStateTransitions() {
        let choice: AppleSpeechChoice = AppleSpeechChoice(kind: .dictation, localeIdentifier: "fi-FI")
        let start: LiveTextState = LiveTextState(routes: HostedLiveRoutes(me: .cloud, others: .onDevice(choice)), liveSpeakers: [.me, .others], stopped: [:])
        #expect(liveTextOnDevice(state: start))
        #expect(liveTextIsOnDevice(state: start, speaker: .others))
        #expect(!liveTextIsOnDevice(state: start, speaker: .me))
        let stopped: LiveTextState = liveTextStep(state: start, event: .streamFailed(speaker: .others, message: "model"))
        #expect(stopped.stopped == [.others: "model"])
        #expect(!liveTextOnDevice(state: stopped))
        let fellBack: LiveTextState = liveTextStep(state: stopped, event: .cloudFellBack)
        #expect(fellBack.routes == HostedLiveRoutes(me: .local, others: .onDevice(choice)))
        #expect(fellBack.stopped == [.others: "model"])
        let recovered: LiveTextState = liveTextStep(state: fellBack, event: .streamRecovered(speaker: .others))
        #expect(recovered.stopped.isEmpty)
        #expect(liveTextOnDevice(state: recovered))
        // A recovery of a track that never stopped, or a stop of a cloud track, leaves "on this device" as it was.
        #expect(liveTextStep(state: start, event: .streamRecovered(speaker: .me)) == start)
        #expect(liveTextOnDevice(state: liveTextStep(state: start, event: .streamFailed(speaker: .me, message: "x"))))
        let cloudOnly: LiveTextState = LiveTextState(routes: HostedLiveRoutes(me: .cloud, others: .cloud), liveSpeakers: [.others], stopped: [:])
        #expect(!liveTextOnDevice(state: cloudOnly))
    }
}

@Suite struct SplitHybridLiveSessionTests {
    // Mac with the on-device preview: "Diğerleri" is written by the preview engine from the start (no cloud fallback
    // event for it), "Sen" starts on the cloud stream and falls back to the regular local engine (never the preview) when
    // the grant is refused; the merged event stream ends after both.
    @Test func previewTrackRunsLocallyWhileCloudTrackKeepsItsFallback() async throws {
        let directory: URL = try temporaryDirectory()
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        // "Sen"'s audio arrives after the fallback (as in a meeting): an already ended track has nothing to fall back.
        let (me, meInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let handle: LiveSessionHandle = runSplitHybridLiveSession(
            config: sessionConfig(directory: directory, speakers: [.me, .others], lateSpeakers: []),
            start: .deepgram(refusedSource()), onDeviceSpeakers: [.others], preview: scriptedPreview(directory: directory, text: "hei"),
            localEngine: { () async throws -> any TranscriptionEngine in ScriptedEngine(text: "sen") },
            recording: startHybridRecording(directory: directory, meAudio: me, othersAudio: chunkedStream(samples: fixture, chunkSize: 1600))
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
            if case .liveEngineFellBack = event {
                for offset in stride(from: 0, to: fixture.count, by: 1600) {
                    meInput.yield(Array(fixture[offset..<min(offset + 1600, fixture.count)]))
                }
                meInput.finish()
            }
        }
        #expect(events.filter { if case .liveEngineFellBack = $0 { true } else { false } }.count == 1)
        let texts: [LiveSegment] = finals(events: events)
        #expect(texts.contains { $0.id.speaker == .others } && texts.contains { $0.id.speaker == .me })
        #expect(texts.allSatisfy { $0.text == ($0.id.speaker == .me ? "sen" : "hei") && $0.id.index >= localSegmentIndexBase })
        #expect(events.contains(.captureEnded(speaker: .me)) && events.contains(.captureEnded(speaker: .others)))
        #expect(try AVAudioFile(forReading: directory.appending(path: "me.caf")).length == AVAudioFramePosition(fixture.count))
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(fixture.count))
    }

    // iPhone and in-person mode: the only live track is on the device, so no cloud stream is opened (a refused grant
    // would otherwise show a fallback event).
    @Test func onlyPreviewTrackOpensNoCloudStream() async throws {
        let directory: URL = try temporaryDirectory()
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        let handle: LiveSessionHandle = runSplitHybridLiveSession(
            config: sessionConfig(directory: directory, speakers: [.others], lateSpeakers: []),
            start: .deepgram(refusedSource()), onDeviceSpeakers: [.others], preview: scriptedPreview(directory: directory, text: "hei"),
            localEngine: { () async throws -> any TranscriptionEngine in ScriptedEngine(text: "yerel") },
            recording: startHybridRecording(directory: directory, meAudio: chunkedStream(samples: [], chunkSize: 1600), othersAudio: chunkedStream(samples: fixture, chunkSize: 1600))
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        #expect(!events.contains { if case .liveEngineFellBack = $0 { true } else { false } })
        #expect(!finals(events: events).isEmpty && finals(events: events).allSatisfy { $0.text == "hei" })
    }

    // The server offers no cloud stream (budget used up, policy off): "Sen" keeps the regular local engine and the
    // user's settings (its live text is its saved transcript), only "Diğerleri" gets the preview engine.
    @Test func savedTrackKeepsRegularLocalEngineWithoutCloud() async throws {
        let directory: URL = try temporaryDirectory()
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        let handle: LiveSessionHandle = runSplitHybridLiveSession(
            config: sessionConfig(directory: directory, speakers: [.me, .others], lateSpeakers: []),
            start: .local, onDeviceSpeakers: [.others], preview: scriptedPreview(directory: directory, text: "hei"),
            localEngine: { () async throws -> any TranscriptionEngine in ScriptedEngine(text: "sen") },
            recording: startHybridRecording(
                directory: directory, meAudio: chunkedStream(samples: fixture, chunkSize: 1600), othersAudio: chunkedStream(samples: fixture, chunkSize: 1600)
            )
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        let texts: [LiveSegment] = finals(events: events)
        #expect(texts.contains { $0.id.speaker == .others } && texts.contains { $0.id.speaker == .me })
        #expect(texts.allSatisfy { $0.text == ($0.id.speaker == .me ? "sen" : "hei") })
    }

    // A preview whose every segment fails (model removed, language not ready) is reported once as a stopped stream; the
    // recording continues to the end.
    @Test func failingPreviewIsReportedAsStoppedStream() async throws {
        let directory: URL = try temporaryDirectory()
        let fixture: [Float] = try loadFixture(name: "fi-dialog")
        let handle: LiveSessionHandle = runSplitHybridLiveSession(
            config: sessionConfig(directory: directory, speakers: [.others], lateSpeakers: []),
            start: .local, onDeviceSpeakers: [.others], preview: scriptedPreview(directory: directory, text: nil),
            localEngine: { () async throws -> any TranscriptionEngine in ScriptedEngine(text: "yerel") },
            recording: startHybridRecording(
                directory: directory, meAudio: chunkedStream(samples: [], chunkSize: 1600),
                othersAudio: chunkedStream(samples: fixture + fixture + fixture, chunkSize: 1600)
            )
        )
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        let stopped: [LiveSessionEvent] = events.filter { if case .streamFailed = $0 { true } else { false } }
        #expect(stopped == [.streamFailed(speaker: .others, message: appleSpeechMessage(error: .previewUnavailable(language: "fi")))])
        #expect(try AVAudioFile(forReading: directory.appending(path: "others.caf")).length == AVAudioFramePosition(fixture.count * 3))
    }
}

/// Process CPU time (user + system), seconds.
private func processCPUSeconds() -> Double {
    var usage: rusage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

/// The real on-device preview path (macOS 26+, Apple's recognition): only with `AINOTEPAD_ONDEVICE_TESTS=1`. Feeds the
/// fixtures in real time through the same hybrid session the apps use and prints the CPU cost per audio second.
@Suite(.enabled(if: onDeviceTestsEnabled), .serialized)
struct OnDeviceLivePreviewEngineTests {
    @Test(arguments: [("en-meeting", MeetingLanguage.english, "report"), ("fi-dialog", MeetingLanguage.finnish, "raport")])
    func writesLivePreviewOnDevice(fixtureName: String, language: MeetingLanguage, expected: String) async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return
        }
        // Like the apps' background install: the test machine gets the model once.
        _ = try await prepareAppleSpeech(language: language) { (_: Double) -> Void in }
        #expect(await currentOnDeviceLiveSupport(language: language) == .ready(try #require(await appleSpeechChoice(language: language))))
        let directory: URL = try temporaryDirectory()
        // Four times the fixture (with a second of silence between) so the CPU figure covers a longer stretch of talk.
        let fixture: [Float] = Array(repeating: try loadFixture(name: fixtureName) + silence(seconds: 1), count: 4).flatMap { $0 }
        let (others, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let config: HybridLiveSessionConfig = HybridLiveSessionConfig(
            speakers: [.others], lateSpeakers: [],
            local: LiveSessionConfig(
                languageMode: .fixed(language), segmenter: .live, recordingDirectory: directory, partialIntervalSec: 1.5, minPartialSpeechSec: 1.0,
                languageLockAfterSec: 30, candidateLanguages: [language]
            ),
            maxPendingAudioSec: 600,
            cloudFailure: .switchToLocal
        )
        let engine: InstalledAppleSpeechEngine = InstalledAppleSpeechEngine()
        let handle: LiveSessionHandle = runSplitHybridLiveSession(
            config: config, start: .local, onDeviceSpeakers: [.others],
            preview: OnDevicePreviewEngine(local: config.local, engine: { () async throws -> any TranscriptionEngine in engine }),
            localEngine: { () async throws -> any TranscriptionEngine in ScriptedEngine(text: "yerel") },
            recording: startHybridRecording(directory: directory, meAudio: chunkedStream(samples: [], chunkSize: 1600), othersAudio: others)
        )
        let cpuBefore: Double = processCPUSeconds()
        let feeder: Task<Void, any Error> = Task {
            // 100 ms chunks in real time (the microphone's pace), so partials run as in a meeting.
            for offset in stride(from: 0, to: fixture.count, by: 1600) {
                othersInput.yield(Array(fixture[offset..<min(offset + 1600, fixture.count)]))
                try await Task.sleep(for: .milliseconds(100))
            }
            othersInput.finish()
        }
        var events: [LiveSessionEvent] = []
        for await event in handle.events {
            events.append(event)
        }
        try await feeder.value
        let cpu: Double = processCPUSeconds() - cpuBefore
        let audioSec: Double = Double(fixture.count) / 16000
        let text: String = finals(events: events).map(\.text).joined(separator: " ")
        print("on-device live preview \(fixtureName): \(String(format: "%.1f", audioSec)) s audio, CPU \(String(format: "%.2f", cpu)) s (\(String(format: "%.0f", cpu / audioSec * 100))% of one core); text: \(text)")
        #expect(text.lowercased().contains(expected), "metin: \(text)")
        #expect(!events.contains { if case .streamFailed = $0 { true } else { false } })
    }
}
