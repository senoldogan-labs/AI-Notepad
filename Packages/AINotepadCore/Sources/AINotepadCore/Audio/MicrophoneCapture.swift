import AVFoundation
import Foundation
import os
import Synchronization
#if os(iOS)
import UIKit
#endif

/// Mikrofonu 16 kHz mono Float parçalar halinde yakalar ("Sen" akışı; iPhone'da odadaki herkes).
///
/// Giriş cihazı değişirse (ör. AirPods bağlanınca, USB mikrofon çıkarılınca) ya da motor bildirimsiz ses vermeyi
/// bırakırsa (takılma bekçisi) motor yeni formatla, geri çekilmeli denemelerle yeniden kurulur. iOS'ta önce kayıt için
/// ses oturumu açılır; telefon çağrısı gibi bir kesinti bitince ve sistemin ses servisleri sıfırlanınca da yeniden
/// kurulur. Kurulamazsa akış bitmez (Mac'te de): durum `.reconnecting` kalır (kayıt paneli ve ekranı gösterir), bekçi
/// aralıkla yeniden dener; aradaki boşluk saatle hizalamada sessizlikle dolar. Her durum değişikliği loglanır ve
/// `onStatusChange` ile bildirilir.
@MainActor
public final class MicrophoneCapture {
    private nonisolated static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MicrophoneCapture")
    /// Bu kadar süre ses parçası gelmezse motor takılmış sayılır (tampon ~85 ms'de bir gelir).
    private static let stallThresholdSec: Double = 3
    /// Yeniden kurma başarısız olduysa yeni deneme aralığı.
    private static let retryIntervalSec: Double = 5

    /// Ses servisleri sıfırlanınca yenisiyle değiştirilir (eski motor kullanılamaz).
    private var engine: AVAudioEngine = AVAudioEngine()
    private var tapInstalled: Bool = false
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configurationObserver: (any NSObjectProtocol)?
    /// iOS: ses oturumu kesintisi (telefon çağrısı, alarm) bitince yeniden kurma.
    private var interruptionObserver: (any NSObjectProtocol)?
    /// iOS: uygulama öne gelince kesinti sürüyorsa yeniden kurma (VoIP uygulamaları kesinti bitişini her zaman bildirmez).
    private var activationObserver: (any NSObjectProtocol)?
    /// iOS: sistemin ses servisleri sıfırlandı; motor baştan kurulur.
    private var mediaResetObserver: (any NSObjectProtocol)?
    /// Takılma bekçisi (bkz. `checkHealth`).
    private var watchdog: Task<Void, Never>?
    /// Ses thread'inden son ses parçasının anı.
    private let heartbeat: AudioHeartbeat = AudioHeartbeat()
    /// Her yeniden kurma isteğinde artar; eski denemeler yenisi gelince vazgeçer.
    private var restartGeneration: Int = 0
    private var isRestarting: Bool = false
    private var lastRestartAttempt: ContinuousClock.Instant = .now
    /// Yakalamanın durumu (kesinti, yeniden kurma); arayüz bunu gösterir.
    public private(set) var status: MicrophoneStatus = .running
    /// Durum değişince çağrılır (iPhone kayıt ekranı "Mikrofon kesildi" / "yeniden bağlanıyor" gösterir).
    public var onStatusChange: (@MainActor (MicrophoneStatus) -> Void)?

    public init() {}

    /// İzni ister, yakalamayı başlatır ve ses parçalarının akışını döndürür. İzin penceresi (ilk kullanım) ya da ses
    /// oturumu beklenirken `stop()` çağrılırsa motor kurulmaz ve `CancellationError` fırlatılır: mikrofon kayıt
    /// durdurulduktan sonra açık kalmaz.
    public func start() async throws -> AsyncStream<[Float]> {
        guard continuation == nil else {
            throw AudioCaptureError.alreadyRunning(source: "MicrophoneCapture")
        }
        // `stop()` sayacı artırır: izin penceresi açıkken durdurulduysa izin gelince başlatma yarıda kalır.
        let generation: Int = restartGeneration
        guard await AVAudioApplication.requestRecordPermission() else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        guard generation == restartGeneration else {
            Self.logger.info("Mikrofon izni beklenirken yakalama durduruldu; motor kurulmadı")
            throw CancellationError()
        }
        // İzin beklenirken başka bir başlatma bitmiş olabilir.
        guard continuation == nil else {
            throw AudioCaptureError.alreadyRunning(source: "MicrophoneCapture")
        }
        let (stream, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        self.continuation = continuation
        #if os(iOS)
        // Oturum beklenirken `stop()` çağrılırsa (sayaç artar) başlatma yarıda kalır: `stop()` akışı bitirdi ve oturumu
        // bıraktı; motor, gözlemciler ve bekçi kurulmaz, kurulsaydı mikrofon kayıt bittikten sonra da açık kalırdı.
        do {
            try await activateRecordingSessionForStart()
        } catch {
            if generation == restartGeneration {
                continuation.finish()
                self.continuation = nil
            }
            throw error
        }
        guard generation == restartGeneration, self.continuation != nil else {
            Self.logger.info("Mikrofon başlatılırken yakalama durduruldu; motor kurulmadı")
            throw CancellationError()
        }
        #endif
        do {
            try startEngine(continuation: continuation)
        } catch {
            continuation.finish()
            self.continuation = nil
            #if os(iOS)
            // Açılan oturum bırakılır: yoksa diğer uygulamaların sesi (müzik) kesik kalırdı.
            deactivateRecordingSession()
            #endif
            throw error
        }
        heartbeat.beat()
        setStatus(.running)
        observeEngineConfiguration()
        #if os(iOS)
        observeAudioSession()
        #endif
        startWatchdog()
        return stream
    }

    /// Yakalamayı durdurur ve akışı bitirir.
    public func stop() {
        removeObservers()
        restartGeneration += 1
        isRestarting = false
        watchdog?.cancel()
        watchdog = nil
        #if os(iOS)
        let wasRunning: Bool = continuation != nil
        #endif
        // Kesinti sürerken durdurulduysa dinleyen de öğrenir: yoksa "Mikrofon kesildi" sonraki kayıtta da kalırdı.
        setStatus(.running)
        stopEngine()
        continuation?.finish()
        continuation = nil
        #if os(iOS)
        if wasRunning {
            deactivateRecordingSession()
        }
        #endif
    }

    private func setStatus(_ newStatus: MicrophoneStatus) {
        guard status != newStatus else {
            return
        }
        status = newStatus
        Self.logger.info("Mikrofon durumu değişti, durum: \(String(describing: newStatus), privacy: .public)")
        onStatusChange?(newStatus)
    }

    /// Takılma bekçisi: saniyede bir motorun ses verip vermediğine bakar; takıldıysa yeniden kurar, yeniden kurma
    /// başarısız kaldıysa aralıkla yeniden dener.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    // İptal: yakalama durdu.
                    return
                }
                guard let self else {
                    return
                }
                await self.checkHealth()
            }
        }
    }

    private func checkHealth() async {
        guard continuation != nil else {
            return
        }
        let now: ContinuousClock.Instant = .now
        let silentForSec: Double = heartbeat.silentForSec(now: now)
        if isMicrophoneStalled(status: status, engineRunning: engine.isRunning, silentForSec: silentForSec, thresholdSec: Self.stallThresholdSec) {
            Self.logger.warning("Mikrofondan ses gelmiyor, motor yeniden kuruluyor, sessiz: \(silentForSec, privacy: .public) sn, motor çalışıyor: \(self.engine.isRunning, privacy: .public)")
            await restartEngine(reason: .stalled)
            return
        }
        guard case .reconnecting(let reason) = status,
              shouldRetryMicrophone(status: status, isRestarting: isRestarting, sinceLastAttemptSec: seconds(of: now - lastRestartAttempt), retryIntervalSec: Self.retryIntervalSec) else {
            return
        }
        Self.logger.warning("Mikrofon hâlâ yeniden kurulamadı, yeniden deneniyor, neden: \(reason.rawValue, privacy: .public)")
        await restartEngine(reason: reason)
    }

    /// Motorun yapılandırma değişikliği (giriş cihazı, ses yolu) izlenir; motor değişince yeniden kaydedilir.
    private func observeEngineConfiguration() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.handleConfigurationChange()
            }
        }
    }

    private func removeObservers() {
        let observers: [(any NSObjectProtocol)?] = [configurationObserver, interruptionObserver, activationObserver, mediaResetObserver]
        for case let observer? in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        configurationObserver = nil
        interruptionObserver = nil
        activationObserver = nil
        mediaResetObserver = nil
    }

    #if os(iOS)
    private func observeAudioSession() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] (notification: Notification) -> Void in
            let rawType: UInt? = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type: AVAudioSession.InterruptionType? = rawType.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let rawReason: UInt = notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt ?? 0
            let rawOptions: UInt = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                // Teşhis: kesintinin türü, nedeni ve uygulamanın o anki durumu (arka planda kesilen kayıt ancak karışabilir
                // oturumla arka planda yeniden açılabilir).
                Self.logger.info("Ses oturumu kesinti bildirimi, tür: \(rawType.map(String.init) ?? "yok", privacy: .public), neden: \(rawReason, privacy: .public), sürdür: \(rawOptions & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0, privacy: .public), uygulama: \(applicationStateName(), privacy: .public)")
                switch type {
                case .began:
                    self?.setStatus(.interrupted)
                case .ended:
                    await self?.resumeAfterInterruption()
                default:
                    return
                }
            }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.recoverOnActivation()
            }
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.rebuildAfterMediaServicesReset()
            }
        }
    }

    /// Kesinti bitti: ses oturumu yeniden etkinleştirilir (kesinti onu kapatır) ve motor yeniden kurulur. Oturum
    /// açılamazsa (çağrı sürüyor) kesinti sürer; uygulama öne gelince yeniden denenir.
    private func resumeAfterInterruption() async {
        guard continuation != nil else {
            return
        }
        do {
            try await activateRecordingSession()
        } catch {
            Self.logger.error("Kesinti sonrası ses oturumu açılamadı, kesinti sürüyor sayılıyor, kod: \(audioSessionErrorCode(error: error), privacy: .public), uygulama: \(applicationStateName(), privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return
        }
        await restartEngine(reason: .interruptionEnded)
    }

    /// Uygulama öne geldi: kesinti sürüyorsa (VoIP uygulamaları kesinti bitişini her zaman bildirmez) ya da motor arka
    /// planda yeniden kurulamadıysa beklemeden yeniden denenir; kullanıcı dönünce kayıt hemen ses almaya başlar.
    private func recoverOnActivation() async {
        switch status {
        case .running:
            return
        case .interrupted:
            Self.logger.info("Uygulama öne geldi, kesinti sürüyordu, mikrofon yeniden açılıyor")
            await resumeAfterInterruption()
        case .reconnecting(let reason):
            guard !isRestarting else {
                return
            }
            Self.logger.info("Uygulama öne geldi, mikrofon yeniden bağlanıyordu, hemen yeniden deneniyor, neden: \(reason.rawValue, privacy: .public)")
            await restartEngine(reason: reason)
        }
    }

    /// Ses servisleri sıfırlandı: eski motor kullanılamaz; yenisi kurulur ve izlenir.
    private func rebuildAfterMediaServicesReset() async {
        guard continuation != nil else {
            return
        }
        Self.logger.warning("Ses servisleri sıfırlandı, mikrofon motoru baştan kuruluyor")
        engine = AVAudioEngine()
        tapInstalled = false
        observeEngineConfiguration()
        await restartEngine(reason: .mediaServicesReset)
    }

    /// Kayıt başlarken ses oturumu: odadaki konuşmayı yerleşik mikrofonla alır; kayıt arka planda ve ekran kilitliyken
    /// sürer (Info.plist'te `audio` arka plan modu). Bluetooth kulaklık yalnızca çalma için (A2DP) kullanılır; kulaklık
    /// mikrofonu (HFP) sesi 16 kHz dar banda düşürdüğü için seçilmez.
    ///
    /// Önce karışmayan oturum açılır: çalan müzik ya da podcast durur, toplantı kaydına karışmaz. Açıldıktan sonra
    /// oturum karışabilir yapılır (`recordingSessionOptions`): başka bir uygulamanın sesi (video, sesli mesaj) kaydı
    /// kesmez ve kesinti sonrası oturum arka planda yeniden açılabilir (iOS karışmayan oturumun arka planda açılmasını
    /// `cannotInterruptOthers` ile reddeder: kesilen kayıt arka planda bir daha ses almaz, uygulama askıya alınır). Gelen
    /// aramanın zil ve bildirimi kaydı kesmez; yalnızca arama kabul edilince kesinti olur.
    /// Oturum değişikliği ana iş parçacığında değil `AudioSessionQueue`'da yapılır (sistem servisini beklerken arayüz
    /// donmasın).
    private func activateRecordingSessionForStart() async throws {
        do {
            try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Void in
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
                try session.setActive(true)
                try session.setCategory(.playAndRecord, mode: .default, options: recordingSessionOptions)
                do {
                    try session.setPrefersNoInterruptionsFromSystemAlerts(true)
                } catch {
                    // Yalnız tercih: açılmazsa gelen arama zili kaydı keser, kesinti bitince kayıt kendiliğinden sürer.
                    Self.logger.warning("Ses oturumunda sistem uyarısı tercihi ayarlanamadı, kod: \(audioSessionErrorCode(error: error), privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("Kayıt ses oturumu açılamadı, kod: \(audioSessionErrorCode(error: error), privacy: .public), uygulama: \(applicationStateName(), privacy: .public)")
            throw AudioCaptureError.microphoneStartFailed(code: Int32((error as NSError).code))
        }
    }

    /// Kesinti, takılma ya da ses servisleri sıfırlanınca oturum yeniden açılır: karışabilir oturum (bkz.
    /// `activateRecordingSessionForStart`) uygulama arka plandayken de açılabilir; açıkken yeniden açmak zararsız.
    private func activateRecordingSession() async throws {
        do {
            try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Void in
                try session.setCategory(.playAndRecord, mode: .default, options: recordingSessionOptions)
                try session.setActive(true)
            }
        } catch {
            throw AudioCaptureError.microphoneStartFailed(code: Int32((error as NSError).code))
        }
    }

    /// Kayıt bitince oturum bırakılır; diğer uygulamaların sesi (müzik) kaldığı yerden sürer.
    /// Kapatma kuyruğa bekletmeden eklenir: durdurma anında arayüz beklemez; sonraki "aç" kuyrukta ondan sonra gelir.
    private func deactivateRecordingSession() {
        AudioSessionQueue.enqueue(
            { (session: AVAudioSession) throws -> Void in
                try session.setActive(false, options: .notifyOthersOnDeactivation)
            },
            onError: { (error: any Error) -> Void in
                Self.logger.error("Ses oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
            }
        )
    }
    #endif

    /// Giriş formatına göre tap kurar ve motoru başlatır. Takılı tap önce sökülür: aynı girişe ikinci tap AVFoundation'da
    /// yakalanamayan bir istisnayla uygulamayı kapatır.
    private func startEngine(continuation: AsyncStream<[Float]>.Continuation) throws {
        if tapInstalled {
            Self.logger.warning("Mikrofon motoru kurulurken eski tap takılıydı, sökülüyor")
            stopEngine()
        }
        let input: AVAudioInputNode = engine.inputNode
        let format: AVAudioFormat = input.outputFormat(forBus: 0)
        let resampler: AudioResampler = try AudioResampler(inputFormat: format)
        input.installTap(
            onBus: 0, bufferSize: 4096, format: format,
            block: Self.makeTapBlock(resampler: resampler, continuation: continuation, heartbeat: heartbeat, throttle: LogThrottle(intervalSec: 60))
        )
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw AudioCaptureError.microphoneStartFailed(code: Int32((error as NSError).code))
        }
    }

    private func stopEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    /// Cihaz değişti: kesinti sürerken (telefon çağrısı) yeniden kurulmaz, denemeler tükenip akış bitmesin; kesinti
    /// bitince `resumeAfterInterruption` motoru yeniden kurar.
    private func handleConfigurationChange() async {
        guard status != .interrupted else {
            Self.logger.info("Kesinti sürerken cihaz değişti; yeniden kurma kesinti bitince yapılacak")
            return
        }
        await restartEngine(reason: .configurationChange)
    }

    /// Motoru (yeni formatla) yeniden kurar; yeni cihaz henüz hazır olmayabileceği için birkaç kez dener. Daha yeni bir
    /// istek gelirse ya da yakalama durdurulursa çekilir. Kurulamazsa durum `.reconnecting` kalır ve bekçi aralıkla
    /// yeniden dener (kayıt açık kalır).
    private func restartEngine(reason: MicrophoneRecoveryReason) async {
        guard continuation != nil else {
            return
        }
        restartGeneration += 1
        let generation: Int = restartGeneration
        setStatus(.reconnecting(reason: reason))
        isRestarting = true
        lastRestartAttempt = .now
        defer {
            if generation == restartGeneration {
                isRestarting = false
                lastRestartAttempt = .now
            }
        }
        do {
            try await retryWithBackoff(
                attempts: 4,
                delaySec: 0.25,
                isolation: #isolation,
                operation: {
                    guard generation == self.restartGeneration, let continuation = self.continuation else {
                        return
                    }
                    self.stopEngine()
                    #if os(iOS)
                    // Takılma ve ses servisi sıfırlanmasında oturum da kapanmış olabilir; açıkken yeniden açmak zararsız.
                    try await self.activateRecordingSession()
                    // Oturum beklenirken daha yeni bir yeniden kurma başladıysa ya da yakalama durdurulduysa motor
                    // kurulmaz: iki kurma aynı girişe ikinci tap'i takardı, durdurulan kayıtta mikrofon açık kalırdı.
                    guard generation == self.restartGeneration, self.continuation != nil else {
                        return
                    }
                    #endif
                    try self.startEngine(continuation: continuation)
                },
                onFailure: { (attempt: Int, error: any Error) -> Void in
                    #if os(iOS)
                    Self.logger.warning("Mikrofon yeniden başlatılamadı, neden: \(reason.rawValue, privacy: .public), deneme \(attempt, privacy: .public), kod: \(audioSessionErrorCode(error: error), privacy: .public), uygulama: \(applicationStateName(), privacy: .public): \(String(describing: error), privacy: .private)")
                    #else
                    Self.logger.warning("Mikrofon yeniden başlatılamadı, neden: \(reason.rawValue, privacy: .public), deneme \(attempt, privacy: .public): \(String(describing: error), privacy: .private)")
                    #endif
                }
            )
            guard generation == restartGeneration, continuation != nil else {
                return
            }
            heartbeat.beat()
            Self.logger.info("Mikrofon yeniden başlatıldı, neden: \(reason.rawValue, privacy: .public)")
            setStatus(.running)
        } catch {
            guard generation == restartGeneration else {
                return
            }
            Self.logger.error("Mikrofon yeniden başlatılamadı, \(Self.retryIntervalSec, privacy: .public) sn sonra yeniden denenecek, neden: \(reason.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Ses thread'inde çalışan tap bloğu. Ana aktöre bağlı olmaması için `nonisolated` üretilir.
    private nonisolated static func makeTapBlock(
        resampler: AudioResampler,
        continuation: AsyncStream<[Float]>.Continuation,
        heartbeat: AudioHeartbeat,
        throttle: LogThrottle
    ) -> AVAudioNodeTapBlock {
        { (buffer: AVAudioPCMBuffer, _: AVAudioTime) -> Void in
            heartbeat.beat()
            do {
                let samples: [Float] = try resampler.convert(buffer: buffer)
                if !samples.isEmpty {
                    continuation.yield(samples)
                }
            } catch {
                // Her tamponda tekrarlanır: dakikada bir loglanır.
                if throttle.allow() {
                    logger.error("Mikrofon sesi dönüştürülemedi, hata: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }
}

/// Ses thread'inden gelen son ses parçasının anı; takılma bekçisi ana aktörden okur. Thread-safe.
final class AudioHeartbeat: Sendable {
    private let last: Mutex<ContinuousClock.Instant> = Mutex(ContinuousClock.now)

    func beat() {
        let now: ContinuousClock.Instant = .now
        last.withLock { (value: inout ContinuousClock.Instant) -> Void in value = now }
    }

    func silentForSec(now: ContinuousClock.Instant) -> Double {
        let lastBeat: ContinuousClock.Instant = last.withLock { (value: inout ContinuousClock.Instant) -> ContinuousClock.Instant in value }
        return seconds(of: now - lastBeat)
    }
}

#if os(iOS)
/// Kayıt sürerken ses oturumunun seçenekleri: hoparlör, yalnız çalma için Bluetooth ve karışabilirlik (bkz.
/// `MicrophoneCapture.activateRecordingSessionForStart`).
private let recordingSessionOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]

/// Ses oturumu hatasının kodu (ör. 560557684 `!int`: karışmayan oturum arka planda açılamaz); içerik taşımaz.
private func audioSessionErrorCode(error: any Error) -> Int {
    if case AudioCaptureError.microphoneStartFailed(let code) = error {
        return Int(code)
    }
    return (error as NSError).code
}

/// Uygulamanın durumu (loglar için): "active", "inactive" ya da "background".
@MainActor
private func applicationStateName() -> String {
    switch UIApplication.shared.applicationState {
    case .active: "active"
    case .inactive: "inactive"
    case .background: "background"
    @unknown default: "unknown"
    }
}
#endif

/// Süreyi saniyeye çevirir. Saf fonksiyondur.
private func seconds(of duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
