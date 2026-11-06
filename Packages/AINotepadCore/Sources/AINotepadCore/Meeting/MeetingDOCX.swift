import Foundation

// Toplantının Word belgesi (DOCX, Office Open XML): Mac'te ve iPhone'da aynı yazıcı. Belge düz XML'dir, sıkıştırmasız
// ZIP kapsayıcısına konur (bkz. `storedZipArchive`); AppKit ya da UIKit gerekmez. İçerik ve biçimler Mac'teki PDF
// belgesiyle (`meetingDocument`) aynıdır: başlık, tarih, senin görevlerin, özet, kararlar, diğer görevler, sözlük ve
// paragraflı transkript (Türkçesiyle).

/// Belgedeki metin biçimi (ölçüler Mac'teki PDF belgesiyle aynı).
enum DocxTextStyle: Sendable, Equatable {
    case title
    case meta
    case heading
    case body
    case listItem
    case listItemStrong
    case listItemMuted
    case transcriptTime
    case transcriptLabel
    case transcriptText
    case transcriptTextBeforeTurkish
    case transcriptTurkish
}

/// Paragraftaki biçimli metin parçası.
struct DocxRun: Sendable, Equatable {
    let text: String
    let style: DocxTextStyle
}

/// Belgenin paragrafı: paragraf biçimi (boşluk, girinti, satır aralığı) `style`'dan, metin parçalarından.
struct DocxParagraph: Sendable, Equatable {
    let style: DocxTextStyle
    let runs: [DocxRun]
}

/// Toplantının Word belgesi (DOCX verisi): Word, Pages ve Google Dokümanlar açar. Saf fonksiyondur.
public func meetingDOCX(record: MeetingRecord) -> Data {
    let title: String = record.note?.title ?? record.title
    return storedZipArchive(entries: [
        ZipEntry(path: "[Content_Types].xml", data: Data(docxContentTypes.utf8)),
        ZipEntry(path: "_rels/.rels", data: Data(docxPackageRelationships.utf8)),
        ZipEntry(path: "docProps/core.xml", data: Data(docxCoreProperties(title: title).utf8)),
        ZipEntry(path: "word/_rels/document.xml.rels", data: Data(docxDocumentRelationships.utf8)),
        ZipEntry(path: "word/styles.xml", data: Data(docxStyles.utf8)),
        ZipEntry(path: "word/document.xml", data: Data(docxDocumentXML(paragraphs: meetingDocxParagraphs(record: record)).utf8)),
    ])
}

/// Belgenin paragrafları, Mac'teki PDF belgesinin sırasıyla. Saf fonksiyondur.
func meetingDocxParagraphs(record: MeetingRecord) -> [DocxParagraph] {
    let header: [DocxParagraph] = [
        single(text: record.note?.title ?? record.title, style: .title),
        single(text: meetingMetaLine(record: record), style: .meta),
    ]
    let noteParagraphs: [DocxParagraph] = record.note.map { (note: MeetingNote) -> [DocxParagraph] in
        let mine: [NoteTask] = note.tasks.filter(\.isMine)
        let others: [NoteTask] = note.tasks.filter { !$0.isMine }
        let myTasks: [DocxParagraph] = mine.isEmpty
            ? [single(text: String(localized: "Sana düşen görev yok."), style: .listItemMuted)]
            : mine.map(taskParagraph(task:))
        let decisions: [DocxParagraph] = note.decisions.isEmpty
            ? []
            : [single(text: String(localized: "KARARLAR"), style: .heading)] + note.decisions.map { single(text: "•  \($0)", style: .listItem) }
        let questions: [String] = note.openQuestions ?? []
        let openQuestions: [DocxParagraph] = questions.isEmpty
            ? []
            : [single(text: String(localized: "AÇIK KONULAR"), style: .heading)] + questions.map { single(text: "•  \($0)", style: .listItem) }
        let otherTasks: [DocxParagraph] = others.isEmpty
            ? []
            : [single(text: String(localized: "DİĞER GÖREVLER"), style: .heading)] + others.map(taskParagraph(task:))
        let glossary: [DocxParagraph] = note.glossary.isEmpty
            ? []
            : [single(text: String(localized: "SÖZLÜK"), style: .heading)] + note.glossary.map { (entry: GlossaryEntry) -> DocxParagraph in
                DocxParagraph(style: .listItem, runs: [DocxRun(text: entry.term, style: .listItemStrong), DocxRun(text: " — \(entry.meaning)", style: .listItem)])
            }
        return [single(text: String(localized: "SENİN GÖREVLERİN"), style: .heading)] + myTasks
            + [single(text: String(localized: "ÖZET"), style: .heading), single(text: note.summary, style: .body)]
            + decisions + openQuestions + otherTasks + glossary
    } ?? []
    let paragraphs: [TranscriptParagraph] = transcriptParagraphs(record: record)
    let transcript: [DocxParagraph] = paragraphs.isEmpty
        ? []
        : [single(text: String(localized: "TRANSKRİPT"), style: .heading)] + paragraphs.flatMap { (paragraph: TranscriptParagraph) -> [DocxParagraph] in
            let label: DocxParagraph = DocxParagraph(style: .transcriptTime, runs: [
                DocxRun(text: "\(timestamp(seconds: paragraph.startSec))  ", style: .transcriptTime),
                DocxRun(text: paragraphLabel(paragraph: paragraph, speakerNames: record.speakerNames), style: .transcriptLabel),
            ])
            let text: DocxParagraph = single(text: paragraph.text, style: paragraph.turkish == nil ? .transcriptText : .transcriptTextBeforeTurkish)
            let turkish: [DocxParagraph] = paragraph.turkish.map { [single(text: $0, style: .transcriptTurkish)] } ?? []
            return [label, text] + turkish
        }
    return header + noteParagraphs + transcript
}

private func single(text: String, style: DocxTextStyle) -> DocxParagraph {
    DocxParagraph(style: style, runs: [DocxRun(text: text, style: style)])
}

private func taskParagraph(task: NoteTask) -> DocxParagraph {
    let due: [DocxRun] = task.dueDate.map { [DocxRun(text: "  (\($0))", style: .listItemMuted)] } ?? []
    return DocxParagraph(style: .listItem, runs: [
        DocxRun(text: "☐  ", style: .listItem),
        DocxRun(text: task.owner, style: .listItemStrong),
        DocxRun(text: " — \(task.description)", style: .listItem),
    ] + due)
}

// MARK: XML

/// `word/document.xml`: paragraflar ve A4 sayfa (kenar boşlukları Mac'teki PDF'le aynı, 56 pt). Saf fonksiyondur.
func docxDocumentXML(paragraphs: [DocxParagraph]) -> String {
    let body: String = paragraphs.map(paragraphXML(paragraph:)).joined()
    return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>"#
        + body
        + #"<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1120" w:right="1120" w:bottom="1120" w:left="1120" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>"#
        + "</w:body></w:document>"
}

private func paragraphXML(paragraph: DocxParagraph) -> String {
    let format: DocxFormat = docxFormat(style: paragraph.style)
    let indent: String = format.hangingIndentTwips > 0
        ? #"<w:ind w:left="\#(format.hangingIndentTwips)" w:hanging="\#(format.hangingIndentTwips)"/>"#
        : ""
    let properties: String = #"<w:pPr><w:spacing w:before="\#(format.spaceBeforeTwips)" w:after="\#(format.spaceAfterTwips)" w:line="\#(format.lineTwips)" w:lineRule="auto"/>"#
        + indent + "</w:pPr>"
    return "<w:p>" + properties + paragraph.runs.map(runXML(run:)).joined() + "</w:p>"
}

/// Parçanın XML'i; metindeki satır sonları `<w:br/>` olur (Word'de `<w:t>` içinde satır sonu boşluk sayılır).
private func runXML(run: DocxRun) -> String {
    let format: DocxFormat = docxFormat(style: run.style)
    let weight: String = format.isBold ? "<w:b/><w:bCs/>" : ""
    let slant: String = format.isItalic ? "<w:i/><w:iCs/>" : ""
    let letterSpacing: String = format.letterSpacingTwips > 0 ? #"<w:spacing w:val="\#(format.letterSpacingTwips)"/>"# : ""
    let properties: String = "<w:rPr>" + weight + slant + #"<w:color w:val="\#(format.color)"/>"# + letterSpacing
        + #"<w:sz w:val="\#(format.halfPoints)"/><w:szCs w:val="\#(format.halfPoints)"/></w:rPr>"#
    let lines: [String] = run.text.components(separatedBy: "\n")
    let content: String = lines
        .map { (line: String) -> String in #"<w:t xml:space="preserve">"# + xmlEscaped(text: line) + "</w:t>" }
        .joined(separator: "<w:br/>")
    return "<w:r>" + properties + content + "</w:r>"
}

/// Metni XML'e güvenle koyar: özel karakterler kaçışlanır, XML 1.0'da yasak denetim karakterleri (sekme ve satır sonu
/// dışında) atılır (yoksa Word belgeyi "bozuk" diye açmaz). Saf fonksiyondur.
func xmlEscaped(text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.filter { (scalar: Unicode.Scalar) -> Bool in
        scalar.value >= 0x20 || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }.filter { (scalar: Unicode.Scalar) -> Bool in
        scalar.value != 0xFFFE && scalar.value != 0xFFFF
    }))
    .replacingOccurrences(of: "&", with: "&amp;")
    .replacingOccurrences(of: "<", with: "&lt;")
    .replacingOccurrences(of: ">", with: "&gt;")
    .replacingOccurrences(of: "\"", with: "&quot;")
}

/// Biçimin Word ölçüleri: yazı boyutu yarım punto, boşluklar twip (1/20 pt), satır yüksekliği 240'ta (240 tek satır).
private struct DocxFormat {
    let halfPoints: Int
    let isBold: Bool
    let isItalic: Bool
    /// Altıgen sRGB renk.
    let color: String
    let letterSpacingTwips: Int
    let spaceBeforeTwips: Int
    let spaceAfterTwips: Int
    let lineTwips: Int
    /// İlk satırdan sonraki satırların girintisi (madde işareti asılı kalır).
    let hangingIndentTwips: Int
}

private let docxInk: String = "1A1A1A"
private let docxMuted: String = "6B6B6B"
private let docxAccent: String = "3B5BDB"

/// Mac'teki PDF belgesinin biçimleri: yazı boyutu, kalınlık, renk, harf aralığı, paragraf boşlukları ve satır aralığı
/// (`lineSpacing` punto olarak satırlar arasına eklenir; Word'de satır yüksekliğine oranlanır).
private func docxFormat(style: DocxTextStyle) -> DocxFormat {
    switch style {
    case .title:
        format(points: 22, bold: true, italic: false, color: docxInk, kern: 0, before: 0, after: 4, lineSpacing: 2, indent: 0)
    case .meta:
        format(points: 10.5, bold: false, italic: false, color: docxMuted, kern: 0, before: 0, after: 18, lineSpacing: 2, indent: 0)
    case .heading:
        format(points: 10, bold: true, italic: false, color: docxAccent, kern: 0.8, before: 16, after: 6, lineSpacing: 2, indent: 0)
    case .body:
        format(points: 11.5, bold: false, italic: false, color: docxInk, kern: 0, before: 0, after: 0, lineSpacing: 3, indent: 0)
    case .listItem:
        format(points: 11.5, bold: false, italic: false, color: docxInk, kern: 0, before: 0, after: 4, lineSpacing: 2, indent: 16)
    case .listItemStrong:
        format(points: 11.5, bold: true, italic: false, color: docxInk, kern: 0, before: 0, after: 4, lineSpacing: 2, indent: 16)
    case .listItemMuted:
        format(points: 10.5, bold: false, italic: false, color: docxMuted, kern: 0, before: 0, after: 0, lineSpacing: 2, indent: 16)
    case .transcriptTime:
        format(points: 9.5, bold: false, italic: false, color: docxMuted, kern: 0, before: 8, after: 0, lineSpacing: 2, indent: 0)
    case .transcriptLabel:
        format(points: 9.5, bold: true, italic: false, color: docxMuted, kern: 0.4, before: 8, after: 0, lineSpacing: 2, indent: 0)
    case .transcriptText:
        format(points: 11, bold: false, italic: false, color: docxInk, kern: 0, before: 0, after: 0, lineSpacing: 2.5, indent: 0)
    case .transcriptTextBeforeTurkish:
        format(points: 11, bold: false, italic: false, color: docxInk, kern: 0, before: 0, after: 2, lineSpacing: 2.5, indent: 0)
    case .transcriptTurkish:
        format(points: 10.5, bold: false, italic: true, color: docxMuted, kern: 0, before: 0, after: 0, lineSpacing: 2, indent: 0)
    }
}

private func format(
    points: Double, bold: Bool, italic: Bool, color: String, kern: Double, before: Double, after: Double, lineSpacing: Double, indent: Double
) -> DocxFormat {
    // Tek satırın yüksekliği yazı boyutunun ~1,2 katı; eklenen aralık buna oranlanır.
    let natural: Double = points * 1.2
    return DocxFormat(
        halfPoints: Int((points * 2).rounded()), isBold: bold, isItalic: italic, color: color, letterSpacingTwips: Int((kern * 20).rounded()),
        spaceBeforeTwips: Int((before * 20).rounded()), spaceAfterTwips: Int((after * 20).rounded()),
        lineTwips: Int((240 * (natural + lineSpacing) / natural).rounded()), hangingIndentTwips: Int((indent * 20).rounded())
    )
}

// MARK: Paket parçaları

private let docxContentTypes: String = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
    + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
    + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
    + #"<Default Extension="xml" ContentType="application/xml"/>"#
    + #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#
    + #"<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#
    + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
    + "</Types>"

private let docxPackageRelationships: String = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
    + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
    + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>"#
    + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
    + "</Relationships>"

private let docxDocumentRelationships: String = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
    + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
    + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
    + "</Relationships>"

/// Varsayılan yazı (Helvetica Neue; yoksa Word benzeriyle değiştirir), boyut ve renk; paragraflar arası varsayılan boşluk yok.
private let docxStyles: String = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
    + #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
    + "<w:docDefaults><w:rPrDefault><w:rPr>"
    + #"<w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:eastAsia="Helvetica Neue" w:cs="Helvetica Neue"/>"#
    + #"<w:color w:val="\#(docxInk)"/><w:sz w:val="23"/><w:szCs w:val="23"/>"#
    + "</w:rPr></w:rPrDefault>"
    + #"<w:pPrDefault><w:pPr><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault>"#
    + "</w:docDefaults>"
    + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>"#
    + "</w:styles>"

/// `docProps/core.xml`: belgenin başlığı (Dosya › Özellikler). Saf fonksiyondur.
private func docxCoreProperties(title: String) -> String {
    #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">"#
        + "<dc:title>" + xmlEscaped(text: title) + "</dc:title>"
        + "</cp:coreProperties>"
}
