import AINotepadCore
import Foundation
import MediaPlayer
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let nowPlayingLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "NowPlaying")

/// Sistem çalma denetimlerinin (kilit ekranı, Denetim Merkezi, AirPods, Mac'te medya tuşları) ileri/geri sarma adımı
/// (saniye).
let remoteSkipInterval: Double = 15

/// Sistemin "Şimdi Çalınan" alanında gösterilen çalma durumu.
struct NowPlayingSnapshot: Equatable, Sendable {
    let title: String
    /// Başlığın altındaki satır: toplantının tarihi.
    let artist: String
    /// Uygulamanın adı (ör. "Gistsmith"); okunamazsa nil (alan gösterilmez).
    let album: String?
    let duration: Double
    let elapsed: Double
    /// Şu anki çalma hızı: duraklatılmışken 0 (sistem konumu bu hızla kendisi ilerletir).
    let playbackRate: Double
    /// Seçili hız (çalarken ve duraklatılmışken aynı).
    let defaultPlaybackRate: Double
    let isPlaying: Bool
}

/// Çalan toplantının sistemde görünen başlığı: notun başlığı, not yoksa toplantının adı. Saf fonksiyondur.
func meetingPlaybackTitle(record: MeetingRecord) -> String {
    record.note?.title ?? record.title
}

/// Çalarin durumundan sistemin "Şimdi Çalınan" bilgisini kurar; konum süreyle sınırlanır. Saf fonksiyondur.
func nowPlayingSnapshot(
    title: String, dateText: String, appName: String?, duration: Double, elapsed: Double, rate: Float, isPlaying: Bool
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        title: title, artist: dateText, album: appName, duration: duration, elapsed: min(max(0, elapsed), duration),
        playbackRate: isPlaying ? Double(rate) : 0, defaultPlaybackRate: Double(rate), isPlaying: isPlaying
    )
}

/// Sistem çalma denetimlerinden gelen komutların çalardaki karşılıkları. Hepsi ana iş parçacığında çağrılır.
struct RemoteCommandActions {
    let play: @MainActor () -> MPRemoteCommandHandlerStatus
    let pause: @MainActor () -> MPRemoteCommandHandlerStatus
    let togglePlayPause: @MainActor () -> MPRemoteCommandHandlerStatus
    let skip: @MainActor (Double) -> MPRemoteCommandHandlerStatus
    let seek: @MainActor (Double) -> MPRemoteCommandHandlerStatus
}

/// `MPNowPlayingInfoCenter` ve `MPRemoteCommandCenter` bağdaştırıcısı: çalınan toplantıyı sistemde gösterir ve sistem
/// denetimlerini çalara bağlar. Uygulamanın tek çaları tarafından, yalnız çalarken (kayıt sırasında çalma yok) kullanılır.
@MainActor
final class NowPlayingCenter {
    /// Komutlar ve `addTarget`'ın döndürdüğü belirteçler (sistem API'si belirteci `Any` olarak verir, `removeTarget`
    /// aynısını ister).
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var cachedArtwork: MPMediaItemArtwork?

    /// Sistem denetimlerini çalara bağlar (önceki bağ bırakılır); sonraki/önceki parça yok, kapalıdır.
    func attach(actions: RemoteCommandActions) {
        detach()
        let center: MPRemoteCommandCenter = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: remoteSkipInterval)]
        // İşleyiciler sistemin seçtiği iş parçacığında çağrılabilir: kapanışlar ana aktöre bağlı değildir (Swift 6'da
        // ana aktörde kurulan kapanış başka iş parçacığında çağrılınca uygulama çöker); iş ana iş parçacığına geçer.
        commandTargets = [
            (center.playCommand, simpleTarget(command: center.playCommand, action: actions.play)),
            (center.pauseCommand, simpleTarget(command: center.pauseCommand, action: actions.pause)),
            (center.togglePlayPauseCommand, simpleTarget(command: center.togglePlayPauseCommand, action: actions.togglePlayPause)),
            (center.skipForwardCommand, skipTarget(command: center.skipForwardCommand, sign: 1, action: actions.skip)),
            (center.skipBackwardCommand, skipTarget(command: center.skipBackwardCommand, sign: -1, action: actions.skip)),
            (center.changePlaybackPositionCommand, seekTarget(command: center.changePlaybackPositionCommand, action: actions.seek)),
        ]
        commandTargets.forEach { $0.0.isEnabled = true }
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    /// Sistem denetimlerinin çalarla bağını koparır (çalma bitince).
    func detach() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        commandTargets = []
    }

    /// Çalma durumunu sistemde gösterir.
    func publish(snapshot: NowPlayingSnapshot) {
        // `nowPlayingInfo` sistem sözleşmesi gereği `[String: Any]`tır; değerler aşağıda türleriyle yazılır.
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyPlaybackDuration: NSNumber(value: snapshot.duration),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: NSNumber(value: snapshot.elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: NSNumber(value: snapshot.playbackRate),
            MPNowPlayingInfoPropertyDefaultPlaybackRate: NSNumber(value: snapshot.defaultPlaybackRate),
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue),
        ]
        if let album = snapshot.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork = artwork() {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        let center: MPNowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // Mac'te Denetim Merkezi ve medya tuşları durumu buradan okur (iPhone ses oturumundan çıkarır).
        center.playbackState = snapshot.isPlaying ? .playing : .paused
    }

    /// "Şimdi Çalınan"ı temizler (çalma bitince).
    func clear() {
        let center: MPNowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    /// Uygulamanın adı (Info.plist'teki görünen ad); yoksa nil.
    func appName() -> String? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String else {
            nowPlayingLogger.error("CFBundleDisplayName okunamadı; Şimdi Çalınan'da uygulama adı gösterilmeyecek")
            return nil
        }
        return name
    }

    /// Kapak görseli: uygulama simgesi (bir kez okunur).
    private func artwork() -> MPMediaItemArtwork? {
        if let cachedArtwork {
            return cachedArtwork
        }
        guard let image = appIconImage() else {
            nowPlayingLogger.error("Uygulama simgesi okunamadı; Şimdi Çalınan kapaksız gösterilecek")
            return nil
        }
        // Görsel isteği sistemin iş parçacığında gelir: kapanış ana aktöre bağlı olmamalı.
        let artwork: MPMediaItemArtwork = MPMediaItemArtwork(boundsSize: image.size) { @Sendable (_: CGSize) in image }
        cachedArtwork = artwork
        return artwork
    }

    #if os(macOS)
    private func appIconImage() -> NSImage? {
        NSApplication.shared.applicationIconImage
    }
    #else
    /// Derlenmiş simge dosyasının adı Info.plist'teki `CFBundleIcons`'ta yazar (simge kataloğu `UIImage(named:)` ile
    /// "AppIcon" adıyla açılmaz).
    private func appIconImage() -> UIImage? {
        let icons: [String: NSObject]? = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: NSObject]
        let primary: [String: NSObject]? = icons?["CFBundlePrimaryIcon"] as? [String: NSObject]
        let files: [String]? = primary?["CFBundleIconFiles"] as? [String]
        return files?.last.flatMap { (name: String) -> UIImage? in UIImage(named: name) }
    }
    #endif
}

/// Parametresiz komutun işleyicisi.
private func simpleTarget(command: MPRemoteCommand, action: @escaping @MainActor () -> MPRemoteCommandHandlerStatus) -> Any {
    command.addTarget { @Sendable (_: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
        onMain { action() }
    }
}

/// İleri/geri sarma: olayın adımı (`sign` yönüyle) çalara gider.
private func skipTarget(command: MPRemoteCommand, sign: Double, action: @escaping @MainActor (Double) -> MPRemoteCommandHandlerStatus) -> Any {
    command.addTarget { @Sendable (event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
        guard let skipEvent = event as? MPSkipIntervalCommandEvent else {
            nowPlayingLogger.error("Sarma komutu beklenmeyen olayla geldi, tür: \(String(describing: type(of: event)), privacy: .public)")
            return .commandFailed
        }
        let seconds: Double = sign * skipEvent.interval
        return onMain { action(seconds) }
    }
}

/// Konum çubuğundan konuma gitme.
private func seekTarget(command: MPRemoteCommand, action: @escaping @MainActor (Double) -> MPRemoteCommandHandlerStatus) -> Any {
    command.addTarget { @Sendable (event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus in
        guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
            nowPlayingLogger.error("Konum komutu beklenmeyen olayla geldi, tür: \(String(describing: type(of: event)), privacy: .public)")
            return .commandFailed
        }
        let position: Double = positionEvent.positionTime
        return onMain { action(position) }
    }
}

/// İşi ana iş parçacığında çalıştırır: zaten oradaysa hemen (sonucu döner), değilse sıraya koyup başarı döner.
private func onMain(_ body: @escaping @MainActor () -> MPRemoteCommandHandlerStatus) -> MPRemoteCommandHandlerStatus {
    if Thread.isMainThread {
        return MainActor.assumeIsolated { body() }
    }
    DispatchQueue.main.async {
        _ = body()
    }
    return .success
}
