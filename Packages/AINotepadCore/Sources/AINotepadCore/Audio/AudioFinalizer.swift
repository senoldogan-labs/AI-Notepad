import AVFoundation
import Foundation

/// Kaydı (ör. `.caf`) 16 kHz mono AAC `.m4a`'ya dönüştürür (32 kbps; saatte ~15 MB). Kaynağı silmez. Dönünce hedef
/// dosya kapanmıştır (bkz. `closeAudioFile`).
public func convertToM4A(source: URL, destination: URL) throws {
    try autoreleasepool {
        try writeM4A(source: source, destination: destination)
    }
}

/// `convertToM4A`'nın işi; dosyalar bu işlevin yerel değişkenleridir, macOS 14'te işlev dönerken bırakılıp kapanır.
private func writeM4A(source: URL, destination: URL) throws {
    let input: AVAudioFile
    do {
        input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw AudioCaptureError.recorderFailed(path: source.path, reason: "okunamadı: \(error)")
    }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000,
    ]
    let output: AVAudioFile
    do {
        output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw AudioCaptureError.recorderFailed(path: destination.path, reason: "yazılamadı: \(error)")
    }
    let chunk: AVAudioFrameCount = 16000 * 10
    guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunk) else {
        throw AudioCaptureError.recorderFailed(path: source.path, reason: "tampon oluşturulamadı")
    }
    do {
        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunk)
            try output.write(from: buffer)
        }
    } catch {
        throw AudioCaptureError.recorderFailed(path: destination.path, reason: "dönüştürülemedi: \(error)")
    }
    // Kapatınca AAC paket tablosu ve süre yazılır (macOS 14'te `output` bu işlev dönünce bırakılıp kapanır).
    closeAudioFile(output)
}

/// `AVAudioFile`'ı hemen kapatır; `close()` macOS 15 ister. macOS 14'te dosya son referansı bırakılınca (deinit)
/// kapanır: çağıran dosyayı bundan sonra tutmamalı ve kapanmış hâlini okumadan önce bırakmalıdır (dosyayı yerel
/// değişkende tutan işlevi `autoreleasepool` içinde çağırıp dönmek: AVFoundation nesneyi otomatik bırakma havuzuna
/// koyduysa da havuz boşalınca kapanır).
func closeAudioFile(_ file: AVAudioFile) {
    if #available(macOS 15.0, *) {
        file.close()
    }
}
