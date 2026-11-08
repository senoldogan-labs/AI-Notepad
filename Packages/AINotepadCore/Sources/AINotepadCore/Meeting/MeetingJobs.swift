import Foundation

/// Bir toplantı üzerinde süren iş (kayıt ve işlemeye devir kaydedicinin durumundadır; burada kayıttan sonraki işler).
/// Bir toplantıda aynı anda tek iş çalışır; iş sürerken toplantı kilitlidir (tekrar işle, not düzenle, ses sil…).
public enum MeetingJob: Sendable, Equatable {
    /// Kayıt sonrası işleme (ilerleme kartı adımı gösterir).
    case processing(ProcessingStep)
    /// Not talimatla düzenleniyor.
    case editingNote
    /// Not yeniden yazılıyor (adlar, şablon, konuşmacı önerileri).
    case rewritingNote
    /// Toplantı sonu çevirisi yapılamayan parçalar yeniden çevriliyor.
    case retryingTranslations
}

/// Toplantıya yeni iş başlatır: toplantıda iş yoksa işle birlikte yeni harita, varsa nil (iki iş aynı toplantıyı
/// birbirinin üstüne yazmasın). Saf fonksiyondur.
public func beginningMeetingJob(jobs: [String: MeetingJob], meetingID: String, job: MeetingJob) -> [String: MeetingJob]? {
    guard jobs[meetingID] == nil else {
        return nil
    }
    var next: [String: MeetingJob] = jobs
    next[meetingID] = job
    return next
}

/// İşlemenin yeni adımı: yalnızca toplantıda işleme sürüyorsa yazılır (başka bir iş ya da bitmiş işleme değişmez).
/// Saf fonksiyondur.
public func advancingMeetingJob(jobs: [String: MeetingJob], meetingID: String, step: ProcessingStep) -> [String: MeetingJob] {
    guard case .processing = jobs[meetingID] else {
        return jobs
    }
    var next: [String: MeetingJob] = jobs
    next[meetingID] = .processing(step)
    return next
}

/// İş bitti: toplantı kilidi kalkar. Saf fonksiyondur.
public func endingMeetingJob(jobs: [String: MeetingJob], meetingID: String) -> [String: MeetingJob] {
    var next: [String: MeetingJob] = jobs
    next[meetingID] = nil
    return next
}

/// İşlemesi süren toplantıların adımları (ilerleme kartı). Saf fonksiyondur.
public func processingSteps(jobs: [String: MeetingJob]) -> [String: ProcessingStep] {
    jobs.compactMapValues { (job: MeetingJob) -> ProcessingStep? in
        if case .processing(let step) = job {
            return step
        }
        return nil
    }
}
