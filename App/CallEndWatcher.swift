import AINotepadCore
import AINotepadUI
import CoreAudio
import Foundation
import SwiftUI

/// Mikrofon girişini şu an kullanan süreçler (Core Audio süreç nesneleri, macOS 14.4+). Ölçüm arasında kapanan sürecin
/// nesnesi geçersizleşir; o süreç artık mikrofonu kullanmıyordur ve listeye girmez. Diğer Core Audio hataları fırlatılır.
func audioInputProcesses() throws -> [AudioInputProcess] {
    let system: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    try checkCoreAudio(status: AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), operation: "kAudioHardwarePropertyProcessObjectList size")
    var objects: [AudioObjectID] = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: Int(size) / MemoryLayout<AudioObjectID>.stride)
    try checkCoreAudio(status: AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects), operation: "kAudioHardwarePropertyProcessObjectList")
    let count: Int = Int(size) / MemoryLayout<AudioObjectID>.stride
    return try objects.prefix(count).compactMap { (object: AudioObjectID) -> AudioInputProcess? in
        var running: UInt32 = 0
        var runningSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let runningStatus: OSStatus = AudioObjectGetPropertyData(object, &runningAddress, 0, nil, &runningSize, &running)
        // Süreç liste okunduktan sonra kapandı: mikrofonu kullanmıyor.
        if runningStatus == kAudioHardwareBadObjectError {
            return nil
        }
        try checkCoreAudio(status: runningStatus, operation: "kAudioProcessPropertyIsRunningInput")
        guard running != 0 else {
            return nil
        }
        var pid: pid_t = 0
        var pidSize: UInt32 = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        let pidStatus: OSStatus = AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid)
        if pidStatus == kAudioHardwareBadObjectError {
            return nil
        }
        try checkCoreAudio(status: pidStatus, operation: "kAudioProcessPropertyPID")
        return AudioInputProcess(pid: pid, bundleID: processBundleID(object: object))
    }
}

/// Süreç nesnesinin paket kimliği (yalnız günlükte); okunamazsa (paketsiz araç, kapanmış süreç) boş.
private func processBundleID(object: AudioObjectID) -> String {
    var bundle: Unmanaged<CFString>?
    var size: UInt32 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &bundle) == noErr, let bundle else {
        return ""
    }
    return bundle.takeRetainedValue() as String
}

private func checkCoreAudio(status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw AudioCaptureError.coreAudio(operation: operation, status: status)
    }
}

/// Kayıt sürerken mikrofonu başka bir uygulamanın kullanıp kullanmadığını 3 sn'de bir ölçer (ince Core Audio
/// bağdaştırıcısı; karar `callEndStep`'te). Ölçüm okunamazsa `onFailure`, okunursa görüşmeye ait süreçlerle (bu
/// uygulamanın kendisi hariç) `onSample` çağrılır.
@MainActor
final class CallEndWatcher {
    static let intervalSec: Double = 3
    private var task: Task<Void, Never>?

    func start(onSample: @escaping @MainActor ([AudioInputProcess]) -> Void, onFailure: @escaping @MainActor (any Error) -> Void) {
        task?.cancel()
        let ownPID: Int32 = getpid()
        task = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    onSample(callInputProcesses(processes: try audioInputProcesses(), ownPID: ownPID))
                } catch {
                    onFailure(error)
                }
                do {
                    try await Task.sleep(for: .seconds(Self.intervalSec))
                } catch {
                    // İptal: kayıt bitti.
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Görüşme bitti gibi görünüyor: kayıt geri sayımın sonunda bitecek; "Kayda devam et" geri sayımı iptal eder, "Şimdi
/// bitir" kaydı hemen ("Bitir" gibi) bitirir. Panelde ve ana pencerede aynı şerit.
struct CallEndNotice: View {
    let deadline: Date
    let onKeep: @MainActor () -> Void
    let onStop: @MainActor () -> Void

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { (context: TimelineViewDefaultContext) in
            let seconds: Int = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
            NoticeBar(severity: .attention, title: Text("Görüşme bitti gibi görünüyor; kayıt \(seconds) sn sonra bitecek"), detail: nil, onDismiss: nil) {
                HStack(spacing: 8) {
                    Button(keepRecordingTitle()) { onKeep() }
                    Button("Şimdi bitir") { onStop() }
                }
            }
        }
    }
}
