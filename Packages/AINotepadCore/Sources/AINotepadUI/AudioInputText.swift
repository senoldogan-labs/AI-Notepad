import AINotepadCore
import Foundation

// Mikrofon seçiminin arayüz metinleri ve simgeleri (Mac ve iPhone ortak): Ayarlar › Kayıt ve diller'deki "Mikrofon"
// satırı, kayıt ekranındaki hızlı seçim ve giriş değişince çıkan kısa bildirim.

/// Bildirimin ekranda kalma süresi (sn).
public let audioInputNoticeSec: Double = 8

/// Seçim listesindeki bir seçenek: Mac'te saklanan cihaz bağlı değilse de listede kalır (adının yanında "bağlı değil").
public struct AudioInputOption: Hashable, Sendable {
    public let choice: AudioInputChoice
    public let isConnected: Bool

    public init(choice: AudioInputChoice, isConnected: Bool) {
        self.choice = choice
        self.isConnected = isConnected
    }
}

/// iPhone'un seçenekleri: türle seçilir (hangi AirPods ya da USB mikrofon bağlıysa o). Bluetooth girişleri iOS'ta ancak
/// kulaklık mikrofonu açıkken listelenir; bu yüzden bağlı olup olmadıkları burada bilinmez, hepsi seçilebilir.
public let phoneAudioInputOptions: [AudioInputOption] = [
    AudioInputOption(choice: .automatic, isConnected: true),
    AudioInputOption(choice: .builtIn, isConnected: true),
    AudioInputOption(choice: .bluetoothHeadset, isConnected: true),
    AudioInputOption(choice: .wiredOrUSB, isConnected: true),
]

/// Mac'in seçenekleri: "Otomatik", bağlı giriş cihazları (sistemin sırasıyla) ve bağlı değilse saklanan cihaz. Saf
/// fonksiyondur.
public func macAudioInputOptions(devices: [AudioInputDevice], stored: AudioInputChoice) -> [AudioInputOption] {
    let connected: [AudioInputOption] = devices.map { (device: AudioInputDevice) -> AudioInputOption in
        AudioInputOption(choice: .device(id: device.id, name: device.name), isConnected: true)
    }
    let missing: [AudioInputOption]
    if case .device(let id, _) = stored, !devices.contains(where: { $0.id == id }) {
        missing = [AudioInputOption(choice: stored, isConnected: false)]
    } else {
        missing = []
    }
    return [AudioInputOption(choice: .automatic, isConnected: true)] + connected + missing
}

/// Seçimin adı.
public func audioInputChoiceTitle(choice: AudioInputChoice) -> String {
    switch choice {
    case .automatic:
        String(localized: "Otomatik")
    case .builtIn:
        #if os(iOS)
        String(localized: "iPhone mikrofonu")
        #else
        String(localized: "Yerleşik mikrofon")
        #endif
    case .bluetoothHeadset:
        String(localized: "AirPods / Bluetooth kulaklık")
    case .wiredOrUSB:
        String(localized: "Kablolu ya da USB mikrofon")
    case .device(_, let name):
        name
    }
}

/// Seçeneğin listedeki adı: bağlı değilse belirtilir.
public func audioInputOptionTitle(option: AudioInputOption) -> String {
    let title: String = audioInputChoiceTitle(choice: option.choice)
    return option.isConnected ? title : String(localized: "\(title) (bağlı değil)")
}

/// Giriş türünün simgesi (SF Symbols).
public func audioInputSymbol(kind: AudioInputKind) -> String {
    switch kind {
    case .builtIn: "mic"
    case .bluetooth: "airpods"
    case .wired: "headphones"
    case .usb: "cable.connector"
    case .continuity: "iphone"
    case .virtual: "waveform"
    case .other: "mic"
    }
}

/// Seçimin simgesi (kayıt ekranındaki hızlı seçim).
public func audioInputChoiceSymbol(choice: AudioInputChoice) -> String {
    switch choice {
    case .automatic: "wand.and.stars"
    case .builtIn: "mic"
    case .bluetoothHeadset: "airpods"
    case .wiredOrUSB: "cable.connector"
    case .device: "mic"
    }
}

/// Kayıt sürerken giriş değişince gösterilen kısa bildirimin metni.
public func audioInputNoticeText(notice: AudioInputNotice) -> String {
    switch notice {
    case .switched(let device):
        String(localized: "Mikrofon değişti: \(device.name). Kayıt sürüyor.")
    case .choiceUnavailable(let choice, let device):
        String(localized: "\(audioInputChoiceTitle(choice: choice)) bağlı değil; kayıt \(device.name) ile sürüyor.")
    }
}

/// "Otomatik"in ne yaptığı (Ayarlar'daki açıklama).
public func automaticAudioInputHelp() -> String {
    #if os(iOS)
    String(localized: "Otomatik: odadaki herkesi duymak için iPhone mikrofonu; USB mikrofon takılıysa o. AirPods müzik ve ses için kullanılır, mikrofonu yalnız takanı duyduğu için kendiliğinden seçilmez. Takıp çıkarmak kaydı durdurmaz.")
    #else
    String(localized: "Otomatik: Mac'in ses ayarlarındaki giriş. Yüz yüze kayıtta Bluetooth kulaklık mikrofonu yerine Mac'in mikrofonu kullanılır (kulaklık yalnız takanı duyar). Takıp çıkarmak kaydı durdurmaz.")
    #endif
}
