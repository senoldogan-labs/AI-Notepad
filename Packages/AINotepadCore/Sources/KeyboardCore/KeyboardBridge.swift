import Foundation

/// Uygulama ile klavyenin paylaştığı App Group.
public let keyboardAppGroupIdentifier: String = "group.com.senoldogan.AINotepad.hosted"

/// App Group'taki dosyalar.
public enum KeyboardSharedFile: String, Sendable, CaseIterable {
    /// Klavye → uygulama: sesle yazma komutu.
    case command = "command.json"
    /// Uygulama → klavye: oturum ve dikte durumu.
    case status = "status.json"
    /// Uygulama → klavye: ayarlar ve sözlük.
    case config = "config.json"
    /// Uygulama → klavye: toplantı listesi (isteğe bağlı).
    case meetings = "meetings.json"
    /// Klavye → uygulama: son görülme.
    case report = "report.json"
    /// Klavye → uygulama: Gistsmith'e soru.
    case askCommand = "ask.json"
    /// Uygulama → klavye: sorunun cevabı.
    case askAnswer = "ask-answer.json"
}

/// Dosya değişince karşı tarafa giden Darwin bildirimleri (yük taşımaz; okuyan dosyayı okur).
public enum KeyboardSignal: String, Sendable, CaseIterable {
    case command = "com.senoldogan.AINotepad.hosted.keyboard.command"
    case status = "com.senoldogan.AINotepad.hosted.keyboard.status"
    case ask = "com.senoldogan.AINotepad.hosted.keyboard.ask"
    case askAnswer = "com.senoldogan.AINotepad.hosted.keyboard.askAnswer"
}

/// App Group dosyası okunamadı ya da yazılamadı.
public enum KeyboardBridgeError: Error, Equatable, CustomStringConvertible {
    /// App Group kabı yok (yetki eksik ya da Tam Erişim kapalı).
    case containerUnavailable(group: String)
    case writeFailed(file: String, reason: String)
    case decodeFailed(file: String, reason: String)

    public var description: String {
        switch self {
        case let .containerUnavailable(group):
            "App Group container unavailable: \(group)"
        case let .writeFailed(file, reason):
            "Keyboard file write failed: \(file): \(reason)"
        case let .decodeFailed(file, reason):
            "Keyboard file decode failed: \(file): \(reason)"
        }
    }
}

/// App Group'taki klavye klasörüne okuyup yazan ve Darwin bildirimi gönderen bağlayıcı. Uygulamada ve klavyede aynı.
/// Komut, durum ve toplantı dosyaları cihaz kilitliyken okunamaz (`complete` / `completeUnlessOpen`) ve yedeğe girmez.
public final class KeyboardBridge: Sendable {
    private let folder: URL

    /// App Group kabı yoksa (`containerURL` nil) `containerUnavailable`.
    public init(containerURL: URL?) throws {
        guard let containerURL else {
            throw KeyboardBridgeError.containerUnavailable(group: keyboardAppGroupIdentifier)
        }
        self.folder = containerURL.appendingPathComponent("Keyboard", isDirectory: true)
    }

    /// Dosyayı çözer; dosya yoksa nil.
    public func read<Value: Decodable>(_ type: Value.Type, file: KeyboardSharedFile) throws -> Value? {
        let url: URL = folder.appendingPathComponent(file.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw KeyboardBridgeError.decodeFailed(file: file.rawValue, reason: String(describing: error))
        }
        do {
            return try keyboardDecoder().decode(type, from: data)
        } catch {
            throw KeyboardBridgeError.decodeFailed(file: file.rawValue, reason: String(describing: error))
        }
    }

    /// Dosyayı atomik yazar; toplantı dosyası `completeUnlessOpen`, diğerleri `complete` korumasıyla.
    public func write<Value: Encodable>(_ value: Value, file: KeyboardSharedFile) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var url: URL = folder.appendingPathComponent(file.rawValue)
            let data: Data = try keyboardEncoder().encode(value)
            // Toplantı listesi kilitliyken de açık klavyede okunabilsin; diğerleri (dikte, soru, cevap) kilitte okunamaz.
            let protection: Data.WritingOptions = file == .meetings ? .completeFileProtectionUnlessOpen : .completeFileProtection
            try data.write(to: url, options: [.atomic, protection])
            var values: URLResourceValues = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            throw KeyboardBridgeError.writeFailed(file: file.rawValue, reason: String(describing: error))
        }
    }

    /// Dosyayı siler; yoksa bir şey yapmaz.
    public func remove(file: KeyboardSharedFile) throws {
        let url: URL = folder.appendingPathComponent(file.rawValue)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw KeyboardBridgeError.writeFailed(file: file.rawValue, reason: String(describing: error))
        }
    }

    /// Karşı tarafa "dosya değişti" der.
    public func post(_ signal: KeyboardSignal) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(signal.rawValue as CFString), nil, nil, true
        )
    }
}

private func keyboardEncoder() -> JSONEncoder {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
}

private func keyboardDecoder() -> JSONDecoder {
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
}

/// Darwin bildirimini dinler; geldikçe `handler` ana kuyrukta çağrılır. `cancel()` ya da nesne bırakılınca dinleme
/// biter.
public final class KeyboardSignalObserver {
    private let name: CFNotificationName
    private let handler: @MainActor () -> Void
    private var isObserving: Bool = true

    public init(signal: KeyboardSignal, handler: @escaping @MainActor () -> Void) {
        self.name = CFNotificationName(signal.rawValue as CFString)
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { (_: CFNotificationCenter?, observer: UnsafeMutableRawPointer?, _: CFNotificationName?, _: UnsafeRawPointer?, _: CFDictionary?) -> Void in
                guard let observer else {
                    return
                }
                let instance: KeyboardSignalObserver = Unmanaged<KeyboardSignalObserver>.fromOpaque(observer).takeUnretainedValue()
                let handler: @MainActor () -> Void = instance.handler
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        handler()
                    }
                }
            },
            signal.rawValue as CFString, nil, .deliverImmediately
        )
    }

    public func cancel() {
        guard isObserving else {
            return
        }
        isObserving = false
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(), name, nil)
    }

    deinit {
        cancel()
    }
}
