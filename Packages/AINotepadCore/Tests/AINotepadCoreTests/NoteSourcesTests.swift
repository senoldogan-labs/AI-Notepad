import Foundation
import Testing
@testable import AINotepadCore

/// Sabit bir toplantı transkripti: üç konu (beta tarihi, fiyat, destek), konuşmacılar ve zamanlar.
private func paragraph(_ id: String, _ person: Int?, _ start: Double, _ end: Double, _ text: String, translated: String?) -> TranscriptParagraph {
    TranscriptParagraph(
        id: id, speaker: person == nil ? .me : .others, person: person, startSec: start, endSec: end, text: text, turkish: translated,
        translationFailed: false, words: []
    )
}

private let weekly: [TranscriptParagraph] = [
    paragraph("p0", 1, 4, 13, "Morning, everyone. Three things today: the beta date, pricing, and how we support the first customers.", translated: nil),
    paragraph("p1", 1, 14, 24, "Engineering says the release candidate is stable. I'd like to open the beta on the fourteenth of November.", translated: nil),
    paragraph("p2", 2, 25, 36, "From our side that works. The export sync bug is the last blocker, and I'll have it fixed by Thursday.", translated: nil),
    paragraph("p3", nil, 37, 47, "Works for me. I'll write the release notes by Friday so they're ready a week ahead.", translated: nil),
    paragraph("p4", 3, 48, 58, "Sales has eighty customers who asked to join. Can we invite all of them in the first wave?", translated: nil),
    paragraph("p5", 1, 59, 70, "Let's cap the first wave at two hundred accounts in total and confirm the list on Monday.", translated: nil),
    paragraph("p6", 3, 612, 623, "On pricing: I have the Nordia call on Thursday and I need the latest pricing table before then.", translated: nil),
    paragraph("p7", nil, 624, 635, "I'll send you the pricing table today, right after this call.", translated: nil),
    paragraph("p8", 1, 636, 650, "And we keep the current tiers for the beta. No discounts until we see the usage numbers.", translated: nil),
    paragraph("p9", 2, 1310, 1321, "One more thing: support should have a weekly sync with us while the beta runs.", translated: nil),
    paragraph("p10", nil, 1322, 1335, "Agreed. I'll set up a Wednesday call with the support team.", translated: nil),
]

private let weeklyOutline: [OutlineItem] = [
    OutlineItem(startSec: 4, title: "Beta date", summary: "The beta opens on 14 November."),
    OutlineItem(startSec: 48, title: "Who gets invited", summary: "The first wave is capped at 200 accounts."),
    OutlineItem(startSec: 612, title: "Pricing", summary: "Current tiers stay."),
    OutlineItem(startSec: 1310, title: "Support during the beta", summary: "A weekly Wednesday sync."),
]

@Test func sourcesFindThePassagesThatShareTheBulletsWords() {
    let sources: NoteSources = noteSources(
        text: "Ayşe gets the latest pricing table before the Nordia call.", anchorSec: nil, paragraphs: weekly, outline: weeklyOutline
    )
    #expect(sources.quotes.map(\.id) == ["p6", "p7"])
    #expect(sources.context == NoteSourceContext(topic: "Pricing", startSec: 612, endSec: 635))
    #expect(sources.quotes.first?.excerpt == "On pricing: I have the Nordia call on Thursday and I need the latest pricing table before then.")
}

@Test func sourcesStayChronologicalAndAtMostThree() {
    let sources: NoteSources = noteSources(
        text: "The beta opens once the export sync bug is fixed; support gets a weekly sync during the beta.", anchorSec: nil, paragraphs: weekly, outline: weeklyOutline
    )
    #expect(sources.quotes.count <= noteSourceMaxQuotes)
    #expect(sources.quotes.map(\.paragraph.startSec) == sources.quotes.map(\.paragraph.startSec).sorted())
    #expect(sources.quotes.map(\.id).contains("p2"))
    #expect(sources.quotes.map(\.id).contains("p9"))
}

@Test func anchorBreaksTiesTowardTheMomentTheLineCameFrom() {
    // "beta" geçen paragraflar başta, fiyatta ve destekte: karar anı (21:50) desteğin paragrafını öne alır.
    let sources: NoteSources = noteSources(text: "Weekly beta sync.", anchorSec: 1310, paragraphs: weekly, outline: weeklyOutline)
    #expect(sources.quotes.first?.id == "p9")
    #expect(sources.context?.topic == "Support during the beta")
}

@Test func anchorAloneFindsTheMomentWhenNoWordsMatch() {
    let sources: NoteSources = noteSources(text: "Zzz qqq.", anchorSec: 630, paragraphs: weekly, outline: weeklyOutline)
    #expect(sources.quotes.map(\.id) == ["p7"])
}

@Test func noWordsAndNoAnchorGiveNoSources() {
    let sources: NoteSources = noteSources(text: "Zzz qqq.", anchorSec: nil, paragraphs: weekly, outline: weeklyOutline)
    #expect(sources == NoteSources(context: nil, quotes: []))
    #expect(noteSources(text: "pricing", anchorSec: nil, paragraphs: [], outline: []) == NoteSources(context: nil, quotes: []))
}

@Test func translationMatchesWhenTheNoteIsInAnotherLanguage() {
    // Not Türkçe, transkript Fince: eşleşme paragrafın çevirisinden gelir, alıntı da çeviriden gösterilir.
    let paragraphs: [TranscriptParagraph] = [
        paragraph("a", 1, 0, 9, "Hyvää huomenta kaikille.", translated: "Herkese günaydın."),
        paragraph("b", 2, 10, 20, "Hinnasto lähetetään tänään.", translated: "Fiyat tablosu bugün gönderilecek."),
        paragraph("c", 1, 21, 30, "Kiitos, nähdään torstaina.", translated: "Teşekkürler, perşembe görüşürüz."),
    ]
    let sources: NoteSources = noteSources(text: "Fiyat tablosu bugün gönderilecek.", anchorSec: nil, paragraphs: paragraphs, outline: [])
    #expect(sources.quotes.map(\.id) == ["b"])
    #expect(sources.quotes.first?.excerpt == "Fiyat tablosu bugün gönderilecek.")
    #expect(sources.context == NoteSourceContext(topic: nil, startSec: 10, endSec: 20))
}

@Test func excerptPicksTheMatchingSentenceAndClipsLongText() {
    let long: String = "First unrelated sentence here. Pricing " + String(repeating: "table words pricing ", count: 30)
    let item: TranscriptParagraph = paragraph("x", 1, 0, 30, long, translated: nil)
    let excerpt: String = sourceExcerpt(paragraph: item, stems: ["prici"], idf: ["prici": 1])
    #expect(excerpt.hasPrefix("Pricing table"))
    #expect(excerpt.hasSuffix("…"))
    #expect(excerpt.count <= noteSourceExcerptChars + 1)
}

@Test func summaryBulletsSplitSentencesAndDropMarkers() {
    #expect(noteSummaryBullets(summary: "The beta opens on 14 November. Pricing stays.\n- Support gets a weekly sync.") == [
        "The beta opens on 14 November.", "Pricing stays.", "Support gets a weekly sync.",
    ])
    #expect(noteSummaryBullets(summary: "  ") == [])
}

@Test func quickActionsReuseBuiltInRecipes() {
    let actions: [MeetingQuickAction] = meetingQuickActions(recipes: builtInRecipes())
    #expect(actions.map(\.id) == ["takip-epostasi", "aksiyonlar", "kisaca", "notu-uzat"])
    let email: Recipe? = builtInRecipes().first { $0.id == "takip-epostasi" }
    #expect(actions.first?.kind == .ask(prompt: email?.prompt ?? "", recipeTitle: email?.title ?? ""))
    #expect(meetingQuickActions(recipes: []).map(\.id) == ["kisaca", "notu-uzat"])
}

@Test func transcriptSearchIgnoresCaseAccentsAndReadsTranslations() {
    #expect(transcriptMatches(paragraphs: weekly, query: "PRICING").map(\.id) == ["p0", "p6", "p7"])
    #expect(transcriptMatches(paragraphs: weekly, query: "  ").count == weekly.count)
    let translated: [TranscriptParagraph] = [paragraph("t", 1, 0, 5, "Hinnasto lähetetään.", translated: "Fiyat tablosu gönderilecek.")]
    #expect(transcriptMatches(paragraphs: translated, query: "gonderilecek").map(\.id) == ["t"])
    #expect(transcriptMatches(paragraphs: translated, query: "lahetetaan").map(\.id) == ["t"])
}
