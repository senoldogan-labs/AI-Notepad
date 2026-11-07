import Foundation
import Testing

/// Sitenin ekran görüntüleri tanıtım verisinden (`App/DemoData.swift`) çekilir: tanıtım ürünle çelişmesin. Güncelleme
/// kartı uygulamanın kendi sürümünü gösterir (elle yazılmış sürüm eskir: kart "0.1.6" diyordu) ve her madde başlığı
/// yayınlanmış bir sürümün notlarında geçer. Kaynak kutusunun başlığı ile alıntılarının uyumu `NoteSourcesTests`'te
/// (aynı transkript).
private let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appending(path: "../../../..").standardizedFileURL

@Test func demoUpdateCardUsesTheAppVersionAndShippedNotes() throws {
    let demo: String = try String(contentsOf: repoRoot.appending(path: "App/DemoData.swift"), encoding: .utf8)
    #expect(demo.firstMatch(of: /version:\s*"\d/) == nil, "Güncelleme kartının sürümü elle yazılmış; Bundle'dan okunmalı")
    let start: Range<String.Index> = try #require(demo.range(of: "releaseNotes: \"\"\""))
    let end: Range<String.Index> = try #require(demo.range(of: "\"\"\"", range: start.upperBound..<demo.endIndex))
    let notes: String = String(demo[start.upperBound..<end.lowerBound])
    let titles: [String] = notes.matches(of: /\*\*(.+?)\*\*/).map { String($0.1) }
    #expect(!titles.isEmpty)
    let folder: URL = repoRoot.appending(path: "docs/release-notes")
    let shipped: String = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("gistsmith-") && $0.pathExtension == "md" }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
    for title in titles {
        #expect(shipped.contains("**\(title)**"), "Tanıtımdaki \"\(title)\" hiçbir yayın notunda yok")
    }
}
