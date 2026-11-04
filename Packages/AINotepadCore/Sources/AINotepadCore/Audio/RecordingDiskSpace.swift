import Foundation

/// Kayıt sürerken her ses akışının `.caf` dosyasına saniyede yazılan bayt: 16 kHz mono 16-bit PCM (`CafRecorder`),
/// dakikada ~1,9 MB, saatte ~115 MB.
public let cafBytesPerSecond: Int64 = 16_000 * 2

/// Kayıt bitince her akışın dönüştürüldüğü `.m4a`'nın saniyelik baytı: 32 kbps AAC (`convertToM4A`), saatte ~14 MB.
/// Dönüştürme sırasında `.caf` henüz silinmemiştir: ikisi birlikte diskte durur.
public let m4aBytesPerSecond: Int64 = 32_000 / 8

/// İşlemenin geçici son geçiş parçası için ayrılan yer: sunucuya giden FLAC parçası en çok 95 MB'tır (`HostedAudio`).
public let finalPassChunkReserveBytes: Int64 = 100_000_000

/// Diskte her zaman boş bırakılan pay: sistem, toplantı dosyası (`meeting.json`) ve kontrol noktaları yazılabilsin.
public let diskSafetyMarginBytes: Int64 = 200_000_000

/// Kayıt öncesi denetimde beklenen en uzun kayıt: abonelikteki toplantı sınırı (4 saat).
public let expectedRecordingSec: Double = 4 * 3600

/// Kayıt sürerken boş yerin denetlenme aralığı (sn).
public let diskSpaceCheckIntervalSec: Double = 30

/// Bu kadar dakikadan kısa kayda yer varsa kayıt başlatılmaz: başlar başlamaz durdurulurdu.
public let minimumRecordableMinutes: Int = 5

/// Kayıt öncesi boş yerin durumu.
public enum RecordingDiskSpace: Sendable, Equatable {
    /// Beklenen en uzun kayda ve işlemesine yer var.
    case enough
    /// Yer var ama beklenen en uzun kayda yetmiyor: yaklaşık bu kadar dakikalık kayıt sığar (uyarı).
    case low(recordableMinutes: Int)
    /// Kısa bir kayda bile yer yok: kayıt başlatılmaz.
    case full
}

/// Kayıt saniyesi başına gereken yer: her akışın `.caf`'ı ve dönüştürülen `.m4a`'sı. Saf fonksiyondur.
public func recordingBytesPerSecond(streams: Int) -> Int64 {
    Int64(max(streams, 0)) * (cafBytesPerSecond + m4aBytesPerSecond)
}

/// Boş yerle kaç saniyelik kayıt (ve işlemesi) sığar: işleme payı ve güvenlik payı ayrıldıktan sonra. Saf fonksiyondur.
public func recordableSeconds(availableBytes: Int64, streams: Int) -> Double {
    let usable: Int64 = availableBytes - finalPassChunkReserveBytes - diskSafetyMarginBytes
    let perSecond: Int64 = recordingBytesPerSecond(streams: streams)
    guard usable > 0, perSecond > 0 else {
        return 0
    }
    return Double(usable) / Double(perSecond)
}

/// Kayıt başlamadan önce boş yer beklenen süreye yetiyor mu. Saf fonksiyondur.
public func recordingDiskSpace(availableBytes: Int64, expectedDurationSec: Double, streams: Int) -> RecordingDiskSpace {
    let seconds: Double = recordableSeconds(availableBytes: availableBytes, streams: streams)
    let minutes: Int = Int(seconds / 60)
    if minutes < minimumRecordableMinutes {
        return .full
    }
    return seconds >= expectedDurationSec ? .enough : .low(recordableMinutes: minutes)
}

/// Kayıt sürerken kayıt şimdi durdurulmalı mı: boş yer, kaydedilenin `.m4a`'ya dönüştürülmesine, işleme ve güvenlik
/// payına ve sonraki denetime kadar (iki aralık: denetim gecikebilir) yazılacak sese yetmiyor. Durdurulunca o ana kadar
/// kaydedilen her şey saklanır ve işlenir. Saf fonksiyondur.
public func shouldStopRecordingForDiskSpace(availableBytes: Int64, recordedSec: Double, streams: Int, checkIntervalSec: Double) -> Bool {
    let conversion: Int64 = Int64(max(recordedSec, 0).rounded(.up)) * Int64(max(streams, 0)) * m4aBytesPerSecond
    let nextInterval: Int64 = Int64((2 * checkIntervalSec).rounded(.up)) * recordingBytesPerSecond(streams: streams)
    return availableBytes < conversion + nextInterval + finalPassChunkReserveBytes + diskSafetyMarginBytes
}

/// Klasörün bulunduğu birimde önemli işler (kullanıcının başlattığı kayıt) için kullanılabilir yer (bayt). Sistem
/// gerekirse temizlenebilir önbellekleri de sayar (`volumeAvailableCapacityForImportantUsage`).
public func availableCapacityForImportantUsage(directory: URL) throws -> Int64 {
    let values: URLResourceValues
    do {
        values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: "boş yer okunamadı: \(error.localizedDescription)")
    }
    guard let capacity = values.volumeAvailableCapacityForImportantUsage else {
        throw StorageError.readFailed(path: directory.path, reason: "boş yer bilinmiyor")
    }
    return capacity
}
