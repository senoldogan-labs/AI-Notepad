import Foundation
import Network
import os
import Testing
@testable import AINotepadCore

/// Testlerde askıda kalmayı yakalama sınırı: beklenen olay kapı ya da sinyalle sıralanır, bu süre yalnızca beklenen şey hiç
/// olmazsa testin sonsuza dek beklemesini önler. Yüklü CI makinesinde (785 test paralel, 3 çekirdek) tek test 15 sn
/// donabildiği için geniş tutulur; doğru davranışta hiçbir zaman dolmaz.
let hangDetectionLimit: Duration = .seconds(60)

/// Süre sınırlarının çarpanı: paylaşılan CI makineleri (GitHub `CI=true` verir) geliştirme Mac'inden belirgin yavaştır;
/// orada sınır iki katıdır, yerelde aynı sıkı sınır geriye gidişi yakalar.
private let performanceLimitScale: Double = ProcessInfo.processInfo.environment["CI"] == "true" ? 2 : 1

@Suite struct DeepgramShutdownTests {
    // Jeton kapanış süresi (5 sn) dolduktan sonra gelirse geçersiz kılınmış oturumda WebSocket açılmaz (önceden
    // `NSGenericException` ile çöküyordu); akış ağa gitmeden sessizce biter. Jeton süreyle değil kapıyla geciktirilir:
    // önceden 6,5 sn uyuyordu ve yüklü CI'da kapanış zamanlayıcısı 1,5 sn'den fazla geç çalışınca jeton süre dolmadan
    // geliyor, gerçek Deepgram'a sahte jetonla bağlanılıyor ve 401 reddi (doğru olarak) `.failed` diye bildiriliyordu.
    @Test func lateTokenAfterCloseDoesNotOpenSocket() async throws {
        let audio: AsyncStream<[Float]> = chunkedStream(samples: [], chunkSize: 1)
        let release: TestGate = TestGate()
        let tokenReturned: TestGate = TestGate()
        let stream: DeepgramStream = startDeepgramStream(
            token: { () async throws -> String in
                await release.wait()
                tokenReturned.open()
                return "gec-gelen-jeton"
            },
            options: developerDeepgramListenOptions, language: .finnish, keyterms: [], onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in }, audio: audio
        )
        var failures: [String] = []
        for await event in stream.events {
            if case .failed(let message) = event {
                failures.append(message)
            }
        }
        #expect(failures.isEmpty)
        // Akış kapanış süresinde bitti (oturum geçersiz); jeton ancak şimdi gelir ve bağlanma denenir.
        release.open()
        #expect(await completes(within: hangDetectionLimit) { await tokenReturned.wait() })
        // Bağlanma denemesi jetondan hemen sonra aynı aktörde yapılır: süreç o ana dek yaşamalı (çökme süreci bitirir).
        try await Task.sleep(for: .seconds(1))
        #expect(!canOpenConnection(sessionInvalidated: true, closeDeadlinePassed: false, hasFailed: false))
        #expect(canOpenConnection(sessionInvalidated: false, closeDeadlinePassed: false, hasFailed: false))
    }

    // Kısa ağ kesintisinde jeton alınamazsa bağlanma bütçesi içinde yeniden denenir (Mac'e hemen geçilmez); sunucunun
    // bilerek verdiği ret (ör. Deepgram bütçesi doldu) hemen bildirilir. Ses akışı üçüncü jeton isteğinden sonra biter:
    // önceden 4 sn sonra bitiyordu ve yüklü makinede denemeler kapanış süresinden (5 sn) sonraya kalabilirdi.
    @Test func transientTokenFailuresAreRetried() async throws {
        let calls: Counter = Counter()
        let rejected: TestGate = TestGate()
        let audio: AsyncStream<[Float]> = AsyncStream { (continuation: AsyncStream<[Float]>.Continuation) -> Void in
            Task {
                await rejected.wait()
                continuation.finish()
            }
        }
        let rejection: HostedAPIError = HostedAPIError(code: .rateLimited, rawCode: "rate_limited", status: 429, serverMessage: "", path: "/v1/live/deepgram-token")
        let stream: DeepgramStream = startDeepgramStream(
            token: { () async throws -> String in
                let call: Int = await calls.increment()
                if call <= 2 {
                    throw HostedClientError.network(path: "/v1/live/deepgram-token", reason: "çevrimdışı")
                }
                rejected.open()
                throw rejection
            },
            options: developerDeepgramListenOptions, language: .finnish, keyterms: [], onConnectionEvent: { (_: DeepgramConnectionEvent) -> Void in }, audio: audio
        )
        var failures: [String] = []
        for await event in stream.events {
            if case .failed(let message) = event {
                failures.append(message)
            }
        }
        #expect(await calls.value == 3)
        #expect(failures == [userFacingMessage(error: rejection)])
        #expect(isTransientDeepgramTokenFailure(error: DeepgramTokenError(underlying: URLError(.notConnectedToInternet))))
        #expect(isTransientDeepgramTokenFailure(error: DeepgramTokenError(underlying: HostedAPIError(code: nil, rawCode: "http_502", status: 502, serverMessage: "", path: "/"))))
        #expect(!isTransientDeepgramTokenFailure(error: DeepgramTokenError(underlying: rejection)))
    }

    // Bağlantı ses akarken koptu ve ağ geri gelmiyor (sunucu kapandı): kayıt durunca akış kapanış süresinde biter.
    // Önceden kopma gönderimde fark edilirse ses döngüsü yeniden bağlanmayı (2 dk) bekliyor, durdurma o kadar sürüyor ve
    // "bağlanılamadı" hatası çıkıyordu (kopmayı alma ya da gönderim fark eder; eski kodda yaklaşık her iki denemeden biri).
    // Adımlar süreyle değil olaylarla sıralanır: önceden kopma 1. saniyede yapılıyordu; yüklü CI'da ilk bağlantı o ana
    // dek kurulmamışsa kopacak bağlantı yoktu ve `.dropped` hiç gelmiyordu.
    @Test func stopDuringReconnectEndsWithinCloseDeadline() async throws {
        let server: SilentWebSocketServer = try SilentWebSocketServer()
        let port: UInt16 = try await server.start()
        let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let connectionEvents: ShutdownEventLog = ShutdownEventLog()
        let dropped: TestGate = TestGate()
        let stream: DeepgramStream = startDeepgramStream(
            authorization: .apiKey("yerel"), options: developerDeepgramListenOptions, url: try #require(URL(string: "ws://127.0.0.1:\(port)/v1/listen")),
            keyterms: [], onConnectionEvent: { (event: DeepgramConnectionEvent) -> Void in
                connectionEvents.add(event: event)
                if event == .dropped {
                    dropped.open()
                }
            }, audio: audio
        )
        let clock: ContinuousClock = ContinuousClock()
        let stopFeeding: TestGate = TestGate()
        let feeder: Task<ContinuousClock.Instant, any Error> = Task {
            // 20 ms'lik parçalarla sürekli ses (Mac'teki gibi), kayıt durdurulana dek.
            while !stopFeeding.isOpen {
                input.yield([Float](repeating: 0.01, count: 320))
                try await Task.sleep(for: .milliseconds(20))
            }
            input.finish()
            return clock.now
        }
        // Bağlantı kuruldu ve ses akıyor (sunucu ilk ses mesajını aldı).
        #expect(await completes(within: hangDetectionLimit) { await server.firstAudio.wait() })
        // Ses akarken bağlantı kopar; sunucu kapandığı için yeniden bağlanma denemeleri reddedilir.
        server.stop()
        await stream.dropConnectionForTesting()
        #expect(await completes(within: hangDetectionLimit) { await dropped.wait() })
        // Kopukken ses bir süre daha akar (gönderim kopmayı fark edebilir), sonra kayıt yeniden bağlanma sürerken durur.
        try await Task.sleep(for: .seconds(1))
        stopFeeding.open()
        var failures: [String] = []
        for await event in stream.events {
            if case .failed(let message) = event {
                failures.append(message)
            }
        }
        let stoppedAt: ContinuousClock.Instant = try await feeder.value
        let shutdown: Duration = clock.now - stoppedAt
        #expect(connectionEvents.events.contains(.dropped))
        #expect(failures.isEmpty, "hatalar: \(failures)")
        // Kapanış süresi 5 sn; yeniden bağlanma bütçesi (120 sn) beklenmemeli. Sınır yüklü CI'da iki katıdır (24 sn), yine de
        // bütçenin çok altında.
        #expect(shutdown < .seconds(12 * performanceLimitScale), "kapanış: \(shutdown)")
    }

    // Ses akışı hiç bitmese de (iPhone'da "Bitir"in süresi doldu, boru hattı takıldı) `cancel()` bağlantıyı hemen keser
    // ve olay akışını bitirir; önceden WebSocket KeepAlive'larla açık kalıyordu. Ses akışı ve bağlantı açık kaldığı için
    // olay akışının bitmesi yalnızca `cancel()`'a bağlıdır; süre sınırı yalnızca askıda kalmayı yakalar.
    @Test func cancelClosesSocketWhileAudioIsStillOpen() async throws {
        let server: SilentWebSocketServer = try SilentWebSocketServer()
        let port: UInt16 = try await server.start()
        defer { server.stop() }
        let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        defer { input.finish() }
        let connectionEvents: ShutdownEventLog = ShutdownEventLog()
        let stream: DeepgramStream = startDeepgramStream(
            authorization: .apiKey("yerel"), options: developerDeepgramListenOptions, url: try #require(URL(string: "ws://127.0.0.1:\(port)/v1/listen")),
            keyterms: [], onConnectionEvent: { (event: DeepgramConnectionEvent) -> Void in connectionEvents.add(event: event) }, audio: audio
        )
        input.yield([Float](repeating: 0.01, count: 3200))
        // Bağlantı kuruldu (yerel sunucu, ping yanıtı) ve ses gönderildi.
        #expect(await completes(within: hangDetectionLimit) { await server.firstAudio.wait() })
        await stream.cancel()
        let failures: OSAllocatedUnfairLock<[String]> = OSAllocatedUnfairLock(initialState: [])
        let ended: Bool = await completes(within: hangDetectionLimit) {
            for await event in stream.events {
                if case .failed(let message) = event {
                    failures.withLock { (current: inout [String]) -> Void in current.append(message) }
                }
            }
        }
        #expect(ended, "olay akışı cancel() sonrası bitmedi")
        let reported: [String] = failures.withLock { (current: inout [String]) -> [String] in current }
        #expect(reported.isEmpty, "hatalar: \(reported)")
        // Bırakılan akış yeniden bağlanmaz.
        input.yield([Float](repeating: 0.01, count: 3200))
        try await Task.sleep(for: .milliseconds(300))
        #expect(connectionEvents.events.isEmpty)
    }
}

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

/// Yerel WebSocket sunucusu: bağlantıyı kabul eder ve ping'e yanıt verir, başka bir şey yollamaz; `stop()` sonrası
/// bağlanma denemeleri reddedilir (ağ geri gelmiyor). İlk ses (ikili mesaj) gelince `firstAudio` açılır: istemci ses
/// yalnızca bağlantı kurulduktan sonra gönderir.
private final class SilentWebSocketServer: Sendable {
    let firstAudio: TestGate = TestGate()
    private let listener: NWListener
    private let queue: DispatchQueue = DispatchQueue(label: "SilentWebSocketServer")

    init() throws {
        let parameters: NWParameters = NWParameters.tcp
        let webSocket: NWProtocolWebSocket.Options = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Dinlemeye başlar ve portu döndürür.
    func start() async throws -> UInt16 {
        let listener: NWListener = listener
        listener.newConnectionHandler = { (connection: NWConnection) -> Void in
            connection.start(queue: self.queue)
            self.receiveUntilFirstAudio(connection: connection)
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) -> Void in
            let resumed: OSAllocatedUnfairLock<Bool> = OSAllocatedUnfairLock(initialState: false)
            listener.stateUpdateHandler = { (state: NWListener.State) -> Void in
                let port: UInt16? = listener.port?.rawValue
                switch state {
                case .ready:
                    guard let port, !resumed.withLock({ (done: inout Bool) -> Bool in defer { done = true }; return done }) else {
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    guard !resumed.withLock({ (done: inout Bool) -> Bool in defer { done = true }; return done }) else {
                        return
                    }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    /// İlk ikili mesaja dek okur; sonra okumayı bırakır (ping yanıtı okumadan bağımsızdır).
    private func receiveUntilFirstAudio(connection: NWConnection) {
        connection.receiveMessage { (_: Data?, context: NWConnection.ContentContext?, _: Bool, error: NWError?) -> Void in
            // Hata bağlantının kapandığıdır (test bağlantıyı koparır ya da kapatır): okunacak başka mesaj yok.
            guard error == nil, let context, !context.isFinal else {
                return
            }
            let metadata: NWProtocolWebSocket.Metadata? = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .binary {
                self.firstAudio.open()
                return
            }
            self.receiveUntilFirstAudio(connection: connection)
        }
    }
}

/// Bağlantı olaylarının kaydı; olay bildirildiği anda (eşzamanlı) eklenir ki akış bitince kayıt eksiksiz olsun.
private final class ShutdownEventLog: Sendable {
    private let state: OSAllocatedUnfairLock<[DeepgramConnectionEvent]> = OSAllocatedUnfairLock(initialState: [])

    var events: [DeepgramConnectionEvent] {
        state.withLock { (events: inout [DeepgramConnectionEvent]) -> [DeepgramConnectionEvent] in events }
    }

    func add(event: DeepgramConnectionEvent) {
        state.withLock { (events: inout [DeepgramConnectionEvent]) -> Void in events.append(event) }
    }
}

/// Eşzamanlı sayaç (testte jeton çağrıları).
private actor Counter {
    private(set) var value: Int = 0

    func increment() -> Int {
        value += 1
        return value
    }
}
