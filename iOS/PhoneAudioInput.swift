import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ayarlar › Kayıt ve diller › "Mikrofon": Otomatik, iPhone mikrofonu, AirPods / Bluetooth kulaklık, kablolu ya da USB
/// mikrofon. Seçim bu iPhone'da saklanır (eşitlenmez) ve süren kayda hemen uygulanır (`storeAudioInputChoice`).
struct PhoneAudioInputRow: View {
    @AppStorage(audioInputSettingKey) private var stored: String = ""

    var body: some View {
        LabeledContent {
            MenuPicker(title: "Mikrofon", selection: audioInputChoiceBinding(stored: stored), options: phoneAudioInputMenuOptions(), size: 15)
        } label: {
            PhoneSettingLabel(icon: "mic", title: Text("Mikrofon"))
                .accessibilityHidden(true)
        }
    }
}

/// Kayıt ekranındaki hızlı mikrofon seçimi: kullanılan girişin adı (bilinmiyorsa seçimin adı); dokununca seçenekler.
/// Seçim Ayarlar'dakiyle aynıdır ve kayıt durmadan uygulanır.
struct PhoneAudioInputChip: View {
    let active: ActiveAudioInput?
    let isEnabled: Bool
    @AppStorage(audioInputSettingKey) private var stored: String = ""

    var body: some View {
        let choice: AudioInputChoice = audioInputChoice(stored: stored)
        let name: String = active?.device.name ?? audioInputChoiceTitle(choice: choice)
        Menu {
            Picker(selection: audioInputChoiceBinding(stored: stored)) {
                ForEach(phoneAudioInputOptions, id: \.self) { (option: AudioInputOption) in
                    Label(audioInputOptionTitle(option: option), systemImage: audioInputChoiceSymbol(choice: option.choice))
                        .tag(option.choice)
                }
            } label: {
                Text("Mikrofon")
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: active.map { audioInputSymbol(kind: $0.device.kind) } ?? audioInputChoiceSymbol(choice: choice))
                Text(verbatim: name)
                    .lineLimit(1)
                Image(systemName: "chevron.down").appFont(size: 9, weight: .bold)
            }
            .appFont(size: 12, weight: .medium)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
        }
        .disabled(!isEnabled)
        .accessibilityLabel(Text("Mikrofon"))
        .accessibilityValue(Text(verbatim: name))
    }
}

/// Saklanan seçimin bağlaması: yazınca saklanır ve süren yakalama yeni girişe geçer.
@MainActor
private func audioInputChoiceBinding(stored: String) -> Binding<AudioInputChoice> {
    Binding<AudioInputChoice>(
        get: { audioInputChoice(stored: stored) },
        set: { (choice: AudioInputChoice) -> Void in storeAudioInputChoice(choice: choice, defaults: .standard) }
    )
}

private func phoneAudioInputMenuOptions() -> [MenuPickerOption<AudioInputChoice>] {
    phoneAudioInputOptions.map { (option: AudioInputOption) -> MenuPickerOption<AudioInputChoice> in
        MenuPickerOption(value: option.choice, label: Text(verbatim: audioInputOptionTitle(option: option)))
    }
}
