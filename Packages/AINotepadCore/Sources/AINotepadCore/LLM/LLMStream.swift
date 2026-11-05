import Foundation
import os

/// Akışlı yanıtta o ana kadar görünen metin (tamamı, parça değil); arayüz her çağrıda metni yeniler.
public typealias LLMTextHandler = @Sendable (String) async -> Void

private let streamLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "LLM")
private let streamAttempts: Int = 3

/// Akışta gösterilecek metin: baştaki `<think>…</think>` bölümü (akıl yürüten yerel modeller) bitene kadar boş, sonra
/// bölümün ardı. Etiketin yarısı gelmişken ("<thi") de boş (düşünme metni bir anlığına görünmesin). Saf fonksiyondur.
public func visibleStreamText(accumulated: String) -> String {
    let trimmed: String = String(accumulated.drop { $0.isWhitespace })
    if "<think>".hasPrefix(trimmed) {
        return ""
    }
    guard trimmed.hasPrefix("<think>") else {
        return trimmed
    }
    guard let end = trimmed.range(of: "</think>") else {
        return ""
    }
    return String(trimmed[end.upperBound...].drop { $0.isWhitespace })
}


/// İsteği akışla (SSE) gönderir: metin geldikçe `onText` o ana kadarki görünen metinle çağrılır; bitince tüm akış
/// sağlayıcının kurallarıyla doğrulanır (kesilme, reddetme, yarım akış hata) ve tam metin döner. Metin görünmeye
/// başlamadan önceki 408/429/5xx/ağ hataları 3 deneme (uyarı logu); metin göründükten sonraki hata yeniden denenmez
/// (kullanıcı yarım cevabı görmüştür), fırlatılır.
public func streamLLM(provider: LLMProvider, request: LLMRequest, onText: LLMTextHandler) async throws -> String {
    switch provider {
    case .anthropic(let config):
        return try await streamPreparedText(call: try prepareClaudeCall(config: config, request: request), textDelta: claudeTextDelta, onText: onText)
    case .openAICompatible(let config):
        try requireNoWebSearch(request: request, provider: "OpenAI-compatible")
        return try await streamPreparedText(call: try prepareOpenAIStreamCall(config: config, request: request), textDelta: openAITextDelta, onText: onText)
    case .onDevice(let config):
        try requireNoWebSearch(request: request, provider: "Apple Intelligence")
        guard #available(macOS 26.0, *) else {
            throw OnDeviceLLMError.unavailable(reason: .requiresNewerSystem)
        }
        return try await streamOnDevice(config: config, request: request, onText: onText)
    case .hosted(let config):
        // Sunucu Anthropic'in akış olaylarını aynen iletir. Jeton 401 ile reddedilirse (metin görünmeden) bir kez
        // yenilenip yeniden denenir.
        return try await withHostedTokenRefresh(config: config) { () async throws -> String in
            try await streamPreparedText(call: try await prepareHostedCall(config: config, request: request), textDelta: claudeTextDelta, onText: onText)
        }
    }
}

/// Akışlı cevabın her güncellemesi (o ana kadarki cevap).
public typealias LLMAnswerHandler = @Sendable (LLMAnswer) async -> Void

/// Sor cevabı gibi web aramalı olabilen istek: Claude'da (kendi anahtarla ya da abonelik sunucusu) akış olayları
/// cevaba (`claudeAnswer`: metin, `[wN]` web alıntıları, arama sorguları) işlenir ve her değişiklikte `onUpdate` çağrılır;
/// diğer sağlayıcılarda `streamLLM` metni web kaynaksız cevap olur (istek web araması taşıyamaz). Yeniden deneme ve
/// doğrulama kuralları `streamLLM`'deki gibidir.
public func streamLLMAnswer(provider: LLMProvider, request: LLMRequest, onUpdate: LLMAnswerHandler) async throws -> LLMAnswer {
    switch provider {
    case .anthropic(let config):
        do {
            return try await streamPreparedAnswer(call: try prepareClaudeCall(config: config, request: request), onUpdate: onUpdate)
        } catch where request.webSearch != nil && isWebSearchDisabledError(error: error) {
            // Kuruluşta web araması kapalı (Console): sunucudaki güvenceyle aynı, istek bir kez araçsız yinelenir ve cevabın
            // altında "web araması şu an yok" notu çıkar (soru cevapsız kalmaz). 400 metin görünmeden gelir.
            streamLogger.warning("Anthropic web aramasını reddetti (kuruluşta kapalı), soru araçsız yineleniyor")
            let answer: LLMAnswer = try await streamPreparedAnswer(call: try prepareClaudeCall(config: config, request: withoutWebSearch(request: request)), onUpdate: onUpdate)
            return LLMAnswer(text: answer.text, webSources: answer.webSources, webQueries: answer.webQueries, webSearchNotice: .unavailable)
        }
    case .hosted(let config):
        return try await withHostedTokenRefresh(config: config) { () async throws -> LLMAnswer in
            try await streamPreparedAnswer(call: try await prepareHostedCall(config: config, request: request), onUpdate: onUpdate)
        }
    case .openAICompatible, .onDevice:
        let text: String = try await streamLLM(provider: provider, request: request) { (partial: String) -> Void in
            await onUpdate(LLMAnswer(text: partial, webSources: [], webQueries: [], webSearchNotice: .ok))
        }
        return LLMAnswer(text: text, webSources: [], webQueries: [], webSearchNotice: .ok)
    }
}

/// Aynı istek, web araması aracı olmadan. Saf fonksiyondur.
func withoutWebSearch(request: LLMRequest) -> LLMRequest {
    LLMRequest(
        purpose: request.purpose, tier: request.tier, system: request.system, userText: request.userText, maxTokens: request.maxTokens,
        jsonSchema: request.jsonSchema, timeoutSec: request.timeoutSec, images: request.images, webSearch: nil
    )
}

/// Metin akışı: her metin parçası birikir, görünen metin (`visibleStreamText`) boş değilse gösterilir.
private func streamPreparedText(call: PreparedLLMCall, textDelta: @escaping @Sendable (Substring) -> String?, onText: LLMTextHandler) async throws -> String {
    let streamed: StreamedCall<String> = try await streamPreparedCall(call: call, initial: "") { (accumulated: String, line: Substring) -> (state: String, changed: Bool) in
        guard let delta = textDelta(line) else {
            return (accumulated, false)
        }
        return (accumulated + delta, true)
    } onChange: { (accumulated: String) -> Bool in
        let visible: String = visibleStreamText(accumulated: accumulated)
        guard !visible.isEmpty else {
            return false
        }
        await onText(visible)
        return true
    }
    return streamed.text
}

/// Cevap akışı (Claude olayları): bloklar `consumeClaudeAnswerLine` ile işlenir; metin ya da arama değişince
/// `onUpdate`. Sonuç doğrulanmış akışın durumudur; abonelik sunucusu aramayı sunamadıysa (hak bitti, kapalı) bunu
/// başlıkla söyler (`webSearchNotice(header:)`).
private func streamPreparedAnswer(call: PreparedLLMCall, onUpdate: LLMAnswerHandler) async throws -> LLMAnswer {
    let streamed: StreamedCall<ClaudeAnswerState> = try await streamPreparedCall(call: call, initial: ClaudeAnswerState(blocks: [:])) { (state: ClaudeAnswerState, line: Substring) -> (state: ClaudeAnswerState, changed: Bool) in
        consumeClaudeAnswerLine(state: state, line: line)
    } onChange: { (state: ClaudeAnswerState) -> Bool in
        let answer: LLMAnswer = claudeAnswer(state: state, headerNotice: .ok)
        guard !answer.text.isEmpty || !answer.webQueries.isEmpty else {
            return false
        }
        await onUpdate(answer)
        return !answer.text.isEmpty
    }
    let answer: LLMAnswer = claudeAnswer(state: streamed.state, headerNotice: webSearchNotice(header: streamed.webSearchHeader))
    guard !answer.text.isEmpty else {
        throw LLMError.empty
    }
    return answer
}

/// Doğrulanmış akışın sonucu: sağlayıcının tam metni, akıştan kurulan durum ve abonelik sunucusunun arama durumu
/// başlığı (`x-web-search`).
private struct StreamedCall<State: Sendable>: Sendable {
    let text: String
    let state: State
    let webSearchHeader: String?
}

/// Hazırlanmış akış çağrısını gönderir: her satır `step` ile duruma işlenir, durum değişince `onChange` (kullanıcıya bir
/// şey gösterdiyse true döner). Metin görünmeden önceki 408/429/5xx/ağ hataları 3 deneme (`retry-after`'a uyarak, uyarı
/// logu); göründükten sonraki hata fırlatılır. Bitince akışın tamamı `call.classify` ile doğrulanır.
private func streamPreparedCall<State: Sendable>(
    call: PreparedLLMCall, initial: State, step: @Sendable (State, Substring) -> (state: State, changed: Bool), onChange: (State) async -> Bool
) async throws -> StreamedCall<State> {
    var lastError: any Error = LLMError.empty
    for attempt in 1...streamAttempts {
        var retryAfter: String?
        var shown: Bool = false
        do {
            let (bytes, response): (URLSession.AsyncBytes, URLResponse) = try await URLSession.shared.bytes(for: call.urlRequest)
            let http: HTTPURLResponse? = response as? HTTPURLResponse
            let status: Int = http?.statusCode ?? 0
            let requestID: String? = http?.value(forHTTPHeaderField: call.requestIDHeader)
            var raw: Data = Data()
            var state: State = initial
            for try await line in bytes.lines {
                raw.append(Data((line + "\n").utf8))
                guard (200..<300).contains(status) else {
                    continue
                }
                let next: (state: State, changed: Bool) = step(state, Substring(line))
                state = next.state
                if next.changed, await onChange(state) {
                    shown = true
                }
            }
            switch call.classify(status, raw, requestID) {
            case .success(let text):
                return StreamedCall(text: text, state: state, webSearchHeader: http?.value(forHTTPHeaderField: "x-web-search"))
            case .final(let error):
                throw error
            case .retryable(let error):
                guard !shown else {
                    throw error
                }
                lastError = error
                retryAfter = http?.value(forHTTPHeaderField: "retry-after")
            }
        } catch let error as URLError where error.code != .cancelled && !shown {
            lastError = error
        }
        try Task.checkCancellation()
        // Hata gövdesi toplantı metni içerebilir: yalnızca özel (private) loglanır.
        streamLogger.warning("LLM akışı başarısız, deneme: \(attempt, privacy: .public), model: \(call.model, privacy: .public), hata: \(String(describing: lastError), privacy: .private)")
        if attempt < streamAttempts {
            try await Task.sleep(for: .seconds(retryDelay(retryAfterHeader: retryAfter, attempt: attempt)))
        }
    }
    throw lastError
}
