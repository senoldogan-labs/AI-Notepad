import Foundation

/// The dictation with the user's vocabulary spelled as listed. Three rules, in this order for each stretch of words:
///
/// 1. A heard word, or up to four heard words joined, that equals a term ignoring case, diacritics and spaces is
///    written as the term: "acme" becomes "ACME", "senol dogan" becomes "Şenol Doğan", "open ai" becomes "OpenAI".
///    A single heard word that differs from its term only in case stays as heard when it is an ordinary dictionary
///    word ("it" with the term "IT", "may" with "May").
///    Only words set apart by single spaces join; punctuation between them ends the stretch. Punctuation stuck to the
///    outer words ("(acme)," ) stays where it is.
/// 2. A single heard word that is one letter away (insertion, deletion or substitution) from a one-word term, with the
///    same first letter and at least four letters on both sides, becomes the term unless `isCommonWord` says the
///    lowercase heard word is an ordinary dictionary word ("Stacy" becomes "Stacey" when "Stacey" is listed; "state"
///    never becomes "Stacey"). When two terms qualify nothing changes.
/// 3. Everything else is untouched, including line breaks and spacing. Scripts written without spaces (Japanese,
///    Chinese) have no word boundaries to match on and are left as they are.
///
/// `isCommonWord` is injected so the function stays pure: true or false for the lowercase word, nil when the language
/// has no dictionary (rule 1 then applies, rule 2 does not). Pure function.
public func keyboardVocabularyApplied(text: String, vocabulary: [String], isCommonWord: (String) -> Bool?) -> String {
    let terms: [String] = vocabulary.map { $0.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }.filter { !$0.isEmpty }
    guard !terms.isEmpty else {
        return text
    }
    let exact: [String: String] = Dictionary(
        terms.map { (vocabularyKey($0.replacingOccurrences(of: " ", with: "")), $0) }, uniquingKeysWith: { first, _ in first }
    )
    let singleWordTerms: [String] = terms.filter { !$0.contains(" ") }
    let tokens: [VocabularyToken] = vocabularyTokens(text: text)
    var result: String = ""
    var index: Int = 0
    while index < tokens.count {
        let token: VocabularyToken = tokens[index]
        guard !token.core.isEmpty else {
            result += token.text + token.separator
            index += 1
            continue
        }
        if let (term, count) = vocabularyJoinedMatch(tokens: tokens, start: index, exact: exact),
           !(count == 1 && token.core.lowercased() == term.lowercased() && isCommonWord(token.core.lowercased()) == true) {
            let last: VocabularyToken = tokens[index + count - 1]
            result += token.lead + term + last.trail + last.separator
            index += count
            continue
        }
        let spelling: String = vocabularyNearMiss(core: token.core, terms: singleWordTerms, isCommonWord: isCommonWord) ?? token.core
        result += token.lead + spelling + token.trail + token.separator
        index += 1
    }
    return result
}

/// A word split into its leading punctuation, letters and trailing punctuation, with the whitespace after it.
private struct VocabularyToken {
    let lead: String
    let core: String
    let trail: String
    let separator: String

    var text: String {
        lead + core + trail
    }
}

private func vocabularyTokens(text: String) -> [VocabularyToken] {
    var tokens: [VocabularyToken] = []
    var word: String = ""
    var separator: String = ""
    func flush() {
        guard !word.isEmpty || !separator.isEmpty else {
            return
        }
        let parts: DictationWord = dictationWord(word)
        tokens.append(VocabularyToken(lead: parts.lead, core: parts.core, trail: parts.trail, separator: separator))
        word = ""
        separator = ""
    }
    for character in text {
        if character.isWhitespace {
            separator.append(character)
        } else {
            if !separator.isEmpty {
                flush()
            }
            word.append(character)
        }
    }
    flush()
    return tokens
}

/// The term for the longest run (4 words down to 1) of words at `start` whose letters joined equal a term's, with the
/// run's length. Inner words carry no punctuation and are separated by one plain space.
private func vocabularyJoinedMatch(tokens: [VocabularyToken], start: Int, exact: [String: String]) -> (String, Int)? {
    for count in stride(from: min(4, tokens.count - start), through: 1, by: -1) {
        let run: ArraySlice<VocabularyToken> = tokens[start ..< start + count]
        let innerIsPlain: Bool = run.enumerated().allSatisfy { offset, token in
            !token.core.isEmpty && (offset == 0 || token.lead.isEmpty) && (offset == count - 1 || (token.trail.isEmpty && token.separator == " "))
        }
        guard innerIsPlain else {
            continue
        }
        if let term = exact[vocabularyKey(run.map(\.core).joined())] {
            return (term, count)
        }
    }
    return nil
}

/// The one-word term a heard word is a near miss of, or nil (see `keyboardVocabularyApplied`, rule 2).
private func vocabularyNearMiss(core: String, terms: [String], isCommonWord: (String) -> Bool?) -> String? {
    let heard: String = vocabularyKey(core)
    guard heard.count >= 4, core.allSatisfy({ $0.isLetter }), isCommonWord(core.lowercased()) == false else {
        return nil
    }
    let candidates: [String] = terms.filter { term in
        let key: String = vocabularyKey(term)
        return key.count >= 4 && key.first == heard.first && key != heard && abs(key.count - heard.count) <= 1
            && vocabularyEditDistanceIsOne(Array(key), Array(heard))
    }
    return candidates.count == 1 ? candidates[0] : nil
}

private func vocabularyKey(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
}

/// Whether the two words differ by exactly one insertion, deletion or substitution.
private func vocabularyEditDistanceIsOne(_ a: [Character], _ b: [Character]) -> Bool {
    guard a != b, abs(a.count - b.count) <= 1 else {
        return false
    }
    var i: Int = 0
    while i < a.count, i < b.count, a[i] == b[i] {
        i += 1
    }
    if a.count == b.count {
        return a[(i + 1)...] == b[(i + 1)...]
    }
    let (longer, shorter): ([Character], [Character]) = a.count > b.count ? (a, b) : (b, a)
    return longer[(i + 1)...] == shorter[i...]
}
