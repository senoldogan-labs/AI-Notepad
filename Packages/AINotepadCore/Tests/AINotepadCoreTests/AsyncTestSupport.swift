import Foundation
import os
@testable import AINotepadCore

// Zamana bağlı testlerin ortak araçları: adımlar duvar saati yerine olaylarla sıralanır, ağır işler eşzamanlılık
// havuzunu tutmaz. Yüklü CI'da (3 çekirdek, yüzlerce test paralel) havuzun birkaç iş parçacığı ağır eşzamanlı testlerle
// dolunca zamanlayıcılar ve devamlar saniyelerce bekliyordu (0,2 sn'lik zamanlayıcı 21,5 sn sürdü).

/// Testlerde askıda kalmayı yakalama sınırı: beklenen olay kapı ya da sinyalle sıralanır, bu süre yalnızca beklenen şey hiç
/// olmazsa testin sonsuza dek beklemesini önler. Yüklü CI makinesinde (785 test paralel, 3 çekirdek) tek test 15 sn
/// donabildiği için geniş tutulur; doğru davranışta hiçbir zaman dolmaz.
let hangDetectionLimit: Duration = .seconds(60)

/// Bir kez açılan kapı: testte adımları süre yerine olaylarla sıralamak için. Bekleme iptal edilirse hemen biter.
final class TestGate: Sendable {
    private let state: OSAllocatedUnfairLock<TestGateState> = OSAllocatedUnfairLock(initialState: TestGateState(isOpen: false, waiters: [:], cancelled: []))

    var isOpen: Bool {
        state.withLock { (state: inout TestGateState) -> Bool in state.isOpen }
    }

    /// Kapıyı açar; bekleyenler ve sonraki beklemeler hemen sürer.
    func open() {
        let waiters: [CheckedContinuation<Void, Never>] = state.withLock { (state: inout TestGateState) -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let waiting: [CheckedContinuation<Void, Never>] = Array(state.waiters.values)
            state.waiters = [:]
            return waiting
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Kapı açılana (ya da görev iptal edilene) dek bekler.
    func wait() async {
        let id: UUID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) -> Void in
                let resumeNow: Bool = state.withLock { (state: inout TestGateState) -> Bool in
                    if state.isOpen || state.cancelled.contains(id) {
                        return true
                    }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow {
                    continuation.resume()
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Never>? = state.withLock { (state: inout TestGateState) -> CheckedContinuation<Void, Never>? in
                guard let waiting = state.waiters.removeValue(forKey: id) else {
                    // İptal beklemeye girmeden geldi: bekleme hiç askıya alınmadan biter.
                    state.cancelled.insert(id)
                    return nil
                }
                return waiting
            }
            waiter?.resume()
        }
    }
}

/// `TestGate`'in durumu.
struct TestGateState: Sendable {
    var isOpen: Bool
    var waiters: [UUID: CheckedContinuation<Void, Never>]
    var cancelled: Set<UUID>
}

/// `operation` `limit` dolmadan biterse true; dolarsa `operation` iptal edilir ve false döner (askıda kalmayı yakalamak
/// için; `operation` iptale yanıt vermelidir, ör. `AsyncStream` tüketimi ya da `TestGate.wait`).
func completes(within limit: Duration, operation: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { (group: inout TaskGroup<Bool>) -> Bool in
        group.addTask {
            await operation()
            return true
        }
        group.addTask {
            do {
                try await Task.sleep(for: limit)
            } catch {
                // Uyku yalnızca iptalde fırlatır: `operation` önce bitti, sonuç zaten alındı.
                return true
            }
            return false
        }
        let first: Bool = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// Ağır eşzamanlı test işini (binlerce kare benzetimi, yüz binlerce örnek, yüzlerce dosya) eşzamanlılık havuzunun dışında
/// çalıştırır: havuzu tutmasın, aynı anda koşan testlerin zamanlayıcıları ve devamları beklemesin. `#expect` çağıranın
/// görevinde yapılmalıdır (test bağlamı GCD iş parçacığına geçmez); iş yalnızca değer döndürür.
func offCooperativePool<Value: Sendable, Failure: Error>(work: @escaping @Sendable () throws(Failure) -> Value) async throws(Failure) -> Value {
    try await runBlocking(qos: .userInitiated, operation: work)
}
