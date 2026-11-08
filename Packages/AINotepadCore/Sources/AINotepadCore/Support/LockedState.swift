import os

/// Bir değeri kilitle koruyan kutu: `Synchronization.Mutex`'in işini görür, ama o macOS 15 ister ve Mac uygulaması
/// macOS 14.2'de de çalışır. İçeride `OSAllocatedUnfairLock` (macOS 13+, iOS 16+) vardır; `withLock` aynı biçimde
/// kullanılır. Kilit yeniden girilemez: gövde aynı kutunun `withLock`'unu çağırmamalı. Thread-safe.
public final class LockedState<Value: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    public init(_ initial: Value) {
        lock = OSAllocatedUnfairLock(uncheckedState: initial)
    }

    /// Kilidi tutarken değeri gövdeye verir; gövdenin döndürdüğünü döndürür.
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLockUnchecked(body)
    }
}
