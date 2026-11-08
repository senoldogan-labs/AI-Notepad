// ScreenCaptureKit yalnız cihaz SDK'sında var (iOS Simulator SDK'sında yok).
#if CALL_CAPTURE_EXPERIMENT && canImport(ScreenCaptureKit)
import AINotepadCore
import AINotepadUI
import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit
import os

/// Deneysel görüşme kaydının aşaması. Akış ve dosyaları yalnız yakalanırken ve bitirilirken vardır (`CallCaptureTake`).
@available(iOS 27.0, *)
enum CallCapturePhase: Equatable {
    case idle
    /// Sistem seçicisi açık (kullanıcı ekranı paylaşmayı ve mikrofonu onaylıyor).
    case picking
    case capturing(CallCaptureTake)
    /// Akış durdu, dosyalar kapanıyor ve karıştırılıyor.
    case finishing(CallCaptureTake)
    /// Karışık dosya hazır; içe aktarılabilir.
    case finished(mixed: URL)
    /// Karışık dosya toplantı olarak içe aktarılıyor; olmazsa `finished`e döner (kayıt silinmez).
    case importing(mixed: URL)
}

/// Süren yakalama: akış, ses çıkışı, akış temsilcisi (akış onu tutmaz) ve dosyaların klasörü.
@available(iOS 27.0, *)
struct CallCaptureTake: Equatable {
    let stream: SCStream
    let output: CallStreamOutput
    let delegate: CallStreamDelegate
    let directory: URL
    let startedAt: Date

    static func == (lhs: CallCaptureTake, rhs: CallCaptureTake) -> Bool {
        lhs.stream === rhs.stream
    }
}

/// Ham dosyaların klasörü: her yeni kayıt öncekini siler (deneysel; yalnız son kayıt saklanır).
func callCaptureRootDirectory() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        .appending(path: "CallCaptureExperiment", directoryHint: .isDirectory)
}

/// Karışık dosyanın adı (arayüz dilinde); içe aktarılan toplantının başlığı olur. Saf fonksiyondur.
func callMixedFileName(startedAt: Date, timeZone: TimeZone) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH.mm"
    return String(localized: "Telefon görüşmesi \(formatter.string(from: startedAt))") + ".m4a"
}

/// iPhone'da çalışan görüşmenin sesini (sistem sesi + mikrofon) ScreenCaptureKit'le yakalar; iki kaynağın canlı
/// seviyesini ve sayaçlarını gösterir, durunca iki ham dosyayı tek m4a'ya karıştırır.
///
/// İzin sistem seçicisidir (`SCContentSharingPicker`): kullanıcı ekranı paylaşmayı onaylar, mikrofonu seçicideki
/// düğmeyle açar. Arka planda sürmesi için `UIBackgroundModes` içinde `screen-capture` gerekir (derleme betiği ekler).
@available(iOS 27.0, *)
@MainActor
@Observable
final class CallCaptureController {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "CallCapture")

    private(set) var phase: CallCapturePhase = .idle
    private(set) var errorMessages: [String] = []
    private(set) var systemStats: CallSourceStats = .empty
    private(set) var microphoneStats: CallSourceStats = .empty
    /// Kullanıcı seçicide mikrofonu açtı.
    private(set) var microphoneEnabled: Bool = false
    /// Son kaydın ham dosyaları (paylaşmak için); yoksa boş.
    private(set) var rawFiles: [URL] = []
    let systemLevels: AudioLevels = AudioLevels(count: 36, interval: 0.08)
    let microphoneLevels: AudioLevels = AudioLevels(count: 36, interval: 0.08)
    @ObservationIgnored private var pickerObserver: CallPickerObserver?

    /// Cihazda ekran kaydı destekleniyor ve izinli (ör. Ekran Süresi kısıtlaması yok).
    var isAvailable: Bool {
        SCContentSharingPicker.shared.isAvailable
    }

    /// Sistem seçicisini açar; seçim gelince akış başlar.
    func start() {
        guard phase == .idle || isFinished else {
            return
        }
        guard isAvailable else {
            errorMessages = [String(localized: "Bu cihazda ekran kaydı kullanılamıyor (Ekran Süresi kısıtlaması olabilir).")]
            return
        }
        errorMessages = []
        phase = .picking
        let observer: CallPickerObserver = CallPickerObserver(
            onSelect: { [weak self] (filter: CallFilterBox) -> Void in
                Task { @MainActor in await self?.begin(filter: filter.filter) }
            },
            onCancel: { [weak self] () -> Void in
                Task { @MainActor in self?.pickerEnded(message: nil) }
            },
            onFail: { [weak self] (message: String) -> Void in
                Task { @MainActor in self?.pickerEnded(message: message) }
            }
        )
        pickerObserver = observer
        let picker: SCContentSharingPicker = SCContentSharingPicker.shared
        var configuration: SCContentSharingPickerConfiguration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = true
        picker.defaultConfiguration = configuration
        picker.add(observer)
        picker.isActive = true
        picker.present(using: .display)
    }

    /// Akışı durdurur, dosyaları kapatıp karıştırır.
    func stop() async {
        guard case .capturing(let take) = phase else {
            return
        }
        phase = .finishing(take)
        do {
            try await take.stream.stopCapture()
        } catch {
            Self.logger.error("Akış durdurulamadı, hata: \(String(describing: error), privacy: .public)")
            errorMessages.append(String(localized: "Akış durdurulamadı: \(String(describing: error))"))
        }
        await finish(take: take)
    }

    /// Karışık dosyayı görüşme kaydı olarak içe aktarma hattına verir (toplantı kuyruğa girer): olduysa ekran baştaki
    /// haline döner ve true; olmadıysa neden hatalarda görünür, kayıt kalır (yeniden denenebilir, paylaşılabilir) ve false.
    func importAsMeeting(recorder: PhoneRecorder) async -> Bool {
        guard case .finished(let mixed) = phase else {
            return false
        }
        phase = .importing(mixed: mixed)
        if let failure = await recorder.importCallRecording(url: mixed) {
            Self.logger.error("Görüşme kaydı içe aktarılamadı, kayıt saklı kaldı")
            errorMessages.append(failure)
            phase = .finished(mixed: mixed)
            return false
        }
        phase = .idle
        return true
    }

    private var isFinished: Bool {
        if case .finished = phase {
            return true
        }
        return false
    }

    private func pickerEnded(message: String?) {
        detachPicker()
        if let message {
            errorMessages.append(String(localized: "Seçici açılamadı: \(message)"))
        }
        if phase == .picking {
            phase = .idle
        }
    }

    private func detachPicker() {
        let picker: SCContentSharingPicker = SCContentSharingPicker.shared
        if let pickerObserver {
            picker.remove(pickerObserver)
        }
        pickerObserver = nil
        picker.isActive = false
    }

    private func begin(filter: SCContentFilter) async {
        guard phase == .picking else {
            return
        }
        // Seçici kayıt bitene dek etkin kalır (sistem arayüzündeki paylaşım denetimi ona bağlı olabilir); ikinci seçim
        // yukarıdaki koşulla yok sayılır.
        let now: Date = Date()
        let folder: URL
        // Yalnız son kayıt saklanır: yeni kayıt (ya da "Yeniden kaydet") öncekini siler. İçe aktarılamayan kayıt burada
        // kalır; kullanıcı onu yeniden kaydetmeyi seçmedikçe ekran `finished`te durur.
        do {
            let root: URL = try callCaptureRootDirectory()
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            folder = root.appending(path: ISO8601DateFormatter().string(from: now), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fail(message: String(localized: "Klasör açılamadı: \(error.localizedDescription)"))
            return
        }
        microphoneEnabled = filter.isMicrophoneEnabled
        systemStats = .empty
        microphoneStats = .empty
        rawFiles = []
        let systemLevels: AudioLevels = systemLevels
        let microphoneLevels: AudioLevels = microphoneLevels
        let output: CallStreamOutput = CallStreamOutput(
            directory: folder,
            barInterval: systemLevels.interval,
            onUpdate: { [weak self] (source: CallAudioSource, level: Float, stats: CallSourceStats) -> Void in
                Task { @MainActor in
                    switch source {
                    case .system:
                        systemLevels.record(level: level)
                        self?.systemStats = stats
                    case .microphone:
                        microphoneLevels.record(level: level)
                        self?.microphoneStats = stats
                    }
                }
            },
            onError: { [weak self] (source: CallAudioSource, message: String) -> Void in
                Task { @MainActor in self?.errorMessages.append(String(localized: "\(source.displayName): \(message)")) }
            }
        )
        let delegate: CallStreamDelegate = CallStreamDelegate { [weak self] (code: Int, message: String) -> Void in
            Task { @MainActor in await self?.streamStopped(code: code, message: message) }
        }
        let configuration: SCStreamConfiguration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 1
        // Uygulamanın kendi sesi (ör. oynatıcı) kayda girmez.
        configuration.excludesCurrentProcessAudio = true
        let created: SCStream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
        do {
            try created.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
            if filter.isMicrophoneEnabled {
                try created.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
            }
            try await created.startCapture()
        } catch {
            fail(message: String(localized: "Yakalama başlamadı: \(String(describing: error))"))
            return
        }
        systemLevels.start()
        microphoneLevels.start()
        phase = .capturing(CallCaptureTake(stream: created, output: output, delegate: delegate, directory: folder, startedAt: now))
        Self.logger.info("Görüşme yakalama başladı, mikrofon: \(filter.isMicrophoneEnabled, privacy: .public)")
    }

    /// Sistem akışı durdurdu (ör. kullanıcı durum çubuğundan durdurdu, arka plan modu eksik): kodu görünür, yazılan ses
    /// yine karıştırılır.
    private func streamStopped(code: Int, message: String) async {
        Self.logger.error("Akış durdu, kod: \(code, privacy: .public), hata: \(message, privacy: .public)")
        errorMessages.append(String(localized: "Akış durdu (kod \(code)): \(message)"))
        guard case .capturing(let take) = phase else {
            return
        }
        phase = .finishing(take)
        await finish(take: take)
    }

    private func finish(take: CallCaptureTake) async {
        detachPicker()
        systemLevels.stop()
        microphoneLevels.stop()
        let directory: URL = take.directory
        let stats: [CallAudioSource: CallSourceStats] = await take.output.finish()
        systemStats = stats[.system] ?? .empty
        microphoneStats = stats[.microphone] ?? .empty
        let files: [(url: URL, firstTime: Double?)] = CallAudioSource.allCases.map { (source: CallAudioSource) -> (url: URL, firstTime: Double?) in
            (url: directory.appending(path: source.fileName), firstTime: stats[source]?.firstTime)
        }
        let tracks: [CallTrack] = callTracks(files: files)
        rawFiles = tracks.map(\.url)
        let mixed: URL = directory.appending(path: callMixedFileName(startedAt: take.startedAt, timeZone: .current))
        do {
            try await mixCallAudio(tracks: tracks, destination: mixed)
        } catch {
            fail(message: String(localized: "Karıştırılamadı: \(String(describing: error))"))
            return
        }
        rawFiles.append(mixed)
        phase = .finished(mixed: mixed)
    }

    private func fail(message: String) {
        Self.logger.error("Görüşme yakalama hatası: \(message, privacy: .public)")
        errorMessages.append(message)
        detachPicker()
        systemLevels.stop()
        microphoneLevels.stop()
        phase = .idle
    }
}

/// Seçicinin verdiği süzgeç, ana aktöre geçmek için kutuda. `SCContentFilter` Sendable işaretli değil; seçiciden
/// sonra yalnız okunur (değiştirilmez) ve ana aktörde akışa verilir, bu yüzden güvenle taşınır.
@available(iOS 27.0, *)
struct CallFilterBox: @unchecked Sendable {
    let filter: SCContentFilter
}

/// Sistem seçicisinin gözlemcisi: sonuçları kapanışlara iletir (hangi iş parçacığında çağrıldığı belgelenmemiş).
@available(iOS 27.0, *)
final class CallPickerObserver: NSObject, SCContentSharingPickerObserver, Sendable {
    private let onSelect: @Sendable (CallFilterBox) -> Void
    private let onCancel: @Sendable () -> Void
    private let onFail: @Sendable (String) -> Void

    init(onSelect: @escaping @Sendable (CallFilterBox) -> Void, onCancel: @escaping @Sendable () -> Void, onFail: @escaping @Sendable (String) -> Void) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onFail = onFail
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        onCancel()
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        onSelect(CallFilterBox(filter: filter))
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        onFail(String(describing: error))
    }
}

/// Akış temsilcisi: sistemin durdurmasını (hata koduyla) iletir.
@available(iOS 27.0, *)
final class CallStreamDelegate: NSObject, SCStreamDelegate, Sendable {
    private let onStop: @Sendable (Int, String) -> Void

    init(onStop: @escaping @Sendable (Int, String) -> Void) {
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop((error as NSError).code, String(describing: error))
    }
}

/// Akışın ses çıkışı: her kaynağı kendi dosyasına yazar, seviyeyi seyrelterek bildirir.
///
/// `@unchecked Sendable`: dosya yazıcıları ve hata kümesi yalnız `queue` üzerinde kullanılır (SCStream örnekleri bu
/// kuyrukta verir; `finish` de bu kuyruğa geçer).
@available(iOS 27.0, *)
final class CallStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.callcapture")
    private let sinks: [CallAudioSource: CallAudioFileSink]
    private let throttles: [CallAudioSource: LevelThrottle]
    private let onUpdate: @Sendable (CallAudioSource, Float, CallSourceStats) -> Void
    private let onError: @Sendable (CallAudioSource, String) -> Void
    /// Yazılamayan kaynak durur (biçim değişti, disk doldu…); hatası bir kez bildirilir.
    private var failed: Set<CallAudioSource> = []

    init(
        directory: URL, barInterval: Double, onUpdate: @escaping @Sendable (CallAudioSource, Float, CallSourceStats) -> Void,
        onError: @escaping @Sendable (CallAudioSource, String) -> Void
    ) {
        var sinks: [CallAudioSource: CallAudioFileSink] = [:]
        var throttles: [CallAudioSource: LevelThrottle] = [:]
        for source in CallAudioSource.allCases {
            sinks[source] = CallAudioFileSink(source: source, url: directory.appending(path: source.fileName))
            throttles[source] = LevelThrottle(intervalSec: levelThrottleInterval(barInterval: barInterval))
        }
        self.sinks = sinks
        self.throttles = throttles
        self.onUpdate = onUpdate
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let source: CallAudioSource
        switch type {
        case .audio:
            source = .system
        case .microphone:
            source = .microphone
        default:
            return
        }
        guard !failed.contains(source), let sink = sinks[source], let throttle = throttles[source] else {
            return
        }
        do {
            let level: Float = try sink.append(sampleBuffer: sampleBuffer)
            if let peak = throttle.add(level: level) {
                onUpdate(source, peak, sink.stats)
            }
        } catch {
            failed.insert(source)
            onError(source, String(describing: error))
        }
    }

    /// Dosyaları kapatır, son sayaçları döndürür (akış durduktan sonra çağrılır).
    func finish() async -> [CallAudioSource: CallSourceStats] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CallAudioSource: CallSourceStats], Never>) -> Void in
            queue.async {
                var stats: [CallAudioSource: CallSourceStats] = [:]
                for (source, sink) in self.sinks {
                    sink.close()
                    stats[source] = sink.stats
                }
                continuation.resume(returning: stats)
            }
        }
    }
}
#endif
