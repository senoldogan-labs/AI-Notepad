import Foundation
import Network
import os
import Synchronization

/// Ağ yolunu izleyen bağdaştırıcı (`NWPathMonitor`): şu an bağlantı var mı ve bağlantı kaç kez koptu. Toplantı
/// işlenirken bağlantı koptuysa başarısız not yeniden denenir; denemeden önce bağlantı beklenir (bkz.
/// `PhoneRecorder.process`). Thread-safe.
final class NetworkPathWatch: Sendable {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "NetworkPathWatch")

    private struct State {
        var isSatisfied: Bool
        var lossCount: Int
    }

    private let monitor: NWPathMonitor = NWPathMonitor()
    private let state: Mutex<State> = Mutex(State(isSatisfied: true, lossCount: 0))

    init() {
        monitor.pathUpdateHandler = { [weak self] (path: NWPath) -> Void in
            guard let self else {
                return
            }
            let satisfied: Bool = path.status == .satisfied
            let changed: Bool = self.state.withLock { (current: inout State) -> Bool in
                guard current.isSatisfied != satisfied else {
                    return false
                }
                current.isSatisfied = satisfied
                if !satisfied {
                    current.lossCount += 1
                }
                return true
            }
            if changed {
                Self.logger.info("Ağ yolu değişti, bağlı: \(satisfied, privacy: .public)")
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.senoldogan.AINotepad.networkPath", qos: .utility))
    }

    deinit {
        monitor.cancel()
    }

    /// Şu an kullanılabilir bir ağ yolu var mı.
    var isSatisfied: Bool {
        state.withLock { (current: inout State) -> Bool in current.isSatisfied }
    }

    /// İzleme başladığından beri bağlantının kaç kez koptuğu (artışı "işleme sırasında koptu" demektir).
    var lossCount: Int {
        state.withLock { (current: inout State) -> Int in current.lossCount }
    }

    /// Bağlantı gelene dek (en çok `limitSec`) saniyede bir bakar. Bağlantı geldiyse true, süre dolduysa false; görev
    /// iptal edilirse `CancellationError`.
    func waitUntilSatisfied(limitSec: Int) async throws -> Bool {
        for _ in 0..<limitSec {
            if isSatisfied {
                return true
            }
            try await Task.sleep(for: .seconds(1))
        }
        return isSatisfied
    }
}
