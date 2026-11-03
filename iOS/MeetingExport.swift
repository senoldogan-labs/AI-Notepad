import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Toplantının dosya olarak dışa aktarılması (Mac'teki "Dışa aktar" menüsünün iPhone karşılığı): PDF, web sayfası
// (HTML), Markdown, transkript (TXT) ve altyazı (SRT). Dosya geçici klasöre yazılır ve iOS paylaşım sayfasıyla
// gönderilir (Dosyalar'a kaydet, Mail, AirDrop…). İçerik çekirdeğin saf fonksiyonlarından gelir; PDF iPhone'da web
// sayfasının UIKit yazdırma çizimiyle üretilir (Mac'teki AppKit belgesi iOS'ta yok). Word (DOCX) iOS'ta üretilemez
// (`NSAttributedString` Office biçimini yalnız macOS'ta yazar).

/// Dışa aktarma biçimi.
enum MeetingExportFormat: String, CaseIterable, Identifiable {
    case pdf
    case html
    case markdown
    case transcriptText
    case subtitles

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .html: "html"
        case .markdown: "md"
        case .transcriptText: "txt"
        case .subtitles: "srt"
        }
    }

    /// Menüdeki adı.
    var title: LocalizedStringKey {
        switch self {
        case .pdf: "PDF"
        case .html: "Web sayfası (HTML)"
        case .markdown: "Markdown"
        case .transcriptText: "Transkript (TXT)"
        case .subtitles: "Altyazı (SRT)"
        }
    }

    /// Kullanım istatistiğindeki adı (Mac'teki dışa aktarmalarla aynı).
    var telemetryFormat: TelemetryExportFormat {
        switch self {
        case .pdf: .pdf
        case .html: .html
        case .markdown: .markdown
        case .transcriptText: .transcriptText
        case .subtitles: .srt
        }
    }

    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .html: "safari"
        case .markdown: "doc.text"
        case .transcriptText: "text.alignleft"
        case .subtitles: "captions.bubble"
        }
    }
}

/// Toplantıda bu biçim için içerik var mı: PDF ve web sayfası not ister, transkript ve altyazı konuşma metni ister,
/// Markdown her toplantıda vardır. Saf fonksiyondur.
func isMeetingExportAvailable(record: MeetingRecord, format: MeetingExportFormat) -> Bool {
    switch format {
    case .pdf, .html: record.note != nil
    case .markdown: true
    case .transcriptText, .subtitles: !(record.finalSegments.isEmpty && record.liveSegments.isEmpty)
    }
}

/// Dışa aktarma hatası.
enum MeetingExportError: Error, Equatable {
    /// Biçimin içeriği yok (ör. notu yazılmamış toplantının PDF'i).
    case contentMissing(format: String, meetingID: String)
    /// PDF çizilemedi (yazdırma çizicisi sayfa üretmedi).
    case pdfRenderFailed(meetingID: String, pages: Int)
}

/// Toplantıyı seçilen biçimde geçici klasöre yazar ve dosyanın yolunu döndürür (paylaşım sayfası bu dosyayı gönderir).
/// Ana iş parçacığında çalışır: PDF UIKit yazdırma çizicisiyle üretilir.
@MainActor
func writeMeetingExport(record: MeetingRecord, format: MeetingExportFormat) throws -> URL {
    guard isMeetingExportAvailable(record: record, format: format) else {
        throw MeetingExportError.contentMissing(format: format.rawValue, meetingID: record.id)
    }
    let directory: URL = FileManager.default.temporaryDirectory.appending(path: "Exports/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url: URL = try exportFileURL(directory: directory, title: record.note?.title ?? record.title, startedAt: record.startedAt, fileExtension: format.fileExtension)
    let data: Data
    switch format {
    case .pdf:
        guard let note = record.note else {
            throw MeetingExportError.contentMissing(format: format.rawValue, meetingID: record.id)
        }
        data = try htmlPDF(html: meetingHTML(record: record, note: note, language: nil, appName: appName), meetingID: record.id)
    case .html:
        guard let note = record.note else {
            throw MeetingExportError.contentMissing(format: format.rawValue, meetingID: record.id)
        }
        data = Data(meetingHTML(record: record, note: note, language: nil, appName: appName).utf8)
    case .markdown:
        data = Data(meetingMarkdown(record: record).utf8)
    case .transcriptText:
        data = Data(transcriptText(record: record).utf8)
    case .subtitles:
        data = Data(transcriptSRT(record: record).utf8)
    }
    try data.write(to: url, options: .atomic)
    return url
}

/// Web sayfasını A4 sayfalara dizip PDF verisi üretir (UIKit yazdırma çizicisi; kenar boşlukları Mac'teki belgeyle aynı).
@MainActor
private func htmlPDF(html: String, meetingID: String) throws -> Data {
    let page: CGRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    let margin: CGFloat = 48
    let formatter: UIMarkupTextPrintFormatter = UIMarkupTextPrintFormatter(markupText: html)
    let renderer: UIPrintPageRenderer = UIPrintPageRenderer()
    renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
    renderer.setValue(page, forKey: "paperRect")
    renderer.setValue(page.insetBy(dx: margin, dy: margin), forKey: "printableRect")
    let pages: Int = renderer.numberOfPages
    guard pages > 0 else {
        throw MeetingExportError.pdfRenderFailed(meetingID: meetingID, pages: pages)
    }
    let data: NSMutableData = NSMutableData()
    UIGraphicsBeginPDFContextToData(data, page, nil)
    for index in 0..<pages {
        UIGraphicsBeginPDFPage()
        renderer.drawPage(at: index, in: UIGraphicsGetPDFContextBounds())
    }
    UIGraphicsEndPDFContext()
    return data as Data
}

/// Paylaşılacak dosya (paylaşım sayfasını açan durum).
struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// iOS paylaşım sayfası (dosya için; `ShareLink` dosyayı önceden üretmeyi gerektirirdi).
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Paylaşılacak metin (başka dile çevrilmiş not): paylaşım sayfasını açar.
struct SharedText: Identifiable {
    let id: UUID = UUID()
    let text: String
}

/// Sistem paylaşım sayfası (metin için).
struct TextShareSheet: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
