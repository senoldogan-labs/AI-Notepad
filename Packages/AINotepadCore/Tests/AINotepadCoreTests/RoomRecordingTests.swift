import AVFoundation
import Foundation
import Testing
@testable import AINotepadCore

private func segment(_ key: String, _ speaker: Speaker, _ start: Double, _ text: String) -> StoredSegment {
    StoredSegment(key: key, speaker: speaker, person: nil, startSec: start, endSec: start + 3, text: text, words: nil)
}

private func roomRecord(live: [StoredSegment]) -> MeetingRecord {
    MeetingRecord(
        id: "room", title: "Öğretmen görüşmesi", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_001_200),
        language: nil, status: .processing, failureMessage: nil, liveSegments: live,
        finalSegments: [segment("final-0", .others, 0, "")], translations: ["me-0": "Merhaba", "others-0": "Selam"],
        speakerNames: [1: "Aino"], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: true
    )
}

/// 16 kHz mono 16 bitlik `.caf` (kayıt biçimi): `level` genlikli 440 Hz ton, 0 ise sessizlik.
private func writeCaf(url: URL, seconds: Double, level: Float) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file: AVAudioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames: AVAudioFrameCount = AVAudioFrameCount(16000 * seconds)
    let buffer: AVAudioPCMBuffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
    buffer.frameLength = frames
    let samples: UnsafeMutablePointer<Float> = try #require(buffer.floatChannelData)[0]
    for index in 0..<Int(frames) {
        samples[index] = level * sin(2 * Float.pi * 440 * Float(index) / 16000)
    }
    try file.write(from: buffer)
}

@Suite struct RoomRecordingTests {
    // Yalnız "Sen" konuşmuş ve "Diğerleri" sessizse (ya da kaydı yoksa) toplantı odada "Sen" diye kaydedilmiştir;
    // "Diğerleri" konuştuysa ya da sistem sesi etkinse (görüşme) değildir.
    @Test func detectsRoomRecordedAsMe() {
        let onlyMe: MeetingRecord = roomRecord(live: [segment("me-0", .me, 0, "Hei, aloitetaan.")])
        #expect(isRoomRecordedAsMe(record: onlyMe, othersActivity: nil))
        #expect(isRoomRecordedAsMe(record: onlyMe, othersActivity: AudioActivity(durationSec: 1200, activeSec: 3)))
        #expect(!isRoomRecordedAsMe(record: onlyMe, othersActivity: AudioActivity(durationSec: 1200, activeSec: 400)))
        let call: MeetingRecord = roomRecord(live: [segment("me-0", .me, 0, "Hei."), segment("others-0", .others, 4, "Moi.")])
        #expect(!isRoomRecordedAsMe(record: call, othersActivity: nil))
        let silentMe: MeetingRecord = roomRecord(live: [segment("me-0", .me, 0, "  ")])
        #expect(!isRoomRecordedAsMe(record: silentMe, othersActivity: nil))
    }

    // Çevrilen kayıtta "Sen" bölümleri kişisiz "Diğerleri" olur, Türkçeleri yeni anahtarla gelir; eski son geçiş,
    // adlar ve "Sen" son geçiş işareti atılır.
    @Test func relabelsMeAsOthers() {
        let record: MeetingRecord = roomRecord(live: [segment("me-0", .me, 0, "Hei, aloitetaan."), segment("others-0", .others, 5, "")])
        let relabeled: MeetingRecord = roomRecordingRelabeled(record: record)
        #expect(relabeled.liveSegments.map(\.key) == ["others-room-me-0", "others-0"])
        #expect(relabeled.liveSegments.allSatisfy { $0.speaker == .others && $0.person == nil })
        #expect(relabeled.translations == ["others-room-me-0": "Merhaba", "others-0": "Selam"])
        #expect(relabeled.finalSegments.isEmpty)
        #expect(relabeled.speakerNames.isEmpty)
        #expect(relabeled.meNeedsFinalPass == nil)
        #expect(meetingSegments(record: relabeled).map(\.speaker) == [.others])
    }

    // Dosyalarla: sessiz sistem sesi kaydı silinir, mikrofon kaydı "Diğerleri" olur. Sistem sesi etkinse (görüşme)
    // hiçbir şey değişmez.
    @Test func convertsRoomRecordingFiles() throws {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "room-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeCaf(url: directory.appending(path: "me.caf"), seconds: 4, level: 0.2)
        try writeCaf(url: directory.appending(path: "others.caf"), seconds: 4, level: 0)
        #expect(try audioActivity(url: directory.appending(path: "others.caf")).isSilent)
        let record: MeetingRecord = roomRecord(live: [segment("me-0", .me, 0, "Hei, aloitetaan.")])

        let converted: MeetingRecord = try convertingRoomRecording(record: record, directory: directory)
        #expect(converted.liveSegments.map(\.speaker) == [.others])
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "me.caf").path))
        let others: AudioActivity = try audioActivity(url: directory.appending(path: "others.caf"))
        #expect(!others.isSilent && abs(others.durationSec - 4) < 0.01)

        // Görüşme: sistem sesi etkin, kayıt ve dosyalar aynen kalır.
        try writeCaf(url: directory.appending(path: "me.caf"), seconds: 4, level: 0.2)
        #expect(try convertingRoomRecording(record: record, directory: directory) == record)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "me.caf").path))
    }
}

private func inPersonRecord(tasks: [NoteTask], names: [Int: String]) -> MeetingRecord {
    MeetingRecord(
        id: "teacher", title: "Öğretmen görüşmesi", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_001_200),
        language: nil, status: .done, failureMessage: nil, liveSegments: [],
        finalSegments: [
            StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 3, text: "Moi.", words: nil),
            StoredSegment(key: "final-1", speaker: .others, person: 1, startSec: 4, endSec: 9, text: "Miten opinnäytetyön johdanto on edennyt tällä viikolla, ehditkö kirjoittaa teoriaosuutta?", words: nil),
            StoredSegment(key: "final-2", speaker: .others, person: 2, startSec: 10, endSec: 14, text: "Kirjoitin johdannon ja teorian.", words: nil),
        ],
        translations: [:], speakerNames: names,
        note: MeetingNote(title: "Tez", summary: "", decisions: [], tasks: tasks, glossary: []),
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct UserSpeakerCandidateTests {
    // Yüz yüze toplantıda görevlerin hiçbiri kullanıcının değilse adı verilmemiş konuşmacılar ilk anlamlı cümleleriyle
    // sorulur; kullanıcı bir konuşmacıya adını verince görev onun olur ve soru kalkar.
    @Test func asksWhichSpeakerIsTheUserUntilNamed() {
        let task: NoteTask = NoteTask(owner: "Konuşmacı 2", description: "Bölümleri e-postayla göndermek", dueDate: nil, isMine: false)
        let record: MeetingRecord = inPersonRecord(tasks: [task], names: [:])
        let candidates: [UserSpeakerCandidate] = userSpeakerCandidates(record: record, userName: "Senol")
        #expect(candidates.map(\.person) == [1, 2])
        #expect(candidates[0].sample == "Miten opinnäytetyön johdanto on edennyt tällä viikolla, ehditkö…")
        #expect(candidates[1].sample == "Kirjoitin johdannon ja teorian.")

        let named: MeetingRecord = inPersonRecord(tasks: [task], names: [2: "Senol"])
        #expect(userSpeakerCandidates(record: named, userName: "Senol").isEmpty)
        #expect(myTasks(meetings: [named], userName: "Senol").count == 1)
        // Öğretmene ad verilmesi soruyu kaldırmaz; kalan konuşmacı sorulur.
        #expect(userSpeakerCandidates(record: inPersonRecord(tasks: [task], names: [1: "Opettaja"]), userName: "Senol").map(\.person) == [2])
        // Görev yoksa ya da biri zaten kullanıcınınsa sorulmaz.
        #expect(userSpeakerCandidates(record: inPersonRecord(tasks: [], names: [:]), userName: "Senol").isEmpty)
        let mine: NoteTask = NoteTask(owner: "Senol", description: "Sunum", dueDate: nil, isMine: true)
        #expect(userSpeakerCandidates(record: inPersonRecord(tasks: [mine, task], names: [:]), userName: "Senol").isEmpty)
    }
}
