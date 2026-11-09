#if os(macOS)
import CoreAudio
import Foundation
import os

// Mac'in ses cihazları (Core Audio): mikrofon seçiminin listesi, varsayılan giriş, çıkışın hoparlör mü kulaklık mı
// olduğu ve cihaz takılıp çıkarılınca bildirim. İnce bağdaştırıcıdır; karar `selectAudioInput`'tadır.

/// Sistem sesi yakalamasının (`SystemAudioCapture`) kurduğu özel toplu cihazın adı: yalnız bu süreç görür ve giriş
/// akışı vardır; mikrofon listesinde gösterilmez.
let systemAudioTapDeviceName: String = "AI-Notepad Tap"

/// Bir Mac ses girişi ve Core Audio nesne kimliği (motorun girişi bu kimlikle seçilir; kimlik yeniden takılınca değişir,
/// UID değişmez).
public struct MacAudioInput: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let device: AudioInputDevice

    public init(objectID: AudioObjectID, device: AudioInputDevice) {
        self.objectID = objectID
        self.device = device
    }
}

/// Giriş akışı olan bütün cihazlar (sistemin sırasıyla); kendi toplu cihazımız hariç. Ad ya da UID'si okunamayan cihaz
/// loglanıp atlanır (listede gösterilemez); cihaz listesi okunamazsa hata fırlatılır.
public func macInputDevices() throws -> [MacAudioInput] {
    let ids: [AudioObjectID] = try readArray(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal)
    return ids.compactMap { (id: AudioObjectID) -> MacAudioInput? in
        guard hasInputStreams(deviceID: id) else {
            return nil
        }
        do {
            let input: MacAudioInput = try macAudioInput(deviceID: id)
            return input.device.name == systemAudioTapDeviceName ? nil : input
        } catch {
            macAudioDevicesLogger.warning("Giriş cihazı okunamadı, listede gösterilmiyor, cihaz: \(id, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Sistemin varsayılan girişi; giriş cihazı yoksa (ör. mikrofonsuz Mac mini) nil.
public func macDefaultInput() throws -> MacAudioInput? {
    let id: AudioObjectID = try readScalar(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal)
    guard id != kAudioObjectUnknown else {
        return nil
    }
    return try macAudioInput(deviceID: id)
}

/// Sistemin varsayılan çıkışı hoparlör mü kulaklık mı (yalnız Ayarlar'daki yankı açıklaması için). Okunamazsa loglanır
/// ve "bilinmiyor" döner: açıklama gösterilmez, başka hiçbir şey buna bağlı değildir.
public func macDefaultOutputKind() -> AudioOutputKind {
    do {
        let id: AudioObjectID = try readScalar(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal)
        guard id != kAudioObjectUnknown else {
            return .unknown
        }
        let transport: UInt32 = try readScalar(objectID: id, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        // Veri kaynağı yalnız yerleşik çıkışta anlamlıdır (hoparlör 'ispk' / kulaklık girişi 'hdpn'); diğerlerinde yoktur.
        let dataSource: UInt32? = transport == kAudioDeviceTransportTypeBuiltIn
            ? try readScalar(objectID: id, selector: kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput)
            : nil
        return audioOutputKind(transportType: transport, dataSource: dataSource)
    } catch {
        macAudioDevicesLogger.warning("Çıkış cihazının türü okunamadı, hata: \(String(describing: error), privacy: .public)")
        return .unknown
    }
}

/// Cihazın girişinin donanım örnekleme hızı (Hz); motorun formatı bununla karşılaştırılır (`isCaptureFormatReady`).
public func macNominalSampleRate(deviceID: AudioObjectID) throws -> Double {
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var rate: Float64 = 0
    var size: UInt32 = UInt32(MemoryLayout<Float64>.size)
    let status: OSStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
    guard status == noErr else {
        throw AudioCaptureError.coreAudio(operation: "NominalSampleRate object \(deviceID)", status: status)
    }
    return rate
}

/// Core Audio taşıma türünden giriş türü. Saf fonksiyondur.
public func audioInputKind(transportType: UInt32) -> AudioInputKind {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn:
        .builtIn
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
        .bluetooth
    case kAudioDeviceTransportTypeUSB:
        .usb
    case kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB:
        .wired
    case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
        .continuity
    case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeVirtual:
        .virtual
    default:
        .other
    }
}

/// Core Audio taşıma türü ve (yerleşik çıkışta) veri kaynağından çıkışın türü. Saf fonksiyondur.
public func audioOutputKind(transportType: UInt32, dataSource: UInt32?) -> AudioOutputKind {
    switch transportType {
    case kAudioDeviceTransportTypeBuiltIn:
        switch dataSource {
        case builtInHeadphonesDataSource: .headphones
        case builtInSpeakerDataSource: .speakers
        default: .unknown
        }
    case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay:
        .speakers
    default:
        .unknown
    }
}

/// Yerleşik çıkışın veri kaynakları: 'ispk' (dahili hoparlör), 'hdpn' (kulaklık girişi).
let builtInSpeakerDataSource: UInt32 = 0x6973_706B
let builtInHeadphonesDataSource: UInt32 = 0x6864_706E

/// Cihaz listesi, varsayılan giriş ya da varsayılan çıkış değişince `onChange`'i ana aktörde çağırır. Listeyi önceki
/// listeyle karşılaştırıp takıldı/çıkarıldı ayrımını yapar. `stop()` dinleyicileri kaldırır.
@MainActor
public final class MacAudioHardwareObserver {
    private let queue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.audio-hardware")
    private var listeners: [(selector: AudioObjectPropertySelector, block: AudioObjectPropertyListenerBlock)] = []
    private var knownInputIDs: Set<String> = []
    private let onChange: @MainActor (AudioRouteChange) -> Void

    public init(onChange: @escaping @MainActor (AudioRouteChange) -> Void) {
        self.onChange = onChange
    }

    /// Dinlemeye başlar. Dinleyici eklenemezse hata fırlatır (eklenenler kaldırılır).
    public func start() throws {
        stop()
        knownInputIDs = currentInputIDs()
        let selectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice]
        for selector in selectors {
            var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] (_: UInt32, _: UnsafePointer<AudioObjectPropertyAddress>) -> Void in
                Task { @MainActor in
                    self?.hardwareChanged(selector: selector)
                }
            }
            let status: OSStatus = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            guard status == noErr else {
                stop()
                throw AudioCaptureError.coreAudio(operation: "AudioObjectAddPropertyListenerBlock(\(selector))", status: status)
            }
            listeners.append((selector: selector, block: block))
        }
    }

    public func stop() {
        for listener in listeners {
            var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: listener.selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status: OSStatus = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener.block)
            if status != noErr {
                macAudioDevicesLogger.error("Ses cihazı dinleyicisi kaldırılamadı, özellik: \(listener.selector, privacy: .public), durum: \(status, privacy: .public)")
            }
        }
        listeners = []
    }

    private func hardwareChanged(selector: AudioObjectPropertySelector) {
        switch selector {
        case kAudioHardwarePropertyDevices:
            let ids: Set<String> = currentInputIDs()
            let change: AudioRouteChange = ids.isSuperset(of: knownInputIDs) ? (ids == knownInputIDs ? .other : .deviceAdded) : .deviceRemoved
            knownInputIDs = ids
            onChange(change)
        case kAudioHardwarePropertyDefaultInputDevice:
            onChange(.defaultChanged)
        default:
            onChange(.other)
        }
    }

    private func currentInputIDs() -> Set<String> {
        do {
            return Set(try macInputDevices().map(\.device.id))
        } catch {
            macAudioDevicesLogger.error("Giriş cihazları okunamadı, hata: \(String(describing: error), privacy: .public)")
            return knownInputIDs
        }
    }
}

private let macAudioDevicesLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MacAudioDevices")

private func macAudioInput(deviceID: AudioObjectID) throws -> MacAudioInput {
    let uid: String = try readString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID)
    let name: String = try readString(objectID: deviceID, selector: kAudioObjectPropertyName)
    let transport: UInt32 = try readScalar(objectID: deviceID, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
    return MacAudioInput(objectID: deviceID, device: AudioInputDevice(id: uid, name: name, kind: audioInputKind(transportType: transport)))
}

private func hasInputStreams(deviceID: AudioObjectID) -> Bool {
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let status: OSStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    return status == noErr && size > 0
}

private func readScalar<T: FixedWidthInteger>(objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> T {
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value: T = 0
    var size: UInt32 = UInt32(MemoryLayout<T>.size)
    let status: OSStatus = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr else {
        throw AudioCaptureError.coreAudio(operation: "AudioObjectGetPropertyData(\(selector)) object \(objectID)", status: status)
    }
    return value
}

private func readArray(objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) throws -> [AudioObjectID] {
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let sizeStatus: OSStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard sizeStatus == noErr else {
        throw AudioCaptureError.coreAudio(operation: "AudioObjectGetPropertyDataSize(\(selector))", status: sizeStatus)
    }
    var ids: [AudioObjectID] = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.size)
    let status: OSStatus = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &ids)
    guard status == noErr else {
        throw AudioCaptureError.coreAudio(operation: "AudioObjectGetPropertyData(\(selector))", status: status)
    }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

private func readString(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status: OSStatus = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
    guard status == noErr, let value else {
        throw AudioCaptureError.coreAudio(operation: "AudioObjectGetPropertyData(\(selector)) object \(objectID)", status: status)
    }
    return value.takeRetainedValue() as String
}
#endif
