import AINotepadCore
import AVFoundation
import Foundation
import MediaPlayer
import Observation
import os

private let playerLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "AudioPlayer")

/// Toplantı sesinin bir konuşmacı kaydı (`me` / `others`): işlenmişse `.m4a`, işleme sürerken `.caf`; yoksa nil.
public func meetingAudioURL(directory: URL, speaker: Speaker) -> URL? {
    ["m4a", "caf"]
        .map { (ext: String) -> URL in directory.appending(path: "\(speaker.rawValue).\(ext)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

/// Seçilebilen çalma hızları (sırayla döner).
public let playbackRates: [Float] = [1, 1.25, 1.5, 2, 0.75]

/// Çalma konumunun yayınlanma adımı (saniye): konum bu kadar ilerleyince görünümler güncellenir.
let playbackPublishStep: Double = 0.1

/// Toplantı oynatıcısı: "Sen" ve "Diğerleri" kayıtlarını aynı zaman çizgisinde birlikte çalar (kayıtlar başlangıca
/// hizalı), duraklatır, sarar, hız değiştirir. Konum ~33 ms'de bir okunur, görünür fark olunca (`playbackPublishStep`,
/// ~10/sn) yayınlanır: kelime vurgusu akıcı, çalma ekranı hafif.
///
/// Çalan toplantı sistemin "Şimdi Çalınan" alanında görünür; kilit ekranı, Denetim Merkezi, AirPods ve Mac'in medya
/// tuşları çaları yönetir. Çalma uygulama arka plandayken (iPhone'da ekran kilitliyken, Mac'te pencere kapalıyken) sürer.
/// Kayıt başlarken çalar durdurulur (bkz. `AppModel`, `PhoneRecorder` gözlemi): sistem denetimleri kayıt sırasında
/// çalara bağlı kalmaz.
@MainActor
@Observable
public final class MeetingAudioPlayer {
    /// Çalan toplantı; çalar boşsa nil.
    public private(set) var meetingID: String?
    public private(set) var isPlaying: Bool = false
    public private(set) var currentTime: Double = 0
    /// Konumun tam saniyesi; yalnızca saniye değişince yayınlanır. Süre etiketleri, konum çubuğu ve şeritteki çizgi
    /// bunu okur: kapakla aynı karttaki çizgi saniyede 10 kez değişince kart (gradyan kapak dahil) baştan çiziliyordu.
    public private(set) var currentSecond: Int = 0
    public private(set) var duration: Double = 0
    public private(set) var rate: Float = 1
    /// Son çalma denemesinin hatası; yalnızca `errorMeetingID` toplantısının sayfasında gösterilir.
    public private(set) var errorMessage: String?
    /// Hatanın ait olduğu toplantı (çalar tek; başka toplantının sayfası bu hatayı göstermez).
    public private(set) var errorMeetingID: String?

    @ObservationIgnored private var players: [AVAudioPlayer] = []
    #if os(iOS)
    /// Çalma için ses oturumunu bu çalar açtı: durunca bırakılır, diğer uygulamaların sesi (müzik) sürer.
    @ObservationIgnored private var ownsAudioSession: Bool = false
    /// Ses oturumunun açılması (oturum kuyruğunda) bitince çalmayı başlatan iş; durdurulunca iptal edilir.
    @ObservationIgnored private var sessionActivation: Task<Void, Never>?
    /// Oturum bir kesintiyle (arama, alarm, Siri) kapandı: sürdürmeden önce yeniden açılır.
    @ObservationIgnored private var sessionInterrupted: Bool = false
    /// Kesinti ve çıkış aygıtı bildirimlerinin gözlemcileri; yalnız oturum bu çalardayken kuruludur.
    @ObservationIgnored private var sessionObservers: [any NSObjectProtocol] = []
    #endif
    /// Kullanıcı çalmayı istiyor (oynattı, duraklatmadı, sona gelmedi): kesinti bitince sistem "sürdür" derse çalma sürer.
    @ObservationIgnored private var wantsPlayback: Bool = false
    @ObservationIgnored private var loadedURLs: [URL] = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let nowPlaying: NowPlayingCenter = NowPlayingCenter()
    /// "Şimdi Çalınan"da gösterilen başlık ve tarih (toplantı açılınca yazılır).
    @ObservationIgnored private var itemTitle: String = ""
    @ObservationIgnored private var itemDateText: String = ""
    @ObservationIgnored private var appName: String?

    public init() {}

    /// Toplantının kayıtlarını (gerekirse) açar ve `startSec`'ten biraz önce birlikte çalmaya başlar (cümlenin başı
    /// kaçmasın).
    public func play(record: MeetingRecord, urls: [URL], startSec: Double) {
        if loadedURLs != urls || meetingID != record.id {
            stop()
            do {
                players = try urls.map { (url: URL) -> AVAudioPlayer in
                    let player: AVAudioPlayer = try AVAudioPlayer(contentsOf: url)
                    player.enableRate = true
                    player.prepareToPlay()
                    return player
                }
            } catch {
                playerLogger.error("Ses açılamadı, toplantı: \(record.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                // `stop()` hatayı temizler; hata ondan sonra bu toplantıya yazılır.
                errorMessage = userFacingMessage(error: StorageError.readFailed(path: urls.first?.path ?? record.id, reason: error.localizedDescription))
                errorMeetingID = record.id
                players = []
                return
            }
            loadedURLs = urls
            meetingID = record.id
            duration = players.map(\.duration).max() ?? 0
            itemTitle = meetingPlaybackTitle(record: record)
            itemDateText = record.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(interfaceLocale()))
            appName = nowPlaying.appName()
            nowPlaying.attach(actions: remoteCommandActions())
        }
        errorMessage = nil
        errorMeetingID = nil
        resume(at: max(0, startSec - 0.3))
    }

    public func togglePause() {
        if isPlaying {
            pause()
        } else {
            resumeFromCurrentPosition()
        }
    }

    /// Duraklatır; konum kayıtların gerçek konumundan alınır (kilit ekranı ve uygulama aynı yeri göstersin).
    private func pause() {
        wantsPlayback = false
        if let position = players.filter(\.isPlaying).map(\.currentTime).max() {
            setPosition(seconds: position)
        }
        players.forEach { $0.pause() }
        ticker?.cancel()
        ticker = nil
        isPlaying = false
        #if os(iOS)
        // Oturum açılırken duraklatıldıysa açılınca çalmasın; oturum sürdürürken yeniden açılır.
        if sessionActivation != nil {
            sessionActivation?.cancel()
            sessionActivation = nil
            sessionInterrupted = true
        }
        #endif
        publishNowPlaying()
    }

    /// Kaldığı yerden sürer; sona gelmişse baştan çalar.
    private func resumeFromCurrentPosition() {
        resume(at: currentTime >= duration - 0.2 ? 0 : currentTime)
    }

    /// Konumu yazar; saniye değiştiyse `currentSecond`'ı da.
    private func setPosition(seconds: Double) {
        currentTime = seconds
        let second: Int = Int(seconds)
        if second != currentSecond {
            currentSecond = second
        }
    }

    /// Konuma gider; çalıyorsa oradan sürer.
    public func seek(to seconds: Double) {
        let target: Double = min(max(0, seconds), duration)
        if isPlaying {
            start(at: target)
        } else {
            players.forEach { $0.currentTime = target }
            setPosition(seconds: target)
            publishNowPlaying()
        }
    }

    /// İleri/geri sarar (ör. ±10 sn).
    public func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    /// Hızı sıradaki değere geçirir.
    public func cycleRate() {
        let index: Int = playbackRates.firstIndex(of: rate) ?? 0
        rate = playbackRates[(index + 1) % playbackRates.count]
        players.forEach { $0.rate = rate }
        if let position = players.filter(\.isPlaying).map(\.currentTime).max() {
            setPosition(seconds: position)
        }
        publishNowPlaying()
    }

    /// Çalmayı bitirir, dosyaları ve hatayı bırakır (toplantı değişince ya da ses silinince). "Şimdi Çalınan" temizlenir,
    /// sistem denetimleri bırakılır. iPhone'da çalma için açılan ses oturumu kapatılır; diğer uygulamaların sesi (müzik,
    /// podcast) kaldığı yerden sürer.
    public func stop() {
        let wasLoaded: Bool = meetingID != nil
        ticker?.cancel()
        ticker = nil
        players.forEach { $0.stop() }
        players = []
        loadedURLs = []
        meetingID = nil
        isPlaying = false
        wantsPlayback = false
        setPosition(seconds: 0)
        duration = 0
        errorMessage = nil
        errorMeetingID = nil
        if wasLoaded {
            nowPlaying.detach()
            nowPlaying.clear()
        }
        #if os(iOS)
        sessionActivation?.cancel()
        sessionActivation = nil
        sessionInterrupted = false
        removeSessionObservers()
        if ownsAudioSession {
            ownsAudioSession = false
            // Kapatma kuyruğa bekletmeden eklenir; açılma sürüyorsa kuyrukta ondan sonra çalışır.
            AudioSessionQueue.enqueue(
                { (session: AVAudioSession) throws -> Void in
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                },
                onError: { (error: any Error) -> Void in
                    playerLogger.error("Çalma oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
                }
            )
        }
        #endif
    }

    /// Verilen konumdan çalar. iPhone'da önce ses oturumu açılır (açık değilse ya da kesintiyle kapandıysa).
    private func resume(at seconds: Double) {
        #if os(iOS)
        // Oturum açık ve açılma bitmişse hemen çalar; açılma sürüyorsa yeni konumla yeniden kurulur.
        if ownsAudioSession && sessionActivation == nil && !sessionInterrupted {
            start(at: seconds)
            return
        }
        // Oturum ana iş parçacığında değil oturum kuyruğunda açılır (sistem servisini beklerken arayüz donmasın);
        // açılınca çalma başlar. Oturum açıldığı için durdurmada kapatılır (iptal edilse de).
        if !ownsAudioSession {
            ownsAudioSession = true
            observeSession()
        }
        sessionInterrupted = false
        wantsPlayback = true
        let meetingID: String? = meetingID
        sessionActivation?.cancel()
        sessionActivation = Task { [weak self] in
            do {
                // Sessiz modda ve arka planda da çalar; konuşma için ayarlı oturum.
                try await AudioSessionQueue.perform { (session: AVAudioSession) throws -> Void in
                    try session.setCategory(.playback, mode: .spokenAudio)
                    try session.setActive(true)
                }
            } catch {
                playerLogger.error("Çalma oturumu açılamadı, hata: \(String(describing: error), privacy: .private)")
                guard let self, !Task.isCancelled else {
                    return
                }
                self.sessionActivation = nil
                self.sessionInterrupted = true
                self.wantsPlayback = false
                self.errorMessage = userFacingMessage(error: AudioCaptureError.playbackSessionFailed(code: Int32((error as NSError).code)))
                self.errorMeetingID = meetingID
                self.publishNowPlaying()
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            self.sessionActivation = nil
            self.start(at: seconds)
        }
        #else
        start(at: seconds)
        #endif
    }

    /// Tüm kayıtları aynı konumdan, aynı anda başlatır (kayıtlar arası kayma olmasın).
    private func start(at seconds: Double) {
        guard let reference = players.first else {
            return
        }
        let startAt: TimeInterval = reference.deviceCurrentTime + 0.05
        for player in players {
            player.pause()
            player.currentTime = min(seconds, player.duration)
            player.rate = rate
            if seconds < player.duration {
                player.play(atTime: startAt)
            }
        }
        setPosition(seconds: seconds)
        isPlaying = true
        wantsPlayback = true
        publishNowPlaying()
        startTicker()
    }

    /// Konumu çalarken ~33 ms'de bir okur, görünür fark olunca yayınlar; tüm kayıtlar bitince durur.
    private func startTicker() {
        ticker?.cancel()
        // Kullanıcı öncelikli: makine yoğunken (derleme, dışa aktarma) konum güncellemesi arka plan işlerinin
        // arkasında kalmasın.
        ticker = Task(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                // Önce beklenir: kayıtlar 50 ms sonra başlar (`play(atTime:)`); hemen bakılırsa "çalmıyor" görünür.
                do {
                    try await Task.sleep(for: .milliseconds(33))
                } catch {
                    return
                }
                guard let self else {
                    return
                }
                let playing: [AVAudioPlayer] = self.players.filter(\.isPlaying)
                if let position = playing.map(\.currentTime).max() {
                    // Konum yalnızca görünür bir fark olunca yayınlanır (~10/sn): kelime vurgusu ve süre için yeter;
                    // her 33 ms'de yayınlamak çalma ekranını boşuna saniyede 30 kez yeniden çizdiriyordu.
                    if abs(position - self.currentTime) >= playbackPublishStep {
                        self.setPosition(seconds: position)
                    }
                } else {
                    // Kayıtlar bitti ya da sistem durdurdu (kesinti): ikincisinde `wantsPlayback` kalır, kesinti
                    // bitince sürer.
                    if self.currentTime >= self.duration - 0.5 {
                        self.wantsPlayback = false
                        self.setPosition(seconds: self.duration)
                    }
                    self.isPlaying = false
                    self.ticker = nil
                    self.publishNowPlaying()
                    return
                }
            }
        }
    }

    // MARK: Sistem denetimleri

    /// Çalma durumunu sistemin "Şimdi Çalınan" alanına yazar (çalma, duraklatma, sarma, hız değişince; arada sistem
    /// konumu hızla kendisi ilerletir).
    private func publishNowPlaying() {
        guard meetingID != nil else {
            return
        }
        nowPlaying.publish(snapshot: nowPlayingSnapshot(
            title: itemTitle, dateText: itemDateText, appName: appName, duration: duration, elapsed: currentTime, rate: rate,
            isPlaying: isPlaying
        ))
    }

    /// Kilit ekranı, Denetim Merkezi, AirPods ve medya tuşlarından gelen komutlar.
    private func remoteCommandActions() -> RemoteCommandActions {
        RemoteCommandActions(
            play: { [weak self] () -> MPRemoteCommandHandlerStatus in
                guard let self, self.meetingID != nil else {
                    return .noActionableNowPlayingItem
                }
                if !self.isPlaying {
                    self.resumeFromCurrentPosition()
                }
                return .success
            },
            pause: { [weak self] () -> MPRemoteCommandHandlerStatus in
                guard let self, self.meetingID != nil else {
                    return .noActionableNowPlayingItem
                }
                if self.isPlaying || self.wantsPlayback {
                    self.pause()
                }
                return .success
            },
            togglePlayPause: { [weak self] () -> MPRemoteCommandHandlerStatus in
                guard let self, self.meetingID != nil else {
                    return .noActionableNowPlayingItem
                }
                self.togglePause()
                return .success
            },
            skip: { [weak self] (seconds: Double) -> MPRemoteCommandHandlerStatus in
                guard let self, self.meetingID != nil else {
                    return .noActionableNowPlayingItem
                }
                self.skip(by: seconds)
                return .success
            },
            seek: { [weak self] (seconds: Double) -> MPRemoteCommandHandlerStatus in
                guard let self, self.meetingID != nil else {
                    return .noActionableNowPlayingItem
                }
                self.seek(to: seconds)
                return .success
            }
        )
    }

    #if os(iOS)
    // MARK: Ses oturumu (iPhone)

    /// Kesintileri (arama, alarm) ve çıkış aygıtı değişikliklerini (kulaklık çıktı) izler.
    private func observeSession() {
        removeSessionObservers()
        let session: AVAudioSession = AVAudioSession.sharedInstance()
        let interruption: any NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] (notification: Notification) -> Void in
            let rawType: UInt? = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions: UInt? = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor in
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        }
        let routeChange: any NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] (notification: Notification) -> Void in
            let rawReason: UInt? = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                self?.handleRouteChange(rawReason: rawReason)
            }
        }
        sessionObservers = [interruption, routeChange]
    }

    private func removeSessionObservers() {
        sessionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        sessionObservers = []
    }

    /// Kesinti başlayınca sistem çalmayı durdurmuştur: arayüz ve "Şimdi Çalınan" duraklatılmış gösterir. Bitince sistem
    /// "sürdür" derse ve kullanıcı duraklatmamışsa kaldığı yerden sürer (oturum yeniden açılır).
    private func handleInterruption(rawType: UInt?, rawOptions: UInt?) {
        guard meetingID != nil, ownsAudioSession else {
            return
        }
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            playerLogger.error("Ses oturumu kesinti bildirimi türsüz geldi, tür: \(rawType.map(String.init) ?? "yok", privacy: .public)")
            return
        }
        switch type {
        case .began:
            playerLogger.info("Çalma kesildi, konum: \(self.currentTime, privacy: .public), sürecek: \(self.wantsPlayback, privacy: .public)")
            sessionInterrupted = true
            sessionActivation?.cancel()
            sessionActivation = nil
            players.forEach { $0.pause() }
            ticker?.cancel()
            ticker = nil
            isPlaying = false
            publishNowPlaying()
        case .ended:
            let shouldResume: Bool = (rawOptions ?? 0) & AVAudioSession.InterruptionOptions.shouldResume.rawValue != 0
            playerLogger.info("Çalma kesintisi bitti, sistem sürdür diyor: \(shouldResume, privacy: .public), sürecek: \(self.wantsPlayback, privacy: .public)")
            if shouldResume && wantsPlayback {
                resumeFromCurrentPosition()
            }
        @unknown default:
            playerLogger.error("Bilinmeyen ses oturumu kesinti türü, tür: \(rawType, privacy: .public)")
        }
    }

    /// Kulaklık çıkınca (ya da Bluetooth aygıtı gidince) çalma duraklar: ses hoparlörden devam etmesin.
    private func handleRouteChange(rawReason: UInt?) {
        guard meetingID != nil, ownsAudioSession, isPlaying else {
            return
        }
        guard let rawReason, let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            playerLogger.error("Çıkış aygıtı bildirimi nedensiz geldi, neden: \(rawReason.map(String.init) ?? "yok", privacy: .public)")
            return
        }
        if reason == .oldDeviceUnavailable {
            playerLogger.info("Çıkış aygıtı gitti, çalma duraklatıldı")
            pause()
        }
    }
    #endif
}
