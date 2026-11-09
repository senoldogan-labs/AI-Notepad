import AudioToolbox
import KeyboardCore
import os

private let soundLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.keyboard", category: "KeyboardSound")

/// Mekanik klavye sesleri: `scripts/make-keyboard-sounds.py`'nin sentezlediği dört kısa ses (harf, boşluk, satır başı,
/// silme; toplam ~47 KB, lisans meselesi yok). Sistem sesi olarak çalınır: düşük gecikme, küçük bellek, sessiz anahtarına
/// uyar.
final class KeyboardSoundPack {
    private var sounds: [String: SystemSoundID] = [:]

    init(bundle: Bundle) {
        for name in ["key", "space", "return", "delete"] {
            guard let url = bundle.url(forResource: name, withExtension: "caf") else {
                soundLogger.error("Keyboard sound missing: \(name, privacy: .public)")
                continue
            }
            var id: SystemSoundID = 0
            let status: OSStatus = AudioServicesCreateSystemSoundID(url as CFURL, &id)
            guard status == noErr else {
                soundLogger.error("Keyboard sound load failed: \(name, privacy: .public), status \(status, privacy: .public)")
                continue
            }
            sounds[name] = id
        }
    }

    func play(kind: KeyboardKeyKind) {
        let name: String
        switch kind {
        case .space:
            name = "space"
        case .returnKey:
            name = "return"
        case .delete:
            name = "delete"
        default:
            name = "key"
        }
        guard let id = sounds[name] else {
            return
        }
        AudioServicesPlaySystemSound(id)
    }

    deinit {
        for id in sounds.values {
            AudioServicesDisposeSystemSoundID(id)
        }
    }
}
