import Foundation
import Network
import os
import Testing
@testable import AINotepadCore

@Suite struct DeepgramShutdownTests {
    // Jeton kapanış süresi (5 sn) dolduktan sonra gelirse geçersiz kılınmış oturumda WebSocket açılmaz (önceden
    // `NSGenericException` ile çöküyordu); akış ağa gitmeden sessizce biter.
    @Test func lateTokenAfterCloseDoesNotOpenSocket() async throws {
        let audio: AsyncStream<[Float]> = chunkedStream(samples: [], chunkSize: 1)
        let stream: DeepgramStream = startDeepgramStream(
            token: { () async throws -> String in
                try await Task.sleep(for: .seconds(6.5))
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
        // Akış kapanış süresinde biter; jeton ondan sonra gelir ve bağlanma denenir: süreç o ana dek yaşamalı.
        try await Task.sleep(for: .seconds(2.5))
        #expect(!canOpenConnection(sessionInvalidated: true, closeDeadlinePassed: false, hasFailed: false))
        #expect(canOpenConnection(sessionInvalidated: false, closeDeadlinePassed: false, hasFailed: false))
    }

    // Kısa ağ kesintisinde jeton alınamazsa bağlanma bütçesi içinde yeniden denenir (Mac'e hemen geçilmez); sunucunun
    // bilerek verdiği ret (ör. Deepgram bütçesi doldu) hemen bildirilir.
    @Test func transientTokenFailuresAreRetried() async throws {
        let calls: Counter = Counter()
        let audio: AsyncStream<[Float]> = AsyncStream { (continuation: AsyncStream<[Float]>.Continuation) -> Void in
            Task {
                try? await Task.sleep(for: .seconds(4))
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
    @Test func stopDuringReconnectEndsWithinCloseDeadline() async throws {
        let server: SilentWebSocketServer = try SilentWebSocketServer()
        let port: UInt16 = try await server.start()
        let (audio, input): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
        let connectionEvents: ShutdownEventLog = ShutdownEventLog()
        let stream: DeepgramStream = startDeepgramStream(
            authorization: .apiKey("yerel"), options: developerDeepgramListenOptions, url: try #require(URL(string: "ws://127.0.0.1:\(port)/v1/listen")),
            keyterms: [], onConnectionEvent: { (event: DeepgramConnectionEvent) -> Void in Task { await connectionEvents.add(event: event) } }, audio: audio
        )
        let clock: ContinuousClock = ContinuousClock()
        let feeder: Task<ContinuousClock.Instant, any Error> = Task {
            // 3 sn ses, 20 ms'lik parçalarla (Mac'teki gibi sürekli akış).
            for _ in 0..<150 {
                input.yield([Float](repeating: 0.01, count: 320))
                try await Task.sleep(for: .milliseconds(20))
            }
            input.finish()
            return clock.now
        }
        let drop: Task<Void, any Error> = Task {
            // Ses akarken bağlantı kopar; sunucu kapandığı için yeniden bağlanma denemeleri reddedilir.
            try await Task.sleep(for: .seconds(1))
            server.stop()
            await stream.dropConnectionForTesting()
        }
        var failures: [String] = []
        for await event in stream.events {
            if case .failed(let message) = event {
                failures.append(message)
            }
        }
        let stoppedAt: ContinuousClock.Instant = try await feeder.value
        let shutdown: Duration = clock.now - stoppedAt
        try await drop.value
        #expect(await connectionEvents.events.contains(.dropped))
        #expect(failures.isEmpty, "hatalar: \(failures)")
        // Kapanış süresi 5 sn; yeniden bağlanma bütçesi (120 sn) beklenmemeli.
        #expect(shutdown < .seconds(12), "kapanış: \(shutdown)")
    }
}

/// Yerel WebSocket sunucusu: bağlantıyı kabul eder ve ping'e yanıt verir, başka bir şey yollamaz; `stop()` sonrası
/// bağlanma denemeleri reddedilir (ağ geri gelmiyor).
private final class SilentWebSocketServer: Sendable {
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
}

/// Bağlantı olaylarının kaydı.
private actor ShutdownEventLog {
    private(set) var events: [DeepgramConnectionEvent] = []

    func add(event: DeepgramConnectionEvent) {
        events.append(event)
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
