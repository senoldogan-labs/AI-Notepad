import Foundation
import os
import Testing
@testable import AINotepadCore

/// Not kalitesi değerlendirmesi (gerçek API çağrısı, ücretli) yalnızca bu değişken "1" ise çalışır. Anahtar Anahtar
/// Zinciri'nden değil ortamdan okunur (`AINOTEPAD_EVAL_ANTHROPIC_KEY`). Çalıştırma:
/// `AINOTEPAD_NOTE_EVAL=1 AINOTEPAD_EVAL_ANTHROPIC_KEY=… swift test --package-path Packages/AINotepadCore --filter NoteQualityEval`.
/// `AINOTEPAD_NOTE_EVAL_OUT` bir klasörse notlar ve puanlar oraya da yazılır.
let noteEvalEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_NOTE_EVAL"] == "1"

/// Kısa fikstürlerin her biri bu kadar kez yazılıp puanlanır (modelin çeşitliliği tek çalıştırmayı yanıltmasın).
let noteEvalRepeats: Int = 3

// MARK: - Fikstürler

/// Beklenen görev: sahip (katlanmış eşitlik) ve açıklamada geçen sözcüklerden biri; `dueStated` transkriptte tarih var mı.
struct ExpectedTask: Decodable, Sendable {
    let owner: String
    let keywords: [String]
    let dueStated: Bool
}

/// Beklenen karar: metinde geçen sözcüklerden biri, alındığı an aralığı (saniye) ve gerekçesinde geçen sözcüklerden biri.
struct ExpectedDecision: Decodable, Sendable {
    let keywords: [String]
    let fromSec: Double
    let toSec: Double
    let rationale: [String]
}

/// Beklenen açık konu: metinde geçen sözcüklerden biri.
struct ExpectedQuestion: Decodable, Sendable {
    let keywords: [String]
}

/// Bir fikstürün beklentileri (`<ad>.expect.json`).
struct NoteEvalExpectation: Decodable, Sendable {
    let noteLanguage: String
    let tasks: [ExpectedTask]
    let decisions: [ExpectedDecision]
    let openQuestions: [ExpectedQuestion]
    /// Notta geçmesi gereken önemli ayrıntılar; her satır eş biçimlerden biri ("18.000" ya da "18 bin").
    let facts: [[String]]
}

/// Değerlendirilecek toplantı.
struct NoteEvalFixture: Sendable {
    let name: String
    let segments: [StoredSegment]
    let speakerNames: [Int: String]
    let userName: String
    let language: ShareLanguage
    let expectation: NoteEvalExpectation?
}

/// `Fixtures/NoteEval/<ad>.txt` biçimi: `# names: 1=Ayşe, 2=Mehmet`, `# user: Doğan`, sonra `mm:ss pN: metin` (N kişi
/// numarası) ya da `mm:ss me: metin` satırları. Bölümün sonu bir sonraki satırın başıdır. Saf fonksiyondur.
func parsedEvalTranscript(text: String) -> (segments: [StoredSegment], names: [Int: String], user: String) {
    let lines: [String] = text.split(separator: "\n").map(String.init)
    let header: (String) -> String = { (key: String) -> String in
        lines.first { $0.hasPrefix("# \(key):") }.map { String($0.dropFirst("# \(key):".count)).trimmingCharacters(in: .whitespaces) } ?? ""
    }
    let names: [Int: String] = Dictionary(uniqueKeysWithValues: header("names").split(separator: ",").compactMap { (pair: Substring) -> (Int, String)? in
        let parts: [String] = pair.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let number = Int(parts[0]) else {
            return nil
        }
        return (number, parts[1])
    })
    let rows: [(start: Double, speaker: String, text: String)] = lines.filter { !$0.hasPrefix("#") }.compactMap { (line: String) -> (start: Double, speaker: String, text: String)? in
        let parts: [Substring] = line.split(separator: " ", maxSplits: 2)
        guard parts.count == 3, let start = timestampSeconds(text: String(parts[0])) else {
            return nil
        }
        return (start, String(parts[1].dropLast()), String(parts[2]))
    }
    let segments: [StoredSegment] = rows.enumerated().map { (item: (offset: Int, element: (start: Double, speaker: String, text: String))) -> StoredSegment in
        let end: Double = item.offset + 1 < rows.count ? rows[item.offset + 1].start : item.element.start + 10
        let person: Int? = item.element.speaker == "me" ? nil : Int(item.element.speaker.dropFirst())
        return StoredSegment(
            key: "eval-\(item.offset)", speaker: person == nil ? .me : .others, person: person, startSec: item.element.start, endSec: end,
            text: item.element.text, words: nil
        )
    }
    return (segments, names, header("user"))
}

func loadedEvalFixture(name: String) throws -> NoteEvalFixture {
    let directory: URL = try #require(Bundle.module.url(forResource: "NoteEval", withExtension: nil, subdirectory: "Fixtures"))
    let transcript: (segments: [StoredSegment], names: [Int: String], user: String) = parsedEvalTranscript(
        text: try String(contentsOf: directory.appending(path: "\(name).txt"), encoding: .utf8)
    )
    let expectation: NoteEvalExpectation = try JSONDecoder().decode(NoteEvalExpectation.self, from: Data(contentsOf: directory.appending(path: "\(name).expect.json")))
    return NoteEvalFixture(
        name: name, segments: transcript.segments, speakerNames: transcript.names, userName: transcript.user,
        language: try #require(ShareLanguage(rawValue: expectation.noteLanguage)), expectation: expectation
    )
}

// MARK: - Maliyet ölçümü

/// Bir modelin harcadığı token'lar ve tutarı (USD).
struct EvalSpend: Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var dollars: Double
}

/// Model başına 1 milyon token fiyatı (giriş, çıkış; USD). Haiku 5.5'te 100 bin token'ı aşan istem pahalı dilimdedir.
func evalPrice(model: String, inputTokens: Int) -> (input: Double, output: Double) {
    switch model {
    case ClaudeModel.haiku.rawValue: inputTokens > 100_000 ? (0.50, 2.50) : (0.10, 0.50)
    case ClaudeModel.sonnet.rawValue: (2, 10)
    case ClaudeModel.opus.rawValue: (4, 20)
    default: (10, 50)
    }
}

/// Akış (SSE) gövdesindeki kullanım: `message_start` girişi, son `message_delta` çıkışı. Saf fonksiyondur.
func streamUsage(body: Data) -> (input: Int, output: Int) {
    let events: [[String: Any]] = String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline)
        .filter { $0.hasPrefix("data:") }
        .compactMap { (line: Substring) -> [String: Any]? in
            try? JSONSerialization.jsonObject(with: Data(line.dropFirst("data:".count).utf8)) as? [String: Any]
        }
    let start: [String: Any] = ((events.first { $0["type"] as? String == "message_start" }?["message"] as? [String: Any])?["usage"] as? [String: Any]) ?? [:]
    let input: Int = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { start[$0] as? Int }.reduce(0, +)
    let output: Int = (events.last { $0["type"] as? String == "message_delta" }?["usage"] as? [String: Any])?["output_tokens"] as? Int ?? 0
    return (input, output)
}

/// api.anthropic.com isteklerini araya girip aynen ileten ve her yanıtın kullanımını model başına toplayan katman:
/// uygulamanın gerçek yolu (`writeMeetingNote`, yeniden denemeler dahil) değişmeden ölçülür.
final class MeteredAnthropicProtocol: URLProtocol, @unchecked Sendable {
    static let spend: OSAllocatedUnfairLock<[String: EvalSpend]> = OSAllocatedUnfairLock(initialState: [:])
    private static let forwarder: URLSession = URLSession(configuration: .ephemeral)
    private var forwarding: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "api.anthropic.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var body: URLRequest = request
        body.httpBody = request.httpBody ?? request.httpBodyStream.map(streamData)
        // Değişmez kopya: görev değişken bir isteği yakalarsa yeni derleyici veri yarışı hatası verir.
        let forwarded: URLRequest = body
        let model: String = forwarded.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["model"] as? String ?? "?"
        let sink: ProtocolSink = ProtocolSink(owner: self, client: client)
        forwarding = Task {
            do {
                let (data, response): (Data, URLResponse) = try await Self.forwarder.data(for: forwarded)
                let usage: (input: Int, output: Int) = streamUsage(body: data)
                let price: (input: Double, output: Double) = evalPrice(model: model, inputTokens: usage.input)
                Self.spend.withLock { (spend: inout [String: EvalSpend]) -> Void in
                    var current: EvalSpend = spend[model] ?? EvalSpend(inputTokens: 0, outputTokens: 0, dollars: 0)
                    current.inputTokens += usage.input
                    current.outputTokens += usage.output
                    current.dollars += Double(usage.input) * price.input / 1_000_000 + Double(usage.output) * price.output / 1_000_000
                    spend[model] = current
                }
                sink.finish(response: response, data: data)
            } catch {
                sink.fail(error: error)
            }
        }
    }

    override func stopLoading() {
        forwarding?.cancel()
    }
}

/// Yanıtı URL sistemine geri veren uç: istemci yalnızca bir kez, tek görevden çağrılır.
private struct ProtocolSink: @unchecked Sendable {
    let owner: URLProtocol
    let client: (any URLProtocolClient)?

    func finish(response: URLResponse, data: Data) {
        client?.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(owner, didLoad: data)
        client?.urlProtocolDidFinishLoading(owner)
    }

    func fail(error: any Error) {
        client?.urlProtocol(owner, didFailWithError: error)
    }
}

/// Akıştaki gövdenin tamamı.
private func streamData(stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data: Data = Data()
    var buffer: [UInt8] = [UInt8](repeating: 0, count: 64 * 1024)
    while stream.hasBytesAvailable {
        let count: Int = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else {
            break
        }
        data.append(buffer, count: count)
    }
    return data
}

/// Şimdiye kadarki toplam harcama (USD) ve model başına satır.
func evalSpendReport() -> (total: Double, lines: [String]) {
    let spend: [String: EvalSpend] = MeteredAnthropicProtocol.spend.withLock { $0 }
    let lines: [String] = spend.keys.sorted().map { (model: String) -> String in
        let item: EvalSpend = spend[model]!
        return "\(model): giriş \(item.inputTokens), çıkış \(item.outputTokens), $\(String(format: "%.4f", item.dollars))"
    }
    return (spend.values.map(\.dollars).reduce(0, +), lines)
}

// MARK: - Belirlenimci denetimler

/// Karşılaştırma için katlanmış metin (küçük harf, aksansız; bkz. `searchFolded`). Saf fonksiyondur.
func folded(_ text: String) -> String {
    searchFolded(text)
}

/// Metin sözcüklerden birini içeriyor mu (katlanmış). Saf fonksiyondur.
func containsAny(text: String, keywords: [String]) -> Bool {
    let haystack: String = folded(text)
    return keywords.contains { haystack.contains(folded($0)) }
}

/// Notun düz metni (yargıç ve sayı denetimi için): başlık, özet, kararlar, görevler, açık konular, akış, sözlük.
func evalNoteText(note: MeetingNote) -> String {
    var lines: [String] = ["# \(note.title)", "", note.summary, "", "## Decisions"]
    lines += note.decisions.map { "- \($0)" }
    lines += ["", "## Tasks"] + note.tasks.map { "- \($0.owner): \($0.description)\($0.dueDate.map { " (due: \($0))" } ?? "")" }
    lines += ["", "## Open questions"] + (note.openQuestions ?? []).map { "- \($0)" }
    lines += ["", "## Outline"] + (note.outline ?? []).map { "- [\(timestamp(seconds: $0.startSec))] \($0.title): \($0.summary)" }
    lines += ["", "## Glossary"] + note.glossary.map { "- \($0.term): \($0.meaning)" }
    return lines.joined(separator: "\n")
}

/// Metindeki sayılar (zaman damgaları ve "Konuşmacı N" etiketleri hariç), ayırıcısız: "18.000" → "18000", "2,1" → "21". "200 bin" ve "15
/// thousand" biçimleri binle çarpılır. Saf fonksiyondur.
func numberTokens(text: String) -> Set<String> {
    let withoutTimes: String = text.replacing(/\d{1,2}:\d{2}(:\d{2})?/, with: " ").replacing(/(Konuşmacı|Speaker) \d+/, with: " ")
    let expanded: String = withoutTimes.replacing(/(\d+)\s*(bin|thousand|k)\b/.ignoresCase()) { (match: Regex<(Substring, Substring, Substring)>.Match) -> String in
        "\(match.output.1)000"
    }
    return Set(expanded.matches(of: /\d+(?:[.,]\d+)*/).map { String($0.output).filter(\.isNumber) })
}

/// Bir notun belirlenimci puanları.
struct DeterministicScore: Codable, Sendable {
    var tasksFound: Int = 0
    var tasksExpected: Int = 0
    /// Bulunan ve transkriptte tarihi olan görevlerden tarihi yazılanlar.
    var duesKept: Int = 0
    var duesExpected: Int = 0
    var decisionsFound: Int = 0
    var decisionsExpected: Int = 0
    /// Bulunan kararlardan gerekçesi yazılanlar.
    var decisionsWithRationale: Int = 0
    /// Bulunan kararlardan zamanı beklenen aralıkta olanlar.
    var decisionsTimed: Int = 0
    var openQuestionsFound: Int = 0
    var openQuestionsExpected: Int = 0
    var factsFound: Int = 0
    var factsExpected: Int = 0
    /// Transkriptte geçmeyen sayılar (uydurma şüphesi; elle bakılır).
    var unsupportedNumbers: [String] = []
    /// Transkriptte ve katılımcılarda olmayan görev sahipleri.
    var unknownOwners: [String] = []
    /// Toplantı süresi dışında ya da sırasız zamanlar (akış ve karar).
    var invalidTimes: Int = 0
}

/// Notu fikstürün beklentileriyle karşılaştırır. Saf fonksiyondur.
func deterministicScore(note: MeetingNote, fixture: NoteEvalFixture, expectation: NoteEvalExpectation) -> DeterministicScore {
    var score: DeterministicScore = DeterministicScore()
    let transcript: String = fixture.segments.map(\.text).joined(separator: "\n")
    let ownerMatches: (String, String) -> Bool = { (owner: String, expected: String) -> Bool in
        folded(owner) == folded(expected) || folded(owner).replacing("speaker", with: "konusmaci") == folded(expected)
    }
    for expected in expectation.tasks {
        score.tasksExpected += 1
        guard let found = note.tasks.first(where: { ownerMatches($0.owner, expected.owner) && containsAny(text: $0.description, keywords: expected.keywords) }) else {
            continue
        }
        score.tasksFound += 1
        if expected.dueStated {
            score.duesExpected += 1
            score.duesKept += found.dueDate == nil ? 0 : 1
        }
    }
    let decisions: [AnchoredLine] = note.decisions.map { anchoredLine(text: $0) }
    for expected in expectation.decisions {
        score.decisionsExpected += 1
        guard let found = decisions.first(where: { containsAny(text: $0.text, keywords: expected.keywords) }) else {
            continue
        }
        score.decisionsFound += 1
        score.decisionsWithRationale += containsAny(text: found.text, keywords: expected.rationale) ? 1 : 0
        score.decisionsTimed += found.startSec.map { $0 >= expected.fromSec && $0 <= expected.toSec } == true ? 1 : 0
    }
    let questions: [String] = note.openQuestions ?? []
    for expected in expectation.openQuestions {
        score.openQuestionsExpected += 1
        score.openQuestionsFound += questions.contains { containsAny(text: $0, keywords: expected.keywords) } ? 1 : 0
    }
    let noteText: String = evalNoteText(note: note)
    for fact in expectation.facts {
        score.factsExpected += 1
        score.factsFound += containsAny(text: noteText, keywords: fact) ? 1 : 0
    }
    score.unsupportedNumbers = numberTokens(text: noteText).subtracting(numberTokens(text: transcript)).sorted()
    let known: [String] = [fixture.userName, "Sen", "You"] + Array(fixture.speakerNames.values)
    score.unknownOwners = Set(note.tasks.map(\.owner)).filter { (owner: String) -> Bool in
        let isLabel: Bool = owner.wholeMatch(of: /(Konuşmacı|Speaker) \d+/) != nil
        return !isLabel && !known.contains { folded($0) == folded(owner) } && !folded(transcript).contains(folded(owner))
    }.sorted()
    let duration: Double = fixture.segments.map(\.endSec).max() ?? 0
    let outline: [Double] = (note.outline ?? []).map(\.startSec)
    let times: [Double] = outline + decisions.compactMap(\.startSec)
    score.invalidTimes = times.filter { $0 < 0 || $0 > duration + 1 }.count + (outline == outline.sorted() ? 0 : 1)
    return score
}

// MARK: - Yargıç

/// Yargıcın puanları (1–5) ve bulduğu hatalar.
struct JudgeScore: Codable, Sendable {
    let accuracy: Int
    let completeness: Int
    let decisions: Int
    let openQuestions: Int
    let clarity: Int
    let concision: Int
    let errors: [String]
    let omissions: [String]

    var mean: Double {
        Double(accuracy + completeness + decisions + openQuestions + clarity + concision) / 6
    }
}

/// Yargıç isteği (Opus 5.5): transkript ve not verilir, ölçüte göre puanlar. Saf fonksiyondur.
func noteJudgeRequest(fixture: NoteEvalFixture, note: MeetingNote) -> LLMRequest {
    LLMRequest(
        purpose: .note,
        tier: .smart,
        system: """
        You are a strict reviewer of AI-written meeting notes. The note's goal: be as correct as possible, detailed where
        it matters, and leave no question in a reader's head that the transcript could answer. The user ("Sen" in the
        transcript) is \(fixture.userName). Unnamed speakers appear as "Konuşmacı N"; the note may write them as
        "Konuşmacı N" or "Speaker N". Score each dimension from 1 (bad) to 5 (excellent):
        - accuracy: every statement is supported by the transcript (names, numbers, dates, owners, who said what). Any
          factual error caps this at 2; an invented fact caps it at 1.
        - completeness: the important specifics (numbers, names, dates, amounts, commitments, deadlines) are present.
        - decisions: each decision says what was decided and, when the transcript gives one, why.
        - openQuestions: unresolved issues, ambiguities and pending follow-ups are surfaced explicitly. Give 1 if the
          transcript has open issues and the note does not surface them.
        - clarity: someone who missed the meeting understands what happened, what is next and who owns what.
        - concision: no padding, repetition or generic filler.
        List every factual error (quote the note, say what the transcript says) and every important omission. Be strict
        and consistent; do not reward length.
        """,
        userText: """
        <transcript>
        \(storedLines(segments: fixture.segments, speakerNames: fixture.speakerNames))
        </transcript>

        <note>
        \(evalNoteText(note: note))
        </note>
        """,
        maxTokens: 8000,
        jsonSchema: """
        {"type":"object","properties":{"accuracy":{"type":"integer"},"completeness":{"type":"integer"},"decisions":{"type":"integer"},\
        "openQuestions":{"type":"integer"},"clarity":{"type":"integer"},"concision":{"type":"integer"},\
        "errors":{"type":"array","items":{"type":"string"}},"omissions":{"type":"array","items":{"type":"string"}}},\
        "required":["accuracy","completeness","decisions","openQuestions","clarity","concision","errors","omissions"],"additionalProperties":false}
        """,
        timeoutSec: 300,
        images: [], webSearch: nil
    )
}

// MARK: - Uzun toplantı

/// Uzun fikstürün (her tur bir aşama) üçte birlik dilimlere göre kapsaması.
struct LongCoverage: Codable, Sendable {
    /// Dilim başına kararlarda geçen aşama sayısı / dilimdeki aşama.
    let decisionPhases: [String]
    /// Dilim başına konu akışı satırı.
    let outlinePerThird: [Int]
    /// Dilim başına görev kapsaması (üç iş × aşama).
    let taskCoveragePerThird: [String]
    /// Özette geçen aşama numaralarının dilimlere dağılımı.
    let summaryPhasesPerThird: [Int]
    let openQuestions: Int
    let decisionsTimed: Int
    let decisions: Int
}

/// Uzun toplantı notunun dilim kapsaması. Saf fonksiyondur.
func longCoverage(note: MeetingNote, rounds: Int) -> LongCoverage {
    let third: Int = rounds / 3
    let ranges: [ClosedRange<Int>] = [1...third, (third + 1)...(2 * third), (2 * third + 1)...rounds]
    let decisionNumbers: Set<Int> = Set(note.decisions.flatMap { anchoredLine(text: $0).text.split { !$0.isNumber }.compactMap { Int($0) } })
    let summaryNumbers: Set<Int> = Set(note.summary.split { !$0.isNumber }.compactMap { Int($0) })
    let coverage: TaskCoverage = taskCoverage(tasks: note.tasks, phases: rounds)
    let missingPhases: [Int] = coverage.missing.compactMap { Int($0.split(separator: " ").last ?? "") }
    let duration: Double = Double(rounds) * 240
    return LongCoverage(
        decisionPhases: ranges.map { "\($0.filter { decisionNumbers.contains($0) }.count)/\($0.count)" },
        outlinePerThird: (0..<3).map { (index: Int) -> Int in
            (note.outline ?? []).filter { $0.startSec >= duration * Double(index) / 3 && $0.startSec < duration * Double(index + 1) / 3 }.count
        },
        taskCoveragePerThird: ranges.map { (range: ClosedRange<Int>) -> String in
            "\(range.count * 3 - missingPhases.filter { range.contains($0) }.count)/\(range.count * 3)"
        },
        summaryPhasesPerThird: ranges.map { $0.filter { summaryNumbers.contains($0) }.count },
        openQuestions: (note.openQuestions ?? []).count,
        decisionsTimed: note.decisions.filter { anchoredLine(text: $0).startSec != nil }.count,
        decisions: note.decisions.count
    )
}

// MARK: - Çalıştırma

/// Bir fikstürün bir çalıştırmasının sonucu.
struct NoteEvalResult: Codable, Sendable {
    let fixture: String
    let run: Int
    let deterministic: DeterministicScore
    let judge: JudgeScore
}

/// Sonuçları ve notu `AINOTEPAD_NOTE_EVAL_OUT` klasörüne yazar (değişken yoksa yazmaz).
func writeEvalOutput(name: String, text: String) throws {
    guard let path = ProcessInfo.processInfo.environment["AINOTEPAD_NOTE_EVAL_OUT"] else {
        return
    }
    let directory: URL = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try text.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
}

/// Notu uygulamanın yoluyla yazan sağlayıcı: Gistsmith'in modeli (Haiku 5.5) ve not effort'u.
func evalWriterProvider(apiKey: String) -> LLMProvider {
    .anthropic(AnthropicConfig(
        apiKey: apiKey, fastModel: .haiku, smartModel: .haiku, fastEffort: hostedEffort(tier: .fast), smartEffort: hostedEffort(tier: .smart)
    ))
}

@Suite(.enabled(if: noteEvalEnabled), .serialized)
struct NoteQualityEval {
    private func apiKey() throws -> String {
        try #require(ProcessInfo.processInfo.environment["AINOTEPAD_EVAL_ANTHROPIC_KEY"], "AINOTEPAD_EVAL_ANTHROPIC_KEY gerekli")
    }

    @Test func shortMeetings() async throws {
        URLProtocol.registerClass(MeteredAnthropicProtocol.self)
        defer { URLProtocol.unregisterClass(MeteredAnthropicProtocol.self) }
        let key: String = try apiKey()
        let judge: LLMProvider = .anthropic(AnthropicConfig(apiKey: key, fastModel: .opus, smartModel: .opus, fastEffort: .medium, smartEffort: .medium))
        var results: [NoteEvalResult] = []
        for name in ["tr-release", "en-client", "tr-inperson"] {
            let fixture: NoteEvalFixture = try loadedEvalFixture(name: name)
            let expectation: NoteEvalExpectation = try #require(fixture.expectation)
            for run in 1...noteEvalRepeats {
                let note: MeetingNote = try #require(try await writeMeetingNote(
                    segments: fixture.segments, speakerNames: fixture.speakerNames, userName: fixture.userName, template: .general, myNotes: "",
                    language: fixture.language, llm: evalWriterProvider(apiKey: key),
                    progressFile: try temporaryDirectory().appending(path: "eval-progress.json"), screens: []
                ))
                // Adlar uygulamadaki gibi okunurken uygulanır (`namedNote`); not genel etiketlerle yazılır.
                let shown: MeetingNote = namedNote(note: note, speakerNames: fixture.speakerNames, userName: fixture.userName)
                let judged: JudgeScore = try await requestStructured(provider: judge, request: noteJudgeRequest(fixture: fixture, note: shown)) { (text: String) throws -> JudgeScore in
                    try JSONDecoder().decode(JudgeScore.self, from: Data(jsonBody(text: text).utf8))
                }
                let result: NoteEvalResult = NoteEvalResult(
                    fixture: name, run: run, deterministic: deterministicScore(note: shown, fixture: fixture, expectation: expectation), judge: judged
                )
                results.append(result)
                try writeEvalOutput(name: "\(name)-\(run).md", text: evalNoteText(note: shown))
                print("EVAL \(name)#\(run) yargıç \(String(format: "%.2f", judged.mean)) \(judged) belirlenimci \(result.deterministic)")
            }
        }
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeEvalOutput(name: "short-results.json", text: String(decoding: try encoder.encode(results), as: UTF8.self))
        print("EVAL ÖZET \(evalSummary(results: results))")
        let spend: (total: Double, lines: [String]) = evalSpendReport()
        print("EVAL MALİYET $\(String(format: "%.4f", spend.total)) — \(spend.lines.joined(separator: "; "))")
    }

    @Test func longMeeting() async throws {
        URLProtocol.registerClass(MeteredAnthropicProtocol.self)
        defer { URLProtocol.unregisterClass(MeteredAnthropicProtocol.self) }
        let rounds: Int = 30
        let segments: [StoredSegment] = realisticMeetingSegments(rounds: rounds)
        let note: MeetingNote = try #require(try await writeMeetingNote(
            segments: segments, speakerNames: [:], userName: "Doğan", template: .general, myNotes: "", language: .turkish,
            llm: evalWriterProvider(apiKey: try apiKey()), progressFile: try temporaryDirectory().appending(path: "eval-long-progress.json"), screens: []
        ))
        let coverage: LongCoverage = longCoverage(note: namedNote(note: note, speakerNames: [1: "Aino", 2: "Mikko"], userName: "Doğan"), rounds: rounds)
        try writeEvalOutput(name: "long.md", text: evalNoteText(note: note))
        let encoder: JSONEncoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeEvalOutput(name: "long-results.json", text: String(decoding: try encoder.encode(coverage), as: UTF8.self))
        print("EVAL uzun (\(rounds * 4) dk, \(segments.map(\.text.count).reduce(0, +)) karakter): \(coverage)")
        let spend: (total: Double, lines: [String]) = evalSpendReport()
        print("EVAL MALİYET $\(String(format: "%.4f", spend.total)) — \(spend.lines.joined(separator: "; "))")
    }
}

/// Çalıştırmaların ortalamaları: yargıç boyutları ve belirlenimci oranlar. Saf fonksiyondur.
func evalSummary(results: [NoteEvalResult]) -> String {
    let count: Double = Double(max(results.count, 1))
    let average: (KeyPath<JudgeScore, Int>) -> String = { (path: KeyPath<JudgeScore, Int>) -> String in
        String(format: "%.2f", Double(results.map { $0.judge[keyPath: path] }.reduce(0, +)) / count)
    }
    let ratio: (KeyPath<DeterministicScore, Int>, KeyPath<DeterministicScore, Int>) -> String = { (found: KeyPath<DeterministicScore, Int>, total: KeyPath<DeterministicScore, Int>) -> String in
        "\(results.map { $0.deterministic[keyPath: found] }.reduce(0, +))/\(results.map { $0.deterministic[keyPath: total] }.reduce(0, +))"
    }
    let decisionsFound: KeyPath<DeterministicScore, Int> = \.decisionsFound
    return [
        "yargıç ort. \(String(format: "%.2f", results.map(\.judge.mean).reduce(0, +) / count))",
        "doğruluk \(average(\.accuracy))", "eksiksizlik \(average(\.completeness))", "kararlar \(average(\.decisions))",
        "açık konular \(average(\.openQuestions))", "açıklık \(average(\.clarity))", "özlülük \(average(\.concision))",
        "görev \(ratio(\.tasksFound, \.tasksExpected))", "tarih \(ratio(\.duesKept, \.duesExpected))",
        "karar \(ratio(decisionsFound, \.decisionsExpected))", "gerekçe \(ratio(\.decisionsWithRationale, decisionsFound))",
        "karar zamanı \(ratio(\.decisionsTimed, decisionsFound))", "açık konu \(ratio(\.openQuestionsFound, \.openQuestionsExpected))",
        "ayrıntı \(ratio(\.factsFound, \.factsExpected))",
        "dayanaksız sayı \(results.map(\.deterministic.unsupportedNumbers.count).reduce(0, +))",
        "bilinmeyen sahip \(results.map(\.deterministic.unknownOwners.count).reduce(0, +))",
        "geçersiz zaman \(results.map(\.deterministic.invalidTimes).reduce(0, +))",
        "yargıç hata \(results.map(\.judge.errors.count).reduce(0, +))",
    ].joined(separator: ", ")
}
