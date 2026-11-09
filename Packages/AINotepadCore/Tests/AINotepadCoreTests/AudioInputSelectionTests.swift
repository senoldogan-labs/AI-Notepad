#if os(macOS)
import CoreAudio
#endif
import Foundation
import Testing
@testable import AINotepadCore

struct AudioInputSelectionTests {
    private let builtIn: AudioInputDevice = AudioInputDevice(id: "built-in", name: "iPhone Microphone", kind: .builtIn)
    private let airPods: AudioInputDevice = AudioInputDevice(id: "airpods", name: "AirPods Pro", kind: .bluetooth)
    private let usb: AudioInputDevice = AudioInputDevice(id: "usb", name: "Rode Wireless GO", kind: .usb)
    private let headset: AudioInputDevice = AudioInputDevice(id: "headset", name: "Headset Microphone", kind: .wired)

    private func request(_ choice: AudioInputChoice, _ context: AudioInputContext) -> AudioInputRequest {
        AudioInputRequest(choice: choice, context: context)
    }

    @Test func automaticLeavesTheChoiceToTheSystem() {
        let selection: AudioInputSelection = selectAudioInput(request: request(.automatic, .room), available: [builtIn, usb], systemDefault: usb)
        #expect(selection == AudioInputSelection(device: nil, unavailableChoice: nil))
        #expect(resolvedAudioInput(selection: selection, systemDefault: usb) == usb)
    }

    @Test func automaticInRoomAvoidsABluetoothHeadset() {
        // AirPods takılıyken yüz yüze kayıt: kulaklık yalnız takanı duyar; oda yerleşik mikrofonla kaydedilir.
        let selection: AudioInputSelection = selectAudioInput(request: request(.automatic, .room), available: [builtIn, airPods], systemDefault: airPods)
        #expect(selection == AudioInputSelection(device: builtIn, unavailableChoice: nil))
    }

    @Test func automaticForPersonalUseFollowsTheBluetoothHeadset() {
        // Mac'te çevrimiçi görüşme ya da sesle yazma: sistemin girişi (AirPods) kullanılır.
        let selection: AudioInputSelection = selectAudioInput(request: request(.automatic, .personal), available: [builtIn, airPods], systemDefault: airPods)
        #expect(selection.device == nil)
        #expect(resolvedAudioInput(selection: selection, systemDefault: airPods) == airPods)
    }

    @Test func automaticInRoomKeepsTheHeadsetWithoutABuiltInMicrophone() {
        // Mikrofonsuz Mac mini: başka giriş yok, sistemin girişi kalır.
        let selection: AudioInputSelection = selectAudioInput(request: request(.automatic, .room), available: [airPods], systemDefault: airPods)
        #expect(selection.device == nil)
    }

    @Test func explicitChoiceUsesTheConnectedDevice() {
        #expect(selectAudioInput(request: request(.bluetoothHeadset, .room), available: [builtIn, airPods], systemDefault: builtIn).device == airPods)
        #expect(selectAudioInput(request: request(.builtIn, .personal), available: [builtIn, airPods], systemDefault: airPods).device == builtIn)
        #expect(selectAudioInput(request: request(.wiredOrUSB, .room), available: [builtIn, headset], systemDefault: builtIn).device == headset)
        #expect(selectAudioInput(request: request(.device(id: "usb", name: "Rode"), .room), available: [builtIn, usb], systemDefault: builtIn).device == usb)
    }

    @Test func kindChoiceKeepsTheSystemsDeviceOfThatKind() {
        // İki kablolu/USB giriş: sistemin seçtiği değiştirilmez.
        let selection: AudioInputSelection = selectAudioInput(request: request(.wiredOrUSB, .room), available: [builtIn, headset, usb], systemDefault: usb)
        #expect(selection.device == usb)
    }

    @Test func missingChoiceFallsBackToAutomaticAndSaysSo() {
        // AirPods seçili ama bağlı değil: kayıt "Otomatik" kuralıyla sürer, kullanıcıya söylenir.
        let selection: AudioInputSelection = selectAudioInput(request: request(.bluetoothHeadset, .room), available: [builtIn], systemDefault: builtIn)
        #expect(selection == AudioInputSelection(device: nil, unavailableChoice: .bluetoothHeadset))
        // Mac: seçilen USB mikrofon çıkarıldı, sistemin girişi AirPods, yüz yüze kayıt: yerleşik mikrofon.
        let mac: AudioInputSelection = selectAudioInput(
            request: request(.device(id: "usb", name: "Rode"), .room), available: [builtIn, airPods], systemDefault: airPods
        )
        #expect(mac == AudioInputSelection(device: builtIn, unavailableChoice: .device(id: "usb", name: "Rode")))
    }

    @Test func reselectsOnlyWhenADeviceChangeMovesTheTarget() {
        #expect(shouldReselectInput(change: .deviceAdded, target: headset, current: builtIn))
        #expect(shouldReselectInput(change: .deviceRemoved, target: builtIn, current: nil))
        #expect(shouldReselectInput(change: .defaultChanged, target: usb, current: builtIn))
        // Hedef zaten kullanılıyor ya da seçim sistemin: yeniden kurma yok.
        #expect(!shouldReselectInput(change: .deviceAdded, target: builtIn, current: builtIn))
        #expect(!shouldReselectInput(change: .deviceAdded, target: nil, current: builtIn))
        // Kendi oturum değişikliğimizin bildirimi döngü kurmaz.
        #expect(!shouldReselectInput(change: .other, target: headset, current: builtIn))
    }

    @Test func noticeOnlyWhenTheInputChanges() {
        let onBuiltIn: ActiveAudioInput = ActiveAudioInput(device: builtIn, unavailableChoice: nil)
        let onAirPods: ActiveAudioInput = ActiveAudioInput(device: airPods, unavailableChoice: nil)
        let lostAirPods: ActiveAudioInput = ActiveAudioInput(device: builtIn, unavailableChoice: .bluetoothHeadset)
        // İlk açılış: seçim kullanılabiliyorsa bildirim yok, kullanılamıyorsa söylenir.
        #expect(audioInputChangeNotice(previous: nil, current: onBuiltIn) == nil)
        #expect(audioInputChangeNotice(previous: nil, current: lostAirPods) == .choiceUnavailable(choice: .bluetoothHeadset, using: builtIn))
        // Aynı giriş: bildirim yok (yeniden kurma, ses yolu tazelemesi).
        #expect(audioInputChangeNotice(previous: onBuiltIn, current: onBuiltIn) == nil)
        #expect(audioInputChangeNotice(previous: lostAirPods, current: lostAirPods) == nil)
        // Kayıtta AirPods çıkarıldı: hangi girişle sürdüğü söylenir; geri takılınca geçiş söylenir.
        #expect(audioInputChangeNotice(previous: onAirPods, current: lostAirPods) == .choiceUnavailable(choice: .bluetoothHeadset, using: builtIn))
        #expect(audioInputChangeNotice(previous: lostAirPods, current: onAirPods) == .switched(to: airPods))
        // Otomatikte USB mikrofon takıldı.
        let onUSB: ActiveAudioInput = ActiveAudioInput(device: usb, unavailableChoice: nil)
        #expect(audioInputChangeNotice(previous: onBuiltIn, current: onUSB) == .switched(to: usb))
    }

    @Test func choiceRoundTripsThroughStorage() throws {
        let choices: [AudioInputChoice] = [.automatic, .builtIn, .bluetoothHeadset, .wiredOrUSB, .device(id: "AppleUSBAudioEngine:Rode:1", name: "Rode NT-USB")]
        for choice in choices {
            #expect(try decodeAudioInputChoice(stored: encodeAudioInputChoice(choice: choice)) == choice)
        }
        #expect(throws: DecodingError.self) { try decodeAudioInputChoice(stored: "airpods") }
    }

    @MainActor
    @Test func storedChoiceDefaultsToAutomatic() throws {
        let suite: String = "AudioInputSelectionTests-\(UUID().uuidString)"
        let defaults: UserDefaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(storedAudioInputChoice(defaults: defaults) == .automatic)
        storeAudioInputChoice(choice: .bluetoothHeadset, defaults: defaults)
        #expect(storedAudioInputChoice(defaults: defaults) == .bluetoothHeadset)
        defaults.set("bozuk", forKey: audioInputSettingKey)
        #expect(storedAudioInputChoice(defaults: defaults) == .automatic)
    }

    #if os(macOS)
    @Test func macTransportTypesMapToKinds() {
        #expect(audioInputKind(transportType: kAudioDeviceTransportTypeBuiltIn) == .builtIn)
        #expect(audioInputKind(transportType: kAudioDeviceTransportTypeBluetooth) == .bluetooth)
        #expect(audioInputKind(transportType: kAudioDeviceTransportTypeUSB) == .usb)
        #expect(audioInputKind(transportType: kAudioDeviceTransportTypeContinuityCaptureWireless) == .continuity)
        #expect(audioInputKind(transportType: kAudioDeviceTransportTypeVirtual) == .virtual)
        #expect(audioOutputKind(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: builtInSpeakerDataSource) == .speakers)
        #expect(audioOutputKind(transportType: kAudioDeviceTransportTypeBuiltIn, dataSource: builtInHeadphonesDataSource) == .headphones)
        #expect(audioOutputKind(transportType: kAudioDeviceTransportTypeHDMI, dataSource: nil) == .speakers)
        #expect(audioOutputKind(transportType: kAudioDeviceTransportTypeBluetooth, dataSource: nil) == .unknown)
    }

    /// Bu Mac'in gerçek cihaz listesi (yalnız okur; mikrofon açılmaz): `AINOTEPAD_AUDIO_DEVICE_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AINOTEPAD_AUDIO_DEVICE_TESTS"] == "1"))
    func macListsRealInputDevices() throws {
        let inputs: [MacAudioInput] = try macInputDevices()
        let systemDefault: MacAudioInput? = try macDefaultInput()
        print("Giriş cihazları: \(inputs.map { "\($0.device.name) [\($0.device.kind.rawValue)]" }), varsayılan: \(systemDefault?.device.name ?? "yok"), çıkış: \(try macDefaultOutputKind())")
        if let systemDefault {
            #expect(inputs.contains { $0.device.id == systemDefault.device.id })
        }
        #expect(!inputs.contains { $0.device.name == systemAudioTapDeviceName })
    }

    /// Gerçek yakalama: varsayılan olmayan bir girişi seçip motoru o cihazla kurar, ses gelir; sonra seçimi değiştirip
    /// kayıt durmadan sistemin girişine geçer. Mikrofon izni ve en az iki giriş cihazı gerekir:
    /// `AINOTEPAD_MIC_DEVICE_TESTS=1`.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AINOTEPAD_MIC_DEVICE_TESTS"] == "1"))
    func macCapturesFromTheChosenDeviceAndSwitchesLive() async throws {
        let systemDefault: MacAudioInput = try #require(try macDefaultInput())
        let other: MacAudioInput = try #require(try macInputDevices().first { $0.device.id != systemDefault.device.id })
        let choice: TestInputChoice = TestInputChoice(value: .device(id: other.device.id, name: other.device.name))
        let capture: MicrophoneCapture = MicrophoneCapture { AudioInputRequest(choice: choice.value, context: .personal) }
        var inputs: [ActiveAudioInput] = []
        capture.onInputChange = { inputs.append($0) }
        let stream: AsyncStream<[Float]> = try await capture.start()
        var iterator: AsyncStream<[Float]>.Iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        #expect(capture.activeInput?.device.id == other.device.id)
        choice.value = .automatic
        await capture.inputChoiceChanged()
        #expect(await iterator.next() != nil)
        #expect(capture.activeInput?.device.id == systemDefault.device.id)
        #expect(capture.status == .running)
        #expect(inputs.map(\.device.id) == [other.device.id, systemDefault.device.id])
        capture.stop()
    }
    #endif
}

/// Testte kayıt sürerken değiştirilen mikrofon seçimi.
@MainActor
private final class TestInputChoice {
    var value: AudioInputChoice

    init(value: AudioInputChoice) {
        self.value = value
    }
}
