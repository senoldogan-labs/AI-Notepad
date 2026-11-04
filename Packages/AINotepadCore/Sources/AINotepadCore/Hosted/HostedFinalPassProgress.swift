import Foundation
import os

private let progressLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "FinalPassProgress")

/// Son geçişin bir parçasının ilerlemesi: kaydın hangi örneklerini kapsadığı, yüklemenin anahtarı (aynı parçanın her
/// denemesi aynı anahtarla gider: sunucu yanıtı kaybolan yüklemenin sonucunu yeniden faturalamadan döndürür, bkz.
/// `server/src/transcriptionCache.ts`) ve tamamlandıysa sunucunun yanıtı (ElevenLabs JSON'u).
public struct HostedChunkProgress: Codable, Sendable, Equatable {
    public let startSample: Int
    public let sampleCount: Int
    public let uploadKey: String
    public let response: Data?

    public init(startSample: Int, sampleCount: Int, uploadKey: String, response: Data?) {
        self.startSample = startSample
        self.sampleCount = sampleCount
        self.uploadKey = uploadKey
        self.response = response
    }
}

/// Bir kaydın (`others` ya da `me`) son geçiş ilerlemesi: kaydın örnek sayısı (aynı kayıt olduğunun denetimi) ve sıradaki
/// parçalar. Uygulama son geçiş sürerken kapanır ya da sistem işlemeyi keserse (iPhone'da arka plan süresi biter)
/// yeniden işleme tamamlanan parçaları yeniden yüklemez ve yeniden faturalamaz; uzun (1–4 saatlik) kayıtta kaldığı
/// parçadan sürer.
public struct HostedFinalPassProgress: Codable, Sendable, Equatable {
    public let totalSamples: Int
    public let chunks: [HostedChunkProgress]

    public init(totalSamples: Int, chunks: [HostedChunkProgress]) {
        self.totalSamples = totalSamples
        self.chunks = chunks
    }
}

/// Toplantı klasöründeki son geçiş ilerleme dosyalarının ön eki (`final-pass-others.json`, `final-pass-me.json`).
let finalPassProgressPrefix: String = "final-pass-"

/// Kaydın son geçiş ilerleme dosyası: kaydın yanında, adıyla (`others.caf` → `final-pass-others.json`). Saf fonksiyondur.
public func hostedFinalPassProgressURL(audioURL: URL) -> URL {
    audioURL.deletingLastPathComponent().appending(path: "\(finalPassProgressPrefix)\(audioURL.deletingPathExtension().lastPathComponent).json")
}

/// Kaydı aynı örnek sayısıyla yeniden okununca kullanılabilecek ilerleme; başka kaydınsa (ör. kayıt `.m4a`'ya dönüşmüş ve
/// örnek sayısı değişmiş) boş ilerleme. Saf fonksiyondur.
public func usableFinalPassProgress(progress: HostedFinalPassProgress?, totalSamples: Int) -> HostedFinalPassProgress {
    guard let progress, progress.totalSamples == totalSamples else {
        return HostedFinalPassProgress(totalSamples: totalSamples, chunks: [])
    }
    return progress
}

/// `index`. parçanın kayıtlı ilerlemesi; parça aynı örnekleri kapsamıyorsa (parçalama değişti) nil. Saf fonksiyondur.
public func resumableChunk(progress: HostedFinalPassProgress, index: Int, span: AudioChunkSpan) -> HostedChunkProgress? {
    guard progress.chunks.indices.contains(index) else {
        return nil
    }
    let chunk: HostedChunkProgress = progress.chunks[index]
    guard chunk.startSample == span.startSample, chunk.sampleCount == span.sampleCount else {
        return nil
    }
    return chunk
}

/// `index`. parçanın ilerlemesi yazılmış yeni ilerleme: sonraki parçaların kaydı atılır (parça yeniden yüklendiğinde
/// sonrakiler onun ardından yeniden hesaplanır). Saf fonksiyondur.
public func recordingChunk(progress: HostedFinalPassProgress, index: Int, chunk: HostedChunkProgress) -> HostedFinalPassProgress {
    let kept: [HostedChunkProgress] = Array(progress.chunks.prefix(index))
    return HostedFinalPassProgress(totalSamples: progress.totalSamples, chunks: kept + [chunk])
}

/// Kayıtlı ilerleme; dosya yoksa nil. Okunamayan dosya (bozuk) loglanır ve yok sayılır: son geçiş baştan yapılır.
func loadFinalPassProgress(url: URL) -> HostedFinalPassProgress? {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }
    do {
        return try JSONDecoder().decode(HostedFinalPassProgress.self, from: Data(contentsOf: url))
    } catch {
        progressLogger.error("Son geçiş ilerlemesi okunamadı, baştan yapılacak, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// İlerlemeyi atomik yazar. Yazılamazsa son geçiş yine sürer (yalnızca kaldığı yerden devam edilemez); hata loglanır.
func saveFinalPassProgress(progress: HostedFinalPassProgress, url: URL) {
    do {
        try JSONEncoder().encode(progress).write(to: url, options: .atomic)
    } catch {
        progressLogger.error("Son geçiş ilerlemesi yazılamadı, hata: \(String(describing: error), privacy: .private)")
    }
}

/// Toplantı klasöründeki son geçiş ilerleme dosyalarını siler (son geçişin sonucu işleme kontrol noktasına yazıldı ya
/// da toplantı baştan yeniden işleniyor). Silinemeyen dosya `StorageError`.
public func removeFinalPassProgress(directory: URL) throws {
    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: error.localizedDescription)
    }
    for name in names where name.hasPrefix(finalPassProgressPrefix) && name.hasSuffix(".json") {
        let url: URL = directory.appending(path: name)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw StorageError.deleteFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}
