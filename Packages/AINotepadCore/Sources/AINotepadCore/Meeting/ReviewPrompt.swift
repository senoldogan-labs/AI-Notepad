import Foundation

// Değerlendirme isteği: iPhone'da App Store'un kendi değerlendirme penceresi (`AppStore.requestReview`), Mac'te (App
// Store dışı, notarize edilmiş DMG; Mac App Store değerlendirmesi yok) ana pencerede bir kez görünen, kapatılabilir
// "Bir arkadaşına öner / Geri bildirim yaz" şeridi. İkisi de aynı olumlu anda sorulur: bu cihazda notu başarıyla
// yazılan üçüncü (ve sonraki) gerçek toplantıdan hemen sonra; kayıt sürerken, son not hatasının üstüne, başka bir teklif
// açıkken, aynı sürümde ikinci kez ve yılda üçten fazla sorulmaz (Apple da yılda en çok üç kez gösterir).

/// İsteğin açılması için bu cihazda notu yazılmış en az gerçek toplantı sayısı.
public let reviewPromptMinimumNotedMeetings: Int = 3

/// Not yazılamadıktan sonra istek bu kadar süre (sn) sorulmaz: hatanın hemen ardından "beğendin mi?" denmez.
public let reviewPromptFailureCooldownSec: Double = 24 * 60 * 60

/// Son 365 günde en çok istek sayısı (Apple'ın sınırıyla aynı).
public let reviewPromptMaxPerYear: Int = 3

/// Yıllık sınırın penceresi (sn).
private let reviewPromptYearSec: Double = 365 * 24 * 60 * 60

/// Geçmişte tutulan en çok toplantı kimliği (yalnız sayım için; eşik `reviewPromptMinimumNotedMeetings`).
private let reviewPromptTrackedMeetingLimit: Int = 20

/// Geçmişin UserDefaults anahtarı.
public let reviewPromptHistoryDefaultsKey: String = "reviewPrompt.history"

/// İsteğin bu cihazdaki geçmişi (UserDefaults'ta JSON).
public struct ReviewPromptHistory: Sendable, Equatable, Codable {
    /// Bu cihazda notu başarıyla yazılan gerçek toplantıların kimlikleri (tekrarsız, en yenisi sonda).
    public let notedMeetingIDs: [String]
    /// Bir toplantının notunun son yazılamadığı an; yoksa nil.
    public let lastFailureAt: Date?
    /// İsteğin gösterildiği anlar (en çok son 365 gün tutulur).
    public let promptedAt: [Date]
    /// İsteğin gösterildiği uygulama sürümleri.
    public let promptedVersions: [String]

    public init(notedMeetingIDs: [String], lastFailureAt: Date?, promptedAt: [Date], promptedVersions: [String]) {
        self.notedMeetingIDs = notedMeetingIDs
        self.lastFailureAt = lastFailureAt
        self.promptedAt = promptedAt
        self.promptedVersions = promptedVersions
    }

    /// Hiç kullanılmamış geçmiş.
    public static let empty: ReviewPromptHistory = ReviewPromptHistory(notedMeetingIDs: [], lastFailureAt: nil, promptedAt: [], promptedVersions: [])
}

/// İşleme bittiği andaki durum (uygulama verir).
public struct ReviewPromptContext: Sendable, Equatable {
    /// Ör. "0.2.1" (`CFBundleShortVersionString`).
    public let appVersion: String
    /// Kayıt sürüyor mu (başka bir toplantı kaydediliyor ya da işleniyor).
    public let isRecording: Bool
    /// Uygulama önde mi (arkadayken istek gösterilmez).
    public let isAppActive: Bool
    /// Başka bir teklif ya da tam ekran sunum açık mı (abonelik teklifi, karşılama, kullanım bildirimi).
    public let isOtherPromptVisible: Bool
    public let now: Date

    public init(appVersion: String, isRecording: Bool, isAppActive: Bool, isOtherPromptVisible: Bool, now: Date) {
        self.appVersion = appVersion
        self.isRecording = isRecording
        self.isAppActive = isAppActive
        self.isOtherPromptVisible = isOtherPromptVisible
        self.now = now
    }
}

/// İsteğin neden sorulmadığı (loglar ve testler için).
public enum ReviewPromptSkip: String, Sendable, Equatable {
    case noteNotWritten
    case sampleMeeting
    case tooFewNotes
    case recentFailure
    case recording
    case inBackground
    case otherPromptVisible
    case alreadyAskedThisVersion
    case yearlyLimit
}

/// İsteğin kararı.
public enum ReviewPromptDecision: Sendable, Equatable {
    case request
    case skip(ReviewPromptSkip)
}

/// Toplantının notu başarıyla yazıldı mı: örnek toplantı değil, bitti ve notu var. Saf fonksiyondur.
public func isSuccessfulNote(record: MeetingRecord) -> Bool {
    !record.isSampleMeeting && record.status == .done && record.note != nil
}

/// Toplantının notu yazılamadı mı: işleme başarısız, yarıda kaldı ya da bitti ama not yok. Çevrimdışı sıraya giren
/// (`queued`) toplantı hata sayılmaz. Saf fonksiyondur.
public func isFailedNote(record: MeetingRecord) -> Bool {
    guard !record.isSampleMeeting else {
        return false
    }
    switch record.status {
    case .failed, .interrupted:
        return true
    case .done:
        return record.note == nil
    case .recording, .processing, .queued:
        return false
    }
}

/// İşlenen toplantı geçmişe işlenir: not yazıldıysa kimliği sayılır (tekrar işleme ikinci kez saymaz), yazılamadıysa
/// hata anı saklanır; örnek toplantı geçmişi değiştirmez. Saf fonksiyondur.
public func reviewPromptHistory(afterProcessing record: MeetingRecord, history: ReviewPromptHistory, now: Date) -> ReviewPromptHistory {
    if isSuccessfulNote(record: record) {
        let ids: [String] = history.notedMeetingIDs.filter { $0 != record.id } + [record.id]
        return ReviewPromptHistory(
            notedMeetingIDs: Array(ids.suffix(reviewPromptTrackedMeetingLimit)), lastFailureAt: history.lastFailureAt,
            promptedAt: history.promptedAt, promptedVersions: history.promptedVersions
        )
    }
    if isFailedNote(record: record) {
        return ReviewPromptHistory(
            notedMeetingIDs: history.notedMeetingIDs, lastFailureAt: now, promptedAt: history.promptedAt, promptedVersions: history.promptedVersions
        )
    }
    return history
}

/// İstek gösterildi: an ve sürüm geçmişe eklenir, 365 günden eski anlar atılır. Saf fonksiyondur.
public func reviewPromptHistory(afterPromptIn version: String, history: ReviewPromptHistory, now: Date) -> ReviewPromptHistory {
    let recent: [Date] = history.promptedAt.filter { now.timeIntervalSince($0) < reviewPromptYearSec }
    let versions: [String] = history.promptedVersions.contains(version) ? history.promptedVersions : history.promptedVersions + [version]
    return ReviewPromptHistory(
        notedMeetingIDs: history.notedMeetingIDs, lastFailureAt: history.lastFailureAt, promptedAt: recent + [now], promptedVersions: versions
    )
}

/// Az önce işlenen toplantıdan sonra istek sorulsun mu. `history`, toplantı işlendikten sonraki geçmiştir (bkz.
/// `reviewPromptHistory(afterProcessing:history:now:)`). Saf fonksiyondur.
public func reviewPromptDecision(record: MeetingRecord, history: ReviewPromptHistory, context: ReviewPromptContext) -> ReviewPromptDecision {
    if record.isSampleMeeting {
        return .skip(.sampleMeeting)
    }
    if !isSuccessfulNote(record: record) {
        return .skip(.noteNotWritten)
    }
    if history.notedMeetingIDs.count < reviewPromptMinimumNotedMeetings {
        return .skip(.tooFewNotes)
    }
    if let failure = history.lastFailureAt, context.now.timeIntervalSince(failure) < reviewPromptFailureCooldownSec {
        return .skip(.recentFailure)
    }
    if context.isRecording {
        return .skip(.recording)
    }
    if !context.isAppActive {
        return .skip(.inBackground)
    }
    if context.isOtherPromptVisible {
        return .skip(.otherPromptVisible)
    }
    if history.promptedVersions.contains(context.appVersion) {
        return .skip(.alreadyAskedThisVersion)
    }
    let lastYear: Int = history.promptedAt.filter { context.now.timeIntervalSince($0) < reviewPromptYearSec }.count
    if lastYear >= reviewPromptMaxPerYear {
        return .skip(.yearlyLimit)
    }
    return .request
}

/// Az önce işlenen toplantıların sonucu: güncel geçmiş ve isteğin şimdi sorulup sorulmayacağı.
public struct ReviewPromptStep: Sendable, Equatable {
    public let history: ReviewPromptHistory
    public let shouldRequest: Bool
}

/// İşlemesi biten toplantılar sırayla geçmişe işlenir; biri isteği açarsa istek bir kez sorulur ve geçmişe yazılır
/// (aynı anda biten iki toplantı iki istek açmaz). Saf fonksiyondur.
public func reviewPromptStep(finished: [MeetingRecord], history: ReviewPromptHistory, context: ReviewPromptContext) -> ReviewPromptStep {
    finished.reduce(ReviewPromptStep(history: history, shouldRequest: false)) { (step: ReviewPromptStep, record: MeetingRecord) -> ReviewPromptStep in
        let updated: ReviewPromptHistory = reviewPromptHistory(afterProcessing: record, history: step.history, now: context.now)
        guard !step.shouldRequest, reviewPromptDecision(record: record, history: updated, context: context) == .request else {
            return ReviewPromptStep(history: updated, shouldRequest: step.shouldRequest)
        }
        return ReviewPromptStep(history: reviewPromptHistory(afterPromptIn: context.appVersion, history: updated, now: context.now), shouldRequest: true)
    }
}

/// Geçmişi okur; hiç yazılmadıysa boş geçmiş. Bozuksa `DecodingError` (yutulmaz; çağıran loglar).
public func loadReviewPromptHistory(defaults: UserDefaults) throws -> ReviewPromptHistory {
    guard let data = defaults.data(forKey: reviewPromptHistoryDefaultsKey) else {
        return .empty
    }
    return try JSONDecoder().decode(ReviewPromptHistory.self, from: data)
}

/// Geçmişi yazar.
public func saveReviewPromptHistory(history: ReviewPromptHistory, defaults: UserDefaults) throws {
    defaults.set(try JSONEncoder().encode(history), forKey: reviewPromptHistoryDefaultsKey)
}

/// Toplantının işleme durumu, listedeki değişimi ucuzca izlemek için (görünüm `onChange` ile karşılaştırır; bütün
/// toplantıyı karşılaştırmak metin ve notları da tarardı).
public struct MeetingProcessingMark: Sendable, Equatable {
    public let id: String
    public let status: MeetingStatus

    public init(id: String, status: MeetingStatus) {
        self.id = id
        self.status = status
    }
}

/// Toplantıların işleme durumları (listenin sırasıyla). Saf fonksiyondur.
public func meetingProcessingMarks(records: [MeetingRecord]) -> [MeetingProcessingMark] {
    records.map { MeetingProcessingMark(id: $0.id, status: $0.status) }
}

/// Önceki listede kaydediliyor, işleniyor ya da çevrimdışı sırada olup şimdiki listede bunlardan çıkan toplantılar:
/// bu cihazda işlemesi az önce biten toplantılar. Yeni gelen (ör. eşitlemeyle) ya da zaten bitmiş toplantılar sayılmaz;
/// böylece istek kayıt ve işleme koduna dokunmadan listedeki değişimden izlenir. Saf fonksiyondur.
public func meetingsFinishedProcessing(previous: [MeetingProcessingMark], current: [MeetingProcessingMark]) -> [String] {
    let inFlight: Set<MeetingStatus> = [.recording, .processing, .queued]
    let wasInFlight: Set<String> = Set(previous.filter { inFlight.contains($0.status) }.map(\.id))
    return current.filter { wasInFlight.contains($0.id) && !inFlight.contains($0.status) }.map(\.id)
}
