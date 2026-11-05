import SwiftUI

/// Açılır seçimin bir seçeneği: değer ve menüde (ve seçiliyken düğmede) görünen ad.
public struct MenuPickerOption<Value: Hashable> {
    public let value: Value
    public let label: Text

    public init(value: Value, label: Text) {
        self.value = value
        self.label = label
    }
}

/// Açılır seçim (iPhone ayar satırları): seçili değer satırın geri kalanı gibi uygulamanın yazı tipinde (Ayarlar ›
/// Görünüm'deki aile ve ölçek), vurgu renginde, yanında küçük `chevron.up.chevron.down`; menüde seçili değer işaretli.
/// Sistemin menü biçimli `Picker`'ı değeri hep sistem yazısında ve daha büyük çiziyordu. VoiceOver ad ve değeri okur.
public struct MenuPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [MenuPickerOption<Value>]
    /// Değerin punto değeri (satır etiketiyle aynı; arayüz ölçeğiyle çarpılır).
    let size: CGFloat

    public init(title: LocalizedStringKey, selection: Binding<Value>, options: [MenuPickerOption<Value>], size: CGFloat) {
        self.title = title
        _selection = selection
        self.options = options
        self.size = size
    }

    public var body: some View {
        let selected: Text = menuPickerSelectedLabel(options: options, selection: selection)
        Menu {
            Picker(selection: $selection) {
                ForEach(Array(options.enumerated()), id: \.offset) { (item: (offset: Int, element: MenuPickerOption<Value>)) in
                    item.element.label.tag(item.element.value)
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MenuPickerLabel(value: selected, size: size)
        }
        // Düz düğme: Mac'te de çerçeveli açılır düğme yerine yalnız değer ve ok görünür.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(Text(title))
        .accessibilityValue(selected)
    }
}

/// Ayar satırı: solda ad (satırın ortam yazısında), sağda açılır seçim; satır etiketiyle aynı punto (15). VoiceOver adı
/// bir kez, seçimle birlikte okur.
public struct MenuPickerRow<Value: Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [MenuPickerOption<Value>]

    public init(title: LocalizedStringKey, selection: Binding<Value>, options: [MenuPickerOption<Value>]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    public var body: some View {
        LabeledContent {
            MenuPicker(title: title, selection: $selection, options: options, size: 15)
        } label: {
            Text(title)
                .accessibilityHidden(true)
        }
    }
}

/// Açılır seçimin düğmesi: seçili değer (uygulamanın yazı tipinde, vurgu renginde) ve küçük çift ok.
public struct MenuPickerLabel: View {
    let value: Text
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(value: Text, size: CGFloat) {
        self.value = value
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 5) {
            value
                .appFont(size: size, weight: .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .appFont(size: size * 0.7, weight: .semibold)
                .accessibilityHidden(true)
        }
        .foregroundStyle(appearance.accent.color)
        .contentShape(Rectangle())
    }
}

/// Seçili seçeneğin adı; seçim seçeneklerde yoksa (ör. eski bir ayar değeri) tire. Saf fonksiyondur.
func menuPickerSelectedLabel<Value: Hashable>(options: [MenuPickerOption<Value>], selection: Value) -> Text {
    options.first { $0.value == selection }?.label ?? Text(verbatim: "–")
}
