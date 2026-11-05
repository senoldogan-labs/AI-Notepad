import AVFoundation
import Foundation
import os

private let roomLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "RoomRecording")

/// Sesin etkin sayıldığı en düşük düzey (RMS, tam ölçeğe göre; yaklaşık -50 dBFS). Boştaki sistem sesi dokunuşu sıfırdır.
private let activeLevel: Float = 0.003

/// Düzeyin ölçüldüğü pencere (saniye).
private let levelWindowSec: Double = 0.1

/// "Diğerleri" kaydı bu oranın altında etkinse sessiz sayılır (bildirim sesi, kısa bir video gibi kırıntılar sayılmaz).
private let silentActiveFraction: Double = 0.02

/// Kaydın düzey özeti: süresi ve etkin (sessiz olmayan) pencerelerinin toplam süresi.
public struct AudioActivity: Sendable, Equatable {
    public let durationSec: Double
    public let activeSec: Double

    public init(durationSec: Double, activeSec: Double) {
        self.durationSec = durationSec
        self.activeSec = activeSec
    }

    /// Etkin süre kaydın `silentActiveFraction`'ından az.
    public var isSilent: Bool {
        activeSec <= durationSec * silentActiveFraction
    }
}

/// Kaydı parça parça okuyup 100 ms'lik pencerelerin düzeyini ölçer (kayıt belleğe bir kerede alınmaz).
/// Okunamazsa `StorageError.readFailed`.
public func audioActivity(url: URL) throws -> AudioActivity {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url)
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
    let format: AVAudioFormat = file.processingFormat
    let window: AVAudioFrameCount = max(1, AVAudioFrameCount(format.sampleRate * levelWindowSec))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else {
        throw StorageError.readFailed(path: url.path, reason: "Could not allocate a \(window)-frame buffer for \(format).")
    }
    var activeWindows: Int = 0
    var totalFrames: AVAudioFramePosition = 0
    while file.framePosition < file.length {
        do {
            try file.read(into: buffer, frameCount: window)
        } catch {
            throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
        }
        guard buffer.frameLength > 0 else {
            break
        }
        totalFrames += AVAudioFramePosition(buffer.frameLength)
        if windowLevel(buffer: buffer) >= activeLevel {
            activeWindows += 1
        }
    }
    return AudioActivity(
        durationSec: Double(totalFrames) / format.sampleRate,
        activeSec: Double(activeWindows) * levelWindowSec
    )
}

/// Pencerenin kanallar arasındaki en yüksek RMS düzeyi.
private func windowLevel(buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else {
        return 0
    }
    let frames: Int = Int(buffer.frameLength)
    return (0..<Int(buffer.format.channelCount)).map { (channel: Int) -> Float in
        let samples: UnsafeMutablePointer<Float> = channels[channel]
        let sum: Float = (0..<frames).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
        return (sum / Float(frames)).squareRoot()
    }.max() ?? 0
}

/// Kayıt odada mikrofonla alındı ama "Yüz yüze" kapalıydı mı: "Sen" (mikrofon) akışında konuşma var, "Diğerleri" (sistem
/// sesi) kaydı yok ya da sessiz (`othersActivity`, kaydı yoksa nil) ve "Diğerleri"nin canlı metni yok. O zaman odadaki
/// herkes "Sen" diye yazılmıştır ve son geçiş (yalnız "Diğerleri"ni yazıya döker) hiç çalışmaz. Saf fonksiyondur.
public func isRoomRecordedAsMe(record: MeetingRecord, othersActivity: AudioActivity?) -> Bool {
    hasOnlyMeLiveSpeech(record: record) && (othersActivity?.isSilent ?? true)
}

/// Canlı metinde yalnız "Sen" konuşuyor ("Diğerleri"nin metinli bölümü yok). Saf fonksiyondur.
private func hasOnlyMeLiveSpeech(record: MeetingRecord) -> Bool {
    let spoken: (Speaker) -> Bool = { (speaker: Speaker) -> Bool in
        record.liveSegments.contains { $0.speaker == speaker && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    return spoken(.me) && !spoken(.others)
}

/// Odada "Sen" diye kaydedilmiş toplantı yüz yüze kayda çevrilmiş haliyle: "Sen"in canlı bölümleri kişisiz "Diğerleri"
/// bölümleri olur (anahtarları ve Türkçeleri birlikte taşınır), önceki son geçiş bölümleri, konuşmacı adları ve ses
/// izleri atılır (son geçiş mikrofon kaydını konuşmacılara ayırıp baştan numaralar). Saf fonksiyondur.
public func roomRecordingRelabeled(record: MeetingRecord) -> MeetingRecord {
    let movedKey: (String) -> String = { (key: String) -> String in "others-room-\(key)" }
    let meKeys: Set<String> = Set(record.liveSegments.filter { $0.speaker == .me }.map(\.key))
    let live: [StoredSegment] = record.liveSegments.map { (segment: StoredSegment) -> StoredSegment in
        guard segment.speaker == .me else {
            return segment
        }
        return StoredSegment(
            key: movedKey(segment.key), speaker: .others, person: nil, startSec: segment.startSec, endSec: segment.endSec,
            text: segment.text, words: segment.words
        )
        .with(spokenLanguage: segment.spokenLanguage)
    }
    let translations: [String: String] = Dictionary(uniqueKeysWithValues: record.translations.map { (key: String, text: String) -> (String, String) in
        (meKeys.contains(key) ? movedKey(key) : key, text)
    })
    return record
        .with(liveSegments: live)
        .with(finalSegments: [], language: record.language)
        .with(translations: translations)
        .with(speakerNames: [:])
        .with(voiceprints: nil)
        .with(meNeedsFinalPass: nil)
}

/// "Yüz yüze" kapalıyken odada kaydedilmiş toplantıyı (bkz. `isRoomRecordedAsMe`) yüz yüze kayda çevirir: sessiz
/// "Diğerleri" kaydı (sistem sesi) silinir, mikrofon kaydı (`me.caf`/`me.m4a`) "Diğerleri" kaydı olur ve kayıt
/// `roomRecordingRelabeled` ile yeniden etiketlenir; son geçiş böylece odadaki herkesi konuşmacılara ayırır. Çevrilmesi
/// gerekmiyorsa kayıt aynen döner. Çağıran dönen kaydı işlemeden önce hemen saklar (dosyalar taşınmıştır). Uzun kaydın
/// düzeyini okuduğu için ana iş parçacığında çağrılmaz. Dosya okunamaz, silinemez ya da taşınamazsa `StorageError`.
public func convertingRoomRecording(record: MeetingRecord, directory: URL) throws -> MeetingRecord {
    let fileManager: FileManager = FileManager.default
    let existing: (String) -> [URL] = { (name: String) -> [URL] in
        ["caf", "m4a"]
            .map { directory.appending(path: "\(name).\($0)") }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }
    let meFiles: [URL] = existing("me")
    let othersFiles: [URL] = existing("others")
    // Önce metin: görüşmede ("Diğerleri" konuştu) ses hiç okunmaz.
    guard !meFiles.isEmpty, hasOnlyMeLiveSpeech(record: record) else {
        return record
    }
    // Kayıpsız `.caf` varsa düzey ondan ölçülür; yoksa `.m4a`.
    let othersActivity: AudioActivity? = try othersFiles.first.map { try audioActivity(url: $0) }
    guard isRoomRecordedAsMe(record: record, othersActivity: othersActivity) else {
        return record
    }
    for url in othersFiles {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw StorageError.deleteFailed(path: url.path, reason: error.localizedDescription)
        }
    }
    for source in meFiles {
        let destination: URL = directory.appending(path: "others.\(source.pathExtension)")
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            throw StorageError.moveFailed(path: source.path, reason: error.localizedDescription)
        }
    }
    roomLogger.info("Odada \"Sen\" diye kaydedilmiş toplantı yüz yüze kayda çevrildi, toplantı: \(record.id, privacy: .public), \"Diğerleri\" etkin süre: \(othersActivity?.activeSec ?? 0, privacy: .public) sn")
    return roomRecordingRelabeled(record: record)
}
