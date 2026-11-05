import Foundation
import Testing
@testable import AINotepadCore

/// Sor'da web araması: istek gövdeleri, akıştan cevap (alıntılar, sorgular, ön söz) ve sağlayıcı desteği.
@Suite struct WebSearchTests {
    /// SSE olayı satırı.
    private func event(_ json: String) -> Substring {
        Substring("data: \(json)")
    }

    /// Satırları sırayla duruma işler.
    private func state(lines: [Substring]) -> ClaudeAnswerState {
        lines.reduce(ClaudeAnswerState(blocks: [:])) { (state: ClaudeAnswerState, line: Substring) -> ClaudeAnswerState in
            consumeClaudeAnswerLine(state: state, line: line).state
        }
    }

    // Aramadan önceki kısa ön söz atılır; alıntılı bloğun ardına alan adı sırasıyla [wN] gelir; aynı sayfa aynı numarayı
    // alır; sorgu okunur.
    @Test func answerFromSearchStream() {
        let lines: [Substring] = [
            event(#"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#),
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Webde arayayım."}}"#),
            event(#"{"type":"content_block_stop","index":0}"#),
            event(#"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"s","name":"web_search","input":{}}}"#),
            event(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"query\":"}}"#),
            event(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"haiku fiyat\"}"}}"#),
            event(#"{"type":"content_block_start","index":2,"content_block":{"type":"web_search_tool_result","tool_use_id":"s","content":[]}}"#),
            event(#"{"type":"content_block_start","index":3,"content_block":{"type":"text","text":"Toplantıda bütçe onaylandı [1]. "}}"#),
            event(#"{"type":"content_block_start","index":4,"content_block":{"type":"text","text":"","citations":[]}}"#),
            event(#"{"type":"content_block_delta","index":4,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://www.b.example/p","title":"B","cited_text":"x","encrypted_index":"e"}}}"#),
            event(#"{"type":"content_block_delta","index":4,"delta":{"type":"text_delta","text":"Fiyat 0,10 $"}}"#),
            event(#"{"type":"content_block_start","index":5,"content_block":{"type":"text","text":" ve 0,50 $.","citations":[]}}"#),
            event(#"{"type":"content_block_delta","index":5,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://c.example","title":"C","cited_text":"y","encrypted_index":"e"}}}"#),
            event(#"{"type":"content_block_delta","index":5,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://www.b.example/p","title":"B","cited_text":"z","encrypted_index":"e"}}}"#),
            event(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5,"server_tool_use":{"web_search_requests":1}}}"#),
        ]
        let answer: LLMAnswer = claudeAnswer(state: state(lines: lines), headerNotice: .ok)
        #expect(answer.text == "Toplantıda bütçe onaylandı [1]. Fiyat 0,10 $ [w1] ve 0,50 $. [w2][w1]")
        #expect(answer.webSources == [WebSource(url: "https://www.b.example/p", title: "B"), WebSource(url: "https://c.example", title: "C")])
        #expect(answer.webQueries == ["haiku fiyat"])
        #expect(webSourceDomain(url: "https://www.b.example/p") == "b.example")
        #expect(webSourceDomain(url: "bozuk") == "bozuk")
    }

    // Arama yokken uzun metin ve aramadan önceki uzun metin cevabın parçasıdır; yarım sorgu boş görünür.
    @Test func longTextBeforeSearchStays() {
        let long: String = String(repeating: "Toplantıda konuşulanlar. ", count: 20)
        let lines: [Substring] = [
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":"\#(long)"}}"#),
            event(#"{"type":"content_block_start","index":1,"content_block":{"type":"server_tool_use","id":"s","name":"web_search","input":{}}}"#),
            event(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"que"}}"#),
        ]
        let answer: LLMAnswer = claudeAnswer(state: state(lines: lines), headerNotice: .capReached)
        #expect(answer.text == long.trimmingCharacters(in: .whitespaces))
        #expect(answer.webQueries == [""])
        #expect(answer.webSearchNotice == .capReached)
        #expect(webSearchNotice(header: "cap_reached") == .capReached)
        #expect(webSearchNotice(header: "unavailable") == .unavailable)
        #expect(webSearchNotice(header: "on") == .ok && webSearchNotice(header: nil) == .ok && webSearchNotice(header: "yeni") == .ok)
    }

    // Her arama hatayla döndüyse (web_search_tool_result_error) ve web kaynağı yoksa not "şu an yok" olur; bir arama
    // başarılıysa fazladan aramanın `max_uses_exceeded`'i not değildir; sunucunun başlığı önce gelir.
    @Test func failedSearchesBecomeUnavailableNotice() {
        let failedLines: [Substring] = [
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"s","name":"web_search","input":{}}}"#),
            event(#"{"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"s","content":{"type":"web_search_tool_result_error","error_code":"unavailable"}}}"#),
            event(#"{"type":"content_block_start","index":2,"content_block":{"type":"text","text":"Toplantılara göre bütçe arttı."}}"#),
        ]
        let failed: ClaudeAnswerState = state(lines: failedLines)
        #expect(failed.blocks[1] == .searchResult(errorCode: "unavailable"))
        #expect(claudeAnswer(state: failed, headerNotice: .ok).webSearchNotice == .unavailable)
        #expect(claudeAnswer(state: failed, headerNotice: .capReached).webSearchNotice == .capReached)
        let partlyLines: [Substring] = failedLines + [
            event(#"{"type":"content_block_start","index":3,"content_block":{"type":"web_search_tool_result","tool_use_id":"t","content":[{"type":"web_search_result","url":"https://a.example","title":"A"}]}}"#),
        ]
        let partly: ClaudeAnswerState = state(lines: partlyLines)
        #expect(partly.blocks[3] == .searchResult(errorCode: nil))
        #expect(claudeAnswer(state: partly, headerNotice: .ok).webSearchNotice == .ok)
        #expect(claudeAnswer(state: state(lines: [failedLines[2]]), headerNotice: .ok).webSearchNotice == .ok)
    }

    // Kendi anahtarla Claude: "kuruluşta web araması kapalı" 400'ü tanınır (soru araçsız yinelenir); başka 400'ler, başka
    // durumlar ve bozuk gövde tanınmaz.
    @Test func recognizesWebSearchDisabledRejection() {
        let disabled: String = #"{"type":"error","error":{"type":"invalid_request_error","message":"Web search is not enabled for this organization."}}"#
        #expect(isWebSearchDisabledError(error: LLMError.http(status: 400, body: disabled, model: "m", requestID: nil)))
        #expect(!isWebSearchDisabledError(error: LLMError.http(status: 403, body: disabled, model: "m", requestID: nil)))
        let other: String = #"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too large"}}"#
        #expect(!isWebSearchDisabledError(error: LLMError.http(status: 400, body: other, model: "m", requestID: nil)))
        #expect(!isWebSearchDisabledError(error: LLMError.http(status: 400, body: "web search is not enabled", model: "m", requestID: nil)))
        #expect(!isWebSearchDisabledError(error: LLMError.empty))
        let request: LLMRequest = archiveAnswerRequest(
            question: "Fiyat ne?", passages: [], screens: [], history: [], userName: "", now: Date(timeIntervalSince1970: 0), language: .turkish, webSearch: true
        )
        let plain: LLMRequest = withoutWebSearch(request: request)
        #expect(plain.webSearch == nil && plain.system == request.system && plain.userText == request.userText)
    }

    // Kendi anahtarlı Claude: araç doğrudan çağrıyla; abonelik sunucusu: yalnız tür, ad ve arama sayısı. Araçsız istekte alan yok.
    @Test func requestBodiesCarryTheTool() throws {
        let request: LLMRequest = archiveAnswerRequest(
            question: "Fiyat ne?", passages: [], screens: [], history: [], userName: "", now: Date(timeIntervalSince1970: 0), language: .turkish, webSearch: true
        )
        #expect(request.webSearch == LLMWebSearch(maxUses: 3) && request.system.contains("Web araması"))
        let claude: [String: Any] = try #require(try JSONSerialization.jsonObject(with: claudeRequestBody(request: request, model: .haiku, effort: .medium)) as? [String: Any])
        let claudeTools: [[String: Any]] = try #require(claude["tools"] as? [[String: Any]])
        #expect(claudeTools.count == 1)
        #expect(claudeTools[0]["type"] as? String == "web_search_20260209" && claudeTools[0]["max_uses"] as? Int == 3)
        #expect(claudeTools[0]["allowed_callers"] as? [String] == ["direct"])
        let hosted: [String: Any] = try #require(try JSONSerialization.jsonObject(with: hostedLLMRequestBody(request: request, effort: .medium, maxTokensCap: 8192)) as? [String: Any])
        let hostedTools: [[String: Any]] = try #require(hosted["tools"] as? [[String: Any]])
        #expect(Set(hostedTools[0].keys) == ["type", "name", "max_uses"])
        let plain: LLMRequest = archiveAnswerRequest(
            question: "Fiyat ne?", passages: [], screens: [], history: [], userName: "", now: Date(timeIntervalSince1970: 0), language: .turkish, webSearch: false
        )
        #expect(plain.webSearch == nil && !plain.system.contains("Web araması"))
        let plainBody: [String: Any] = try #require(try JSONSerialization.jsonObject(with: hostedLLMRequestBody(request: plain, effort: .medium, maxTokensCap: 8192)) as? [String: Any])
        #expect(plainBody["tools"] == nil)
    }

    // Sor cevabının çağrı sınırı hesap çağrısınınkinden büyük, toplantı çağrısında toplantı sınırı.
    @Test func askAnswerTokenCap() {
        #expect(hostedMaxTokensCap(purpose: .askAnswer, isMeetingCall: false) == hostedAskAnswerMaxTokens)
        #expect(hostedMaxTokensCap(purpose: .noteEdit, isMeetingCall: false) == hostedAccountMaxTokens)
        #expect(hostedMaxTokensCap(purpose: .askAnswer, isMeetingCall: true) == hostedMeetingMaxTokens)
        #expect(hostedAskAnswerMaxTokens > hostedAccountMaxTokens)
    }

    // Web aramasını desteklemeyen sağlayıcıya araçlı istek gönderilmez (hata), destekleyenler Claude ve abonelik sunucusu.
    @Test func providersWithoutWebSearchRefuse() async throws {
        let openAI: LLMProvider = .openAICompatible(OpenAICompatibleConfig(
            baseURL: try #require(URL(string: "http://127.0.0.1:9")), apiKey: nil, fastModel: "m", smartModel: "m", fastEffort: nil, smartEffort: nil
        ))
        #expect(!supportsWebSearch(provider: openAI))
        #expect(supportsWebSearch(provider: .anthropic(defaultAnthropicConfig(apiKey: "k"))))
        let request: LLMRequest = LLMRequest(
            purpose: .askAnswer, tier: .smart, system: "s", userText: "u", maxTokens: 100, jsonSchema: nil, timeoutSec: 5, images: [], webSearch: LLMWebSearch(maxUses: 1)
        )
        await #expect(throws: LLMError.notConfigured(detail: "OpenAI-compatible does not support web search")) {
            try await streamLLM(provider: openAI, request: request) { (_: String) -> Void in }
        }
    }
}
