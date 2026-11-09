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
///
/// Hangi mikrofonun kullanılacağını her kurmada `input` sorulup `selectAudioInput` karar verir: iPhone'da ses oturumunun
/// tercih edilen girişi (`setPreferredInput`; Bluetooth kulaklık seçildiyse oturum HFP'ye ve iOS 26'da AirPods yüksek
/// kaliteli kayda izin verir), Mac'te motorun giriş cihazı (`AUAudioUnit.setDeviceID`). Her kurma yeni bir
/// `AVAudioEngine` ile yapılır ve tap ancak motorun formatı donanımın örnekleme hızına geçtikten sonra takılır
/// (`isCaptureFormatReady`): cihaz değişiminin hemen ardından eski formatla takılan tap AVFoundation'da yakalanamayan
/// bir istisnayla uygulamayı kapatır. iPhone'da önce ses yolunun hedef girişe geçmesi beklenir. Mac'te hedef cihaz
/// kurulamazsa sistemin varsayılan girişi kurulur (`audioInputAttempts`). Cihaz takılıp çıkarılınca (iPhone
/// `routeChangeNotification`, Mac Core Audio cihaz listesi ve varsayılan giriş) hedef giriş kullanılandan farklıysa
/// motor yeniden kurulur; kurma sürerken gelen değişiklikler sıraya alınır ve kurma bitince bir kez değerlendirilir.
/// Kayıt hiçbir durumda durmaz; kullanılan giriş ses yolu gerçekten geçtikten sonra `activeInput` ve `onInputChange` ile
/// bildirilir.
@MainActor
public final class MicrophoneCapture {
    private nonisolated static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MicrophoneCapture")
    /// Bu kadar süre ses parçası gelmezse motor takılmış sayılır (tampon ~85 ms'de bir gelir).
    private static let stallThresholdSec: Double = 3
    /// Yeniden kurma başarısız olduysa yeni deneme aralığı.
    private static let retryIntervalSec: Double = 5
    /// Görüşme mikrofonu tutarken oturumu yeniden açma aralığı (görüşme bitince kayıt kendiliğinden sürsün).
    private static let callRetryIntervalSec: Double = 10
    /// Kesinti başladıktan bu kadar sonra oturum bir kez yeniden açılmayı dener: görüşme sürüyorsa iOS bunu
    /// `insufficientPriority` ile reddeder ve kayıt ekranı kesintinin nedenini (görüşme) söyleyebilir.
    private static let interruptionProbeDelaySec: Double = 1.5
    /// iOS: tercih edilen giriş verildikten sonra ses yolunun ona geçmesi en çok bu kadar beklenir.
    private static let routeSettleTimeoutSec: Double = 1
    private static let routeSettlePollSec: Double = 0.05

    /// Her kurmada yenisiyle değiştirilir (`replaceEngine`): cihaz değişiminden sonra eski motorun formatı güvenilmez.
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
    /// iOS: kesinti başlayınca nedenini anlamak için bir kez yeniden açma denemesi (bkz. `probeInterruption`).
    private var interruptionProbe: Task<Void, Never>?
    /// Ses thread'inden son ses parçasının anı.
    private let heartbeat: AudioHeartbeat = AudioHeartbeat()
    /// Her yeniden kurma isteğinde artar; eski denemeler yenisi gelince vazgeçer.
    private var restartGeneration: Int = 0
    private var isRestarting: Bool = false
    private var lastRestartAttempt: ContinuousClock.Instant = .now
    /// Kurma sürerken gelen ses yolu/cihaz/seçim değişikliği: kurma bitince bir kez değerlendirilir (atılmaz).
    private var pendingRouteChange: AudioRouteChange?
    /// Yakalamanın durumu (kesinti, yeniden kurma); arayüz bunu gösterir.
    public private(set) var status: MicrophoneStatus = .running
    /// Durum değişince çağrılır (iPhone kayıt ekranı "Mikrofon kesildi" / "yeniden bağlanıyor" gösterir).
    public var onStatusChange: (@MainActor (MicrophoneStatus) -> Void)?
    /// Kullanıcının mikrofon seçimi ve bağlamı; her kurmada okunur (ayar kayıt sırasında da değişebilir).
    private let input: @MainActor () -> AudioInputRequest
    /// Kullanılan giriş (bilinmiyorsa nil: ör. Mac'te cihaz listesi okunamadı, motor sistemin girişini kullanıyor).
    public private(set) var activeInput: ActiveAudioInput?
    /// Kullanılan giriş değişince çağrılır (kayıt ekranı adını ve bildirimi gösterir).
    public var onInputChange: (@MainActor (ActiveAudioInput) -> Void)?
    /// Mikrofon seçimi değişti (`audioInputChoiceDidChange`).
    private var choiceObserver: (any NSObjectProtocol)?
    #if os(iOS)
    /// iOS: ses yolu değişti (kulaklık takıldı/çıkarıldı, AirPods bağlandı).
    private var routeChangeObserver: (any NSObjectProtocol)?
    /// iOS: son kurulan oturumda Bluetooth mikrofonu (HFP) açık mıydı; seçim bunu değiştirirse motor yeniden kurulur.
    private var appliedBluetoothInput: Bool = false
    #else
    /// Mac: cihaz takıldı/çıkarıldı ya da varsayılan giriş değişti.
    private var hardwareObserver: MacAudioHardwareObserver?
    #endif

    /// `input`: kullanıcının mikrofon seçimi ve bağlamı (bkz. `AudioInputRequest`); her kurmada çağrılır.
    public init(input: @escaping @MainActor () -> AudioInputRequest) {
        self.input = input
    }

    /// Kullanıcı mikrofon seçimini değiştirdi: kullanılan giriş değişecekse yakalama yeni girişle yeniden kurulur, aynı
    /// kalıyorsa yalnız durum tazelenir (kayıt durmaz). Kesinti sürerken (çağrı) beklenir: kesinti bitince kurma yeni
    /// seçimi zaten okur; kurma sürerken sıraya alınır.
    public func inputChoiceChanged() async {
        await routeChangeArrived(change: .choiceChanged)
    }

    /// Kullanılan giriş: değiştiyse dinleyene bildirilir.
    private func setActiveInput(_ newInput: ActiveAudioInput?) {
        guard let newInput, newInput != activeInput else {
            return
        }
        activeInput = newInput
        Self.logger.info("Mikrofon girişi, tür: \(newInput.device.kind.rawValue, privacy: .public), seçim kullanılamıyor: \(newInput.unavailableChoice != nil, privacy: .public)")
        onInputChange?(newInput)
    }

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
        // Oturum ya da kurma beklenirken `stop()` çağrılırsa (sayaç artar) başlatma yarıda kalır: `stop()` akışı bitirdi
        // ve oturumu bıraktı; motor, gözlemciler ve bekçi kurulmaz, kurulsaydı mikrofon kayıt bittikten sonra da açık
        // kalırdı.
        do {
            #if os(iOS)
            try await activateRecordingSessionForStart(request: input())
            #endif
            // Yeni seçilen cihazın formatı ilk denemede hazır olmayabilir (`inputFormatNotReady`): kısa aralıkla yeniden.
            try await retryWithBackoff(
                attempts: 3,
                delaySec: 0.2,
                isolation: #isolation,
                operation: {
                    guard generation == self.restartGeneration, self.continuation != nil else {
                        return
                    }
                    try await self.buildCapture(continuation: continuation, generation: generation)
                },
                onFailure: { (attempt: Int, error: any Error) -> Void in
                    Self.logger.warning("Mikrofon başlatılamadı, deneme \(attempt, privacy: .public): \(String(describing: error), privacy: .private)")
                }
            )
        } catch {
            if generation == restartGeneration {
                stopEngine()
                continuation.finish()
                self.continuation = nil
                #if os(iOS)
                // Açılan oturum bırakılır: yoksa diğer uygulamaların sesi (müzik) kesik kalırdı.
                deactivateRecordingSession()
                #endif
            }
            throw error
        }
        guard generation == restartGeneration, self.continuation != nil else {
            Self.logger.info("Mikrofon başlatılırken yakalama durduruldu; motor kurulmadı")
            throw CancellationError()
        }
        heartbeat.beat()
        setStatus(.running)
        choiceObserver = NotificationCenter.default.addObserver(forName: audioInputChoiceDidChange, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            Task { @MainActor in
                await self?.inputChoiceChanged()
            }
        }
        #if os(iOS)
        observeAudioSession()
        #else
        observeAudioHardware()
        #endif
        startWatchdog()
        return stream
    }

    /// Yakalamayı durdurur ve akışı bitirir.
    public func stop() {
        removeObservers()
        restartGeneration += 1
        isRestarting = false
        pendingRouteChange = nil
        watchdog?.cancel()
        watchdog = nil
        interruptionProbe?.cancel()
        interruptionProbe = nil
        #if os(iOS)
        let wasRunning: Bool = continuation != nil
        #endif
        // Kesinti sürerken durdurulduysa dinleyen de öğrenir: yoksa "Mikrofon kesildi" sonraki kayıtta da kalırdı.
        setStatus(.running)
        stopEngine()
        continuation?.finish()
        continuation = nil
        // Sonraki yakalama girişini baştan bildirir (önceki kaydın girişiyle karşılaştırılmaz).
        activeInput = nil
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
        #if os(iOS)
        if shouldRetryAfterCall(status: status, isRestarting: isRestarting, sinceLastAttemptSec: seconds(of: now - lastRestartAttempt), retryIntervalSec: Self.callRetryIntervalSec) {
            lastRestartAttempt = now
            await resumeAfterInterruption()
            return
        }
        #endif
        guard case .reconnecting(let reason) = status,
              shouldRetryMicrophone(status: status, isRestarting: isRestarting, sinceLastAttemptSec: seconds(of: now - lastRestartAttempt), retryIntervalSec: Self.retryIntervalSec) else {
            return
        }
        Self.logger.warning("Mikrofon hâlâ yeniden kurulamadı, yeniden deneniyor, neden: \(reason.rawValue, privacy: .public)")
        await restartEngine(reason: reason)
    }

    /// Motorun yapılandırma değişikliği (giriş cihazı, ses yolu) izlenir; motor her kurmada yenilendiği için yenisi
    /// izlenir (eskisinin bildirimi artık gelmez).
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
        let observers: [(any NSObjectProtocol)?] = [configurationObserver, interruptionObserver, activationObserver, mediaResetObserver, choiceObserver]
        for case let observer? in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        choiceObserver = nil
        configurationObserver = nil
        interruptionObserver = nil
        activationObserver = nil
        mediaResetObserver = nil
        #if os(iOS)
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        #else
        hardwareObserver?.stop()
        hardwareObserver = nil
        #endif
    }

    /// Ses yolu, cihaz listesi ya da seçim değişti. Kurma sürerken (ya da kurulamamışken) sıraya alınır ve kurma bitince
    /// bir kez değerlendirilir; kesinti sürerken (çağrı) kesinti bitince yapılan kurma zaten yeni durumu okur.
    private func routeChangeArrived(change: AudioRouteChange) async {
        guard continuation != nil, !isMicrophoneInterrupted(status: status) else {
            return
        }
        guard !isRestarting, status == .running else {
            pendingRouteChange = mergedRouteChange(pending: pendingRouteChange, new: change)
            return
        }
        #if os(iOS)
        await phoneRouteChanged(change: change)
        #else
        await macHardwareChanged(change: change)
        #endif
    }

    /// Kurma bitti: sırada bekleyen değişiklik varsa değerlendirilir.
    private func processPendingRouteChange() {
        guard let pending = pendingRouteChange, status == .running, !isRestarting else {
            return
        }
        pendingRouteChange = nil
        Task { [weak self] in
            await self?.routeChangeArrived(change: pending)
        }
    }

    /// Eski motoru durdurup yenisini kurar ve izler (tap henüz takılmaz).
    private func replaceEngine() {
        stopEngine()
        engine = AVAudioEngine()
        tapInstalled = false
        observeEngineConfiguration()
    }

    #if os(macOS)
    /// Mac: cihaz takılıp çıkarılınca ya da varsayılan giriş değişince hedef giriş yeniden hesaplanır; kullanılandan
    /// farklıysa motor yeniden kurulur. Dinleyici kurulamazsa loglanır: kayıt sürer, motorun kendi yapılandırma
    /// bildirimi (kullanılan cihaz çıkarılınca) yine çalışır.
    private func observeAudioHardware() {
        let observer: MacAudioHardwareObserver = MacAudioHardwareObserver { [weak self] (change: AudioRouteChange) -> Void in
            Task { @MainActor in
                await self?.routeChangeArrived(change: change)
            }
        }
        do {
            try observer.start()
            hardwareObserver = observer
        } catch {
            Self.logger.error("Ses cihazı değişiklikleri izlenemiyor, hata: \(String(describing: error), privacy: .public)")
        }
    }

    private func macHardwareChanged(change: AudioRouteChange) async {
        let plan: MacInputPlan
        do {
            plan = try macInputPlan(request: input())
        } catch {
            Self.logger.error("Cihaz değişince giriş cihazları okunamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        let target: ActiveAudioInput? = plan.attempts.first
        if change == .choiceChanged, let target, !needsCaptureRebuild(current: activeInput, target: target.device, sessionOptionsChanged: false) {
            // Seçim değişti ama kullanılan cihaz aynı: kurma sesi kesmesin, yalnız durum tazelenir.
            setActiveInput(target)
            return
        }
        guard shouldReselectInput(change: change, target: target?.device, current: activeInput?.device) else {
            return
        }
        Self.logger.info("Ses cihazları ya da seçim değişti, mikrofon yeni girişle kuruluyor")
        await restartEngine(reason: change == .choiceChanged ? .inputSelected : .configurationChange)
    }

    /// Mac'te seçimin sonucu, kurulacak girişler sırasıyla ve cihazların Core Audio kimlikleri.
    private struct MacInputPlan {
        let attempts: [ActiveAudioInput]
        let objectIDs: [String: AudioObjectID]
    }

    private func macInputPlan(request: AudioInputRequest) throws -> MacInputPlan {
        let available: [MacAudioInput] = try macInputDevices()
        let systemDefault: MacAudioInput? = try macDefaultInput()
        let selection: AudioInputSelection = selectAudioInput(request: request, available: available.map(\.device), systemDefault: systemDefault?.device)
        let objectIDs: [String: AudioObjectID] = Dictionary(
            (available + [systemDefault].compactMap { $0 }).map { ($0.device.id, $0.objectID) },
            uniquingKeysWith: { (first: AudioObjectID, _: AudioObjectID) -> AudioObjectID in first }
        )
        return MacInputPlan(attempts: audioInputAttempts(request: request, selection: selection, systemDefault: systemDefault?.device), objectIDs: objectIDs)
    }

    /// Mac: hedef girişi yeni bir motorla kurar; kurulamazsa (cihaz açılmadı, motor başlamadı, format tutmadı) sistemin
    /// varsayılan girişini kurar ve seçimi "kullanılamıyor" bildirir. Cihaz listesi okunamazsa ya da giriş cihazı
    /// yoksa motor sistemin girişiyle kurulur. Hiçbiri kurulamazsa son hata fırlatılır (yeniden denenir).
    private func buildMacCapture(continuation: AsyncStream<[Float]>.Continuation) throws {
        let request: AudioInputRequest = input()
        let plan: MacInputPlan?
        do {
            plan = try macInputPlan(request: request)
        } catch {
            Self.logger.error("Giriş cihazları okunamadı, motor sistemin girişiyle kuruluyor, hata: \(String(describing: error), privacy: .public)")
            plan = nil
        }
        guard let plan, !plan.attempts.isEmpty else {
            replaceEngine()
            try startEngine(continuation: continuation)
            return
        }
        var lastError: any Error = AudioCaptureError.microphoneStartFailed(code: 0)
        for attempt in plan.attempts {
            guard let objectID = plan.objectIDs[attempt.device.id] else {
                continue
            }
            do {
                try startMacEngine(objectID: objectID, continuation: continuation)
                setActiveInput(attempt)
                return
            } catch {
                Self.logger.error("Mikrofon cihazı kurulamadı, sıradaki deneniyor, tür: \(attempt.device.kind.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .public)")
                stopEngine()
                lastError = error
            }
        }
        throw lastError
    }

    /// Yeni motoru verilen cihazla kurar. `setDeviceID`'den sonra giriş düğümünün çıkış (istemci) formatı önceki
    /// cihazın örnekleme hızında kalır: bu Mac'te 44,1 kHz BlackHole seçilince düğüm 48 kHz diyordu ve motor "çalışıyor"
    /// görünürken tap'e hiç ses gelmiyordu. Bu yüzden istemci formatı cihazın donanım hızına ayarlanır ve tutmadıysa tap
    /// takılmaz (`inputFormatNotReady`, sıradaki giriş denenir).
    private func startMacEngine(objectID: AudioObjectID, continuation: AsyncStream<[Float]>.Continuation) throws {
        replaceEngine()
        let input: AVAudioInputNode = engine.inputNode
        try input.auAudioUnit.setDeviceID(objectID)
        let hardwareRate: Double = try macNominalSampleRate(deviceID: objectID)
        let channels: AVAudioChannelCount = max(1, input.inputFormat(forBus: 0).channelCount)
        guard let clientFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: channels) else {
            throw AudioCaptureError.inputFormatNotReady(nodeSampleRate: input.outputFormat(forBus: 0).sampleRate, hardwareSampleRate: hardwareRate)
        }
        // Giriş düğümünün istemci tarafı AUHAL'in 1 numaralı (giriş) çıkış veriyoludur.
        try input.auAudioUnit.outputBusses[1].setFormat(clientFormat)
        let nodeRate: Double = input.outputFormat(forBus: 0).sampleRate
        guard isCaptureFormatReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate) else {
            throw AudioCaptureError.inputFormatNotReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate)
        }
        try startEngine(continuation: continuation)
    }

    /// Çalışan motorun formatı cihazınkiyle hâlâ aynı mı (yapılandırma bildirimi zararsız mıydı).
    private func captureFormatIsCurrent() async -> Bool {
        do {
            let hardwareRate: Double = try macNominalSampleRate(deviceID: engine.inputNode.auAudioUnit.deviceID)
            return isCaptureFormatReady(nodeSampleRate: engine.inputNode.outputFormat(forBus: 0).sampleRate, hardwareSampleRate: hardwareRate)
        } catch {
            Self.logger.warning("Giriş cihazının örnekleme hızı okunamadı, hata: \(String(describing: error), privacy: .public)")
            return false
        }
    }
    #endif

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
                    self?.probeInterruption()
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
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] (notification: Notification) -> Void in
            let rawReason: UInt = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            Task { @MainActor in
                Self.logger.info("Ses yolu değişti, neden: \(rawReason, privacy: .public)")
                await self?.routeChangeArrived(change: audioRouteChange(reason: AVAudioSession.RouteChangeReason(rawValue: rawReason)))
            }
        }
    }

    /// Ses yolu ya da seçim değişti (kurma sürmüyor).
    /// - Seçim değişti: oturum seçenekleri (Bluetooth mikrofonu) değişiyorsa yeniden kurulur; değişmiyorsa yalnız tercih
    ///   edilen giriş verilir, ses yolu yerleşince giriş gerçekten değiştiyse bir kez yeniden kurulur, değişmediyse yalnız
    ///   durum tazelenir.
    /// - Cihaz takıldı/çıkarıldı ve hedef giriş kullanılandan farklı (ör. "Kablolu / USB" seçiliyken kulaklık takıldı:
    ///   `defaultToSpeaker` sistemi yerleşik mikrofonda tutar): yeniden kurulur.
    /// - Diğer: ses yolu girişi değişmediyse yalnız durum tazelenir; değiştiyse motorun yapılandırma bildirimi kurar.
    private func phoneRouteChanged(change: AudioRouteChange) async {
        let request: AudioInputRequest = input()
        if change == .choiceChanged {
            await applyChoiceWithoutRebuild(request: request)
            return
        }
        let snapshot: PhoneInputSnapshot
        do {
            snapshot = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> PhoneInputSnapshot in
                phoneInputSnapshot(session: session)
            }
        } catch {
            Self.logger.error("Ses yolu okunamadı, hata: \(String(describing: error), privacy: .private)")
            return
        }
        let selection: AudioInputSelection = selectAudioInput(request: request, available: snapshot.available, systemDefault: snapshot.current)
        if shouldReselectInput(change: change, target: selection.device, current: snapshot.current) {
            Self.logger.info("Ses yolu değişti, mikrofon seçime göre yeniden kuruluyor, giriş: \(snapshot.current?.kind.rawValue ?? "yok", privacy: .public)")
            await restartEngine(reason: .configurationChange)
            return
        }
        if let current = snapshot.current, current.id == activeInput?.device.id || engine.isRunning {
            setActiveInput(settledActiveInput(request: request, selection: selection, current: current))
        }
    }

    /// Seçim değişti: yeniden kurma yalnız gerekiyorsa (bkz. `phoneRouteChanged`).
    private func applyChoiceWithoutRebuild(request: AudioInputRequest) async {
        guard needsBluetoothInput(choice: request.choice) == appliedBluetoothInput else {
            await restartEngine(reason: .inputSelected)
            return
        }
        let current: AudioInputDevice?
        let preference: PhoneInputPreference
        do {
            preference = try await activateRecordingSession(request: request)
            current = await settleRoute(preference: preference)
        } catch {
            Self.logger.error("Mikrofon seçimi uygulanamadı, yeniden kuruluyor, hata: \(String(describing: error), privacy: .private)")
            await restartEngine(reason: .inputSelected)
            return
        }
        // Ses yolu geçerken motorun yapılandırma bildirimi kurmayı başlatmış olabilir: o kurma yeni seçimi okur.
        guard !isRestarting, continuation != nil else {
            return
        }
        guard let current, !needsCaptureRebuild(current: activeInput, target: current, sessionOptionsChanged: false), engine.isRunning else {
            await restartEngine(reason: .inputSelected)
            return
        }
        setActiveInput(settledActiveInput(request: request, selection: preference.selection, current: current))
    }

    /// Tercih edilen giriş verildiyse ses yolunun ona geçmesi en çok `routeSettleTimeoutSec` beklenir; kullanılan giriş
    /// döner (geçmediyse gerçekte kullanılan).
    private func settleRoute(preference: PhoneInputPreference) async -> AudioInputDevice? {
        let deadline: ContinuousClock.Instant = .now + .seconds(Self.routeSettleTimeoutSec)
        while true {
            let current: AudioInputDevice?
            do {
                current = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> AudioInputDevice? in
                    session.currentRoute.inputs.first.map(phoneInputDevice(port:))
                }
            } catch {
                Self.logger.error("Ses yolu okunamadı, hata: \(String(describing: error), privacy: .private)")
                return nil
            }
            guard preference.applied, let target = preference.selection.device, current?.id != target.id, ContinuousClock.now < deadline else {
                return current
            }
            do {
                try await Task.sleep(for: .seconds(Self.routeSettlePollSec))
            } catch {
                return current
            }
        }
    }

    /// iPhone: oturumu seçimle açar, ses yolunun yerleşmesini bekler, yeni motoru kurar; motorun formatı oturumun
    /// örnekleme hızına geçmediyse tap takılmaz (yeniden denenir). Kullanılan giriş ancak motor çalışınca bildirilir.
    private func buildPhoneCapture(continuation: AsyncStream<[Float]>.Continuation, generation: Int) async throws {
        let request: AudioInputRequest = input()
        let preference: PhoneInputPreference = try await activateRecordingSession(request: request)
        let current: AudioInputDevice? = await settleRoute(preference: preference)
        let hardwareRate: Double = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Double in
            session.sampleRate
        }
        // Beklerken daha yeni bir kurma başladıysa ya da yakalama durdurulduysa motor kurulmaz: iki kurma aynı girişe
        // ikinci tap'i takardı, durdurulan kayıtta mikrofon açık kalırdı.
        guard generation == restartGeneration, self.continuation != nil else {
            return
        }
        replaceEngine()
        let nodeRate: Double = engine.inputNode.outputFormat(forBus: 0).sampleRate
        guard isCaptureFormatReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate) else {
            throw AudioCaptureError.inputFormatNotReady(nodeSampleRate: nodeRate, hardwareSampleRate: hardwareRate)
        }
        try startEngine(continuation: continuation)
        appliedBluetoothInput = needsBluetoothInput(choice: request.choice)
        setActiveInput(settledActiveInput(request: request, selection: preference.selection, current: current))
    }

    /// Çalışan motorun formatı oturumunkiyle hâlâ aynı mı (yapılandırma bildirimi zararsız mıydı).
    private func captureFormatIsCurrent() async -> Bool {
        do {
            let hardwareRate: Double = try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Double in
                session.sampleRate
            }
            return isCaptureFormatReady(nodeSampleRate: engine.inputNode.outputFormat(forBus: 0).sampleRate, hardwareSampleRate: hardwareRate)
        } catch {
            Self.logger.warning("Ses oturumunun örnekleme hızı okunamadı, hata: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    /// Kesinti başladı: kısa bir süre sonra oturum bir kez yeniden açılmayı dener. Bu iPhone'da bir görüşme sürüyorsa
    /// (Zoom, Teams, FaceTime, telefon) iOS bunu `insufficientPriority` ile reddeder: durum `.heldByCall` olur, kayıt
    /// ekranı nedeni söyler ve görüşme bitene dek aralıkla yeniden denenir. Kesinti kısa sürdüyse (alarm) kayıt erken
    /// sürer; reddin başka nedeni varsa kesinti sürer (eski davranış).
    private func probeInterruption() {
        interruptionProbe?.cancel()
        interruptionProbe = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Self.interruptionProbeDelaySec))
            } catch {
                // İptal: yakalama durdu.
                return
            }
            guard let self, self.status == .interrupted else {
                return
            }
            Self.logger.info("Kesinti sürüyor, nedenini anlamak için ses oturumu yeniden açılıyor, uygulama: \(applicationStateName(), privacy: .public)")
            await self.resumeAfterInterruption()
        }
    }

    /// Kesinti bitti: ses oturumu yeniden etkinleştirilir (kesinti onu kapatır) ve motor yeniden kurulur. Oturum
    /// açılamazsa kesinti sürer; uygulama öne gelince yeniden denenir. Açılamamanın nedeni bu iPhone'daki bir görüşmeyse
    /// durum `.heldByCall` olur ve bekçi görüşme bitene dek aralıkla yeniden dener.
    private func resumeAfterInterruption() async {
        guard continuation != nil else {
            return
        }
        do {
            // Kullanılan giriş motor kurulunca (`restartEngine`) bildirilir; burada yalnız oturumun açılabildiği denenir.
            _ = try await activateRecordingSession(request: input())
        } catch {
            if case AudioCaptureError.microphoneHeldByCall = error, isMicrophoneInterrupted(status: status) {
                Self.logger.info("Ses oturumu açılamadı: bu iPhone'da bir görüşme mikrofonu tutuyor, görüşme bitince yeniden denenecek")
                lastRestartAttempt = .now
                setStatus(.heldByCall)
                return
            }
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
        case .interrupted, .heldByCall:
            Self.logger.info("Uygulama öne geldi, kesinti sürüyordu, mikrofon yeniden açılıyor, durum: \(String(describing: self.status), privacy: .public)")
            await resumeAfterInterruption()
        case .reconnecting(let reason):
            guard !isRestarting else {
                return
            }
            Self.logger.info("Uygulama öne geldi, mikrofon yeniden bağlanıyordu, hemen yeniden deneniyor, neden: \(reason.rawValue, privacy: .public)")
            await restartEngine(reason: reason)
        }
    }

    /// Ses servisleri sıfırlandı: eski motor kullanılamaz; kurma yeni motorla yapılır (`replaceEngine`).
    private func rebuildAfterMediaServicesReset() async {
        guard continuation != nil else {
            return
        }
        Self.logger.warning("Ses servisleri sıfırlandı, mikrofon motoru baştan kuruluyor")
        await restartEngine(reason: .mediaServicesReset)
    }

    /// Kayıt başlarken ses oturumu: odadaki konuşmayı yerleşik mikrofonla alır; kayıt arka planda ve ekran kilitliyken
    /// sürer (Info.plist'te `audio` arka plan modu). Bluetooth kulaklık yalnızca çalma için (A2DP) kullanılır; kulaklık
    /// mikrofonu (HFP) yalnızca kullanıcı "Bluetooth kulaklık"ı seçerse açılır (bkz. `recordingSessionOptions`).
    /// Tercih edilen giriş kurmada verilir (`activateRecordingSession`).
    ///
    /// Önce karışmayan oturum açılır: çalan müzik ya da podcast durur, toplantı kaydına karışmaz. Açıldıktan sonra
    /// oturum karışabilir yapılır (`recordingSessionOptions`): başka bir uygulamanın sesi (video, sesli mesaj) kaydı
    /// kesmez ve kesinti sonrası oturum arka planda yeniden açılabilir (iOS karışmayan oturumun arka planda açılmasını
    /// `cannotInterruptOthers` ile reddeder: kesilen kayıt arka planda bir daha ses almaz, uygulama askıya alınır). Gelen
    /// aramanın zil ve bildirimi kaydı kesmez; yalnızca arama kabul edilince kesinti olur.
    /// Oturum değişikliği ana iş parçacığında değil `AudioSessionQueue`'da yapılır (sistem servisini beklerken arayüz
    /// donmasın).
    private func activateRecordingSessionForStart(request: AudioInputRequest) async throws {
        let options: AVAudioSession.CategoryOptions = recordingSessionOptions(choice: request.choice)
        do {
            try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Void in
                try session.setCategory(.playAndRecord, mode: .default, options: options.subtracting(.mixWithOthers))
                try session.setActive(true)
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                do {
                    try session.setPrefersNoInterruptionsFromSystemAlerts(true)
                } catch {
                    // Yalnız tercih: açılmazsa gelen arama zili kaydı keser, kesinti bitince kayıt kendiliğinden sürer.
                    Self.logger.warning("Ses oturumunda sistem uyarısı tercihi ayarlanamadı, kod: \(audioSessionErrorCode(error: error), privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("Kayıt ses oturumu açılamadı, kod: \(audioSessionErrorCode(error: error), privacy: .public), uygulama: \(applicationStateName(), privacy: .public)")
            throw sessionActivationError(error: error)
        }
    }

    /// Her kurmada, kesinti sonrası ve mikrofon seçimi değişince oturum seçimle (yeniden) açılır: karışabilir oturum
    /// (bkz. `activateRecordingSessionForStart`) uygulama arka plandayken de açılabilir; açıkken yeniden açmak zararsız.
    /// Tercih edilen giriş seçime göre verilir.
    private func activateRecordingSession(request: AudioInputRequest) async throws -> PhoneInputPreference {
        let options: AVAudioSession.CategoryOptions = recordingSessionOptions(choice: request.choice)
        do {
            return try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> PhoneInputPreference in
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true)
                return applyPreferredInput(session: session, request: request)
            }
        } catch {
            throw sessionActivationError(error: error)
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

    /// Seçime göre girişi bulup yeni motorla yakalamayı kurar (bkz. `buildPhoneCapture`, `buildMacCapture`).
    private func buildCapture(continuation: AsyncStream<[Float]>.Continuation, generation: Int) async throws {
        #if os(iOS)
        try await buildPhoneCapture(continuation: continuation, generation: generation)
        #else
        try buildMacCapture(continuation: continuation)
        #endif
    }

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

    /// Motorun yapılandırması değişti. Kesinti sürerken (telefon çağrısı) yeniden kurulmaz (kesinti bitince kurulur);
    /// kurma sürerken sıraya alınır (o kurma yeni motor kurar, ses yolunu yeniden okur: bir değişiklik bir kurma). Motor
    /// hâlâ çalışıyor ve formatı donanımla aynıysa bildirim zararsızdır, kurulmaz; değilse yeniden kurulur.
    private func handleConfigurationChange() async {
        guard !isMicrophoneInterrupted(status: status) else {
            Self.logger.info("Kesinti sürerken cihaz değişti; yeniden kurma kesinti bitince yapılacak")
            return
        }
        guard !isRestarting else {
            pendingRouteChange = mergedRouteChange(pending: pendingRouteChange, new: .other)
            return
        }
        if engine.isRunning, await captureFormatIsCurrent() {
            Self.logger.info("Motorun yapılandırması değişti ama motor çalışıyor ve format aynı; yeniden kurulmadı")
            return
        }
        await restartEngine(reason: .configurationChange)
    }

    /// Motoru (yeni formatla) yeniden kurar; yeni cihaz henüz hazır olmayabileceği için birkaç kez dener. Daha yeni bir
    /// istek gelirse ya da yakalama durdurulursa çekilir. Kurulamazsa durum `.reconnecting` kalır ve bekçi aralıkla
    /// yeniden dener (kayıt açık kalır). Kurma sürerken gelen değişiklikler kurma bitince değerlendirilir.
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
                processPendingRouteChange()
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
                    try await self.buildCapture(continuation: continuation, generation: generation)
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
            // Yeniden kurarken bu iPhone'da görüşme başladı: kesinti gibi görüşme bitince sürer (bekçi aralıkla dener).
            if case AudioCaptureError.microphoneHeldByCall = error {
                Self.logger.info("Mikrofon yeniden başlatılamadı: bu iPhone'da bir görüşme mikrofonu tutuyor, neden: \(reason.rawValue, privacy: .public)")
                setStatus(.heldByCall)
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
/// `MicrophoneCapture.activateRecordingSessionForStart`). Kullanıcı "Bluetooth kulaklık"ı seçtiyse kulaklık mikrofonu
/// (HFP) da açılır; iOS 26'da AirPods'un yüksek kaliteli kaydı (destekleyen modelde tam bant; desteklemeyende HFP'ye
/// düşer). Seçilmediyse HFP kapalı kalır: aynı cihazda HFP açıkken iOS onu öncelikle seçer ve AirPods sesini dar banda
/// düşürür (Apple: `AVAudioSessionCategoryOptionAllowBluetoothA2DP` belgesi).
private func recordingSessionOptions(choice: AudioInputChoice) -> AVAudioSession.CategoryOptions {
    let base: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
    guard needsBluetoothInput(choice: choice) else {
        return base
    }
    if #available(iOS 26.0, *) {
        return base.union([.allowBluetoothHFP, .bluetoothHighQualityRecording])
    }
    return base.union(.allowBluetoothHFP)
}

/// Ses yolundaki girişler ve kullanılan giriş.
private struct PhoneInputSnapshot: Sendable {
    let available: [AudioInputDevice]
    let current: AudioInputDevice?
}

/// Tercih edilen girişin sonucu: seçim ve tercih verilebildi mi (verilemediyse ses yolu beklenmez).
private struct PhoneInputPreference: Sendable {
    let selection: AudioInputSelection
    let applied: Bool
}

private func phoneInputSnapshot(session: AVAudioSession) -> PhoneInputSnapshot {
    PhoneInputSnapshot(
        available: (session.availableInputs ?? []).map(phoneInputDevice(port:)),
        current: session.currentRoute.inputs.first.map(phoneInputDevice(port:))
    )
}

/// Seçime göre tercih edilen girişi verir (oturum kuyruğunda, oturum açıkken; Apple: tercih edilen giriş kategori ve
/// mod ayarlanıp oturum açıldıktan sonra verilmeli). "Otomatik"te tercih kaldırılır (nil): ses yolu sistemindir.
/// Tercih verilemezse loglanır; kayıt sistemin girişiyle sürer ve seçim "kullanılamıyor" sayılır
/// (`settledActiveInput`).
private func applyPreferredInput(session: AVAudioSession, request: AudioInputRequest) -> PhoneInputPreference {
    let ports: [AVAudioSessionPortDescription] = session.availableInputs ?? []
    let snapshot: PhoneInputSnapshot = phoneInputSnapshot(session: session)
    let selection: AudioInputSelection = selectAudioInput(request: request, available: snapshot.available, systemDefault: snapshot.current)
    let port: AVAudioSessionPortDescription? = selection.device.flatMap { (device: AudioInputDevice) -> AVAudioSessionPortDescription? in
        ports.first { $0.uid == device.id }
    }
    do {
        try session.setPreferredInput(port)
        return PhoneInputPreference(selection: selection, applied: true)
    } catch {
        phoneInputLogger.error("Tercih edilen mikrofon verilemedi, kayıt sistemin girişiyle sürüyor, tür: \(selection.device?.kind.rawValue ?? "otomatik", privacy: .public), kod: \((error as NSError).code, privacy: .public)")
        return PhoneInputPreference(selection: selection, applied: false)
    }
}

/// iOS ses yolu girişini uygulamanın giriş türüne çevirir.
private func phoneInputDevice(port: AVAudioSessionPortDescription) -> AudioInputDevice {
    AudioInputDevice(id: port.uid, name: port.portName, kind: phoneInputKind(portType: port.portType))
}

private func phoneInputKind(portType: AVAudioSession.Port) -> AudioInputKind {
    switch portType {
    case .builtInMic:
        .builtIn
    case .bluetoothHFP, .bluetoothLE:
        .bluetooth
    case .headsetMic, .lineIn:
        .wired
    case .usbAudio:
        .usb
    case .continuityMicrophone:
        .continuity
    default:
        .other
    }
}

/// iOS ses yolu değişikliğinin nedeni uygulamanın türüne: yalnız takma/çıkarma girişi yeniden seçtirir.
private func audioRouteChange(reason: AVAudioSession.RouteChangeReason?) -> AudioRouteChange {
    switch reason {
    case .newDeviceAvailable:
        .deviceAdded
    case .oldDeviceUnavailable, .noSuitableRouteForCategory:
        .deviceRemoved
    default:
        .other
    }
}

private let phoneInputLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MicrophoneCapture")

/// Ses oturumu hatasının kodu (ör. 560557684 `!int`: karışmayan oturum arka planda açılamaz); içerik taşımaz.
private func audioSessionErrorCode(error: any Error) -> Int {
    switch error {
    case AudioCaptureError.microphoneStartFailed(let code):
        Int(code)
    case AudioCaptureError.microphoneHeldByCall:
        audioSessionInsufficientPriorityCode
    default:
        (error as NSError).code
    }
}

/// Ses oturumu açılamadı: bu iPhone'daki bir görüşme mikrofonu tutuyorsa (`insufficientPriority`) ayrı hata (kullanıcıya
/// nedeni ve çaresi söylenir), değilse kodlu genel hata.
private func sessionActivationError(error: any Error) -> AudioCaptureError {
    let code: Int = (error as NSError).code
    guard !isCallHoldingMicrophone(code: code) else {
        return .microphoneHeldByCall
    }
    return .microphoneStartFailed(code: Int32(code))
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
