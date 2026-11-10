import Foundation
import os

private let hostedLLMLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedLLM")

/// Sunucunun kullandığı tek model (sunucuda sabittir; istemci model göndermez).
public let hostedModelName: String = "claude-haiku-5-5"

/// Sunucunun çağrı başı `max_tokens` sınırları (`server/wrangler.jsonc` `LLM_MAX_TOKENS`, `LLM_ACCOUNT_MAX_TOKENS`):
/// toplantıya bağlı çağrı ve hesap çağrısı. İstek bunları aşmaz (sunucu zaten kırpar; istemci tahminini sınırla aynı
/// tutar, kesilme mesajı yanıltmasın).
public let hostedMeetingMaxTokens: Int = 8192
public let hostedAccountMaxTokens: Int = 6144
/// Sor cevabının (`ask_answer`) hesap çağrısı sınırı (`LLM_ASK_MAX_TOKENS`): uzun yapılandırılmış cevaplar (plan, tablo,
/// hazır istem) kesilmesin.
public let hostedAskAnswerMaxTokens: Int = 8192

/// Yapay zekâ çağrısının kimliği: erişim jetonu ve (toplantıya bağlı çağrıda) toplantı oturumu; hesap çağrısında nil.
public struct HostedLLMCredentials: Sendable, Equatable {
    public let accessToken: String
    public let meetingID: String?

    public init(accessToken: String, meetingID: String?) {
        self.accessToken = accessToken
        self.meetingID = meetingID
    }
}

/// Çağrı anında geçerli jetonu ve açık toplantıyı veren kaynak (bkz. `HostedClient`).
public protocol HostedLLMCredentialSource: AnyObject, Sendable {
    /// Her isteğe eklenen sürüm başlıkları (bkz. `HostedClientInfo`).
    nonisolated var clientInfo: HostedClientInfo { get }
    /// Geçerli (gerekirse yenilenmiş) erişim jetonu ve son açılan toplantı; giriş yoksa `notSignedIn`, toplantı yoksa
    /// `noActiveMeeting`.
    func meetingLLMCredentials() async throws -> HostedLLMCredentials
    /// Geçerli (gerekirse yenilenmiş) erişim jetonu; giriş yoksa `notSignedIn`.
    func validAccessToken() async throws -> String
    /// Sunucu `rejected` jetonunu 401 ile reddettiyse yinelemenin jetonu (bkz. `HostedClient.accessToken(afterRejecting:)`);
    /// jeton önceki bir oturumunsa `notSignedIn`, oturum kapandıysa `sessionEnded`.
    func accessToken(afterRejecting rejected: String) async throws -> String
    /// Kaydı bitmiş toplantıyı işleme için yeniden açar (`POST /v1/meetings/{id}/reprocess`; bkz.
    /// `withRecordedMeetingReopen`). Sınır dolduysa `reprocess_limit_reached`.
    func reopenRecordedMeeting(meetingID: String) async throws
    /// Throws `HostedClientError.aiConsentRequired` unless the user agreed to the AI disclosure (see `HostedAIConsent.swift`).
    func requireAIConsent() async throws
}

/// Çağrının sunucudaki bütçesi.
public enum HostedLLMScope: Sendable, Equatable {
    /// Kayıt sırasındaki istekler (canlı çeviri, "Ne kaçırdım?", toplantı sorusu) ve kaydın hemen ardından not: son
    /// açılan toplantının bütçesinden düşer; toplantı kapanıp ek süre geçince `meeting_not_active`.
    case meeting
    /// Kaydı bitmiş belirli bir toplantının istekleri (kaydın ardından not): o toplantının sunucu oturumunun bütçesinden
    /// düşer; bu arada yeni bir kayıt başlasa da onun bütçesine yazılmaz.
    case recordedMeeting(serverMeetingID: String)
    /// Her zaman kullanılabilen istekler (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı):
    /// toplantı kimliği gönderilmez; sunucu abonelik ya da kalan deneme ister, kullanıcının sınırlarına sayar.
    case account
}

/// Abonelik sunucusu sağlayıcısı: adres, kimlik kaynağı ve bütçe. Kaynak aynı nesneyse eşittir.
public struct HostedLLMConfig: Sendable, Equatable {
    public let baseURL: URL
    public let credentials: any HostedLLMCredentialSource
    public let scope: HostedLLMScope

    public init(baseURL: URL, credentials: any HostedLLMCredentialSource, scope: HostedLLMScope) {
        self.baseURL = baseURL
        self.credentials = credentials
        self.scope = scope
    }

    public static func == (lhs: HostedLLMConfig, rhs: HostedLLMConfig) -> Bool {
        lhs.baseURL == rhs.baseURL && lhs.credentials === rhs.credentials && lhs.scope == rhs.scope
    }
}

/// İsteğin effort'u: kayıt sırasında beklenen istekler (canlı çeviri, "Ne kaçırdım?", toplantı sorusu, arama terimleri)
/// `low`, not yazma ve düzenleme `medium`. Sunucu yalnızca bu ikisini kabul eder. Saf fonksiyondur.
public func hostedEffort(tier: LLMTier) -> LLMEffort {
    switch tier {
    case .fast, .live: .low
    case .smart: .medium
    }
}

/// A content block of the user message: text, or a base64 JPEG image (shared-screen snapshot).
enum HostedContentBlock: Encodable, Equatable {
    case text(String)
    case jpeg(Data)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case source
    }

    private struct ImageSource: Encodable {
        let type: String
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .jpeg(let data):
            try container.encode("image", forKey: .type)
            try container.encode(ImageSource(type: "base64", mediaType: "image/jpeg", data: data.base64EncodedString()), forKey: .source)
        }
    }
}

/// The user message: plain text, or (with images) blocks.
enum HostedMessageContent: Encodable, Equatable {
    case text(String)
    case blocks([HostedContentBlock])

    func encode(to encoder: any Encoder) throws {
        var container: any SingleValueEncodingContainer = encoder.singleValueContainer()
        switch self {
        case .text(let text):
            try container.encode(text)
        case .blocks(let blocks):
            try container.encode(blocks)
        }
    }
}

/// A message of the hosted request.
struct HostedChatMessage: Encodable, Equatable {
    let role: String
    let content: HostedMessageContent
}

/// The user message of a request: text only without images (the body stays as before); with images each image comes
/// after its label and before the text (Claude reads images best before the question). Pure function.
func hostedUserContent(request: LLMRequest) -> HostedMessageContent {
    guard !request.images.isEmpty else {
        return .text(request.userText)
    }
    return .blocks(request.images.flatMap { [HostedContentBlock.text($0.label), .jpeg($0.jpeg)] } + [.text(request.userText)])
}

/// Sunucunun izin verdiği istek gövdesi: zorunlu `effort`, `system`, tek kullanıcı mesajı, `max_tokens`, isteğe bağlı
/// `output_config.format`, `stream` ve (Sor cevabında) web araması aracı. Model, düşünme ve örnekleme alanları gönderilmez.
struct HostedLLMRequestBody: Encodable {
    struct OutputConfig: Encodable {
        let format: ClaudeRequestBody.OutputFormat
    }

    let effort: String
    let system: String
    let messages: [HostedChatMessage]
    let maxTokens: Int
    let outputConfig: OutputConfig?
    let stream: Bool
    /// Sor cevabının web araması (sunucu yalnız tür, ad ve arama sayısını kabul eder; çağrı biçimini kendisi ekler).
    let tools: [WebSearchToolBody]?

    enum CodingKeys: String, CodingKey {
        case effort
        case system
        case messages
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
        case stream
        case tools
    }
}

/// İstek gövdesi; her zaman akışlıdır (Anthropic olayları aynen gelir, `classifyClaudeResponse` ile çözülür). Saf
/// fonksiyondur.
public func hostedLLMRequestBody(request: LLMRequest, effort: LLMEffort, maxTokensCap: Int) throws -> Data {
    let format: ClaudeRequestBody.OutputFormat? = try request.jsonSchema.map { (schemaText: String) throws -> ClaudeRequestBody.OutputFormat in
        ClaudeRequestBody.OutputFormat(type: "json_schema", schema: try parsedSchema(text: schemaText))
    }
    let body: HostedLLMRequestBody = HostedLLMRequestBody(
        effort: effort.rawValue,
        system: request.system,
        messages: [HostedChatMessage(role: "user", content: hostedUserContent(request: request))],
        maxTokens: min(request.maxTokens, maxTokensCap),
        outputConfig: format.map { HostedLLMRequestBody.OutputConfig(format: $0) },
        stream: true,
        tools: request.webSearch.map { (search: LLMWebSearch) -> [WebSearchToolBody] in
            [WebSearchToolBody(type: webSearchToolType, name: "web_search", maxUses: search.maxUses, allowedCallers: nil)]
        }
    )
    return try llmRequestEncoder().encode(body)
}

/// Çağrı başı `max_tokens` sınırı: toplantıya bağlı çağrıda `hostedMeetingMaxTokens`, hesap çağrısında
/// `hostedAccountMaxTokens`, Sor cevabında `hostedAskAnswerMaxTokens` (sunucunun `callMaxTokens`'ı ile aynı). Saf
/// fonksiyondur.
public func hostedMaxTokensCap(purpose: LLMPurpose, isMeetingCall: Bool) -> Int {
    if isMeetingCall {
        return hostedMeetingMaxTokens
    }
    return purpose == .askAnswer ? hostedAskAnswerMaxTokens : hostedAccountMaxTokens
}

/// `POST /v1/llm/messages` isteği: bearer jeton, toplantıya bağlıysa toplantı başlığı (`x-meeting-id`), isteğin özelliği
/// (`x-llm-purpose`; sunucu token kullanımını özellik başına toplar), sürüm başlıkları ve gövde. Saf fonksiyondur.
public func hostedLLMURLRequest(baseURL: URL, credentials: HostedLLMCredentials, clientInfo: HostedClientInfo, request: LLMRequest) throws -> URLRequest {
    var urlRequest: URLRequest = URLRequest(url: baseURL.appending(path: "v1/llm/messages"))
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = request.timeoutSec
    let cap: Int = hostedMaxTokensCap(purpose: request.purpose, isMeetingCall: credentials.meetingID != nil)
    urlRequest.httpBody = try hostedLLMRequestBody(request: request, effort: hostedEffort(tier: request.tier), maxTokensCap: cap)
    urlRequest.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "authorization")
    if let meetingID = credentials.meetingID {
        urlRequest.setValue(meetingID, forHTTPHeaderField: "x-meeting-id")
    }
    urlRequest.setValue(request.purpose.rawValue, forHTTPHeaderField: "x-llm-purpose")
    urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
    return withHostedClientHeaders(request: urlRequest, info: clientInfo)
}

/// Yanıtı sınıflandırır: 2xx gövde Anthropic akışıdır (Claude ile aynı kurallar); başarısız durumda sunucunun hata
/// kodu `LLMError.hosted` olur, geçici olanlar yeniden denenir. Saf fonksiyondur.
public func classifyHostedLLMResponse(status: Int, data: Data, requestID: String?) -> LLMOutcome {
    guard (200..<300).contains(status) else {
        let error: HostedAPIError = parseHostedAPIError(status: status, data: data, path: "/v1/llm/messages")
        return isRetryableHostedError(error: error) ? .retryable(.hosted(error)) : .final(.hosted(error))
    }
    return classifyClaudeResponse(status: status, data: data, model: hostedModelName, requestID: requestID)
}

/// Kaydı bitmiş toplantının çağrısı `meeting_not_active` aldıysa yeniden açılacak toplantı; başka kapsamda ya da başka
/// hatada nil. Saf fonksiyondur.
public func recordedMeetingToReopen(scope: HostedLLMScope, error: any Error) -> String? {
    guard case .recordedMeeting(let meetingID) = scope, case LLMError.hosted(let hosted) = error, hosted.code == .meetingNotActive else {
        return nil
    }
    return meetingID
}

/// Kaydı bitmiş toplantının notu, toplantının sunucu oturumu kapandıktan sonra da yazılır: çağrı `meeting_not_active`
/// alırsa (işleme süresi geçti — uygulama arka planda askıya alındı, kapatıldı ya da çevrimdışı kaldı — ya da toplantı
/// yeni kayıtla kapandı) toplantı bir kez yeniden işlemeye açılır (`reopenRecordedMeeting`; ses yeniden faturalanmaz,
/// toplantının yapay zekâ bütçesi kullanılır) ve çağrı yinelenir. Açılamazsa (sınır doldu, abonelik yok) açma hatası
/// fırlar: kullanıcı gerçek nedeni görür. Her açılış uyarı loglanır.
func withRecordedMeetingReopen(config: HostedLLMConfig, operation: () async throws -> String) async throws -> String {
    do {
        return try await operation()
    } catch {
        guard let meetingID = recordedMeetingToReopen(scope: config.scope, error: error) else {
            throw error
        }
        hostedLLMLogger.warning("Kaydın sunucu oturumu kapanmış, not için yeniden açılıyor, toplantı: \(meetingID, privacy: .public)")
        try await config.credentials.reopenRecordedMeeting(meetingID: meetingID)
        return try await operation()
    }
}

/// Çağrının jetonu ve (toplantıya bağlıysa) toplantısı, çağrı anında (jeton gerekirse yenilenir).
func hostedLLMCredentials(config: HostedLLMConfig) async throws -> HostedLLMCredentials {
    // No AI request without the user's consent (see `HostedAIConsent.swift`).
    try await config.credentials.requireAIConsent()
    return switch config.scope {
    case .meeting:
        try await config.credentials.meetingLLMCredentials()
    case .recordedMeeting(let serverMeetingID):
        HostedLLMCredentials(accessToken: try await config.credentials.validAccessToken(), meetingID: serverMeetingID)
    case .account:
        HostedLLMCredentials(accessToken: try await config.credentials.validAccessToken(), meetingID: nil)
    }
}

/// Abonelik sunucusu çağrısını `credentials` ile hazırlar.
func prepareHostedCall(config: HostedLLMConfig, request: LLMRequest, credentials: HostedLLMCredentials) throws -> PreparedLLMCall {
    PreparedLLMCall(
        urlRequest: try hostedLLMURLRequest(baseURL: config.baseURL, credentials: credentials, clientInfo: config.credentials.clientInfo, request: request),
        model: hostedModelName,
        // Destek için Cloudflare istek kimliği.
        requestIDHeader: "cf-ray"
    ) { (status: Int, data: Data, requestID: String?) -> LLMOutcome in
        classifyHostedLLMResponse(status: status, data: data, requestID: requestID)
    }
}
