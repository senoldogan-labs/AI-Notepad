import Foundation
import Testing
@testable import AINotepadCore

/// Arşivden okunan dosya: yol, içerik ve merkezi dizindeki CRC.
private struct ReadEntry {
    let path: String
    let data: Data
    let crc: UInt32
}

private enum ZipReadError: Error {
    case malformed(String)
}

private func uint16(_ data: Data, _ offset: Int) -> Int {
    Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
}

private func uint32(_ data: Data, _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { (value: UInt32, index: Int) -> UInt32 in
        value | UInt32(data[data.startIndex + offset + index]) << (8 * UInt32(index))
    }
}

/// ZIP'i bir okuyucunun yaptığı gibi açar: sondaki merkezi dizinden kayıtları, oradan yerel başlıkları ve sıkıştırmasız
/// içerikleri okur; imzalar ve boyutlar tutmazsa hata.
private func readZip(data: Data) throws -> [ReadEntry] {
    let end: Int = data.count - 22
    guard end >= 0, uint32(data, end) == 0x0605_4B50 else {
        throw ZipReadError.malformed("merkezi dizin sonu yok")
    }
    let count: Int = uint16(data, end + 10)
    var cursor: Int = Int(uint32(data, end + 16))
    #expect(cursor + Int(uint32(data, end + 12)) == end)
    return try (0..<count).map { (_: Int) -> ReadEntry in
        guard uint32(data, cursor) == 0x0201_4B50 else {
            throw ZipReadError.malformed("merkezi dizin kaydı bozuk")
        }
        let method: Int = uint16(data, cursor + 10)
        let crc: UInt32 = uint32(data, cursor + 16)
        let size: Int = Int(uint32(data, cursor + 20))
        let nameLength: Int = uint16(data, cursor + 28)
        let local: Int = Int(uint32(data, cursor + 42))
        let name: String = try #require(String(data: data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength)), encoding: .utf8))
        cursor += 46 + nameLength
        guard method == 0, uint32(data, local) == 0x0403_4B50, uint16(data, local + 26) == nameLength else {
            throw ZipReadError.malformed("yerel başlık bozuk: \(name)")
        }
        let start: Int = local + 30 + nameLength + uint16(data, local + 28)
        return ReadEntry(path: name, data: data.subdata(in: start..<(start + size)), crc: crc)
    }
}

/// Arşivdeki dosyanın UTF-8 metni; dosya yoksa ya da metin değilse hata.
private func entryText(entries: [ReadEntry], path: String) throws -> String {
    guard let entry = entries.first(where: { $0.path == path }), let text = String(data: entry.data, encoding: .utf8) else {
        throw ZipReadError.malformed("dosya yok ya da UTF-8 değil: \(path)")
    }
    return text
}

/// XML'in iyi biçimli olduğunu XMLParser ile denetler.
private func isWellFormedXML(data: Data) -> Bool {
    XMLParser(data: data).parse()
}

/// Örnek not: özel XML karakterleri, satır sonu ve yasak denetim karakteri (BEL) içerir.
private let sampleNote: MeetingNote = MeetingNote(
    title: "Rapor & sunum", summary: "Rapor gelecek hafta.\nSunum cuma.", decisions: ["Sunum cuma."],
    tasks: [NoteTask(owner: "Doğan", description: "Slaytları hazırla", dueDate: "Perşembe", isMine: true),
            NoteTask(owner: "Aino", description: "Raporu gönder\u{0007}", dueDate: nil, isMine: false)],
    glossary: [GlossaryEntry(term: "palauttaa", meaning: "teslim etmek")]
)

private func sampleRecord(note: MeetingNote?) -> MeetingRecord {
    MeetingRecord(
        id: "20261026-100000", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        endedAt: Date(timeIntervalSince1970: 1_800_002_520), language: .finnish, status: .done, failureMessage: nil,
        liveSegments: [],
        finalSegments: (0..<3).map { (index: Int) -> StoredSegment in
            StoredSegment(key: "final-\(index)", speaker: .others, person: index % 2 + 1, startSec: Double(index * 10), endSec: Double(index * 10 + 8),
                          text: "Raportti <numero \(index)> & esitys", words: nil)
        },
        translations: ["final-0": "Rapor \"numara\" 0"],
        speakerNames: [1: "Aino"],
        note: note,
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct MeetingDOCXTests {
    // CRC-32'nin bilinen değeri ("123456789" → CBF43926).
    @Test func crcMatchesReference() {
        #expect(crc32(data: Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(crc32(data: Data()) == 0)
    }

    // Word belgesi geçerli bir OOXML paketi: ZIP kayıtları ve CRC'leri tutarlı, [Content_Types].xml ve
    // word/document.xml yerinde, tüm XML'ler iyi biçimli, içerik türleri ana belgeyi tanıtıyor.
    @Test func docxIsValidPackage() throws {
        let entries: [ReadEntry] = try readZip(data: meetingDOCX(record: sampleRecord(note: sampleNote)))
        let paths: [String] = entries.map(\.path)
        #expect(paths.first == "[Content_Types].xml")
        #expect(Set(paths) == ["[Content_Types].xml", "_rels/.rels", "docProps/core.xml", "word/_rels/document.xml.rels", "word/styles.xml", "word/document.xml"])
        for entry in entries {
            #expect(crc32(data: entry.data) == entry.crc, "CRC tutmuyor: \(entry.path)")
            #expect(isWellFormedXML(data: entry.data), "XML bozuk: \(entry.path)")
        }
        let types: String = try entryText(entries: entries, path: "[Content_Types].xml")
        #expect(types.contains(#"PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml""#))
        let relationships: String = try entryText(entries: entries, path: "_rels/.rels")
        #expect(relationships.contains(#"Target="word/document.xml""#))
    }

    // Belgede not ve transkript sırasıyla; özel karakterler kaçışlanır, yasak denetim karakteri atılır, satır sonu
    // Word satır kesmesi olur.
    @Test func documentHasNoteAndTranscriptInOrder() throws {
        let entries: [ReadEntry] = try readZip(data: meetingDOCX(record: sampleRecord(note: sampleNote)))
        let document: String = try entryText(entries: entries, path: "word/document.xml")
        #expect(document.contains("Rapor &amp; sunum"))
        #expect(document.contains("Raportti &lt;numero 2&gt; &amp; esitys"))
        #expect(document.contains("Rapor &quot;numara&quot; 0"))
        #expect(document.contains("Rapor gelecek hafta.</w:t><w:br/><w:t xml:space=\"preserve\">Sunum cuma."))
        #expect(document.contains("Raporu gönder</w:t>"))
        #expect(!document.contains("\u{0007}"))
        let mine: Range<String.Index> = try #require(document.range(of: "SENİN GÖREVLERİN"))
        let summary: Range<String.Index> = try #require(document.range(of: "ÖZET"))
        let transcript: Range<String.Index> = try #require(document.range(of: "TRANSKRİPT"))
        #expect(mine.lowerBound < summary.lowerBound && summary.lowerBound < transcript.lowerBound)
        #expect(document.contains("Aino"))
    }

    // Notu olmayan toplantının da belgesi var (başlık, tarih ve transkript).
    @Test func meetingWithoutNoteStillExports() throws {
        let record: MeetingRecord = sampleRecord(note: nil)
        let paragraphs: [DocxParagraph] = meetingDocxParagraphs(record: record)
        #expect(paragraphs.first?.runs.first?.text == "Toplantı")
        #expect(!paragraphs.contains { $0.runs.contains { $0.text == "ÖZET" } })
        #expect(paragraphs.contains { $0.runs.contains { $0.text == "TRANSKRİPT" } })
        #expect(try readZip(data: meetingDOCX(record: record)).count == 6)
    }

    #if os(macOS)
    // Sistemin unzip aracı arşivi bozuksuz açar (ZIP kapsayıcısının bağımsız denetimi).
    @Test func systemUnzipAcceptsArchive() throws {
        let directory: URL = try temporaryDirectory()
        let file: URL = directory.appending(path: "toplanti.docx")
        try meetingDOCX(record: sampleRecord(note: sampleNote)).write(to: file)
        let process: Process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", file.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    #endif
}
