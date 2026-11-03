import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AINotepadCore

/// Deterministic pseudo-random fingerprint: every seed gives a different screen (about 90 % of the cells differ by
/// more than `cellDelta` between two seeds).
func seededFingerprint(seed: Int) -> ScreenFingerprint {
    let count: Int = screenFingerprintWidth * screenFingerprintHeight
    let luma: [UInt8] = (0..<count).map { (cell: Int) -> UInt8 in
        var value: UInt64 = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ cell &* 40_503 &+ 97)
        value ^= value >> 13
        value = value &* 0x5bd1e995
        value ^= value >> 15
        return UInt8(truncatingIfNeeded: value)
    }
    return ScreenFingerprint(width: screenFingerprintWidth, height: screenFingerprintHeight, luma: luma)
}

/// A candidate at `index` (10 s apart) with the given speech and size.
func screenCandidate(index: Int, speechChars: Int, width: Int, height: Int, fingerprint: ScreenFingerprint) -> ScreenNoteCandidate {
    ScreenNoteCandidate(
        snapshot: screenSnapshot(offsetSec: Double(index) * 10), startSec: Double(index) * 10, endSec: Double(index) * 10 + 10,
        speechChars: speechChars, fingerprint: fingerprint, size: ScreenPixelSize(width: width, height: height)
    )
}

/// A "slide": coloured background, a dark title bar and `index`-dependent blocks, drawn at `width`×`height` and stored
/// as the meeting's snapshot at `offsetSec`.
func writeTestSlide(meetingDirectory: URL, offsetSec: Double, index: Int, width: Int, height: Int) throws {
    let context: CGContext = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let hue: CGFloat = CGFloat(index % 7) / 7
    context.setFillColor(CGColor(red: 0.2 + hue * 0.7, green: 0.9 - hue * 0.6, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: Double(height) * 0.8, width: Double(width), height: Double(height) * 0.2))
    for block in 0..<4 where (index >> block) & 1 == 1 {
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: Double(width) * Double(block) / 4, y: 0, width: Double(width) / 4, height: Double(height) * 0.6))
    }
    let image: CGImage = try #require(context.makeImage())
    try writeScreenSnapshot(meetingDirectory: meetingDirectory, snapshot: screenSnapshot(offsetSec: offsetSec), jpeg: try jpegData(image: image, quality: 0.7))
}

/// Pixel size of encoded JPEG bytes.
func jpegPixelSize(_ data: Data) throws -> ScreenPixelSize {
    let source: CGImageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties: [CFString: Any] = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    return ScreenPixelSize(width: try #require(properties[kCGImagePropertyPixelWidth] as? Int), height: try #require(properties[kCGImagePropertyPixelHeight] as? Int))
}

/// Meeting with one live paragraph every 10 s for `seconds`.
func screenNotesMeeting(seconds: Int) -> MeetingRecord {
    let segments: [StoredSegment] = stride(from: 0, to: seconds, by: 10).map { (start: Int) -> StoredSegment in
        StoredSegment(
            key: "live-\(start)", speaker: start % 20 == 0 ? .me : .others, person: start % 20 == 0 ? nil : 1, startSec: Double(start),
            endSec: Double(start) + 8, text: String(repeating: "konuşma ", count: 1 + (start / 10) % 9), words: nil
        )
    }
    return MeetingRecord(
        id: "m", title: "m", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: .turkish, status: .done, failureMessage: nil,
        liveSegments: segments, finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .local,
        notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct ScreenNotesTests {
    // Same formula and examples as the server (`server/test/llmImages.test.ts`) and the vision docs' table.
    @Test func visualTokensFollowThe28PixelPatches() {
        #expect(screenVisualTokens(width: 812, height: 448) == 29 * 16)
        #expect(screenVisualTokens(width: 1, height: 1) == 1)
        #expect(screenVisualTokens(width: 29, height: 28) == 2)
        #expect(screenVisualTokens(width: 1000, height: 1000) == 1_296)
        #expect(screenVisualTokens(width: 1092, height: 1092) == 1_521)
    }

    // Whatever the source (tiny, huge, extreme aspect ratios), the size never exceeds the token cap or the long edge,
    // is never upscaled, keeps the aspect, and uses most of the allowance when the source is large enough.
    @Test func imageSizeAlwaysFitsTheCaps() throws {
        let sources: [(Int, Int)] = [
            (1, 1), (27, 29), (100, 50), (784, 448), (1280, 720), (1440, 900), (1600, 1000), (1920, 1080), (2560, 1600), (3024, 1964), (3840, 2160),
            (8000, 8000), (7999, 13), (10_000, 1), (1, 8000), (1600, 30), (30, 1600), (5120, 1440), (1179, 2556), (999, 1001),
        ]
        for (width, height) in sources {
            for maxTokens in [1, 64, 200, 450, 451, 1_000] {
                let size: ScreenPixelSize = try #require(screenNoteImageSize(width: width, height: height, maxTokens: maxTokens, maxLongEdge: 1_024))
                let tokens: Int = screenVisualTokens(width: size.width, height: size.height)
                #expect(tokens <= maxTokens, "\(width)x\(height) at \(maxTokens): \(size.width)x\(size.height) = \(tokens)")
                #expect(max(size.width, size.height) <= 1_024)
                #expect(size.width <= width && size.height <= height)
                if size.width > 28, size.height > 28 {
                    let aspect: Double = Double(width) / Double(height)
                    #expect(abs(Double(size.width) / Double(size.height) - aspect) / aspect < 0.05, "\(width)x\(height) → \(size.width)x\(size.height)")
                }
                // Tokens of the source capped only by the long edge: when that exceeds the cap, the cap must be mostly used.
                let edgeScale: Double = min(1, 1_024 / Double(max(width, height)))
                let full: Int = screenVisualTokens(width: Int(Double(width) * edgeScale), height: Int(Double(height) * edgeScale))
                if full > maxTokens, min(width, height) >= 200, maxTokens >= 200 {
                    #expect(Double(tokens) >= Double(maxTokens) * 0.8, "wasteful: \(width)x\(height) at \(maxTokens) → \(tokens)")
                }
            }
        }
        #expect(screenNoteImageSize(width: 0, height: 10, maxTokens: 450, maxLongEdge: 1_024) == nil)
        #expect(screenNoteImageSize(width: 10, height: 10, maxTokens: 0, maxLongEdge: 1_024) == nil)
        // A 16:10 Mac screen at the app's cap is ~730 px wide (~440 tokens).
        let slide: ScreenPixelSize = try #require(screenNoteImageSize(width: 1600, height: 1000, maxTokens: 450, maxLongEdge: 1_024))
        #expect(slide.width >= 700 && slide.width <= 840 && screenVisualTokens(width: slide.width, height: slide.height) >= 420)
    }

    // The hard budget: 300 distinct huge snapshots (the per-meeting maximum) and every budget variation never exceed
    // the image count or the total visual tokens.
    @Test func selectionNeverExceedsTheBudget() {
        let shapes: [(Int, Int)] = [(8000, 8000), (3840, 2160), (10_000, 1), (1, 8000), (1179, 2556), (1600, 1000), (5120, 1440)]
        let candidates: [ScreenNoteCandidate] = (0..<screenSnapshotPolicy.maxPerMeeting).map { (index: Int) -> ScreenNoteCandidate in
            let shape: (Int, Int) = shapes[index % shapes.count]
            return screenCandidate(index: index, speechChars: (index * 37) % 900, width: shape.0, height: shape.1, fingerprint: seededFingerprint(seed: index))
        }
        let budgets: [ScreenNoteBudget] = [
            screenNoteBudget,
            ScreenNoteBudget(maxImages: 6, maxImageTokens: 1_000, maxTotalTokens: 2_700, minImageTokens: 64, maxLongEdge: 2_576, maxImageBytes: 250_000),
            ScreenNoteBudget(maxImages: 50, maxImageTokens: 450, maxTotalTokens: 2_700, minImageTokens: 1, maxLongEdge: 1_024, maxImageBytes: 250_000),
            ScreenNoteBudget(maxImages: 6, maxImageTokens: 450, maxTotalTokens: 100, minImageTokens: 64, maxLongEdge: 1_024, maxImageBytes: 250_000),
            ScreenNoteBudget(maxImages: 6, maxImageTokens: 450, maxTotalTokens: 10, minImageTokens: 64, maxLongEdge: 1_024, maxImageBytes: 250_000),
        ]
        for budget in budgets {
            let selected: [ScreenNoteSelection] = selectScreenNoteImages(candidates: candidates, excludedIDs: [], budget: budget, policy: screenSnapshotPolicy)
            #expect(selected.count <= budget.maxImages)
            #expect(selected.reduce(0) { $0 + $1.tokens } <= budget.maxTotalTokens)
            for selection in selected {
                #expect(selection.tokens == screenVisualTokens(width: selection.size.width, height: selection.size.height))
                #expect(selection.tokens <= budget.maxImageTokens && max(selection.size.width, selection.size.height) <= budget.maxLongEdge)
            }
        }
        let app: [ScreenNoteSelection] = selectScreenNoteImages(candidates: candidates, excludedIDs: [], budget: screenNoteBudget, policy: screenSnapshotPolicy)
        #expect(app.count == 6)
        #expect(app.reduce(0) { $0 + $1.tokens } <= 2_700)
        #expect(selectScreenNoteImages(candidates: candidates, excludedIDs: [], budget: budgets[4], policy: screenSnapshotPolicy).isEmpty)
    }

    // The most-discussed screens win, in time order; unticked and near-identical ones (the same slide shown again)
    // are left out.
    @Test func selectionPrefersDiscussedScreensAndSkipsDuplicatesAndExclusions() {
        let slide: ScreenFingerprint = seededFingerprint(seed: 1)
        let candidates: [ScreenNoteCandidate] = [
            screenCandidate(index: 0, speechChars: 50, width: 1600, height: 1000, fingerprint: seededFingerprint(seed: 10)),
            screenCandidate(index: 1, speechChars: 900, width: 1600, height: 1000, fingerprint: slide),
            screenCandidate(index: 2, speechChars: 800, width: 1600, height: 1000, fingerprint: slide),
            screenCandidate(index: 3, speechChars: 700, width: 1600, height: 1000, fingerprint: seededFingerprint(seed: 3)),
            screenCandidate(index: 4, speechChars: 10, width: 1600, height: 1000, fingerprint: seededFingerprint(seed: 4)),
        ]
        let budget: ScreenNoteBudget = ScreenNoteBudget(maxImages: 2, maxImageTokens: 450, maxTotalTokens: 2_700, minImageTokens: 64, maxLongEdge: 1_024, maxImageBytes: 250_000)
        let picked: [String] = selectScreenNoteImages(candidates: candidates, excludedIDs: [], budget: budget, policy: screenSnapshotPolicy).map(\.snapshot.id)
        #expect(picked == [candidates[1].snapshot.id, candidates[3].snapshot.id])
        let withoutTop: [String] = selectScreenNoteImages(
            candidates: candidates, excludedIDs: [candidates[1].snapshot.id], budget: budget, policy: screenSnapshotPolicy
        ).map(\.snapshot.id)
        #expect(withoutTop == [candidates[2].snapshot.id, candidates[3].snapshot.id])
        #expect(selectScreenNoteImages(candidates: candidates, excludedIDs: Set(candidates.map(\.snapshot.id)), budget: budget, policy: screenSnapshotPolicy).isEmpty)
    }

    // A long silent screen still counts: time on screen weighs like speech at ~15 characters a second.
    @Test func scoreCountsTimeOnScreen() {
        let silent: ScreenNoteCandidate = ScreenNoteCandidate(
            snapshot: screenSnapshot(offsetSec: 0), startSec: 0, endSec: 120, speechChars: 0, fingerprint: seededFingerprint(seed: 1),
            size: ScreenPixelSize(width: 100, height: 100)
        )
        #expect(screenNoteScore(candidate: silent) == 1_800)
    }

    @Test func exclusionsToggleAndPrune() throws {
        let a: String = screenSnapshot(offsetSec: 1).id
        let b: String = screenSnapshot(offsetSec: 2).id
        #expect(toggledScreenNoteExclusion(excluded: [], snapshotID: a) == [a])
        #expect(toggledScreenNoteExclusion(excluded: [a, b], snapshotID: a) == [b])
        #expect(prunedScreenNoteExclusions(excluded: [a, b], snapshots: [screenSnapshot(offsetSec: 2)]) == [b])
        let meeting: URL = try temporaryDirectory()
        #expect(try readScreenNoteExclusions(meetingDirectory: meeting).isEmpty)
        try writeTestSlide(meetingDirectory: meeting, offsetSec: 1, index: 1, width: 64, height: 40)
        try writeScreenNoteExclusions(meetingDirectory: meeting, excluded: [b, a])
        #expect(try readScreenNoteExclusions(meetingDirectory: meeting) == [a, b])
        // The exclusions file is not a snapshot.
        #expect(try listScreenSnapshots(meetingDirectory: meeting).map(\.id) == [a])
        try writeScreenNoteExclusions(meetingDirectory: meeting, excluded: [])
        #expect(!FileManager.default.fileExists(atPath: screenSnapshotsDirectory(meetingDirectory: meeting).appending(path: screenNoteExclusionsFileName).path))
    }

    // From disk: a full meeting (300 snapshots, odd sizes, some unticked) gives at most 6 JPEGs whose real pixel sizes
    // stay within the token budget and whose bytes stay within the server's cap; labels carry the time on screen.
    @Test func imagesFromDiskStayWithinTheBudget() throws {
        let meeting: URL = try temporaryDirectory()
        let shapes: [(Int, Int)] = [(1600, 1000), (1600, 900), (1600, 40), (40, 1600), (1179, 1600), (1600, 1600)]
        for index in 0..<screenSnapshotPolicy.maxPerMeeting {
            let shape: (Int, Int) = shapes[index % shapes.count]
            try writeTestSlide(meetingDirectory: meeting, offsetSec: Double(index) * 6 + 1, index: index, width: shape.0 / 4, height: shape.1 / 4)
        }
        // A few big ones (screen-size) among them.
        for index in 0..<3 {
            try writeTestSlide(meetingDirectory: meeting, offsetSec: Double(index) * 6 + 2, index: index + 8, width: 3200, height: 2000)
        }
        let excluded: ScreenSnapshot = screenSnapshot(offsetSec: 2)
        try writeScreenNoteExclusions(meetingDirectory: meeting, excluded: [excluded.id])
        let images: [LLMImage] = try screenNoteImages(
            record: screenNotesMeeting(seconds: 1_900), meetingDirectory: meeting, budget: screenNoteBudget, policy: screenSnapshotPolicy
        )
        #expect(!images.isEmpty && images.count <= screenNoteBudget.maxImages)
        var tokens: Int = 0
        for image in images {
            let size: ScreenPixelSize = try jpegPixelSize(image.jpeg)
            tokens += screenVisualTokens(width: size.width, height: size.height)
            #expect(image.jpeg.count <= screenNoteBudget.maxImageBytes)
            #expect(image.label.hasPrefix("Ekran ") && image.label.contains("–"))
        }
        #expect(tokens <= screenNoteBudget.maxTotalTokens)
        // Nothing there: no images.
        #expect(try screenNoteImages(record: screenNotesMeeting(seconds: 60), meetingDirectory: try temporaryDirectory(), budget: screenNoteBudget, policy: screenSnapshotPolicy).isEmpty)
    }

    // The big screen-size slide is redrawn at exactly the selected size (the server counts tokens from the JPEG header).
    @Test func encodesAtTheExactSelectedSize() throws {
        let meeting: URL = try temporaryDirectory()
        try writeTestSlide(meetingDirectory: meeting, offsetSec: 5, index: 3, width: 3024, height: 1964)
        let file: URL = screenSnapshotFile(meetingDirectory: meeting, snapshot: screenSnapshot(offsetSec: 5))
        #expect(try screenImagePixelSize(file: file) == ScreenPixelSize(width: 3024, height: 1964))
        let size: ScreenPixelSize = try #require(screenNoteImageSize(width: 3024, height: 1964, maxTokens: 450, maxLongEdge: 1_024))
        let jpeg: Data = try screenNoteJPEG(file: file, size: size, maxBytes: screenNoteBudget.maxImageBytes)
        #expect(try jpegPixelSize(jpeg) == size)
        #expect(throws: ScreenImageError.self) { try screenNoteJPEG(file: file, size: size, maxBytes: 100) }
    }

    // Images go before the transcript in exactly one request: the single note or the overview of a long note, never a
    // chunk; the prompt rule is added only with images.
    @Test func imagesGoToExactlyOneRequest() throws {
        let image: LLMImage = LLMImage(label: "Ekran 1 [00:00–00:10]", jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
        let segments: [StoredSegment] = screenNotesMeeting(seconds: 60).liveSegments
        let plain: LLMRequest = try #require(meetingNoteRequest(
            segments: segments, speakerNames: [:], userName: "Doğan", template: .general, myNotes: "", language: .turkish, screens: []
        ))
        let withScreens: LLMRequest = try #require(meetingNoteRequest(
            segments: segments, speakerNames: [:], userName: "Doğan", template: .general, myNotes: "", language: .turkish, screens: [image]
        ))
        #expect(plain.images.isEmpty && !plain.system.contains("Ekran 2 [12:40"))
        #expect(withScreens.images == [image] && withScreens.system.contains("Ekran 2 [12:40–14:05]"))
        #expect(withScreens.userText == plain.userText)
        let chunk: LLMRequest = noteChunkRequest(
            chunk: segments, part: 1, partCount: 2, state: .empty, speakerNames: [:], userName: "Doğan", template: .general, myNotes: "", language: .turkish
        )
        #expect(chunk.images.isEmpty)
        let overview: LLMRequest = noteOverviewRequest(state: .empty, userName: "Doğan", template: .general, myNotes: "", language: .english, screens: [image])
        #expect(overview.images == [image] && overview.system.contains("English"))
    }

    // Hosted body: each label then its image (base64 JPEG) before the text; without images the content stays a string.
    @Test func hostedBodyCarriesImageBlocks() throws {
        let jpeg: Data = Data([0xff, 0xd8, 0xff, 0xd9])
        let request: LLMRequest = LLMRequest(
            purpose: .note, tier: .smart, system: "s", userText: "<transkript>x</transkript>", maxTokens: 1000, jsonSchema: nil, timeoutSec: 30,
            images: [LLMImage(label: "Ekran 1 [00:00–00:10]", jpeg: jpeg), LLMImage(label: "Ekran 2 [00:10–00:20]", jpeg: jpeg)]
        )
        let body: [String: Any] = try #require(try JSONSerialization.jsonObject(with: hostedLLMRequestBody(request: request, effort: .medium, maxTokensCap: 8192)) as? [String: Any])
        let messages: [[String: Any]] = try #require(body["messages"] as? [[String: Any]])
        let content: [[String: Any]] = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "image", "text", "image", "text"])
        #expect(content[0]["text"] as? String == "Ekran 1 [00:00–00:10]")
        let source: [String: Any] = try #require(content[1]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64" && source["media_type"] as? String == "image/jpeg" && source["data"] as? String == jpeg.base64EncodedString())
        #expect(content[4]["text"] as? String == "<transkript>x</transkript>")
        let plain: LLMRequest = LLMRequest(purpose: .note, tier: .smart, system: "s", userText: "u", maxTokens: 1000, jsonSchema: nil, timeoutSec: 30, images: [])
        let plainBody: [String: Any] = try #require(try JSONSerialization.jsonObject(with: hostedLLMRequestBody(request: plain, effort: .medium, maxTokensCap: 8192)) as? [String: Any])
        #expect((plainBody["messages"] as? [[String: Any]])?.first?["content"] as? String == "u")
    }

    // Providers other than the Gistsmith server never silently drop images: the call fails before any network.
    @Test func otherProvidersRejectImages() async throws {
        let request: LLMRequest = LLMRequest(
            purpose: .note, tier: .smart, system: "s", userText: "u", maxTokens: 1000, jsonSchema: nil, timeoutSec: 1,
            images: [LLMImage(label: "Ekran 1", jpeg: Data([0xff]))]
        )
        await #expect(throws: LLMError.self) {
            _ = try await sendLLM(provider: .anthropic(defaultAnthropicConfig(apiKey: "test")), request: request)
        }
    }
}
