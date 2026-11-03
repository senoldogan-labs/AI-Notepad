import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import AINotepadCore

/// A slide image with a title and lines of text (fixture for the screen-notes cost test), written as the meeting's
/// snapshot at `offsetSec`.
func writeTextSlide(meetingDirectory: URL, offsetSec: Double, title: String, lines: [String]) throws {
    let (width, height): (Int, Int) = (1600, 1000)
    let context: CGContext = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let draw: (String, CGFloat, CGFloat) -> Void = { (text: String, size: CGFloat, y: CGFloat) -> Void in
        let font: CTFont = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.1, blue: 0.2, alpha: 1),
        ]
        let line: CTLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 90, y: y)
        CTLineDraw(line, context)
    }
    draw(title, 96, 820)
    for (index, line) in lines.enumerated() {
        draw(line, 64, 620 - CGFloat(index) * 120)
    }
    let image: CGImage = try #require(context.makeImage())
    try writeScreenSnapshot(meetingDirectory: meetingDirectory, snapshot: screenSnapshot(offsetSec: offsetSec), jpeg: try jpegData(image: image, quality: 0.7))
}

/// Usage and text of one Messages call.
struct MeasuredNoteCall {
    let inputTokens: Int
    let outputTokens: Int
    let text: String
}

/// Sends the request exactly as the Gistsmith server forwards it (`server/src/llm/request.ts` → `upstreamParams`):
/// the app's hosted body (same content blocks), the server's model and `output_config.effort`, not streamed. Returns
/// the API's own `usage`.
func measuredHostedNoteCall(request: LLMRequest, apiKey: String) async throws -> MeasuredNoteCall {
    let hosted: [String: Any] = try #require(
        try JSONSerialization.jsonObject(with: hostedLLMRequestBody(request: request, effort: hostedEffort(tier: request.tier), maxTokensCap: hostedMeetingMaxTokens)) as? [String: Any]
    )
    var outputConfig: [String: Any] = (hosted["output_config"] as? [String: Any]) ?? [:]
    outputConfig["effort"] = hosted["effort"]
    let upstream: [String: Any] = [
        "model": hostedModelName, "max_tokens": try #require(hosted["max_tokens"]), "system": try #require(hosted["system"]),
        "messages": try #require(hosted["messages"]), "output_config": outputConfig,
    ]
    var urlRequest: URLRequest = URLRequest(url: try #require(URL(string: "https://api.anthropic.com/v1/messages")))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = 300
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: upstream)
    for (name, value) in claudeHeaders(apiKey: apiKey, model: .haiku) {
        urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: urlRequest)
    let status: Int = (response as? HTTPURLResponse)?.statusCode ?? 0
    // The body never contains the key; on failure it explains the rejection.
    #expect(status == 200, "status \(status): \(String(decoding: data, as: UTF8.self))")
    let json: [String: Any] = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let usage: [String: Any] = try #require(json["usage"] as? [String: Any])
    let blocks: [[String: Any]] = try #require(json["content"] as? [[String: Any]])
    let input: Int = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { usage[$0] as? Int }.reduce(0, +)
    return MeasuredNoteCall(
        inputTokens: input, outputTokens: try #require(usage["output_tokens"] as? Int),
        text: blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    )
}

extension CloudTests {
    /// Real-call proof of the screen-notes cost (Gistsmith's model, Haiku 5.5): the same short meeting noted with and
    /// without its screen snapshots, through the real selection pipeline (6 slides on disk → `screenNoteImages`). The
    /// extra input tokens must stay under the image budget plus the labels and prompt rule, and the note must use what
    /// only the slides show. Run: `AINOTEPAD_CLOUD_TESTS=1 swift test --filter ScreenNotesCostTests` (Anthropic key in
    /// the Keychain, see `cloudKey`). Prints the measured tokens and dollars.
    @Suite(.serialized)
    struct ScreenNotesCostTests {
        /// Extra input a note with screens may cost: the image budget plus the time labels and the prompt rule.
        static let maxExtraInputTokens: Int = 3_000

        @Test func screensCostStaysWithinTheBudgetAndNotesUseThem() async throws {
            let meeting: URL = try temporaryDirectory()
            let slides: [(Double, String, [String])] = [
                (5, "Agenda", ["1. Pricing", "2. Roadmap", "3. Hiring"]),
                (40, "Pricing", ["Pro plan: 12 € / month", "Team plan: 29 € / seat", "Yearly: 2 months free"]),
                (100, "Roadmap Q1", ["Mobile app beta: 15 March", "Offline mode: April"]),
                (160, "Hiring", ["2 iOS engineers", "1 designer (Helsinki)"]),
                (220, "Risks", ["App Store review delay", "Server costs"]),
                (280, "Next steps", ["Send pricing to Aino by Friday"]),
            ]
            for (offset, title, lines) in slides {
                try writeTextSlide(meetingDirectory: meeting, offsetSec: offset, title: title, lines: lines)
            }
            let lines: [(Double, Speaker, Int?, String)] = [
                (6, .others, 1, "Bugün üç konu var, ekrandaki gündemden gidelim."),
                (42, .others, 1, "Fiyatlandırma slaytı açık. Ekrandaki Pro plan fiyatını onaylıyor muyuz?"),
                (60, .me, nil, "Evet, Pro planın fiyatı ekranda yazdığı gibi kalsın. Ekip planını da aynen kabul ediyorum."),
                (102, .others, 2, "Yol haritasında mobil beta tarihini ekranda görüyorsunuz, o tarihe yetişebiliriz."),
                (162, .others, 1, "İşe alımda ekrandaki sayılar geçerli, tasarımcı ilanını bu hafta açıyorum."),
                (222, .others, 2, "Risklerde App Store incelemesi en büyüğü."),
                (282, .others, 1, "Doğan, fiyat tablosunu Cuma'ya kadar bana gönderir misin?"),
                (290, .me, nil, "Tamam, Cuma günü gönderirim."),
            ]
            let segments: [StoredSegment] = lines.enumerated().map { (item: (offset: Int, element: (Double, Speaker, Int?, String))) -> StoredSegment in
                let (start, speaker, person, text): (Double, Speaker, Int?, String) = item.element
                return StoredSegment(key: "live-\(item.offset)", speaker: speaker, person: person, startSec: start, endSec: start + 12, text: text, words: nil)
            }
            let record: MeetingRecord = MeetingRecord(
                id: "cost", title: "cost", startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, language: .turkish, status: .done, failureMessage: nil,
                liveSegments: segments, finalSegments: [], translations: [:], speakerNames: [1: "Aino", 2: "Mikko"], note: nil, audioDeleted: false,
                engine: .cloud, notice: nil, meNeedsFinalPass: nil
            )
            let images: [LLMImage] = try screenNoteImages(record: record, meetingDirectory: meeting, budget: screenNoteBudget, policy: screenSnapshotPolicy)
            #expect(images.count == 6)
            let plain: LLMRequest = try #require(meetingNoteRequest(
                segments: segments, speakerNames: record.speakerNames, userName: "Doğan", template: .general, myNotes: "", language: .turkish, screens: []
            ))
            let withScreens: LLMRequest = try #require(meetingNoteRequest(
                segments: segments, speakerNames: record.speakerNames, userName: "Doğan", template: .general, myNotes: "", language: .turkish, screens: images
            ))
            let apiKey: String = try cloudKey(account: .anthropic)
            let without: MeasuredNoteCall = try await measuredHostedNoteCall(request: plain, apiKey: apiKey)
            let with: MeasuredNoteCall = try await measuredHostedNoteCall(request: withScreens, apiKey: apiKey)
            let extra: Int = with.inputTokens - without.inputTokens
            // Haiku 5.5: $0.10 / MTok input, $0.50 / MTok output (prompts under 100K tokens).
            let dollars: (MeasuredNoteCall) -> Double = { (call: MeasuredNoteCall) -> Double in
                Double(call.inputTokens) * 0.10 / 1_000_000 + Double(call.outputTokens) * 0.50 / 1_000_000
            }
            print(
                "SCREEN NOTES COST: without screens \(without.inputTokens) in / \(without.outputTokens) out ($\(dollars(without))); "
                    + "with \(images.count) screens \(with.inputTokens) in / \(with.outputTokens) out ($\(dollars(with))); extra input \(extra) tokens "
                    + "($\(Double(extra) * 0.10 / 1_000_000)); image bytes \(images.map(\.jpeg.count))"
            )
            #expect(extra > 0)
            #expect(extra <= Self.maxExtraInputTokens, "extra input \(extra) tokens")
            let note: MeetingNote = try parseMeetingNote(text: with.text)
            let written: String = ([note.summary] + note.decisions + note.tasks.map(\.description) + (note.outline ?? []).map { "\($0.title) \($0.summary)" })
                .joined(separator: "\n")
            // The price and the beta date are only on the slides, never in the transcript.
            #expect(written.contains("12") || written.contains("29"), "note: \(written)")
            #expect(written.localizedCaseInsensitiveContains("slayt") || written.localizedCaseInsensitiveContains("ekran"), "note: \(written)")
        }
    }
}
