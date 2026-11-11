import AINotepadCore
import AINotepadUI
import Testing

@Suite struct ThemeContrastTests {
    /// Soluk yazı (`muted`) her temada zemin, kart, soluk yüzey ve seçili satır üstünde en az 4,5:1 (WCAG AA).
    @Test func mutedTextIsReadableOnEverySurface() {
        let sets: [(name: String, colors: ThemeColorSet)] = [
            ("light", .light), ("dark", .dark), ("emberLight", .emberLight), ("emberDark", .emberDark),
        ]
        for (name, colors) in sets {
            for (surface, hex) in [("background", colors.background), ("card", colors.card), ("soft", colors.soft), ("selected", colors.selected)] {
                let ratio: Double = contrastRatio(foreground: colors.muted, background: hex)
                #expect(ratio >= 4.5, "\(name) muted on \(surface): \(ratio)")
            }
            #expect(contrastRatio(foreground: colors.ink, background: colors.background) >= 7, "\(name) ink")
        }
    }

    @Test func contrastRatioMatchesKnownValues() {
        #expect(abs(contrastRatio(foreground: 0x000000, background: 0xFFFFFF) - 21) < 0.01)
        #expect(abs(contrastRatio(foreground: 0x777777, background: 0xFFFFFF) - 4.48) < 0.01)
    }

    @Test func bottomPanelTakesAtMostFortyFivePercent() {
        #expect(bottomPanelMaxHeight(pageHeight: 560, cap: 340) == 252)
        #expect(bottomPanelMaxHeight(pageHeight: 1000, cap: 340) == 340)
        #expect(bottomPanelMaxHeight(pageHeight: 0, cap: 340) == 340)
    }

    @Test func enlargedConversationLeavesRoomForThePanelChrome() {
        #expect(enlargedConversationMaxHeight(pageHeight: 760, chrome: 240) == 520)
        // Klavye açıkken sayfa kısa: en az 160 pt kalır.
        #expect(enlargedConversationMaxHeight(pageHeight: 300, chrome: 240) == 160)
        #expect(enlargedConversationMaxHeight(pageHeight: 0, chrome: 240) == 160)
    }
}

@Suite struct StreamingMarkdownTests {
    /// Akış boyunca her önek, bütün metnin ayrıştırmasıyla aynı paragraf ve başlıkları verir; önek yalnız paragraf
    /// bitince yeniden ayrıştırılır.
    @Test func streamedBlocksMatchFullParse() {
        let text: String = "# Plan\n\nThe beta opens [1].\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nLast paragraph **bold**."
        var state: StreamingMarkdown = .empty
        var last: [MarkdownBlock] = []
        for end in 1...text.count {
            let step: (state: StreamingMarkdown, blocks: [MarkdownBlock]) = streamingMarkdown(previous: state, text: String(text.prefix(end)))
            state = step.state
            last = step.blocks
        }
        #expect(last == parseMarkdown(text: text))
    }

    @Test func blankLineInsideCodeFenceDoesNotSplit() {
        let open: String = "```\nline one\n\nline two"
        let step: (state: StreamingMarkdown, blocks: [MarkdownBlock]) = streamingMarkdown(previous: .empty, text: open)
        #expect(step.blocks == parseMarkdown(text: open))
    }
}
