import CoreGraphics
import Foundation

// Kaydırarak yazma: SHARK² yolundan (Kristensson ve Zhai, 2004) bir şekil eşleştirici. Parmağın izi, aday kelimenin tuş
// merkezlerinden geçen ideal izle karşılaştırılır: konum farkı (iz tuşların üstünden mi geçti), biçim farkı (konumdan
// bağımsız çizgi şekli) ve uzunluk farkı; üstüne kelimenin sıklığından gelen küçük bir pay. Adaylar cihazın kendi
// sözlüğünden gelir (`UITextChecker` tamamlamaları; sıklık sırasıyla): pakete kelime listesi girmez, ağ kullanılmaz.

/// Kaydırmanın bir aday kelimesi: kelime ve sıklık sırası (0 en sık).
public struct SwipeCandidate: Sendable, Hashable {
    public let word: String
    public let rank: Int

    public init(word: String, rank: Int) {
        self.word = word
        self.rank = rank
    }
}

/// Kaydırmanın sonucu: kelime ve puanı (küçük daha iyi).
public struct SwipeMatch: Sendable, Hashable {
    public let word: String
    public let score: Double

    public init(word: String, score: Double) {
        self.word = word
        self.score = score
    }
}

/// Düzenin harf tuşlarının merkezleri ve tuş genişliği (ölçek).
public struct SwipeKeyboard: Sendable, Hashable {
    public let centers: [Character: CGPoint]
    public let keyWidth: CGFloat

    public init(centers: [Character: CGPoint], keyWidth: CGFloat) {
        self.centers = centers
        self.keyWidth = keyWidth
    }
}

/// Tuş çerçevelerinden kaydırma düzeni (yalnız harf tuşları; küçük harf). Saf fonksiyondur.
public func swipeKeyboard(frames: [KeyboardKeyFrame]) -> SwipeKeyboard {
    var centers: [Character: CGPoint] = [:]
    var widths: [CGFloat] = []
    for frame in frames {
        guard case .character(let text) = frame.key.kind, text.count == 1, let character = text.first, character.isLetter else {
            continue
        }
        centers[character] = CGPoint(x: frame.frame.midX, y: frame.frame.midY)
        widths.append(frame.frame.width)
    }
    let keyWidth: CGFloat = widths.isEmpty ? 1 : widths.sorted()[widths.count / 2]
    return SwipeKeyboard(centers: centers, keyWidth: keyWidth)
}

/// İz bir dokunuş değil kaydırma mı: başlangıçtan en az bir buçuk tuş uzaklaşmış. Saf fonksiyondur.
public func swipeIsGesture(points: [CGPoint], keyWidth: CGFloat) -> Bool {
    guard let first = points.first else {
        return false
    }
    return points.contains { distance($0, first) > keyWidth * 1.5 }
}

/// İzin üstünden geçtiği harf tuşları sırasıyla (art arda aynı tuş bir kez): merkezine yarım tuştan yakın geçilen tuşlar.
/// Saf fonksiyondur.
public func swipeKeySequence(points: [CGPoint], keyboard: SwipeKeyboard) -> [Character] {
    var sequence: [Character] = []
    for point in resampled(points: points, count: 64) {
        guard let (key, gap) = nearestKey(point: point, keyboard: keyboard), gap <= keyboard.keyWidth * 0.6 else {
            continue
        }
        if sequence.last != key {
            sequence.append(key)
        }
    }
    return sequence
}

/// İzin `radius` tuş genişliği yakınından geçtiği harf tuşları, ize en çok yaklaştıkları sırayla. Saf fonksiyondur.
public func swipeNearKeys(points: [CGPoint], keyboard: SwipeKeyboard, radius: CGFloat) -> [Character] {
    let samples: [CGPoint] = resampled(points: points, count: 64)
    let near: [(key: Character, index: Int)] = keyboard.centers.compactMap { (entry: (key: Character, value: CGPoint)) -> (key: Character, index: Int)? in
        guard let closest = samples.indices.min(by: { distance(samples[$0], entry.value) < distance(samples[$1], entry.value) }),
              distance(samples[closest], entry.value) <= keyboard.keyWidth * radius
        else {
            return nil
        }
        return (entry.key, closest)
    }
    return near.sorted { $0.index < $1.index || ($0.index == $1.index && $0.key < $1.key) }.map(\.key)
}

/// Aday sorgusu için önekler: başlangıca en yakın iki tuş × izin sonraki tuşları (iki ve üç harfli; çift harf için aynı
/// tuş da). Cihaz her önek için sözlüğün sıklık sıralı tamamlamalarını alır. Saf fonksiyondur.
public func swipeCandidatePrefixes(points: [CGPoint], keyboard: SwipeKeyboard, limit: Int) -> [String] {
    guard let start = points.first else {
        return []
    }
    let starts: [Character] = keyboard.centers
        .map { (key: $0.key, gap: distance($0.value, start)) }
        .filter { $0.gap <= keyboard.keyWidth * 1.1 }
        .sorted { $0.gap < $1.gap }
        .prefix(2)
        .map(\.key)
    // Önek harfleri için daha geniş bir yakınlık: el, köşeleri tuşun merkezinden değil kenarından döner.
    let sequence: [Character] = swipeNearKeys(points: points, keyboard: keyboard, radius: 0.95)
    var prefixes: [String] = []
    func add(_ prefix: String) {
        if prefixes.count < limit, !prefixes.contains(prefix) {
            prefixes.append(prefix)
        }
    }
    // İzde ilk harften sonra geçilen tuşlar; ikinci harf bunlardan biri (ya da çift harf), üçüncü onun ardından. Önce
    // bütün iki harfliler (sınır üç harflileri keser, ikileri değil).
    let afterStarts: [(first: Character, after: [Character])] = starts.map { (first: Character) -> (first: Character, after: [Character]) in
        (first, Array(sequence.filter { $0 != first }.prefix(9)))
    }
    for (first, after) in afterStarts {
        for second in [first] + after {
            add(String([first, second]))
        }
    }
    for (first, after) in afterStarts {
        for (index, second) in ([first] + after).enumerated() {
            let following: [Character] = Array(after.dropFirst(max(0, index)).prefix(5)) + [second]
            for third in following {
                add(String([first, second, third]))
            }
        }
    }
    // İki harfliler önce: kısa önekin listesi daha sık kelimeleri taşır.
    return prefixes.sorted { $0.count < $1.count }
}

/// Önek listelerini tek aday listesine çevirir: kelimenin sırası, göründüğü en kısa önek listesindeki yeri (üç harfli
/// listelerdekiler biraz geride sayılır). Büyük harfli özel adlar küçük harf gibi eşleşir ama yazıldığı gibi döner.
/// Saf fonksiyondur.
public func swipeCandidates(prefixLists: [(prefix: String, words: [String])], personalWords: [String]) -> [SwipeCandidate] {
    var best: [String: (word: String, rank: Int)] = [:]
    for list in prefixLists {
        let base: Int = list.prefix.count <= 2 ? 0 : 8
        for (index, word) in list.words.enumerated() where word.count >= 2 {
            let key: String = word.lowercased()
            let rank: Int = base + index
            if let current = best[key], current.rank <= rank {
                continue
            }
            best[key] = (word, rank)
        }
    }
    for word in personalWords where word.count >= 2 {
        let key: String = word.lowercased()
        best[key] = (best[key]?.word ?? word, min(best[key]?.rank ?? 6, 6))
    }
    return best.values.map { SwipeCandidate(word: $0.word, rank: $0.rank) }
}

/// İzi adaylarla eşleştirir; en iyi `limit` sonuç, iyi olan önce. Düzende olmayan harfi olan, ilk ya da son harfi izin
/// başına ve sonuna uzak olan adaylar elenir. Saf fonksiyondur.
public func swipeDecode(points: [CGPoint], keyboard: SwipeKeyboard, candidates: [SwipeCandidate], language: KeyboardLanguage, limit: Int) -> [SwipeMatch] {
    guard points.count >= 2, let start = points.first, let end = points.last else {
        return []
    }
    let sampleCount: Int = 40
    let gesture: [CGPoint] = resampled(points: points, count: sampleCount)
    let gestureShape: [CGPoint] = normalizedShape(points: gesture)
    let gestureLength: CGFloat = pathLength(points: points)
    let width: CGFloat = keyboard.keyWidth
    var matches: [SwipeMatch] = []
    for candidate in candidates {
        let letters: [Character] = Array(candidate.word.lowercased(with: language.casingLocale))
        guard let path = templatePath(letters: letters, keyboard: keyboard), let first = path.first, let last = path.last else {
            continue
        }
        let startGap: CGFloat = distance(first, start) / width
        let endGap: CGFloat = distance(last, end) / width
        guard startGap <= 1.6, endGap <= 1.6 else {
            continue
        }
        // Kelimenin her harfinin tuşu ize yakın olmalı: izin hiç uğramadığı harfler (uzun aday kelimeler) cezalanır.
        let misses: [Double] = path.map { (anchor: CGPoint) -> Double in
            Double(gesture.map { distance($0, anchor) }.min() ?? 0) / Double(width)
        }
        let anchorGap: Double = misses.reduce(0, +) / Double(misses.count) + 0.5 * (misses.max() ?? 0)
        let template: [CGPoint] = resampled(points: path, count: sampleCount)
        let location: Double = Double(zip(gesture, template).reduce(CGFloat(0)) { $0 + distance($1.0, $1.1) } / CGFloat(sampleCount) / width)
        let shape: Double = Double(zip(gestureShape, normalizedShape(points: template)).reduce(CGFloat(0)) { $0 + distance($1.0, $1.1) } / CGFloat(sampleCount))
        let templateLength: CGFloat = max(pathLength(points: path), width * 0.5)
        let lengthGap: Double = abs(log(Double(max(gestureLength, width * 0.5) / templateLength)))
        let frequency: Double = log2(1 + Double(candidate.rank))
        let score: Double = location + 0.8 * shape + 1.0 * lengthGap + 0.2 * frequency + 0.5 * Double(startGap + endGap) + 0.8 * anchorGap
        matches.append(SwipeMatch(word: candidate.word, score: score))
    }
    return Array(matches.sorted { $0.score < $1.score || ($0.score == $1.score && $0.word < $1.word) }.prefix(limit))
}

/// Kelimenin ideal izi: harflerinin tuş merkezleri (art arda aynı harf bir kez); düzende olmayan harf varsa nil.
private func templatePath(letters: [Character], keyboard: SwipeKeyboard) -> [CGPoint]? {
    var path: [CGPoint] = []
    var previous: Character?
    for letter in letters {
        guard letter != previous else {
            continue
        }
        guard let center = keyboard.centers[letter] else {
            return nil
        }
        path.append(center)
        previous = letter
    }
    return path.count >= 1 ? path : nil
}

private func nearestKey(point: CGPoint, keyboard: SwipeKeyboard) -> (Character, CGFloat)? {
    keyboard.centers.map { ($0.key, distance($0.value, point)) }.min { $0.1 < $1.1 }
}

func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx: CGFloat = a.x - b.x
    let dy: CGFloat = a.y - b.y
    return (dx * dx + dy * dy).squareRoot()
}

func pathLength(points: [CGPoint]) -> CGFloat {
    zip(points, points.dropFirst()).reduce(CGFloat(0)) { $0 + distance($1.0, $1.1) }
}

/// İzi eşit aralıklı `count` noktaya yeniden örnekler (tek noktalı iz o noktanın tekrarı). Saf fonksiyondur.
func resampled(points: [CGPoint], count: Int) -> [CGPoint] {
    guard let first = points.first else {
        return []
    }
    let total: CGFloat = pathLength(points: points)
    guard total > 0, count > 1 else {
        return Array(repeating: first, count: count)
    }
    let step: CGFloat = total / CGFloat(count - 1)
    var result: [CGPoint] = [first]
    var carried: CGFloat = 0
    for (a, b) in zip(points, points.dropFirst()) {
        let segment: CGFloat = distance(a, b)
        guard segment > 0 else {
            continue
        }
        var position: CGFloat = step - carried
        while position <= segment, result.count < count {
            let t: CGFloat = position / segment
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            position += step
        }
        carried = segment - (position - step)
    }
    while result.count < count, let last = points.last {
        result.append(last)
    }
    return result
}

/// Konumdan ve ölçekten bağımsız şekil: ağırlık merkezi sıfıra, en uzun kenar bire.
private func normalizedShape(points: [CGPoint]) -> [CGPoint] {
    guard !points.isEmpty else {
        return []
    }
    let cx: CGFloat = points.reduce(0) { $0 + $1.x } / CGFloat(points.count)
    let cy: CGFloat = points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
    let xs: [CGFloat] = points.map(\.x)
    let ys: [CGFloat] = points.map(\.y)
    let side: CGFloat = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0), 1)
    return points.map { CGPoint(x: ($0.x - cx) / side, y: ($0.y - cy) / side) }
}
