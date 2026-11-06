import Foundation

/// Şablon galerisinin kategorisi (Mac ve iPhone'da aynı sırayla).
public enum TemplateCategory: String, Sendable, CaseIterable {
    case team
    case product
    case customers
    case hiring
    case learning

    /// Galerideki başlığı.
    public var displayName: String {
        switch self {
        case .team: String(localized: "Ekip")
        case .product: String(localized: "Ürün ve proje")
        case .customers: String(localized: "Müşteri ve satış")
        case .hiring: String(localized: "İşe alım")
        case .learning: String(localized: "Öğrenme")
        }
    }
}

/// Galerideki şablonun kaynağı: yerleşik tür (`NoteTemplateKind`, kendi yönergesiyle) ya da yalnızca galeride duran hazır
/// şablon. Hazır şablon yeni bir tür değildir: seçilince "Kendi şablonum" olarak kaydedilir, böylece toplantı kayıtları
/// ve eşitleme eski sürümlerin tanımadığı bir türle karşılaşmaz.
public enum GalleryTemplateSource: Sendable, Equatable {
    case builtIn(NoteTemplateKind)
    case preset
}

/// Galerideki bir şablon: adı, tek satırlık açıklaması ve notta öne çıkardığı bölümler (önizleme ve kopyanın metni).
public struct GalleryTemplate: Sendable, Equatable, Identifiable {
    public let id: String
    public let category: TemplateCategory
    public let source: GalleryTemplateSource
    public let name: String
    public let summary: String
    public let sections: [String]
    /// Kartın SF Symbol simgesi.
    public let icon: String
}

/// Galerinin bir kategorisi ve şablonları.
public struct TemplateGallerySection: Sendable, Equatable, Identifiable {
    public let category: TemplateCategory
    public let templates: [GalleryTemplate]

    public var id: String { category.rawValue }
}

/// "Kopyasını düzenle"nin ya da hazır şablonu seçmenin kendi şablona yazdığı ad ve yönerge.
public struct TemplateCopy: Sendable, Equatable {
    public let name: String
    public let instructions: String
}

/// Galerinin şablonları, kategori sırasıyla: yedi yerleşik tür ve kategorileri boş kalmasın diye üç hazır şablon
/// (retrospektif, kullanıcı araştırması, mülakat değerlendirmesi). Metinler arayüz dilindedir. Saf fonksiyondur.
public func templateGallery() -> [GalleryTemplate] {
    [
        GalleryTemplate(
            id: NoteTemplateKind.general.rawValue, category: .team, source: .builtIn(.general),
            name: NoteTemplateKind.general.displayName,
            summary: String(localized: "Her toplantıya uyan dengeli not."),
            sections: [
                String(localized: "Kısa özet ve konu akışı"), String(localized: "Alınan kararlar"),
                String(localized: "Kimin neyi ne zamana yapacağı"), String(localized: "Açık kalan konular"),
            ],
            icon: "doc.text"
        ),
        GalleryTemplate(
            id: NoteTemplateKind.oneOnOne.rawValue, category: .team, source: .builtIn(.oneOnOne),
            name: NoteTemplateKind.oneOnOne.displayName,
            summary: String(localized: "Yöneticinle ya da bir ekip arkadaşınla birebir görüşmeler."),
            sections: [
                String(localized: "Verilen ve alınan geri bildirimler"), String(localized: "Kişinin hedefleri ve endişeleri"),
                String(localized: "Takip edilecek konular"), String(localized: "Varılan anlaşmalar"),
            ],
            icon: "person.2"
        ),
        GalleryTemplate(
            id: NoteTemplateKind.standup.rawValue, category: .team, source: .builtIn(.standup),
            name: NoteTemplateKind.standup.displayName,
            summary: String(localized: "Kısa günlük ekip toplantıları, kişi kişi."),
            sections: [
                String(localized: "Engeller ve kimden yardım beklendiği"), String(localized: "Her kişinin dün yaptıkları"),
                String(localized: "Her kişinin bugün yapacakları"), String(localized: "Toplantıda yeni üstlenilen işler"),
            ],
            icon: "sun.max"
        ),
        GalleryTemplate(
            id: NoteTemplateKind.sprintPlanning.rawValue, category: .product, source: .builtIn(.sprintPlanning),
            name: NoteTemplateKind.sprintPlanning.displayName,
            summary: String(localized: "Sprintin hedefini ve kapsamını belirleyen toplantılar."),
            sections: [
                String(localized: "Sprint hedefi"), String(localized: "Sprinte alınan işler ve sorumluları"),
                String(localized: "Sprint dışında bırakılan işler"), String(localized: "Riskler ve bağımlılıklar"),
                String(localized: "Kapasite notları (izinler, tahminler)"),
            ],
            icon: "list.bullet.rectangle"
        ),
        GalleryTemplate(
            id: "retrospective", category: .product, source: .preset,
            name: String(localized: "Retrospektif"),
            summary: String(localized: "Biten dönemi birlikte değerlendiren ekip toplantıları."),
            sections: [
                String(localized: "İyi gidenler"), String(localized: "Zorlayanlar ve nedenleri"),
                String(localized: "Denenecek iyileştirmeler ve sorumluları"),
                String(localized: "Önceki retrospektifte alınan kararların durumu"),
            ],
            icon: "arrow.triangle.2.circlepath"
        ),
        GalleryTemplate(
            id: NoteTemplateKind.client.rawValue, category: .customers, source: .builtIn(.client),
            name: NoteTemplateKind.client.displayName,
            summary: String(localized: "Satış, demo ve hesap görüşmeleri."),
            sections: [
                String(localized: "Müşterinin ihtiyaçları ve hedefleri"), String(localized: "İtirazlar ve soru işaretleri"),
                String(localized: "Bütçe ve zamanlama"), String(localized: "Anılan rakipler"), String(localized: "Sonraki adımlar"),
            ],
            icon: "briefcase"
        ),
        GalleryTemplate(
            id: "userResearch", category: .customers, source: .preset,
            name: String(localized: "Kullanıcı araştırması"),
            summary: String(localized: "Ürünü kullananlarla yapılan keşif görüşmeleri."),
            sections: [
                String(localized: "Kullanıcının bağlamı ve bugün nasıl çözdüğü"),
                String(localized: "Yaşadığı sorunlar, kendi sözleriyle"),
                String(localized: "Ürünle ilgili gözlemler ve istekler"), String(localized: "Şaşırtıcı bulgular"),
                String(localized: "Doğrulanması gereken varsayımlar"),
            ],
            icon: "magnifyingglass"
        ),
        GalleryTemplate(
            id: NoteTemplateKind.interview.rawValue, category: .hiring, source: .builtIn(.interview),
            name: NoteTemplateKind.interview.displayName,
            summary: String(localized: "Adaylarla yapılan mülakatlar."),
            sections: [
                String(localized: "Adayın deneyimi"), String(localized: "Güçlü yanları"), String(localized: "Soru işaretleri"),
                String(localized: "Konuşulan koşullar (ücret, başlama tarihi)"),
            ],
            icon: "person.crop.rectangle"
        ),
        GalleryTemplate(
            id: "hiringDebrief", category: .hiring, source: .preset,
            name: String(localized: "Mülakat değerlendirmesi"),
            summary: String(localized: "Mülakatlardan sonra ekibin aday hakkında karar verdiği toplantı."),
            sections: [
                String(localized: "Her değerlendiricinin görüşü ve gerekçesi"),
                String(localized: "Ortak güçlü yanlar ve endişeler"), String(localized: "Karar ve sonraki adım"),
                String(localized: "Eksik kalan bilgiler"),
            ],
            icon: "checkmark.seal"
        ),
        GalleryTemplate(
            id: NoteTemplateKind.lecture.rawValue, category: .learning, source: .builtIn(.lecture),
            name: NoteTemplateKind.lecture.displayName,
            summary: String(localized: "Dersler, eğitimler ve sunumlar."),
            sections: [
                String(localized: "Ana kavramlar ve açıklamaları"), String(localized: "Örnekler"),
                String(localized: "Ödev ve sınav bilgileri"), String(localized: "Kapsamlı bir sözlük"),
            ],
            icon: "graduationcap"
        ),
    ]
}

/// Şablonları kategorilere ayırır (kategori sırası `TemplateCategory.allCases`, kategori içinde verilen sıra); şablonu
/// olmayan kategori atlanır. Saf fonksiyondur.
public func templateGallerySections(templates: [GalleryTemplate]) -> [TemplateGallerySection] {
    TemplateCategory.allCases.compactMap { (category: TemplateCategory) -> TemplateGallerySection? in
        let inCategory: [GalleryTemplate] = templates.filter { $0.category == category }
        return inCategory.isEmpty ? nil : TemplateGallerySection(category: category, templates: inCategory)
    }
}

/// Şablonun kendi şablon yönergesi olarak metni: öne çıkacak bölümler madde madde, arayüz dilinde (kullanıcı
/// düzenleyebilsin diye; not modeli yönergeyi her dilde anlar). Saf fonksiyondur.
public func templateInstructionsText(template: GalleryTemplate) -> String {
    ([String(localized: "Notta şunları öne çıkar:")] + template.sections.map { "- \($0)" }).joined(separator: "\n")
}

/// "Kopyasını düzenle": adı "<ad> (kopya)", yönergesi şablonun bölümleri. Saf fonksiyondur.
public func templateEditableCopy(template: GalleryTemplate) -> TemplateCopy {
    TemplateCopy(name: String(localized: "\(template.name) (kopya)"), instructions: templateInstructionsText(template: template))
}

/// Hazır şablonu seçmek: adı aynen, yönergesi şablonun bölümleri. Saf fonksiyondur.
public func templatePresetChoice(template: GalleryTemplate) -> TemplateCopy {
    TemplateCopy(name: template.name, instructions: templateInstructionsText(template: template))
}

/// Şablon şu an yeni notların varsayılanı mı: yerleşik tür seçili türse; hazır şablon "Kendi şablonum" seçiliyken
/// kendi şablonun adı ve metni onunkiyle aynıysa (kullanıcı düzenlediyse artık o şablon değildir). Saf fonksiyondur.
public func isGalleryTemplateSelected(template: GalleryTemplate, selectedKind: String, customName: String, customInstructions: String) -> Bool {
    switch template.source {
    case .builtIn(let kind):
        return kind.rawValue == selectedKind
    case .preset:
        let choice: TemplateCopy = templatePresetChoice(template: template)
        return selectedKind == NoteTemplateKind.custom.rawValue && customName == choice.name && customInstructions == choice.instructions
    }
}

/// Şablon menüsünde "Kendi şablonum"un adı: kullanıcı ad verdiyse (ör. galeriden kopyalayınca) o ad. Saf fonksiyondur.
public func customTemplateDisplayName(name: String) -> String {
    let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? NoteTemplateKind.custom.displayName : trimmed
}
