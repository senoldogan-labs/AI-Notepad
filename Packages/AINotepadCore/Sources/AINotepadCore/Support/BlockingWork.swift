import Foundation

/// Engelleyen eşzamanlı işi (dosya koordinasyonu, iCloud kapsayıcısı, Keychain, sistem günlüğü, çoklu dosya okuma)
/// Swift eşzamanlılık havuzunun dışında, GCD'nin genel kuyruğunda çalıştırır ve sonucunu bekler.
///
/// `Task.detached` arka plan iş parçacığı vermez: iş, çekirdek sayısı kadar iş parçacığı olan ortak havuzda çalışır ve
/// beklediği sürece (Keychain izin penceresi, iCloud indirmesi, `NSFileCoordinator`) o iş parçacığını tutar. Havuz
/// dolunca uygulamanın bütün görevleri (zamanlayıcılar, Deepgram bağlantısı, ses akışı) bekler. GCD ise engellenen iş
/// parçacığının yerine yenisini açar. İşin hatası çağırana olduğu gibi iletilir.
public func runBlocking<Value: Sendable, Failure: Error>(
    qos: DispatchQoS.QoSClass, operation: @escaping @Sendable () throws(Failure) -> Value
) async throws(Failure) -> Value {
    let result: Result<Value, Failure> = await withCheckedContinuation { (continuation: CheckedContinuation<Result<Value, Failure>, Never>) -> Void in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(returning: Result { () throws(Failure) -> Value in try operation() })
        }
    }
    return try result.get()
}
