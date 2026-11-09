#if os(macOS)
import CoreAudio
#endif
import Foundation
import Synchronization
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
        // İlk açılış: kısa bildirim yok; seçim kullanılamıyorsa kalıcı bildirim söyler.
        #expect(audioInputChangeNotice(previous: nil, current: onBuiltIn) == nil)
        #expect(audioInputChangeNotice(previous: nil, current: lostAirPods) == nil)
        #expect(persistentAudioInputNotice(active: lostAirPods) == .choiceUnavailable(choice: .bluetoothHeadset, using: builtIn))
        // Aynı giriş: bildirim yok (yeniden kurma, ses yolu tazelemesi).
        #expect(audioInputChangeNotice(previous: onBuiltIn, current: onBuiltIn) == nil)
        #expect(audioInputChangeNotice(previous: lostAirPods, current: lostAirPods) == nil)
        // Kayıtta AirPods çıkarıldı: kısa geçiş bildirimi değil, durum sürdükçe kalıcı bildirim.
        #expect(audioInputChangeNotice(previous: onAirPods, current: lostAirPods) == nil)
        // Geri takılınca geçiş kısa süre söylenir, kalıcı bildirim kalkar.
        #expect(audioInputChangeNotice(previous: lostAirPods, current: onAirPods) == .switched(to: airPods))
        #expect(persistentAudioInputNotice(active: onAirPods) == nil)
        // Otomatikte USB mikrofon takıldı.
        let onUSB: ActiveAudioInput = ActiveAudioInput(device: usb, unavailableChoice: nil)
        #expect(audioInputChangeNotice(previous: onBuiltIn, current: onUSB) == .switched(to: usb))
    }

    @Test func persistentNoticeWinsOverTransient() {
        let lostAirPods: ActiveAudioInput = ActiveAudioInput(device: builtIn, unavailableChoice: .bluetoothHeadset)
        let onUSB: ActiveAudioInput = ActiveAudioInput(device: usb, unavailableChoice: nil)
        #expect(visibleAudioInputNotice(active: lostAirPods, transient: .switched(to: builtIn)) == .choiceUnavailable(choice: .bluetoothHeadset, using: builtIn))
        #expect(visibleAudioInputNotice(active: onUSB, transient: .switched(to: usb)) == .switched(to: usb))
        #expect(visibleAudioInputNotice(active: onUSB, transient: .storedChoiceUnreadable) == .storedChoiceUnreadable)
        #expect(visibleAudioInputNotice(active: nil, transient: nil) == nil)
    }

    @Test func attemptsFallBackToTheSystemDefaultOnce() {
        // Mac: seçilen USB mikrofon kurulamazsa sistemin girişi denenir ve seçim "kullanılamıyor" olur.
        let chosen: AudioInputRequest = request(.device(id: "usb", name: "Rode"), .personal)
        let selection: AudioInputSelection = selectAudioInput(request: chosen, available: [builtIn, usb], systemDefault: builtIn)
        #expect(audioInputAttempts(request: chosen, selection: selection, systemDefault: builtIn) == [
            ActiveAudioInput(device: usb, unavailableChoice: nil),
            ActiveAudioInput(device: builtIn, unavailableChoice: .device(id: "usb", name: "Rode")),
        ])
        // Otomatik: hedef zaten sistemin girişi; aynı cihaz iki kez denenmez.
        let automatic: AudioInputRequest = request(.automatic, .personal)
        let systemOnly: AudioInputSelection = selectAudioInput(request: automatic, available: [builtIn, usb], systemDefault: usb)
        #expect(audioInputAttempts(request: automatic, selection: systemOnly, systemDefault: usb) == [ActiveAudioInput(device: usb, unavailableChoice: nil)])
        // Oda kuralıyla yerleşik mikrofon hedefse ve kurulamazsa sistemin girişine düşülür; seçim olmadığı için bildirim yok.
        let room: AudioInputRequest = request(.automatic, .room)
        let roomSelection: AudioInputSelection = selectAudioInput(request: room, available: [builtIn, airPods], systemDefault: airPods)
        #expect(audioInputAttempts(request: room, selection: roomSelection, systemDefault: airPods) == [
            ActiveAudioInput(device: builtIn, unavailableChoice: nil),
            ActiveAudioInput(device: airPods, unavailableChoice: nil),
        ])
        // Giriş cihazı yok.
        #expect(audioInputAttempts(request: automatic, selection: AudioInputSelection(device: nil, unavailableChoice: nil), systemDefault: nil).isEmpty)
    }

    @Test func activeInputIsReportedOnlyAfterTheRouteSwitched() {
        let wired: AudioInputRequest = request(.wiredOrUSB, .room)
        let selection: AudioInputSelection = AudioInputSelection(device: headset, unavailableChoice: nil)
        // Ses yolu hedefe geçti.
        #expect(settledActiveInput(request: wired, selection: selection, current: headset) == ActiveAudioInput(device: headset, unavailableChoice: nil))
        // Geçmedi (zaman aşımı ya da tercih reddedildi): gerçekte kullanılan giriş, seçim kullanılamıyor.
        #expect(settledActiveInput(request: wired, selection: selection, current: builtIn) == ActiveAudioInput(device: builtIn, unavailableChoice: .wiredOrUSB))
        // Otomatik: seçim sistemin, ne varsa o.
        let automatic: AudioInputSelection = AudioInputSelection(device: nil, unavailableChoice: nil)
        #expect(settledActiveInput(request: request(.automatic, .room), selection: automatic, current: usb) == ActiveAudioInput(device: usb, unavailableChoice: nil))
        #expect(settledActiveInput(request: wired, selection: selection, current: nil) == nil)
    }

    @Test func choiceChangeRebuildsOnlyWhenTheDeviceOrSessionChanges() {
        let onBuiltIn: ActiveAudioInput = ActiveAudioInput(device: builtIn, unavailableChoice: nil)
        // "Otomatik"ten "iPhone mikrofonu"na: aynı cihaz, kurma yok.
        #expect(!needsCaptureRebuild(current: onBuiltIn, target: builtIn, sessionOptionsChanged: false))
        #expect(needsCaptureRebuild(current: onBuiltIn, target: usb, sessionOptionsChanged: false))
        // Bluetooth mikrofonu açıldı/kapandı: oturum değişir, kurulur.
        #expect(needsCaptureRebuild(current: onBuiltIn, target: builtIn, sessionOptionsChanged: true))
        #expect(needsCaptureRebuild(current: nil, target: builtIn, sessionOptionsChanged: false))
        #expect(needsCaptureRebuild(current: onBuiltIn, target: nil, sessionOptionsChanged: false))
    }

    @Test func tapWaitsForTheHardwareSampleRate() {
        #expect(isCaptureFormatReady(nodeSampleRate: 48_000, hardwareSampleRate: 48_000))
        // Cihaz 44,1 kHz'e geçti, motor hâlâ 48 kHz: tap takılmaz.
        #expect(!isCaptureFormatReady(nodeSampleRate: 48_000, hardwareSampleRate: 44_100))
        #expect(!isCaptureFormatReady(nodeSampleRate: 0, hardwareSampleRate: 48_000))
        #expect(!isCaptureFormatReady(nodeSampleRate: 16_000, hardwareSampleRate: 0))
    }

    @Test func changesDuringARebuildAreQueuedNotDropped() {
        #expect(mergedRouteChange(pending: nil, new: .deviceAdded) == .deviceAdded)
        #expect(mergedRouteChange(pending: .deviceRemoved, new: .other) == .deviceRemoved)
        #expect(mergedRouteChange(pending: .deviceRemoved, new: .choiceChanged) == .choiceChanged)
        #expect(mergedRouteChange(pending: nil, new: .other) == .other)
        // A queued input choice survives a later device change (checking the choice re-reads the devices).
        #expect(mergedRouteChange(pending: .choiceChanged, new: .deviceRemoved) == .choiceChanged)
        #expect(mergedRouteChange(pending: .choiceChanged, new: .other) == .choiceChanged)
        // Sıradaki seçim değişikliği hedef farklıysa kurar.
        #expect(shouldReselectInput(change: .choiceChanged, target: usb, current: builtIn))
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
        #expect(readAudioInputChoice(stored: "bozuk") == .unreadable)
        #expect(readAudioInputChoice(stored: "") == .choice(.automatic))
        // Okunamayan değer kayıt başında bir kez silinir ve söylenir; sonra yok.
        #expect(resetUnreadableAudioInputChoice(defaults: defaults))
        #expect(defaults.string(forKey: audioInputSettingKey) == nil)
        #expect(!resetUnreadableAudioInputChoice(defaults: defaults))
        storeAudioInputChoice(choice: .builtIn, defaults: defaults)
        #expect(!resetUnreadableAudioInputChoice(defaults: defaults))
        #expect(storedAudioInputChoice(defaults: defaults) == .builtIn)
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
        print("Giriş cihazları: \(inputs.map { "\($0.device.name) [\($0.device.kind.rawValue)]" }), varsayılan: \(systemDefault?.device.name ?? "yok"), çıkış: \(macDefaultOutputKind())")
        if let systemDefault {
            #expect(inputs.contains { $0.device.id == systemDefault.device.id })
        }
        #expect(!inputs.contains { $0.device.name == systemAudioTapDeviceName })
    }

    /// Gerçek yakalama, iki farklı örnekleme hızında: varsayılan olmayan girişin hızı varsayılanınkinden farklı yapılır
    /// (ör. BlackHole 44,1 kHz, MacBook mikrofonu 48 kHz; test sonunda eski hızına döner). O giriş seçilir, ses gelir;
    /// kayıt sürerken "Otomatik"e, sonra yeniden o girişe geçilir: her geçişte akış kopmadan ses gelir, durum "çalışıyor"
    /// kalır, uygulama çökmez. Mikrofon izni ve en az iki giriş cihazı gerekir: `AINOTEPAD_MIC_DEVICE_TESTS=1`.
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AINOTEPAD_MIC_DEVICE_TESTS"] == "1"))
    func macSwitchesLiveBetweenDevicesWithDifferentSampleRates() async throws {
        let systemDefault: MacAudioInput = try #require(try macDefaultInput())
        let other: MacAudioInput = try #require(try macInputDevices().first { $0.device.id != systemDefault.device.id })
        let defaultRate: Double = try macNominalSampleRate(deviceID: systemDefault.objectID)
        let otherRate: Double = try macNominalSampleRate(deviceID: other.objectID)
        let wantedRate: Double = defaultRate == 44_100 ? 48_000 : 44_100
        try setNominalSampleRate(deviceID: other.objectID, rate: wantedRate)
        defer {
            do {
                try setNominalSampleRate(deviceID: other.objectID, rate: otherRate)
            } catch {
                Issue.record("Cihazın örnekleme hızı geri alınamadı: \(error)")
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try macNominalSampleRate(deviceID: other.objectID) != defaultRate)
        print("Örnekleme hızları: \(other.device.name) \(try macNominalSampleRate(deviceID: other.objectID)), \(systemDefault.device.name) \(defaultRate)")

        let choice: TestInputChoice = TestInputChoice(value: .device(id: other.device.id, name: other.device.name))
        let capture: MicrophoneCapture = MicrophoneCapture { AudioInputRequest(choice: choice.value, context: .personal) }
        var inputs: [ActiveAudioInput] = []
        capture.onInputChange = { inputs.append($0) }
        let stream: AsyncStream<[Float]> = try await capture.start()
        // Gelen 16 kHz örnekler sayılır: her geçişten sonra yeni ses gelmeli (eski tamponlar sayılmaz).
        let received: SampleCount = SampleCount()
        let reader: Task<Void, Never> = Task {
            for await chunk in stream {
                received.add(chunk.count)
            }
        }
        defer { reader.cancel() }
        try await Task.sleep(for: .milliseconds(600))
        #expect(received.value > 4_000)
        #expect(capture.activeInput?.device.id == other.device.id)
        for round in 0..<3 {
            choice.value = round.isMultiple(of: 2) ? .automatic : .device(id: other.device.id, name: other.device.name)
            await capture.inputChoiceChanged()
            #expect(capture.status == .running)
            let before: Int = received.value
            try await Task.sleep(for: .milliseconds(600))
            // 600 ms'de ~9 600 örnek gelir; en az yarısı gelmeli (sessiz tap ya da takılma olmamalı).
            #expect(received.value - before > 4_800, "geçiş \(round): \(received.value - before) örnek")
        }
        #expect(capture.activeInput?.device.id == systemDefault.device.id)
        #expect(capture.activeInput?.unavailableChoice == nil)
        #expect(inputs.map(\.device.id) == [other.device.id, systemDefault.device.id, other.device.id, systemDefault.device.id])
        capture.stop()
    }

    /// Testin cihaz örnekleme hızını değiştirmesi (yalnız test; uygulama sistem ayarını değiştirmez).
    private func setNominalSampleRate(deviceID: AudioObjectID, rate: Double) throws {
        var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Float64 = rate
        let status: OSStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
        guard status == noErr else {
            throw AudioCaptureError.coreAudio(operation: "SetNominalSampleRate \(rate)", status: status)
        }
    }
    #endif
}

/// Gerçek yakalama testinde gelen örnek sayısı (okuyucu görevden yazılır).
private final class SampleCount: Sendable {
    private let count: Mutex<Int> = Mutex(0)

    func add(_ samples: Int) {
        count.withLock { (value: inout Int) -> Void in value += samples }
    }

    var value: Int {
        count.withLock { (value: inout Int) -> Int in value }
    }
}

/// Testte kayıt sürerken değiştirilen mikrofon seçimi.
@MainActor
private final class TestInputChoice {
    var value: AudioInputChoice

    init(value: AudioInputChoice) {
        self.value = value
    }
}
