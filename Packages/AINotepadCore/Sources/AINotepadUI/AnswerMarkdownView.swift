import AINotepadCore
import SwiftUI
import UniformTypeIdentifiers

/// Sor cevabının Markdown görünümü (Mac ve iPhone): başlıklar, listeler, tablolar (yatay kaydırılır), kod blokları (eş
/// aralıklı, yatay kaydırılır, blok başına Kopyala), alıntılar ve çizgiler. Toplantı kaynakları vurgu renginde ayrı
/// rozetlerdir (`1`, `2`; dokununca kaynak açılır), web kaynakları alan adıyla soluk rozetlerdir (dokununca tarayıcıda
/// açılır). Bloklar `parseMarkdown`'dan gelir; akış sürerken yarım metin de çizilir.
struct AnswerMarkdownView: View {
    let blocks: [MarkdownBlock]
    let webSources: [WebSource]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * appearance.uiScale) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { (item: (offset: Int, element: MarkdownBlock)) in
                MarkdownBlockView(block: item.element, webSources: webSources, depth: 0)
            }
        }
    }
}

/// Tek blok.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let webSources: [WebSource]
    /// Liste iç içeliği (madde işareti değişir).
    let depth: Int
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        switch block {
        case .heading(let level, let content):
            InlineText(inlines: content, webSources: webSources, font: appearance.font(size: headingSize(level: level), weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let content):
            InlineText(inlines: content, webSources: webSources, font: appearance.font(size: 15, weight: .regular))
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: 6 * appearance.uiScale) {
                ForEach(Array(items.enumerated()), id: \.offset) { (item: (offset: Int, element: [MarkdownBlock])) in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: ordered ? "\(start + item.offset)." : bulletSymbol(depth: depth))
                            .font(appearance.font(size: 15, weight: ordered ? .medium : .regular))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .frame(minWidth: 16 * appearance.uiScale, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 6 * appearance.uiScale) {
                            ForEach(Array(item.element.enumerated()), id: \.offset) { (child: (offset: Int, element: MarkdownBlock)) in
                                MarkdownBlockView(block: child.element, webSources: webSources, depth: depth + 1)
                            }
                        }
                    }
                }
            }
        case .code(let language, let text):
            CodeBlockView(language: language, code: text)
        case .table(let header, let alignments, let rows):
            TableBlockView(header: header, alignments: alignments, rows: rows, webSources: webSources)
        case .quote(let children):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.line)
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(children.enumerated()), id: \.offset) { (child: (offset: Int, element: MarkdownBlock)) in
                        MarkdownBlockView(block: child.element, webSources: webSources, depth: depth)
                    }
                }
                .foregroundStyle(Theme.ink.opacity(0.8))
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func headingSize(level: Int) -> CGFloat {
        switch level {
        case 1: 21
        case 2: 18
        case 3: 16
        default: 15
        }
    }

    private func bulletSymbol(depth: Int) -> String {
        ["•", "◦", "▪︎"][depth % 3]
    }
}

/// Satır içi öğelerden bir metin: kaynak bağlantıları (`ainotepad-source://n`) `onCitation` ortamıyla açılır.
private struct InlineText: View {
    let inlines: [MarkdownInline]
    let webSources: [WebSource]
    let font: Font
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Text(answerAttributedText(
            inlines: inlines, webSources: webSources,
            style: AnswerTextStyle(
                accent: appearance.accent.color, citationFont: appearance.font(size: 11, weight: .semibold), strongFont: font.bold(),
                codeFont: appearance.monoFont(size: 13.5, weight: .regular), codeBackground: Theme.soft,
                webForeground: Theme.ink.opacity(0.7), webBackground: Theme.ink.opacity(0.07)
            )
        ))
        .font(font)
        .foregroundStyle(Theme.ink)
        .lineSpacing(4 * appearance.uiScale)
        .fixedSize(horizontal: false, vertical: true)
        .answerTextSelection()
    }
}

/// Satır içi biçimin renkleri ve yazıları.
struct AnswerTextStyle {
    let accent: Color
    let citationFont: Font
    /// Kalın metnin yazısı: ağırlığı açıkça verilen yazı (Inter ve kurulu yazılar `.weight(...)` ile gelir) kalın
    /// sunum niyetini (`stronglyEmphasized`) yok sayıyordu; **kalın** düz görünüyordu.
    let strongFont: Font
    let codeFont: Font
    /// Satır içi kodun zemini.
    let codeBackground: Color
    /// Web rozetinin yazısı ve zemini.
    let webForeground: Color
    let webBackground: Color
}

/// Toplantı kaynağı bağlantısının şeması (`ainotepad-source://3`).
let citationScheme: String = "ainotepad-source"

/// Satır içi öğeleri biçimli metne çevirir: kalın, italik, üstü çizili, satır içi kod (eş aralıklı, soluk zemin),
/// bağlantılar; toplantı kaynağı vurgu renkli rozet ("1"), web kaynağı alan adıyla soluk rozet ("example.com"); ardışık
/// rozetler arasında ince boşluk, metinle arasında ince boşluk (rakamlar asla birleşmez). Saf fonksiyondur.
func answerAttributedText(inlines: [MarkdownInline], webSources: [WebSource], style: AnswerTextStyle) -> AttributedString {
    inlines.enumerated().reduce(into: AttributedString()) { (result: inout AttributedString, item: (offset: Int, element: MarkdownInline)) -> Void in
        let previousIsCitation: Bool = item.offset > 0 && isCitation(inlines[item.offset - 1])
        switch item.element {
        case .text(let text):
            result += AttributedString(text)
        case .lineBreak:
            result += AttributedString("\n")
        case .strong(let children):
            var run: AttributedString = answerAttributedText(inlines: children, webSources: webSources, style: style)
            run.inlinePresentationIntent = .stronglyEmphasized
            // Kendi yazısı olan parçalar (kaynak rozeti, satır içi kod) yazısını korur.
            for (font, range) in run.runs[AttributeScopes.SwiftUIAttributes.FontAttribute.self].reversed() where font == nil {
                run[range].swiftUI.font = style.strongFont
            }
            result += run
        case .emphasis(let children):
            var run: AttributedString = answerAttributedText(inlines: children, webSources: webSources, style: style)
            run.inlinePresentationIntent = .emphasized
            result += run
        case .strikethrough(let children):
            var run: AttributedString = answerAttributedText(inlines: children, webSources: webSources, style: style)
            run.strikethroughStyle = .single
            result += run
        case .code(let code):
            var run: AttributedString = AttributedString("\u{2009}\(code)\u{2009}")
            run.font = style.codeFont
            run.backgroundColor = style.codeBackground
            result += run
        case .link(let label, let url):
            var run: AttributedString = answerAttributedText(inlines: label, webSources: webSources, style: style)
            run.link = isWebAddress(url) ? URL(string: url) : nil
            run.foregroundColor = style.accent
            run.underlineStyle = .single
            result += run
        case .citation(let number):
            result += citationGap(after: result, previousIsCitation: previousIsCitation)
            var run: AttributedString = AttributedString("\u{2009}\(number)\u{2009}")
            run.link = URL(string: "\(citationScheme)://\(number)")
            run.foregroundColor = style.accent
            run.backgroundColor = style.accent.opacity(0.14)
            run.font = style.citationFont
            result += run
        case .webCitation(let number):
            result += citationGap(after: result, previousIsCitation: previousIsCitation)
            let source: WebSource? = webSources.indices.contains(number - 1) ? webSources[number - 1] : nil
            var run: AttributedString = AttributedString("\u{2009}\(source.map { webSourceDomain(url: $0.url) } ?? "web")\u{2009}")
            run.link = source.flatMap { isWebAddress($0.url) ? URL(string: $0.url) : nil }
            run.foregroundColor = style.webForeground
            run.backgroundColor = style.webBackground
            run.font = style.citationFont
            result += run
        }
    }
}

/// Rozetten önceki boşluk: önceki rozetle arasında ince boşluk; metinle arasında, metin boşlukla bitmiyorsa ince boşluk
/// (bölünmez). Saf fonksiyondur.
private func citationGap(after text: AttributedString, previousIsCitation: Bool) -> AttributedString {
    if previousIsCitation {
        return AttributedString("\u{202F}")
    }
    guard let last = text.characters.last, !last.isWhitespace else {
        return AttributedString()
    }
    return AttributedString("\u{202F}")
}

/// Kod bloğu: üstte dil ve Kopyala, altta eş aralıklı, yatay kaydırılan kod (satırlar kaydırılmaz).
private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(verbatim: language)
                    .font(appearance.font(size: 11, weight: .medium))
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button {
                    copyToPasteboard(text: code)
                    copied = true
                } label: {
                    Label(copied ? "Kopyalandı" : "Kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(appearance.font(size: 11, weight: .medium))
                        .foregroundStyle(copied ? Theme.ink : Theme.muted)
                        .contentTransition(.symbolEffect(.replace))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityLabel(copied ? "Kopyalandı" : "Kodu kopyala")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .appMonoFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.soft.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        .task(id: copied) {
            guard copied else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            copied = false
        }
    }
}

/// Tablo: başlık satırı kalın ve soluk zeminli, hücreler sütun hizasında; geniş tablo yatay kaydırılır.
private struct TableBlockView: View {
    let header: [[MarkdownInline]]
    let alignments: [MarkdownTableAlignment]
    let rows: [[[MarkdownInline]]]
    let webSources: [WebSource]
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { (cell: (offset: Int, element: [MarkdownInline])) in
                        tableCell(inlines: cell.element, column: cell.offset, weight: .semibold)
                            .background(Theme.soft)
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { (row: (offset: Int, element: [[MarkdownInline]])) in
                    Rectangle().fill(Theme.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.element.enumerated()), id: \.offset) { (cell: (offset: Int, element: [MarkdownInline])) in
                            tableCell(inlines: cell.element, column: cell.offset, weight: .regular)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            .padding(1)
        }
        .scrollIndicators(.automatic)
    }

    private func tableCell(inlines: [MarkdownInline], column: Int, weight: Font.Weight) -> some View {
        let alignment: MarkdownTableAlignment = alignments.indices.contains(column) ? alignments[column] : .leading
        return Text(answerAttributedText(
            inlines: inlines, webSources: webSources,
            style: AnswerTextStyle(
                accent: appearance.accent.color, citationFont: appearance.font(size: 10, weight: .semibold),
                strongFont: appearance.font(size: 13.5, weight: .bold),
                codeFont: appearance.monoFont(size: 12.5, weight: .regular), codeBackground: Theme.soft,
                webForeground: Theme.ink.opacity(0.7), webBackground: Theme.ink.opacity(0.07)
            )
        ))
        .font(appearance.font(size: 13.5, weight: weight))
        .foregroundStyle(Theme.ink)
        .multilineTextAlignment(textAlignment(alignment))
        .frame(minWidth: 60, maxWidth: 280, alignment: frameAlignment(alignment))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .answerTextSelection()
    }

    private func textAlignment(_ alignment: MarkdownTableAlignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

extension View {
    /// Cevap metninin seçimi: Mac'te metin seçilebilir; iPhone'da uzun basış cevabın menüsünü (kopyala, Markdown, paylaş)
    /// açar, metin seçimi onu örtmesin diye kapalıdır.
    @ViewBuilder
    func answerTextSelection() -> some View {
        #if os(macOS)
        textSelection(.enabled)
        #else
        self
        #endif
    }
}

// MARK: Markdown dosyası

/// Markdown dosya türü (`.md`).
public let markdownContentType: UTType = {
    guard let type = UTType(filenameExtension: "md", conformingTo: .plainText) else {
        preconditionFailure("md uzantısının dosya türü oluşturulamadı")
    }
    return type
}()

/// Kaydetme panelinin belgesi (Mac'te ".md olarak kaydet").
public struct MarkdownFileDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [markdownContentType] }

    public let text: String

    public init(text: String) {
        self.text = text
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Paylaşılacak Markdown dosyası (iPhone'da "Paylaş (.md)"): paylaşım anında geçici klasöre `<ad>.md` olarak yazılır.
public struct MarkdownShareFile: Transferable {
    public let fileName: String
    public let text: String

    public init(fileName: String, text: String) {
        self.fileName = fileName
        self.text = text
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: markdownContentType) { (file: MarkdownShareFile) -> SentTransferredFile in
            let directory: URL = FileManager.default.temporaryDirectory.appending(path: "AskExports/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url: URL = directory.appending(path: file.fileName)
            try Data(file.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
