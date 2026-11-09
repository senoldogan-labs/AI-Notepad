import CoreGraphics
import Foundation
import Testing
@testable import KeyboardCore
#if canImport(AppKit)
import AppKit
#endif

/// Tekrarlanabilir rastgele sayılar (SplitMix64): sentetik izler her çalıştırmada aynı.
struct SwipeNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z: UInt64 = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Ortalaması 0, sapması `sigma` olan normal dağılım (Box–Muller).
    mutating func gaussian(sigma: Double) -> Double {
        let u: Double = max(next(), 1e-12)
        let v: Double = next()
        return sigma * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// Bir kelimenin insan elini taklit eden izi: harflerin tuş merkezleri sapmalı (`sigma` tuş genişliği cinsinden), aralar
/// doğrusal örnekli ve yumuşatılmış (köşeler kesilir), noktalara küçük titreme eklenir.
func syntheticSwipe(word: String, keyboard: SwipeKeyboard, language: KeyboardLanguage, noise: inout SwipeNoise, sigma: Double) -> [CGPoint] {
    var anchors: [CGPoint] = []
    var previous: Character?
    for letter in word.lowercased(with: language.casingLocale) where letter != previous {
        previous = letter
        guard let center = keyboard.centers[letter] else {
            continue
        }
        let kw: Double = Double(keyboard.keyWidth)
        anchors.append(CGPoint(x: center.x + CGFloat(noise.gaussian(sigma: sigma * kw)), y: center.y + CGFloat(noise.gaussian(sigma: sigma * kw * 0.8))))
    }
    guard anchors.count >= 2 else {
        return anchors + anchors
    }
    var raw: [CGPoint] = []
    for (a, b) in zip(anchors, anchors.dropFirst()) {
        let steps: Int = max(3, Int(distance(a, b) / 4))
        for step in 0 ..< steps {
            let t: CGFloat = CGFloat(step) / CGFloat(steps)
            raw.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }
    raw.append(anchors[anchors.count - 1])
    // Köşe kesme: kayan ortalama (uçlar yerinde kalır).
    let window: Int = 4
    var smooth: [CGPoint] = raw
    for index in raw.indices.dropFirst().dropLast() {
        let range: ClosedRange<Int> = max(0, index - window) ... min(raw.count - 1, index + window)
        let x: CGFloat = range.reduce(CGFloat(0)) { $0 + raw[$1].x } / CGFloat(range.count)
        let y: CGFloat = range.reduce(CGFloat(0)) { $0 + raw[$1].y } / CGFloat(range.count)
        smooth[index] = CGPoint(x: x, y: y)
    }
    return smooth.map { CGPoint(x: $0.x + CGFloat(noise.gaussian(sigma: 0.6)), y: $0.y + CGFloat(noise.gaussian(sigma: 0.6))) }
}

func benchmarkKeyboard(language: KeyboardLanguage) -> SwipeKeyboard {
    let rows: [[KeyboardKey]] = keyboardRows(
        language: language, page: .letters, options: KeyboardLayoutOptions(showsGlobe: false, showsMicrophone: true, showsLanguage: false, field: .text)
    )
    let metrics: KeyboardMetrics = KeyboardMetrics(
        width: 390, height: 216, horizontalGap: 6, verticalGap: 11, sideInset: 3, topInset: 2, bottomInset: 2, maximumKeysWidth: 640
    )
    return swipeKeyboard(frames: keyboardKeyFrames(rows: rows, metrics: metrics))
}

@Suite struct KeyboardSwipeTests {
    private let keyboard: SwipeKeyboard = benchmarkKeyboard(language: .english)

    @Test func tapsAreNotSwipes() {
        let start: CGPoint = keyboard.centers["g"] ?? .zero
        #expect(!swipeIsGesture(points: [start, CGPoint(x: start.x + 8, y: start.y)], keyWidth: keyboard.keyWidth))
        #expect(swipeIsGesture(points: [start, keyboard.centers["k"] ?? .zero], keyWidth: keyboard.keyWidth))
    }

    @Test func keySequenceFollowsThePath() {
        let points: [CGPoint] = ["h", "e", "l", "o"].compactMap { keyboard.centers[$0] }
        let sequence: [Character] = swipeKeySequence(points: points, keyboard: keyboard)
        #expect(sequence.first == "h")
        #expect(sequence.last == "o")
        #expect(sequence.contains("e"))
    }

    // Temiz bir iz doğru kelimeyi seçer; sıklık ancak şekil eşitken öne geçirir.
    @Test func decodesCleanPathsFromASmallLexicon() {
        let lexicon: [SwipeCandidate] = ["the", "they", "tie", "hello", "help", "hell", "meeting", "melting", "good", "food"].enumerated().map {
            SwipeCandidate(word: $0.element, rank: $0.offset)
        }
        for word in ["the", "hello", "help", "meeting", "good", "food"] {
            var noise: SwipeNoise = SwipeNoise(seed: 7)
            let path: [CGPoint] = syntheticSwipe(word: word, keyboard: keyboard, language: .english, noise: &noise, sigma: 0.08)
            let best: String? = swipeDecode(points: path, keyboard: keyboard, candidates: lexicon, language: .english, limit: 3).first?.word
            #expect(best == word, "swiped \(word), got \(best ?? "nothing")")
        }
    }

    @Test func turkishLettersHaveKeys() {
        let turkish: SwipeKeyboard = benchmarkKeyboard(language: .turkish)
        for letter: Character in ["ğ", "ü", "ş", "ı", "i", "ö", "ç"] {
            #expect(turkish.centers[letter] != nil)
        }
        var noise: SwipeNoise = SwipeNoise(seed: 3)
        let path: [CGPoint] = syntheticSwipe(word: "güzel", keyboard: turkish, language: .turkish, noise: &noise, sigma: 0.08)
        let lexicon: [SwipeCandidate] = [SwipeCandidate(word: "güzel", rank: 0), SwipeCandidate(word: "gözel", rank: 1), SwipeCandidate(word: "gazel", rank: 2)]
        #expect(swipeDecode(points: path, keyboard: turkish, candidates: lexicon, language: .turkish, limit: 1).first?.word == "güzel")
    }

    @Test func candidatesKeepTheBestRankAndPersonalWords() {
        let candidates: [SwipeCandidate] = swipeCandidates(
            prefixLists: [("th", ["the", "this"]), ("the", ["the", "they"])], personalWords: ["Gistsmith"]
        )
        #expect(candidates.first { $0.word == "the" }?.rank == 0)
        #expect(candidates.first { $0.word == "they" }?.rank == 9)
        #expect(candidates.contains { $0.word == "Gistsmith" })
    }

    @Test func prefixesStartAtTheFirstKey() {
        let points: [CGPoint] = ["t", "h", "e"].compactMap { keyboard.centers[$0] }
        let prefixes: [String] = swipeCandidatePrefixes(points: points, keyboard: keyboard, limit: 40)
        #expect(prefixes.contains("th"))
        #expect(prefixes.contains("the"))
        #expect(prefixes.allSatisfy { $0.count >= 2 && $0.count <= 3 })
    }
}

#if canImport(AppKit)
/// Kaydırarak yazma ölçümü: yaygın kelimeler için sentetik izler, adaylar sistemin sözlüğünden (macOS'ta
/// `NSSpellChecker`; cihazdaki `UITextChecker` ile aynı tür sıklık sıralı tamamlamalar). Sonuç yazdırılır; hedef
/// top-1 ≥ %80. `AINOTEPAD_SWIPE_BENCH=1` ile çalışır (dil sözlükleri CI makinesinde olmayabilir).
@Suite struct KeyboardSwipeBenchmark {
    static let words: [KeyboardLanguage: [String]] = [
        .english: [
            "the", "and", "you", "that", "have", "for", "not", "with", "this", "but", "from", "they", "she", "will", "one",
            "all", "would", "there", "their", "what", "out", "about", "who", "get", "which", "when", "make", "can", "like",
            "time", "just", "know", "take", "people", "into", "year", "your", "good", "some", "could", "them", "see", "other",
            "than", "then", "now", "look", "only", "come", "over", "think", "also", "back", "after", "use", "two", "how",
            "our", "work", "first", "well", "way", "even", "new", "want", "because", "any", "these", "give", "day", "most",
            "meeting", "thanks", "today", "tomorrow", "please", "call", "send", "next", "week",
        ],
        .turkish: [
            "bir", "için", "ile", "çok", "daha", "gibi", "kadar", "sonra", "ama", "olarak", "şey", "var", "yok", "ben", "sen",
            "biz", "nasıl", "neden", "şimdi", "bugün", "yarın", "toplantı", "teşekkürler", "merhaba", "tamam", "evet",
            "hayır", "güzel", "iyi", "zaman", "gün", "yıl", "her", "hem", "değil", "olan", "oldu", "geldi", "büyük", "küçük",
            "yeni", "son", "ilk", "önce", "göre", "kendi", "başka", "insan", "hafta", "saat", "proje", "rapor", "ekip",
            "lütfen", "görüşürüz", "akşam", "sabah", "bilgi", "konu", "durum",
        ],
        .german: [
            "und", "der", "die", "das", "ist", "nicht", "ein", "eine", "ich", "sie", "mit", "auf", "für", "von", "sich",
            "auch", "dem", "den", "wir", "aber", "wie", "wenn", "noch", "nach", "bei", "nur", "schon", "heute", "morgen",
            "danke", "bitte", "gut", "sehr", "mehr", "über", "kann", "werden", "haben", "sein", "alle", "jetzt", "hier",
            "immer", "zeit", "jahr", "termin", "projekt", "woche", "gerne", "später",
        ],
        .finnish: [
            "että", "joka", "mutta", "kuin", "myös", "niin", "vain", "sitten", "tämä", "mitä", "kun", "hän", "olla", "ovat",
            "oli", "tai", "jos", "nyt", "sekä", "kaikki", "hyvä", "kiitos", "tänään", "huomenna", "aika", "vuosi", "työ",
            "kokous", "projekti", "viikko", "asia", "paljon", "vielä", "aina", "missä", "miksi", "koska", "sinä", "minä",
            "moi",
        ],
    ]

    static func completions(prefix: String, language: KeyboardLanguage) -> [String] {
        let range: NSRange = NSRange(location: 0, length: (prefix as NSString).length)
        return NSSpellChecker.shared.completions(forPartialWordRange: range, in: prefix, language: language.rawValue, inSpellDocumentWithTag: 0) ?? []
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["AINOTEPAD_SWIPE_BENCH"] == "1"))
    func benchmark() {
        var report: [String] = []
        for language: KeyboardLanguage in [.english, .turkish, .german, .finnish] {
            let keyboard: SwipeKeyboard = benchmarkKeyboard(language: language)
            var top1: Int = 0
            var top3: Int = 0
            var total: Int = 0
            var misses: [String] = []
            for (index, word) in (Self.words[language] ?? []).enumerated() {
                for trial in 0 ..< 3 {
                    var noise: SwipeNoise = SwipeNoise(seed: UInt64(index * 31 + trial + 1))
                    let path: [CGPoint] = syntheticSwipe(word: word, keyboard: keyboard, language: language, noise: &noise, sigma: 0.22)
                    let prefixes: [String] = swipeCandidatePrefixes(points: path, keyboard: keyboard, limit: 60)
                    let lists: [(prefix: String, words: [String])] = prefixes.map { ($0, Self.completions(prefix: $0, language: language)) }
                    let matches: [SwipeMatch] = swipeDecode(
                        points: path, keyboard: keyboard, candidates: swipeCandidates(prefixLists: lists, personalWords: []), language: language, limit: 3
                    )
                    let found: [String] = matches.map { $0.word.lowercased(with: language.casingLocale) }
                    total += 1
                    if found.first == word {
                        top1 += 1
                    } else if trial == 0 {
                        misses.append("\(word)→\(found.first ?? "-")")
                    }
                    if found.contains(word) {
                        top3 += 1
                    }
                }
            }
            let line: String = "\(language.rawValue): top-1 \(String(format: "%.1f", 100 * Double(top1) / Double(total)))%, top-3 \(String(format: "%.1f", 100 * Double(top3) / Double(total)))% (\(total) swipes); misses: \(misses.prefix(12).joined(separator: ", "))"
            report.append(line)
        }
        print("SWIPE_BENCH\n" + report.joined(separator: "\n"))
    }
}
#endif
