import AINotepadWatchLink
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
        #expect(items.first { $0.name == "utm_source" }?.value == "partner")
        #expect(items.first { $0.name == "utm_campaign" }?.value == "share_app")
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

    // Permanent failures, or failed/interrupted meetings without audio, with nothing written. Never a meeting "Process
    // again" can still recover (interrupted, transient or unknown failure with its audio), a note, transcript, own
    // notes, highlight, the sample or a locked meeting.
    @Test func clearableMeetingsHoldNothingWritten() {
        let start: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let failedPermanent: MeetingRecord = meeting(id: "a", startedAt: start.addingTimeInterval(30)).failed(message: "x", kind: .permanent)
        let interrupted: MeetingRecord = meeting(id: "b", startedAt: start.addingTimeInterval(60)).with(status: .interrupted, failureMessage: nil)
        let failedUnknown: MeetingRecord = meeting(id: "c", startedAt: start.addingTimeInterval(20)).with(status: .failed, failureMessage: "x")
        let transientRetrying: MeetingRecord = meeting(id: "d", startedAt: start).failed(message: "x", kind: .transient)
        let transientExhausted: MeetingRecord = meeting(id: "e", startedAt: start.addingTimeInterval(10)).failed(message: "x", kind: .transient)
            .with(automaticRetries: AutomaticRetries(count: automaticRetryLimit, lastAttemptAt: start))
        let withNote: MeetingRecord = meeting(id: "f", startedAt: start).failed(message: "x", kind: .permanent)
            .with(note: MeetingNote(title: "t", summary: "s", decisions: [], tasks: [], glossary: []))
        let withTranscript: MeetingRecord = meeting(id: "g", startedAt: start).failed(message: "x", kind: .permanent)
            .with(liveSegments: [StoredSegment(key: "me-0", speaker: .me, person: nil, startSec: 0, endSec: 1, text: "Hello", words: nil)])
        let withMyNotes: MeetingRecord = meeting(id: "h", startedAt: start).failed(message: "x", kind: .permanent).with(myNotes: "Budget")
        let withHighlight: MeetingRecord = meeting(id: "i", startedAt: start).failed(message: "x", kind: .permanent)
            .with(highlights: [Highlight(startSec: 3, endSec: nil)])
        let sample: MeetingRecord = meeting(id: "j", startedAt: start).failed(message: "x", kind: .permanent).markedAsSample()
        let locked: MeetingRecord = meeting(id: "k", startedAt: start).failed(message: "x", kind: .permanent)
        let done: MeetingRecord = meeting(id: "l", startedAt: start)
        let queued: MeetingRecord = meeting(id: "m", startedAt: start).with(status: .queued, failureMessage: nil)
        let interruptedWithoutAudio: MeetingRecord = meeting(id: "n", startedAt: start.addingTimeInterval(40)).with(status: .interrupted, failureMessage: nil)
            .withAudioDeleted()
        let records: [MeetingRecord] = [
            failedPermanent, interrupted, failedUnknown, transientRetrying, transientExhausted, withNote, withTranscript, withMyNotes, withHighlight, sample,
            locked, done, queued, interruptedWithoutAudio,
        ]
        let clearable: [MeetingRecord] = clearableFailedMeetings(records: records, locked: ["k"])
        #expect(clearable.map(\.id) == ["a", "n"])
        let items: [ClearableRecording] = clearableRecordings(
            meetings: clearable, failedWatchImports: [WatchFailedImport(id: "w", title: "Weekly sync", reason: "r")]
        )
        #expect(items.map(\.id) == ["n", "a", "w"])
        #expect(items.last?.kind == .watchRecording)
    }
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
