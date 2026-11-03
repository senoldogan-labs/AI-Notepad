#if CALL_CAPTURE_EXPERIMENT
import AINotepadCore
import AVFoundation
import CoreMedia

// Deneysel: iPhone'da çalışan görüşmenin (Teams/Zoom) sesini ScreenCaptureKit ile kaydetme. Yalnız
// `CALL_CAPTURE_EXPERIMENT` derleme ayarıyla derlenir (bkz. docs/superpowers/specs/2026-11-03-iphone-call-capture-research.md).

/// Yakalanan sesin kaynağı.
enum CallAudioSource: String, Sendable, CaseIterable {
    /// Sistem sesi: diğer uygulamaların çaldığı ses (ör. görüşmedeki karşı taraf).
    case system
    /// Mikrofon (seçicide kullanıcı açtıysa).
    case microphone

    /// Ham dosyanın adı (oturum klasöründe).
    var fileName: String {
        switch self {
        case .system: "system.m4a"
        case .microphone: "mic.m4a"
        }
    }
}

/// Bir kaynağın kayıt boyunca biriken sayaçları (ekranda görünür; cihaz testinin sonucu bunlarla raporlanır).
struct CallSourceStats: Equatable, Sendable {
    /// Gelen ses parçası sayısı.
    var buffers: Int
    /// Gelen sesin toplam süresi (saniye).
    var seconds: Double
    /// Sessizlik eşiğinin üstündeki sesin süresi (saniye): karşı taraf konuştukça artar.
    var loudSeconds: Double
    /// Doldurulan boşlukların toplamı (saniye): akış parça vermediyse araya sessizlik yazıldı.
    var gapSeconds: Double
    /// Kayıt boyunca en yüksek seviye (0...1).
    var peakLevel: Float
    /// İlk parçanın akış saatindeki zamanı (saniye); iki kaynağı hizalamak için.
    var firstTime: Double?

    static let empty: CallSourceStats = CallSourceStats(buffers: 0, seconds: 0, loudSeconds: 0, gapSeconds: 0, peakLevel: 0, firstTime: nil)
}

/// "Sesli" sayılan en düşük seviye (`audioLevel` ölçeğinde 0...1; 0.25 ≈ -45 dBFS). Saf sabit.
let callLoudLevelThreshold: Float = 0.25

/// Beklenen zamandan bu kadar (saniye) geç gelen parça boşluk sayılır; arası sessizlikle doldurulur.
let callGapToleranceSec: Double = 0.1

/// Bir boşluğa en fazla bu kadar sessizlik yazılır (saat sıçraması dosyayı şişirmesin).
let callMaxGapFillSec: Double = 600

/// Parça `actual` saniyede geldi, `expected`'ta beklenmişti: araya yazılacak sessizlik örnek sayısı. Saf fonksiyondur.
func callSilenceFrames(expected: Double?, actual: Double, sampleRate: Double, toleranceSec: Double, maxFillSec: Double) -> Int {
    guard let expected else {
        return 0
    }
    let gap: Double = actual - expected
    guard gap > toleranceSec else {
        return 0
    }
    return Int((min(gap, maxFillSec) * sampleRate).rounded())
}

/// Sayaçlara bir parçayı ekler. Saf fonksiyondur.
func callStatsAdding(stats: CallSourceStats, time: Double, durationSec: Double, gapSec: Double, level: Float) -> CallSourceStats {
    CallSourceStats(
        buffers: stats.buffers + 1,
        seconds: stats.seconds + durationSec,
        loudSeconds: stats.loudSeconds + (level >= callLoudLevelThreshold ? durationSec : 0),
        gapSeconds: stats.gapSeconds + gapSec,
        peakLevel: max(stats.peakLevel, level),
        firstTime: stats.firstTime ?? time
    )
}

/// Ses yakalama ya da birleştirme hatası.
enum CallCaptureError: Error, Equatable {
    case notAvailable
    case noAudioFormat(source: String)
    case unsupportedSampleFormat(source: String, format: String)
    case formatChanged(source: String, from: String, to: String)
    case copyFailed(source: String, status: String)
    case writeFailed(path: String, reason: String)
    case nothingCaptured
    case exportFailed(path: String, reason: String)
}

/// `AVAudioPCMBuffer`'ın ilk kanalındaki örnekleri Float olarak (seviye ölçümü için). Float32 ve Int16 desteklenir.
func callFirstChannelSamples(buffer: AVAudioPCMBuffer, source: CallAudioSource) throws -> [Float] {
    let frames: Int = Int(buffer.frameLength)
    let stride: Int = buffer.stride
    if let channels = buffer.floatChannelData {
        return (0..<frames).map { channels[0][$0 * stride] }
    }
    if let channels = buffer.int16ChannelData {
        return (0..<frames).map { Float(channels[0][$0 * stride]) / Float(Int16.max) }
    }
    throw CallCaptureError.unsupportedSampleFormat(source: source.rawValue, format: String(describing: buffer.format))
}

/// Bir kaynağın ses parçalarını AAC dosyasına yazan bağdaştırıcı. Dosya ilk parçanın biçimiyle açılır; parça
/// gelmeyen aralıklar sessizlikle doldurulur (iki kaynak sonradan hizalı karışsın).
///
/// Yalnız yakalama kuyruğunda (tek seri kuyruk) kullanılır; başka iş parçacığından dokunulmaz.
final class CallAudioFileSink {
    let source: CallAudioSource
    let url: URL
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    /// Bir sonraki parçanın beklenen zamanı (akış saatinde, saniye).
    private var nextTime: Double?
    private(set) var stats: CallSourceStats = .empty

    init(source: CallAudioSource, url: URL) {
        self.source = source
        self.url = url
    }

    /// Parçayı dosyaya yazar, seviyesini (0...1) döndürür.
    func append(sampleBuffer: CMSampleBuffer) throws -> Float {
        guard let description = sampleBuffer.formatDescription else {
            throw CallCaptureError.noAudioFormat(source: source.rawValue)
        }
        let incoming: AVAudioFormat = AVAudioFormat(cmAudioFormatDescription: description)
        let frameCount: Int = sampleBuffer.numSamples
        let buffer: AVAudioPCMBuffer = try pcmBuffer(format: incoming, frames: frameCount)
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<frameCount, into: buffer.mutableAudioBufferList)
        } catch {
            throw CallCaptureError.copyFailed(source: source.rawValue, status: String(describing: error))
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let output: AVAudioFile = try openFile(format: incoming)
        let time: Double = sampleBuffer.presentationTimeStamp.seconds
        let silence: Int = callSilenceFrames(
            expected: nextTime, actual: time, sampleRate: incoming.sampleRate, toleranceSec: callGapToleranceSec, maxFillSec: callMaxGapFillSec
        )
        try writeSilence(file: output, format: incoming, frames: silence)
        try write(file: output, buffer: buffer)
        let duration: Double = Double(frameCount) / incoming.sampleRate
        nextTime = time + duration
        let level: Float = audioLevel(samples: try callFirstChannelSamples(buffer: buffer, source: source))
        stats = callStatsAdding(stats: stats, time: time, durationSec: duration, gapSec: Double(silence) / incoming.sampleRate, level: level)
        return level
    }

    /// Dosyayı kapatır (AAC son paketleri yazılır). Hiç parça gelmediyse dosya yoktur.
    func close() {
        file?.close()
        file = nil
    }

    private func pcmBuffer(format: AVAudioFormat, frames: Int) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(frames, 1))) else {
            throw CallCaptureError.unsupportedSampleFormat(source: source.rawValue, format: String(describing: format))
        }
        return buffer
    }

    /// Dosyayı ilk parçanın biçimiyle açar; biçim sonradan değişirse (ör. mikrofon rotası) hata verir.
    private func openFile(format incoming: AVAudioFormat) throws -> AVAudioFile {
        if let file, let format {
            guard format == incoming else {
                throw CallCaptureError.formatChanged(source: source.rawValue, from: String(describing: format), to: String(describing: incoming))
            }
            return file
        }
        let settings: [String: any Sendable] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: incoming.sampleRate,
            AVNumberOfChannelsKey: incoming.channelCount,
            AVEncoderBitRateKey: 64000,
        ]
        let created: AVAudioFile
        do {
            created = try AVAudioFile(forWriting: url, settings: settings, commonFormat: incoming.commonFormat, interleaved: incoming.isInterleaved)
        } catch {
            throw CallCaptureError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
        file = created
        format = incoming
        return created
    }

    private func writeSilence(file: AVAudioFile, format: AVAudioFormat, frames: Int) throws {
        var remaining: Int = frames
        let chunk: Int = Int(format.sampleRate)
        while remaining > 0 {
            let count: Int = min(remaining, chunk)
            let buffer: AVAudioPCMBuffer = try pcmBuffer(format: format, frames: count)
            // Yeni tampon sıfırla dolu gelmeyebilir: açıkça sıfırlanır.
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData {
                    memset(data, 0, Int(audioBuffer.mDataByteSize))
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try write(file: file, buffer: buffer)
            remaining -= count
        }
    }

    private func write(file: AVAudioFile, buffer: AVAudioPCMBuffer) throws {
        do {
            try file.write(from: buffer)
        } catch {
            throw CallCaptureError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}

/// Birleştirilecek bir ham dosya ve akıştaki başlangıç kayması (saniye).
struct CallTrack: Sendable {
    let url: URL
    let offsetSec: Double
}

/// Kaynakların ilk parça zamanlarından dosya kaymaları: en erken başlayan 0. Parça gelmeyen kaynak atlanır. Saf fonksiyondur.
func callTracks(files: [(url: URL, firstTime: Double?)]) -> [CallTrack] {
    let started: [(url: URL, firstTime: Double)] = files.compactMap { (file: (url: URL, firstTime: Double?)) -> (url: URL, firstTime: Double)? in
        file.firstTime.map { (url: file.url, firstTime: $0) }
    }
    guard let origin = started.map(\.firstTime).min() else {
        return []
    }
    return started.map { CallTrack(url: $0.url, offsetSec: $0.firstTime - origin) }
}

/// Ham dosyaları (sistem sesi + mikrofon) kaymalarıyla tek ses izine karıştırıp `destination`'a m4a yazar; dosya
/// mevcut içe aktarma hattına (`importMediaAudio`) verilir.
func mixCallAudio(tracks: [CallTrack], destination: URL) async throws {
    guard !tracks.isEmpty else {
        throw CallCaptureError.nothingCaptured
    }
    let composition: AVMutableComposition = AVMutableComposition()
    for track in tracks {
        let asset: AVURLAsset = AVURLAsset(url: track.url)
        let sources: [AVAssetTrack]
        let duration: CMTime
        do {
            sources = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw CallCaptureError.exportFailed(path: track.url.path, reason: error.localizedDescription)
        }
        guard let source = sources.first,
              let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CallCaptureError.exportFailed(path: track.url.path, reason: "ses izi yok")
        }
        do {
            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration), of: source, at: CMTime(seconds: track.offsetSec, preferredTimescale: 48000)
            )
        } catch {
            throw CallCaptureError.exportFailed(path: track.url.path, reason: error.localizedDescription)
        }
    }
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
        throw CallCaptureError.exportFailed(path: destination.path, reason: "AppleM4A dışa aktarma oturumu açılamadı")
    }
    do {
        try await export.export(to: destination, as: .m4a)
    } catch {
        throw CallCaptureError.exportFailed(path: destination.path, reason: error.localizedDescription)
    }
}
#endif
