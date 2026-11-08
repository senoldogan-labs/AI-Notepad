import Foundation

// Dosya içe aktarma işleri (iPhone): kullanıcının seçtiği ya da paylaştığı dosyalar ve görüşme kaydı ayrı işlerdir.
// Hatalar işine bağlıdır: arka planda gelen arama kaydı, kullanıcının süren içe aktarmasının hatalarını silmez.

/// İçe aktarmanın kaynağı.
public enum ImportSource: Sendable, Equatable {
    /// Kullanıcının seçtiği ya da paylaşım sayfasından gelen dosyalar.
    case files
    /// Görüşme kaydı (uygulamadan yapılan arama ya da deneysel görüşme yakalama).
    case callRecording
}

/// Bir içe aktarma işi: aynı anda verilen dosyalar.
public struct ImportJob: Sendable, Equatable {
    public let id: UUID
    public let source: ImportSource
    /// Henüz bitmeyen dosya sayısı.
    public let remaining: Int
    /// İçe aktarılamayan dosyaların nedenleri (sırayla, tekrarsız).
    public let errors: [String]

    public init(id: UUID, source: ImportSource, remaining: Int, errors: [String]) {
        self.id = id
        self.source = source
        self.remaining = remaining
        self.errors = errors
    }
}

/// Yeni iş: aynı kaynağın biten işleri (ve hataları) düşer, süren işler ve başka kaynağın hataları kalır. Saf
/// fonksiyondur.
public func beginningImportJob(jobs: [ImportJob], id: UUID, source: ImportSource, count: Int) -> [ImportJob] {
    jobs.filter { (job: ImportJob) -> Bool in job.source != source || job.remaining > 0 }
        + [ImportJob(id: id, source: source, remaining: count, errors: [])]
}

/// İşin bir dosyası içe aktarıldı. Bilinmeyen ya da biten iş değişmez. Saf fonksiyondur.
public func finishingImportItem(jobs: [ImportJob], id: UUID) -> [ImportJob] {
    jobs.map { (job: ImportJob) -> ImportJob in
        guard job.id == id, job.remaining > 0 else {
            return job
        }
        return ImportJob(id: job.id, source: job.source, remaining: job.remaining - 1, errors: job.errors)
    }
}

/// İşin bir dosyası içe aktarılamadı: dosya biter, nedeni işin hatalarına eklenir. Bilinmeyen ya da biten iş değişmez.
/// Saf fonksiyondur.
public func failingImportItem(jobs: [ImportJob], id: UUID, message: String) -> [ImportJob] {
    jobs.map { (job: ImportJob) -> ImportJob in
        guard job.id == id, job.remaining > 0 else {
            return job
        }
        let errors: [String] = job.errors.contains(message) ? job.errors : job.errors + [message]
        return ImportJob(id: job.id, source: job.source, remaining: job.remaining - 1, errors: errors)
    }
}

/// İçe aktarılmakta olan dosya sayısı. Saf fonksiyondur.
public func importingCount(jobs: [ImportJob]) -> Int {
    jobs.reduce(0) { (total: Int, job: ImportJob) -> Int in total + job.remaining }
}

/// Gösterilen hatalar (işlerin sırasıyla, tekrarsız). Saf fonksiyondur.
public func importErrors(jobs: [ImportJob]) -> [String] {
    jobs.flatMap(\.errors).reduce(into: [String]()) { (shown: inout [String], message: String) -> Void in
        if !shown.contains(message) {
            shown.append(message)
        }
    }
}
