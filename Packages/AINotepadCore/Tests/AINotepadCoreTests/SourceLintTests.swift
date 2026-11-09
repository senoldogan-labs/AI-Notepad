import Foundation
import Testing

/// Deponun kökü (bu dosya `Packages/AINotepadCore/Tests/AINotepadCoreTests` içinde).
private func lintRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Taranan arayüz kaynakları (uygulamalar, widget'lar ve paylaşılan arayüz paketi).
private let lintedFolders: [String] = ["App", "iOS", "iOSWidgets", "Packages/AINotepadCore/Sources/AINotepadUI"]

/// Bir kaynak kuralı: adı, ne yakaladığı ve dosya metnindeki ihlal sayısı (saf fonksiyon).
private struct SourceRule: Sendable {
    let name: String
    let reason: String
    let folders: [String]
    /// Kuralın bilerek uygulanmadığı dosyalar ve klasörler (yol öneki), her biri gerekçesiyle.
    let exceptions: [String: String]
    let violations: @Sendable (String) -> Int
}

/// Yazı sisteminin kendisi ve belgelenmiş istisnaları (bkz. `Typography.swift`).
private let typographyExceptions: [String: String] = [
    "Packages/AINotepadCore/Sources/AINotepadUI/Typography.swift": "Yazı sisteminin kendisi.",
    "Packages/AINotepadCore/Sources/AINotepadUI/PanelAppearance.swift": "Yazı sisteminin kendisi (aile, ölçek, okuma metni).",
    "iOSWidgets/": "Widget ve Canlı Etkinlik ayrı süreçte çizilir, uygulamanın görünüm ayarını okuyamaz: sistem metin stilleriyle Dinamik Yazı'yı izler.",
]

/// Yazı sistemini atlayan yazı: `.font(.system(`, `.font(.custom(`, `Font.system(`/`Font.custom(`, `codeFont: .system(`
/// gibi doğrudan yazı değerleri ve sistem metin stilleri (`.font(.callout)`).
private let rawFontPattern: String =
    #"(\.font\(\s*\.(system|custom)\(|\bFont\.(system|custom)\(|Font: \.(system|custom)\(|\.font\(\s*\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b)"#

/// Metinde düzenli ifadenin eşleşme sayısı. Saf fonksiyondur.
private func matchCount(pattern: String, text: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        Issue.record("Geçersiz desen: \(pattern)")
        return 0
    }
    return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
}

/// Simgeli düğmeler: `} label: {` hemen ardından tek bir `Image(systemName:` ve sonraki 14 satırda erişilebilirlik adı yok
/// (`accessibilityLabel`, `labelStyle`, `Label(`, `hoverHint` — o da adı verir). VoiceOver böyle düğmeyi "düğme" diye okur. Saf fonksiyondur.
private func unlabeledIconButtons(text: String) -> Int {
    let lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
    var count: Int = 0
    for (index, line) in lines.enumerated() where line.hasSuffix("} label: {") && index + 1 < lines.count {
        guard lines[index + 1].trimmingCharacters(in: .whitespaces).hasPrefix("Image(systemName:") else {
            continue
        }
        let window: String = lines[(index + 1)..<min(lines.count, index + 15)].joined(separator: "\n")
        if !window.contains("accessibilityLabel"), !window.contains("labelStyle"), !window.contains("Label("), !window.contains("hoverHint(") {
            count += 1
        }
    }
    return count
}

private let sourceRules: [SourceRule] = [
    SourceRule(
        name: "raw-reason-in-message",
        reason: "Kullanıcı metnine hatanın teknik nedeni (`reason`, sistem ya da sabit Türkçe metin) eklenmez: arayüz dilinde olmayabilir. Nedeni günlüğe yaz, metni `String(localized:)` ile kur.",
        folders: lintedFolders + ["Packages/AINotepadCore/Sources/AINotepadCore"],
        exceptions: [:],
        violations: { matchCount(pattern: #"String\(localized: "[^"\n]*\\\(reason\)"#, text: $0) }
    ),
    SourceRule(
        name: "describing-error-in-ui",
        reason: "`String(describing: error)` yalnız günlüğe gider; arayüzde `userFacingMessage(error:)` kullan.",
        folders: lintedFolders,
        exceptions: [:],
        violations: { matchCount(pattern: #"(reason|message|Text\(verbatim): String\(describing: error\)"#, text: $0) }
    ),
    SourceRule(
        name: "raw-font",
        reason: "Yazı Ayarlar › Görünüm'deki aile, ölçek ve Dinamik Yazı'yı izlemeli: `appFont(size:weight:)`, `readingText`, `appMonoFont` ya da `shapeSymbol` kullan (bkz. `Typography.swift`); `.system(...)`, `.custom(...)` ya da sistem metin stili (`.callout`) kullanma.",
        folders: lintedFolders,
        exceptions: typographyExceptions,
        violations: { matchCount(pattern: rawFontPattern, text: $0) }
    ),
    SourceRule(
        name: "uncached-naming",
        reason: "iPhone'da bütün arşivi adlandırma (`namedRecords(records:`) her çizimde etiket araması yapar: `store.namedMeetings()` kullan.",
        folders: ["iOS"],
        exceptions: [:],
        violations: { matchCount(pattern: #"namedRecords\(records: store\.meetings"#, text: $0) }
    ),
    SourceRule(
        name: "unlabeled-icon-button",
        reason: "Yalnız simgeli düğmeye `accessibilityLabel` ver (VoiceOver aksi hâlde yalnız \"düğme\" der).",
        folders: lintedFolders,
        exceptions: [:],
        violations: unlabeledIconButtons(text:)
    ),
    SourceRule(
        name: "system-orange-text",
        reason: "Sistem turuncusu açık zeminde okunmaz (~2:1): uyarı yazısı için `NoticeSeverity.attention.tint`.",
        folders: ["iOS", "App"],
        exceptions: [:],
        violations: { matchCount(pattern: #"\.foregroundStyle\(\.orange\)"#, text: $0) }
    ),
]

/// Bu testin eklendiği gün var olan ihlaller ("kural|dosya" → sayı). Yeni ihlal (sayı artarsa) test başarısız olur;
/// düzeltilen ihlalin sayısını burada da düşür ki geri gelmesin.
private let sourceLintBaseline: [String: Int] = [
    "raw-reason-in-message|App/DiagnosticsViews.swift": 1,
    "raw-reason-in-message|App/EventKitConnector.swift": 2,
    "raw-reason-in-message|App/MeetingNotifier.swift": 2,
    "raw-reason-in-message|App/ShortcutSettings.swift": 1,
    "raw-reason-in-message|App/VoiceTypingSettings.swift": 1,
    "raw-reason-in-message|Packages/AINotepadCore/Sources/AINotepadCore/Hosted/HostedFinalTranscriber.swift": 1,
    "raw-reason-in-message|Packages/AINotepadCore/Sources/AINotepadCore/Meeting/ProcessMeeting.swift": 2,
    "raw-reason-in-message|Packages/AINotepadCore/Sources/AINotepadCore/Support/UserMessages.swift": 3,
    "raw-reason-in-message|iOS/TasksTab.swift": 1,
]

@Suite struct SourceLintTests {
    @Test func noNewViolations() throws {
        let root: URL = lintRepositoryRoot()
        var found: [String: Int] = [:]
        for rule in sourceRules {
            for folder in rule.folders {
                let base: URL = root.appending(path: folder)
                guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
                    Issue.record("Klasör okunamadı: \(folder)")
                    continue
                }
                for case let url as URL in enumerator where url.pathExtension == "swift" {
                    let relative: String = String(url.path.dropFirst(root.path.count + 1))
                    if rule.exceptions.keys.contains(where: { relative.hasPrefix($0) }) {
                        continue
                    }
                    let count: Int = rule.violations(try String(contentsOf: url, encoding: .utf8))
                    if count > 0 {
                        found["\(rule.name)|\(relative)"] = count
                    }
                }
            }
        }
        let increased: [String] = found.keys.sorted().filter { found[$0, default: 0] > sourceLintBaseline[$0, default: 0] }
        for key in increased {
            let rule: String = String(key.split(separator: "|").first ?? "")
            let why: String = sourceRules.first { $0.name == rule }?.reason ?? ""
            Issue.record("Yeni ihlal \(key): \(found[key, default: 0]) (taban \(sourceLintBaseline[key, default: 0])). \(why)")
        }
        if !increased.isEmpty {
            print("SOURCE_LINT_FOUND " + found.keys.sorted().map { "\"\($0)\": \(found[$0, default: 0])," }.joined(separator: " "))
        }
    }

    /// iPhone'da bir sayfa (sheet, tam ekran sunum, seçici) yalnız sunum değiştiricisinin olduğu yerdeki ortamı alır.
    /// `RootView`'un ortam nesneleri (`PhoneStore`, `PhoneRecorder`, `PhoneImportState`, `PhoneDialer`) bütün
    /// sunumlarından sonra eklenmeli: önce eklenirse nesneyi okuyan sayfa açılırken SwiftUI uygulamayı durdurur
    /// (`EnvironmentValues` → `_assertionFailure`; telefon görüşmesi rehberi böyle çöktü, I-P0-1).
    @Test func phoneRootPresentationsAreInsideTheEnvironment() throws {
        let text: String = try String(contentsOf: lintRepositoryRoot().appending(path: "iOS/AINotepadiOSApp.swift"), encoding: .utf8)
        let start: Range<String.Index> = try #require(text.range(of: "struct RootView: View {"))
        let end: Range<String.Index> = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        let root: Substring = text[start.lowerBound..<end.lowerBound]
        let injections: [String] = [".environment(store)", ".environment(recorder)", ".environment(imports)", ".environment(dialer)"]
        let positions: [String.Index] = injections.compactMap { (injection: String) -> String.Index? in root.range(of: injection)?.lowerBound }
        let firstInjection: String.Index = try #require(positions.min())
        #expect(injections.allSatisfy { root.contains($0) }, "RootView ortam nesnelerinin hepsini eklemeli")
        let presentation = /\.(sheet|fullScreenCover|popover|fileImporter|photosPicker|alert|confirmationDialog|modifier)\(/
        let late: [String] = root[firstInjection...].matches(of: presentation).map { String($0.output.1) }
        #expect(late.isEmpty, "Ortam nesnelerinden sonra gelen sunum: \(late)")

        // Pencere düzeyindeki sayfalar (klavye kurulumu, sorusu ve oturumu) yalnız `PhoneSharedFileInbox`'u alır.
        let keyboardDirectory: URL = lintRepositoryRoot().appending(path: "iOS/Keyboard")
        for file in try FileManager.default.contentsOfDirectory(at: keyboardDirectory, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let source: String = try String(contentsOf: file, encoding: .utf8)
            let objects: [String] = source.matches(of: /@Environment\(([A-Za-z]+)\.self\)/).map { String($0.output.1) }
            #expect(objects.allSatisfy { $0 == "PhoneSharedFileInbox" }, "\(file.lastPathComponent): \(objects)")
        }
    }
}
