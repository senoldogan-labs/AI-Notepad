import Foundation
import os

private let checkpointLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ProcessingCheckpoint")

/// Son geçişi bitmiş toplantının işleme kontrol noktası (toplantı klasöründe). İşleme not adımında kesilirse (uygulama
/// kapandı, iPhone'da sistem işlemeyi durdurdu) yeniden işleme ses dönüştürmeyi ve son geçişi atlayıp nottan sürer: ses
/// yeniden yüklenmez ve yeniden faturalanmaz. Not uzunsa parçaları da kaldığı yerden sürer (`noteProgressFileName`).
let processingCheckpointFileName: String = "processing-checkpoint.json"

/// Kontrol noktasının kopyaladığı alanlar: son geçişin ve konuşmacıların sonucu. Toplantının diğer alanları (başlık,
/// notlar, işaretler) işlemeye verilen kayıttan gelir. Saf fonksiyondur.
public func resumingFromCheckpoint(record: MeetingRecord, checkpoint: MeetingRecord) -> MeetingRecord {
    record
        .with(translations: checkpoint.translations)
        .with(finalSegments: checkpoint.finalSegments, language: checkpoint.language)
        .with(speakerNames: checkpoint.speakerNames)
        .with(voiceprints: checkpoint.voiceprints)
        .with(notice: checkpoint.notice)
        .with(meNeedsFinalPass: checkpoint.meNeedsFinalPass)
}

/// Kontrol noktasını atomik yazar; yazılamazsa `StorageError`.
func saveProcessingCheckpoint(record: MeetingRecord, directory: URL) throws {
    let url: URL = directory.appending(path: processingCheckpointFileName)
    do {
        let encoder: JSONEncoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: url, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Bu toplantının kontrol noktası; yoksa ya da başka toplantınınsa nil. Okunamayan dosya loglanır ve yok sayılır
/// (işleme baştan yapılır).
func loadProcessingCheckpoint(directory: URL, recordID: String) -> MeetingRecord? {
    let url: URL = directory.appending(path: processingCheckpointFileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }
    do {
        let record: MeetingRecord = try meetingDecoder().decode(MeetingRecord.self, from: Data(contentsOf: url))
        guard record.id == recordID else {
            checkpointLogger.error("İşleme kontrol noktası başka toplantının, yok sayıldı, toplantı: \(recordID, privacy: .public)")
            return nil
        }
        return record
    } catch {
        checkpointLogger.error("İşleme kontrol noktası okunamadı, işleme baştan yapılacak, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// İşlenmiş toplantı saklandıktan sonra kontrol noktasını siler (yoksa bir şey yapmaz); silinemezse `StorageError`.
public func removeProcessingCheckpoint(directory: URL) throws {
    let url: URL = directory.appending(path: processingCheckpointFileName)
    guard FileManager.default.fileExists(atPath: url.path) else {
        return
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        throw StorageError.deleteFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// Toplantı baştan yeniden işlenecek ("Tekrar işle"): kontrol noktası ve son geçiş parça ilerlemesi silinir, ses yeniden
/// yazıya dökülür. Silinemeyen dosya `StorageError`.
public func discardProcessingProgress(directory: URL) throws {
    try removeProcessingCheckpoint(directory: directory)
    try removeFinalPassProgress(directory: directory)
}
