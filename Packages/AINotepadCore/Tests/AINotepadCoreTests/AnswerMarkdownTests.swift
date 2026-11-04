import Foundation
import Testing
@testable import AINotepadCore

/// Sor cevaplarının Markdown ayrıştırıcısı, kod bloklarındaki kaynak işaretleri ve Markdown dışa aktarımı.
@Suite struct AnswerMarkdownTests {
    // Başlık, paragraf, kalın/italik/kod/bağlantı ve kaynak işaretleri ayrı öğelerdir; ardışık işaretler tekrarsız birleşir.
    @Test func headingsParagraphsAndInlines() {
        let blocks: [MarkdownBlock] = parseMarkdown(text: "## Plan\n\n**Bütçe** _artacak_ ve `run()` [1] [1][2][w1].\nBkz. [site](https://a.example).")
        #expect(blocks == [
            .heading(level: 2, content: [.text("Plan")]),
            .paragraph([
                .strong([.text("Bütçe")]), .text(" "), .emphasis([.text("artacak")]), .text(" ve "), .code("run()"), .text(" "),
                .citation(1), .citation(2), .webCitation(1), .text("."), .lineBreak, .text("Bkz. "),
                .link(label: [.text("site")], url: "https://a.example"), .text("."),
            ]),
        ])
    }

    // Sözcük içindeki "_" (snake_case) vurgu değildir; kapanmamış "**" düz yazı kalır (akış sürerken).
    @Test func underscoresInWordsAndUnclosedBold() {
        #expect(parseInlines(text: "max_tokens ve snake_case_name") == [.text("max_tokens ve snake_case_name")])
        #expect(parseInlines(text: "**yarım") == [.text("**yarım")])
        #expect(parseInlines(text: "~~eski~~ fiyat") == [.strikethrough([.text("eski")]), .text(" fiyat")])
    }

    // Çıplak adres ve açılı bağlantı tıklanabilir; sondaki nokta adrese girmez; "[1](x)" kaynak değil bağlantıdır.
    @Test func urlsAndLinkThatLooksLikeCitation() {
        #expect(parseInlines(text: "Bkz. https://example.com/a.") == [.text("Bkz. "), .link(label: [.text("https://example.com/a")], url: "https://example.com/a"), .text(".")])
        #expect(parseInlines(text: "<https://x.example>") == [.link(label: [.text("https://x.example")], url: "https://x.example")])
        #expect(parseInlines(text: "[1](https://x.example)") == [.link(label: [.text("1")], url: "https://x.example")])
    }

    // İç içe sırasız liste, numarası 3'ten başlayan sıralı liste ve görev kutuları.
    @Test func nestedAndOrderedLists() {
        let blocks: [MarkdownBlock] = parseMarkdown(text: "- Bir\n  - İç\n- [x] İki\n\n3. Üç\n4. Dört")
        #expect(blocks == [
            .list(ordered: false, start: 1, items: [
                [.paragraph([.text("Bir")]), .list(ordered: false, start: 1, items: [[.paragraph([.text("İç")])]])],
                [.paragraph([.text("☑ İki")])],
            ]),
            .list(ordered: true, start: 3, items: [[.paragraph([.text("Üç")])], [.paragraph([.text("Dört")])]]),
        ])
    }

    // Kapanmış kod bloğu dil ve metniyle; kapanmamış blok (akış sürerken) sona kadar koddur; içindeki "[1]" kod kalır.
    @Test func fencedCodeClosedAndOpen() {
        #expect(parseMarkdown(text: "```swift\nlet a = arr[1]\n```\nSonra") == [.code(language: "swift", text: "let a = arr[1]"), .paragraph([.text("Sonra")])])
        #expect(parseMarkdown(text: "Önce\n~~~\nyarım\nkod") == [.paragraph([.text("Önce")]), .code(language: "", text: "yarım\nkod")])
    }

    // GFM tablosu: hizalar, kaçışlı "|", kod içindeki "|", hücrede kaynak işareti; eksik hücre boş, fazlası atılır.
    @Test func tables() {
        let text: String = "| Ad | Not | Puan |\n|:---|:---:|---:|\n| A \\| B | `x|y` [2] | 3 |\n| C | D |\n| E | F | G | H |"
        #expect(parseMarkdown(text: text) == [
            .table(
                header: [[.text("Ad")], [.text("Not")], [.text("Puan")]],
                alignments: [.leading, .center, .trailing],
                rows: [
                    [[.text("A | B")], [.code("x|y"), .text(" "), .citation(2)], [.text("3")]],
                    [[.text("C")], [.text("D")], []],
                    [[.text("E")], [.text("F")], [.text("G")]],
                ]
            ),
        ])
        // Ayırıcısı henüz gelmemiş başlık satırı şimdilik paragraftır.
        #expect(parseMarkdown(text: "| Ad | Not |") == [.paragraph([.text("| Ad | Not |")])])
    }

    // Alıntı blokları ve yatay çizgi.
    @Test func quotesAndRules() {
        #expect(parseMarkdown(text: "> Alıntı\n> **iki**\n\n---\nSon") == [
            .quote([.paragraph([.text("Alıntı"), .lineBreak, .strong([.text("iki")])])]),
            .rule,
            .paragraph([.text("Son")]),
        ])
    }

    // Kod bloğundaki kaynak işaretleri koddan çıkıp bloğun altına taşınır ve numaralanır; `arr[1]` gibi kod ve satır içi
    // kod dokunulmadan kalır; kapanmamış blokta işaretler gösterilmez.
    @Test func citationsLeaveCodeBlocks() {
        let passages: [ArchivePassage] = (1...3).map { (index: Int) -> ArchivePassage in
            ArchivePassage(id: "p\(index)", meetingID: "m", meetingTitle: "T", meetingDate: Date(timeIntervalSince1970: 0), kind: .note, startSec: 0, text: "x")
        }
        let answer: ArchiveAnswer = citedAnswer(
            text: "Hedef [3].\n```\nAjan: teslim cuma [2].\nlet x = arr[1] [w1]\n```\nAyrıca `a[2]` kalır.", passages: passages, webSources: []
        )
        #expect(answer.text == "Hedef [1].\n```\nAjan: teslim cuma.\nlet x = arr[1]\n```\n[2][w1]\nAyrıca `a[2]` kalır.")
        #expect(answer.sources.map(\.id) == ["p3", "p2"])
        let open: ArchiveAnswer = citedAnswer(text: "```\nteslim [1]\n", passages: passages, webSources: [])
        #expect(open.text == "```\nteslim")
        #expect(open.sources.isEmpty)
    }

    // Markdown dosyası: başlık, kod olduğu gibi, düz yazıdaki işaretler dipnot; dipnot tanımları sonda.
    @Test func markdownExportUsesFootnotes() {
        let source: ArchivePassage = ArchivePassage(
            id: "a-note", meetingID: "a", meetingTitle: "Haftalık", meetingDate: Date(timeIntervalSince1970: 1_792_000_000), kind: .note, startSec: 0, text: "x"
        )
        let answer: ArchiveAnswer = ArchiveAnswer(
            text: "Karar [1] ve fiyat [w1].\n```\narr[1]\n```", sources: [source], webSources: [WebSource(url: "https://example.com/p", title: "Fiyat [2026]")]
        )
        let locale: Locale = Locale(identifier: "en_US")
        let date: String = source.meetingDate.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
        #expect(archiveAnswerMarkdown(title: "Ne karar\nverildi?", answer: answer, noteLabel: "note", locale: locale) == """
        # Ne karar verildi?

        Karar [^1] ve fiyat [^w1].
        ```
        arr[1]
        ```

        [^1]: Haftalık · \(date) · note
        [^w1]: [Fiyat [2026\\]](https://example.com/p)

        """)
    }

    // Dosya adı: kullanılamayan karakterler atılır, 60 karakterle sınırlanır, boşsa yedek ad.
    @Test func markdownFileName() {
        #expect(askMarkdownFileName(title: "Ajanıma: nasıl \"istem\" yazmalıyım?", fallback: "Cevap") == "Ajanıma nasıl istem yazmalıyım.md")
        #expect(askMarkdownFileName(title: "...", fallback: "Cevap") == "Cevap.md")
        #expect(askMarkdownFileName(title: String(repeating: "a", count: 80), fallback: "Cevap") == String(repeating: "a", count: 60) + ".md")
    }
}
