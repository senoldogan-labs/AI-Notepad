import AVFoundation
import Foundation

/// 16 kHz mono Float örnekleri 16-bit PCM `.caf` dosyasına yazar.
///
/// CAF, yazma sırasında uygulama çökse bile okunabilir kalır. Thread-safe değildir;
/// tek bir görevden kullanılır.
public final class CafRecorder {
    /// Kapatılınca `nil`: macOS 14'te dosya ancak son referansı bırakılınca kapanır.
    private var file: AVAudioFile?
    private let fileURL: URL

    public init(fileURL: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            self.file = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioCaptureError.recorderFailed(path: fileURL.path, reason: String(describing: error))
        }
        self.fileURL = fileURL
    }

    /// Örnekleri dosyanın sonuna ekler.
    public func append(samples: [Float]) throws {
        guard !samples.isEmpty else {
            return
        }
        guard let file else {
            throw AudioCaptureError.recorderFailed(path: fileURL.path, reason: "kayıt dosyası kapatıldıktan sonra yazılmak istendi")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else {
            throw AudioCaptureError.recorderFailed(path: fileURL.path, reason: "tampon oluşturulamadı (\(samples.count) örnek)")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { (source: UnsafeBufferPointer<Float>) -> Void in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioCaptureError.recorderFailed(path: fileURL.path, reason: String(describing: error))
        }
    }

    /// Dosyayı kapatır; sonrasında `append` çağrılmamalıdır.
    public func close() {
        if let file {
            closeAudioFile(file)
        }
        file = nil
    }
}
