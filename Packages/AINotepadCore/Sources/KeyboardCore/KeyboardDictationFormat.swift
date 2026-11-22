import Foundation

/// A finished dictation as the field receives it, under the user's `KeyboardDictationOptions`: fillers and stutters
/// dropped, spoken marks ("comma", "virgül", "new line") turned into the marks, "first … second …" turned into a list,
/// the final period dropped, then lowercase. `languageCode` is the dictation language ("tr", "en-US"); English phrases
/// are understood in every language. Languages without spaces between words (Japanese, Chinese…) only get the period
/// and lowercase rules. Pure function.
public func keyboardFormatDictation(text: String, languageCode: String, options: KeyboardDictationOptions) -> String {
    let language: String = keyboardLocaleLanguage(identifier: languageCode)
    var pieces: [DictationPiece] = dictationPieces(text: text)
    if options.cleanUp {
        pieces = dictationCleanedUp(pieces: pieces, language: language)
    }
    if options.spokenPunctuation {
        pieces = dictationSpokenMarksApplied(pieces: pieces, language: language)
    }
    if options.formatLists {
        pieces = dictationListFormatted(pieces: pieces, language: language)
    }
    var result: String = dictationJoined(pieces: pieces)
    if !options.endWithPeriod {
        result = dictationWithoutFinalPeriod(text: result)
    }
    if options.lowercase {
        result = result.lowercased(with: Locale(identifier: language))
    }
    return result
}

/// A word with the punctuation stuck to it ("Hello,"), or a line break ("\n", "\n\n").
enum DictationPiece: Hashable {
    case word(String)
    case lineBreak(String)
}

/// The text split at spaces; line breaks are their own pieces. Pure function.
func dictationPieces(text: String) -> [DictationPiece] {
    var pieces: [DictationPiece] = []
    var current: String = ""
    for character in text {
        if character.isNewline {
            if !current.isEmpty {
                pieces.append(.word(current))
                current = ""
            }
            if case .lineBreak(let breaks) = pieces.last {
                pieces[pieces.count - 1] = .lineBreak(breaks + "\n")
            } else {
                pieces.append(.lineBreak("\n"))
            }
        } else if character.isWhitespace {
            if !current.isEmpty {
                pieces.append(.word(current))
                current = ""
            }
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty {
        pieces.append(.word(current))
    }
    return pieces
}

/// The pieces back as text: one space between words, none around line breaks, trimmed. Pure function.
func dictationJoined(pieces: [DictationPiece]) -> String {
    var result: String = ""
    var afterBreak: Bool = true
    for piece in pieces {
        switch piece {
        case .word(let word):
            result += (afterBreak ? "" : " ") + word
            afterBreak = false
        case .lineBreak(let breaks):
            result += breaks
            afterBreak = true
        }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Drops one final "." (or "。"); "?", "!" and an ellipsis stay. Pure function.
func dictationWithoutFinalPeriod(text: String) -> String {
    let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasSuffix(".") || trimmed.hasSuffix("。"), !trimmed.hasSuffix("..") else {
        return trimmed
    }
    return String(trimmed.dropLast())
}

// MARK: - Words

/// Punctuation that can stick to either end of a spoken word.
private let dictationEdgePunctuation: Set<Character> = [
    ".", ",", ";", ":", "!", "?", "…", "\"", "“", "”", "„", "«", "»", "'", "‘", "’", "(", ")", "¿", "¡",
]
/// Marks that end or split a clause (the ones a transcriber guesses).
private let dictationClausePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "…"]
private let dictationSentenceEnds: Set<Character> = [".", "!", "?", "…"]

/// A word's leading punctuation, its letters and its trailing punctuation ("(Hello)," → "(", "Hello", "),").
struct DictationWord: Hashable {
    let lead: String
    let core: String
    let trail: String

    var text: String {
        lead + core + trail
    }
}

func dictationWord(_ word: String) -> DictationWord {
    let lead: Substring = word.prefix { dictationEdgePunctuation.contains($0) }
    guard lead.count < word.count else {
        return DictationWord(lead: word, core: "", trail: "")
    }
    let rest: Substring = word.dropFirst(lead.count)
    let trailCount: Int = rest.reversed().prefix { dictationEdgePunctuation.contains($0) }.count
    return DictationWord(lead: String(lead), core: String(rest.dropLast(trailCount)), trail: String(rest.suffix(trailCount)))
}

/// The word's letters in lowercase, for comparing with the phrase tables.
private func dictationKey(_ word: String, language: String) -> String {
    dictationWord(word).core.lowercased(with: Locale(identifier: language))
}

private enum DictationCase {
    case keep
    case upper
    case lower
}

/// The word with its first letter changed. `lower` leaves "I" and words in capitals ("NASA") alone.
private func dictationCased(_ word: String, as letterCase: DictationCase, language: String) -> String {
    let parts: DictationWord = dictationWord(word)
    guard let first = parts.core.first else {
        return word
    }
    let changed: String
    switch letterCase {
    case .keep:
        return word
    case .upper:
        changed = String(first).uppercased(with: Locale(identifier: language))
    case .lower:
        let rest: Substring = parts.core.dropFirst()
        guard parts.core != "I", !rest.isEmpty, rest == rest.lowercased() else {
            return word
        }
        changed = String(first).lowercased(with: Locale(identifier: language))
    }
    return parts.lead + changed + parts.core.dropFirst() + parts.trail
}

private func dictationLastWordIndex(_ pieces: [DictationPiece]) -> Int? {
    guard let last = pieces.indices.last, case .word = pieces[last] else {
        return nil
    }
    return last
}

/// Whether a list marker at `index` starts a clause: the start of the text or of a line, or after a mark.
private func dictationStartsClause(_ pieces: [DictationPiece], at index: Int) -> Bool {
    guard index > 0 else {
        return true
    }
    switch pieces[index - 1] {
    case .lineBreak:
        return true
    case .word(let previous):
        return dictationWord(previous).trail.contains { dictationClausePunctuation.contains($0) }
    }
}

// MARK: - Clean up

private let dictationFillers: [String: Set<String>] = [
    "en": ["um", "umm", "uh", "uhh", "uhm", "erm", "hmm", "mm", "mmm"],
    "tr": ["ıı", "ııı", "ıııı", "ım", "ımm", "ıhm", "ee", "eee", "eeee", "hmm"],
    "de": ["äh", "ähm", "äähm", "öhm", "hm"],
    "fr": ["euh", "heu", "hum"],
    "es": ["ehm", "em", "mmm"],
    "it": ["ehm", "uhm"],
    "pt": ["hã", "ahn", "ehm"],
    "nl": ["eh", "ehm", "uh", "uhm"],
]

/// The words whose doubling is only ever a stutter ("I I", "the the"), per language: pronouns, articles and "and" that
/// grammar never repeats. Words a sentence can repeat on purpose stay out ("that that", "had had", German and Dutch
/// "die die", "der der"), as do the Turkish words doubled on purpose ("yavaş yavaş", "tek tek", "bir bir").
private let dictationStutterWords: [String: Set<String>] = [
    "en": ["i", "the", "a", "an", "and", "we", "you", "it", "to", "my"],
    "tr": ["ben", "sen", "biz", "siz", "ve", "ama"],
    "de": ["ich", "wir", "und", "ein", "eine"],
    "fr": ["je", "le", "les", "un", "une", "et"],
    "es": ["yo", "el", "los", "un", "una", "y"],
    "it": ["io", "il", "lo", "un", "una", "e"],
    "pt": ["eu", "o", "os", "uma", "e"],
    "nl": ["ik", "het", "een", "en"],
]

/// Drops the language's own fillers (with the commas around them) and a stuttered pronoun or article. Only the
/// dictation language's lists apply: English "um" is a German and Portuguese word. Pure function.
func dictationCleanedUp(pieces: [DictationPiece], language: String) -> [DictationPiece] {
    let fillers: Set<String> = dictationFillers[language] ?? []
    let stutterWords: Set<String> = dictationStutterWords[language] ?? []
    var result: [DictationPiece] = []
    var capitalizeNext: Bool = false
    for (index, piece) in pieces.enumerated() {
        guard case .word(let word) = piece else {
            result.append(piece)
            continue
        }
        let parts: DictationWord = dictationWord(word)
        let key: String = parts.core.lowercased(with: Locale(identifier: language))
        if fillers.contains(key) {
            let ends: String = String(parts.trail.filter { dictationSentenceEnds.contains($0) })
            let startsSentence: Bool = dictationLastWordIndex(result).map { (last: Int) -> Bool in
                guard case .word(let previous) = result[last] else {
                    return true
                }
                return dictationWord(previous).trail.contains { dictationSentenceEnds.contains($0) }
            } ?? true
            if let last = dictationLastWordIndex(result), case .word(let previous) = result[last] {
                let previousParts: DictationWord = dictationWord(previous)
                let keptTrail: String = previousParts.trail
                if !ends.isEmpty, !previousParts.trail.contains(where: { dictationSentenceEnds.contains($0) }) {
                    let withoutComma: String = keptTrail.hasSuffix(",") ? String(keptTrail.dropLast()) : keptTrail
                    result[last] = .word(previousParts.lead + previousParts.core + withoutComma + ends)
                } else if parts.trail.contains(","), keptTrail.hasSuffix(",") {
                    result[last] = .word(previousParts.lead + previousParts.core + keptTrail.dropLast())
                }
            }
            if startsSentence {
                capitalizeNext = true
            }
            continue
        }
        if stutterWords.contains(key), index + 1 < pieces.count, case .word(let next) = pieces[index + 1] {
            let nextParts: DictationWord = dictationWord(next)
            let isStutter: Bool = parts.trail.isEmpty && nextParts.lead.isEmpty && parts.lead.isEmpty
                && nextParts.core.lowercased(with: Locale(identifier: language)) == key
            if isStutter {
                if let first = parts.core.first, first.isUppercase {
                    capitalizeNext = true
                }
                continue
            }
        }
        result.append(.word(capitalizeNext ? dictationCased(word, as: .upper, language: language) : word))
        capitalizeNext = false
    }
    return result
}

// MARK: - Spoken punctuation

private enum DictationSpokenOutput: Hashable {
    case mark(String)
    case lineBreak(String)
}

private struct DictationSpokenMark: Hashable {
    let words: [String]
    let output: DictationSpokenOutput
    /// A common word too ("period", "nokta"): a mark only as the dictation's last words.
    let onlyAtEnd: Bool
}

private func spoken(_ phrase: String, _ output: DictationSpokenOutput, onlyAtEnd: Bool) -> DictationSpokenMark {
    DictationSpokenMark(words: phrase.split(separator: " ").map(String.init), output: output, onlyAtEnd: onlyAtEnd)
}

private func spokenMarks(
    comma: [String], period: [String], periodAtEnd: [String], question: [String], exclamation: [String], colon: [String],
    newLine: [String], newParagraph: [String]
) -> [DictationSpokenMark] {
    comma.map { spoken($0, .mark(","), onlyAtEnd: false) }
        + period.map { spoken($0, .mark("."), onlyAtEnd: false) }
        + periodAtEnd.map { spoken($0, .mark("."), onlyAtEnd: true) }
        + question.map { spoken($0, .mark("?"), onlyAtEnd: false) }
        + exclamation.map { spoken($0, .mark("!"), onlyAtEnd: false) }
        + colon.map { spoken($0, .mark(":"), onlyAtEnd: false) }
        + newLine.map { spoken($0, .lineBreak("\n"), onlyAtEnd: false) }
        + newParagraph.map { spoken($0, .lineBreak("\n\n"), onlyAtEnd: false) }
}

private let dictationSpokenMarkTable: [String: [DictationSpokenMark]] = [
    "en": spokenMarks(
        comma: ["comma"], period: ["full stop"], periodAtEnd: ["period"], question: ["question mark"],
        exclamation: ["exclamation mark", "exclamation point"], colon: ["colon"], newLine: ["new line"], newParagraph: ["new paragraph"]
    ),
    "tr": spokenMarks(
        comma: ["virgül"], period: [], periodAtEnd: ["nokta"], question: ["soru işareti"], exclamation: ["ünlem işareti", "ünlem"],
        colon: ["iki nokta üst üste"], newLine: ["yeni satır"], newParagraph: ["yeni paragraf"]
    ),
    "de": spokenMarks(
        comma: ["komma"], period: [], periodAtEnd: ["punkt"], question: ["fragezeichen"], exclamation: ["ausrufezeichen"],
        colon: ["doppelpunkt"], newLine: ["neue zeile"], newParagraph: ["neuer absatz"]
    ),
    "fr": spokenMarks(
        comma: ["virgule"], period: ["point final"], periodAtEnd: ["point"], question: ["point d'interrogation", "point d’interrogation"],
        exclamation: ["point d'exclamation", "point d’exclamation"], colon: ["deux-points", "deux points"],
        newLine: ["à la ligne", "nouvelle ligne"], newParagraph: ["nouveau paragraphe"]
    ),
    "es": spokenMarks(
        comma: ["coma"], period: ["punto final"], periodAtEnd: ["punto"], question: ["signo de interrogación"],
        exclamation: ["signo de exclamación"], colon: ["dos puntos"], newLine: ["nueva línea"], newParagraph: ["nuevo párrafo"]
    ),
    "it": spokenMarks(
        comma: ["virgola"], period: [], periodAtEnd: ["punto"], question: ["punto interrogativo"], exclamation: ["punto esclamativo"],
        colon: ["due punti"], newLine: ["nuova riga", "a capo"], newParagraph: ["nuovo paragrafo"]
    ),
    "pt": spokenMarks(
        comma: ["vírgula"], period: ["ponto final"], periodAtEnd: ["ponto"], question: ["ponto de interrogação"],
        exclamation: ["ponto de exclamação"], colon: ["dois pontos"], newLine: ["nova linha"], newParagraph: ["novo parágrafo"]
    ),
    "nl": spokenMarks(
        comma: ["komma"], period: [], periodAtEnd: ["punt"], question: ["vraagteken"], exclamation: ["uitroepteken"],
        colon: ["dubbele punt"], newLine: ["nieuwe regel"], newParagraph: ["nieuwe alinea"]
    ),
]

/// The marks understood in a language, longest phrase first ("point d'interrogation" before "point").
private func dictationSpokenMarks(language: String) -> [DictationSpokenMark] {
    let own: [DictationSpokenMark] = dictationSpokenMarkTable[language] ?? []
    let english: [DictationSpokenMark] = language == "en" ? [] : (dictationSpokenMarkTable["en"] ?? [])
    return (own + english).sorted { $0.words.count > $1.words.count }
}

/// The spoken mark that starts at `index`, if any: its words match exactly, nothing but the last one carries trailing
/// punctuation, and an end-only mark ends the dictation.
private func dictationSpokenMatch(
    pieces: [DictationPiece], at index: Int, marks: [DictationSpokenMark], language: String
) -> DictationSpokenMark? {
    marks.first { (mark: DictationSpokenMark) -> Bool in
        let end: Int = index + mark.words.count
        guard end <= pieces.count else {
            return false
        }
        for (offset, expected) in mark.words.enumerated() {
            guard case .word(let word) = pieces[index + offset] else {
                return false
            }
            let parts: DictationWord = dictationWord(word)
            guard parts.core.lowercased(with: Locale(identifier: language)) == expected,
                  offset == 0 || parts.lead.isEmpty,
                  offset == mark.words.count - 1 || parts.trail.isEmpty
            else {
                return false
            }
        }
        guard mark.onlyAtEnd else {
            return true
        }
        return pieces[end...].allSatisfy { (piece: DictationPiece) -> Bool in
            if case .lineBreak = piece {
                return true
            }
            return false
        }
    }
}

/// Spoken marks become the marks: the punctuation a transcriber guessed around the phrase goes, the mark sticks to the
/// word before, and the next word is capitalized after ". ? !" (or lowercased after ", :" that replaced a guessed
/// sentence end). A mark with no word before it is dropped. Pure function.
func dictationSpokenMarksApplied(pieces: [DictationPiece], language: String) -> [DictationPiece] {
    let marks: [DictationSpokenMark] = dictationSpokenMarks(language: language)
    var result: [DictationPiece] = []
    var pending: DictationCase = .keep
    var index: Int = 0
    while index < pieces.count {
        guard let mark = dictationSpokenMatch(pieces: pieces, at: index, marks: marks, language: language) else {
            switch pieces[index] {
            case .word(let word):
                result.append(.word(dictationCased(word, as: pending, language: language)))
                pending = .keep
            case .lineBreak:
                result.append(pieces[index])
            }
            index += 1
            continue
        }
        index += mark.words.count
        switch mark.output {
        case .mark(let symbol):
            guard let last = dictationLastWordIndex(result), case .word(let previous) = result[last] else {
                continue
            }
            let parts: DictationWord = dictationWord(previous)
            let removed: String = String(parts.trail.filter { dictationClausePunctuation.contains($0) })
            let kept: String = String(parts.trail.filter { !dictationClausePunctuation.contains($0) })
            result[last] = .word(parts.lead + parts.core + kept + symbol)
            if [".", "?", "!"].contains(symbol) {
                pending = .upper
            } else if removed.contains(where: { dictationSentenceEnds.contains($0) }) {
                pending = .lower
            } else {
                pending = .keep
            }
        case .lineBreak(let breaks):
            result.append(.lineBreak(breaks))
            pending = .upper
        }
    }
    return result
}

// MARK: - Lists

private let dictationOrdinals: [String: [[String]]] = [
    "en": [
        ["first", "firstly"], ["second", "secondly"], ["third", "thirdly"], ["fourth", "fourthly"], ["fifth", "fifthly"],
        ["sixth"], ["seventh"], ["eighth"], ["ninth"], ["tenth"],
    ],
    "tr": [
        ["birinci", "birincisi"], ["ikinci", "ikincisi"], ["üçüncü", "üçüncüsü"], ["dördüncü", "dördüncüsü"], ["beşinci", "beşincisi"],
        ["altıncı", "altıncısı"], ["yedinci", "yedincisi"], ["sekizinci", "sekizincisi"], ["dokuzuncu", "dokuzuncusu"], ["onuncu", "onuncusu"],
    ],
    "de": [["erstens"], ["zweitens"], ["drittens"], ["viertens"], ["fünftens"], ["sechstens"], ["siebtens"], ["achtens"], ["neuntens"], ["zehntens"]],
    "fr": [
        ["premièrement"], ["deuxièmement"], ["troisièmement"], ["quatrièmement"], ["cinquièmement"], ["sixièmement"],
        ["septièmement"], ["huitièmement"], ["neuvièmement"], ["dixièmement"],
    ],
    "es": [["primero"], ["segundo"], ["tercero"], ["cuarto"], ["quinto"], ["sexto"], ["séptimo"], ["octavo"], ["noveno"], ["décimo"]],
    "it": [["primo"], ["secondo"], ["terzo"], ["quarto"], ["quinto"], ["sesto"], ["settimo"], ["ottavo"], ["nono"], ["decimo"]],
    "pt": [["primeiro"], ["segundo"], ["terceiro"], ["quarto"], ["quinto"], ["sexto"], ["sétimo"], ["oitavo"], ["nono"], ["décimo"]],
]

/// Words that start a bullet ("bullet point" before "bullet").
private let dictationBullets: [String: [[String]]] = [
    "en": [["bullet", "point"], ["bullet"]],
    "tr": [["madde"]],
]
/// Bullet words that mean nothing else, so they start an item anywhere; the others ("madde" is also "substance",
/// "clause") only at the start of a clause.
private let dictationBulletWordsAnywhere: Set<String> = ["bullet"]

/// Where a list item starts: the marker's first piece and how many pieces the marker spans.
private struct DictationListMarker: Hashable {
    let index: Int
    let length: Int
}

/// "first … second …" in order, each at the start of a clause (so "the first one beat the second" stays prose).
private func dictationOrdinalMarkers(pieces: [DictationPiece], language: String) -> [DictationListMarker] {
    let ordinals: [[String]] = dictationOrdinals[language] ?? dictationOrdinals["en"] ?? []
    var markers: [DictationListMarker] = []
    for index in pieces.indices where markers.count < ordinals.count {
        guard case .word(let word) = pieces[index], dictationStartsClause(pieces, at: index) else {
            continue
        }
        if ordinals[markers.count].contains(dictationKey(word, language: language)) {
            markers.append(DictationListMarker(index: index, length: 1))
        }
    }
    return markers
}

private func dictationBulletMarkers(pieces: [DictationPiece], language: String) -> [DictationListMarker] {
    let phrases: [[String]] = (dictationBullets[language] ?? []) + (language == "en" ? [] : (dictationBullets["en"] ?? []))
    var markers: [DictationListMarker] = []
    var index: Int = 0
    while index < pieces.count {
        let match: [String]? = phrases.first { (phrase: [String]) -> Bool in
            guard index + phrase.count <= pieces.count else {
                return false
            }
            return phrase.enumerated().allSatisfy { (offset: Int, expected: String) -> Bool in
                guard case .word(let word) = pieces[index + offset] else {
                    return false
                }
                return dictationKey(word, language: language) == expected
            }
        }
        if let match, match.first.map(dictationBulletWordsAnywhere.contains) == true || dictationStartsClause(pieces, at: index) {
            markers.append(DictationListMarker(index: index, length: match.count))
            index += match.count
        } else {
            index += 1
        }
    }
    return markers
}

/// Two or more spoken ordinals ("first … second …") make a numbered list, else two or more "bullet"s a bulleted one:
/// what came before stays as the lead-in (ending in ":"), each item goes on its own line, capitalized, without the
/// trailing comma or period. Pure function.
func dictationListFormatted(pieces: [DictationPiece], language: String) -> [DictationPiece] {
    let ordinals: [DictationListMarker] = dictationOrdinalMarkers(pieces: pieces, language: language)
    let numbered: Bool = ordinals.count >= 2
    let markers: [DictationListMarker] = numbered ? ordinals : dictationBulletMarkers(pieces: pieces, language: language)
    guard markers.count >= 2, let first = markers.first else {
        return pieces
    }
    var result: [DictationPiece] = Array(pieces[..<first.index])
    if let last = dictationLastWordIndex(result), case .word(let previous) = result[last] {
        let parts: DictationWord = dictationWord(previous)
        if parts.trail.isEmpty || parts.trail == "," {
            result[last] = .word(parts.lead + parts.core + ":")
        }
    }
    var number: Int = 0
    for (position, marker) in markers.enumerated() {
        let end: Int = position + 1 < markers.count ? markers[position + 1].index : pieces.count
        var item: [String] = pieces[(marker.index + marker.length)..<end].compactMap { (piece: DictationPiece) -> String? in
            if case .word(let word) = piece {
                return word
            }
            return nil
        }
        // A marker said with its own mark ("First," "madde:") leaves a bare mark word behind; drop it.
        item = item.filter { !dictationWord($0).core.isEmpty }
        guard let firstWord = item.first, let lastWord = item.last else {
            continue
        }
        number += 1
        item[0] = dictationCased(firstWord, as: .upper, language: language)
        let lastParts: DictationWord = dictationWord(item.count == 1 ? item[0] : lastWord)
        let trail: String = String(lastParts.trail.reversed().drop { [",", ";", "."].contains($0) }.reversed())
        item[item.count - 1] = lastParts.lead + lastParts.core + trail
        if !result.isEmpty {
            result.append(.lineBreak("\n"))
        }
        result.append(.word(numbered ? "\(number)." : "-"))
        result += item.map { DictationPiece.word($0) }
    }
    return result
}
