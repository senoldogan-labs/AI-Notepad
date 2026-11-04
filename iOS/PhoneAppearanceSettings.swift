import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit

/// Ayarlar › Görünüm: canlı önizleme, tema kartları, vurgu rengi, yazı tipi, arayüz yazı boyutu, okuma metni boyutu,
/// satır aralığı ve alt boşluk (Mac'teki Görünüm ayarlarıyla aynı seçenekler ve anahtarlar). Değişiklikler anında tüm sekmelere uygulanır;
/// iPhone'un yazı boyutu (Dinamik Yazı) bu ayarların üstüne çarpılır.
struct PhoneAppearanceScreen: View {
    @AppStorage(PhoneSettingsKey.theme) private var theme: String = AppTheme.system.rawValue
    @AppStorage(PhoneSettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(PhoneSettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue
    @AppStorage(PhoneSettingsKey.uiScale) private var uiScale: Double = PanelAppearance.standard.uiScale
    @AppStorage(PhoneSettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(PhoneSettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(PhoneSettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        List {
            Section {
                PhoneAppearancePreview()
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            Section("Tema") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 12) {
                    ForEach(AppTheme.allCases, id: \.self) { (item: AppTheme) in
                        ThemeSwatch(theme: item, isSelected: theme == item.rawValue, accent: appearance.accent.color) { theme = item.rawValue }
                    }
                }
                .padding(.vertical, 6)
            }
            Section {
                PhoneCaptionedRow(caption: Text("Vurgu rengi düğmelerde, ölçerlerde ve seçili sekmede kullanılır.")) {
                    PhoneAccentPicker(selection: $accent)
                }
                NavigationLink {
                    PhoneFontPicker(selection: $fontDesign)
                } label: {
                    LabeledContent("Yazı tipi", value: fontChoiceName(choice: AppFontChoice.parse(storage: fontDesign) ?? PanelAppearance.standard.fontChoice))
                }
            }
            Section {
                PhoneSettingSlider(
                    title: Text("Arayüz yazısı: %\(percent(value: uiScale, reference: 1))"), value: $uiScale, range: AppearanceRange.uiScale, step: 0.05,
                    minSymbol: "textformat.size.smaller", maxSymbol: "textformat.size.larger"
                )
                PhoneSettingSlider(
                    title: Text("Okuma metni: %\(percent(value: textSize, reference: PanelAppearance.standard.textSize))"), value: $textSize,
                    range: AppearanceRange.textSize, step: 1, minSymbol: "textformat.size.smaller", maxSymbol: "textformat.size.larger"
                )
                PhoneSettingSlider(
                    title: Text("Satır aralığı: \(Int(lineSpacing))"), value: $lineSpacing, range: AppearanceRange.lineSpacing, step: 1,
                    minSymbol: "arrow.down.right.and.arrow.up.left", maxSymbol: "arrow.up.left.and.arrow.down.right"
                )
                // Mac'teki "Alt boşluk": kayıt sırasında canlı metnin son satırı ile alttaki düğmeler arasındaki boşluk.
                PhoneSettingSlider(
                    title: Text("Alt boşluk: \(Int(bottomSpacing)) pt"), value: $bottomSpacing, range: AppearanceRange.bottomSpacing, step: 4,
                    minSymbol: "arrow.down.right.and.arrow.up.left", maxSymbol: "arrow.up.left.and.arrow.down.right"
                )
            } header: {
                Text("Boyut")
            } footer: {
                Text("Arayüz yazısı düğmeleri ve listeleri, okuma metni notu ve transkripti değiştirir; alt boşluk kayıttaki canlı metnin altında kalır.")
            }
            Section {
                Button("Görünümü varsayılana döndür") {
                    resetPhoneAppearance(defaults: .standard)
                }
            }
        }
        .navigationTitle("Görünüm")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Değerin başvuru değerine oranı, yüzde olarak. Saf fonksiyondur.
    private func percent(value: Double, reference: Double) -> Int {
        Int((value / reference * 100).rounded())
    }
}

/// Seçilen görünümle küçük bir toplantı notu: başlık ve etiket arayüz yazısıyla, özet okuma metniyle, görev vurgu
/// rengiyle. Ayar değiştikçe anında güncellenir.
private struct PhoneAppearancePreview: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .frame(width: 28, height: 28)
                    .background(appearance.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Haftalık ürün toplantısı")
                        .appFont(size: 15, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text("Bugün · 32 dk")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
            }
            Text("Ekip yeni sürümün tarihini 14 Kasım olarak belirledi; tasarım incelemesi perşembe yapılacak ve geri bildirimler cuma toplanacak.")
                .readingText(size: 16, weight: .regular, lineSpacing: 4)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "circle")
                    .appFont(size: 18, weight: .regular)
                    .foregroundStyle(appearance.accent.color)
                Text("Sürüm notlarını perşembeye kadar hazırla")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Görünüm önizlemesi"))
    }
}

/// Ayar kaydırıcısı: başlıkta güncel değer, iki ucunda küçük ve büyük ucu gösteren soluk simgeler.
private struct PhoneSettingSlider: View {
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minSymbol: String
    let maxSymbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title.monospacedDigit()
            HStack(spacing: 10) {
                Image(systemName: minSymbol).foregroundStyle(Theme.muted).accessibilityHidden(true)
                Slider(value: $value, in: range, step: step) { title }
                Image(systemName: maxSymbol).foregroundStyle(Theme.muted).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Vurgu rengi seçimi: beş renk yuvarlağı yan yana; seçilenin çevresinde halka. Mac'teki ayarla aynı renkler.
struct PhoneAccentPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack {
            Text("Vurgu rengi")
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                ForEach(PanelAccent.allCases, id: \.self) { (accent: PanelAccent) in
                    let isSelected: Bool = (PanelAccent(rawValue: selection) ?? PanelAppearance.standard.accent) == accent
                    Button {
                        selection = accent.rawValue
                    } label: {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 24, height: 24)
                            .padding(3)
                            .overlay(Circle().strokeBorder(isSelected ? accent.color : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: accent.displayName))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }
}

/// Yazı tipi seçimi: uygulamanın tasarımları (Inter ve SF tasarımları), önerilen aileler ve iPhone'daki tüm aileler
/// (aranabilir). Her satır kendi yazı tipiyle yazılır; seçilende onay işareti.
private struct PhoneFontPicker: View {
    @Binding var selection: String
    @State private var query: String = ""

    var body: some View {
        let current: AppFontChoice = AppFontChoice.parse(storage: selection) ?? PanelAppearance.standard.fontChoice
        let available: [String] = UIFont.familyNames.sorted()
        let suggested: [String] = suggestedFontFamilies(available: Set(available), current: current)
        let others: [String] = available.filter { (family: String) -> Bool in
            !suggested.contains(family) && (query.isEmpty || family.localizedCaseInsensitiveContains(query))
        }
        List {
            if query.isEmpty {
                Section {
                    ForEach(PanelFontDesign.allCases, id: \.self) { (design: PanelFontDesign) in
                        row(choice: .design(design), current: current)
                    }
                }
                Section("Önerilen") {
                    ForEach(suggested, id: \.self) { (family: String) in
                        row(choice: .installed(family: family), current: current)
                    }
                }
            }
            Section("Tüm yazı tipleri") {
                ForEach(others, id: \.self) { (family: String) in
                    row(choice: .installed(family: family), current: current)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Yazı tipi ara"))
        .navigationTitle("Yazı tipi")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(choice: AppFontChoice, current: AppFontChoice) -> some View {
        Button {
            selection = choice.storageValue
        } label: {
            HStack {
                // Kökteki sistem tasarımı (ör. tırnaklı) özel yazı tiplerini de sistem yazısına çevirirdi: her satır kendi
                // yazı tipini göstersin.
                Text(verbatim: fontChoiceName(choice: choice))
                    .font(fontPreview(choice: choice))
                    .fontDesign(nil)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if choice == current {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(choice == current ? .isSelected : [])
    }
}

/// Yazı tipi seçiminin adı: tasarımın Ayarlar'daki adı ya da ailenin adı. Saf fonksiyondur.
func fontChoiceName(choice: AppFontChoice) -> String {
    switch choice {
    case .design(let design): design.displayName
    case .installed(let family): family
    }
}

/// Seçimin kendi yazı tipiyle satır yazısı (17 pt, normal).
private func fontPreview(choice: AppFontChoice) -> Font {
    let standard: PanelAppearance = .standard
    return PanelAppearance(
        fontChoice: choice, uiScale: standard.uiScale, textSize: standard.textSize, lineSpacing: standard.lineSpacing,
        bottomSpacing: standard.bottomSpacing, accent: standard.accent, surface: standard.surface, surfaceOpacity: standard.surfaceOpacity
    )
    .font(size: 17, weight: .regular)
}
