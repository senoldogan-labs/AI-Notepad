import Foundation

// Kaydın yaşam döngüsü (Mac ve iPhone ortak): boşta → başlatılıyor → kaydediliyor → bitiriliyor → boşta. Durum tek
// değerdir; her olay saf `recorderStep` ile yeni durumu ve uygulamanın yapacağı işleri (`RecorderEffect`) üretir.
// Uygulamalar yalnızca işleri yürüten ince bağdaştırıcılardır (mikrofon, sunucu oturumu, dosyalar). Her kayıt kendi
// kimliğini ve başlarken açılan sunucu oturumunu taşır: kapanış, duraklatma bildirimi ve bildirimlerdeki eylemler bu
// değerleri kullanır (genel "şimdiki toplantı" kayıt bitince okunmaz; oturum kapansa da kaydın oturumu bilinir).

/// Bir kaydın kimliği: başlatma isteğinde üretilir; bildirimler ve kilit ekranı eylemleri bunu taşır, başka kaydın
/// eylemi yok sayılır.
public struct RecordingID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

/// Kaydın sunucu oturumu (kayıt başlarken bir kez belirlenir).
public enum RecordingServerSession: Equatable, Sendable {
    /// Sunucu oturumu yok (geliştirici sürümü: kendi anahtarların).
    case local
    /// Sunucuda açılan toplantı oturumu: kapanış ve duraklatma bildirimleri bu kimlikle gider.
    case online(meetingID: String)
    /// Sunucuya ulaşılamadan başladı: toplantı bağlantı gelince işlenir.
    case offline

    /// Açık sunucu oturumunun kimliği; yoksa nil.
    public var meetingID: String? {
        if case .online(let meetingID) = self {
            return meetingID
        }
        return nil
    }
}

/// Süren kaydın duraklatması: kullanıcının duraklatması ile kesintinin (iPhone'da arama, alarm) duraklatması ayrıdır.
/// Kesinti bitince yalnız kesintinin duraklatması kalkar; kullanıcı kesinti sürerken "Devam"a basarsa kayıt kesinti
/// bitene dek duraklatılmış kalır (aramadaki sessizlik kaydedilmez).
public enum RecorderPause: Equatable, Sendable {
    case running
    case user(since: Date)
    case interruption(since: Date)
    case both(userSince: Date, interruptionSince: Date)

    /// Ses kaydedilmiyor (herhangi bir nedenle).
    public var isPaused: Bool {
        self != .running
    }

    /// Kullanıcı duraklattı (kesinti de sürüyor olabilir).
    public var isPausedByUser: Bool {
        switch self {
        case .user, .both:
            true
        case .running, .interruption:
            false
        }
    }
}

/// Başlatmanın beklediği adım.
public enum RecorderStartStage: Equatable, Sendable {
    /// Hazırlık (ayarlar, anahtarlar, klasör).
    case preparing
    /// Ses akışları açılıyor (ilk kullanımda izin penceresi): bitirme isteği akışları kapatarak beklemeyi keser.
    case awaitingCapture
    /// Ses akışları açık; sunucu oturumu ve canlı motor bekleniyor.
    case awaitingServer
}

/// Başlatma sürerken gelen istekler: başlatma her adımdan sonra bunlara göre ilerler ya da bırakılır.
public struct RecorderStartIntents: Equatable, Sendable {
    /// "Bitir"/"İptal" istendi: kayıt başlamaz; açılan sunucu oturumu kapatılır, toplantı oluşmaz.
    public let stop: Bool
    /// "Kaydı sil" istendi (bitirmeyle birlikte).
    public let discard: Bool
    /// "Sen" (mikrofon) kapalı olsun: kayıt başlarken değiştirilen ayar başladığı anda uygulanır.
    public let micMuted: Bool
    /// Mikrofon kesintide (iPhone'da arama, alarm): kayıt kesinti duraklatmasıyla başlar.
    public let interrupted: Bool

    public init(stop: Bool, discard: Bool, micMuted: Bool, interrupted: Bool) {
        self.stop = stop
        self.discard = discard
        self.micMuted = micMuted
        self.interrupted = interrupted
    }
}

/// Başlatılıyor.
public struct RecorderStarting: Equatable, Sendable {
    public let id: RecordingID
    public let stage: RecorderStartStage
    public let intents: RecorderStartIntents
    /// Ses akışlarının açıldığı an (süre buradan sayılır); henüz açılmadıysa nil.
    public let capturedAt: Date?
    /// Açılan sunucu oturumu; henüz açılmadıysa nil.
    public let server: RecordingServerSession?

    public init(id: RecordingID, stage: RecorderStartStage, intents: RecorderStartIntents, capturedAt: Date?, server: RecordingServerSession?) {
        self.id = id
        self.stage = stage
        self.intents = intents
        self.capturedAt = capturedAt
        self.server = server
    }
}

/// Kaydediliyor.
public struct RecorderRecording: Equatable, Sendable {
    public let id: RecordingID
    public let server: RecordingServerSession
    public let startedAt: Date
    public let pause: RecorderPause
    /// Duraklatma saati: süre göstergeleri ve süre sınırı duraklatılan zamanı saymaz.
    public let clock: PauseClock
    public let micMuted: Bool

    public init(id: RecordingID, server: RecordingServerSession, startedAt: Date, pause: RecorderPause, clock: PauseClock, micMuted: Bool) {
        self.id = id
        self.server = server
        self.startedAt = startedAt
        self.pause = pause
        self.clock = clock
        self.micMuted = micMuted
    }
}

/// Bitirmenin adımı.
public enum RecorderFinishStage: Equatable, Sendable {
    /// Ses kapandı; canlı oturum kalan sesi bitiriyor. `deadline`'da beklenmeden kapatılır.
    case draining(deadline: Date)
    /// Canlı oturum bitti: bekleyen çeviriler ve sunucu oturumunun kapanışı (uygulama ikisini de süreyle sınırlar).
    case closing
}

/// Bitiriliyor.
public struct RecorderFinishing: Equatable, Sendable {
    public let id: RecordingID
    public let server: RecordingServerSession
    public let startedAt: Date
    /// "Bitir"e basılan (ya da oturumun kendiliğinden bittiği) an: süre burada durur.
    public let stoppedAt: Date
    /// Bitirme anında donmuş duraklatma saati.
    public let clock: PauseClock
    /// "Kaydı sil": bitince toplantı işlenmez, klasörü silinir. Bitirme sürerken de istenebilir.
    public let discardRequested: Bool
    public let stage: RecorderFinishStage

    public init(id: RecordingID, server: RecordingServerSession, startedAt: Date, stoppedAt: Date, clock: PauseClock, discardRequested: Bool, stage: RecorderFinishStage) {
        self.id = id
        self.server = server
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.clock = clock
        self.discardRequested = discardRequested
        self.stage = stage
    }
}

/// Kaydedicinin durumu.
public enum RecorderState: Equatable, Sendable {
    case idle
    case starting(RecorderStarting)
    case recording(RecorderRecording)
    case finishing(RecorderFinishing)
    /// Son başlatma başarısız oldu (nedeni uygulamada görünür); boşta gibi yeni kayıt başlayabilir.
    case failed(RecordingID)

    /// Süren (başlatılan, kaydedilen ya da bitirilen) kaydın kimliği; yoksa nil.
    public var activeID: RecordingID? {
        switch self {
        case .idle, .failed:
            nil
        case .starting(let starting):
            starting.id
        case .recording(let recording):
            recording.id
        case .finishing(let finishing):
            finishing.id
        }
    }

    /// Yeni kayıt başlatılabilir (boşta ya da son başlatma başarısız).
    public var isIdle: Bool {
        activeID == nil
    }

    public var isStarting: Bool {
        if case .starting = self {
            return true
        }
        return false
    }

    /// Kaydediliyor (bitirilmiyor).
    public var isRecording: Bool {
        if case .recording = self {
            return true
        }
        return false
    }

    public var isFinishing: Bool {
        if case .finishing = self {
            return true
        }
        return false
    }

    /// Kaydın sunucu oturumu (kaydediliyor ya da bitiriliyorsa); yoksa nil.
    public var server: RecordingServerSession? {
        switch self {
        case .idle, .failed:
            nil
        case .starting(let starting):
            starting.server
        case .recording(let recording):
            recording.server
        case .finishing(let finishing):
            finishing.server
        }
    }

    /// Kaydın başladığı an (ses akışları açılınca); yoksa nil.
    public var startedAt: Date? {
        switch self {
        case .idle, .failed:
            nil
        case .starting(let starting):
            starting.capturedAt
        case .recording(let recording):
            recording.startedAt
        case .finishing(let finishing):
            finishing.startedAt
        }
    }

    /// Duraklatma saati (kayıt yokken `running`).
    public var clock: PauseClock {
        switch self {
        case .idle, .failed, .starting:
            .running
        case .recording(let recording):
            recording.clock
        case .finishing(let finishing):
            finishing.clock
        }
    }

    /// Kaydın duraklatması (kaydedilmiyorsa `running`).
    public var pause: RecorderPause {
        if case .recording(let recording) = self {
            return recording.pause
        }
        return .running
    }
}

/// Bir eylemin hedefi: uygulamadaki düğmeler süren kaydı, bildirim ve kilit ekranı eylemleri kendi kaydını hedefler
/// (başka kaydınki yok sayılır: eski bir "Kaydı bitir" yeni kaydı bitirmez).
public enum RecorderTarget: Equatable, Sendable {
    case current
    case recording(RecordingID)
}

/// Kaydediciye gelen olay.
public enum RecorderEvent: Equatable, Sendable {
    /// Kayıt istendi (düğme, kısayol, Siri, bildirim, takvim). Kayıt sürerken ya da başlatılırken bir şey yapmaz: başlatma
    /// istekleri hiçbir zaman süren başlatmayı iptal etmez.
    case startRequested(id: RecordingID, micMuted: Bool)
    /// Ses akışları açılıyor (izin penceresi olabilir).
    case awaitingCapture(id: RecordingID)
    /// Ses akışları açıldı.
    case captureOpened(id: RecordingID, at: Date)
    /// Sunucu oturumu açıldı (ya da kayıt çevrimdışı ya da sunucusuz sürer).
    case serverStarted(id: RecordingID, server: RecordingServerSession)
    /// Canlı oturum kuruldu: kayıt başladı.
    case sessionStarted(id: RecordingID, at: Date)
    /// Başlatma başarısız (akış açılamadı, sunucu reddetti, klasör kurulamadı…).
    case startFailed(id: RecordingID)
    /// "Bitir" (başlatılırken "İptal").
    case stopRequested(target: RecorderTarget, at: Date)
    /// "Kaydı sil": bitirir; toplantı işlenmez, klasörü silinir.
    case discardRequested(target: RecorderTarget, at: Date)
    case pauseRequested(target: RecorderTarget, at: Date)
    case resumeRequested(target: RecorderTarget, at: Date)
    /// Mikrofon kesintisi başladı ya da bitti (iPhone: arama, alarm).
    case interruptionChanged(interrupted: Bool, at: Date)
    /// "Sen" (mikrofon) kapatıldı ya da açıldı.
    case micMuteChanged(muted: Bool)
    /// Canlı oturumun kalan sesi beklenmeden kapatılsın (bitirme süresi doldu ya da "Şimdi bitir").
    case finishNow(id: RecordingID)
    /// Canlı oturumun olay akışı bitti (bitirildi ya da ses akışları kendiliğinden kapandı).
    case sessionDrained(id: RecordingID, at: Date)
    /// Bekleyen çeviriler ve sunucu oturumunun kapanışı bitti.
    case closed(id: RecordingID)
}

/// Uygulamanın yürüteceği iş.
public enum RecorderEffect: Equatable, Sendable {
    /// Başlatmayı yürüt (izinler, ses akışları, sunucu oturumu, canlı oturum); her adım olay olarak döner.
    case beginStart(id: RecordingID)
    /// Açılmakta olan ses akışlarını kapat (izin penceresi açıkken iptal).
    case cancelCapture(id: RecordingID)
    /// Başlamayan kaydı bırak: açılan akışlar kapanır, klasör silinir; sunucu oturumu açıldıysa kapatılır (toplantı oluşmaz).
    case abandonStart(id: RecordingID, server: RecordingServerSession?)
    /// "Sen"i (mikrofon) kapat ya da aç.
    case applyMicMuted(id: RecordingID, muted: Bool)
    /// Ses kapılarını duraklat ya da sürdür.
    case setAudioPaused(id: RecordingID, paused: Bool, at: Date)
    /// Duraklatmayı kaydın sunucu oturumuna bildir.
    case reportPause(meetingID: String, paused: Bool)
    /// Yakalamayı durdur ("Bitir"): ses akışları kapanır, canlı oturum kalan sesi bitirir.
    case stopCapture(id: RecordingID)
    /// Bitirmenin süre sınırını kur: `deadline`'da `finishNow` gönderilir.
    case scheduleFinishDeadline(id: RecordingID, deadline: Date)
    /// Canlı oturumu kalan sesi beklemeden bırak.
    case cancelLiveSession(id: RecordingID)
    /// Kapat: bekleyen çevirileri bekle, kaydın sunucu oturumunu (başta yakalanan kimlikle) kapat, sonra `closed` gönder.
    case close(id: RecordingID, server: RecordingServerSession)
    /// Kayıt bitti: toplantıyı sakla ve işle ya da ("Kaydı sil") klasörünü sil. `stoppedAt`: kaydın bittiği an.
    case complete(id: RecordingID, server: RecordingServerSession, discard: Bool, stoppedAt: Date)
    /// Kayıt yokken bitir/duraklat/sürdür: kalmış canlı etkinlik ya da gösterge kaldırılır.
    case dismissStaleIndicators
}

/// Bir olayın sonucu: yeni durum ve sırayla yürütülecek işler.
public struct RecorderStep: Equatable, Sendable {
    public let state: RecorderState
    public let effects: [RecorderEffect]

    public init(state: RecorderState, effects: [RecorderEffect]) {
        self.state = state
        self.effects = effects
    }
}

/// Kaydın durum makinesi. Sırası bozuk ya da başka kayda ait olay durumu değiştirmez. `finishingLimitSec`: "Bitir"den
/// sonra canlı oturumun kalan sesi en çok bu kadar beklenir. Saf fonksiyondur.
public func recorderStep(state: RecorderState, event: RecorderEvent, finishingLimitSec: Double) -> RecorderStep {
    let unchanged: RecorderStep = RecorderStep(state: state, effects: [])
    switch (state, event) {
    // Başlatma: yalnız boştayken; süren kayıtta yinelenen istek hiçbir şey yapmaz (asla iptal etmez).
    case (.idle, .startRequested(let id, let micMuted)), (.failed, .startRequested(let id, let micMuted)):
        let intents: RecorderStartIntents = RecorderStartIntents(stop: false, discard: false, micMuted: micMuted, interrupted: false)
        return RecorderStep(
            state: .starting(RecorderStarting(id: id, stage: .preparing, intents: intents, capturedAt: nil, server: nil)),
            effects: [.beginStart(id: id)]
        )
    case (.starting, .startRequested), (.recording, .startRequested), (.finishing, .startRequested):
        return unchanged

    case (.starting(let starting), .awaitingCapture(let id)) where starting.id == id:
        return RecorderStep(state: .starting(starting.with(stage: .awaitingCapture)), effects: [])
    case (.starting(let starting), .captureOpened(let id, let at)) where starting.id == id:
        guard !starting.intents.stop else {
            return abandon(starting: starting)
        }
        return RecorderStep(state: .starting(starting.with(stage: .awaitingServer).with(capturedAt: at)), effects: [])
    case (.starting(let starting), .serverStarted(let id, let server)) where starting.id == id:
        let next: RecorderStarting = starting.with(server: server)
        guard !starting.intents.stop else {
            return abandon(starting: next)
        }
        return RecorderStep(state: .starting(next), effects: [])
    case (.starting(let starting), .startFailed(let id)) where starting.id == id:
        // İstenen iptal başarısızlık değildir: kayıt boşa döner (hata gösterilmez, uygulama mesajı kendisi seçer).
        let failed: RecorderStep = abandon(starting: starting)
        return starting.intents.stop ? failed : RecorderStep(state: .failed(id), effects: failed.effects)
    case (.starting(let starting), .sessionStarted(let id, let at)) where starting.id == id:
        return started(starting: starting, at: at, finishingLimitSec: finishingLimitSec)

    case (.starting(let starting), .stopRequested(let target, _)) where matches(target: target, id: starting.id):
        return requestStopDuringStart(starting: starting, discard: false)
    case (.starting(let starting), .discardRequested(let target, _)) where matches(target: target, id: starting.id):
        return requestStopDuringStart(starting: starting, discard: true)
    // Başlarken değiştirilen "Sen" ayarı hem saklanır (kayıt başlayınca yeniden uygulanır) hem de açılmış ses kapısına
    // hemen uygulanır: sunucu oturumu beklenirken gelen ses de kapatılan mikrofondan yazılmaz.
    case (.starting(let starting), .micMuteChanged(let muted)):
        return RecorderStep(
            state: .starting(starting.with(intents: starting.intents.with(micMuted: muted))),
            effects: [.applyMicMuted(id: starting.id, muted: muted)]
        )
    case (.starting(let starting), .interruptionChanged(let interrupted, _)):
        return RecorderStep(state: .starting(starting.with(intents: starting.intents.with(interrupted: interrupted))), effects: [])

    case (.recording(let recording), .stopRequested(let target, let at)) where matches(target: target, id: recording.id):
        return stop(recording: recording, at: at, discard: false, finishingLimitSec: finishingLimitSec)
    case (.recording(let recording), .discardRequested(let target, let at)) where matches(target: target, id: recording.id):
        return stop(recording: recording, at: at, discard: true, finishingLimitSec: finishingLimitSec)
    case (.recording(let recording), .pauseRequested(let target, let at)) where matches(target: target, id: recording.id):
        return userPause(recording: recording, at: at)
    case (.recording(let recording), .resumeRequested(let target, let at)) where matches(target: target, id: recording.id):
        return userResume(recording: recording, at: at)
    case (.recording(let recording), .interruptionChanged(let interrupted, let at)):
        return interruption(recording: recording, interrupted: interrupted, at: at)
    case (.recording(let recording), .micMuteChanged(let muted)):
        return RecorderStep(state: .recording(recording.with(micMuted: muted)), effects: [.applyMicMuted(id: recording.id, muted: muted)])
    case (.recording(let recording), .sessionDrained(let id, let at)) where recording.id == id:
        // Ses akışları kendiliğinden kapandı: kayıt o ana dek kaydedilenle biter (arayüz hemen "bitiriliyor" gösterir).
        let finishing: RecorderFinishing = RecorderFinishing(
            id: id, server: recording.server, startedAt: recording.startedAt, stoppedAt: at, clock: recording.clock.resuming(at: at),
            discardRequested: false, stage: .closing
        )
        return RecorderStep(state: .finishing(finishing), effects: [.stopCapture(id: id), .close(id: id, server: recording.server)])

    // Bitirme sürerken "Kaydı sil" de geçerlidir: toplantı işlenmez.
    case (.finishing(let finishing), .discardRequested(let target, _)) where matches(target: target, id: finishing.id):
        return RecorderStep(state: .finishing(finishing.with(discardRequested: true)), effects: [])
    case (.finishing(let finishing), .finishNow(let id)) where finishing.id == id:
        guard case .draining = finishing.stage else {
            return unchanged
        }
        return RecorderStep(
            state: .finishing(finishing.with(stage: .closing)),
            effects: [.cancelLiveSession(id: id), .close(id: id, server: finishing.server)]
        )
    case (.finishing(let finishing), .sessionDrained(let id, _)) where finishing.id == id:
        guard case .draining = finishing.stage else {
            return unchanged
        }
        return RecorderStep(state: .finishing(finishing.with(stage: .closing)), effects: [.close(id: id, server: finishing.server)])
    case (.finishing(let finishing), .closed(let id)) where finishing.id == id && finishing.stage == .closing:
        return RecorderStep(state: .idle, effects: [
            .complete(id: id, server: finishing.server, discard: finishing.discardRequested, stoppedAt: finishing.stoppedAt),
        ])

    // Kayıt yokken bitir/duraklat/sürdür (kilit ekranı, Denetim Merkezi): kalmış gösterge kalkar.
    case (.idle, .stopRequested), (.idle, .pauseRequested), (.idle, .resumeRequested),
         (.failed, .stopRequested), (.failed, .pauseRequested), (.failed, .resumeRequested):
        return RecorderStep(state: state, effects: [.dismissStaleIndicators])

    default:
        return unchanged
    }
}

/// Hedef süren kayıt mı.
private func matches(target: RecorderTarget, id: RecordingID) -> Bool {
    switch target {
    case .current:
        true
    case .recording(let targetID):
        targetID == id
    }
}

/// Başlamayan kayıt bırakılır: boşa döner; açılan sunucu oturumu kapatılır.
private func abandon(starting: RecorderStarting) -> RecorderStep {
    RecorderStep(state: .idle, effects: [.abandonStart(id: starting.id, server: starting.server)])
}

/// Başlatılırken "Bitir"/"İptal"/"Kaydı sil": istek saklanır; akışlar açılıyorsa (izin penceresi) kapatılır.
private func requestStopDuringStart(starting: RecorderStarting, discard: Bool) -> RecorderStep {
    let intents: RecorderStartIntents = starting.intents.with(stop: true).with(discard: starting.intents.discard || discard)
    let effects: [RecorderEffect] = starting.stage == .awaitingCapture && !starting.intents.stop ? [.cancelCapture(id: starting.id)] : []
    return RecorderStep(state: .starting(starting.with(intents: intents)), effects: effects)
}

/// Canlı oturum kuruldu. Başlarken istenenler uygulanır: mikrofon ayarı, kesinti duraklatması; "Bitir" istendiyse kayıt
/// silinerek bitirilir (canlı oturum kurulmuştur; toplantı oluşmaz, açılan sunucu oturumu kapanır).
private func started(starting: RecorderStarting, at: Date, finishingLimitSec: Double) -> RecorderStep {
    let server: RecordingServerSession = starting.server ?? .local
    let startedAt: Date = starting.capturedAt ?? at
    let recording: RecorderRecording = RecorderRecording(
        id: starting.id, server: server, startedAt: startedAt, pause: .running, clock: .running, micMuted: starting.intents.micMuted
    )
    let micEffect: RecorderEffect = .applyMicMuted(id: starting.id, muted: starting.intents.micMuted)
    if starting.intents.stop {
        let stopped: RecorderStep = stop(recording: recording, at: at, discard: true, finishingLimitSec: finishingLimitSec)
        return RecorderStep(state: stopped.state, effects: [micEffect] + stopped.effects)
    }
    guard starting.intents.interrupted else {
        return RecorderStep(state: .recording(recording), effects: [micEffect])
    }
    let paused: RecorderStep = interruption(recording: recording, interrupted: true, at: at)
    return RecorderStep(state: paused.state, effects: [micEffect] + paused.effects)
}

/// "Bitir" (ya da "Kaydı sil"): yakalama durur, canlı oturum kalan sesi `finishingLimitSec` içinde bitirir.
private func stop(recording: RecorderRecording, at: Date, discard: Bool, finishingLimitSec: Double) -> RecorderStep {
    let deadline: Date = at.addingTimeInterval(finishingLimitSec)
    let finishing: RecorderFinishing = RecorderFinishing(
        id: recording.id, server: recording.server, startedAt: recording.startedAt, stoppedAt: at, clock: recording.clock.resuming(at: at),
        discardRequested: discard, stage: .draining(deadline: deadline)
    )
    return RecorderStep(
        state: .finishing(finishing),
        effects: [.stopCapture(id: recording.id), .scheduleFinishDeadline(id: recording.id, deadline: deadline)]
    )
}

/// Kullanıcı duraklattı. Kesinti zaten duraklattıysa ses kapısı ve sunucu değişmez.
private func userPause(recording: RecorderRecording, at: Date) -> RecorderStep {
    switch recording.pause {
    case .running:
        return pausing(recording: recording, pause: .user(since: at), at: at)
    case .interruption(let since):
        return RecorderStep(state: .recording(recording.with(pause: .both(userSince: at, interruptionSince: since))), effects: [])
    case .user, .both:
        return RecorderStep(state: .recording(recording), effects: [])
    }
}

/// Kullanıcı sürdürdü. Kesinti sürüyorsa kayıt kesinti bitene dek duraklatılmış kalır.
private func userResume(recording: RecorderRecording, at: Date) -> RecorderStep {
    switch recording.pause {
    case .user:
        return resuming(recording: recording, at: at)
    case .both(_, let interruptionSince):
        return RecorderStep(state: .recording(recording.with(pause: .interruption(since: interruptionSince))), effects: [])
    case .running, .interruption:
        return RecorderStep(state: .recording(recording), effects: [])
    }
}

/// Kesinti başladı ya da bitti. Kullanıcı da duraklattıysa kesintinin bitişi kaydı sürdürmez.
private func interruption(recording: RecorderRecording, interrupted: Bool, at: Date) -> RecorderStep {
    switch (recording.pause, interrupted) {
    case (.running, true):
        return pausing(recording: recording, pause: .interruption(since: at), at: at)
    case (.user(let since), true):
        return RecorderStep(state: .recording(recording.with(pause: .both(userSince: since, interruptionSince: at))), effects: [])
    case (.interruption, false):
        return resuming(recording: recording, at: at)
    case (.both(let userSince, _), false):
        return RecorderStep(state: .recording(recording.with(pause: .user(since: userSince))), effects: [])
    case (.interruption, true), (.both, true), (.running, false), (.user, false):
        return RecorderStep(state: .recording(recording), effects: [])
    }
}

/// Ses kaydedilmez olur: kapılar duraklar, saat durur, sunucu oturumu varsa bildirilir.
private func pausing(recording: RecorderRecording, pause: RecorderPause, at: Date) -> RecorderStep {
    let next: RecorderRecording = recording.with(pause: pause).with(clock: recording.clock.pausing(at: at))
    return RecorderStep(state: .recording(next), effects: pauseEffects(recording: recording, paused: true, at: at))
}

/// Ses yeniden kaydedilir.
private func resuming(recording: RecorderRecording, at: Date) -> RecorderStep {
    let next: RecorderRecording = recording.with(pause: .running).with(clock: recording.clock.resuming(at: at))
    return RecorderStep(state: .recording(next), effects: pauseEffects(recording: recording, paused: false, at: at))
}

private func pauseEffects(recording: RecorderRecording, paused: Bool, at: Date) -> [RecorderEffect] {
    let gate: RecorderEffect = .setAudioPaused(id: recording.id, paused: paused, at: at)
    guard let meetingID = recording.server.meetingID else {
        return [gate]
    }
    return [gate, .reportPause(meetingID: meetingID, paused: paused)]
}

// MARK: Kopyalar

private extension RecorderStartIntents {
    func with(stop: Bool) -> RecorderStartIntents {
        RecorderStartIntents(stop: stop, discard: discard, micMuted: micMuted, interrupted: interrupted)
    }

    func with(discard: Bool) -> RecorderStartIntents {
        RecorderStartIntents(stop: stop, discard: discard, micMuted: micMuted, interrupted: interrupted)
    }

    func with(micMuted: Bool) -> RecorderStartIntents {
        RecorderStartIntents(stop: stop, discard: discard, micMuted: micMuted, interrupted: interrupted)
    }

    func with(interrupted: Bool) -> RecorderStartIntents {
        RecorderStartIntents(stop: stop, discard: discard, micMuted: micMuted, interrupted: interrupted)
    }
}

private extension RecorderStarting {
    func with(stage: RecorderStartStage) -> RecorderStarting {
        RecorderStarting(id: id, stage: stage, intents: intents, capturedAt: capturedAt, server: server)
    }

    func with(intents: RecorderStartIntents) -> RecorderStarting {
        RecorderStarting(id: id, stage: stage, intents: intents, capturedAt: capturedAt, server: server)
    }

    func with(capturedAt: Date) -> RecorderStarting {
        RecorderStarting(id: id, stage: stage, intents: intents, capturedAt: capturedAt, server: server)
    }

    func with(server: RecordingServerSession) -> RecorderStarting {
        RecorderStarting(id: id, stage: stage, intents: intents, capturedAt: capturedAt, server: server)
    }
}

private extension RecorderRecording {
    func with(pause: RecorderPause) -> RecorderRecording {
        RecorderRecording(id: id, server: server, startedAt: startedAt, pause: pause, clock: clock, micMuted: micMuted)
    }

    func with(clock: PauseClock) -> RecorderRecording {
        RecorderRecording(id: id, server: server, startedAt: startedAt, pause: pause, clock: clock, micMuted: micMuted)
    }

    func with(micMuted: Bool) -> RecorderRecording {
        RecorderRecording(id: id, server: server, startedAt: startedAt, pause: pause, clock: clock, micMuted: micMuted)
    }
}

private extension RecorderFinishing {
    func with(discardRequested: Bool) -> RecorderFinishing {
        RecorderFinishing(id: id, server: server, startedAt: startedAt, stoppedAt: stoppedAt, clock: clock, discardRequested: discardRequested, stage: stage)
    }

    func with(stage: RecorderFinishStage) -> RecorderFinishing {
        RecorderFinishing(id: id, server: server, startedAt: startedAt, stoppedAt: stoppedAt, clock: clock, discardRequested: discardRequested, stage: stage)
    }
}
