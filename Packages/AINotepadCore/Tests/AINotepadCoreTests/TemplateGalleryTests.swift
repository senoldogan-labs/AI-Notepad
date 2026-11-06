import Foundation
import Testing
@testable import AINotepadCore

/// Şablon galerisi: her yerleşik tür bir kez ve bir kategoride, kategoriler sırayla, kopyanın adı ve metni.
@Suite struct TemplateGalleryTests {
    @Test func everyBuiltInKindAppearsOnceExceptCustom() {
        let kinds: [NoteTemplateKind] = templateGallery().compactMap { (template: GalleryTemplate) -> NoteTemplateKind? in
            if case .builtIn(let kind) = template.source { kind } else { nil }
        }
        #expect(kinds.count == Set(kinds).count)
        #expect(Set(kinds) == Set(NoteTemplateKind.allCases.filter { $0 != .custom }))
    }

    @Test func idsAreUniqueAndEveryTemplateHasSections() {
        let templates: [GalleryTemplate] = templateGallery()
        #expect(Set(templates.map(\.id)).count == templates.count)
        #expect(templates.allSatisfy { !$0.sections.isEmpty && !$0.summary.isEmpty })
    }

    @Test func sectionsFollowCategoryOrderAndSkipEmpty() {
        let sections: [TemplateGallerySection] = templateGallerySections(templates: templateGallery())
        #expect(sections.map(\.category) == TemplateCategory.allCases)
        #expect(sections.allSatisfy { (section: TemplateGallerySection) -> Bool in section.templates.allSatisfy { $0.category == section.category } })
        let onlyHiring: [GalleryTemplate] = templateGallery().filter { $0.category == .hiring }
        #expect(templateGallerySections(templates: onlyHiring).map(\.category) == [.hiring])
    }

    @Test func editableCopyNamesTheCopyAndListsSections() throws {
        let template: GalleryTemplate = try #require(templateGallery().first { $0.source == .builtIn(.oneOnOne) })
        let copy: TemplateCopy = templateEditableCopy(template: template)
        #expect(copy.name == "\(template.name) (kopya)")
        #expect(copy.instructions.split(separator: "\n").count == template.sections.count + 1)
        #expect(template.sections.allSatisfy { copy.instructions.contains("- \($0)") })
    }

    @Test func selectionMatchesKindOrUnchangedPreset() throws {
        let gallery: [GalleryTemplate] = templateGallery()
        let standup: GalleryTemplate = try #require(gallery.first { $0.source == .builtIn(.standup) })
        let retro: GalleryTemplate = try #require(gallery.first { $0.id == "retrospective" })
        let choice: TemplateCopy = templatePresetChoice(template: retro)
        #expect(isGalleryTemplateSelected(template: standup, selectedKind: "standup", customName: "", customInstructions: ""))
        #expect(!isGalleryTemplateSelected(template: standup, selectedKind: "custom", customName: "", customInstructions: ""))
        #expect(isGalleryTemplateSelected(template: retro, selectedKind: "custom", customName: choice.name, customInstructions: choice.instructions))
        #expect(!isGalleryTemplateSelected(template: retro, selectedKind: "custom", customName: choice.name, customInstructions: choice.instructions + "!"))
        #expect(!isGalleryTemplateSelected(template: retro, selectedKind: "general", customName: choice.name, customInstructions: choice.instructions))
    }

    @Test func customDisplayNameFallsBackToKindName() {
        #expect(customTemplateDisplayName(name: "  ") == NoteTemplateKind.custom.displayName)
        #expect(customTemplateDisplayName(name: " Retro (kopya) ") == "Retro (kopya)")
    }
}
