import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

// Yerel sunucuyu `Process` ile hazırlar: yalnızca macOS'ta derlenir (iOS'ta `Process` yok).
#if os(macOS)

/// Yerel sunucuya karşı uçtan uca deneme yalnızca açıkça istenirse: `AINOTEPAD_HOSTED_E2E=1` ve sunucunun adresi
/// `AINOTEPAD_HOSTED_BASE` (ör. `http://127.0.0.1:8787`). Önce `server/` içinde: `.dev.vars` (sahte gizli değerler),
/// `npm run migrate:local`, `npx wrangler dev`. Denemeler üçüncü taraf servislere (Anthropic, ElevenLabs, Stripe, Apple)
/// istek göndermez: her senaryo sunucunun üst servisten önce verdiği kararı (hak, sınır, oturum) dener. Yerel
/// sunucunun ayarları `server/wrangler.jsonc` geliştirme `vars`'ıdır (3 deneme toplantısı, 7 gün, ayda 10 saat,
/// günlük harcama tavanı 25 $, deneme tavanı 10 $, `DEVICECHECK_POLICY=off`).
let hostedE2EEnabled: Bool = ProcessInfo.processInfo.environment["AINOTEPAD_HOSTED_E2E"] == "1"

/// Denemelerin sürüm başlıkları (`x-app-version`, `x-os-version`).
let e2eClientInfo: HostedClientInfo = HostedClientInfo(appVersion: "0.1.10 (19)", osVersion: "macOS 15.4.1")

/// Bellekte oturum (Anahtar Zinciri'ne dokunulmaz).
final class MemoryTokenStorage: HostedTokenStorage {
    private let tokens: Mutex<HostedTokens?>

    init(tokens initial: HostedTokens?) {
        tokens = Mutex(initial)
    }

    func load() throws -> HostedTokens? {
        tokens.withLock { $0 }
    }

    func save(tokens saved: HostedTokens) throws {
        tokens.withLock { $0 = saved }
    }

    func clear() throws {
        tokens.withLock { $0 = nil }
    }
}

/// Oturum kapanınca çağrılan geri çağrının sayacı.
private final class SessionEndCounter: Sendable {
    let count: Mutex<Int> = Mutex(0)
}

/// Yerel D1'de SQL çalıştırır (`wrangler d1 execute --local`; üretim veritabanına hiç dokunmaz).
func executeLocalD1(sql: String) throws {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "wrangler", "d1", "execute", "ainotepad", "--local", "--command", sql]
    process.currentDirectoryURL = serverDirectory()
    let output: Pipe = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let log: String = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw HostedClientError.malformedResponse(path: "wrangler d1 execute", status: Int(process.terminationStatus), body: log)
    }
}

/// `wrangler d1 execute --json` çıktısındaki toplantı satırı.
private struct MeetingEndRow: Decodable {
    let ended_at: Int?
}

/// `wrangler d1 execute --json` çıktısındaki bir ifadenin sonucu.
private struct MeetingEndStatement: Decodable {
    let results: [MeetingEndRow]
}

/// Yerel D1'deki toplantı oturumu kapanmış mı (`ended_at` dolu); oturum yoksa hata.
private func localMeetingIsEnded(meetingID: String) throws -> Bool {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "wrangler", "d1", "execute", "ainotepad", "--local", "--json", "--command", "SELECT ended_at FROM meeting_sessions WHERE id = '\(meetingID)';"]
    process.currentDirectoryURL = serverDirectory()
    let output: Pipe = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data: Data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, let row = try JSONDecoder().decode([MeetingEndStatement].self, from: data).first?.results.first else {
        throw HostedClientError.malformedResponse(path: "wrangler d1 execute --json", status: Int(process.terminationStatus), body: String(decoding: data, as: UTF8.self))
    }
    return row.ended_at != nil
}

/// Yerel D1'de sorgu çalıştırır (`--json`) ve ilk ifadenin satırlarını çözer.
func localD1Rows<Row: Decodable>(sql: String, as type: Row.Type) throws -> [Row] {
    let process: Process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["npx", "wrangler", "d1", "execute", "ainotepad", "--local", "--json", "--command", sql]
    process.currentDirectoryURL = serverDirectory()
    let output: Pipe = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data: Data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw HostedClientError.malformedResponse(path: "wrangler d1 execute --json", status: Int(process.terminationStatus), body: String(decoding: data, as: UTF8.self))
    }
    return try JSONDecoder().decode([LocalD1Statement<Row>].self, from: data).first?.results ?? []
}

/// `wrangler d1 execute --json` çıktısındaki bir ifadenin satırları.
struct LocalD1Statement<Row: Decodable>: Decodable {
    let results: [Row]
}

/// Hesabın son bildirilen sürümleri.
private struct UserVersionRow: Decodable {
    let last_app_version: String?
    let last_os_version: String?
}

/// Yerel D1'deki raporun alıntı izni.
private struct QuoteRow: Decodable {
    let quoteFirstName: String?

    private enum CodingKeys: String, CodingKey {
        case quoteFirstName = "quote_first_name"
    }
}

/// Günün olay sayısı.
private struct EventCountRow: Decodable {
    let count: Int
}

/// Toplantı kaydı (yalnızca kuyruğun sahiplik ayrımı için gereken alanlarla).
private func queuedRecord(id: String) -> MeetingRecord {
    MeetingRecord(
        id: id, title: id, startedAt: Date(), endedAt: Date(), language: nil, status: .queued, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false,
        engine: .local, notice: nil, meNeedsFinalPass: nil
    )
}

/// Şimdiki an (ms, sunucunun sakladığı biçim).
func nowMs() -> Int {
    Int(Date().timeIntervalSince1970 * 1000)
}

/// Sunucunun gün ve ay anahtarları ("YYYY-MM-DD", "YYYY-MM"; UTC).
private func utcDayKey() -> String {
    String(ISO8601DateFormatter().string(from: Date()).prefix(10))
}

private func utcMonthKey() -> String {
    String(utcDayKey().prefix(7))
}

/// Apple ve Google kimlik jetonları yerelde üretilemediği için oturum yerel D1'e doğrudan eklenir (kullanıcı, oturum
/// ailesi ve yenileme jetonu; sunucunun saklama biçimi: SHA-256 onaltılık). İstemci bu jetonla `/v1/auth/refresh`
/// üzerinden gerçek oturumu alır; giriş ucundan sonraki her adım uygulamanınkiyle aynıdır.
func insertSession(refreshToken: String) throws -> String {
    let hash: String = SHA256.hash(data: Data(refreshToken.utf8)).map { String(format: "%02x", $0) }.joined()
    let now: Int = nowMs()
    let userID: String = "e2e-\(UUID().uuidString.lowercased())"
    let familyID: String = "e2e-\(UUID().uuidString.lowercased())"
    try executeLocalD1(sql: [
        "INSERT INTO users (id, created_at) VALUES ('\(userID)', \(now));",
        "INSERT INTO refresh_families (id, user_id, created_at) VALUES ('\(familyID)', '\(userID)', \(now));",
        "INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES ('\(hash)', '\(familyID)', \(now), \(now + 24 * 3_600_000));",
    ].joined(separator: " "))
    return userID
}

/// Rastgele base64url jeton (sunucunun ürettiğiyle aynı biçim).
func randomToken() -> String {
    Data((0..<32).map { (_: Int) -> UInt8 in UInt8.random(in: 0...255) }).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

/// Yerel sunucunun adresi.
func localServerBase() throws -> URL {
    let base: String = try #require(ProcessInfo.processInfo.environment["AINOTEPAD_HOSTED_BASE"], "AINOTEPAD_HOSTED_BASE (wrangler dev adresi) gerekli")
    return try parseHostedBaseURL(value: base)
}

/// Giriş uçlarının IP hız sınırı (`AUTH_IP_LIMITER`, dakikada 10; yenileme ve çıkış da sayılır) yerelde de uygulanır:
/// işlem `rate_limited` alırsa bir dakika beklenip yeniden denenir (en çok 3 bekleme).
func awaitingAuthLimit<Value: Sendable>(operation: () async throws -> Value) async throws -> Value {
    for _ in 1...3 {
        do {
            return try await operation()
        } catch let error as HostedAPIError where error.code == .rateLimited {
            try await Task.sleep(for: .seconds(61))
        }
    }
    return try await operation()
}

/// Yeni kullanıcı ve yenileme jetonuyla oturum açmış istemci (erişim jetonu alınmış).
private struct SignedInUser {
    let client: HostedClient
    let storage: MemoryTokenStorage
    let userID: String
    let seedRefreshToken: String
}

private func signedInUser(baseURL: URL) async throws -> SignedInUser {
    let seedRefreshToken: String = randomToken()
    let userID: String = try insertSession(refreshToken: seedRefreshToken)
    let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
        accessToken: "gecersiz", refreshToken: seedRefreshToken, accessExpiresAt: Date.distantPast, userId: userID
    ))
    let client: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
    _ = try await awaitingAuthLimit { try await client.validAccessToken() }
    return SignedInUser(client: client, storage: storage, userID: userID, seedRefreshToken: seedRefreshToken)
}

/// Yeni bir deneme hesabının ilk toplantısı IP başına günlük deneme sınırına (yerelde 3) sayılır; yerel veritabanı
/// çalıştırmalar arasında kaldığı için önceki çalıştırmaların bugünkü sayaçları silinir.
private func resetLocalTrialStarts() throws {
    try executeLocalD1(sql: "DELETE FROM trial_starts; DELETE FROM deleted_trial_starts;")
}

/// Denemesi başlamış (bir deneme toplantısı devralınmış) kullanıcı: IP sınırına girmeden deneme toplantısı açabilir.
private func markTrialStarted(userID: String, usedMeetings: Int, startedAtMs: Int) throws {
    try executeLocalD1(sql: "UPDATE users SET carried_trial_meetings = \(usedMeetings), trial_started_at = \(startedAtMs) WHERE id = '\(userID)';")
}

/// Toplantı dışı (hesap) yapay zekâ çağrısı: uygulamanın Sor, notu yeniden yazma ve paylaşım çevirisi yolu.
private func accountLLMProvider(baseURL: URL, client: HostedClient) -> LLMProvider {
    .hosted(HostedLLMConfig(baseURL: baseURL, credentials: client, scope: .account))
}

/// Kısa bir istek (sunucunun ret kararı üst servisten önce verilir; gövde Anthropic'e gitmez).
private func smallRequest() -> LLMRequest {
    translationRequest(sentence: "Hyvää huomenta.", context: [], language: .english)
}

/// İşlemin fırlattığı sunucu hatası; başka hata ya da başarı denemeyi düşürür.
private func hostedError(operation: () async throws -> Void) async -> HostedAPIError? {
    do {
        try await operation()
        Issue.record("Sunucu hatası bekleniyordu, işlem başarılı oldu")
        return nil
    } catch let error as HostedAPIError {
        return error
    } catch LLMError.hosted(let error) {
        return error
    } catch {
        Issue.record("Sunucu hatası bekleniyordu, gelen: \(error)")
        return nil
    }
}

/// Kod tanınmadığında gösterilen genel metin: kullanıcıya ne yapacağını söylemez; eşleşen her kodda bundan farklı
/// olmalı.
private func genericHostedMessage(status: Int) -> String {
    hostedErrorMessage(error: HostedAPIError(code: nil, rawCode: "http_\(status)", status: status, serverMessage: "", path: "/"))
}

/// 1 sn sessiz 16 kHz mono 16 bit FLAC'ı (uygulamanın son geçişte gönderdiği biçim; sunucu süreyi STREAMINFO'dan
/// okur) `directory`'ye yazar ve yolunu döndürür.
private func silentFlac(directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source: URL = directory.appending(path: "sessiz.wav")
    try wavData(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000).write(to: source)
    let chunks: [AudioChunkFile] = try writeHostedFlacChunks(source: source, directory: directory, maxBytes: hostedTranscribeMaxBytes, maxSamples: 16_000, overlapSamples: 0)
    return try #require(chunks.first?.url)
}

@Suite(.enabled(if: hostedE2EEnabled), .serialized) struct HostedE2ETests {
    // iPhone uygulaması aynı hesap ve uçlarla çalışır: `x-os-version` "iOS …" kabul edilir (eski sunucu 400 verirdi),
    // hak durumu okunur, deneme toplantısı açılıp kapanır.
    @Test func iPhoneClientUsesSameAccountAndMeetings() async throws {
        let baseURL: URL = try localServerBase()
        try resetLocalTrialStarts()
        let seedRefreshToken: String = randomToken()
        let userID: String = try insertSession(refreshToken: seedRefreshToken)
        let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: "gecersiz", refreshToken: seedRefreshToken, accessExpiresAt: Date.distantPast, userId: userID
        ))
        let phoneInfo: HostedClientInfo = try hostedClientInfo(
            shortVersion: "0.1.12", buildNumber: "21", system: .iOS, operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        )
        let client: HostedClient = HostedClient(clientInfo: phoneInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
        let entitlements: HostedEntitlements = try await awaitingAuthLimit { try await client.entitlements() }
        #expect(entitlements.userId == userID)
        let started: HostedStartedMeeting = try await client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        #expect(started.kind == "trial")
        let finished: HostedEndedMeeting = try await client.endMeeting(meetingID: started.meetingId)
        #expect(finished.meetingId == started.meetingId)
    }

    // Oturum (yenileme jetonuyla) → /v1/me → toplantı başlat (deneme düşer) → bitir → erişim jetonu yenilenir →
    // yanıtı kaybolmuş yenilemenin 10 dakika içindeki tekrarı kabul edilir → halef kullanıldıktan sonra eski jeton
    // yeniden gelirse tüm oturumlar düşer ve istemci çıkış yapar.
    @Test func signInMeetingAndRefreshAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        try resetLocalTrialStarts()
        let seedRefreshToken: String = randomToken()
        let userID: String = try insertSession(refreshToken: seedRefreshToken)

        let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: "gecersiz", refreshToken: seedRefreshToken, accessExpiresAt: Date.distantPast, userId: userID
        ))
        let ended: SessionEndCounter = SessionEndCounter()
        let client: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        #expect(try await client.isSignedIn())

        let before: HostedEntitlements = try await awaitingAuthLimit { try await client.entitlements() }
        #expect(hostedPlanStatus(entitlements: before, now: Date()) == .trial(.notStarted(left: before.trialMeetingsTotal, total: before.trialMeetingsTotal)))
        #expect(before.trialEndsAt == nil)
        #expect(before.monthlyHoursCap > 0)

        let started: HostedStartedMeeting = try await client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        #expect(started.kind == "trial")
        #expect(started.trialMeetingsLeft == before.trialMeetingsTotal - 1)
        #expect(await client.currentMeetingID() == started.meetingId)
        let credentials: HostedLLMCredentials = try await client.meetingLLMCredentials()
        #expect(credentials.meetingID == started.meetingId)

        let during: HostedEntitlements = try await client.entitlements()
        #expect(during.trialMeetingsLeft == before.trialMeetingsTotal - 1)
        // Deneme süresi ilk toplantıyla başlar.
        #expect(during.trialEndsAt != nil)
        let finished: HostedEndedMeeting = try await client.endMeeting(meetingID: started.meetingId)
        #expect(finished.meetingId == started.meetingId)
        #expect(finished.minutes == 1)

        // Erişim jetonu bitmiş sayılınca istek öncesi yenilenir; yenileme jetonu döner.
        let original: HostedTokens = try #require(try storage.load())
        try storage.save(tokens: HostedTokens(accessToken: original.accessToken, refreshToken: original.refreshToken, accessExpiresAt: Date.distantPast, userId: original.userId))
        let refreshingClient: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        _ = try await refreshingClient.entitlements()
        let rotated: HostedTokens = try #require(try storage.load())
        #expect(rotated.refreshToken != original.refreshToken)
        #expect(rotated.accessExpiresAt > Date())

        // Yanıtı kaybolmuş yenilemenin tekrarı (yerine geçen jeton henüz kullanılmamış, 10 dakikalık süre içinde): oturum
        // düşmez, yeni bir çift verilir; kullanılmamış eski halef geçersizleşir.
        let retryStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: original.accessToken, refreshToken: original.refreshToken, accessExpiresAt: Date.distantPast, userId: original.userId
        ))
        let retryClient: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: retryStorage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        _ = try await retryClient.entitlements()
        let retried: HostedTokens = try #require(try retryStorage.load())
        #expect(retried.refreshToken != original.refreshToken)
        #expect(retried.refreshToken != rotated.refreshToken)
        #expect(ended.count.withLock { $0 } == 0)

        // Halef kullanıldıktan sonra (yeni çift bir kez daha yenilendi) eski jeton yeniden gelirse çalınmış sayılır: sunucu
        // tüm oturum ailesini kapatır, istemci yerel oturumu siler ve bildirir. Önce giriş uçlarının IP sınırı (dakikada
        // 10, diğer denemelerle ortak) sıfırlansın diye beklenir.
        try await Task.sleep(for: .seconds(61))
        // Halefi ayrı bir istemci kullanır (istemci jetonları bellekte tutar; depoyu dışarıdan değiştirmek yenilemez).
        let successorStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: retried.accessToken, refreshToken: retried.refreshToken, accessExpiresAt: Date.distantPast, userId: retried.userId
        ))
        let successorClient: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: successorStorage) { () async -> Void in }
        _ = try await successorClient.entitlements()
        let newest: HostedTokens = try #require(try successorStorage.load())
        #expect(newest.refreshToken != retried.refreshToken)
        let replayStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: original.accessToken, refreshToken: original.refreshToken, accessExpiresAt: Date.distantPast, userId: original.userId
        ))
        let replayClient: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: replayStorage) { () async -> Void in
            ended.count.withLock { $0 += 1 }
        }
        await #expect(throws: HostedClientError.sessionEnded) { _ = try await replayClient.entitlements() }
        #expect(try replayStorage.load() == nil)
        #expect(ended.count.withLock { $0 } == 1)
        // Aile düştüğü için en yeni jeton da artık geçmez.
        let familyClient: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: MemoryTokenStorage(tokens: HostedTokens(
            accessToken: newest.accessToken, refreshToken: newest.refreshToken, accessExpiresAt: Date.distantPast, userId: newest.userId
        ))) { () async -> Void in }
        await #expect(throws: HostedClientError.sessionEnded) { _ = try await familyClient.entitlements() }
    }

    // Rapor ucu: hesapsız sürümlerin (geliştirici sürümü, iPhone) jetonsuz geri bildirimi kabul edilir
    // (`anonymousReportDestination`; sunucu tür bütçesinin dörtte birini ayırır); hesaplı (bearer) geri bildirim ve çökme
    // raporu da 2xx alır.
    // Telemetri: `/v1/me` sürüm başlıklarını hesaba yazar; olaylar günün toplamına eklenir (hesaba bağlanmaz); günün
    // özellik raporu hesap başına bir kez sayılır.
    @Test func telemetryAndVersionsAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        _ = try await user.client.entitlements()
        let versions: [UserVersionRow] = try localD1Rows(sql: "SELECT last_app_version, last_os_version FROM users WHERE id = '\(user.userID)';", as: UserVersionRow.self)
        #expect(versions.first?.last_app_version == e2eClientInfo.appVersion)
        #expect(versions.first?.last_os_version == e2eClientInfo.osVersion)

        let countSQL: String = "SELECT count FROM client_event_counts WHERE day = '\(utcDayKey())' AND kind = 'recording_overrun' AND app_version = '\(e2eClientInfo.appVersion)';"
        let before: Int = try localD1Rows(sql: countSQL, as: EventCountRow.self).first?.count ?? 0
        let pending: TelemetryPendingEvents = addingTelemetryDuration(
            pending: addingTelemetryCount(pending: TelemetryPendingEvents(counts: [], durations: []), kind: .recordingOverrun),
            kind: .finalPassDuration, seconds: 42
        )
        try await user.client.sendTelemetryEvents(body: try #require(try hostedTelemetryEventsBody(pending: pending)))
        #expect(try localD1Rows(sql: countSQL, as: EventCountRow.self).first?.count == before + 1)

        let usage: TelemetryFeatureUsage = recordingFeature(usage: emptyFeatureUsage(day: telemetryDayKey(date: Date())), feature: .export(.pdf))
        #expect(try await user.client.sendFeatureUsage(body: try hostedFeatureUsageBody(usage: usage)))
        #expect(try await !user.client.sendFeatureUsage(body: try hostedFeatureUsageBody(usage: usage)))
    }

    // İlk açılış hunisi: oturumsuz istemcinin her adımı (`POST /v1/funnel`, jetonsuz) günün, ayrıntının ve uygulama
    // sürümünün sayacına bir ekler.
    @Test func funnelStepsCountedWithoutAccountAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let client: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: MemoryTokenStorage(tokens: nil)) { () async -> Void in }
        #expect(try await !client.isSignedIn())
        let steps: [HostedFunnelStep] = [
            .firstLaunch,
            .signInStarted(.google),
            .signInCanceled(.apple),
            .signInFailed(.callback),
            .signedIn(.google),
        ]
        for step in steps {
            let countSQL: String = "SELECT count FROM app_funnel_daily WHERE day = '\(utcDayKey())' AND step = '\(step.kind.rawValue)' AND detail = '\(step.detail)' AND app_version = '\(e2eClientInfo.appVersion)';"
            let before: Int = try localD1Rows(sql: countSQL, as: EventCountRow.self).first?.count ?? 0
            try await client.sendFunnelStep(step: step)
            #expect(try localD1Rows(sql: countSQL, as: EventCountRow.self).first?.count == before + 1, "\(step.kind.rawValue) sayılmadı")
        }
    }

    @Test func reportsAcceptedWithAndWithoutAccountAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let diagnostics: ReportDiagnostics = currentReportDiagnostics(bundle: .main, platformName: "macOS")
        let feedback: ReportRequest = try feedbackReport(message: "Uçtan uca deneme geri bildirimi.", email: "e2e@ornek.fi", diagnostics: diagnostics, quoteFirstName: nil)
        try await submitReport(report: feedback, destination: ReportDestination(baseURL: baseURL, accessToken: nil))

        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try await submitReport(report: feedback, destination: ReportDestination(baseURL: baseURL, accessToken: try await user.client.validAccessToken()))
        let payload: Data = Data(#"{"crashDiagnostics":[{"diagnosticMetaData":{"appVersion":"0.1.4","appBuildVersion":"5","osVersion":"macOS 26.1","exceptionType":1,"signal":11}}]}"#.utf8)
        let crash: CrashDiagnostic = try #require(try crashDiagnostics(payload: payload).first)
        try await submitReport(
            report: try crashReportRequest(payload: payload, diagnostic: crash),
            destination: ReportDestination(baseURL: baseURL, accessToken: try await user.client.validAccessToken())
        )
        // Alıntı izni (ön adla) tanılama eklenmiş geri bildirimle sunucuya ulaşır ve raporla saklanır.
        let marker: String = "quote-consent-\(UUID().uuidString)"
        let consented: ReportRequest = try appendingDiagnostics(
            report: try feedbackReport(message: marker, email: "", diagnostics: diagnostics, quoteFirstName: " Aino "),
            diagnosticsText: "- Hesap: deneme", limit: reportMessageLimit
        )
        try await submitReport(report: consented, destination: ReportDestination(baseURL: baseURL, accessToken: try await user.client.validAccessToken()))
        let stored: [QuoteRow] = try localD1Rows(sql: "SELECT quote_first_name FROM reports WHERE instr(message, '\(marker)') = 1", as: QuoteRow.self)
        #expect(stored.map(\.quoteFirstName) == ["Aino"])
    }

    // Bir hesabın yolculuğu, her adımda uygulamanın gösterdiği durum ve hata metni: yeni deneme (toplantı dışı yapay
    // zekâ `trial_not_started`, portal `subscription_required`, toplantısız canlı istek yerelde `noActiveMeeting`) →
    // deneme bitti (`trial_exhausted`, toplantı dışı `subscription_required`) → abonelik etkin → aylık sınır dolu
    // (`monthly_cap_reached`) → ödeme gecikti (ek süre) → abonelik iptal edildi.
    @Test func accountJourneyStatesAndMessagesAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        let client: HostedClient = user.client
        let account: LLMProvider = accountLLMProvider(baseURL: baseURL, client: client)

        // 1. Yeni hesap, deneme başlamadı.
        let fresh: HostedEntitlements = try await client.entitlements()
        #expect(fresh.plan == .trial)
        #expect(hostedPlanStatus(entitlements: fresh, now: Date()) == .trial(.notStarted(left: fresh.trialMeetingsTotal, total: fresh.trialMeetingsTotal)))
        #expect(fresh.trialEndsAt == nil)
        let notStarted: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: account, request: smallRequest()) }
        #expect(notStarted?.code == .trialNotStarted)
        #expect(notStarted?.status == 403)
        if let notStarted {
            #expect(userFacingMessage(error: LLMError.hosted(notStarted)) != genericHostedMessage(status: 403))
            #expect(userFacingMessage(error: LLMError.hosted(notStarted)) == hostedErrorMessage(error: notStarted))
        }
        let portal: HostedAPIError? = await hostedError { _ = try await client.portalURL() }
        #expect(portal?.code == .subscriptionRequired)
        // Kayıt sırasındaki istekler (canlı çeviri, "Ne kaçırdım?") toplantı ister: toplantı yokken ağa çıkmadan durur.
        let meetingScoped: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: client, scope: .meeting))
        await #expect(throws: HostedClientError.noActiveMeeting) { _ = try await sendLLM(provider: meetingScoped, request: smallRequest()) }
        #expect(stopsLiveTranslation(error: HostedClientError.noActiveMeeting))

        // 2. Deneme toplantıları harcandı.
        try markTrialStarted(userID: user.userID, usedMeetings: fresh.trialMeetingsTotal, startedAtMs: nowMs())
        let exhausted: HostedEntitlements = try await client.entitlements()
        #expect(hostedPlanStatus(entitlements: exhausted, now: Date()) == .trial(.ended(reason: .meetingsUsed, total: exhausted.trialMeetingsTotal)))
        #expect(exhausted.trialEndsAt != nil)
        let exhaustedStart: HostedAPIError? = await hostedError { _ = try await client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        #expect(exhaustedStart?.code == .trialExhausted)
        #expect(exhaustedStart?.status == 402)
        let exhaustedAsk: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: account, request: smallRequest()) }
        #expect(exhaustedAsk?.code == .subscriptionRequired)
        if let exhaustedAsk {
            #expect(stopsLiveTranslation(error: LLMError.hosted(exhaustedAsk)))
        }

        // 3. Abonelik etkin (webhook'un yazdığı satır).
        let periodEnd: Int = nowMs() + 30 * 86_400_000
        try executeLocalD1(sql: """
            INSERT INTO subscriptions (user_id, stripe_customer_id, stripe_subscription_id, status, current_period_end, last_event_created, updated_at)
            VALUES ('\(user.userID)', 'cus_\(user.userID)', 'sub_\(user.userID)', 'active', \(periodEnd), 1, \(nowMs()));
            """)
        let subscribed: HostedEntitlements = try await client.entitlements()
        #expect(subscribed.plan == .subscription)
        #expect(subscribed.subscription?.access == .active)
        if case .subscribed = hostedPlanStatus(entitlements: subscribed, now: Date()) {
        } else {
            Issue.record("Etkin abonelik `.subscribed` görünmeli: \(hostedPlanStatus(entitlements: subscribed, now: Date()))")
        }

        // 4. Bu ayın süresi doldu: abonelik toplantısı başlamaz.
        let capSeconds: Int = Int(subscribed.monthlyHoursCap * 3600)
        try executeLocalD1(sql: "INSERT INTO monthly_usage (user_id, month, audio_seconds) VALUES ('\(user.userID)', '\(utcMonthKey())', \(capSeconds));")
        let capped: HostedEntitlements = try await client.entitlements()
        #expect(capped.monthlyHoursUsed >= capped.monthlyHoursCap)
        let cappedStart: HostedAPIError? = await hostedError { _ = try await client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        #expect(cappedStart?.code == .monthlyCapReached)
        if let cappedStart {
            #expect(userFacingMessage(error: cappedStart) != genericHostedMessage(status: 403))
        }

        // 5. Ödeme alınamadı: ek süre boyunca erişim sürer.
        try executeLocalD1(sql: "UPDATE subscriptions SET status = 'past_due', past_due_since = \(nowMs()), current_period_end = \(nowMs() - 86_400_000) WHERE user_id = '\(user.userID)';")
        let pastDue: HostedEntitlements = try await client.entitlements()
        #expect(pastDue.plan == .subscription)
        #expect(pastDue.subscription?.access == .grace)
        if case .grace = hostedPlanStatus(entitlements: pastDue, now: Date()) {
        } else {
            Issue.record("Ek süredeki abonelik `.grace` görünmeli: \(hostedPlanStatus(entitlements: pastDue, now: Date()))")
        }

        // 6. Abonelik iptal edildi: sunucu planı denemeye döndürür (deneme toplantıları harcanmış); uygulama bunu
        // "deneme bitti" değil "abonelik sona erdi" olarak gösterir ve yeniden abone olmayı önerir.
        try executeLocalD1(sql: "UPDATE subscriptions SET status = 'canceled', past_due_since = NULL WHERE user_id = '\(user.userID)';")
        let canceled: HostedEntitlements = try await client.entitlements()
        #expect(canceled.plan == .trial)
        #expect(canceled.subscription?.access == HostedSubscriptionAccess.none)
        if case .expired = hostedPlanStatus(entitlements: canceled, now: Date()) {
            #expect(hostedStartBlock(entitlements: canceled, now: Date()) == .subscriptionEnded)
        } else {
            Issue.record("İptal edilmiş abonelik `.expired` görünmeli: \(hostedPlanStatus(entitlements: canceled, now: Date()))")
        }
        let canceledAsk: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: account, request: smallRequest()) }
        #expect(canceledAsk?.code == .subscriptionRequired)
    }

    // Günlük harcama tavanları: deneme tavanı dolunca deneme toplantısı ve denemedeki toplantı dışı yapay zekâ
    // `trial_capacity_reached`, genel tavan dolunca toplantı `spend_ceiling_reached` alır; ikisi de kalıcı sayılır
    // (yeniden denenmez) ve canlı çeviriyi durdurur. Bugünkü harcama sayaçları deneme sonunda geri alınır.
    @Test func spendCeilingsAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let bump: Int = 1_000_000_000_000
        let day: String = utcDayKey()

        try executeLocalD1(sql: "INSERT INTO daily_spend (day, micro_usd, trial_micro_usd) VALUES ('\(day)', 0, \(bump)) ON CONFLICT(day) DO UPDATE SET trial_micro_usd = trial_micro_usd + \(bump);")
        let trialStart: HostedAPIError? = await hostedError { _ = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        let trialAsk: HostedAPIError? = await hostedError {
            _ = try await sendLLM(provider: accountLLMProvider(baseURL: baseURL, client: user.client), request: smallRequest())
        }
        try executeLocalD1(sql: "UPDATE daily_spend SET trial_micro_usd = trial_micro_usd - \(bump) WHERE day = '\(day)';")
        #expect(trialStart?.code == .trialCapacityReached)
        #expect(trialAsk?.code == .trialCapacityReached)
        if let trialAsk {
            #expect(!isRetryableHostedError(error: trialAsk))
            #expect(stopsLiveTranslation(error: LLMError.hosted(trialAsk)))
        }

        try executeLocalD1(sql: "INSERT INTO daily_spend (day, micro_usd) VALUES ('\(day)', \(bump)) ON CONFLICT(day) DO UPDATE SET micro_usd = micro_usd + \(bump);")
        let ceilingStart: HostedAPIError? = await hostedError { _ = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false) }
        try executeLocalD1(sql: "UPDATE daily_spend SET micro_usd = micro_usd - \(bump) WHERE day = '\(day)';")
        #expect(ceilingStart?.code == .spendCeilingReached)
        #expect(ceilingStart?.status == 503)
        if let ceilingStart {
            #expect(!isRetryableHostedError(error: ceilingStart))
            #expect(userFacingMessage(error: ceilingStart) != genericHostedMessage(status: 503))
        }
    }

    // Son geçiş yüklemesi: toplantıda süren bir ses isteği varken (ör. zaman aşımına uğrayan yüklemenin istemci
    // tekrarı) sunucu `409 transcription_in_progress` döner; ses hakkı kapanmış toplantı `403 transcription_closed`.
    // İkisi de üst servise gitmeden reddedilir.
    @Test func finalPassUploadConflictsAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        let audioDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: audioDirectory) }
        let flac: URL = try silentFlac(directory: audioDirectory)

        let now: Int = nowMs()
        try executeLocalD1(sql: """
            INSERT INTO usage_reservations (id, user_id, meeting_id, kind, month, day, tokens, trial_account_tokens, account_tokens, audio_seconds, estimated_micro_usd, trial_spend, created_at, expires_at)
            VALUES ('e2e-\(UUID().uuidString.lowercased())', '\(user.userID)', '\(started.meetingId)', 'audio', '\(utcMonthKey())', '\(utcDayKey())', 0, 0, 0, 1, 0, 1, \(now), \(now + 600_000));
            """)
        let inProgress: HostedAPIError? = await hostedError {
            _ = try await user.client.transcribe(meetingID: started.meetingId, flacFile: flac, languageCode: nil, keyterms: [], uploadKey: try makeUploadKey(), timeoutSec: 30)
        }
        try executeLocalD1(sql: "DELETE FROM usage_reservations WHERE meeting_id = '\(started.meetingId)';")
        #expect(inProgress?.status == 409)
        #expect(inProgress?.rawCode == "transcription_in_progress")
        // İstemci kodu tanır: son geçiş bekleyip yeniden dener (HostedFinalTranscriber), kullanıcı genel hata görmez.
        #expect(inProgress?.code == .transcriptionInProgress)
        if let inProgress {
            #expect(userFacingMessage(error: inProgress) != genericHostedMessage(status: 409))
        }

        try executeLocalD1(sql: "UPDATE meeting_sessions SET transcription_closed = 1 WHERE id = '\(started.meetingId)';")
        let closed: HostedAPIError? = await hostedError {
            _ = try await user.client.transcribe(meetingID: started.meetingId, flacFile: flac, languageCode: nil, keyterms: [], uploadKey: try makeUploadKey(), timeoutSec: 30)
        }
        #expect(closed?.code == .transcriptionClosed)
        _ = try await user.client.endMeeting(meetingID: started.meetingId)
    }

    // Duraklatma: istemcinin çözdüğü yanıt sunucunun sözleşmesiyle aynı; duraklatmada bitiş kalan hak kadar ileri gider,
    // sürdürünce yalnızca gerçekten duraklatılan süre kadar uzamış kalır; yinelenen istekler durumu döndürür.
    @Test func pauseAndResumeMoveTheMeetingEndAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        let paused: HostedMeetingPause = try await user.client.pauseMeeting(meetingID: started.meetingId)
        #expect(paused.paused)
        #expect(paused.meetingId == started.meetingId)
        #expect(paused.expiresAt > started.expiresAt.addingTimeInterval(Double(started.maxDurationMinutes) * 60 - 60))
        #expect(try await user.client.pauseMeeting(meetingID: started.meetingId).paused)
        let resumed: HostedMeetingPause = try await user.client.resumeMeeting(meetingID: started.meetingId)
        #expect(!resumed.paused)
        #expect(resumed.expiresAt >= started.expiresAt)
        #expect(resumed.expiresAt < started.expiresAt.addingTimeInterval(60))
        #expect(!(try await user.client.resumeMeeting(meetingID: started.meetingId).paused))
        _ = try await user.client.endMeeting(meetingID: started.meetingId)
        let afterEnd: HostedAPIError? = await hostedError { _ = try await user.client.pauseMeeting(meetingID: started.meetingId) }
        #expect(afterEnd?.code == .meetingNotActive)
    }

    // Çevrimdışı kaydedilmiş toplantı bağlantı gelince açılır: aynı kayıt kimliğiyle (`clientRef`) yinelenen başlatma
    // (yanıt kaybolduysa, uygulama yeniden açıldıysa) aynı oturumu döndürür, deneme bir kez düşer; oturum hemen
    // kapatılsa da ses hakkı en çok sürece açıktır ve not için ek süre başlar.
    @Test func deferredMeetingStartIsIdempotentAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        // Yeni deneme kullanıcısı IP başına günlük deneme sayısına yazılır: tek başına tekrar koşunca sınıra takılmasın.
        try resetLocalTrialStarts()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        let before: HostedEntitlements = try await user.client.entitlements()
        let recordID: String = "kayit-\(UUID().uuidString.lowercased())"
        let first: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        _ = try await user.client.endMeeting(meetingID: first.meetingId)
        let repeated: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        #expect(repeated.meetingId == first.meetingId)
        #expect(repeated.maxDurationMinutes == first.maxDurationMinutes)
        let after: HostedEntitlements = try await user.client.entitlements()
        #expect(after.trialMeetingsLeft == before.trialMeetingsLeft - 1)
        // Kapatma tekrarı zararsız; kapalı oturum yapay zekâ çağrısı için ek sürede açık.
        let ended: HostedEndedMeeting = try await user.client.endMeeting(meetingID: first.meetingId)
        #expect(ended.meetingId == first.meetingId)
        let other: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: "kayit-\(UUID().uuidString.lowercased())", deferred: false)
        #expect(other.meetingId != first.meetingId)
        // Canlı kayıt sürerken dönen ertelenmiş açılış (kuyruk hazırlığı) canlı kaydın yapay zekâ toplantısını ezmez.
        _ = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        #expect(await user.client.currentMeetingID() == other.meetingId)
        _ = try await user.client.endMeeting(meetingID: other.meetingId)
    }

    // İşleme süresi (24 saat) geçmiş toplantı: toplantı kapsamlı çağrı `meeting_not_active` alır; "Tekrar işle" oturumu
    // yeniden işleme için açar (`reprocessMeeting`, en çok iki kez; yeni deneme düşmez), sonra çağrı yine geçer. Sınır
    // dolunca `reprocess_limit_reached` ve kullanıcı genel hata değil gerçek nedeni görür.
    @Test func reprocessAfterGraceAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        // İşleme süresindeki toplantı zaten açık: hak harcanmaz.
        let recent: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        _ = try await user.client.endMeeting(meetingID: recent.meetingId)
        let stillOpen: HostedReprocessedMeeting = try await user.client.reprocessMeeting(meetingID: recent.meetingId)
        #expect(stillOpen.reprocessesLeft == 2)
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        try await endMeetingInThePast(client: user.client, meetingID: started.meetingId, durationMs: 60_000, endedAgoMs: 90_000_000)
        let before: HostedEntitlements = try await user.client.entitlements()
        let audioDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "ainotepad-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: audioDirectory) }
        let flac: URL = try silentFlac(directory: audioDirectory)
        let expired: HostedAPIError? = await hostedError {
            _ = try await user.client.transcribe(meetingID: started.meetingId, flacFile: flac, languageCode: nil, keyterms: [], uploadKey: try makeUploadKey(), timeoutSec: 30)
        }
        #expect(expired?.code == .meetingNotActive)

        let first: HostedReprocessedMeeting = try await user.client.reprocessMeeting(meetingID: started.meetingId)
        #expect(first.reprocessesLeft == 1)
        #expect(first.usableUntil > Date())
        try ageReprocessWindow(meetingID: started.meetingId, ms: 90_000_000)
        let second: HostedReprocessedMeeting = try await user.client.reprocessMeeting(meetingID: started.meetingId)
        #expect(second.reprocessesLeft == 0)
        try ageReprocessWindow(meetingID: started.meetingId, ms: 90_000_000)
        let limited: HostedAPIError? = await hostedError { _ = try await user.client.reprocessMeeting(meetingID: started.meetingId) }
        #expect(limited?.code == .reprocessLimitReached)
        if let limited {
            #expect(userFacingMessage(error: limited) != genericHostedMessage(status: 409))
        }
        let after: HostedEntitlements = try await user.client.entitlements()
        #expect(after.trialMeetingsLeft == before.trialMeetingsLeft)
        // Ölü bağ (sunucuda olmayan ya da başka hesabın oturumu) `not_found` döner: kuyruk bağı silip yeni oturum açar.
        let missing: HostedAPIError? = await hostedError { _ = try await user.client.endMeeting(meetingID: UUID().uuidString.lowercased()) }
        #expect(missing?.code == .notFound)
        let foreign: SignedInUser = try await signedInUser(baseURL: baseURL)
        let foreignReprocess: HostedAPIError? = await hostedError { _ = try await foreign.client.reprocessMeeting(meetingID: started.meetingId) }
        #expect(foreignReprocess?.code == .notFound)
    }

    // İçe aktarılan dosya kayıt gibi sayılır: kuyruk sunucu oturumunu `clientRef` ile açar, deneme hakkı düşer; deneme
    // bitince yeni içe aktarma reddedilir (`trial_exhausted`, ses Mac'te kalır), ama yarıda kalmış içe aktarmanın aynı
    // kimlikle yinelenen açılışı (uygulama kapanıp açıldı) yine aynı oturumu döndürür.
    @Test func importedFileCountsLikeRecordingAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 2, startedAtMs: nowMs())
        let importID: String = "ice-aktarim-\(UUID().uuidString.lowercased())"
        let imported: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: importID, deferred: true)
        #expect(imported.kind == "trial")
        #expect(imported.trialMeetingsLeft == 0)
        _ = try await user.client.endMeeting(meetingID: imported.meetingId)
        let repeated: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: importID, deferred: true)
        #expect(repeated.meetingId == imported.meetingId)
        let refused: HostedAPIError? = await hostedError {
            _ = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: "ice-aktarim-\(UUID().uuidString.lowercased())", deferred: true)
        }
        #expect(refused?.code == .trialExhausted)
        let after: HostedEntitlements = try await user.client.entitlements()
        #expect(hostedStartBlock(entitlements: after, now: Date()) == .trialEnded)
    }

    // Çıkış ve hesap silme: ikisinde de yerel oturum silinir; eski yenileme jetonu artık geçmez (istemci "oturum
    // kapandı" der ve kayıtlı oturumu siler).
    @Test func signOutAndDeleteAccountAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()

        let leaving: SignedInUser = try await signedInUser(baseURL: baseURL)
        try await awaitingAuthLimit { try await leaving.client.signOut() }
        #expect(try await leaving.client.isSignedIn() == false)
        await #expect(throws: HostedClientError.notSignedIn) { _ = try await leaving.client.entitlements() }
        let stale: HostedTokens = HostedTokens(accessToken: "gecersiz", refreshToken: leaving.seedRefreshToken, accessExpiresAt: Date.distantPast, userId: leaving.userID)
        let staleStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: stale)
        let staleClient: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: staleStorage) { () async -> Void in }
        await #expect(throws: HostedClientError.sessionEnded) {
            _ = try await awaitingAuthLimit { try await staleClient.entitlements() }
        }
        #expect(try staleStorage.load() == nil)

        let deleting: SignedInUser = try await signedInUser(baseURL: baseURL)
        let current: HostedTokens = try #require(try deleting.storage.load())
        let deletion: HostedAccountDeletion? = try await deleting.client.deleteAccount()
        // App Store aboneliği olmayan hesap: Apple'da iptal uyarısı yok.
        #expect(deletion == HostedAccountDeletion(deleted: true, appStoreSubscription: nil, notice: nil))
        #expect(try await deleting.client.isSignedIn() == false)
        let deletedStorage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(
            accessToken: "gecersiz", refreshToken: current.refreshToken, accessExpiresAt: Date.distantPast, userId: current.userId
        ))
        let deletedClient: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: deletedStorage) { () async -> Void in }
        await #expect(throws: HostedClientError.sessionEnded) {
            _ = try await awaitingAuthLimit { try await deletedClient.entitlements() }
        }
    }

    // Çevrimdışı kayıt → bağlantı gelince işlenir: sunucuya ulaşılamazken (kapalı kapı, erişim jetonunun süresi de
    // dolmuş) toplantı başlatma gerçek URLSession hatasıyla "çevrimdışı" sayılır, oturum düşmez ve son hak durumunun
    // izni kayda süre verir. Aynı Mac'te başka hesap açılınca kayıt o hesapla işlenmez. Bağlantı gelince (uygulama
    // yeniden açılmış gibi yeni istemci, aynı jeton deposu) kayıt kendi kimliğiyle ertelenmiş oturum açar, yinelenen
    // açılış aynı oturumu döndürür, süren canlı toplantı kapanmaz ve deneme yalnızca sahibinden bir kez düşer.
    @Test func offlineRecordingIsProcessedWhenBackOnlineAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        try resetLocalTrialStarts()
        let owner: SignedInUser = try await signedInUser(baseURL: baseURL)
        let lastKnown: HostedEntitlements = try await owner.client.entitlements()
        let permit: HostedOfflinePermit = try #require(hostedOfflinePermit(entitlements: lastKnown, now: Date(), maxAgeSec: hostedOfflinePermitMaxAgeSec))
        let live: HostedStartedMeeting = try await owner.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: "canli-\(UUID().uuidString.lowercased())", deferred: false)

        // Sunucuya ulaşılamıyor; erişim jetonu da bitmiş (yenileme de ağa çıkmalı).
        let stored: HostedTokens = try #require(try owner.storage.load())
        try owner.storage.save(tokens: HostedTokens(accessToken: stored.accessToken, refreshToken: stored.refreshToken, accessExpiresAt: Date.distantPast, userId: stored.userId))
        let endedSessions: SessionEndCounter = SessionEndCounter()
        let offline: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: try parseHostedBaseURL(value: "http://127.0.0.1:1"), storage: owner.storage) { () async -> Void in
            endedSessions.count.withLock { $0 += 1 }
        }
        let recordID: String = "kayit-\(UUID().uuidString.lowercased())"
        do {
            _ = try await offline.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: false)
            Issue.record("Kapalı kapıya başlatma başarılı olmamalı")
        } catch {
            #expect(isOfflineStartError(error: error), "Ulaşılamayan sunucu çevrimdışı kayda düşmeli: \(error)")
        }
        #expect(try await offline.isSignedIn())
        #expect(endedSessions.count.withLock { $0 } == 0)
        #expect(try owner.storage.load()?.refreshToken == stored.refreshToken)
        #expect(hostedOfflineRecordingMinutes(permit: permit, userId: try owner.storage.load()?.userId, now: Date()) == permit.maxMinutes)

        // Aynı Mac'te başka hesap: kayıt onun kuyruğunda değil, onun denemesi düşmez.
        let other: SignedInUser = try await signedInUser(baseURL: baseURL)
        let otherBefore: HostedEntitlements = try await other.client.entitlements()
        let owners: [String: String] = [recordID: owner.userID]
        let asOther: HostedQueuedRecords = hostedQueuedRecords(records: [queuedRecord(id: recordID)], owners: owners, userId: other.userID)
        #expect(asOther.own.isEmpty)
        #expect(asOther.foreign.map(\.id) == [recordID])

        // Bağlantı geldi: sahibinin kuyruğunda; ertelenmiş oturum açılır, yinelenen açılış aynı oturumu döndürür.
        let online: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: owner.storage) { () async -> Void in }
        let asOwner: HostedQueuedRecords = hostedQueuedRecords(records: [queuedRecord(id: recordID)], owners: owners, userId: try #require(try await online.signedInUserID()))
        #expect(asOwner.own.map(\.id) == [recordID])
        let queued: HostedStartedMeeting = try await awaitingAuthLimit {
            try await online.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        }
        #expect(queued.meetingId != live.meetingId)
        _ = try await online.endMeeting(meetingID: queued.meetingId)
        let repeated: HostedStartedMeeting = try await online.startMeeting(device: nil, deviceCheckToken: nil, clientRef: recordID, deferred: true)
        #expect(repeated.meetingId == queued.meetingId)
        #expect(try localMeetingIsEnded(meetingID: live.meetingId) == false, "Ertelenmiş kayıt süren canlı toplantıyı kapatmamalı")
        #expect(try localMeetingIsEnded(meetingID: queued.meetingId))
        let ownerAfter: HostedEntitlements = try await online.entitlements()
        #expect(ownerAfter.trialMeetingsLeft == lastKnown.trialMeetingsLeft - 2)
        #expect(try await other.client.entitlements().trialMeetingsLeft == otherBefore.trialMeetingsLeft)
        _ = try await online.endMeeting(meetingID: live.meetingId)
    }

    // Screen snapshots in notes through the real client and server: the app's own pipeline (6 slides on disk →
    // `screenNoteImages`) passes the server's caps and the raised body limit (the local server's fake Anthropic key then
    // rejects upstream, or a real one answers); one image too many, or images on a purpose that may not carry them, are
    // refused with `screen_images_over_limit` before any upstream call (Ask may carry images, editing a note may not).
    @Test func screenNoteImagesAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        let meeting: URL = try temporaryDirectory()
        for index in 0..<7 {
            try writeTestSlide(meetingDirectory: meeting, offsetSec: Double(index) * 30 + 5, index: index + 1, width: 1600, height: 1000)
        }
        let record: MeetingRecord = screenNotesMeeting(seconds: 240)
        let images: [LLMImage] = try screenNoteImages(record: record, meetingDirectory: meeting, budget: screenNoteBudget, policy: screenSnapshotPolicy)
        #expect(images.count == screenNoteBudget.maxImages)
        let provider: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: user.client, scope: .recordedMeeting(serverMeetingID: started.meetingId)))
        let note: LLMRequest = try #require(meetingNoteRequest(
            segments: record.liveSegments, speakerNames: [:], userName: "Doğan", profile: .empty, template: .general, myNotes: "", language: .turkish, screens: images
        ))
        do {
            _ = try await sendLLM(provider: provider, request: note)
        } catch LLMError.hosted(let error) {
            #expect(error.code == .upstreamRejected || error.code == .upstreamUnavailable, "\(error)")
        }
        let first: LLMImage = try #require(images.first)
        let tooMany: LLMRequest = try #require(meetingNoteRequest(
            segments: record.liveSegments, speakerNames: [:], userName: "Doğan", profile: .empty, template: .general, myNotes: "", language: .turkish,
            screens: images + [first]
        ))
        let overCount: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: provider, request: tooMany) }
        #expect(overCount?.code == .screenImagesOverLimit && overCount?.status == 413)
        if let overCount {
            #expect(!isRetryableHostedError(error: overCount))
        }
        let wrongPurpose: LLMRequest = LLMRequest(
            purpose: .noteEdit, tier: .smart, system: "s", userText: "u", maxTokens: 1000, jsonSchema: nil, timeoutSec: 30, images: [first], webSearch: nil
        )
        let refused: HostedAPIError? = await hostedError { _ = try await sendLLM(provider: provider, request: wrongPurpose) }
        #expect(refused?.code == .screenImagesOverLimit)
    }
}

/// Sahte üst servislerle (Anthropic, ElevenLabs) uçtan uca deneme yalnızca açıkça istenirse: `AINOTEPAD_HOSTED_E2E=1`,
/// `AINOTEPAD_HOSTED_UPSTREAM_STUB=1` ve sunucu `wrangler dev --var UPSTREAM_STUB_URL:http://127.0.0.1:<port>` ile, sahte
/// servis `node scripts/fake-upstreams.ts <port>` ile çalışıyor olmalı (bkz. AGENTS.md). Ücretli çağrı yapılmaz.
let hostedUpstreamStubEnabled: Bool = hostedE2EEnabled && ProcessInfo.processInfo.environment["AINOTEPAD_HOSTED_UPSTREAM_STUB"] == "1"

/// Toplantı oturumunun işleme alanları.
private struct ProcessingRow: Decodable {
    let reprocess_count: Int
    let tokens_used: Int
    let audio_seconds: Double
}

/// Yerel D1'deki toplantının işleme alanları.
private func processingRow(meetingID: String) throws -> ProcessingRow {
    try #require(try localD1Rows(sql: "SELECT reprocess_count, tokens_used, audio_seconds FROM meeting_sessions WHERE id = '\(meetingID)';", as: ProcessingRow.self).first)
}

/// `ended_at` satırı.
private struct EndedAtRow: Decodable {
    let ended_at: Int?
}

/// Henüz bitmemiş toplantıyı `durationMs` sürmüş ve `endedAgoMs` önce bitmiş gibi bitirir; üretimdeki yolla: kaydın
/// başı ve en çok bitişi geçmişe alınır (toplantının süresi geçmiş olur), `/end` bitişi bir kez `max_ends_at` olarak
/// yazar (uygulama süresi geçmiş toplantıyı sonradan bitirdi). Bitmiş toplantının bitişi bir daha değişmez (göç 0057).
private func endMeetingInThePast(client: HostedClient, meetingID: String, durationMs: Int, endedAgoMs: Int) async throws {
    let endMs: Int = nowMs() - endedAgoMs
    try executeLocalD1(sql: "UPDATE meeting_sessions SET started_at = \(endMs - durationMs), max_ends_at = \(endMs) WHERE id = '\(meetingID)' AND ended_at IS NULL;")
    _ = try await client.endMeeting(meetingID: meetingID)
    let row: EndedAtRow = try #require(try localD1Rows(sql: "SELECT ended_at FROM meeting_sessions WHERE id = '\(meetingID)';", as: EndedAtRow.self).first)
    #expect(row.ended_at == endMs)
}

/// Yeniden işleme açıklığını `ms` kadar geçmişe taşır (toplantı o kadar önce yeniden işlemeye açılmış gibi).
private func ageReprocessWindow(meetingID: String, ms: Int) throws {
    try executeLocalD1(sql: "UPDATE meeting_sessions SET reprocess_until = reprocess_until - \(ms) WHERE id = '\(meetingID)' AND reprocess_until IS NOT NULL;")
}

/// `llm_purpose_usage`'tan bir amacın toplam çağrı sayısı.
private struct PurposeCallsRow: Decodable {
    let calls: Int?
}

/// Son geçişi bitmiş, notu henüz yazılmamış toplantı (iPhone'da "Hazırlanıyor"da askıya alınmış kayıt).
private func transcribedRecord(id: String) -> MeetingRecord {
    MeetingRecord(
        id: id, title: "Toplantı", startedAt: Date(), endedAt: Date(), language: .finnish, status: .processing, failureMessage: nil,
        liveSegments: [], finalSegments: [
            StoredSegment(key: "final-0", speaker: .others, person: 1, startSec: 0, endSec: 4, text: "Hyvää huomenta, aloitetaan viikkopalaveri.", words: nil),
            StoredSegment(key: "final-1", speaker: .others, person: 2, startSec: 5, endSec: 9, text: "Budjetti on valmis ja menee hallitukselle perjantaina.", words: nil),
        ],
        translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

// Uzun ya da askıya alınmış toplantının notu kullanıcı bir şey yapmadan tamamlanır (2026-11-04 TestFlight hatası: 31
// dakikalık toplantının notu 32 dk sonra istendi, sunucunun 30 dk'lık ek süresi kapanmıştı).
@Suite(.enabled(if: hostedUpstreamStubEnabled), .serialized) struct HostedLongMeetingE2ETests {
    // Kayıt bitti, not ek süreden (30 dk) sonra istendi: düzgün biten toplantı işleme süresinde (24 saat) açık; not
    // yeniden işleme hakkı harcanmadan yazılır ve kullanım toplantıya sayılır.
    @Test func noteRequestedAfterGraceCompletesWithoutReprocess() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        try await endMeetingInThePast(client: user.client, meetingID: started.meetingId, durationMs: 60_000, endedAgoMs: 32 * 60_000)
        let directory: URL = try temporaryDirectory()
        let provider: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: user.client, scope: .recordedMeeting(serverMeetingID: started.meetingId)))
        let result: MeetingRecord = await regenerateNote(
            record: transcribedRecord(id: directory.lastPathComponent), directory: directory, llm: provider, userName: "Doğan", profile: .empty, language: .turkish, screens: .off
        )
        #expect(result.status == .done, "hata: \(result.failureMessage ?? "")")
        #expect(result.note != nil)
        let row: ProcessingRow = try processingRow(meetingID: started.meetingId)
        #expect(row.reprocess_count == 0)
        #expect(row.tokens_used > 0)
    }

    // Kayıt bitti, not işleme süresinden (24 saat) de sonra istendi (uygulama günlerce açılmadı): istemci toplantıyı
    // kendiliğinden yeniden işlemeye açar (bir hak), not yazılır.
    @Test func noteRequestedAfterProcessingWindowReopensAutomatically() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        try await endMeetingInThePast(client: user.client, meetingID: started.meetingId, durationMs: 60_000, endedAgoMs: 25 * 3_600_000)
        let directory: URL = try temporaryDirectory()
        let provider: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: user.client, scope: .recordedMeeting(serverMeetingID: started.meetingId)))
        let result: MeetingRecord = await regenerateNote(
            record: transcribedRecord(id: directory.lastPathComponent), directory: directory, llm: provider, userName: "Doğan", profile: .empty, language: .turkish, screens: .off
        )
        #expect(result.status == .done, "hata: \(result.failureMessage ?? "")")
        #expect(result.note != nil)
        #expect(try processingRow(meetingID: started.meetingId).reprocess_count == 1)
    }

    // Toplantı sonu çevirisi: son geçiş transkripti kaydın kendi oturumuyla (işleme amacı `transcript_translation`,
    // ek süreden sonra da) parça parça çevrilir ve toplantının bütçesine sayılır; çevrilemeyen parçanın "Tekrar dene"si
    // hesaptan gider. Sahte Anthropic her `<parca>` için bir çeviri döndürür.
    @Test func transcriptTranslationRunsOnTheMeetingAndRetriesFromTheAccount() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        try await endMeetingInThePast(client: user.client, meetingID: started.meetingId, durationMs: 60_000, endedAgoMs: 32 * 60_000)
        let watched: MeetingRecord = transcribedRecord(id: UUID().uuidString).with(translations: ["others-0": "canlı"])
        let provider: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: user.client, scope: .recordedMeeting(serverMeetingID: started.meetingId)))
        let translated: MeetingRecord = await translatingTranscript(record: watched, llm: provider, language: .turkish, userName: "Doğan")
        #expect(translated.failedTranslationKeys == nil)
        #expect(translated.translations["final-0"] == "Uçtan uca çeviri 1")
        #expect(translated.translations["final-1"] == "Uçtan uca çeviri 2")
        let row: ProcessingRow = try processingRow(meetingID: started.meetingId)
        #expect(row.reprocess_count == 0 && row.tokens_used > 0)
        let account: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: user.client, scope: .account))
        let retried: MeetingRecord = await retryingFailedTranscriptTranslations(
            record: watched.with(failedTranslationKeys: ["final-1"]), llm: account, language: .turkish, userName: "Doğan"
        )
        #expect(retried.failedTranslationKeys == nil)
        #expect(retried.translations["final-1"] == "Uçtan uca çeviri 1")
        let calls: [PurposeCallsRow] = try localD1Rows(sql: "SELECT SUM(calls) AS calls FROM llm_purpose_usage WHERE purpose = 'transcript_translation';", as: PurposeCallsRow.self)
        #expect((calls.first?.calls ?? 0) >= 2)
    }

    // Son geçiş işleme süresinden (24 saat) sonra da yapılabilir: toplantı kendiliğinden yeniden açılır; parça ilerlemesi
    // kaydedilir ve aynı kayıt yeniden işlenince (uygulama işleme sırasında kapandı) tamamlanan parça yeniden yüklenmez
    // (ses bir kez sayılır). Yeniden işleme açıklığı da geçince sesi sayılmış toplantı bir kez daha açılır.
    @Test func finalPassAfterGraceResumesWithoutDoubleBilling() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let started: HostedStartedMeeting = try await user.client.startMeeting(device: nil, deviceCheckToken: nil, clientRef: UUID().uuidString.lowercased(), deferred: false)
        // Kayıt 10 dakika sürmüş olsun (ses toplantının gerçek süresini aşamaz).
        try await endMeetingInThePast(client: user.client, meetingID: started.meetingId, durationMs: 600_000, endedAgoMs: 25 * 3_600_000)
        let directory: URL = try temporaryDirectory()
        let others: CafRecorder = try CafRecorder(fileURL: directory.appending(path: "others.caf"))
        try others.append(samples: silence(seconds: 3))
        others.close()
        let transcriber: HostedFinalTranscriber = HostedFinalTranscriber(client: user.client, meetingID: started.meetingId, keyterms: [])
        let first: FinalPassResult = try await transcriber.transcribeFinal(audioURL: directory.appending(path: "others.caf"), languageMode: .fixed(.finnish))
        #expect(!first.segments.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "final-pass-others.json").path))
        let afterFirst: ProcessingRow = try processingRow(meetingID: started.meetingId)
        #expect(afterFirst.audio_seconds > 0)
        #expect(afterFirst.reprocess_count == 1)
        // Uygulama son geçişin sonucu saklanmadan kapandı: aynı kayıt yeniden işlenir, parça önceki yanıttan alınır.
        let resumed: FinalPassResult = try await transcriber.transcribeFinal(audioURL: directory.appending(path: "others.caf"), languageMode: .fixed(.finnish))
        #expect(resumed.segments.map(\.text) == first.segments.map(\.text))
        #expect(try processingRow(meetingID: started.meetingId).audio_seconds == afterFirst.audio_seconds)
        // Yeniden işleme açıklığı da geçti: yükleme `meeting_not_active` alır, toplantı yeniden açılır ve son geçiş tamamlanır.
        try removeFinalPassProgress(directory: directory)
        try ageReprocessWindow(meetingID: started.meetingId, ms: 25 * 3_600_000)
        let reopened: FinalPassResult = try await transcriber.transcribeFinal(audioURL: directory.appending(path: "others.caf"), languageMode: .fixed(.finnish))
        #expect(!reopened.segments.isEmpty)
        #expect(try processingRow(meetingID: started.meetingId).reprocess_count == 2)
    }
}

/// Kullanıcının bu ayki web araması sayısı (yerel D1).
private struct WebSearchRow: Decodable {
    let web_searches: Int
}

/// Sor'da web araması abonelik sunucusundan uçtan uca (sahte Anthropic bir arama yapar ve sayfayı alıntılar): cevapta web
/// kaynağı `[w1]` olarak görünür, arama kullanıcının aylık sayacına yazılır; hak bitince araç sunulmaz ve istemci bunu bilir.
@Suite(.enabled(if: hostedUpstreamStubEnabled), .serialized) struct HostedAskWebSearchE2ETests {
    @Test func askAnswerSearchesTheWebAndCountsIt() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let provider: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: user.client, scope: .account))
        let record: MeetingRecord = transcribedRecord(id: UUID().uuidString)
        let queries: LockedQueries = LockedQueries()
        let answer: ArchiveAnswer = try await askAboutMeetings(
            question: "Haiku 5.5 ne kadar?", history: [], records: [record], userName: "Doğan", profile: .empty, noteLanguage: .turkish, answerLanguage: .turkish, llm: provider, maxChars: 60_000,
            screens: .off, webSearch: true, now: Date()
        ) { (progress: ArchiveProgress) -> Void in
            if case .web(let found, let notice) = progress {
                queries.set(found, notice: notice)
            }
        }
        #expect(answer.webSources == [WebSource(url: "https://example.com/haiku-pricing", title: "Example pricing page")])
        #expect(answer.text.contains("[w1]"), "\(answer.text)")
        #expect(!answer.text.contains("Searching the web"), "ön söz cevaba girmemeli: \(answer.text)")
        #expect(queries.value.queries == ["uçtan uca deneme"] && queries.value.notice == .ok)
        let used: [WebSearchRow] = try localD1Rows(sql: "SELECT web_searches FROM monthly_usage WHERE user_id = '\(user.userID)';", as: WebSearchRow.self)
        #expect(used.map(\.web_searches) == [1])

        // Aylık hak bitti: araç sunulmaz, cevap yalnız toplantılardan, istemci bunu bilir.
        try executeLocalD1(sql: "UPDATE monthly_usage SET web_searches = 100 WHERE user_id = '\(user.userID)';")
        let capped: LockedQueries = LockedQueries()
        let plain: ArchiveAnswer = try await askAboutMeetings(
            question: "Haiku 5.5 ne kadar?", history: [], records: [record], userName: "Doğan", profile: .empty, noteLanguage: .turkish, answerLanguage: .turkish, llm: provider, maxChars: 60_000,
            screens: .off, webSearch: true, now: Date()
        ) { (progress: ArchiveProgress) -> Void in
            if case .web(let found, let notice) = progress {
                capped.set(found, notice: notice)
            }
        }
        #expect(plain.webSources.isEmpty && !plain.text.contains("[w"))
        #expect(capped.value.notice == .capReached)
    }

    // Anthropic kuruluşta web aramasını reddederse (sahte servis soruda `fakeWebSearchDisabledMarker` görünce 400 döner):
    // sunucu isteği araçsız yineler, cevap gelir, hak geri verilir ve istemci "web araması şu an yok" notunu alır.
    @Test func rejectedWebSearchStillAnswersWithNotice() async throws {
        let baseURL: URL = try localServerBase()
        let user: SignedInUser = try await signedInUser(baseURL: baseURL)
        try markTrialStarted(userID: user.userID, usedMeetings: 1, startedAtMs: nowMs())
        let provider: LLMProvider = .hosted(HostedLLMConfig(baseURL: baseURL, credentials: user.client, scope: .account))
        let record: MeetingRecord = transcribedRecord(id: UUID().uuidString)
        let states: LockedQueries = LockedQueries()
        let answer: ArchiveAnswer = try await askAboutMeetings(
            question: "Haiku 5.5 ne kadar? \(fakeWebSearchDisabledMarker)", history: [], records: [record], userName: "Doğan", profile: .empty, noteLanguage: .turkish, answerLanguage: .turkish, llm: provider,
            maxChars: 60_000, screens: .off, webSearch: true, now: Date()
        ) { (progress: ArchiveProgress) -> Void in
            if case .web(let found, let notice) = progress {
                states.set(found, notice: notice)
            }
        }
        #expect(!answer.text.isEmpty && answer.webSources.isEmpty)
        #expect(states.value.notice == .unavailable)
        let used: [WebSearchRow] = try localD1Rows(sql: "SELECT web_searches FROM monthly_usage WHERE user_id = '\(user.userID)';", as: WebSearchRow.self)
        #expect(used.map(\.web_searches).reduce(0, +) == 0)
    }
}

/// Sahte Anthropic'in (`server/scripts/fake-upstreams.ts`) "kuruluşta web araması kapalı" 400'ünü döndürdüğü soru işareti.
private let fakeWebSearchDisabledMarker: String = "[fake:web-search-disabled]"

/// İlerlemedeki son web durumu (testte eşzamanlı erişim için kilitli).
private final class LockedQueries: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var stored: (queries: [String], notice: WebSearchNotice) = ([], .ok)

    func set(_ queries: [String], notice: WebSearchNotice) {
        lock.lock()
        stored = (queries, notice)
        lock.unlock()
    }

    var value: (queries: [String], notice: WebSearchNotice) {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

#endif
