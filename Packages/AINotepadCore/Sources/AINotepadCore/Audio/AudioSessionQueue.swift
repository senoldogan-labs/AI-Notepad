#if os(iOS)
import AVFoundation
import Foundation

/// iPhone ses oturumu (`AVAudioSession`) çağrıları için tek seri kuyruk.
///
/// `setCategory` ve `setActive` sistem ses servisine XPC ile gider ve cevap gelene dek çağıranı bekletir; ana iş
/// parçacığından yapılınca arayüz bir saniyeye kadar donar (0.1.12 (22) TestFlight'ta MetricKit takılma raporu: kayıt
/// başlarken ana iş parçacığı `AudioSession` içinde 1 sn bekledi). Bütün oturum değişiklikleri bu kuyrukta, verildikleri
/// sırayla çalışır: hemen ardından gelen "kapat" ve "aç" yer değiştirmez.
public enum AudioSessionQueue {
    private static let queue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.audioSession", qos: .userInitiated)

    /// `body`'yi oturum kuyruğunda çalıştırır ve bitmesini (ya da hatasını) bekler. İş, çağrı anında kuyruğa girer.
    public static func perform(_ body: @escaping @Sendable (AVAudioSession) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) -> Void in
            queue.async {
                do {
                    try body(AVAudioSession.sharedInstance())
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// `body`'yi oturum kuyruğuna bekletmeden ekler (durdururken: çağıran beklemez); hata `onError`'a gider.
    public static func enqueue(
        _ body: @escaping @Sendable (AVAudioSession) throws -> Void,
        onError: @escaping @Sendable (any Error) -> Void
    ) {
        queue.async {
            do {
                try body(AVAudioSession.sharedInstance())
            } catch {
                onError(error)
            }
        }
    }
}
#endif
