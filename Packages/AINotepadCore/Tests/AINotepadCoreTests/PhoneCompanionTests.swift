import AINotepadWatchLink
import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import AINotepadCore

/// The iPhone's Apple Watch page state, the "Share Gistsmith" link and QR code, the support email and what the "Clear
/// storage" quick action may delete.
@Suite struct PhoneCompanionTests {
    private func facts(supported: Bool, activated: Bool, paired: Bool, installed: Bool, system: Int) -> WatchSessionFacts {
        WatchSessionFacts(isSupported: supported, isActivated: activated, isPaired: paired, isWatchAppInstalled: installed, systemMajorVersion: system)
    }

    // Support first, then the iPhone's system, then activation, pairing and installation.
    @Test func watchSetupStateOrder() {
        let required: Int = watchAppMinimumPhoneSystemMajorVersion
        #expect(watchSetupState(facts: facts(supported: false, activated: true, paired: true, installed: true, system: 26), requiredMajorVersion: required) == .unsupported)
        #expect(
            watchSetupState(facts: facts(supported: true, activated: true, paired: true, installed: true, system: 18), requiredMajorVersion: required)
                == .needsNewerSystem(requiredMajorVersion: 26)
        )
        #expect(watchSetupState(facts: facts(supported: true, activated: false, paired: false, installed: false, system: 26), requiredMajorVersion: required) == .checking)
        #expect(watchSetupState(facts: facts(supported: true, activated: true, paired: false, installed: false, system: 26), requiredMajorVersion: required) == .noWatchPaired)
        #expect(watchSetupState(facts: facts(supported: true, activated: true, paired: true, installed: false, system: 27), requiredMajorVersion: required) == .appNotInstalled)
        #expect(watchSetupState(facts: facts(supported: true, activated: true, paired: true, installed: true, system: 26), requiredMajorVersion: required) == .ready)
    }

    // The invite link wins; without one the site link with an allowed campaign source.
    @Test func shareLinkPrefersInvite() throws {
        let invite: URL = try #require(URL(string: "https://gistsmith.com/invite/ABCD2345"))
        #expect(shareAppLink(inviteURL: invite) == invite)
        let site: URL = shareAppLink(inviteURL: nil)
        let items: [URLQueryItem] = URLComponents(url: site, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(site.host() == "gistsmith.com")
        #expect(items.first { $0.name == "utm_source" }?.value == "qr")
        #expect(items.first { $0.name == "utm_campaign" }?.value == "share-app")
    }

    // The branded QR code (Ember ink on cream) decodes back to the same link, also with the centre covered by the icon.
    @Test func qrCodeDecodesBack() throws {
        let link: String = shareAppSiteURL.absoluteString
        let image: CGImage = try qrCodeImage(text: link, moduleScale: 12, ink: QRCodeColor(hex: 0x2A1A12), paper: QRCodeColor(hex: 0xF7F0E6))
        #expect(image.width == image.height)
        #expect(try decodedQRCodes(image: image) == [link])
        #expect(try decodedQRCodes(image: try coveringCentre(image: image, fraction: 0.24)) == [link])
        #expect(throws: QRCodeError.notEncodable(characterCount: 0)) {
            try qrCodeImage(text: "", moduleScale: 4, ink: QRCodeColor(hex: 0), paper: QRCodeColor(hex: 0xFFFFFF))
        }
    }

    // Only app version, system and device model; the subject and address are encoded.
    @Test func supportMailCarriesOnlyDeviceFacts() throws {
        let url: URL = try #require(supportMailURL(
            address: supportEmailAddress, subject: "Gistsmith support",
            facts: SupportMailFacts(appVersion: "0.2.6 (53)", systemVersion: "iOS 26.1", deviceModel: "iPhone17,1")
        ))
        let components: URLComponents = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == supportEmailAddress)
        #expect(components.queryItems?.first { $0.name == "subject" }?.value == "Gistsmith support")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == "\n\n—\nGistsmith 0.2.6 (53)\niOS 26.1\niPhone17,1")
    }

    private func meeting(id: String, startedAt: Date) -> MeetingRecord {
        MeetingRecord(
            id: id, title: id, startedAt: startedAt, endedAt: nil, language: nil, status: .done, failureMessage: nil, liveSegments: [], finalSegments: [],
            translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: nil, notice: nil, meNeedsFinalPass: nil
        )
    }

    // Only a failed meeting with nothing written whose audio is deleted or unreadable. Never one "Process again" can
    // still recover: an expired subscription or missing AI consent (readable audio), an interruption, a transient or
    // unknown failure. Never a note, transcript, own notes, highlight, the sample or a locked meeting.
    @Test func clearableMeetingsCanNeverGiveANote() {
        let start: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let permanent: ProcessingFailureKind = processingFailureKind(error: AudioCaptureError.recorderFailed(path: "others.caf", reason: "okunamadı"))
        let undecodable: MeetingRecord = meeting(id: "a", startedAt: start.addingTimeInterval(30)).failed(message: "x", kind: permanent)
        let interrupted: MeetingRecord = meeting(id: "b", startedAt: start.addingTimeInterval(60)).with(status: .interrupted, failureMessage: nil)
        let failedUnknown: MeetingRecord = meeting(id: "c", startedAt: start.addingTimeInterval(20)).with(status: .failed, failureMessage: "x")
        let transient: MeetingRecord = meeting(id: "d", startedAt: start).failed(message: "x", kind: .transient)
        let withNote: MeetingRecord = meeting(id: "f", startedAt: start).failed(message: "x", kind: permanent)
            .with(note: MeetingNote(title: "t", summary: "s", decisions: [], tasks: [], glossary: []))
        let withTranscript: MeetingRecord = meeting(id: "g", startedAt: start).failed(message: "x", kind: permanent)
            .with(liveSegments: [StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 0, endSec: 1, text: "Hello", words: nil)])
        let withMyNotes: MeetingRecord = meeting(id: "h", startedAt: start).failed(message: "x", kind: permanent).with(myNotes: "Budget")
        let withHighlight: MeetingRecord = meeting(id: "i", startedAt: start).failed(message: "x", kind: permanent)
            .with(highlights: [Highlight(startSec: 3, endSec: nil)])
        let sample: MeetingRecord = meeting(id: "j", startedAt: start).failed(message: "x", kind: permanent).markedAsSample()
        let locked: MeetingRecord = meeting(id: "k", startedAt: start).failed(message: "x", kind: permanent)
        let done: MeetingRecord = meeting(id: "l", startedAt: start)
        let queued: MeetingRecord = meeting(id: "m", startedAt: start).with(status: .queued, failureMessage: nil)
        let interruptedWithoutAudio: MeetingRecord = meeting(id: "n", startedAt: start.addingTimeInterval(40)).with(status: .interrupted, failureMessage: nil)
            .withAudioDeleted()
        let subscriptionEnded: HostedAPIError = HostedAPIError(
            code: .subscriptionRequired, rawCode: "subscription_required", status: 402, serverMessage: "", path: "/v1/meetings/x/final"
        )
        let consentMissing: HostedAPIError = HostedAPIError(code: .aiConsentRequired, rawCode: "ai_consent_required", status: 403, serverMessage: "", path: "/v1/llm")
        let expiredSubscription: MeetingRecord = meeting(id: "o", startedAt: start)
            .failed(message: "x", kind: processingFailureKind(error: subscriptionEnded))
        let missingConsent: MeetingRecord = meeting(id: "p", startedAt: start)
            .failed(message: "x", kind: processingFailureKind(error: LLMError.hosted(consentMissing)))
        let missingConsentLocally: MeetingRecord = meeting(id: "q", startedAt: start)
            .failed(message: "x", kind: processingFailureKind(error: HostedClientError.aiConsentRequired))
        let records: [MeetingRecord] = [
            undecodable, interrupted, failedUnknown, transient, withNote, withTranscript, withMyNotes, withHighlight, sample, locked, done, queued,
            interruptedWithoutAudio, expiredSubscription, missingConsent, missingConsentLocally,
        ]
        let candidates: [MeetingRecord] = clearableCandidateMeetings(records: records, locked: ["k"])
        #expect(candidates.map(\.id) == ["a", "b", "c", "d", "n", "o", "p", "q"])
        // Only "a" has unreadable audio (the rest of the unreadable set holds writing or is the sample/locked).
        let clearable: [MeetingRecord] = clearableFailedMeetings(candidates: candidates, unreadableAudioIDs: ["a", "f", "g", "h", "i", "j", "k"])
        #expect(clearable.map(\.id) == ["a", "n"])
        let items: [ClearableRecording] = clearableRecordings(
            meetings: clearable, failedWatchImports: [WatchFailedImport(id: "w", title: "Weekly sync", reason: "r")]
        )
        #expect(items.map(\.id) == ["n", "a", "w"])
        #expect(items.last?.kind == .watchRecording)
    }

    // Real files: a recording that opens for reading or a processing checkpoint is readable; a damaged recording and a
    // zero-length one are unreadable; an empty folder (a meeting synced from another device) is absent, not unreadable.
    @Test func readableAudioOnDisk() throws {
        let root: URL = FileManager.default.temporaryDirectory.appending(path: "clearable-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let url: URL = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        #expect(meetingAudioOnDisk(directory: try folder("empty")) == .absent)
        let damaged: URL = try folder("damaged")
        try Data("not audio".utf8).write(to: damaged.appending(path: "others.caf"))
        #expect(meetingAudioOnDisk(directory: damaged) == .unreadable)
        let silentFile: URL = try folder("zero-length")
        try writeTone(url: silentFile.appending(path: "me.caf"), frames: 0)
        #expect(meetingAudioOnDisk(directory: silentFile) == .unreadable)
        let good: URL = try folder("good")
        try Data("not audio".utf8).write(to: good.appending(path: "others.caf"))
        try writeTone(url: good.appending(path: "me.caf"), frames: 1_600)
        #expect(meetingAudioOnDisk(directory: good) == .readable)
        let resumable: URL = try folder("checkpoint")
        try Data("{}".utf8).write(to: resumable.appending(path: "processing-checkpoint.json"))
        #expect(meetingAudioOnDisk(directory: resumable) == .readable)
    }
}

/// A 16 kHz mono recording of `frames` samples of a quiet tone.
private func writeTone(url: URL, frames: Int) throws {
    let format: AVAudioFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let file: AVAudioFile = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard frames > 0 else {
        return
    }
    let buffer: AVAudioPCMBuffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let samples: UnsafeMutablePointer<Float> = try #require(buffer.floatChannelData?[0])
    for index in 0..<frames {
        samples[index] = Float(sin(Double(index) * 0.2) * 0.1)
    }
    try file.write(from: buffer)
}

/// The QR codes `CIDetector` finds in `image`.
private func decodedQRCodes(image: CGImage) throws -> [String] {
    let detector: CIDetector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    return detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
}

/// `image` with a square of `fraction` of its side painted over in its centre (where the app icon sits).
private func coveringCentre(image: CGImage, fraction: Double) throws -> CGImage {
    let space: CGColorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context: CGContext = try #require(CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let rect: CGRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.draw(image, in: rect)
    let side: Double = Double(image.width) * fraction
    context.setFillColor(CGColor(srgbRed: 0.8, green: 0.5, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: (Double(image.width) - side) / 2, y: (Double(image.height) - side) / 2, width: side, height: side))
    return try #require(context.makeImage())
}
