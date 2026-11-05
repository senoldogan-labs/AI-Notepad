import Foundation

/// Notun bir satırı (karar ya da açık konu) ve başındaki an: "[12:34] Android sürümü 25 Kasım'a ertelendi…" satırında
/// 754 saniye ve metnin geri kalanı. Anı olmayan (eski) satırda an nil, metin aynen.
public struct AnchoredLine: Sendable, Equatable {
    public let startSec: Double?
    public let text: String

    public init(startSec: Double?, text: String) {
        self.startSec = startSec
        self.text = text
    }
}

/// Satırın başındaki "[mm:ss]" ya da "[s:mm:ss]" anını ayırır; başta geçerli zaman yoksa an nil ve metin aynen. Saf
/// fonksiyondur.
public func anchoredLine(text: String) -> AnchoredLine {
    guard let match = text.prefixMatch(of: /\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s*/), let seconds = timestampSeconds(text: String(match.output.1)) else {
        return AnchoredLine(startSec: nil, text: text)
    }
    return AnchoredLine(startSec: seconds, text: String(text[match.range.upperBound...]))
}

/// Anı satırın başına yazar ("[12:34] metin"); an yoksa metin aynen. Saf fonksiyondur.
public func anchoredText(startSec: Double?, text: String) -> String {
    let body: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return startSec.map { "[\(timestamp(seconds: $0))] \(body)" } ?? body
}

/// Çevrilen ya da düzenlenen satırın anı asıl satırdan alınır (model zamanı değiştirmesin ya da atlamasın). Saf
/// fonksiyondur.
func withOriginalAnchor(original: String, translated: String) -> String {
    anchoredText(startSec: anchoredLine(text: original).startSec, text: anchoredLine(text: translated).text)
}
