// Sistem sesi yakalama (Core Audio süreç musluğu) yalnızca macOS'ta var; iPhone başka uygulamaların sesini yakalayamaz.
#if os(macOS)
import AVFoundation
import CoreAudio
import Foundation
import os

/// Sistemde çalan tüm sesi (Zoom, Teams vb.) Core Audio process tap ile yakalar ("Diğerleri" akışı).
///
/// Akış: global tap → tap'i ve varsayılan çıkış cihazını içeren özel toplu (aggregate) cihaz → IO bloğu.
/// Ekran kaydı izni gerekmez; ilk kullanımda macOS "sistem sesi kaydı" izni sorar.
/// Varsayılan çıkış cihazı, toplu cihazın örnekleme hızı ya da tap formatı değişirse (ör. AirPods
/// bağlanınca ya da HFP moduna geçince) toplu cihaz geri çekilmeli denemelerle yeniden kurulur. Geçiş sırasında IO
/// bloğuna kurulu formata uymayan tampon gelirse (tap tamponu yok, tampon ya da dönüştürme kurulamadı) o tampon atlanır,
/// uyarı loglanır ve toplu cihaz yeni formatla yeniden kurulur; akış sürer, aradaki boşluk saatle hizalamada sessizlikle
/// dolar. Yeniden kurulamazsa ya da art arda `maxMismatchRebuilds` kurulumdan hiç ses gelmezse akış bitirilir (uygulama
/// "ses akışı durdu" uyarısı gösterir; "Diğerleri" sessizce boş kalmaz).
@MainActor
public final class SystemAudioCapture {
    private nonisolated static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SystemAudioCapture")
    /// Uyuşmayan tampon yüzünden art arda (arada ses gelmeden) en fazla bu kadar yeniden kurma; sonra akış bitirilir.
    private static let maxMismatchRebuilds: Int = 3

    private let ioQueue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.system-audio", qos: .userInteractive)
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var tapUID: String = ""
    private var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// IO bloğunun tap tamponlarını kopyaladığı, önceden ayrılmış liste.
    private var tapBufferList: UnsafeMutableAudioBufferListPointer?
    private var continuation: AsyncStream<[Float]>.Continuation?
    /// Yakalama boyunca geçerli dinleyiciler (varsayılan çıkış, tap formatı).
    private var sessionListeners: [PropertyListener] = []
    /// Toplu cihaz boyunca geçerli dinleyiciler (örnekleme hızı).
    private var deviceListeners: [PropertyListener] = []
    /// Her yeniden kurma isteğinde artar; eski denemeler yenisi gelince vazgeçer.
    private var restartGeneration: Int = 0
    /// Çalışan toplu cihazın kurulduğu çıkış ve format; değişmediyse bildirimde yeniden kurulmaz.
    private var activeSignature: DeviceSignature?
    /// Çalışan IO bloğunun durumu (ses geldi mi, uyuşmazlık bildirildi mi).
    private var ioState: TapIOState?
    /// Uyuşmayan tampon yüzünden art arda yapılan yeniden kurma sayısı (bkz. `tapRecoveryDecision`).
    private var mismatchRebuilds: Int = 0

    public init() {}

    /// Tap'i oluşturur, yakalamayı başlatır ve ses parçalarının akışını döndürür.
    public func start() async throws -> AsyncStream<[Float]> {
        guard continuation == nil else {
            throw AudioCaptureError.alreadyRunning(source: "SystemAudioCapture")
        }
        // Uygulamanın kendi sesi (ör. eski toplantıyı çalmak) "Diğerleri" diye yazıya dökülmesin: kendi süreci hariç.
        let description: CATapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: try ownProcessObjects())
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var newTapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        try check(status: AudioHardwareCreateProcessTap(description, &newTapID), operation: "AudioHardwareCreateProcessTap")
        tapID = newTapID
        tapUID = description.uuid.uuidString

        let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        do {
            try startDevice(continuation: continuation)
            sessionListeners = [
                try addRestartListener(objectID: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice),
                try addRestartListener(objectID: tapID, selector: kAudioTapPropertyFormat),
            ]
        } catch {
            stop()
            throw error
        }
        return stream
    }

    /// Bu sürecin Core Audio süreç nesnesi (tap'ten hariç tutmak için). Core Audio süreci henüz tanımıyorsa (hiç ses
    /// açmamış) hariç tutulacak çıkışı da yoktur: boş liste.
    private func ownProcessObjects() throws -> [AudioObjectID] {
        var pid: pid_t = getpid()
        var object: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
        var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try check(
            status: AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
            operation: "kAudioHardwarePropertyTranslatePIDToProcessObject"
        )
        return object == AudioObjectID(kAudioObjectUnknown) ? [] : [object]
    }

    /// Yakalamayı durdurur, Core Audio nesnelerini siler ve akışı bitirir.
    public func stop() {
        removeListeners(listeners: sessionListeners)
        sessionListeners = []
        stopDevice()
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            logIfFailed(status: AudioHardwareDestroyProcessTap(tapID), operation: "AudioHardwareDestroyProcessTap")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        continuation?.finish()
        continuation = nil
        mismatchRebuilds = 0
    }

    /// Toplu cihazı varsayılan çıkışla kurar ve IO bloğunu başlatır.
    private func startDevice(continuation: AsyncStream<[Float]>.Continuation) throws {
        let signature: DeviceSignature = try currentSignature(tapID: tapID)
        let outputUID: String = signature.outputUID
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AI-Notepad Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
        ]
        var newAggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        try check(
            status: AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        aggregateID = newAggregateID

        var streamDescription: AudioStreamBasicDescription = try tapFormat(tapID: tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw AudioCaptureError.converterCreationFailed(inputDescription: String(describing: streamDescription))
        }
        let resampler: AudioResampler = try AudioResampler(inputFormat: format)
        let tapBuffers: UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(
            maximumBuffers: format.isInterleaved ? 1 : Int(format.channelCount)
        )
        tapBufferList = tapBuffers
        let state: TapIOState = TapIOState()
        ioState = state
        let onMismatch: @Sendable () -> Void = { [weak self] () -> Void in
            Task { @MainActor in
                await self?.recoverFromMismatch(state: state)
            }
        }
        var newProcID: AudioDeviceIOProcID?
        try check(
            status: AudioDeviceCreateIOProcIDWithBlock(
                &newProcID,
                aggregateID,
                ioQueue,
                Self.makeIOBlock(
                    format: format, tapBuffers: tapBuffers, resampler: resampler, continuation: continuation, state: state, onMismatch: onMismatch,
                    throttle: LogThrottle(intervalSec: 60)
                )
            ),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newProcID
        deviceListeners = [try addRestartListener(objectID: aggregateID, selector: kAudioDevicePropertyNominalSampleRate)]
        try check(status: AudioDeviceStart(aggregateID, ioProcID), operation: "AudioDeviceStart")
        activeSignature = signature
        Self.logger.info("Sistem sesi yakalama başladı, çıkış: \(outputUID, privacy: .public), örnekleme: \(format.sampleRate, privacy: .public)")
    }

    /// IO bloğunu ve toplu cihazı siler (tap kalır).
    private func stopDevice() {
        activeSignature = nil
        ioState = nil
        removeListeners(listeners: deviceListeners)
        deviceListeners = []
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID = ioProcID {
                logIfFailed(status: AudioDeviceStop(aggregateID, procID), operation: "AudioDeviceStop")
                logIfFailed(status: AudioDeviceDestroyIOProcID(aggregateID, procID), operation: "AudioDeviceDestroyIOProcID")
            }
            logIfFailed(status: AudioHardwareDestroyAggregateDevice(aggregateID), operation: "AudioHardwareDestroyAggregateDevice")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        ioProcID = nil
        // IO bloğu durdurulduktan sonra serbest bırakılır.
        if let list = tapBufferList {
            free(list.unsafeMutablePointer)
        }
        tapBufferList = nil
    }

    /// Özellik değişince toplu cihazı yeniden kuran bir dinleyici ekler.
    private func addRestartListener(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> PropertyListener {
        var address: AudioObjectPropertyAddress = propertyAddress(selector: selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] (_: UInt32, _: UnsafePointer<AudioObjectPropertyAddress>) -> Void in
            Task { @MainActor in
                await self?.restartDevice()
            }
        }
        try check(
            status: AudioObjectAddPropertyListenerBlock(objectID, &address, ioQueue, block),
            operation: "AudioObjectAddPropertyListenerBlock(\(selector))"
        )
        return PropertyListener(objectID: objectID, selector: selector, block: block)
    }

    private func removeListeners(listeners: [PropertyListener]) {
        for listener in listeners {
            var address: AudioObjectPropertyAddress = propertyAddress(selector: listener.selector)
            logIfFailed(
                status: AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, ioQueue, listener.block),
                operation: "AudioObjectRemovePropertyListenerBlock(\(listener.selector))"
            )
        }
    }

    /// Özellik bildirimi (çıkış, örnekleme hızı, tap formatı): koşullar kurulu toplu cihazınkiyle aynıysa (ör. kendi
    /// kurulumumuzun tetiklediği bildirim) yeniden kurulmaz, döngü önlenir. Koşullar okunamıyorsa cihaz değişiyor demektir:
    /// yeniden kurulur, hata orada raporlanır.
    private func restartDevice() async {
        guard continuation != nil else {
            return
        }
        if let active = activeSignature, let current = try? currentSignature(tapID: tapID), current == active {
            return
        }
        await rebuildDevice()
    }

    /// IO bloğu kurulu formata uymayan tampon aldı (çıkış değişirken geçici uyuşmazlık): toplu cihaz, koşullar aynı
    /// görünse de yeni formatla yeniden kurulur. Arada ses gelmeden art arda `maxMismatchRebuilds` kez olursa akış
    /// bitirilir.
    private func recoverFromMismatch(state: TapIOState) async {
        // Bildirim eski bir IO bloğundansa (cihaz bu arada yeniden kuruldu) yok sayılır.
        guard continuation != nil, state === ioState else {
            return
        }
        switch tapRecoveryDecision(previousRebuilds: mismatchRebuilds, deliveredSinceLastRebuild: state.hasDelivered, maxRebuilds: Self.maxMismatchRebuilds) {
        case .rebuild(let attempt):
            mismatchRebuilds = attempt
            Self.logger.warning("Sistem sesi tamponu kurulu formata uymuyor, toplu cihaz yeniden kuruluyor, deneme: \(attempt, privacy: .public)")
            await rebuildDevice()
        case .giveUp:
            Self.logger.error("Sistem sesi art arda yeniden kurmalarda da formata uymadı, akış bitiriliyor, kurma: \(Self.maxMismatchRebuilds, privacy: .public)")
            stop()
        }
    }

    /// Toplu cihazı yeniden kurar; yeni cihaz (ör. bağlanan AirPods) henüz hazır olmayabileceği için geri çekilmeli
    /// olarak birkaç kez dener (toplam ~8 sn). Daha yeni bir istek gelirse ya da yakalama durdurulursa bu deneme sessizce
    /// çekilir; kurulamazsa akış bitirilir.
    private func rebuildDevice() async {
        guard continuation != nil else {
            return
        }
        restartGeneration += 1
        let generation: Int = restartGeneration
        stopDevice()
        do {
            try await retryWithBackoff(
                attempts: 6,
                delaySec: 0.25,
                isolation: #isolation,
                operation: {
                    guard generation == self.restartGeneration, let continuation = self.continuation else {
                        return
                    }
                    self.stopDevice()
                    try self.startDevice(continuation: continuation)
                },
                onFailure: { (attempt: Int, error: any Error) -> Void in
                    Self.logger.warning("Sistem sesi yeniden kurulamadı, deneme \(attempt, privacy: .public): \(String(describing: error), privacy: .private)")
                }
            )
        } catch {
            guard generation == restartGeneration else {
                return
            }
            Self.logger.error("Sistem sesi yeniden kurulamadı, akış bitiriliyor: \(String(describing: error), privacy: .private)")
            stop()
        }
    }

    /// IO thread'inde çalışan blok. Ana aktöre bağlı olmaması için `nonisolated` üretilir. Kurulu formata uymayan tampon
    /// (çıkış değişirken) atlanır ve bu toplu cihaz için bir kez `onMismatch` çağrılır; akış bitirilmez.
    private nonisolated static func makeIOBlock(
        format: AVAudioFormat,
        tapBuffers: UnsafeMutableAudioBufferListPointer,
        resampler: AudioResampler,
        continuation: AsyncStream<[Float]>.Continuation,
        state: TapIOState,
        onMismatch: @escaping @Sendable () -> Void,
        throttle: LogThrottle
    ) -> AudioDeviceIOBlock {
        { (_: UnsafePointer<AudioTimeStamp>, inputData: UnsafePointer<AudioBufferList>, _: UnsafePointer<AudioTimeStamp>, _: UnsafeMutablePointer<AudioBufferList>, _: UnsafePointer<AudioTimeStamp>) -> Void in
            let source: UnsafeMutableAudioBufferListPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            // Uyuşmazlık her tamponda tekrarlanır: log dakikada bir, yeniden kurma isteği bu toplu cihaz için bir kez.
            let reportMismatch: (String) -> Void = { (reason: String) -> Void in
                if throttle.allow() {
                    logger.warning("Sistem sesi tamponu atlandı, neden: \(reason, privacy: .public)")
                }
                if state.markMismatch() {
                    onMismatch()
                }
            }
            guard copyTrailingBuffers(source: source, destination: tapBuffers) else {
                reportMismatch("toplu cihaz girişinde tap tamponu yok: \(source.count) tampon, beklenen \(tapBuffers.count)")
                return
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: tapBuffers.unsafePointer, deallocator: nil) else {
                reportMismatch("tampon kurulu formatla oluşturulamadı")
                return
            }
            do {
                let samples: [Float] = try resampler.convert(buffer: buffer)
                state.markDelivered()
                if !samples.isEmpty {
                    continuation.yield(samples)
                }
            } catch {
                reportMismatch("dönüştürülemedi: \(String(describing: error))")
            }
        }
    }
}

/// Bir toplu cihazın IO bloğunun durumu: IO thread'i yazar, ana aktör okur. Thread-safe.
final class TapIOState: Sendable {
    private let flags: LockedState<TapIOFlags> = LockedState(TapIOFlags(delivered: false, mismatchReported: false))

    /// Bu toplu cihazdan en az bir tampon dönüştürüldü.
    var hasDelivered: Bool {
        flags.withLock { (value: inout TapIOFlags) -> Bool in value.delivered }
    }

    func markDelivered() {
        flags.withLock { (value: inout TapIOFlags) -> Void in
            value.delivered = true
        }
    }

    /// Uyuşmazlığı işaretler; bu toplu cihazda ilk kezse true (yeniden kurma bir kez istenir).
    func markMismatch() -> Bool {
        flags.withLock { (value: inout TapIOFlags) -> Bool in
            let first: Bool = !value.mismatchReported
            value.mismatchReported = true
            return first
        }
    }
}

private struct TapIOFlags {
    var delivered: Bool
    var mismatchReported: Bool
}

/// Uyuşmayan sistem sesi tamponundan sonra verilen karar.
enum TapRecoveryDecision: Equatable {
    /// Toplu cihaz yeniden kurulur; `attempt`: arada ses gelmeden art arda kaçıncı kurma.
    case rebuild(attempt: Int)
    /// Art arda kurmalar da ses vermedi: akış bitirilir (uygulama uyarı gösterir).
    case giveUp
}

/// Uyuşmazlıktan sonra yeniden kurulsun mu: son kurmadan beri ses geldiyse sayaç baştan başlar (geçici uyuşmazlık, ör.
/// çıkış değişti); gelmediyse artar ve `maxRebuilds`'i aşınca vazgeçilir (sonsuz kurma döngüsü olmasın). Saf fonksiyondur.
func tapRecoveryDecision(previousRebuilds: Int, deliveredSinceLastRebuild: Bool, maxRebuilds: Int) -> TapRecoveryDecision {
    let attempt: Int = deliveredSinceLastRebuild ? 1 : previousRebuilds + 1
    return attempt > maxRebuilds ? .giveUp : .rebuild(attempt: attempt)
}

/// Toplu cihazın kurulduğu koşullar.
private struct DeviceSignature: Equatable {
    let outputUID: String
    let sampleRate: Float64
    let channelCount: UInt32
}

/// Şu anki varsayılan çıkış ve tap formatı.
private func currentSignature(tapID: AudioObjectID) throws -> DeviceSignature {
    let format: AudioStreamBasicDescription = try tapFormat(tapID: tapID)
    return DeviceSignature(
        outputUID: try deviceUID(deviceID: defaultOutputDeviceID()),
        sampleRate: format.mSampleRate,
        channelCount: format.mChannelsPerFrame
    )
}

/// Kaldırılabilmek için saklanan Core Audio özellik dinleyicisi.
private struct PropertyListener {
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let block: AudioObjectPropertyListenerBlock
}

/// Toplu cihazın giriş listesindeki son `destination.count` tamponu hedefe kopyalar.
/// Alt cihazın (ör. kulaklık mikrofonu) giriş akışları önce, tap akışı en sonda gelir.
/// Kaynakta yeterli tampon yoksa false döner.
func copyTrailingBuffers(source: UnsafeMutableAudioBufferListPointer, destination: UnsafeMutableAudioBufferListPointer) -> Bool {
    let offset: Int = source.count - destination.count
    guard offset >= 0 else {
        return false
    }
    for index in 0..<destination.count {
        destination[index] = source[offset + index]
    }
    return true
}

/// `noErr` dışındaki Core Audio durumunu hataya çevirir.
private func check(status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw AudioCaptureError.coreAudio(operation: operation, status: status)
    }
}

/// Temizlik sırasında hata fırlatmak yerine loglar (kalan kaynakların da silinmesi için).
private func logIfFailed(status: OSStatus, operation: String) {
    guard status != noErr else {
        return
    }
    Logger(subsystem: "com.senoldogan.AINotepad", category: "SystemAudioCapture")
        .error("Temizlik başarısız: \(operation, privacy: .public), durum: \(status, privacy: .public)")
}

private func propertyAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

/// Sistemin varsayılan çıkış cihazı.
private func defaultOutputDeviceID() throws -> AudioObjectID {
    var address: AudioObjectPropertyAddress = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
    var deviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
    try check(
        status: AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID),
        operation: "DefaultOutputDevice"
    )
    return deviceID
}

/// Bir ses cihazının kalıcı UID'si.
private func deviceUID(deviceID: AudioObjectID) throws -> String {
    var address: AudioObjectPropertyAddress = propertyAddress(selector: kAudioDevicePropertyDeviceUID)
    var uid: Unmanaged<CFString>?
    var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(status: AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid), operation: "DeviceUID")
    guard let value = uid?.takeRetainedValue() else {
        throw AudioCaptureError.coreAudio(operation: "kAudioDevicePropertyDeviceUID (empty)", status: 0)
    }
    return value as String
}

/// Tap'in ürettiği sesin formatı.
private func tapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
    var address: AudioObjectPropertyAddress = propertyAddress(selector: kAudioTapPropertyFormat)
    var description: AudioStreamBasicDescription = AudioStreamBasicDescription()
    var size: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(status: AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description), operation: "TapFormat")
    return description
}
#endif
