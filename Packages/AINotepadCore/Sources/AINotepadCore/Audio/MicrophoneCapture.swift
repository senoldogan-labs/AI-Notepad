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
/// Hangi mikrofonun kullanılacağını her (yeniden) kurmada `input` sorulup `selectAudioInput` karar verir: iPhone'da
/// ses oturumunun tercih edilen girişi (`setPreferredInput`; Bluetooth kulaklık seçildiyse oturum HFP'ye ve iOS 26'da
/// AirPods yüksek kaliteli kayda izin verir), Mac'te motorun giriş cihazı (`AUAudioUnit.setDeviceID`). Cihaz takılıp
/// çıkarılınca (iPhone `routeChangeNotification`, Mac Core Audio cihaz listesi ve varsayılan giriş) hedef giriş
/// kullanılandan farklıysa motor yeniden kurulur; seçilen giriş yoksa "Otomatik" kuralıyla sürer. Kayıt hiçbir
/// durumda durmaz; kullanılan giriş `activeInput` ve `onInputChange` ile bildirilir.
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
    /// iOS: kesinti başlayınca nedenini anlamak için bir kez yeniden açma denemesi (bkz. `probeInterruption`).
    private var interruptionProbe: Task<Void, Never>?
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
    /// Kullanıcının mikrofon seçimi ve bağlamı; her (yeniden) kurmada okunur (ayar kayıt sırasında da değişebilir).
    private let input: @MainActor () -> AudioInputRequest
    /// Kullanılan giriş (bilinmiyorsa nil: ör. Mac'te cihaz listesi okunamadı, motor sistemin girişini kullanıyor).
    public private(set) var activeInput: ActiveAudioInput?
    /// Kullanılan giriş değişince çağrılır (kayıt ekranı adını ve kısa bildirimi gösterir).
    public var onInputChange: (@MainActor (ActiveAudioInput) -> Void)?
    /// Mikrofon seçimi değişti (`audioInputChoiceDidChange`): yakalama yeni girişle yeniden kurulur.
    private var choiceObserver: (any NSObjectProtocol)?
    #if os(iOS)
    /// iOS: ses yolu değişti (kulaklık takıldı/çıkarıldı, AirPods bağlandı).
    private var routeChangeObserver: (any NSObjectProtocol)?
    #else
    /// Mac: cihaz takıldı/çıkarıldı ya da varsayılan giriş değişti.
    private var hardwareObserver: MacAudioHardwareObserver?
    #endif

    /// `input`: kullanıcının mikrofon seçimi ve bağlamı (bkz. `AudioInputRequest`); her (yeniden) kurmada çağrılır.
    public init(input: @escaping @MainActor () -> AudioInputRequest) {
        self.input = input
    }

    /// Kullanıcı mikrofon seçimini değiştirdi: yakalama sürüyorsa yeni seçimle yeniden kurulur (kayıt durmaz). Kesinti
    /// sürerken (çağrı) beklenir: kesinti bitince kurma yeni seçimi zaten okur.
    public func inputChoiceChanged() async {
        guard continuation != nil, !isMicrophoneInterrupted(status: status) else {
            return
        }
        Self.logger.info("Mikrofon seçimi değişti, yakalama yeni girişle kuruluyor")
        await restartEngine(reason: .inputSelected)
    }

    /// Kullanılan giriş: değiştiyse dinleyene bildirilir.
    private func setActiveInput(_ newInput: ActiveAudioInput?) {
        guard let newInput, newInput != activeInput else {
            return
        }
        activeInput = newInput
        Self.logger.info("Mikrofon girişi, tür: \(newInput.device.kind.rawValue, privacy: .public), seçim yok: \(newInput.unavailableChoice != nil, privacy: .public)")
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
        #if os(iOS)
        // Oturum beklenirken `stop()` çağrılırsa (sayaç artar) başlatma yarıda kalır: `stop()` akışı bitirdi ve oturumu
        // bıraktı; motor, gözlemciler ve bekçi kurulmaz, kurulsaydı mikrofon kayıt bittikten sonra da açık kalırdı.
        let selectedInput: ActiveAudioInput?
        do {
            selectedInput = try await activateRecordingSessionForStart(request: input())
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
        #else
        let selectedInput: ActiveAudioInput? = selectMacInput(request: input())
        #endif
        do {
            try startEngine(continuation: continuation)
            setActiveInput(selectedInput)
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

    #if os(macOS)
    /// Mac: cihaz takılıp çıkarılınca ya da varsayılan giriş değişince hedef giriş yeniden hesaplanır; kullanılandan
    /// farklıysa motor yeniden kurulur. Dinleyici kurulamazsa loglanır: kayıt sürer, motorun kendi yapılandırma
    /// bildirimi (kullanılan cihaz çıkarılınca) yine çalışır.
    private func observeAudioHardware() {
        let observer: MacAudioHardwareObserver = MacAudioHardwareObserver { [weak self] (change: AudioRouteChange) -> Void in
            Task { @MainActor in
                await self?.hardwareChanged(change: change)
            }
        }
        do {
            try observer.start()
            hardwareObserver = observer
        } catch {
            Self.logger.error("Ses cihazı değişiklikleri izlenemiyor, hata: \(String(describing: error), privacy: .public)")
        }
    }

    private func hardwareChanged(change: AudioRouteChange) async {
        guard continuation != nil, status == .running, !isRestarting else {
            return
        }
        let target: AudioInputDevice?
        do {
            target = try macTargetInput(request: input())?.input.device
        } catch {
            Self.logger.error("Cihaz değişince giriş cihazları okunamadı, hata: \(String(describing: error), privacy: .public)")
            return
        }
        guard shouldReselectInput(change: change, target: target, current: activeInput?.device) else {
            return
        }
        Self.logger.info("Ses cihazları değişti, mikrofon yeni girişle kuruluyor")
        await restartEngine(reason: .configurationChange)
    }

    /// Mac'te kullanılacak giriş ve seçimin sonucu; giriş cihazı yoksa nil.
    private func macTargetInput(request: AudioInputRequest) throws -> (input: MacAudioInput, selection: AudioInputSelection)? {
        let available: [MacAudioInput] = try macInputDevices()
        let systemDefault: MacAudioInput? = try macDefaultInput()
        let selection: AudioInputSelection = selectAudioInput(request: request, available: available.map(\.device), systemDefault: systemDefault?.device)
        guard let target = resolvedAudioInput(selection: selection, systemDefault: systemDefault?.device),
              let input = available.first(where: { $0.device.id == target.id }) ?? systemDefault else {
            return nil
        }
        return (input: input, selection: selection)
    }

    /// Mac: motorun giriş cihazını seçer (motor dururken). Seçilen cihaz kurulamazsa sistemin varsayılan girişi kurulur
    /// ve seçim "kullanılamıyor" sayılır (kullanıcıya söylenir); kayıt mikrofonsuz kalmaz. Cihazlar okunamazsa ya da
    /// varsayılan giriş de kurulamazsa loglanır, motorun cihazı değiştirilmez (nil).
    private func selectMacInput(request: AudioInputRequest) -> ActiveAudioInput? {
        let target: (input: MacAudioInput, selection: AudioInputSelection)?
        do {
            target = try macTargetInput(request: request)
        } catch {
            Self.logger.error("Giriş cihazları okunamadı, motorun cihazı değiştirilmedi, hata: \(String(describing: error), privacy: .public)")
            return nil
        }
        guard let target else {
            Self.logger.warning("Bağlı giriş cihazı yok")
            return nil
        }
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(target.input.objectID)
            return ActiveAudioInput(device: target.input.device, unavailableChoice: target.selection.unavailableChoice)
        } catch {
            Self.logger.error("Mikrofon cihazı seçilemedi, varsayılan giriş deneniyor, tür: \(target.input.device.kind.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .public)")
        }
        do {
            guard let systemDefault = try macDefaultInput(), systemDefault.device.id != target.input.device.id else {
                return nil
            }
            try engine.inputNode.auAudioUnit.setDeviceID(systemDefault.objectID)
            return ActiveAudioInput(device: systemDefault.device, unavailableChoice: request.choice == .automatic ? nil : request.choice)
        } catch {
            Self.logger.error("Varsayılan giriş de kurulamadı, motorun cihazı değiştirilmedi, hata: \(String(describing: error), privacy: .public)")
            return nil
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
                await self?.routeChanged(rawReason: rawReason)
            }
        }
    }

    /// Ses yolu değişti. Cihaz takıldı/çıkarıldıysa ve seçime göre hedef giriş kullanılandan farklıysa motor yeniden
    /// kurulur (ör. "Kablolu / USB" seçiliyken kulaklık takıldı: `defaultToSpeaker` sistemi yerleşik mikrofonda
    /// tutar). Değilse yalnızca kullanılan giriş tazelenir (sistem girişi kendisi değiştirdiyse ad güncellensin).
    private func routeChanged(rawReason: UInt) async {
        guard continuation != nil, status == .running, !isRestarting else {
            return
        }
        let change: AudioRouteChange = audioRouteChange(reason: AVAudioSession.RouteChangeReason(rawValue: rawReason))
        let request: AudioInputRequest = input()
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
        Self.logger.info("Ses yolu değişti, neden: \(rawReason, privacy: .public), giriş: \(snapshot.current?.kind.rawValue ?? "yok", privacy: .public)")
        if shouldReselectInput(change: change, target: selection.device, current: snapshot.current) {
            Self.logger.info("Ses yolu değişti, mikrofon seçime göre yeniden kuruluyor")
            await restartEngine(reason: .configurationChange)
            return
        }
        if let current = snapshot.current {
            setActiveInput(ActiveAudioInput(device: current, unavailableChoice: selection.unavailableChoice))
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
    /// mikrofonu (HFP) yalnızca kullanıcı "Bluetooth kulaklık"ı seçerse açılır (bkz. `recordingSessionOptions`), sonra
    /// `request`'e göre tercih edilen giriş kurulur (`applyPreferredInput`).
    ///
    /// Önce karışmayan oturum açılır: çalan müzik ya da podcast durur, toplantı kaydına karışmaz. Açıldıktan sonra
    /// oturum karışabilir yapılır (`recordingSessionOptions`): başka bir uygulamanın sesi (video, sesli mesaj) kaydı
    /// kesmez ve kesinti sonrası oturum arka planda yeniden açılabilir (iOS karışmayan oturumun arka planda açılmasını
    /// `cannotInterruptOthers` ile reddeder: kesilen kayıt arka planda bir daha ses almaz, uygulama askıya alınır). Gelen
    /// aramanın zil ve bildirimi kaydı kesmez; yalnızca arama kabul edilince kesinti olur.
    /// Oturum değişikliği ana iş parçacığında değil `AudioSessionQueue`'da yapılır (sistem servisini beklerken arayüz
    /// donmasın).
    private func activateRecordingSessionForStart(request: AudioInputRequest) async throws -> ActiveAudioInput? {
        let options: AVAudioSession.CategoryOptions = recordingSessionOptions(choice: request.choice)
        do {
            return try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> ActiveAudioInput? in
                try session.setCategory(.playAndRecord, mode: .default, options: options.subtracting(.mixWithOthers))
                try session.setActive(true)
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                do {
                    try session.setPrefersNoInterruptionsFromSystemAlerts(true)
                } catch {
                    // Yalnız tercih: açılmazsa gelen arama zili kaydı keser, kesinti bitince kayıt kendiliğinden sürer.
                    Self.logger.warning("Ses oturumunda sistem uyarısı tercihi ayarlanamadı, kod: \(audioSessionErrorCode(error: error), privacy: .public)")
                }
                return applyPreferredInput(session: session, request: request)
            }
        } catch {
            Self.logger.error("Kayıt ses oturumu açılamadı, kod: \(audioSessionErrorCode(error: error), privacy: .public), uygulama: \(applicationStateName(), privacy: .public)")
            throw sessionActivationError(error: error)
        }
    }

    /// Kesinti, takılma, ses servisleri sıfırlanınca ya da mikrofon seçimi değişince oturum yeniden açılır: karışabilir
    /// oturum (bkz. `activateRecordingSessionForStart`) uygulama arka plandayken de açılabilir; açıkken yeniden açmak
    /// zararsız. Tercih edilen giriş seçime göre yeniden kurulur.
    private func activateRecordingSession(request: AudioInputRequest) async throws -> ActiveAudioInput? {
        let options: AVAudioSession.CategoryOptions = recordingSessionOptions(choice: request.choice)
        do {
            return try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> ActiveAudioInput? in
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
        guard !isMicrophoneInterrupted(status: status) else {
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
                    let selectedInput: ActiveAudioInput? = try await self.activateRecordingSession(request: self.input())
                    // Oturum beklenirken daha yeni bir yeniden kurma başladıysa ya da yakalama durdurulduysa motor
                    // kurulmaz: iki kurma aynı girişe ikinci tap'i takardı, durdurulan kayıtta mikrofon açık kalırdı.
                    guard generation == self.restartGeneration, self.continuation != nil else {
                        return
                    }
                    #else
                    // Seçilen cihaz yoksa (çıkarıldı) "Otomatik" kuralıyla başka giriş kurulur; kayıt sürer.
                    let selectedInput: ActiveAudioInput? = self.selectMacInput(request: self.input())
                    #endif
                    try self.startEngine(continuation: continuation)
                    self.setActiveInput(selectedInput)
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

private func phoneInputSnapshot(session: AVAudioSession) -> PhoneInputSnapshot {
    PhoneInputSnapshot(
        available: (session.availableInputs ?? []).map(phoneInputDevice(port:)),
        current: session.currentRoute.inputs.first.map(phoneInputDevice(port:))
    )
}

/// Seçime göre tercih edilen girişi kurar (oturum kuyruğunda, oturum açıkken; Apple: tercih edilen giriş kategori ve
/// mod ayarlanıp oturum açıldıktan sonra verilmeli) ve kullanılan girişi döndürür. "Otomatik"te tercih kaldırılır (nil):
/// ses yolu sistemindir. Tercih kurulamazsa loglanır, kayıt sistemin girişiyle sürer ve seçim "kullanılamıyor" sayılır.
private func applyPreferredInput(session: AVAudioSession, request: AudioInputRequest) -> ActiveAudioInput? {
    let ports: [AVAudioSessionPortDescription] = session.availableInputs ?? []
    let snapshot: PhoneInputSnapshot = phoneInputSnapshot(session: session)
    let selection: AudioInputSelection = selectAudioInput(request: request, available: snapshot.available, systemDefault: snapshot.current)
    let port: AVAudioSessionPortDescription? = selection.device.flatMap { (device: AudioInputDevice) -> AVAudioSessionPortDescription? in
        ports.first { $0.uid == device.id }
    }
    do {
        try session.setPreferredInput(port)
    } catch {
        phoneInputLogger.error("Tercih edilen mikrofon kurulamadı, kayıt sistemin girişiyle sürüyor, tür: \(selection.device?.kind.rawValue ?? "otomatik", privacy: .public), kod: \((error as NSError).code, privacy: .public)")
        return session.currentRoute.inputs.first.map { (current: AVAudioSessionPortDescription) -> ActiveAudioInput in
            ActiveAudioInput(device: phoneInputDevice(port: current), unavailableChoice: request.choice == .automatic ? nil : request.choice)
        }
    }
    // Ses yolu değişikliği hemen görünmeyebilir: hedef seçildiyse o yazılır; `routeChanged` gerçeğini sonra tazeler.
    let used: AudioInputDevice? = selection.device ?? session.currentRoute.inputs.first.map(phoneInputDevice(port:))
    return used.map { (device: AudioInputDevice) -> ActiveAudioInput in
        ActiveAudioInput(device: device, unavailableChoice: selection.unavailableChoice)
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
