import Foundation
import os

// Mikrofon girişinin seçimi (Mac ve iPhone ortak, saf). Kullanıcı Ayarlar › Kayıt ve diller'de ya da kayıt ekranında
// "Otomatik"i ya da belirli bir girişi seçer; yakalama (`MicrophoneCapture`) her başlatmada ve her cihaz değişikliğinde
// `selectAudioInput` ile hangi girişi kullanacağını bulur. Seçilen giriş yoksa (AirPods çıkarıldı, USB mikrofon
// takılı değil) kayıt durmaz: "Otomatik" kuralıyla sürer ve kullanıcıya kısa bir bildirim gösterilir
// (`audioInputChangeNotice`). Tasarım ve kaynaklar: docs/superpowers/specs/2026-11-09-audio-input-selection.md.

/// Bir ses girişinin türü (arayüzdeki simge ve "Otomatik" kuralı buna bakar).
public enum AudioInputKind: String, Sendable, Codable, CaseIterable {
    /// iPhone'un ya da Mac'in yerleşik mikrofonu.
    case builtIn
    /// Bluetooth kulaklık mikrofonu (AirPods, HFP kulaklıklar).
    case bluetooth
    /// Kablolu kulaklık mikrofonu, hat girişi ya da Thunderbolt/PCI ses arayüzü.
    case wired
    /// USB / USB-C mikrofon ya da kulaklık.
    case usb
    /// Süreklilik mikrofonu (iPhone'u Mac'in mikrofonu olarak kullanmak).
    case continuity
    /// Sanal ya da toplu cihaz (ör. BlackHole, Loopback, görüşme uygulamalarının sanal cihazları).
    case virtual
    /// Diğerleri (araç sesi, AirPlay, tanınmayan bağlantı).
    case other
}

/// Bağlı bir ses girişi.
public struct AudioInputDevice: Hashable, Sendable {
    /// Kalıcı kimlik: iPhone'da ses yolu girişinin UID'si, Mac'te Core Audio cihaz UID'si.
    public let id: String
    /// Cihazın sistemdeki adı (ör. "AirPods Pro", "MacBook Pro Mikrofonu").
    public let name: String
    public let kind: AudioInputKind

    public init(id: String, name: String, kind: AudioInputKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// Kullanıcının mikrofon seçimi (cihaza özgü; eşitlenmez). iPhone türle seçer (hangi AirPods bağlıysa o), Mac belirli
/// cihazla (`device`).
public enum AudioInputChoice: Hashable, Sendable, Codable {
    /// Otomatik: Mac'te sistemin varsayılan girişi, iPhone'da ses yolu. Odadaki toplantıda Bluetooth kulaklık mikrofonu
    /// kendiliğinden seçilmez (yalnız takanı duyar, sesi dar banda düşürür): yerleşik mikrofon kullanılır.
    case automatic
    /// Yerleşik mikrofon.
    case builtIn
    /// Bağlı Bluetooth kulaklık (AirPods).
    case bluetoothHeadset
    /// Kablolu ya da USB mikrofon/kulaklık.
    case wiredOrUSB
    /// Belirli bir cihaz (Mac); `name` cihaz bağlı değilken arayüzde gösterilir.
    case device(id: String, name: String)
}

/// Mikrofonun neyi kaydettiği: "Otomatik" kuralı buna göre değişir.
public enum AudioInputContext: Sendable, Equatable {
    /// Odadaki herkes (yüz yüze toplantı; iPhone'da her toplantı kaydı).
    case room
    /// Yalnızca kullanıcının sesi (Mac'te çevrimiçi görüşme, sesle yazma, Sor'a sesle soru).
    case personal
}

/// Yakalamanın her (yeniden) başlatmada sorduğu seçim ve bağlam.
public struct AudioInputRequest: Equatable, Sendable {
    public let choice: AudioInputChoice
    public let context: AudioInputContext

    public init(choice: AudioInputChoice, context: AudioInputContext) {
        self.choice = choice
        self.context = context
    }
}

/// `selectAudioInput` sonucu.
public struct AudioInputSelection: Equatable, Sendable {
    /// Kullanılacak giriş; nil ise seçim sistemindir (Mac'te varsayılan giriş, iPhone'da ses yolu).
    public let device: AudioInputDevice?
    /// Seçilen giriş bağlı değil: "Otomatik" kuralıyla sürülüyor (kullanıcıya söylenir). Seçim kullanılabiliyorsa nil.
    public let unavailableChoice: AudioInputChoice?

    public init(device: AudioInputDevice?, unavailableChoice: AudioInputChoice?) {
        self.device = device
        self.unavailableChoice = unavailableChoice
    }
}

/// Kullanılan giriş: kayıt ekranı adını gösterir, değişince kısa bildirim çıkar.
public struct ActiveAudioInput: Equatable, Sendable {
    public let device: AudioInputDevice
    /// Seçilen giriş bağlı değil, bunun yerine `device` kullanılıyor.
    public let unavailableChoice: AudioInputChoice?

    public init(device: AudioInputDevice, unavailableChoice: AudioInputChoice?) {
        self.device = device
        self.unavailableChoice = unavailableChoice
    }
}

/// Kayıt ekranındaki mikrofon bildirimi.
public enum AudioInputNotice: Equatable, Sendable {
    /// Giriş değişti (cihaz takıldı/çıkarıldı ya da kullanıcı seçti); kayıt yeni girişle sürüyor. Kısa süre görünür.
    case switched(to: AudioInputDevice)
    /// Seçilen giriş bağlı değil ya da kurulamadı; kayıt `using` ile sürüyor. Durum sürdükçe görünür.
    case choiceUnavailable(choice: AudioInputChoice, using: AudioInputDevice)
    /// Saklanan mikrofon seçimi okunamadı ve silindi; "Otomatik" kullanılıyor. Kayıt başında bir kez, kısa süre görünür.
    case storedChoiceUnreadable
}

/// Saklanan mikrofon seçiminin okunuşu: okunamayan değer "Otomatik"ten ayrılır (kullanıcıya bir kez söylenir).
public enum AudioInputChoiceReading: Equatable, Sendable {
    case choice(AudioInputChoice)
    case unreadable
}

/// Ses yolu değişikliğinin nedeni (iPhone `AVAudioSession.RouteChangeReason`, Mac cihaz listesi ve varsayılan giriş
/// bildirimleri bunlara çevrilir).
public enum AudioRouteChange: Sendable, Equatable {
    /// Yeni bir giriş/çıkış bağlandı (kulaklık takıldı, AirPods bağlandı, USB mikrofon).
    case deviceAdded
    /// Bir cihaz çıkarıldı ya da bağlantısı koptu.
    case deviceRemoved
    /// Mac: sistemin varsayılan girişi değişti.
    case defaultChanged
    /// Kullanıcı mikrofon seçimini değiştirdi.
    case choiceChanged
    /// Kategori, geçersiz kılma, uyanma ya da başka bir nedenle değişti (kendi oturum değişikliğimiz dahil).
    case other
}

/// Yeniden kurma sürerken gelen değişiklikler sıraya alınır, kurma bitince bir kez değerlendirilir: anlamlı olan
/// (`other` dışı) korunur, `other` onun yerine geçmez. Saf fonksiyondur.
public func mergedRouteChange(pending: AudioRouteChange?, new: AudioRouteChange) -> AudioRouteChange {
    guard let pending, new == .other else {
        return new
    }
    return pending
}

/// "Mikrofon" ayarının anahtarı (Mac ve iPhone; cihaza özgüdür, eşitlenmez).
public let audioInputSettingKey: String = "audioInputChoice"

private let audioInputLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AudioInputSelection")

/// Mikrofon seçimi değişti (`storeAudioInputChoice`): süren yakalamalar (kayıt, sesle yazma) yeni girişe geçer.
public let audioInputChoiceDidChange: Notification.Name = Notification.Name("AudioInputChoiceDidChange")

/// Saklanan mikrofon seçimi; hiç seçilmediyse ya da okunamıyorsa "Otomatik" (okunamayan değer kayıt başında
/// `resetUnreadableAudioInputChoice` ile bir kez bildirilip silinir).
public func storedAudioInputChoice(defaults: UserDefaults) -> AudioInputChoice {
    audioInputChoice(stored: defaults.string(forKey: audioInputSettingKey) ?? "")
}

/// Ayarın saklanan metninden seçim (`@AppStorage` değeri; arayüz her çizimde okur, bu yüzden loglamaz): boşsa ya da
/// okunamıyorsa "Otomatik". Saf fonksiyondur.
public func audioInputChoice(stored: String) -> AudioInputChoice {
    switch readAudioInputChoice(stored: stored) {
    case .choice(let choice):
        choice
    case .unreadable:
        .automatic
    }
}

/// Saklanan metnin okunuşu: boşsa "Otomatik", çözülemiyorsa `unreadable`. Saf fonksiyondur.
public func readAudioInputChoice(stored: String) -> AudioInputChoiceReading {
    guard !stored.isEmpty else {
        return .choice(.automatic)
    }
    do {
        return .choice(try decodeAudioInputChoice(stored: stored))
    } catch {
        return .unreadable
    }
}

/// Kayıt başında: saklanan seçim okunamıyorsa (bozuk ya da eski biçim) bir kez loglanır ve silinir; true dönerse kayıt
/// ekranı bunu bir kez söyler ("Otomatik" kullanılıyor). Okunabiliyorsa hiçbir şey yapmaz.
public func resetUnreadableAudioInputChoice(defaults: UserDefaults) -> Bool {
    guard let stored = defaults.string(forKey: audioInputSettingKey), readAudioInputChoice(stored: stored) == .unreadable else {
        return false
    }
    audioInputLogger.error("Saklanan mikrofon seçimi okunamadı, silindi, Otomatik kullanılıyor, uzunluk: \(stored.count, privacy: .public)")
    defaults.removeObject(forKey: audioInputSettingKey)
    return true
}

/// Yalnızca kullanıcının sesini alan yakalamanın isteği (sesle yazma, Sor'a sesle soru): saklanan seçim, kişisel bağlam.
@MainActor
public func personalAudioInputRequest() -> AudioInputRequest {
    AudioInputRequest(choice: storedAudioInputChoice(defaults: .standard), context: .personal)
}

/// Odadaki herkesi kaydeden yakalamanın isteği (iPhone'da toplantı kaydı): saklanan seçim, oda bağlamı.
@MainActor
public func roomAudioInputRequest() -> AudioInputRequest {
    AudioInputRequest(choice: storedAudioInputChoice(defaults: .standard), context: .room)
}

/// Mikrofon seçimini saklar ve `audioInputChoiceDidChange` yayınlar (süren yakalama yeni girişe geçer).
@MainActor
public func storeAudioInputChoice(choice: AudioInputChoice, defaults: UserDefaults) {
    defaults.set(encodeAudioInputChoice(choice: choice), forKey: audioInputSettingKey)
    NotificationCenter.default.post(name: audioInputChoiceDidChange, object: nil)
}

/// Seçimi saklanacak metne çevirir (JSON). Saf fonksiyondur.
public func encodeAudioInputChoice(choice: AudioInputChoice) -> String {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    do {
        let data: Data = try encoder.encode(choice)
        guard let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("JSONEncoder UTF-8 dışı veri üretti")
        }
        return text
    } catch {
        // Sentezlenmiş Codable bu enum için hata vermez; verirse programlama hatasıdır.
        preconditionFailure("Mikrofon seçimi kodlanamadı: \(error)")
    }
}

/// Saklanan metni seçime çevirir. Saf fonksiyondur.
public func decodeAudioInputChoice(stored: String) throws -> AudioInputChoice {
    try JSONDecoder().decode(AudioInputChoice.self, from: Data(stored.utf8))
}

/// Seçim bu girişe uyuyor mu. Saf fonksiyondur.
public func audioInputMatches(choice: AudioInputChoice, device: AudioInputDevice) -> Bool {
    switch choice {
    case .automatic:
        false
    case .builtIn:
        device.kind == .builtIn
    case .bluetoothHeadset:
        device.kind == .bluetooth
    case .wiredOrUSB:
        device.kind == .wired || device.kind == .usb
    case .device(let id, _):
        device.id == id
    }
}

/// Seçim Bluetooth kulaklık mikrofonu mu istiyor (iPhone: ses oturumu HFP'ye ve AirPods yüksek kaliteli kayda izin
/// vermeli; izin verilmezse Bluetooth girişleri listede bile görünmez). Saf fonksiyondur.
public func needsBluetoothInput(choice: AudioInputChoice) -> Bool {
    choice == .bluetoothHeadset
}

/// Kullanılacak girişi seçer. Kural:
/// 1. Belirli bir giriş seçildiyse ve bağlıysa o.
/// 2. Seçilen giriş bağlı değilse "Otomatik" uygulanır ve bu `unavailableChoice` ile bildirilir (kayıt durmaz).
/// 3. "Otomatik": seçim sistemindir (`device` nil); yalnızca odadaki toplantıda sistemin girişi Bluetooth kulaklıksa
///    yerleşik mikrofon seçilir (kulaklık mikrofonu yalnız takanı duyar ve HFP sesi dar banda düşürür). Yerleşik
///    mikrofon yoksa (ör. Mac mini) sistemin girişi kalır.
/// Saf fonksiyondur.
public func selectAudioInput(request: AudioInputRequest, available: [AudioInputDevice], systemDefault: AudioInputDevice?) -> AudioInputSelection {
    if request.choice != .automatic {
        if let match = preferredMatch(choice: request.choice, available: available, systemDefault: systemDefault) {
            return AudioInputSelection(device: match, unavailableChoice: nil)
        }
        let automatic: AudioInputSelection = selectAudioInput(
            request: AudioInputRequest(choice: .automatic, context: request.context), available: available, systemDefault: systemDefault
        )
        return AudioInputSelection(device: automatic.device, unavailableChoice: request.choice)
    }
    guard request.context == .room, systemDefault?.kind == .bluetooth,
          let builtIn = available.first(where: { $0.kind == .builtIn }) else {
        return AudioInputSelection(device: nil, unavailableChoice: nil)
    }
    return AudioInputSelection(device: builtIn, unavailableChoice: nil)
}

/// Seçime uyan girişlerden sistemin şu anki girişi (uyuyorsa) ya da ilki: türle seçimde (ör. iki USB mikrofon) sistemin
/// seçtiği değiştirilmez.
private func preferredMatch(choice: AudioInputChoice, available: [AudioInputDevice], systemDefault: AudioInputDevice?) -> AudioInputDevice? {
    if let systemDefault, audioInputMatches(choice: choice, device: systemDefault), available.contains(systemDefault) {
        return systemDefault
    }
    return available.first { audioInputMatches(choice: choice, device: $0) }
}

/// Seçimin gerçekte kullanılacak girişi: seçim sistemindeyse sistemin girişi. Saf fonksiyondur.
public func resolvedAudioInput(selection: AudioInputSelection, systemDefault: AudioInputDevice?) -> AudioInputDevice? {
    selection.device ?? systemDefault
}

/// Ses yolu değişince yakalama yeniden kurulmalı mı: yalnız cihaz takıldı/çıkarıldı ya da (Mac) varsayılan giriş
/// değiştiyse ve hedef giriş şu an kullanılandan farklıysa. Kendi oturum değişikliğimizin bildirimi (`other`) ve hedefin
/// zaten kullanıldığı durum yeniden kurmaz: kurma döngüsü olmaz. Saf fonksiyondur.
public func shouldReselectInput(change: AudioRouteChange, target: AudioInputDevice?, current: AudioInputDevice?) -> Bool {
    guard change != .other, let target else {
        return false
    }
    return target.id != current?.id
}

/// Kurulacak girişler sırasıyla: önce hedef (seçimin sonucu), o kurulamazsa (cihaz açılmadı, motor başlamadı, format
/// tutmadı) sistemin varsayılan girişi. Varsayılana düşmek seçimi "kullanılamıyor" yapar (kullanıcıya söylenir);
/// "Otomatik"te seçim yoktur. Aynı cihaz iki kez denenmez. Saf fonksiyondur.
public func audioInputAttempts(request: AudioInputRequest, selection: AudioInputSelection, systemDefault: AudioInputDevice?) -> [ActiveAudioInput] {
    guard let target = resolvedAudioInput(selection: selection, systemDefault: systemDefault) else {
        return []
    }
    let first: ActiveAudioInput = ActiveAudioInput(device: target, unavailableChoice: selection.unavailableChoice)
    guard let systemDefault, systemDefault.id != target.id else {
        return [first]
    }
    return [first, ActiveAudioInput(device: systemDefault, unavailableChoice: explicitChoice(request: request))]
}

/// Ses yolu yerleştikten sonra kullanılan giriş: hedefe geçildiyse seçimin sonucu, geçilemediyse (zaman aşımı, tercih
/// reddedildi) gerçekte kullanılan giriş ve seçim "kullanılamıyor". Giriş yoksa nil. Saf fonksiyondur.
public func settledActiveInput(request: AudioInputRequest, selection: AudioInputSelection, current: AudioInputDevice?) -> ActiveAudioInput? {
    guard let current else {
        return nil
    }
    if let target = selection.device, target.id != current.id {
        return ActiveAudioInput(device: current, unavailableChoice: explicitChoice(request: request))
    }
    return ActiveAudioInput(device: current, unavailableChoice: selection.unavailableChoice)
}

/// Kullanıcının açık seçimi ("Otomatik" değilse); kullanılamıyor bildirimi bunu söyler.
private func explicitChoice(request: AudioInputRequest) -> AudioInputChoice? {
    request.choice == .automatic ? nil : request.choice
}

/// Seçim değişti ama kullanılan giriş aynı kalıyorsa yakalama yeniden kurulmaz (yalnız durum tazelenir): kurma sesi
/// kısa da olsa keser. iPhone'da oturum seçenekleri değiştiyse (Bluetooth mikrofonu açıldı/kapandı) kurulur. Saf
/// fonksiyondur.
public func needsCaptureRebuild(current: ActiveAudioInput?, target: AudioInputDevice?, sessionOptionsChanged: Bool) -> Bool {
    guard !sessionOptionsChanged, let current, let target else {
        return true
    }
    return current.device.id != target.id
}

/// Motorun format düğümü donanımla aynı örnekleme hızında mı: değilse tap kurulmaz (AVFoundation uyuşmayan formatta
/// yakalanamayan bir istisnayla uygulamayı kapatır), kurma yeniden denenir. Saf fonksiyondur.
public func isCaptureFormatReady(nodeSampleRate: Double, hardwareSampleRate: Double) -> Bool {
    nodeSampleRate > 0 && hardwareSampleRate > 0 && abs(nodeSampleRate - hardwareSampleRate) < 1
}

/// Kullanılan giriş değişince kısa süre gösterilecek bildirim: yalnız gerçekten başka girişe geçildiyse ve seçim
/// kullanılabiliyorsa (kullanılamıyorsa kalıcı bildirim `persistentAudioInputNotice` söyler). İlk açılışta nil. Saf
/// fonksiyondur.
public func audioInputChangeNotice(previous: ActiveAudioInput?, current: ActiveAudioInput) -> AudioInputNotice? {
    guard let previous, previous.device.id != current.device.id, current.unavailableChoice == nil else {
        return nil
    }
    return .switched(to: current.device)
}

/// Seçilen giriş kullanılamadıkça görünen bildirim (kısa süreli değil); kullanılabiliyorsa nil. Saf fonksiyondur.
public func persistentAudioInputNotice(active: ActiveAudioInput?) -> AudioInputNotice? {
    guard let active, let missing = active.unavailableChoice else {
        return nil
    }
    return .choiceUnavailable(choice: missing, using: active.device)
}

/// Kayıt ekranında görünen mikrofon bildirimi: kalıcı olan önce, yoksa kısa süreli olan. Saf fonksiyondur.
public func visibleAudioInputNotice(active: ActiveAudioInput?, transient: AudioInputNotice?) -> AudioInputNotice? {
    persistentAudioInputNotice(active: active) ?? transient
}

/// Mac'in çıkışı: hoparlörden çalan görüşme sesi mikrofona da girer (yankı). Ayarlar uyarır; yinelenen "Sen" satırlarını
/// `suppressEchoes` ayıklar.
public enum AudioOutputKind: Sendable, Equatable {
    case speakers
    case headphones
    /// Ne olduğu bilinmiyor (Bluetooth/USB cihaz hoparlör de kulaklık da olabilir; sanal cihazlar).
    case unknown
}
