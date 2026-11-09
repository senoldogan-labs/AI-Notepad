import Foundation
import os

/// Hibrit canlı oturumun Deepgram kaynağı (abonelik sürümü): dil, terimler, adres seçenekleri ve her bağlantıda yeni
/// kısa ömürlü jeton veren kaynak.
public struct DeepgramLiveSource: Sendable {
    /// Akışın dili: sabit dil ya da otomatikte ana toplantı dili (Deepgram akışı dil algılamaz).
    public let language: MeetingLanguage
    public let keyterms: [String]
    public let options: DeepgramListenOptions
    /// Her bağlantıda yeni jeton (sunucudan); jeton saklanmaz.
    public let token: @Sendable () async throws -> String
    /// Akışlardan birinin bağlantısı koptu ya da yeniden kuruldu (güvenilirlik telemetrisi).
    public let onConnectionEvent: @Sendable (DeepgramConnectionEvent) -> Void

    public init(
        language: MeetingLanguage, keyterms: [String], options: DeepgramListenOptions, onConnectionEvent: @escaping @Sendable (DeepgramConnectionEvent) -> Void,
        token: @escaping @Sendable () async throws -> String
    ) {
        self.language = language
        self.keyterms = keyterms
        self.options = options
        self.onConnectionEvent = onConnectionEvent
        self.token = token
    }
}

/// Hibrit oturumun başladığı motor.
public enum HybridLiveStart: Sendable {
    /// Bulut (Deepgram); akış durursa oturum Mac'e geçer.
    case deepgram(DeepgramLiveSource)
    /// Doğrudan Mac (WhisperKit); motor hazırlanırken gelen ses bekletilir.
    case local
    /// Canlı metin yok (bulut kullanılamıyor, cihazda motor yok: iPhone, iOS 18–25): konuşmacılar için `.streamFailed`
    /// `message`'la bildirilir, kayıt sürer.
    case unavailable(message: String)
}

/// Hibrit oturumun kaydı (`startHybridRecording`): iki ses akışı oluşturulduğu anda `me.caf` ve `others.caf`'a yazılır;
/// yazılan ses ve kayıt olayları oturuma aktarılır.
public struct HybridRecording: Sendable {
    let events: AsyncStream<LiveSessionEvent>
    let sink: AsyncStream<LiveSessionEvent>.Continuation
    let me: AsyncStream<[Float]>
    let others: AsyncStream<[Float]>
}

/// İki ses akışını hemen diske yazmaya başlar (kayıt motordan bağımsız, kesintisizdir): toplantı oturumu açılırken ve
/// canlı motor seçilirken (ağ beklenirken) gelen ses de bellekte değil dosyada durur. Yazılan ses, oturum başlayana dek
/// bekletilir ve `runHybridLiveSession`'a verilir.
public func startHybridRecording(directory: URL, meAudio: AsyncStream<[Float]>, othersAudio: AsyncStream<[Float]>) -> HybridRecording {
    let (events, sink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) =
        AsyncStream.makeStream(of: LiveSessionEvent.self)
    return HybridRecording(
        events: events,
        sink: sink,
        me: recordedStream(speaker: .me, audio: meAudio, directory: directory, events: sink),
        others: recordedStream(speaker: .others, audio: othersAudio, directory: directory, events: sink)
    )
}

/// Hibrit canlı oturum ayarları.
public struct HybridLiveSessionConfig: Sendable {
    /// Canlı metni üretilecek konuşmacılar (sesi başlamış olanlar): sessiz akış için Deepgram bağlantısı açılmaz.
    public let speakers: Set<Speaker>
    /// Kayıt sırasında katılabilecek konuşmacılar (mikrofon kapalı başlayan kayıtta "Sen"): Deepgram bağlantısı kayıt
    /// başında değil, ilk sesli parçada açılır (bkz. `startDeepgramStreamOnFirstSound`); öncesindeki sessizlik
    /// gönderilmez.
    public let lateSpeakers: Set<Speaker>
    /// Mac'teki yazıya dökmenin ayarları; `recordingDirectory` alanı kullanılmaz.
    public let local: LiveSessionConfig
    /// Mac motoru hazırlanırken (model inerken) konuşmacı başına bekletilen en uzun ses; daha eskisi canlı metne
    /// katılmaz (kayıtta durur, son geçiş kapsar).
    public let maxPendingAudioSec: Double
    /// Bulut akışı kalıcı olarak durunca: cihazdaki motora geçiş ya da bulutu yeniden deneme (bkz. `hybridCloudFailure`).
    public let cloudFailure: HybridCloudFailure

    public init(
        speakers: Set<Speaker>, lateSpeakers: Set<Speaker>, local: LiveSessionConfig, maxPendingAudioSec: Double, cloudFailure: HybridCloudFailure
    ) {
        self.speakers = speakers
        self.lateSpeakers = lateSpeakers.subtracting(speakers)
        self.local = local
        self.maxPendingAudioSec = maxPendingAudioSec
        self.cloudFailure = cloudFailure
    }
}

/// Mac'e geçişten sonraki bölüm numaralarının başlangıcı: Deepgram bölümleriyle çakışmasın.
let localSegmentIndexBase: Int = 2_000_000

private let hybridSampleRate: Int = 16000
private let hybridLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HybridLiveSession")

/// Abonelik sürümünün canlı oturumu: kaydı süren (`startHybridRecording`) iki ses akışının canlı metnini Deepgram'la (bulut) üretir;
/// Deepgram akışı kalıcı olarak durursa (jeton alınamadı: bütçe, sunucu, ağ; ya da bağlantı kurulamadı) oturum Mac'teki
/// motora (WhisperKit) geçer ve `.liveEngineFellBack` yayınlar. Cihazda motor yoksa (`config.cloudFailure`
/// `.reconnectCloud`: iPhone, iOS 18–25) geçilmez: o konuşmacının bulut akışı geri çekilerek yeniden açılır
/// (`.liveTextReconnecting`, ilk sonuçta `.liveTextReconnected`). `localEngine` motoru gerektiğinde hazırlar (ilk seferde
/// modeli indirir); hazırlanırken gelen ses `maxPendingAudioSec`'e dek bekletilip sonra yazıya dökülür. Motor
/// hazırlanamazsa canlı metin durur (`.streamFailed`), kayıt sürer. Mac'te başlayan oturum (`.local`) aynı yolu kullanır.
///
/// İki giriş akışı bitince kalan metin üretilir ve olay akışı biter; motor hazırlanırken biterse beklenmez (son geçiş
/// kaydın tamamını yazıya döker). Kullanıcı dili değiştirirse o anki motor yeni dile geçer, sonraki geçiş de o dille olur.
public func runHybridLiveSession(
    config: HybridLiveSessionConfig,
    start: HybridLiveStart,
    localEngine: @escaping @Sendable () async throws -> any TranscriptionEngine,
    recording: HybridRecording
) -> LiveSessionHandle {
    let events: AsyncStream<LiveSessionEvent> = recording.events
    let sink: AsyncStream<LiveSessionEvent>.Continuation = recording.sink
    let recorded: [(Speaker, AsyncStream<[Float]>)] = [(.me, recording.me), (.others, recording.others)]
    let maxPendingSamples: Int = Int(config.maxPendingAudioSec * Double(hybridSampleRate))
    let liveSpeakers: [Speaker] = [Speaker.me, Speaker.others].filter { config.speakers.contains($0) || config.lateSpeakers.contains($0) }
    let router: HybridRouter
    switch start {
    case .deepgram(let source):
        var inputs: [Speaker: AsyncStream<[Float]>.Continuation] = [:]
        var streams: [Speaker: DeepgramStream] = [:]
        for speaker in liveSpeakers {
            let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
            inputs[speaker] = input
            let connect: @Sendable (AsyncStream<[Float]>) -> DeepgramStream = { (forward: AsyncStream<[Float]>) -> DeepgramStream in
                connectDeepgram(source: source, language: source.language, audio: forward)
            }
            // Sonradan katılan konuşmacının bağlantısı ilk seste açılır (kayıt başından beri sessiz akış ücretlenmez).
            streams[speaker] = config.speakers.contains(speaker)
                ? connect(audio)
                : startDeepgramStreamOnFirstSound(audio: audio, sampleRate: hybridSampleRate, start: connect)
        }
        router = HybridRouter(backend: .deepgram(inputs: inputs, streams: streams), consumers: streams.count, maxPendingSamples: maxPendingSamples)
        for (speaker, stream) in streams {
            Task {
                await consumeDeepgram(
                    speaker: speaker, stream: stream, source: source, router: router, config: config, localEngine: localEngine, events: sink
                )
            }
        }
    case .local:
        router = HybridRouter(backend: .preparingLocal, consumers: 0, maxPendingSamples: maxPendingSamples)
        startLocalTranscription(router: router, config: config, localEngine: localEngine, events: sink)
    case .unavailable(let message):
        router = HybridRouter(backend: .unavailable, consumers: 0, maxPendingSamples: maxPendingSamples)
        hybridLogger.info("Canlı metin bu kayıtta yok (bulut yok, cihazda motor yok)")
        for speaker in liveSpeakers {
            sink.yield(.streamFailed(speaker: speaker, message: message))
        }
    }

    Task {
        await withTaskGroup(of: Void.self) { (group: inout TaskGroup<Void>) -> Void in
            for (speaker, audio) in recorded {
                group.addTask {
                    for await chunk in audio {
                        await router.route(speaker: speaker, chunk: chunk)
                    }
                    await router.end(speaker: speaker)
                }
            }
        }
        await router.drain()
        sink.finish()
    }
    return LiveSessionHandle(
        events: events,
        languageSetter: { (language: MeetingLanguage) async -> Void in
            let backend: HybridBackend = await router.lock(language: language)
            sink.yield(.languageLocked(language))
            switch backend {
            case .deepgram(_, let streams):
                for stream in streams.values {
                    await stream.switchLanguage(to: language)
                }
            case .local(_, let handle):
                await handle.setLanguage(language)
            case .preparingLocal, .unavailable:
                // Mac motoru başlarken kilitli dili alır.
                break
            }
        },
        canceller: { () async -> Void in
            // Sonraki ses arka uca gitmez (kayıt dosyalara sürer); Deepgram bağlantıları hemen kesilir, Mac oturumu da
            // bırakılır; olay akışı biter.
            switch await router.cancel() {
            case .deepgram(_, let streams):
                for stream in streams.values {
                    await stream.cancel()
                }
            case .local(_, let handle):
                await handle.cancel()
            case .preparingLocal, .unavailable:
                break
            }
            sink.finish()
        }
    )
}

/// Hibrit oturumun o anki yazıya dökme arka ucu.
private enum HybridBackend: Sendable {
    case deepgram(inputs: [Speaker: AsyncStream<[Float]>.Continuation], streams: [Speaker: DeepgramStream])
    /// Mac motoru hazırlanıyor: ses bekletilir.
    case preparingLocal
    case local(inputs: [Speaker: AsyncStream<[Float]>.Continuation], handle: LiveSessionHandle)
    /// Mac motoru hazırlanamadı: canlı metin yok, kayıt sürer.
    case unavailable
}

/// Deepgram akışı durunca verilen karar.
private enum FallbackDecision {
    /// Mac'e geçiş başladı.
    case started
    /// Geçiş zaten başlamış (diğer akış durdu) ya da oturum Mac'te.
    case alreadyLocal
    /// İki giriş de bitti: geçilecek ses yok.
    case ended
}

/// Mac'teki yazıya dökmenin zamanı başladığı mutlak konum (saniye), konuşmacı başına.
struct LocalTimeline: Sendable, Equatable {
    let meStartSec: Double
    let othersStartSec: Double

    func startSec(speaker: Speaker) -> Double {
        switch speaker {
        case .me: meStartSec
        case .others: othersStartSec
        }
    }
}

/// Sesin hangi arka uca gideceğini, geçişi, bekletilen sesi ve bitişi yönetir.
private actor HybridRouter {
    private var backend: HybridBackend
    private let maxPendingSamples: Int
    /// Konuşmacı başına arka uca verilmiş toplam örnek (kaydın zaman çizgisi).
    private var routed: [Speaker: Int] = [.me: 0, .others: 0]
    /// Mac motoru hazırlanırken bekletilen ses ve mutlak başlangıç örneği.
    private var pending: [Speaker: [Float]] = [.me: [], .others: []]
    private var pendingStart: [Speaker: Int] = [.me: 0, .others: 0]
    private var ended: Set<Speaker> = []
    private var lockedLanguage: MeetingLanguage?
    /// Olayları oturuma aktaran ve henüz bitmemiş tüketiciler (Deepgram akışları, Mac oturumu).
    private var activeConsumers: Int
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(backend: HybridBackend, consumers: Int, maxPendingSamples: Int) {
        self.backend = backend
        self.activeConsumers = consumers
        self.maxPendingSamples = maxPendingSamples
    }

    func route(speaker: Speaker, chunk: [Float]) {
        routed[speaker, default: 0] += chunk.count
        switch backend {
        case .deepgram(let inputs, _), .local(let inputs, _):
            inputs[speaker]?.yield(chunk)
        case .preparingLocal:
            // Yerinde eklenir (sözlüğün `default:` alt simgesi değiştirerek erişir): her parçada tüm tamponu kopyalamak
            // 10 dakikalık bekletmede saniyede yüzlerce MB kopya ederdi.
            pending[speaker, default: []].append(contentsOf: chunk)
            // Her parçada kırpmak pahalı: sınır 10 sn aşılınca bir kez kırpılır.
            let count: Int = pending[speaker, default: []].count
            if count > maxPendingSamples + hybridSampleRate * 10 {
                let excess: Int = count - maxPendingSamples
                pending[speaker, default: []].removeFirst(excess)
                pendingStart[speaker, default: 0] += excess
            }
        case .unavailable:
            break
        }
    }

    func end(speaker: Speaker) {
        ended.insert(speaker)
        switch backend {
        case .deepgram(let inputs, _), .local(let inputs, _):
            inputs[speaker]?.finish()
        case .preparingLocal, .unavailable:
            break
        }
    }

    /// Deepgram akışı durdu: ilk duran akış geçişi başlatır (Deepgram girişleri kapanır, ses bekletilmeye başlar).
    func beginFallback() -> FallbackDecision {
        guard case .deepgram(let inputs, _) = backend else {
            return .alreadyLocal
        }
        guard ended.count < 2 else {
            return .ended
        }
        for input in inputs.values {
            input.finish()
        }
        backend = .preparingLocal
        for speaker in [Speaker.me, Speaker.others] {
            pending[speaker] = []
            pendingStart[speaker] = routed[speaker, default: 0]
        }
        return .started
    }

    /// Mac motoru hazır: girişler bağlanır, bekleyen ses aktarılır, bitmiş konuşmacıların girişi kapanır. Mac zamanının
    /// mutlak başlangıcı döner; iki giriş de bittiyse nil (Mac oturumu başlatılmaz).
    func activateLocal(inputs: [Speaker: AsyncStream<[Float]>.Continuation], handle: LiveSessionHandle) -> LocalTimeline? {
        guard case .preparingLocal = backend, ended.count < 2 else {
            pending = [.me: [], .others: []]
            return nil
        }
        for (speaker, input) in inputs {
            let buffered: [Float] = pending[speaker, default: []]
            if !buffered.isEmpty {
                input.yield(buffered)
            }
            if ended.contains(speaker) {
                input.finish()
            }
        }
        let timeline: LocalTimeline = LocalTimeline(
            meStartSec: Double(pendingStart[.me, default: 0]) / Double(hybridSampleRate),
            othersStartSec: Double(pendingStart[.others, default: 0]) / Double(hybridSampleRate)
        )
        pending = [.me: [], .others: []]
        backend = .local(inputs: inputs, handle: handle)
        activeConsumers += 1
        return timeline
    }

    /// Oturum bırakıldı: girişler kapanır, bekletilen ses atılır; sonraki ses ve Mac'e geçiş arka uca gitmez. Bırakılan
    /// arka uç döner (çağıran bağlantılarını keser).
    func cancel() -> HybridBackend {
        let previous: HybridBackend = backend
        switch backend {
        case .deepgram(let inputs, _), .local(let inputs, _):
            for input in inputs.values {
                input.finish()
            }
        case .preparingLocal, .unavailable:
            break
        }
        pending = [.me: [], .others: []]
        backend = .unavailable
        return previous
    }

    /// Bulut akışı yeniden kurulacak (cihazda motor yok): konuşmacının girişi bırakılır; ses kayda yazılmaya sürer ama
    /// yeni bağlantıya dek canlı metne gitmez. Konuşmacının sesi bittiyse ya da oturum bırakıldıysa false (yeniden
    /// bağlanılmaz).
    func detachCloud(speaker: Speaker) -> Bool {
        guard case .deepgram(var inputs, let streams) = backend, !ended.contains(speaker) else {
            return false
        }
        inputs[speaker]?.finish()
        inputs[speaker] = nil
        backend = .deepgram(inputs: inputs, streams: streams)
        return true
    }

    /// Konuşmacının sesi sürüyor ve oturum bulutta (yeniden bağlanma beklemesi bu sürece sürer).
    func isCloudOpen(speaker: Speaker) -> Bool {
        guard case .deepgram = backend else {
            return false
        }
        return !ended.contains(speaker)
    }

    /// Yeni bulut akışı bağlandı: bundan sonraki ses ona gider. Akışın zaman çizgisinin kayıttaki başlangıcı (sn) döner;
    /// konuşmacının sesi bittiyse ya da oturum bırakıldıysa nil (çağıran akışı kapatır).
    func attachCloud(speaker: Speaker, input: AsyncStream<[Float]>.Continuation, stream: DeepgramStream) -> Double? {
        guard case .deepgram(var inputs, var streams) = backend, !ended.contains(speaker) else {
            return nil
        }
        inputs[speaker] = input
        streams[speaker] = stream
        backend = .deepgram(inputs: inputs, streams: streams)
        return Double(routed[speaker, default: 0]) / Double(hybridSampleRate)
    }

    /// Mac motoru hazırlanamadı: bekletilen ses bırakılır, canlı metin durur.
    func localUnavailable() {
        pending = [.me: [], .others: []]
        backend = .unavailable
    }

    func lock(language: MeetingLanguage) -> HybridBackend {
        lockedLanguage = language
        return backend
    }

    func locked() -> MeetingLanguage? {
        lockedLanguage
    }

    func consumerFinished() {
        activeConsumers -= 1
        guard activeConsumers == 0 else {
            return
        }
        let waiters: [CheckedContinuation<Void, Never>] = drainWaiters
        drainWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Tüm tüketiciler bitene dek bekler (iki giriş bittikten sonra çağrılır).
    func drain() async {
        guard activeConsumers > 0 else {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) -> Void in
            drainWaiters.append(continuation)
        }
    }
}

/// Kaynağın ayarlarıyla verilen dilde Deepgram akışı açar.
private func connectDeepgram(source: DeepgramLiveSource, language: MeetingLanguage, audio: AsyncStream<[Float]>) -> DeepgramStream {
    startDeepgramStream(
        token: source.token, options: source.options, language: language, keyterms: source.keyterms, onConnectionEvent: source.onConnectionEvent,
        audio: audio
    )
}

/// Deepgram olaylarını bölümlere çevirir; akış kalıcı olarak durursa `config.cloudFailure`'a göre Mac'e geçişi başlatır
/// ya da konuşmacının akışını geri çekilerek yeniden açar. Yeniden açılan akışın zamanları bağlandığı kayıt konumu kadar
/// kayar; bölüm numaraları sürer (kopan akışın geçici metni silinir, numarası yeni akışta yeniden kullanılır).
private func consumeDeepgram(
    speaker: Speaker,
    stream: DeepgramStream,
    source: DeepgramLiveSource,
    router: HybridRouter,
    config: HybridLiveSessionConfig,
    localEngine: @escaping @Sendable () async throws -> any TranscriptionEngine,
    events: AsyncStream<LiveSessionEvent>.Continuation
) async {
    var index: Int = 0
    var current: DeepgramStream = stream
    var offsetSec: Double = 0
    var attempt: Int = 0
    var reconnectingMessage: String?
    while true {
        var failure: String?
        for await event in current.events {
            switch event {
            case .partial(let text, let start, let end):
                announceReconnected(message: &reconnectingMessage, attempt: &attempt, events: events)
                events.yield(.segment(LiveSegment(
                    id: SegmentID(speaker: speaker, index: index), startSec: start + offsetSec, endSec: end + offsetSec, text: text, isFinal: false,
                    failureMessage: nil, person: nil
                )))
            case .final(let text, let start, let end):
                announceReconnected(message: &reconnectingMessage, attempt: &attempt, events: events)
                // Boş kesin sonuç da yayınlanır: reducer ekrandaki geçici metni siler.
                events.yield(.segment(LiveSegment(
                    id: SegmentID(speaker: speaker, index: index), startSec: start + offsetSec, endSec: end + offsetSec, text: text, isFinal: true,
                    failureMessage: nil, person: nil
                )))
                index += 1
            case .failed(let message):
                // Geçişte ya da yeniden bağlanmada bu kimliğin geçici metni yenilenmeyebilir: silinir.
                events.yield(.segment(clearingPartial(id: SegmentID(speaker: speaker, index: index))))
                failure = message
            case .incomplete(let untranscribedSec):
                events.yield(.streamIncomplete(speaker: speaker, untranscribedSec: untranscribedSec))
            }
        }
        guard let message = failure else {
            break
        }
        switch config.cloudFailure {
        case .switchToLocal:
            switch await router.beginFallback() {
            case .started:
                hybridLogger.warning("Deepgram akışı durdu, canlı metin Mac'e geçiyor, konuşmacı: \(speaker.rawValue, privacy: .public), neden: \(message, privacy: .private)")
                events.yield(.liveEngineFellBack(message: message))
                startLocalTranscription(router: router, config: config, localEngine: localEngine, events: events)
            case .alreadyLocal:
                break
            case .ended:
                events.yield(.streamFailed(speaker: speaker, message: message))
            }
        case .reconnectCloud(let delaysSec):
            guard await router.detachCloud(speaker: speaker) else {
                events.yield(.streamFailed(speaker: speaker, message: message))
                break
            }
            if reconnectingMessage == nil {
                let notice: String = String(localized: "Canlı metin bağlantısı koptu, yeniden bağlanılıyor. Kayıt sürüyor; eksik kalan metin notta tamamlanır.")
                reconnectingMessage = notice
                events.yield(.liveTextReconnecting(message: notice))
            }
            let delay: Double = cloudReconnectDelaySec(attempt: attempt, delaysSec: delaysSec)
            attempt += 1
            hybridLogger.warning("Deepgram akışı durdu, \(delay, privacy: .public) sn sonra yeniden bağlanılacak, konuşmacı: \(speaker.rawValue, privacy: .public), deneme: \(attempt, privacy: .public), neden: \(message, privacy: .private)")
            guard await waitWhileCloudOpen(speaker: speaker, router: router, seconds: delay) else {
                break
            }
            let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
            let next: DeepgramStream = connectDeepgram(source: source, language: await router.locked() ?? source.language, audio: audio)
            guard let start = await router.attachCloud(speaker: speaker, input: input, stream: next) else {
                input.finish()
                await next.cancel()
                break
            }
            current = next
            offsetSec = start
            continue
        }
        break
    }
    await router.consumerFinished()
}

/// Yeniden bağlanan akıştan ilk sonuç geldi: "yeniden bağlanılıyor" bildirimi kalkar, beklemeler baştan başlar.
private func announceReconnected(message: inout String?, attempt: inout Int, events: AsyncStream<LiveSessionEvent>.Continuation) {
    guard let notice = message else {
        return
    }
    events.yield(.liveTextReconnected(message: notice))
    message = nil
    attempt = 0
}

/// Yeniden bağlanmadan önce `seconds` bekler; konuşmacının sesi biterse ya da oturum bırakılırsa beklemeyi keser ve
/// false döner (kayıt bitince oturum en uzun beklemeyi beklemeden kapanır).
private func waitWhileCloudOpen(speaker: Speaker, router: HybridRouter, seconds: Double) async -> Bool {
    let deadline: Date = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        guard await router.isCloudOpen(speaker: speaker) else {
            return false
        }
        do {
            try await Task.sleep(for: .seconds(min(0.25, max(0, deadline.timeIntervalSinceNow))))
        } catch {
            return false
        }
    }
    return await router.isCloudOpen(speaker: speaker)
}

/// Mac motorunu hazırlar ve bekletilen sesten başlayarak Mac oturumunu çalıştırır; olayları zaman çizgisine kaydırıp
/// oturuma aktarır. Motor hazırlanamazsa canlı metni sesi olan konuşmacılar için durdurur.
private func startLocalTranscription(
    router: HybridRouter,
    config: HybridLiveSessionConfig,
    localEngine: @escaping @Sendable () async throws -> any TranscriptionEngine,
    events: AsyncStream<LiveSessionEvent>.Continuation
) {
    Task {
        let engine: any TranscriptionEngine
        do {
            engine = try await localEngine()
        } catch {
            hybridLogger.error("Mac'teki konuşma tanıma hazırlanamadı, canlı metin durdu, hata: \(String(describing: error), privacy: .private)")
            await router.localUnavailable()
            let message: String = userFacingMessage(error: error)
            for speaker in [Speaker.me, Speaker.others] where config.speakers.contains(speaker) || config.lateSpeakers.contains(speaker) {
                events.yield(.streamFailed(speaker: speaker, message: message))
            }
            return
        }
        let (meAudio, meInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let (othersAudio, othersInput): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let (localEvents, localSink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) =
            AsyncStream.makeStream(of: LiveSessionEvent.self)
        let locked: MeetingLanguage? = await router.locked()
        let local: LiveSessionConfig = LiveSessionConfig(
            languageMode: locked.map { (language: MeetingLanguage) -> LanguageMode in .fixed(language) } ?? config.local.languageMode,
            segmenter: config.local.segmenter,
            recordingDirectory: config.local.recordingDirectory,
            partialIntervalSec: config.local.partialIntervalSec,
            minPartialSpeechSec: config.local.minPartialSpeechSec,
            languageLockAfterSec: config.local.languageLockAfterSec,
            candidateLanguages: config.local.candidateLanguages
        )
        let handle: LiveSessionHandle = runTranscriptionPipeline(
            config: local, engine: engine, meAudio: meAudio, othersAudio: othersAudio, events: localEvents, eventSink: localSink
        )
        guard let timeline = await router.activateLocal(inputs: [.me: meInput, .others: othersInput], handle: handle) else {
            // Oturum motor hazırlanırken bitti: son geçiş kaydın tamamını yazıya döker.
            hybridLogger.info("Mac motoru hazır olduğunda oturum bitmişti, Mac oturumu başlatılmadı")
            meInput.finish()
            othersInput.finish()
            return
        }
        hybridLogger.info("Canlı metin Mac'te sürüyor, başlangıç: \(timeline.othersStartSec, privacy: .public) sn")
        var failures: LocalFailureRun = LocalFailureRun(consecutive: [:], reported: [])
        for await event in localEvents {
            guard let shifted = shiftedLocalEvent(event: event, timeline: timeline) else {
                continue
            }
            events.yield(shifted)
            let step: LocalFailureStep = countedLocalFailure(run: failures, event: shifted, threshold: localFailureThreshold)
            failures = step.run
            if let stopped = step.stopped {
                hybridLogger.error("Yerel canlı metin art arda yazıya dökülemedi, konuşmacı: \(stopped.speaker.rawValue, privacy: .public)")
                events.yield(.streamFailed(speaker: stopped.speaker, message: stopped.message))
            }
        }
        await router.consumerFinished()
    }
}

/// Mac oturumunun olayını hibrit oturumun zaman çizgisine taşır: bölüm zamanları Mac zamanının başladığı konum kadar
/// kayar, numaralar Deepgram bölümleriyle çakışmasın diye `localSegmentIndexBase`'den başlar. Yakalama sonu hibrit
/// kayıttan bildirildiği için atılır. Saf fonksiyondur.
func shiftedLocalEvent(event: LiveSessionEvent, timeline: LocalTimeline) -> LiveSessionEvent? {
    switch event {
    case .segment(let segment):
        let offset: Double = timeline.startSec(speaker: segment.id.speaker)
        return .segment(LiveSegment(
            id: SegmentID(speaker: segment.id.speaker, index: segment.id.index + localSegmentIndexBase),
            startSec: segment.startSec + offset,
            endSec: segment.endSec + offset,
            text: segment.text,
            isFinal: segment.isFinal,
            failureMessage: segment.failureMessage,
            person: segment.person
        ))
    case .captureEnded:
        return nil
    case .languageLocked, .recordingFailed, .speakersAssigned, .streamFailed, .streamIncomplete, .diarizationFailed, .liveEngineFellBack,
         .liveTextReconnecting, .liveTextReconnected:
        return event
    }
}

/// Consecutive failed final segments of a speaker after which the local live transcript counts as stopped: one failed
/// segment is a glitch, a run of them (assets removed, analysis broken) must be visible (`.streamFailed`).
let localFailureThreshold: Int = 3

/// Consecutive failed final segments per speaker, and the speakers already reported as stopped.
struct LocalFailureRun: Sendable, Equatable {
    let consecutive: [Speaker: Int]
    let reported: Set<Speaker>
}

/// A speaker's local live transcript stopped: its last failure text.
struct LocalFailureStop: Sendable, Equatable {
    let speaker: Speaker
    let message: String
}

/// The run after one event, and the stop to report when the speaker just reached the threshold.
struct LocalFailureStep: Sendable, Equatable {
    let run: LocalFailureRun
    let stopped: LocalFailureStop?
}

/// Counts a final segment's failure: a failed final adds one to its speaker's run, a transcribed final resets it; the
/// speaker is reported once, when the run reaches `threshold` (the recording and the session continue; a later success
/// resets the count but the speaker stays reported). Other events change nothing. Pure function.
func countedLocalFailure(run: LocalFailureRun, event: LiveSessionEvent, threshold: Int) -> LocalFailureStep {
    guard case .segment(let segment) = event, segment.isFinal else {
        return LocalFailureStep(run: run, stopped: nil)
    }
    let speaker: Speaker = segment.id.speaker
    guard let message = segment.failureMessage else {
        return LocalFailureStep(run: LocalFailureRun(consecutive: run.consecutive.merging([speaker: 0]) { (_: Int, new: Int) -> Int in new }, reported: run.reported), stopped: nil)
    }
    let count: Int = run.consecutive[speaker, default: 0] + 1
    let consecutive: [Speaker: Int] = run.consecutive.merging([speaker: count]) { (_: Int, new: Int) -> Int in new }
    guard count >= threshold, !run.reported.contains(speaker) else {
        return LocalFailureStep(run: LocalFailureRun(consecutive: consecutive, reported: run.reported), stopped: nil)
    }
    return LocalFailureStep(run: LocalFailureRun(consecutive: consecutive, reported: run.reported.union([speaker])), stopped: LocalFailureStop(speaker: speaker, message: message))
}

/// The on-device live preview's engine and its local settings (fixed language: Apple's recognition detects none).
public struct OnDevicePreviewEngine: Sendable {
    public let local: LiveSessionConfig
    public let engine: @Sendable () async throws -> any TranscriptionEngine

    public init(local: LiveSessionConfig, engine: @escaping @Sendable () async throws -> any TranscriptionEngine) {
        self.local = local
        self.engine = engine
    }
}

/// Runs the hybrid live session with the `onDeviceSpeakers` tracks on the on-device preview from the start and the rest
/// as before: on `start` (cloud, or local when the server offers no cloud stream) with `config.local` and `localEngine`
/// (also their fallback), so a track whose live text is saved never gets the preview engine. With no on-device track this
/// is `runHybridLiveSession` itself; with only on-device tracks, `runHybridLiveSession` on the preview engine. Otherwise
/// each group gets its own hybrid sub-session over its own tracks of the one recording (the recording and its files are
/// unchanged): their events are merged into the recording's event stream, which ends when both sub-sessions end; a
/// language change goes to both (the stream may carry `.languageLocked` once per sub-session); cancel stops both.
public func runSplitHybridLiveSession(
    config: HybridLiveSessionConfig,
    start: HybridLiveStart,
    onDeviceSpeakers: Set<Speaker>,
    preview: OnDevicePreviewEngine,
    localEngine: @escaping @Sendable () async throws -> any TranscriptionEngine,
    recording: HybridRecording
) -> LiveSessionHandle {
    let live: Set<Speaker> = config.speakers.union(config.lateSpeakers)
    let local: Set<Speaker> = onDeviceSpeakers.intersection(live)
    let rest: Set<Speaker> = live.subtracting(local)
    guard !local.isEmpty else {
        return runHybridLiveSession(config: config, start: start, localEngine: localEngine, recording: recording)
    }
    let previewConfig: HybridLiveSessionConfig = HybridLiveSessionConfig(
        speakers: config.speakers, lateSpeakers: config.lateSpeakers, local: preview.local, maxPendingAudioSec: config.maxPendingAudioSec,
        cloudFailure: config.cloudFailure
    )
    guard !rest.isEmpty else {
        return runHybridLiveSession(config: previewConfig, start: .local, localEngine: preview.engine, recording: recording)
    }
    let empty: AsyncStream<[Float]> = AsyncStream<[Float]> { (continuation: AsyncStream<[Float]>.Continuation) -> Void in continuation.finish() }
    // A track that is not live (e.g. "Sen" in in-person mode) is still drained by the other group, as before.
    func subRecording(speakers: Set<Speaker>) -> HybridRecording {
        let (events, sink): (AsyncStream<LiveSessionEvent>, AsyncStream<LiveSessionEvent>.Continuation) = AsyncStream.makeStream(of: LiveSessionEvent.self)
        return HybridRecording(
            events: events, sink: sink,
            me: speakers.contains(.me) ? recording.me : empty,
            others: speakers.contains(.others) ? recording.others : empty
        )
    }
    func subConfig(speakers: Set<Speaker>, local: LiveSessionConfig) -> HybridLiveSessionConfig {
        HybridLiveSessionConfig(
            speakers: config.speakers.intersection(speakers), lateSpeakers: config.lateSpeakers.intersection(speakers), local: local,
            maxPendingAudioSec: config.maxPendingAudioSec, cloudFailure: config.cloudFailure
        )
    }
    let cloudSpeakers: Set<Speaker> = Set([Speaker.me, Speaker.others]).subtracting(local)
    let cloud: LiveSessionHandle = runHybridLiveSession(
        config: subConfig(speakers: cloudSpeakers, local: config.local), start: start, localEngine: localEngine, recording: subRecording(speakers: cloudSpeakers)
    )
    let onDevice: LiveSessionHandle = runHybridLiveSession(
        config: subConfig(speakers: local, local: preview.local), start: .local, localEngine: preview.engine, recording: subRecording(speakers: local)
    )
    let sink: AsyncStream<LiveSessionEvent>.Continuation = recording.sink
    Task {
        await withTaskGroup(of: Void.self) { (group: inout TaskGroup<Void>) -> Void in
            for handle in [cloud, onDevice] {
                group.addTask {
                    for await event in handle.events {
                        sink.yield(event)
                    }
                }
            }
        }
        sink.finish()
    }
    return LiveSessionHandle(
        events: recording.events,
        languageSetter: { (language: MeetingLanguage) async -> Void in
            await cloud.setLanguage(language)
            await onDevice.setLanguage(language)
        },
        canceller: { () async -> Void in
            await cloud.cancel()
            await onDevice.cancel()
            sink.finish()
        }
    )
}
