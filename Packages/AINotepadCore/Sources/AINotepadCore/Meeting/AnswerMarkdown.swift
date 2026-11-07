import Foundation

/// Sor cevaplarının Markdown'ı (GitHub biçiminin modelin kullandığı alt kümesi): başlıklar, kalın/italik/üstü çizili,
/// sıralı ve sırasız (iç içe) listeler, görev kutuları, bağlantılar, satır içi kod, çitli kod blokları, tablolar, alıntı
/// blokları ve yatay çizgiler. Toplantı kaynak işaretleri (`[2]`) ve web kaynak işaretleri (`[w1]`) ayrı satır içi
/// öğelerdir: arayüz onları ayrı, dokunulabilir rozetler olarak çizer. Ayrıştırıcı akış sırasında yarım kalan metni de
/// kabul eder: kapanmamış kod bloğu sona kadar koddur, kapanmamış `**` düz yazıdır, başlığı gelmiş ama ayıracı gelmemiş
/// tablo şimdilik paragraftır.

/// Satır içi öğe.
public enum MarkdownInline: Sendable, Equatable {
    case text(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(label: [MarkdownInline], url: String)
    /// Toplantı kaynağı (1'den başlar; cevabın `sources` sırası).
    case citation(Int)
    /// Web kaynağı (1'den başlar; cevabın `webSources` sırası).
    case webCitation(Int)
    case lineBreak
}

/// Tablo sütununun hizası.
public enum MarkdownTableAlignment: Sendable, Equatable {
    case leading
    case center
    case trailing
}

/// Blok öğe.
public indirect enum MarkdownBlock: Sendable, Equatable {
    case heading(level: Int, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    /// Liste; her madde kendi bloklarından oluşur (iç içe listeler dahil).
    case list(ordered: Bool, start: Int, items: [[MarkdownBlock]])
    /// Çitli kod: dil (bilgi dizgisinin ilk sözcüğü; yoksa boş) ve metin.
    case code(language: String, text: String)
    /// Tablo: her satırın hücre sayısı başlığınkine eşittir (eksikler boş, fazlalar atılır).
    case table(header: [[MarkdownInline]], alignments: [MarkdownTableAlignment], rows: [[[MarkdownInline]]])
    case quote([MarkdownBlock])
    case rule
}

/// Metni bloklara ayrıştırır. Saf fonksiyondur.
public func parseMarkdown(text: String) -> [MarkdownBlock] {
    parseBlocks(lines: text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
}

/// Akan cevabın ayrıştırması: metnin kararlı öneki (son boş satıra kadar; açık kod çiti içinde değil) ve onun blokları.
/// Akış sırasında her karede bütün cevap yeniden ayrıştırılmaz: önek yalnız yeni bir paragraf bitince ayrıştırılır, her
/// karede yalnız sondaki yarım paragraf.
public struct StreamingMarkdown: Sendable, Equatable {
    let stablePrefix: String
    let stableBlocks: [MarkdownBlock]

    public static let empty: StreamingMarkdown = StreamingMarkdown(stablePrefix: "", stableBlocks: [])
}

/// Akan metnin blokları ve sonraki kare için durum (bkz. `StreamingMarkdown`). Önek değişmediyse blokları yeniden
/// kullanılır; metin öncekinin devamı değilse (cevap yeniden başladı) baştan ayrıştırılır. Sonuç, öneki ve kalanı ayrı
/// ayrı ayrıştırmaktır: boş satırla ayrılan iki liste maddesi akış sırasında iki liste görünebilir; bitmiş cevap
/// `parseMarkdown` ile bütün olarak çizilir. Saf fonksiyondur.
public func streamingMarkdown(previous: StreamingMarkdown, text: String) -> (state: StreamingMarkdown, blocks: [MarkdownBlock]) {
    let split: String.Index = stableSplit(text: text)
    let prefix: Substring = text[..<split]
    let state: StreamingMarkdown = prefix == previous.stablePrefix
        ? previous
        : StreamingMarkdown(stablePrefix: String(prefix), stableBlocks: parseMarkdown(text: String(prefix)))
    let tail: Substring = text[split...]
    return (state: state, blocks: state.stableBlocks + (tail.isEmpty ? [] : parseMarkdown(text: String(tail))))
}

/// Metnin kararlı ön ekinin sonu: açık kod çiti dışında kalan son boş satırdan (`\n\n`) sonrası; yoksa baş. Saf
/// fonksiyondur.
func stableSplit(text: String) -> String.Index {
    var split: String.Index = text.startIndex
    var fence: MarkdownFence?
    var lineStart: String.Index = text.startIndex
    var previousLineBlank: Bool = false
    while lineStart < text.endIndex {
        let lineEnd: String.Index = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
        let line: String = String(text[lineStart..<lineEnd])
        let isBlank: Bool = line.trimmingCharacters(in: .whitespaces).isEmpty
        if let open = fence {
            if closesFence(line: line, fence: open) {
                fence = nil
            }
        } else if let opened = openingFence(line: line) {
            fence = opened
        } else if !isBlank, previousLineBlank, lineStart > text.startIndex {
            // Boş satırdan sonra başlayan satır: önceki bloklar bitti.
            split = lineStart
        }
        previousLineBlank = isBlank && fence == nil
        guard lineEnd < text.endIndex else {
            break
        }
        lineStart = text.index(after: lineEnd)
    }
    return split
}

// MARK: Bloklar

/// Satırın baştaki boşluk sayısı (sekme 4 boşluk sayılır). Saf fonksiyondur.
func leadingSpaces(line: String) -> Int {
    line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
}

/// Satırın başından en çok `count` boşluk atar. Saf fonksiyondur.
func dropIndent(line: String, count: Int) -> String {
    var removed: Int = 0
    var index: String.Index = line.startIndex
    while index < line.endIndex, removed < count, line[index] == " " || line[index] == "\t" {
        removed += line[index] == "\t" ? 4 : 1
        index = line.index(after: index)
    }
    return String(line[index...])
}

/// Çit açılışı: en çok 3 boşluk girintili, en az 3 "`" ya da "~"; dil bilgi dizgisinin ilk sözcüğü.
struct MarkdownFence: Equatable {
    let marker: Character
    let length: Int
    let indent: Int
    let language: String
}

/// Satır bir çit açıyorsa çiti. "`" çitinin bilgi dizgisinde "`" olamaz. Saf fonksiyondur.
func openingFence(line: String) -> MarkdownFence? {
    let indent: Int = leadingSpaces(line: line)
    guard indent <= 3 else {
        return nil
    }
    let rest: Substring = Substring(dropIndent(line: line, count: indent))
    guard let marker = rest.first, marker == "`" || marker == "~" else {
        return nil
    }
    let run: Int = rest.prefix { $0 == marker }.count
    guard run >= 3 else {
        return nil
    }
    let info: Substring = rest.dropFirst(run)
    if marker == "`", info.contains("`") {
        return nil
    }
    let language: String = info.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    return MarkdownFence(marker: marker, length: run, indent: indent, language: language)
}

/// Satır `fence` çitini kapatıyor mu: aynı işaretten en az aynı uzunlukta ve ardında yalnız boşluk. Saf fonksiyondur.
func closesFence(line: String, fence: MarkdownFence) -> Bool {
    let indent: Int = leadingSpaces(line: line)
    guard indent <= 3 else {
        return false
    }
    let rest: Substring = Substring(dropIndent(line: line, count: indent))
    let run: Int = rest.prefix { $0 == fence.marker }.count
    return run >= fence.length && rest.dropFirst(run).allSatisfy(\.isWhitespace)
}

/// ATX başlık: düzey ve içerik. Saf fonksiyondur.
func headingLine(line: String) -> (level: Int, text: String)? {
    guard leadingSpaces(line: line) <= 3 else {
        return nil
    }
    let trimmed: Substring = line.drop { $0 == " " }
    let level: Int = trimmed.prefix { $0 == "#" }.count
    guard (1...6).contains(level) else {
        return nil
    }
    let rest: Substring = trimmed.dropFirst(level)
    guard rest.isEmpty || rest.first?.isWhitespace == true else {
        return nil
    }
    var content: String = rest.trimmingCharacters(in: .whitespaces)
    // Kapanış "#"leri (önünde boşluk varsa ya da içerik yalnız onlarsa) başlığa dahil değildir.
    if content.allSatisfy({ $0 == "#" }) {
        content = ""
    } else if let closing = content.range(of: #"\s+#+$"#, options: .regularExpression) {
        content.removeSubrange(closing)
    }
    return (level, content)
}

/// Yatay çizgi: en çok 3 boşluk girintili, aynı işaretten ("-", "*", "_") en az 3, arada boşluk olabilir. Saf
/// fonksiyondur.
func isRule(line: String) -> Bool {
    guard leadingSpaces(line: line) <= 3 else {
        return false
    }
    let characters: [Character] = line.filter { !$0.isWhitespace }
    guard characters.count >= 3, let first = characters.first, "-*_".contains(first) else {
        return false
    }
    return characters.allSatisfy { $0 == first }
}

/// Alıntı satırı: en çok 3 boşluk girintili ">"; ">" ve ardındaki tek boşluk atılmış içerik. Saf fonksiyondur.
func quoteContent(line: String) -> String? {
    guard leadingSpaces(line: line) <= 3 else {
        return nil
    }
    let trimmed: Substring = line.drop { $0 == " " }
    guard trimmed.first == ">" else {
        return nil
    }
    let rest: Substring = trimmed.dropFirst()
    return String(rest.first == " " ? rest.dropFirst() : rest)
}

/// Liste maddesi satırı.
struct MarkdownListMarker: Equatable {
    let ordered: Bool
    let number: Int
    /// Madde işaretinin girintisi.
    let indent: Int
    /// İçeriğin başladığı sütun (devam satırları en az bu kadar girintili).
    let contentIndent: Int
    let content: String
}

/// Satır bir liste maddesiyse maddesi: "-", "*", "+" ya da "1." / "1)" ve ardında boşluk (ya da satır sonu). Saf
/// fonksiyondur.
func listMarker(line: String) -> MarkdownListMarker? {
    let indent: Int = leadingSpaces(line: line)
    let rest: String = dropIndent(line: line, count: indent)
    guard let first = rest.first else {
        return nil
    }
    let markerLength: Int
    let ordered: Bool
    let number: Int
    if "-*+".contains(first) {
        markerLength = 1
        ordered = false
        number = 1
    } else {
        let digits: Substring = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let value = Int(digits) else {
            return nil
        }
        let after: Substring = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")" else {
            return nil
        }
        markerLength = digits.count + 1
        ordered = true
        number = value
    }
    let afterMarker: Substring = rest.dropFirst(markerLength)
    guard afterMarker.isEmpty || afterMarker.first == " " || afterMarker.first == "\t" else {
        return nil
    }
    let spaces: Int = afterMarker.prefix { $0 == " " }.count
    // Çok boşluklu madde (5+) içeriği girintili kod sayılmaz; içerik işaretten bir boşluk sonra başlar.
    let gap: Int = afterMarker.isEmpty ? 1 : (spaces > 4 ? 1 : max(1, spaces))
    return MarkdownListMarker(
        ordered: ordered, number: number, indent: indent, contentIndent: indent + markerLength + gap,
        content: String(afterMarker.drop { $0 == " " || $0 == "\t" })
    )
}

/// Tablo ayırıcı satırının hizaları: hücreler yalnız "-" ve uçlarda ":" (en az bir "-"); satırda "|" olmalı. Saf
/// fonksiyondur.
func tableDelimiter(line: String) -> [MarkdownTableAlignment]? {
    guard line.contains("|") else {
        return nil
    }
    let alignments: [MarkdownTableAlignment?] = tableCells(line: line).map { (cell: String) -> MarkdownTableAlignment? in
        guard cell.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let left: Bool = cell.hasPrefix(":")
        let right: Bool = cell.hasSuffix(":")
        return left && right ? .center : right ? .trailing : .leading
    }
    let valid: [MarkdownTableAlignment] = alignments.compactMap { $0 }
    return valid.count == alignments.count && !valid.isEmpty ? valid : nil
}

/// Tablo satırının hücreleri: baştaki ve sondaki "|" atılır, "\|" ve satır içi kodun içindeki "|" ayırıcı değildir.
/// Saf fonksiyondur.
func tableCells(line: String) -> [String] {
    var trimmed: Substring = Substring(line.trimmingCharacters(in: .whitespaces))
    if trimmed.hasPrefix("|") {
        trimmed = trimmed.dropFirst()
    }
    if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") {
        trimmed = trimmed.dropLast()
    }
    var cells: [String] = []
    var current: String = ""
    var inCode: Bool = false
    var escaped: Bool = false
    for character in trimmed {
        if escaped {
            current.append(character == "|" ? "|" : "\\\(character)")
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "`" {
            inCode.toggle()
            current.append(character)
        } else if character == "|", !inCode {
            cells.append(current.trimmingCharacters(in: .whitespaces))
            current = ""
        } else {
            current.append(character)
        }
    }
    if escaped {
        current.append("\\")
    }
    cells.append(current.trimmingCharacters(in: .whitespaces))
    return cells
}

/// `index`'teki satır bir tablo başlatıyor mu (başlık satırı "|" içerir, ardındaki satır ayırıcıdır ve sütun sayıları
/// tutar); başlatıyorsa hizalar. Saf fonksiyondur.
func tableStart(lines: [String], index: Int) -> [MarkdownTableAlignment]? {
    guard index + 1 < lines.count, lines[index].contains("|"), let alignments = tableDelimiter(line: lines[index + 1]) else {
        return nil
    }
    return tableCells(line: lines[index]).count == alignments.count ? alignments : nil
}

/// Satır yeni bir blok başlatıyor mu (paragrafı ya da tembel devam satırını keser). Saf fonksiyondur.
func startsBlock(lines: [String], index: Int) -> Bool {
    let line: String = lines[index]
    return openingFence(line: line) != nil || headingLine(line: line) != nil || quoteContent(line: line) != nil || isRule(line: line)
        || listMarker(line: line) != nil || tableStart(lines: lines, index: index) != nil
}

/// Satırları bloklara ayrıştırır. Saf fonksiyondur.
func parseBlocks(lines: [String]) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var index: Int = 0
    while index < lines.count {
        let line: String = lines[index]
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        } else if let fence = openingFence(line: line) {
            var body: [String] = []
            index += 1
            while index < lines.count, !closesFence(line: lines[index], fence: fence) {
                body.append(dropIndent(line: lines[index], count: fence.indent))
                index += 1
            }
            // Kapanış çiti (akış sürerken henüz gelmemiş olabilir).
            index += 1
            blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
        } else if let heading = headingLine(line: line) {
            blocks.append(.heading(level: heading.level, content: parseInlines(text: heading.text)))
            index += 1
        } else if isRule(line: line) {
            blocks.append(.rule)
            index += 1
        } else if quoteContent(line: line) != nil {
            var body: [String] = []
            while index < lines.count, let content = quoteContent(line: lines[index]) {
                body.append(content)
                index += 1
            }
            blocks.append(.quote(parseBlocks(lines: body)))
        } else if let alignments = tableStart(lines: lines, index: index) {
            let header: [[MarkdownInline]] = tableCells(line: line).map { parseInlines(text: $0) }
            index += 2
            var rows: [[[MarkdownInline]]] = []
            while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                let cells: [String] = tableCells(line: lines[index])
                let padded: [String] = Array((cells + Array(repeating: "", count: max(0, header.count - cells.count))).prefix(header.count))
                rows.append(padded.map { parseInlines(text: $0) })
                index += 1
            }
            blocks.append(.table(header: header, alignments: alignments, rows: rows))
        } else if let marker = listMarker(line: line) {
            let parsed: (block: MarkdownBlock, next: Int) = parseList(lines: lines, start: index, first: marker)
            blocks.append(parsed.block)
            index = parsed.next
        } else {
            var body: [String] = [line.trimmingCharacters(in: .whitespaces)]
            index += 1
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty, !startsBlock(lines: lines, index: index) {
                body.append(lines[index].trimmingCharacters(in: .whitespaces))
                index += 1
            }
            blocks.append(.paragraph(parseInlines(text: body.joined(separator: "\n"))))
        }
    }
    return blocks
}

/// `start`'taki maddeyle başlayan listeyi ayrıştırır: aynı türden ve daha az girintili maddeler kardeştir; maddenin
/// içerik sütunu kadar girintili satırlar (iç içe listeler dahil) maddeye aittir; boş satırdan sonra liste ancak ardından
/// kardeş madde ya da girintili devam gelirse sürer; girintisiz satır önceki satır boş değilse paragrafın tembel
/// devamıdır. Saf fonksiyondur.
func parseList(lines: [String], start: Int, first: MarkdownListMarker) -> (block: MarkdownBlock, next: Int) {
    var items: [[String]] = []
    var current: [String] = [taskBox(content: first.content)]
    var contentIndent: Int = first.contentIndent
    var index: Int = start + 1
    var previousBlank: Bool = false
    while index < lines.count {
        let line: String = lines[index]
        let blank: Bool = line.trimmingCharacters(in: .whitespaces).isEmpty
        if blank {
            // Boş satır: ardından liste sürmüyorsa liste biter.
            let nextIndex: Int? = lines[(index + 1)...].firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let nextIndex else {
                break
            }
            let next: String = lines[nextIndex]
            let continues: Bool = leadingSpaces(line: next) >= contentIndent
                || listMarker(line: next).map { $0.ordered == first.ordered && $0.indent < contentIndent } == true
            guard continues else {
                break
            }
            current.append("")
            previousBlank = true
            index += 1
            continue
        }
        let indent: Int = leadingSpaces(line: line)
        if indent >= contentIndent {
            current.append(dropIndent(line: line, count: contentIndent))
        } else if let marker = listMarker(line: line), indent <= first.indent + 1 || indent < contentIndent {
            guard marker.ordered == first.ordered, !isRule(line: line) else {
                break
            }
            items.append(current)
            current = [taskBox(content: marker.content)]
            contentIndent = marker.contentIndent
        } else if !previousBlank, !startsBlock(lines: lines, index: index) {
            current.append(line.trimmingCharacters(in: .whitespaces))
        } else {
            break
        }
        previousBlank = false
        index += 1
    }
    items.append(current)
    return (.list(ordered: first.ordered, start: first.number, items: items.map { parseBlocks(lines: $0) }), index)
}

/// Görev kutusu: "[ ] iş" → "☐ iş", "[x] iş" → "☑ iş". Saf fonksiyondur.
func taskBox(content: String) -> String {
    if content.hasPrefix("[ ] ") {
        return "☐ " + content.dropFirst(4)
    }
    if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
        return "☑ " + content.dropFirst(4)
    }
    return content
}

// MARK: Satır içi

/// Satır içi Markdown'ı öğelere ayrıştırır; ardışık kaynak işaretleri arasındaki boşluk atılır ve aynı işaret bir kez
/// kalır ("[1] [1][2]" → 1, 2). Saf fonksiyondur.
public func parseInlines(text: String) -> [MarkdownInline] {
    mergedCitations(inlines: scanInlines(characters: Array(text)))
}

/// Ardışık kaynak işaretlerini birleştirir: aralarındaki yalnız boşluktan oluşan metin atılır, tekrarlar kalkar. İç
/// öğelere de uygulanır. Saf fonksiyondur.
func mergedCitations(inlines: [MarkdownInline]) -> [MarkdownInline] {
    let nested: [MarkdownInline] = inlines.map { (inline: MarkdownInline) -> MarkdownInline in
        switch inline {
        case .strong(let children): .strong(mergedCitations(inlines: children))
        case .emphasis(let children): .emphasis(mergedCitations(inlines: children))
        case .strikethrough(let children): .strikethrough(mergedCitations(inlines: children))
        case .link(let label, let url): .link(label: mergedCitations(inlines: label), url: url)
        case .text, .code, .citation, .webCitation, .lineBreak: inline
        }
    }
    return nested.enumerated().reduce(into: [MarkdownInline]()) { (result: inout [MarkdownInline], item: (offset: Int, element: MarkdownInline)) -> Void in
        let inline: MarkdownInline = item.element
        if isCitation(inline) {
            // Önceki kaynak işaretiyle arasındaki boşluk atılır; aynı grupta tekrarlanan işaret eklenmez.
            if case .text(let gap) = result.last, gap.allSatisfy(\.isWhitespace), result.count >= 2, isCitation(result[result.count - 2]) {
                result.removeLast()
            }
            let group: [MarkdownInline] = Array(result.reversed().prefix { isCitation($0) })
            if !group.contains(inline) {
                result.append(inline)
            }
        } else {
            result.append(inline)
        }
    }
}

/// Öğe bir kaynak işareti mi. Saf fonksiyondur.
public func isCitation(_ inline: MarkdownInline) -> Bool {
    switch inline {
    case .citation, .webCitation: true
    default: false
    }
}

/// Karakter dizisini tarar. Saf fonksiyondur.
private func scanInlines(characters: [Character]) -> [MarkdownInline] {
    var result: [MarkdownInline] = []
    var buffer: String = ""
    var index: Int = 0

    func flush() {
        if !buffer.isEmpty {
            result.append(.text(buffer))
            buffer = ""
        }
    }

    while index < characters.count {
        let character: Character = characters[index]
        if character == "\\", index + 1 < characters.count, characters[index + 1].isPunctuation || characters[index + 1].isSymbol {
            buffer.append(characters[index + 1])
            index += 2
        } else if character == "\n" {
            flush()
            result.append(.lineBreak)
            index += 1
        } else if character == "`", let span = codeSpan(characters: characters, start: index) {
            flush()
            result.append(.code(span.code))
            index = span.end
        } else if character == "[", let citation = citationMarker(characters: characters, start: index) {
            flush()
            result.append(citation.inline)
            index = citation.end
        } else if character == "[", let link = linkSpan(characters: characters, start: index) {
            flush()
            result.append(.link(label: scanInlines(characters: link.label), url: link.url))
            index = link.end
        } else if character == "<", let link = autolink(characters: characters, start: index) {
            flush()
            result.append(.link(label: [.text(link.url)], url: link.url))
            index = link.end
        } else if character == "h", index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber), let url = bareURL(characters: characters, start: index) {
            flush()
            result.append(.link(label: [.text(url)], url: url))
            index += url.count
        } else if character == "*" || character == "_" || character == "~", let span = delimited(characters: characters, start: index) {
            flush()
            let inner: [MarkdownInline] = scanInlines(characters: span.inner)
            switch span.kind {
            case .strong: result.append(.strong(inner))
            case .emphasis: result.append(.emphasis(inner))
            case .strikethrough: result.append(.strikethrough(inner))
            }
            index = span.end
        } else {
            buffer.append(character)
            index += 1
        }
    }
    flush()
    return result
}

/// Satır içi kod: aynı uzunlukta "`" dizisiyle kapanan aralık; içeriğin iki ucundaki tek boşluk atılır. Kapanmazsa nil.
/// Saf fonksiyondur.
private func codeSpan(characters: [Character], start: Int) -> (code: String, end: Int)? {
    let run: Int = characters[start...].prefix { $0 == "`" }.count
    var index: Int = start + run
    while index < characters.count {
        if characters[index] == "`" {
            let closing: Int = characters[index...].prefix { $0 == "`" }.count
            if closing == run {
                var code: String = String(characters[(start + run)..<index]).replacingOccurrences(of: "\n", with: " ")
                if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) {
                    code = String(code.dropFirst().dropLast())
                }
                return (code, index + closing)
            }
            index += closing
        } else {
            index += 1
        }
    }
    return nil
}

/// Kaynak işareti: "[12]" toplantı, "[w3]" web. Saf fonksiyondur.
private func citationMarker(characters: [Character], start: Int) -> (inline: MarkdownInline, end: Int)? {
    var index: Int = start + 1
    let isWeb: Bool = index < characters.count && characters[index] == "w"
    if isWeb {
        index += 1
    }
    let digits: [Character] = Array(characters[min(index, characters.count)...].prefix { $0.isASCII && $0.isNumber })
    let end: Int = index + digits.count
    guard (1...4).contains(digits.count), end < characters.count, characters[end] == "]", let number = Int(String(digits)), number > 0 else {
        return nil
    }
    // "[1](adres)" bir bağlantıdır.
    if end + 1 < characters.count, characters[end + 1] == "(" {
        return nil
    }
    return (isWeb ? .webCitation(number) : .citation(number), end + 1)
}

/// Bağlantı: "[etiket](adres)" (etiketteki köşeli parantezler dengeli, adres boşluksuz; isteğe bağlı "başlık" atılır).
/// Saf fonksiyondur.
private func linkSpan(characters: [Character], start: Int) -> (label: [Character], url: String, end: Int)? {
    var depth: Int = 0
    var index: Int = start
    while index < characters.count {
        let character: Character = characters[index]
        if character == "\n" {
            return nil
        }
        if character == "[" {
            depth += 1
        } else if character == "]" {
            depth -= 1
            if depth == 0 {
                break
            }
        }
        index += 1
    }
    guard index + 1 < characters.count, characters[index] == "]", characters[index + 1] == "(" else {
        return nil
    }
    let label: [Character] = Array(characters[(start + 1)..<index])
    guard let close = characters[(index + 2)...].firstIndex(of: ")") else {
        return nil
    }
    let target: String = String(characters[(index + 2)..<close]).trimmingCharacters(in: .whitespaces)
    let url: String = String(target.split(separator: " ", maxSplits: 1).first ?? "")
    guard !url.isEmpty, !url.contains("\n") else {
        return nil
    }
    let address: String = url.hasPrefix("<") && url.hasSuffix(">") ? String(url.dropFirst().dropLast()) : url
    // Yalnız web adresi bağlantı olur; file:, smb:, özel uygulama şemaları düz yazı kalır (adres görünür).
    guard isWebAddress(address) else {
        return nil
    }
    return (label, address, close + 1)
}

/// Adres bir web adresi mi ("http://" ya da "https://"; şema büyük/küçük harf duyarsız). Cevaplardaki bağlantılar ve
/// tıklanınca açılan adresler yalnız bunlar olabilir. Saf fonksiyondur.
public func isWebAddress(_ address: String) -> Bool {
    let lowered: String = address.lowercased()
    return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
}

/// Açılı bağlantı: "<https://…>". Saf fonksiyondur.
private func autolink(characters: [Character], start: Int) -> (url: String, end: Int)? {
    guard let close = characters[(start + 1)...].firstIndex(of: ">") else {
        return nil
    }
    let url: String = String(characters[(start + 1)..<close])
    guard url.hasPrefix("http://") || url.hasPrefix("https://"), !url.contains(where: \.isWhitespace) else {
        return nil
    }
    return (url, close + 1)
}

/// Çıplak adres ("https://…" boşluğa kadar; sondaki noktalama ve eşi olmayan kapanış parantezi adrese dahil değil). Saf
/// fonksiyondur.
private func bareURL(characters: [Character], start: Int) -> String? {
    let rest: String = String(characters[start...].prefix { !$0.isWhitespace && $0 != "<" && $0 != ">" })
    guard rest.hasPrefix("https://") || rest.hasPrefix("http://") else {
        return nil
    }
    var url: Substring = Substring(rest)
    while let last = url.last, ".,;:!?\"'*_".contains(last) || (last == ")" && url.filter({ $0 == "(" }).count < url.filter({ $0 == ")" }).count) {
        url = url.dropLast()
    }
    return url.count > "https://".count ? String(url) : nil
}

/// Vurgu türü.
private enum DelimiterKind {
    case strong
    case emphasis
    case strikethrough
}

/// Vurgu aralığı: "**…**", "__…__" kalın; "*…*", "_…_" italik; "~~…~~" üstü çizili. Açılıştan sonra ve kapanıştan önce
/// boşluk olamaz; "_" sözcük içinde (snake_case) vurgu değildir. Kapanmazsa nil (işaretler düz yazı kalır). Saf
/// fonksiyondur.
private func delimited(characters: [Character], start: Int) -> (kind: DelimiterKind, inner: [Character], end: Int)? {
    let marker: Character = characters[start]
    let run: Int = characters[start...].prefix { $0 == marker }.count
    let width: Int
    let kind: DelimiterKind
    switch (marker, run) {
    case ("~", 2...):
        width = 2
        kind = .strikethrough
    case ("~", _):
        return nil
    case (_, 2...):
        width = 2
        kind = .strong
    default:
        width = 1
        kind = .emphasis
    }
    let open: Int = start + width
    guard open < characters.count, !characters[open].isWhitespace else {
        return nil
    }
    if marker == "_", start > 0, characters[start - 1].isLetter || characters[start - 1].isNumber {
        return nil
    }
    var index: Int = open
    while index < characters.count {
        let character: Character = characters[index]
        if character == "`", let span = codeSpan(characters: characters, start: index) {
            index = span.end
            continue
        }
        if character == "\n", index + 1 < characters.count, characters[index + 1] == "\n" {
            return nil
        }
        if character == marker {
            let closing: Int = characters[index...].prefix { $0 == marker }.count
            let before: Character = characters[index - 1]
            let after: Character? = index + width < characters.count ? characters[index + width] : nil
            let flanking: Bool = !before.isWhitespace && index > open
            let wordInside: Bool = marker == "_" && after.map { $0.isLetter || $0.isNumber } == true
            if flanking, !wordInside, closing >= width, width == 2 || closing == 1 || closing >= 3 {
                return (kind, Array(characters[open..<index]), index + width)
            }
            index += closing
            continue
        }
        index += 1
    }
    return nil
}
