// Ekran görüntüsü (ScreenCaptureKit) yalnızca macOS'ta; iPhone başka uygulamaların ekranını yakalayamaz.
#if os(macOS)
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Synchronization
import os

private let screenLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ScreenSnapshots")

/// Ekran görüntüsü alma hataları.
public enum ScreenCaptureError: Error, Equatable, Sendable {
    /// Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı'nda izin yok.
    case permissionDenied
    /// Görüntüsü alınacak ekran bulunamadı.
    case noDisplay
    /// ScreenCaptureKit görüntüyü veremedi (ardışık denemelerden sonuncusunun nedeni).
    case captureFailed(reason: String)
    /// Görüntü işlenemedi ya da toplantının klasörüne yazılamadı.
    case storeFailed(reason: String)
}

/// Kayıt sırasında görüntü almanın olayları (ana iş parçacığında bildirilir).
public enum ScreenSnapshotEvent: Sendable, Equatable {
    /// Yeni görüntü toplantının klasörüne yazıldı.
    case stored(ScreenSnapshot)
    /// Toplantının sınırı doldu; bu kayıtta başka görüntü alınmaz.
    case capReached
    /// Görüntü alma durdu (izin yok ya da art arda başarısız oldu).
    case stopped(ScreenCaptureError)
}

/// Ekran Kaydı izni var mı (sistem penceresi açmaz).
public func hasScreenCapturePermission() -> Bool {
    CGPreflightScreenCaptureAccess()
}

/// Ekran Kaydı iznini ister: ilk istekte macOS kendi izin penceresini açar; daha önce reddedildiyse açmaz ve false döner
/// (izin Sistem Ayarları'ndan verilir, uygulama yeniden açılınca geçerli olur).
public func requestScreenCapturePermission() -> Bool {
    CGRequestScreenCaptureAccess()
}

/// Art arda bu kadar bakış başarısız olursa görüntü alma durur (ör. ekran kilitli kaldı, ScreenCaptureKit bozuldu).
private let maxConsecutiveFailures: Int = 5

/// Kayıt boyunca belli aralıkla ekrana bakar, anlamlı değişince görüntüyü toplantının klasörüne yazar. Bakış ve
/// karşılaştırma arka planda (düşük öncelikte) yapılır; görüşme penceresi bulunursa yalnızca o, yoksa ana ekran alınır.
/// Uygulamanın kendi pencereleri hiçbir zaman görüntüye girmez.
@MainActor
public final class ScreenSnapshotRecorder {
    private var task: Task<Void, Never>?
    /// Bu çalıştırmanın durumu (çalışıyor, duraklatıldı, durdu); bakış döngüsüyle paylaşılır.
    private var run: ScreenCaptureRun?

    public init() {}

    /// Görüntü almayı başlatır. `timeline`: kaydedilen sesin zaman çizgisi (görüntüler transkriptle aynı saniyeleri taşır;
    /// duraklatılan süre düşülür).
    /// İzin yoksa `permissionDenied`; zaten çalışıyorsa önce durdurulur.
    public func start(
        meetingDirectory: URL, timeline: RecordingPauseGate, policy: ScreenSnapshotPolicy, onEvent: @escaping @MainActor @Sendable (ScreenSnapshotEvent) -> Void
    ) throws(ScreenCaptureError) {
        stop()
        guard hasScreenCapturePermission() else {
            throw ScreenCaptureError.permissionDenied
        }
        let existing: Int
        do {
            existing = try listScreenSnapshots(meetingDirectory: meetingDirectory).filter { $0.kind == .screen }.count
        } catch {
            throw ScreenCaptureError.storeFailed(reason: String(describing: error))
        }
        let run: ScreenCaptureRun = ScreenCaptureRun()
        self.run = run
        task = Task.detached(priority: .utility) {
            await runSnapshotLoop(meetingDirectory: meetingDirectory, timeline: timeline, policy: policy, existing: existing, run: run, onEvent: onEvent)
        }
        screenLogger.info("Ekran görüntüsü alma başladı, klasör: \(meetingDirectory.lastPathComponent, privacy: .public)")
    }

    /// Duraklatılınca bakılmaz; sürdürülünce ekranın yeniden durulması beklenir.
    public func setPaused(_ isPaused: Bool) {
        run?.apply(event: isPaused ? .pause : .resume)
    }

    /// Görüntü almayı bitirir; o an alınmakta olan görüntü yazılmaz. İkinci kez çağrılması zararsızdır.
    public func stop() {
        guard let task else {
            return
        }
        // Önce durum "durdu" olur: süren bir yazım bitene dek beklenir, sonra hiçbir görüntü yazılmaz.
        run?.apply(event: .stop)
        run = nil
        task.cancel()
        self.task = nil
        screenLogger.info("Ekran görüntüsü alma durdu")
    }
}

/// Bir görüntü alma çalıştırmasının paylaşılan durumu (ana iş parçacığı geçirir, bakış döngüsü okur). Görüntü
/// `writeIfRunning` içinde, durumla aynı kilidin altında yazılır: `stop()` döndükten sonra hiçbir görüntü yazılmaz
/// (toplantı klasörü silinmiş olabilir; yazmak Screens klasörünü yeniden kurardı).
private final class ScreenCaptureRun: Sendable {
    private let state: Mutex<ScreenCaptureRunState> = Mutex(.running)

    func apply(event: ScreenCaptureRunEvent) {
        state.withLock { $0 = screenCaptureRunTransition(state: $0, event: event) }
    }

    var current: ScreenCaptureRunState {
        state.withLock { $0 }
    }

    /// Çalışıyorsa `write`'ı kilit altında çalıştırır ve true döner; duraklatılmış ya da durmuşsa yazmaz, false döner.
    func writeIfRunning(_ write: () throws -> Void) throws -> Bool {
        try state.withLock { (value: inout ScreenCaptureRunState) throws -> Bool in
            guard value == .running else {
                return false
            }
            try write()
            return true
        }
    }
}

/// Bakış döngüsü: iptal edilene, sınır dolana ya da art arda başarısız olana dek.
private func runSnapshotLoop(
    meetingDirectory: URL, timeline: RecordingPauseGate, policy: ScreenSnapshotPolicy, existing: Int, run: ScreenCaptureRun,
    onEvent: @escaping @MainActor @Sendable (ScreenSnapshotEvent) -> Void
) async {
    var state: ScreenSnapshotState = initialScreenSnapshotState(storedCount: existing)
    var failures: Int = 0
    while !Task.isCancelled {
        do {
            try await Task.sleep(for: .seconds(policy.captureIntervalSec))
        } catch {
            return
        }
        guard run.current == .running else {
            // Duraklatma boyunca ekran değişmiş olabilir: sürdürünce önce durulması beklenir.
            state = pausedScreenSnapshotState(state: state)
            continue
        }
        do {
            let image: CGImage = try await captureScreenImage(maxPixelSize: policy.maxPixelSize)
            // Bakış sürerken kayıt bitti ya da duraklatıldı: görüntü yazılmaz (bitince toplantı klasörü silinmiş olabilir;
            // yazmak Screens klasörünü yeniden kurardı). Duraklatmada sürdürünce ekranın yeniden durulması beklenir.
            switch run.current {
            case .stopped:
                return
            case .paused:
                state = pausedScreenSnapshotState(state: state)
                continue
            case .running:
                break
            }
            let offsetSec: Double = timeline.keptSeconds(at: .now)
            let fingerprint: ScreenFingerprint = try screenFingerprint(image: image)
            let decision: ScreenSnapshotDecision = screenSnapshotDecision(policy: policy, state: state, candidate: fingerprint, offsetSec: offsetSec)
            failures = 0
            switch decision {
            case .store:
                let snapshot: ScreenSnapshot = screenSnapshot(offsetSec: offsetSec)
                let jpeg: Data = try jpegData(image: image, quality: policy.jpegQuality)
                // Kodlama sürerken durdurulduysa ya da duraklatıldıysa yazılmaz (bkz. `ScreenCaptureRun`).
                guard try run.writeIfRunning({ () throws -> Void in
                    try writeScreenSnapshot(meetingDirectory: meetingDirectory, snapshot: snapshot, jpeg: jpeg)
                }) else {
                    continue
                }
                state = advancedScreenSnapshotState(policy: policy, state: state, candidate: fingerprint, offsetSec: offsetSec, stored: true)
                await onEvent(.stored(snapshot))
            case .capReached:
                screenLogger.info("Toplantının ekran görüntüsü sınırı doldu, sınır: \(policy.maxPerMeeting, privacy: .public)")
                await onEvent(.capReached)
                return
            case .unchanged, .unsettled, .moving, .tooSoon:
                state = advancedScreenSnapshotState(policy: policy, state: state, candidate: fingerprint, offsetSec: offsetSec, stored: false)
            }
        } catch {
            if Task.isCancelled {
                return
            }
            failures += 1
            let failure: ScreenCaptureError = screenCaptureError(error: error)
            screenLogger.warning("Ekran görüntüsü alınamadı, deneme: \(failures, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            if failure == .permissionDenied || failures >= maxConsecutiveFailures {
                await onEvent(.stopped(failure))
                return
            }
        }
    }
}

/// Bakışın hatası: izin hataları `permissionDenied`, disk ve kodlama hataları `storeFailed`, diğerleri `captureFailed`.
private func screenCaptureError(error: any Error) -> ScreenCaptureError {
    switch error {
    case let error as ScreenCaptureError:
        return error
    case let error as StorageError:
        return .storeFailed(reason: String(describing: error))
    case let error as ScreenImageError:
        return .storeFailed(reason: String(describing: error))
    case let error as SCStreamError where error.code == .userDeclined:
        return .permissionDenied
    default:
        return hasScreenCapturePermission() ? .captureFailed(reason: String(describing: error)) : .permissionDenied
    }
}

/// Ekranın şu anki görüntüsü: görüşme penceresi varsa yalnızca o (üstündeki pencereler girmez), yoksa uygulamanın kendi
/// pencereleri hariç ana ekran. Uzun kenar en fazla `maxPixelSize`; imleç çizilmez.
private func captureScreenImage(maxPixelSize: Int) async throws -> CGImage {
    let content: SCShareableContent = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    let candidates: [SCWindow] = content.windows.filter { $0.owningApplication?.processID != ownPID }
    let infos: [ScreenWindowInfo] = candidates.map { (window: SCWindow) -> ScreenWindowInfo in
        ScreenWindowInfo(
            windowID: window.windowID, bundleID: window.owningApplication?.bundleIdentifier ?? "", title: window.title ?? "",
            width: window.frame.width, height: window.frame.height, layer: window.windowLayer, isOnScreen: window.isOnScreen
        )
    }
    let filter: SCContentFilter
    if let chosen = meetingWindow(windows: infos), let window = candidates.first(where: { $0.windowID == chosen.windowID }) {
        filter = SCContentFilter(desktopIndependentWindow: window)
    } else {
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ScreenCaptureError.noDisplay
        }
        let ownApps: [SCRunningApplication] = content.applications.filter { $0.processID == ownPID }
        filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
    }
    let size: (width: Int, height: Int) = screenCaptureSize(
        width: filter.contentRect.width * Double(filter.pointPixelScale), height: filter.contentRect.height * Double(filter.pointPixelScale),
        maxPixelSize: maxPixelSize
    )
    let configuration: SCStreamConfiguration = SCStreamConfiguration()
    configuration.width = size.width
    configuration.height = size.height
    configuration.showsCursor = false
    configuration.capturesAudio = false
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
}
#endif
