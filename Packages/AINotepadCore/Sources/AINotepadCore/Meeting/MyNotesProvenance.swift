import Foundation

/// Where a line of the finished note came from, for showing the user's own notes apart from what the model added
/// (Granola-style hybrid notes).
public enum NoteLineOrigin: Sendable, Equatable {
    /// The note carries no marks (no own notes, nothing marked, or an older note): show every line the same.
    case unmarked
    /// The line came from the user's own notes ("Notlarım").
    case myNotes
    /// The note has marks but not on this line: the model added it from the recording.
    case added
}

/// Name of the note schema field in which the model quotes the lines that came from the user's own notes.
let myNotesQuotesField: String = "benimNotlarimdan"

/// System prompt rule for `myNotesQuotesField`; only in requests that carry the user's notes and ask for the field.
/// Pure function.
func myNotesQuotesRule() -> String {
    """
    \(myNotesQuotesField): notun kullanıcının kendi notlarından (<benim_notlarim>) gelen satırları: kendi notundaki bir
      maddeyi karşılayan özet cümleleri, kararlar ve açık konular. Her birini notta yazdığın gibi aynen
      kopyala (zamanı ve madde işareti olmadan). Yalnızca transkriptten eklediğin satırları yazma; kendi notlarıyla ilgili
      satır yoksa boş liste.
    """
}

/// The note's lines that can come from the user's own notes, in note order: summary sentences (`noteSummaryBullets`) and
/// decision and open-question texts without their anchor. Tasks are a checklist of their own and stay unmarked. Pure
/// function.
public func noteProvenanceLines(note: MeetingNote) -> [String] {
    noteSummaryBullets(summary: note.summary)
        + note.decisions.map { anchoredLine(text: $0).text }
        + (note.openQuestions ?? []).map { anchoredLine(text: $0).text }
}

/// Shortest quote (folded characters) that may match as part of a line; shorter quotes must match a whole line, so a
/// quoted word such as "Bütçe" cannot mark every line that mentions it.
let myNotesContainedMinChars: Int = 16

/// Text compared when matching quotes to lines: folded (`searchFolded`), anchor and bullet stripped, whitespace
/// collapsed, trailing punctuation dropped. Pure function.
func provenanceKey(text: String) -> String {
    let body: String = anchoredLine(text: text.trimmingCharacters(in: .whitespacesAndNewlines)).text
        .replacing(/^[-•*]\s+/, with: "")
    let collapsed: String = searchFolded(body)
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
    return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ".!?…;:,").union(.whitespaces))
}

/// Whether the model's `quote` names `line`. The quote is split into sentences first (the model may quote two summary
/// sentences at once); a sentence names the line when it is the same text, or a part of it of at least
/// `myNotesContainedMinChars` characters. A line is never marked for merely sitting inside a longer quote: a quoted
/// paragraph must not mark the lines the model added around the user's own. Pure function.
func quoteMatches(quote: String, line: String) -> Bool {
    let lineKey: String = provenanceKey(text: line)
    guard !lineKey.isEmpty else {
        return false
    }
    return sourceSentences(text: quote).contains { (sentence: String) -> Bool in
        let quoteKey: String = provenanceKey(text: sentence)
        return !quoteKey.isEmpty && (quoteKey == lineKey || (quoteKey.count >= myNotesContainedMinChars && lineKey.contains(quoteKey)))
    }
}

/// The note with the lines the model quoted as coming from the user's own notes (`myNotesLines`). Model output is
/// checked: only quotes that match a real line of the note mark it, and the note's own text is stored, never the quote.
/// No quotes, or none that match, leaves the note without marks. Pure function.
public func withMyNotesQuotes(note: MeetingNote, quotes: [String]) -> MeetingNote {
    let marked: [String] = noteProvenanceLines(note: note).filter { (line: String) -> Bool in
        quotes.contains { quoteMatches(quote: $0, line: line) }
    }
    return note.with(myNotesLines: uniqued(lines: marked))
}

/// Where `line` (as shown: a summary sentence, or a decision or open question without its anchor) came from. Pure function.
public func noteLineOrigin(note: MeetingNote, line: String) -> NoteLineOrigin {
    guard let lines = note.myNotesLines, !lines.isEmpty else {
        return .unmarked
    }
    return lines.contains(line) ? .myNotes : .added
}

/// The marks of `old` that still name a line of `new`: a note edit rewrites the note without marks, unchanged lines
/// keep theirs. Pure function.
public func withCarriedMyNotesLines(old: MeetingNote, new: MeetingNote) -> MeetingNote {
    let lines: Set<String> = Set(noteProvenanceLines(note: new))
    return new.with(myNotesLines: (old.myNotesLines ?? []).filter { lines.contains($0) })
}

/// The marks of `original` on its translation `translated`, by position: decisions and open questions keep their
/// order and count in a translation (`parseSharedNote`); summary sentences only when both summaries split into as many.
/// Pure function.
public func translatedMyNotesLines(original: MeetingNote, translated: MeetingNote) -> [String] {
    guard let marked = original.myNotesLines, !marked.isEmpty else {
        return []
    }
    let isMarked: (String) -> Bool = { (line: String) -> Bool in marked.contains(line) }
    let pairs: ([String], [String]) -> [String] = { (from: [String], to: [String]) -> [String] in
        guard from.count == to.count else {
            return []
        }
        return zip(from, to).filter { isMarked($0.0) }.map(\.1)
    }
    let summary: [String] = pairs(noteSummaryBullets(summary: original.summary), noteSummaryBullets(summary: translated.summary))
    let decisions: [String] = pairs(original.decisions.map { anchoredLine(text: $0).text }, translated.decisions.map { anchoredLine(text: $0).text })
    let questions: [String] = pairs(
        (original.openQuestions ?? []).map { anchoredLine(text: $0).text }, (translated.openQuestions ?? []).map { anchoredLine(text: $0).text }
    )
    return uniqued(lines: summary + decisions + questions)
}

/// Lines in their first order without repeats. Pure function.
private func uniqued(lines: [String]) -> [String] {
    lines.reduce(into: [String]()) { (result: inout [String], line: String) -> Void in
        if !result.contains(line) {
            result.append(line)
        }
    }
}
