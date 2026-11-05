import Foundation
import os

// Örnek toplantı: karşılamadaki rehberli denemenin uygulamayla gelen kısa toplantısı (sentetik iki ses, İngilizce;
// `App/SampleMeeting/`). Canlı metin sesle eş zamanlı satır satır akar, bitince önceden yazılmış not gösterilir; sunucu,
// konuşma tanıma ya da dil modeli çağrılmaz. Saklanan örnek toplantı (`MeetingRecord.isSampleMeeting`) eşitlemeye,
// kullanım ve telemetri sayılarına, bildirimlere ve MCP'ye girmez (bkz. `realMeetings`).

private let sampleMeetingLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SampleMeeting")

/// Örnek toplantının bir satırı: konuşan kişi (1 tabanlı), metin ve sesteki yeri (saniye).
public struct SampleMeetingLine: Sendable, Equatable, Codable {
    public let person: Int
    public let text: String
    public let startSec: Double
    public let endSec: Double

    public init(person: Int, text: String, startSec: Double, endSec: Double) {
        self.person = person
        self.text = text
        self.startSec = startSec
        self.endSec = endSec
    }
}

/// Örnek toplantının zamanlı metni (`sample-meeting.json`; ses üreticisi `promo/sample-meeting/` yazar).
public struct SampleMeetingScript: Sendable, Equatable, Codable {
    /// Sesin süresi (saniye).
    public let durationSec: Double
    public let lines: [SampleMeetingLine]

    public init(durationSec: Double, lines: [SampleMeetingLine]) {
        self.durationSec = durationSec
        self.lines = lines
    }
}

/// Örnek toplantı okunamadı.
public enum SampleMeetingError: Error, Equatable, CustomStringConvertible {
    /// Uygulama paketinde dosya yok (hedefin kaynaklarına eklenmemiş).
    case resourceMissing(name: String)
    /// Metin dosyası çözülemedi ya da tutarsız (satırlar sırasız, süre dışında, boş).
    case invalidScript(reason: String)

    public var description: String {
        switch self {
        case .resourceMissing(let name):
            "Örnek toplantı dosyası uygulama paketinde yok: \(name)"
        case .invalidScript(let reason):
            "Örnek toplantının metni okunamadı: \(reason)"
        }
    }
}

/// `sample-meeting.json`'u çözer ve doğrular: en az bir satır, satırlar zaman sırasında, her satırın sonu başından sonra
/// ve sesin süresi içinde, metinler boş değil. Saf fonksiyondur.
public func decodeSampleMeetingScript(data: Data) throws -> SampleMeetingScript {
    let script: SampleMeetingScript
    do {
        script = try JSONDecoder().decode(SampleMeetingScript.self, from: data)
    } catch {
        throw SampleMeetingError.invalidScript(reason: String(describing: error))
    }
    guard !script.lines.isEmpty else {
        throw SampleMeetingError.invalidScript(reason: "satır yok")
    }
    for (index, line) in script.lines.enumerated() {
        guard !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, line.person >= 1 else {
            throw SampleMeetingError.invalidScript(reason: "satır \(index): boş metin ya da geçersiz kişi \(line.person)")
        }
        guard line.startSec >= 0, line.endSec > line.startSec, line.endSec <= script.durationSec + 0.05 else {
            throw SampleMeetingError.invalidScript(reason: "satır \(index): zaman \(line.startSec)–\(line.endSec), süre \(script.durationSec)")
        }
        if index > 0, line.startSec < script.lines[index - 1].endSec - 0.05 {
            throw SampleMeetingError.invalidScript(reason: "satır \(index) öncekinin bitişinden (\(script.lines[index - 1].endSec)) önce başlıyor: \(line.startSec)")
        }
    }
    return script
}

/// Sesin `elapsed` saniyesinde canlı metin: başlamış satırlar; konuşulan satır kelime kelime (geçen süreye oranla) ve
/// kesinleşmemiş, bitenler kesin. Hepsi "Diğerleri" (toplantının iki katılımcısı; kullanıcı dinler). Saf fonksiyondur.
public func sampleMeetingTranscript(script: SampleMeetingScript, elapsed: Double) -> [LiveSegment] {
    script.lines.enumerated().compactMap { (item: (offset: Int, element: SampleMeetingLine)) -> LiveSegment? in
        let line: SampleMeetingLine = item.element
        guard elapsed >= line.startSec else {
            return nil
        }
        let id: SegmentID = SegmentID(speaker: .others, index: item.offset)
        guard elapsed < line.endSec else {
            return LiveSegment(id: id, startSec: line.startSec, endSec: line.endSec, text: line.text, isFinal: true, failureMessage: nil, person: line.person)
        }
        let words: [Substring] = line.text.split(separator: " ")
        let fraction: Double = (elapsed - line.startSec) / (line.endSec - line.startSec)
        let shown: Int = min(words.count, max(1, Int((fraction * Double(words.count)).rounded(.up))))
        return LiveSegment(
            id: id, startSec: line.startSec, endSec: elapsed, text: words.prefix(shown).joined(separator: " "), isFinal: false,
            failureMessage: nil, person: line.person
        )
    }
}

/// Şu an konuşan kişi (satırın içindeyse); sessiz aralıkta nil. Saf fonksiyondur.
public func sampleMeetingSpeaker(script: SampleMeetingScript, elapsed: Double) -> Int? {
    script.lines.first { (line: SampleMeetingLine) -> Bool in elapsed >= line.startSec && elapsed < line.endSec }?.person
}

/// Saklanan örnek toplantı: satırlar kesin transkript, not önceden yazılmış (çağıranın dilinde), kullanıcının denemede
/// yazdığı not kendi notları; bitmiş, ses `others.m4a` olarak klasörde (çağıran kopyalar). Saf fonksiyondur.
public func sampleMeetingRecord(
    id: String, script: SampleMeetingScript, note: MeetingNote, speakerNames: [Int: String], startedAt: Date, myNotes: String
) -> MeetingRecord {
    let segments: [StoredSegment] = script.lines.enumerated().map { (item: (offset: Int, element: SampleMeetingLine)) -> StoredSegment in
        StoredSegment(
            key: "final-\(item.offset)", speaker: .others, person: item.element.person, startSec: item.element.startSec,
            endSec: item.element.endSec, text: item.element.text, words: nil
        )
    }
    return MeetingRecord(
        id: id, title: note.title, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(script.durationSec), language: .english,
        status: .done, failureMessage: nil, liveSegments: [], finalSegments: segments, translations: [:], speakerNames: speakerNames,
        note: note, audioDeleted: false, engine: nil, notice: nil, meNeedsFinalPass: nil
    )
    .with(myNotes: myNotes)
    .markedAsSample()
}

/// Gerçek toplantılar: örnek toplantı hariç. Eşitleme, kullanım ve telemetri sayıları, bildirimler ve MCP bunu okur:
/// örnek toplantı kullanıcının işi değildir, başka cihaza ya da sunucuya gitmez. Saf fonksiyondur.
public func realMeetings(records: [MeetingRecord]) -> [MeetingRecord] {
    records.filter { (record: MeetingRecord) -> Bool in !record.isSampleMeeting }
}

/// Saklı örnek toplantı (varsa en yenisi): deneme yeniden açılınca yenisi yazılmaz, bu açılır. Saf fonksiyondur.
public func existingSampleMeetingID(records: [MeetingRecord]) -> String? {
    records.filter(\.isSampleMeeting).max { $0.startedAt < $1.startedAt }?.id
}

/// Örnek toplantıyı yeni bir oturum klasörüne yazar (yerel; iCloud'a taşınmaz): ses `others.m4a` (toplantı sayfasında
/// çalınır), kayıt `meeting.json`. Toplantı sesin süresi kadar önce başlamış sayılır. Yazılan kaydı döndürür; klasör
/// alınamaz ya da dosya yazılamazsa hata (yarım klasör silinir).
public func writeSampleMeeting(
    script: SampleMeetingScript, note: MeetingNote, speakerNames: [Int: String], myNotes: String, audio: URL, now: Date
) throws -> MeetingRecord {
    let claimed: (url: URL, startedAt: Date) = try AppPaths.newExclusiveSessionDirectory(startedAt: now.addingTimeInterval(-script.durationSec.rounded(.up)))
    let record: MeetingRecord = sampleMeetingRecord(
        id: claimed.url.lastPathComponent, script: script, note: note, speakerNames: speakerNames, startedAt: claimed.startedAt, myNotes: myNotes
    )
    do {
        try FileManager.default.copyItem(at: audio, to: claimed.url.appending(path: "\(Speaker.others.rawValue).m4a"))
        try saveMeeting(record: record, directory: claimed.url)
    } catch {
        do {
            try FileManager.default.removeItem(at: claimed.url)
        } catch let cleanup {
            sampleMeetingLogger.error("Yarım kalan örnek toplantı klasörü silinemedi, klasör: \(claimed.url.lastPathComponent, privacy: .public), hata: \(String(describing: cleanup), privacy: .private)")
        }
        throw StorageError.writeFailed(path: claimed.url.path, reason: String(describing: error))
    }
    return record
}
