import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar › Not › Şablon galerisi: kategorilere ayrılmış şablonlar (Mac'teki `TemplateGalleryView`'un karşılığı);
/// satıra dokununca önizleme açılır.
struct TemplateGalleryScreen: View {
    @AppStorage(PhoneSettingsKey.noteTemplate) private var noteTemplate: String = NoteTemplateKind.general.rawValue
    @AppStorage(PhoneSettingsKey.customTemplate) private var customTemplate: String = ""
    @AppStorage(PhoneSettingsKey.customTemplateName) private var customTemplateName: String = ""

    var body: some View {
        List {
            ForEach(templateGallerySections(templates: templateGallery())) { (section: TemplateGallerySection) in
                Section {
                    ForEach(section.templates) { (template: GalleryTemplate) in
                        NavigationLink(value: PhoneSettingsRoute.templatePreview(id: template.id)) {
                            LabeledContent {
                                if isGalleryTemplateSelected(template: template, selectedKind: noteTemplate, customName: customTemplateName, customInstructions: customTemplate) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel(Text("Varsayılan"))
                                }
                            } label: {
                                PhoneSettingLabel(icon: template.icon, title: Text(verbatim: template.name)) {
                                    Text(verbatim: template.summary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(verbatim: section.category.displayName)
                }
            }
        }
        .navigationTitle("Şablon galerisi")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Şablonun önizlemesi: notta öne çıkan bölümler, "Kullan" ve "Kopyasını düzenle" (kopya kendi şablonuna yazılır ve
/// düzenleyicisi açılır).
struct TemplatePreviewScreen: View {
    let template: GalleryTemplate
    let router: PhoneRouter
    @AppStorage(PhoneSettingsKey.noteTemplate) private var noteTemplate: String = NoteTemplateKind.general.rawValue
    @AppStorage(PhoneSettingsKey.customTemplate) private var customTemplate: String = ""
    @AppStorage(PhoneSettingsKey.customTemplateName) private var customTemplateName: String = ""

    var body: some View {
        let isDefault: Bool = isGalleryTemplateSelected(template: template, selectedKind: noteTemplate, customName: customTemplateName, customInstructions: customTemplate)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    SettingsIconTile(systemImage: template.icon)
                    Text(verbatim: template.name)
                        .appFont(size: 22, weight: .semibold)
                    Text(verbatim: template.summary)
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section {
                ForEach(Array(template.sections.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                    Label {
                        Text(verbatim: item.element)
                    } icon: {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                    }
                }
            } header: {
                Text("Notta öne çıkanlar")
            } footer: {
                if let note = previewNote {
                    note
                }
            }
            Section {
                Button(isDefault ? LocalizedStringKey("Kullanılıyor") : LocalizedStringKey("Kullan"), systemImage: "checkmark.circle") {
                    use()
                }
                .disabled(isDefault)
                Button("Kopyasını düzenle", systemImage: "square.and.pencil") {
                    editCopy()
                }
            }
        }
        .navigationTitle(Text(verbatim: template.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Hazır şablonun kendi şablon olarak kaydedildiğini ve kaybolacak metni söyleyen dipnot.
    private var previewNote: Text? {
        let current: String = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let replaces: Bool = !current.isEmpty && current != templateInstructionsText(template: template)
        switch (template.source, replaces) {
        case (.preset, true):
            return Text("Hazır şablon: kendi şablonun olarak kaydedilir ve şimdiki metninin yerine geçer.")
        case (.preset, false):
            return Text("Hazır şablon: kendi şablonun olarak kaydedilir.")
        case (.builtIn, true):
            return Text("Kopyasını düzenlersen kendi şablonundaki şimdiki metin değişir.")
        case (.builtIn, false):
            return nil
        }
    }

    /// "Kullan": yerleşik tür seçilir; hazır şablon kendi şablonun olarak kaydedilip seçilir.
    private func use() {
        switch template.source {
        case .builtIn(let kind):
            noteTemplate = kind.rawValue
        case .preset:
            let choice: TemplateCopy = templatePresetChoice(template: template)
            customTemplateName = choice.name
            customTemplate = choice.instructions
            noteTemplate = NoteTemplateKind.custom.rawValue
        }
    }

    /// "Kopyasını düzenle": kopya kendi şablonuna yazılır, seçilir ve düzenleyicisi açılır (geri Ayarlar'a döner).
    private func editCopy() {
        let copy: TemplateCopy = templateEditableCopy(template: template)
        customTemplateName = copy.name
        customTemplate = copy.instructions
        noteTemplate = NoteTemplateKind.custom.rawValue
        router.settingsPath = [.customTemplate]
    }
}

/// Kendi şablonun: adı ve notta neyin öne çıkacağını anlatan yönergesi.
struct CustomTemplateScreen: View {
    @AppStorage(PhoneSettingsKey.customTemplate) private var customTemplate: String = ""
    @AppStorage(PhoneSettingsKey.customTemplateName) private var customTemplateName: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notta neyin öne çıkacağını yaz; ör. “Riskleri ayrı say, kararların gerekçesini yaz.”")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            TextField(text: $customTemplateName) {
                Text("Şablon adı")
            }
            .appFont(size: 16, weight: .regular)
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
            TextEditor(text: $customTemplate)
                .appFont(size: 16, weight: .regular)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .autocorrectionDisabled()
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(20)
        .background(Theme.background)
        .navigationTitle("Kendi şablonun")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isFocused = true }
    }
}

/// `--sablon-galerisi [<şablon kimliği>]` başlatma argümanı (yalnız Debug, görsel kontrol): Ayarlar'da galeriyi, kimlik
/// verildiyse o şablonun önizlemesini açar; yoksa boş. Saf fonksiyondur.
func launchTemplateGalleryPath(arguments: [String]) -> [PhoneSettingsRoute] {
    guard let index = arguments.firstIndex(of: "--sablon-galerisi") else {
        return []
    }
    guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
        return [.templateGallery]
    }
    return [.templateGallery, .templatePreview(id: arguments[index + 1])]
}
