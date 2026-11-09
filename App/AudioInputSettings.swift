import AINotepadCore
import AINotepadUI
import SwiftUI
import os

private let audioInputsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AudioInputs")

/// Bu Mac'in ses cihazları (mikrofon seçimi için): bağlı girişler, sistemin varsayılan girişi ve çıkışın hoparlör mü
/// kulaklık mı olduğu. Cihaz takılıp çıkarılınca ve varsayılanlar değişince tazelenir (uygulama boyunca yaşar).
@MainActor
@Observable
final class MacAudioInputs {
    private(set) var devices: [AudioInputDevice] = []
    private(set) var systemDefault: AudioInputDevice?
    private(set) var outputKind: AudioOutputKind = .unknown
    @ObservationIgnored private var observer: MacAudioHardwareObserver?

    init() {
        refresh()
        let observer: MacAudioHardwareObserver = MacAudioHardwareObserver { [weak self] (_: AudioRouteChange) -> Void in
            self?.refresh()
        }
        do {
            try observer.start()
            self.observer = observer
        } catch {
            audioInputsLogger.error("Ses cihazı değişiklikleri izlenemiyor; liste Ayarlar açılınca tazelenir, hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Listeyi Core Audio'dan yeniden okur. Okunamazsa loglanır ve eski liste kalır.
    func refresh() {
        do {
            devices = try macInputDevices().map(\.device)
            systemDefault = try macDefaultInput()?.device
            outputKind = try macDefaultOutputKind()
        } catch {
            audioInputsLogger.error("Ses cihazları okunamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Mikrofon seçimi menüsü (Ayarlar › Kayıt ve diller, Sesle yazma): "Otomatik" ve bağlı girişler (sistemin girişinin
/// adı satırın açıklamasında: menü kısa kalsın); seçim saklanır ve süren kayda hemen uygulanır (`storeAudioInputChoice`).
struct AudioInputSettingsMenu: View {
    let inputs: MacAudioInputs
    @AppStorage(audioInputSettingKey) private var stored: String = ""

    var body: some View {
        let choice: AudioInputChoice = audioInputChoice(stored: stored)
        SettingsMenu(
            selection: Binding<AudioInputChoice>(
                get: { choice },
                set: { (newChoice: AudioInputChoice) -> Void in storeAudioInputChoice(choice: newChoice, defaults: .standard) }
            ),
            options: macAudioInputOptions(devices: inputs.devices, stored: choice).map { (option: AudioInputOption) -> (AudioInputChoice, Text) in
                (option.choice, Text(verbatim: audioInputOptionTitle(option: option)))
            }
        )
        .onAppear { inputs.refresh() }
    }
}

/// Mikrofon seçiminin menü öğeleri (menü çubuğu ve ana penceredeki kayıt çubuğu): seçili olan işaretli.
struct AudioInputMenuItems: View {
    let inputs: MacAudioInputs
    @AppStorage(audioInputSettingKey) private var stored: String = ""

    var body: some View {
        let choice: AudioInputChoice = audioInputChoice(stored: stored)
        Picker(selection: Binding<AudioInputChoice>(
            get: { choice },
            set: { (newChoice: AudioInputChoice) -> Void in storeAudioInputChoice(choice: newChoice, defaults: .standard) }
        )) {
            ForEach(macAudioInputOptions(devices: inputs.devices, stored: choice), id: \.self) { (option: AudioInputOption) in
                Text(verbatim: macAudioInputOptionTitle(option: option, systemDefault: inputs.systemDefault)).tag(option.choice)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Mac'teki seçeneğin adı: "Otomatik" sistemin şu anki girişini de söyler.
func macAudioInputOptionTitle(option: AudioInputOption, systemDefault: AudioInputDevice?) -> String {
    guard option.choice == .automatic, let systemDefault else {
        return audioInputOptionTitle(option: option)
    }
    return String(localized: "Otomatik (\(systemDefault.name))")
}

/// Kayıt ayarlarındaki "Mikrofon" satırı: seçim, "Otomatik"in kuralı ve çıkış hoparlörse yankı açıklaması.
struct AudioInputSettingsRow: View {
    let inputs: MacAudioInputs
    @AppStorage(audioInputSettingKey) private var stored: String = ""

    var body: some View {
        SettingsRow(icon: "mic", title: Text("Mikrofon")) {
            SettingsMoreText(
                summary: Text("Kayıtta ve sesle yazmada kullanılan giriş."),
                details: Text(verbatim: automaticAudioInputHelp())
            )
            if audioInputChoice(stored: stored) == .automatic, let systemDefault = inputs.systemDefault {
                Text("Şu an: \(systemDefault.name)")
            }
            if inputs.outputKind == .speakers {
                // Hoparlörden çalan görüşme sesi mikrofona da girer: yinelenen "Sen" satırlarını yankı süzgeci ayıklar.
                NoticeText("Ses hoparlörden çalıyor: mikrofon karşı tarafı da duyar. Yinelenen satırları yankı süzgeci ayıklar; en temiz metin için kulaklık kullan.", severity: .info)
            }
        } control: {
            AudioInputSettingsMenu(inputs: inputs)
        }
    }
}
