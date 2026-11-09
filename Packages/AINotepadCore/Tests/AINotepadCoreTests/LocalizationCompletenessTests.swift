import Foundation
import Testing

/// Deponun kökü (bu dosya `Packages/AINotepadCore/Tests/AINotepadCoreTests` içinde).
private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}

/// Arayüz dilleri (kaynak Türkçe ve İngilizce dışında); `scripts/l10n.py` `TARGET_LANGUAGES` ile aynı olmalı.
private let uiLanguages: [String] = ["de", "fr", "es", "it", "pt-BR", "nl", "ja", "ko", "zh-Hans", "fi"]

/// Çevirisi denetlenen metin katalogları.
private let catalogPaths: [String] = [
    "App/Localizable.xcstrings",
    "App/InfoPlist.xcstrings",
    "App/Hosted/InfoPlist.xcstrings",
    "iOS/InfoPlist.xcstrings",
    "App/AppShortcuts.xcstrings",
    "Watch/Localizable.xcstrings",
    "Watch/InfoPlist.xcstrings",
]

/// Ürün adları her dilde aynı kalır; çeviri istenmez.
private let untranslatedKeys: Set<String> = ["CFBundleName", "CFBundleDisplayName"]

/// String kataloğunun (`.xcstrings`) bu testin okuduğu kısmı.
private struct StringCatalog: Decodable {
    let strings: [String: CatalogEntry]
}

private struct CatalogEntry: Decodable {
    let shouldTranslate: Bool?
    let localizations: [String: CatalogLocalization]?
}

private struct CatalogLocalization: Decodable {
    let stringUnit: CatalogStringUnit?
    let variations: CatalogVariations?

    /// Düz metin ya da çoğul biçim (en az "other") var mı.
    var hasText: Bool {
        if let stringUnit {
            return !stringUnit.value.isEmpty
        }
        return variations?.plural?["other"] != nil
    }
}

private struct CatalogStringUnit: Decodable {
    let value: String
}

private struct CatalogVariations: Decodable {
    let plural: [String: CatalogPluralForm]?
}

private struct CatalogPluralForm: Decodable {
    let stringUnit: CatalogStringUnit
}

/// Eksik çeviriler: çevrilecek (İngilizcesi olan) her metin her arayüz dilinde bulunmalı. Saf fonksiyondur.
private func missingTranslations(catalog: StringCatalog, path: String) -> [String] {
    catalog.strings.flatMap { (key: String, entry: CatalogEntry) -> [String] in
        guard entry.shouldTranslate != false, !untranslatedKeys.contains(key), let localizations = entry.localizations,
              localizations["en"]?.hasText == true
        else {
            return []
        }
        return uiLanguages.filter { localizations[$0]?.hasText != true }.map { "\(path) [\($0)] \(key)" }
    }
    .sorted()
}

/// Arayüz çevirileri: eksik çeviri cihazda İngilizceye değil Türkçe kaynağa düşer (Almanca arayüzde Türkçe metin), bu
/// yüzden yeni her metin tüm dillere çevrilmeli. Çeviri akışı: `scripts/l10n.py export | validate | import | check`.
@Suite struct LocalizationCompletenessTests {
    @Test func everyStringIsTranslatedIntoEveryUILanguage() throws {
        var missing: [String] = []
        for path in catalogPaths {
            let data: Data = try Data(contentsOf: repositoryRoot().appending(path: path))
            let catalog: StringCatalog = try JSONDecoder().decode(StringCatalog.self, from: data)
            missing += missingTranslations(catalog: catalog, path: path)
        }
        #expect(missing.isEmpty, "Çevirisi eksik \(missing.count) metin (scripts/l10n.py export ile çıkar): \(missing.prefix(20))")
    }

    // Metnin sonundaki üç nokta taban çizgisindeki "…" (U+2026) olmalı: "⋯" (U+22EF, ortada) yalnız ⋯ menü düğmesinin
    // adıdır ("⋯ menüsü", "会議の⋯メニュー"). Bir harfin ya da rakamın hemen ardından gelip metni ya da cümleyi bitiren "⋯"
    // üç nokta yerine yazılmıştır.
    @Test func trailingEllipsesUseTheBaselineGlyph() throws {
        let trailing: Regex<Substring> = #/[\p{L}\p{N}]⋯(?=$|[\s.,;:!?)"”])/#
        #expect("Ask a follow-up⋯".contains(trailing) && "Reading 1 meeting⋯ (2)".contains(trailing))
        #expect(!"the ⋯ menu".contains(trailing) && !"会議の⋯メニュー".contains(trailing) && !"(⋯-valikko)".contains(trailing))
        var found: [String] = []
        for path in catalogPaths {
            let data: Data = try Data(contentsOf: repositoryRoot().appending(path: path))
            let catalog: StringCatalog = try JSONDecoder().decode(StringCatalog.self, from: data)
            for (key, entry) in catalog.strings {
                let values: [String] = (entry.localizations ?? [:]).values.flatMap { (localization: CatalogLocalization) -> [String] in
                    [localization.stringUnit?.value].compactMap { $0 } + (localization.variations?.plural?.values.map(\.stringUnit.value) ?? [])
                }
                found += ([key] + values).filter { $0.contains(trailing) }.map { "\(path): \($0)" }
            }
        }
        let sources: [URL] = ["App", "iOS", "Packages/AINotepadCore/Sources"].flatMap { (folder: String) -> [URL] in
            let enumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(at: repositoryRoot().appending(path: folder), includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }
        #expect(sources.count > 100)
        for file in sources {
            let text: String = try String(contentsOf: file, encoding: .utf8)
            // Yalnız metin değişmezleri: yorumlardaki "⋯ menüsü" adlandırmadır.
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                found += line.matches(of: #/"[^"]*"/#).map { String($0.output) }.filter { $0.contains(trailing) }.map { "\(file.lastPathComponent): \($0)" }
            }
        }
        #expect(found.isEmpty, "Sonda \"⋯\" yerine \"…\" yazılmalı: \(found.prefix(20))")
    }

    @Test func languageListMatchesTheTranslationScript() throws {
        let script: String = try String(contentsOf: repositoryRoot().appending(path: "scripts/l10n.py"), encoding: .utf8)
        let line: Substring = try #require(script.firstRange(of: "TARGET_LANGUAGES: tuple[str, ...] = (").map { script[$0.upperBound...] })
        let body: Substring = try #require(line.firstRange(of: ")").map { line[..<$0.lowerBound] })
        let scriptLanguages: [String] = body.matches(of: #/"([A-Za-z-]+)"/#).map { String($0.output.1) }
        #expect(scriptLanguages == uiLanguages)
    }
}
