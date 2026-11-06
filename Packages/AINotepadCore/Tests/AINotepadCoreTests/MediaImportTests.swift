import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

@Suite struct MediaImportTests {
    // Gerçek dosyalar: WAV ve (afconvert ile) 44.1 kHz stereo M4A 16 kHz mono AAC'ye dönüşür, süre korunur; sessiz/
    // olmayan dosya anlaşılır hata verir.
    @Test func importsAudioFiles() async throws {
        let fixture: URL = try #require(Bundle.module.url(forResource: "fi-dialog", withExtension: "wav", subdirectory: "Fixtures"))
        let directory: URL = try temporaryDirectory()
        let duration: Double = try await importMediaAudio(source: fixture, destination: directory.appending(path: "a.m4a"))
        let expected: Double = Double(try loadFixture(name: "fi-dialog").count) / 16000
        #expect(abs(duration - expected) < 0.2)
        let file: AVAudioFile = try AVAudioFile(forReading: directory.appending(path: "a.m4a"))
        #expect(file.fileFormat.sampleRate == 16000 && file.fileFormat.channelCount == 1)

        // Stereo AAC dosyası macOS'un `afconvert` aracıyla üretilir (iOS simülatöründe bu adım atlanır).
        #if os(macOS)
        let stereo: URL = directory.appending(path: "stereo.m4a")
        let process: Process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = ["-f", "m4af", "-d", "aac@44100", "-c", "2", fixture.path, stereo.path]
        try process.run()
        process.waitUntilExit()
        let converted: Double = try await importMediaAudio(source: stereo, destination: directory.appending(path: "b.m4a"))
        #expect(abs(converted - expected) < 0.3)
        #endif

        let text: URL = directory.appending(path: "not-audio.txt")
        try Data("merhaba".utf8).write(to: text)
        await #expect(throws: MediaImportError.self) {
            try await importMediaAudio(source: text, destination: directory.appending(path: "c.m4a"))
        }
    }
}

extension CloudTests {
@Suite struct MediaImportCloudTests {
    // Gerçek uçtan uca: dosya içe aktarılır, ElevenLabs son geçişi konuşmacıları ayırır, Claude notu yazar.
    @Test func importedFileBecomesMeetingWithNote() async throws {
        let fixture: URL = try #require(Bundle.module.url(forResource: "fi-dialog", withExtension: "wav", subdirectory: "Fixtures"))
        let directory: URL = try temporaryDirectory()
        let duration: Double = try await importMediaAudio(source: fixture, destination: directory.appending(path: "others.m4a"))
        let record: MeetingRecord = importedMeetingRecord(id: "import", source: fixture, startedAt: Date(), durationSec: duration, engine: .cloud, template: .general)
        let result: MeetingRecord = await processMeeting(
            record: record, directory: directory,
            finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: [])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), languageMode: .automatic, userName: "Doğan", profile: .empty,
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [], screens: .off,
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .done, "\(result.failureMessage ?? "")")
        #expect(Set(result.finalSegments.compactMap(\.person)).count >= 2)
        #expect(result.note != nil)
        #expect(result.language == .finnish)
    }

    // İsveççe dosya: dil İsveççe algılanır, not Türkçe yazılır (rapor ve bütçe Türkçe geçer).
    @Test func swedishFileBecomesTurkishNote() async throws {
        let fixture: URL = try #require(Bundle.module.url(forResource: "sv-meeting", withExtension: "wav", subdirectory: "Fixtures"))
        let directory: URL = try temporaryDirectory()
        let duration: Double = try await importMediaAudio(source: fixture, destination: directory.appending(path: "others.m4a"))
        let record: MeetingRecord = importedMeetingRecord(id: "import-sv", source: fixture, startedAt: Date(), durationSec: duration, engine: .cloud, template: .general)
        let result: MeetingRecord = await processMeeting(
            record: record, directory: directory,
            finalPass: .run(ElevenLabsFinalTranscriber(apiKey: try cloudKey(account: .elevenlabs), keyterms: [])),
            llm: .anthropic(defaultAnthropicConfig(apiKey: try cloudKey(account: .anthropic))), languageMode: .automatic, userName: "Doğan", profile: .empty,
            noteLanguage: .turkish, voiceEmbedder: nil, registry: [], screens: .off,
            onStep: { (_: ProcessingStep) async -> Void in }
        )
        #expect(result.status == .done, "\(result.failureMessage ?? "")")
        #expect(result.language == .swedish)
        let note: MeetingNote = try #require(result.note)
        let text: String = (note.summary + " " + note.tasks.map(\.description).joined(separator: " ")).lowercased()
        #expect(["rapor", "bütçe", "sunum"].contains { text.contains($0) }, "not: \(text)")
    }
}
}

@Suite struct AudioLevelTests {
    // Sessizlik 0, tam ölçek sinüs ~1, konuşma düzeyi arada; ölçülü akış parçaları değiştirmeden geçirir.
    @Test func levelsAndMeteredStream() async {
        #expect(audioLevel(samples: [Float](repeating: 0, count: 1600)) == 0)
        let loud: [Float] = (0..<1600).map { Float(sin(Double($0) * 0.1)) }
        #expect(audioLevel(samples: loud) > 0.9)
        let speech: [Float] = loud.map { $0 * 0.05 }
        #expect((0.3...0.8).contains(audioLevel(samples: speech)))
        let (input, sink): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let collected: LevelBox = LevelBox()
        let metered: AsyncStream<[Float]> = meteredStream(audio: input, onLevel: { collected.append($0) })
        sink.yield(loud)
        sink.yield(speech)
        sink.finish()
        var chunks: [[Float]] = []
        for await chunk in metered {
            chunks.append(chunk)
        }
        #expect(chunks == [loud, speech])
        #expect(collected.values.count == 2)
    }
}

/// Seviye geri çağrılarını toplar (testte eşzamanlı erişim için kilitli).
private final class LevelBox: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: [Float] = []

    func append(_ value: Float) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite struct AudioClipTests {
    // İki kayıt aynı aralıkta tek klibe karışır; süre aralık kadar; aralık kayıtların dışındaysa açık hata.
    @Test func exportsMixedClip() async throws {
        let first: URL = try #require(Bundle.module.url(forResource: "fi-meeting", withExtension: "wav", subdirectory: "Fixtures"))
        let second: URL = try #require(Bundle.module.url(forResource: "en-meeting", withExtension: "wav", subdirectory: "Fixtures"))
        let destination: URL = try temporaryDirectory().appending(path: "klip.m4a")
        let range: (start: Double, end: Double) = clipRange(startSec: 1.5, endSec: 5.5)
        try await exportAudioClip(sources: [first, second], startSec: range.start, endSec: range.end, destination: destination)
        let duration: Double = try await AVURLAsset(url: destination).load(.duration).seconds
        #expect(abs(duration - 5) < 0.3, "süre: \(duration)")
        await #expect(throws: AudioClipError.self) {
            try await exportAudioClip(sources: [first], startSec: 600, endSec: 610, destination: try temporaryDirectory().appending(path: "bos.m4a"))
        }
    }

    // Aralık paragrafın yarım saniye öncesinden yarım saniye sonrasına; başta 0'ın altına inmez, ters aralık başlangıçtan
    // sonra biter. Dosya adı toplantı adı ve ":" yerine "." ile an.
    @Test func clipRangeAndTitle() {
        let middle: (start: Double, end: Double) = clipRange(startSec: 10, endSec: 20)
        #expect(middle.start == 9.5 && middle.end == 20.5)
        let first: (start: Double, end: Double) = clipRange(startSec: 0.2, endSec: 3)
        #expect(first.start == 0 && first.end == 3.5)
        let reversed: (start: Double, end: Double) = clipRange(startSec: 8, endSec: 5)
        #expect(reversed.start == 7.5 && reversed.end == 8.5)
        #expect(audioClipTitle(meetingTitle: "Bütçe", startSec: 65) == "Bütçe 01.05")
        #expect(audioClipTitle(meetingTitle: "Plan", startSec: 3725) == "Plan 1.02.05")
    }

    // iPhone'un sakladığı biçimler: işlenmemiş kayıt 16 kHz 16-bit `.caf` (`CafRecorder`), işlenmiş kayıt `.m4a`
    // (`convertToM4A`). İkisinden (ve karışık) klip çıkar; aralık kaydın sonunu aşarsa kaydın sonunda biter.
    @Test func exportsClipFromStoredRecordingFormats() async throws {
        let samples: [Float] = try loadFixture(name: "fi-meeting")
        let directory: URL = try temporaryDirectory()
        let caf: URL = directory.appending(path: "others.caf")
        let recorder: CafRecorder = try CafRecorder(fileURL: caf)
        try recorder.append(samples: samples)
        recorder.close()
        let m4a: URL = directory.appending(path: "me.m4a")
        try convertToM4A(source: caf, destination: m4a)
        let total: Double = Double(samples.count) / 16000

        let fromCaf: URL = directory.appending(path: "caf-klip.m4a")
        try await exportAudioClip(sources: [caf], startSec: 1, endSec: 4, destination: fromCaf)
        #expect(abs(try await AVURLAsset(url: fromCaf).load(.duration).seconds - 3) < 0.3)

        let mixed: URL = directory.appending(path: "karisik-klip.m4a")
        try await exportAudioClip(sources: [caf, m4a], startSec: 2, endSec: 5, destination: mixed)
        #expect(abs(try await AVURLAsset(url: mixed).load(.duration).seconds - 3) < 0.3)

        let tail: URL = directory.appending(path: "son-klip.m4a")
        try await exportAudioClip(sources: [m4a], startSec: total - 1, endSec: total + 5, destination: tail)
        #expect(abs(try await AVURLAsset(url: tail).load(.duration).seconds - 1) < 0.3)
    }
}
