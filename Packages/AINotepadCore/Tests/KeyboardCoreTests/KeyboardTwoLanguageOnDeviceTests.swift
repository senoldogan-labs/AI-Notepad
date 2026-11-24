#if os(macOS)
import AVFoundation
import Foundation
import KeyboardCore
import Speech
import Testing

/// Two-language dictation on real Apple speech models (macOS 26+): mixed Turkish/English sentences are synthesized with
/// the system voices (`say`: Yelda and Samantha), read by one `SpeechAnalyzer` with a tr_TR and an en_US
/// `DictationTranscriber`, and the word errors of each language alone are compared with the merge
/// (`keyboardMergeTwoLanguages`). Only with `AINOTEPAD_ONDEVICE_TESTS=1`; needs the tr_TR and en_US dictation models
/// and the `Yelda` and `Samantha` voices. Synthetic voices change at every language boundary, which real code-switching
/// does not, so the numbers show the direction, not the real-world rate.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["AINOTEPAD_ONDEVICE_TESTS"] == "1"), .serialized)
struct KeyboardTwoLanguageOnDeviceTests {
    private struct Part {
        let language: String
        let text: String
    }

    private static let sentences: [[Part]] = [
        [Part(language: "tr", text: "Kardeşim, hele"), Part(language: "en", text: "how are you?"), Part(language: "tr", text: "Hepsi daha iyi olması gerekiyor")],
        [Part(language: "en", text: "Let's schedule the meeting for"), Part(language: "tr", text: "yarın sabah dokuzda"), Part(language: "en", text: "and send the report")],
        [Part(language: "tr", text: "Bu proje için"), Part(language: "en", text: "the quarterly roadmap"), Part(language: "tr", text: "çok önemli")],
        [Part(language: "en", text: "I think we should"), Part(language: "tr", text: "bunu müşteriye göstermeden önce"), Part(language: "en", text: "double check the numbers")],
        [Part(language: "tr", text: "Toplantıda"), Part(language: "en", text: "pull request review"), Part(language: "tr", text: "yapacağız ve sonra"), Part(language: "en", text: "deploy to production")],
        [Part(language: "tr", text: "Müşteri bize"), Part(language: "en", text: "the contract is signed"), Part(language: "tr", text: "dedi, çok sevindim")],
    ]

    @Test func mergingBothLanguagesBeatsEitherAlone() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return
        }
        var referenceWords: Int = 0
        var turkishErrors: Int = 0
        var englishErrors: Int = 0
        var mergedErrors: Int = 0
        for sentence in Self.sentences {
            let samples: [Float] = try sentence.flatMap { (part: Part) -> [Float] in try Self.speak(part) + [Float](repeating: 0, count: 800) }
                + [Float](repeating: 0, count: 8000)
            let reference: [String] = Self.words(sentence.map(\.text).joined(separator: " "))
            let result: (turkish: [Transcript], english: [Transcript]) = try await Self.transcribe(samples: samples)
            let turkishWords: [KeyboardTimedWord] = result.turkish.filter(\.isFinal).flatMap(\.words)
            let englishWords: [KeyboardTimedWord] = result.english.filter(\.isFinal).flatMap(\.words)
            let merged: String = keyboardMergeTwoLanguages(primary: turkishWords, secondary: englishWords, tuning: .standard).text
            referenceWords += reference.count
            turkishErrors += Self.editDistance(reference, Self.words(turkishWords.map(\.text).joined(separator: " ")))
            englishErrors += Self.editDistance(reference, Self.words(englishWords.map(\.text).joined(separator: " ")))
            mergedErrors += Self.editDistance(reference, Self.words(merged))
            print("two-language: \(reference.joined(separator: " ")) -> \(merged)")
        }
        print("two-language word errors of \(referenceWords): turkish only \(turkishErrors), english only \(englishErrors), merged \(mergedErrors)")
        #expect(mergedErrors * 2 <= min(turkishErrors, englishErrors), "merged \(mergedErrors) vs \(turkishErrors) / \(englishErrors)")
    }

    private struct Transcript {
        let isFinal: Bool
        let words: [KeyboardTimedWord]
    }

    /// One analyzer, two transcribers, the same audio.
    @available(macOS 26.0, iOS 26.0, *)
    private static func transcribe(samples: [Float]) async throws -> (turkish: [Transcript], english: [Transcript]) {
        let modules: [DictationTranscriber] = ["tr_TR", "en_US"].map { (identifier: String) -> DictationTranscriber in
            DictationTranscriber(
                locale: Locale(identifier: identifier), contentHints: [], transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            )
        }
        let collectors: [Task<[Transcript], any Error>] = modules.map { (module: DictationTranscriber) -> Task<[Transcript], any Error> in
            Task.detached {
                var transcripts: [Transcript] = []
                for try await result in module.results {
                    var words: [KeyboardTimedWord] = []
                    for run in result.text.runs {
                        guard let range = run.audioTimeRange, let confidence = run.transcriptionConfidence else {
                            continue
                        }
                        words.append(KeyboardTimedWord(
                            text: String(result.text[run.range].characters), start: range.start.seconds, end: range.end.seconds, confidence: confidence,
                            startsPhrase: words.isEmpty
                        ))
                    }
                    transcripts.append(Transcript(isFinal: result.isFinal, words: words))
                }
                return transcripts
            }
        }
        let format: AVAudioFormat = try #require(await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules))
        let analyzer: SpeechAnalyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: try chunks(samples: samples, format: format))
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return (try await collectors[0].value, try await collectors[1].value)
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func chunks(samples: [Float], format: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        let source: AVAudioFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let converter: AVAudioConverter = try #require(AVAudioConverter(from: source, to: format))
        let (stream, continuation): (AsyncStream<AnalyzerInput>, AsyncStream<AnalyzerInput>.Continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        var start: Int = 0
        while start < samples.count {
            let count: Int = min(1600, samples.count - start)
            let input: AVAudioPCMBuffer = try #require(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)))
            for index in 0..<count {
                input.floatChannelData?[0][index] = samples[start + index]
            }
            input.frameLength = AVAudioFrameCount(count)
            let output: AVAudioPCMBuffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(count) * format.sampleRate / 16000) + 64)
            )
            nonisolated(unsafe) var supplied: Bool = false
            nonisolated(unsafe) let pending: AVAudioPCMBuffer = input
            converter.convert(to: output, error: nil) { (_: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
                if supplied {
                    status.pointee = .noDataNow
                    return nil
                }
                supplied = true
                status.pointee = .haveData
                return pending
            }
            if output.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: output))
            }
            start += count
        }
        continuation.finish()
        return stream
    }

    /// The part spoken by the system voice of its language, as 16 kHz mono samples.
    private static func speak(_ part: Part) throws -> [Float] {
        let file: URL = FileManager.default.temporaryDirectory.appendingPathComponent("two-language-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say: Process = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", part.language == "tr" ? "Yelda" : "Samantha", "-o", file.path, part.text]
        try say.run()
        say.waitUntilExit()
        let audio: AVAudioFile = try AVAudioFile(forReading: file)
        let target: AVAudioFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let converter: AVAudioConverter = try #require(AVAudioConverter(from: audio.processingFormat, to: target))
        let input: AVAudioPCMBuffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: input)
        let output: AVAudioPCMBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(audio.length) * 16000 / audio.processingFormat.sampleRate) + 1024)
        )
        nonisolated(unsafe) var supplied: Bool = false
        nonisolated(unsafe) let pending: AVAudioPCMBuffer = input
        converter.convert(to: output, error: nil) { (_: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return pending
        }
        return Array(UnsafeBufferPointer(start: output.floatChannelData?[0], count: Int(output.frameLength)))
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    /// Word-level Levenshtein distance.
    private static func editDistance(_ reference: [String], _ heard: [String]) -> Int {
        var row: [Int] = Array(0...heard.count)
        for (i, expected) in reference.enumerated() {
            var previous: Int = row[0]
            row[0] = i + 1
            for (j, actual) in heard.enumerated() {
                let above: Int = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, previous + (expected == actual ? 0 : 1))
                previous = above
            }
        }
        return row[heard.count]
    }
}
#endif
