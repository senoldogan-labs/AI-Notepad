import Testing
@testable import AINotepadUI

@Suite struct AppearanceTests {
    // Saklanan değerler aralığa sıkıştırılır; tanınmayan seçim varsayılanına döner.
    @Test func resolvedAppearanceClampsAndParses() {
        let appearance: PanelAppearance = resolvedPanelAppearance(stored: StoredAppearance(
            fontDesign: "family:Georgia", uiScale: 3, textSize: 2, lineSpacing: -4, bottomSpacing: 500, accent: "teal", surface: "frosted",
            surfaceOpacity: 0.1
        ), isFontFamilyInstalled: { $0 == "Georgia" })
        #expect(appearance.fontChoice == .installed(family: "Georgia"))
        #expect(appearance.uiScale == AppearanceRange.uiScale.upperBound)
        #expect(appearance.textSize == AppearanceRange.textSize.lowerBound)
        #expect(appearance.lineSpacing == 0)
        #expect(appearance.bottomSpacing == AppearanceRange.bottomSpacing.upperBound)
        #expect(appearance.accent == PanelAppearance.standard.accent)
        #expect(appearance.surface == .frosted)
        #expect(appearance.surfaceOpacity == AppearanceRange.surfaceOpacity.lowerBound)

        let unknownFont: PanelAppearance = resolvedPanelAppearance(stored: StoredAppearance(
            fontDesign: "", uiScale: 1, textSize: 14, lineSpacing: 4, bottomSpacing: 32, accent: "green", surface: "", surfaceOpacity: 0.7
        ), isFontFamilyInstalled: { _ in true })
        #expect(unknownFont.fontChoice == PanelAppearance.standard.fontChoice)
        #expect(unknownFont.accent == .green)
        #expect(unknownFont.surface == PanelAppearance.standard.surface)

        // Kaldırılmış yazı ailesi varsayılan yazıdır; tasarımlar yüklü aileye bağlı değildir.
        let removedFamily: PanelAppearance = resolvedPanelAppearance(stored: StoredAppearance(
            fontDesign: "family:Removed Sans", uiScale: 1, textSize: 14, lineSpacing: 4, bottomSpacing: 32, accent: "green", surface: "",
            surfaceOpacity: 0.7
        ), isFontFamilyInstalled: { _ in false })
        #expect(removedFamily.fontChoice == PanelAppearance.standard.fontChoice)
        #expect(availableFontChoice(storage: "serif", isFamilyInstalled: { _ in false }) == .design(.serif))
    }

    // Okuma metni varsayılanda tasarımdaki boyut ve aralıktadır; ayar büyüdükçe orantılı büyür.
    @Test func readingMetricsFollowSettings() {
        let standard: PanelAppearance = .standard
        #expect(standard.readingSize(base: 18) == 18)
        #expect(standard.readingLineSpacing(base: 6) == 6)
        let large: PanelAppearance = resolvedPanelAppearance(stored: StoredAppearance(
            fontDesign: "inter", uiScale: 1, textSize: 21, lineSpacing: 8, bottomSpacing: 32, accent: "orange", surface: "solid", surfaceOpacity: 0.7
        ), isFontFamilyInstalled: { _ in true })
        #expect(large.readingSize(base: 18) == 27)
        #expect(large.readingLineSpacing(base: 6) == 12)
    }

    // Dinamik Yazı çarpanı arayüz ölçeğine, metin boyutuna ve satır aralığına uygulanır; kullanıcının ayarı korunur.
    @Test func dynamicTypeScalesOnTopOfSettings() {
        let scaled: PanelAppearance = PanelAppearance.standard.dynamicTypeScaled(factor: 1.5)
        #expect(scaled.uiScale == 1.5)
        #expect(scaled.textSize == 21)
        #expect(scaled.lineSpacing == 6)
        #expect(scaled.fontChoice == PanelAppearance.standard.fontChoice)
        #expect(scaled.accent == PanelAppearance.standard.accent)
    }

    // Önerilen aileler yalnız yüklü olanlardır; seçili aile listede yoksa sona eklenir.
    @Test func suggestedFamiliesKeepSelection() {
        let available: Set<String> = ["Georgia", "Menlo", "Zapfino"]
        #expect(suggestedFontFamilies(available: available, current: .design(.inter)) == ["Georgia", "Menlo"])
        #expect(suggestedFontFamilies(available: available, current: .installed(family: "Zapfino")) == ["Georgia", "Menlo", "Zapfino"])
        #expect(suggestedFontFamilies(available: available, current: .installed(family: "Georgia")) == ["Georgia", "Menlo"])
    }
}
