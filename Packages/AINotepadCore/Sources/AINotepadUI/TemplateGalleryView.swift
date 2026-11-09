// Mac'te Ayarlar › Notlar ve şablonlar altındaki şablon galerisi (iPhone'daki karşılığı listedir: iOS/TemplateGalleryScreen.swift).
#if os(macOS)
import AINotepadCore
import SwiftUI

/// Şablon galerisi: kategori başlıkları altında iki sütunlu kartlar (ad, tek satırlık açıklama, varsayılansa işaret).
/// Karta tıklanınca o kategorinin altında önizleme açılır: notta öne çıkan bölümler, "Kullan" ve "Kopyasını düzenle".
/// Değerleri ve eylemleri çağıran verir; görünüm yalnızca hangi şablonun önizlendiğini tutar.
public struct TemplateGalleryView: View {
    private let sections: [TemplateGallerySection]
    private let selectedKind: String
    private let customName: String
    private let customInstructions: String
    private let onUse: (GalleryTemplate) -> Void
    private let onEditCopy: (GalleryTemplate) -> Void
    @State private var previewID: String?

    public init(
        sections: [TemplateGallerySection], selectedKind: String, customName: String, customInstructions: String,
        initialPreviewID: String?, onUse: @escaping (GalleryTemplate) -> Void, onEditCopy: @escaping (GalleryTemplate) -> Void
    ) {
        self.sections = sections
        self.selectedKind = selectedKind
        self.customName = customName
        self.customInstructions = customInstructions
        self.onUse = onUse
        self.onEditCopy = onEditCopy
        _previewID = State(initialValue: initialPreviewID)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(sections) { (section: TemplateGallerySection) in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: section.category.displayName)
                        .appFont(size: 12, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .padding(.leading, 4)
                        .accessibilityAddTraits(.isHeader)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top), GridItem(.flexible(), spacing: 10, alignment: .top)], spacing: 10) {
                        ForEach(section.templates) { (template: GalleryTemplate) in
                            TemplateGalleryCard(
                                template: template, isDefault: isSelected(template: template), isPreviewed: previewID == template.id
                            ) {
                                withAnimation(.smooth(duration: 0.2)) { previewID = previewID == template.id ? nil : template.id }
                            }
                        }
                    }
                    if let previewed = section.templates.first(where: { $0.id == previewID }) {
                        TemplateGalleryPreview(
                            template: previewed, isDefault: isSelected(template: previewed),
                            replacesCustomText: replacesCustomText(template: previewed),
                            onUse: { onUse(previewed) }, onEditCopy: { onEditCopy(previewed) }
                        )
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private func isSelected(template: GalleryTemplate) -> Bool {
        isGalleryTemplateSelected(template: template, selectedKind: selectedKind, customName: customName, customInstructions: customInstructions)
    }

    /// Kendi şablonunda kaybolacak bir metin var mı (boş değil ve bu şablonun metni değil).
    private func replacesCustomText(template: GalleryTemplate) -> Bool {
        let current: String = customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return !current.isEmpty && current != templateInstructionsText(template: template)
    }
}

/// Galeri kartı: simge kutusu, ad, açıklama; varsayılan şablonda vurgu renginde işaret, önizlenen kartta vurgu çerçevesi.
private struct TemplateGalleryCard: View {
    let template: GalleryTemplate
    let isDefault: Bool
    let isPreviewed: Bool
    let onTap: () -> Void

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconTile(systemImage: template.icon)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: template.name)
                            .appFont(size: 14, weight: .medium)
                            .foregroundStyle(Theme.ink)
                        if isDefault {
                            Image(systemName: "checkmark.circle.fill")
                                .appFont(size: 12, weight: .semibold)
                                .foregroundStyle(.tint)
                                .accessibilityLabel(Text("Varsayılan"))
                        }
                    }
                    Text(verbatim: template.summary)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(Theme.card, in: shape)
            .overlay(shape.strokeBorder(isPreviewed ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.line), lineWidth: isPreviewed ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .linkPointer(isEnabled: true)
        .accessibilityHint(Text("Şablonun önizlemesini açar"))
    }
}

/// Önizleme: şablonun notta öne çıkardığı bölümler madde madde, altında eylemler.
private struct TemplateGalleryPreview: View {
    let template: GalleryTemplate
    let isDefault: Bool
    let replacesCustomText: Bool
    let onUse: () -> Void
    let onEditCopy: () -> Void

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: template.name)
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: template.summary)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notta öne çıkanlar")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(Theme.muted)
                ForEach(Array(template.sections.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(.tint).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(verbatim: item.element)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let note = previewNote {
                note
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(isDefault ? LocalizedStringKey("Kullanılıyor") : LocalizedStringKey("Kullan"), action: onUse)
                    .buttonStyle(.pillPrimary)
                    .disabled(isDefault)
                Button("Kopyasını düzenle", action: onEditCopy)
                    .buttonStyle(.pill)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: shape)
        .overlay(shape.strokeBorder(Theme.line))
    }

    /// Hazır şablonun kendi şablon olarak kaydedildiğini ve kaybolacak metni söyleyen satır.
    private var previewNote: Text? {
        switch (template.source, replacesCustomText) {
        case (.preset, true):
            Text("Hazır şablon: kendi şablonun olarak kaydedilir ve şimdiki metninin yerine geçer.")
        case (.preset, false):
            Text("Hazır şablon: kendi şablonun olarak kaydedilir.")
        case (.builtIn, true):
            Text("Kopyasını düzenlersen kendi şablonundaki şimdiki metin değişir.")
        case (.builtIn, false):
            nil
        }
    }
}
#endif
