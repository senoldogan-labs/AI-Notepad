import Foundation
import os
import SpeakerKit
import WhisperKit

/// SpeakerKit (Pyannote) ile ses izi: model ilk kullanımda yüklenir (yoksa ~40 MB indirilir) ve örnek yaşadıkça
/// bellekte kalır; kayıt boyunca her dakika aynı model kullanılır.
public actor SpeakerKitVoiceEmbedder: VoiceEmbedder {
    private let modelsDirectory: URL
    private var kit: SpeakerKit?

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    public func clusters(samples: [Float]) async throws -> [VoiceCluster] {
        do {
            let loaded: SpeakerKit = try await loadedKit()
            // Çekirdekte de `DiarizationResult` olduğu için sonuç tipi adıyla yazılamaz.
            let result = try await loaded.diarize(audioArray: samples)
            let turns: [Int: [ClosedRange<Double>]] = result.segments.reduce(into: [Int: [ClosedRange<Double>]]()) { (turns: inout [Int: [ClosedRange<Double>]], segment: SpeakerSegment) -> Void in
                if let id = segment.speaker.speakerId, segment.endTime > segment.startTime {
                    turns[id, default: []].append(Double(segment.startTime)...Double(segment.endTime))
                }
            }
            return result.speakerCentroidEmbeddings.keys.sorted().compactMap { (id: Int) -> VoiceCluster? in
                guard let centroid = result.speakerCentroidEmbeddings[id], let spoken = turns[id] else {
                    return nil
                }
                return VoiceCluster(turns: spoken, centroid: centroid)
            }
        } catch {
            throw TranscriptionError.diarizationFailed(reason: String(describing: error))
        }
    }

    private func loadedKit() async throws -> SpeakerKit {
        if let kit {
            return kit
        }
        let loaded: SpeakerKit = try await SpeakerKit(PyannoteConfig(
            downloadBase: modelsDirectory.path, download: true, load: true, verbose: false, logLevel: .error
        ))
        kit = loaded
        return loaded
    }
}

/// Ses izi modelinin (SpeakerKit Pyannote: bölütleyici, gömme ve PLDA) yaklaşık indirme boyutu (MB).
public let voiceModelDownloadMegabytes: Int = 40

/// Ses izi modeli denetlenemedi ya da indirilemedi.
public enum VoiceModelError: Error, Equatable {
    /// Bu cihazdaki model dosyaları doğrulanamadı.
    case checkFailed(reason: String)
    /// İndirme (yeniden denemelerle) başarısız oldu.
    case downloadFailed(reason: String)
}

private let voiceModelLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "VoiceModel")

/// Ses izi modeli bu cihazda tam mı (dosyalar ve özetleri ağsız doğrulanır). Model yoksa ya da yarım indirildiyse false;
/// doğrulama başka bir nedenle olmazsa `VoiceModelError.checkFailed`.
public func voiceModelIsDownloaded(modelsDirectory: URL) async throws -> Bool {
    // Protokol üzerinden: alt sınıfın ve `ModelManager`'ın aynı adlı indirme yöntemleri karışmasın.
    let diarizer: any Diarizer = SpeakerKitDiarizer.pyannote(config: PyannoteConfig(
        downloadBase: modelsDirectory.path, download: false, load: false, verbose: false, logLevel: .error
    ))
    do {
        try await diarizer.downloadModels()
        return true
    } catch ModelDownloaderError.modelUnavailable {
        return false
    } catch {
        throw VoiceModelError.checkFailed(reason: String(describing: error))
    }
}

/// Ses izi modelini (~40 MB, Hugging Face) indirir; ilerleme 0…1 olarak bildirilir. Model zaten tamsa ağ kullanılmaz.
/// Ağ hatasında 3 kez artan beklemeyle yeniden denenir (her deneme uyarı olarak loglanır); hepsi başarısız olursa
/// `VoiceModelError.downloadFailed`. Görev iptal edilirse `CancellationError`.
public func downloadVoiceModel(modelsDirectory: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
    do {
        try await retryWithBackoff(attempts: 3, delaySec: 2, isolation: nil) { () async throws -> Void in
            // Üst sınıf üzerinden: alt sınıfın aynı adlı (`@Sendable` geri çağırmalı) yöntemiyle karışmasın.
            let manager: ModelManager = SpeakerKitDiarizer.pyannote(config: PyannoteConfig(
                downloadBase: modelsDirectory.path, download: true, load: false, verbose: false, logLevel: .error
            ))
            try await manager.downloadModels { (progress: Progress) -> Void in
                onProgress(progress.fractionCompleted)
            }
            try Task.checkCancellation()
        } onFailure: { (attempt: Int, error: any Error) -> Void in
            voiceModelLogger.warning("Ses izi modeli indirilemedi, deneme: \(attempt, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw VoiceModelError.downloadFailed(reason: String(describing: error))
    }
}

/// Dosyayı ya da klasörü cihaz yedeğinin (iCloud/bilgisayar yedeği) dışında tutar: iPhone'da ses izleri cihazdan
/// çıkmasın, yeniden indirilebilen modeller yedeği büyütmesin. Yazılamazsa `StorageError.writeFailed`.
public func excludeFromBackup(url: URL) throws {
    var target: URL = url
    var values: URLResourceValues = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
        try target.setResourceValues(values)
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Kayıt dosyasını 16 kHz mono örneklere çevirir.
public func loadMonoSamples(url: URL) throws -> [Float] {
    do {
        return try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
    } catch {
        throw StorageError.readFailed(path: url.path, reason: String(describing: error))
    }
}

/// Kayıtlı seslerin dosyası: kullanıcı verisinin altında `Voices.json` (yalnızca sayılar; ses saklanmaz; bkz.
/// `AppPaths.userDataDirectory`).
public func voicesFileURL() throws -> URL {
    try AppPaths.userDataDirectory().appending(path: "Voices.json")
}

/// Kayıtlı sesleri okur; dosya henüz yoksa boş.
public func loadRegisteredVoices(url: URL) throws -> [RegisteredVoice] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return []
    }
    do {
        let decoder: JSONDecoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([RegisteredVoice].self, from: Data(contentsOf: url))
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Kayıtlı sesleri atomik olarak yazar.
public func saveRegisteredVoices(voices: [RegisteredVoice], url: URL) throws {
    do {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(voices).write(to: url, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
}
