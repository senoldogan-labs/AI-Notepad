import Foundation

/// Sor'da web araması: Anthropic'in sunucu tarafı `web_search` aracı. Model, soru toplantılarda olmayan bir bilgi
/// istediğinde (güncel bilgi, tanım, dış kaynak) en çok `askWebSearchMaxUses` arama yapar; cevaptaki web bilgisi
/// alıntılarla (`web_search_result_location`) gelir ve cevapta `[w1]` işaretine dönüşür. Aramayı Anthropic yapar; abonelik
/// sunucusu cevap başına ve aylık arama sayısını ayrıca sınırlar (`server/src/llm/webSearch.ts`).

/// Cevap başına en çok arama (sunucunun `webSearchMaxUsesPerAnswer` ile aynı; bkz. `ServerParityTests`).
public let askWebSearchMaxUses: Int = 3

/// Aracın sürümü: dinamik süzmeli sürüm (Haiku 5.5 dahil güncel Claude modelleri).
let webSearchToolType: String = "web_search_20260209"

/// "Sor'da web aramasına izin ver" ayarının anahtarı (Mac ve iPhone; varsayılan açık).
public let askWebSearchSettingKey: String = "askWebSearch"

/// "Sor'da web aramasına izin ver" ayarı: hiç değiştirilmediyse açık (ayarın varsayılanı).
public func askWebSearchAllowed(defaults: UserDefaults) -> Bool {
    defaults.object(forKey: askWebSearchSettingKey) as? Bool ?? true
}

/// Sağlayıcı web aramasını destekliyor mu: Claude (kendi anahtarla) ve abonelik sunucusu. Saf fonksiyondur.
public func supportsWebSearch(provider: LLMProvider) -> Bool {
    switch provider {
    case .anthropic, .hosted:
        true
    case .openAICompatible, .onDevice:
        false
    }
}

/// Web aramasını desteklemeyen sağlayıcıya araçlı istek bir programlama hatasıdır: sessizce atılmaz, hata verir.
func requireNoWebSearch(request: LLMRequest, provider: String) throws {
    guard request.webSearch == nil else {
        throw LLMError.notConfigured(detail: "\(provider) does not support web search")
    }
}

/// İstek gövdesindeki web araması aracı. `allowed_callers: ["direct"]`: kod yürütmesiz doğrudan arama (sunucu döngüsü
/// en çok `maxUses + 1` adım; `pause_turn` olmaz). Abonelik sunucusuna gövde bu alan olmadan gider (sunucu ekler).
struct WebSearchToolBody: Encodable, Equatable {
    let type: String
    let name: String
    let maxUses: Int
    let allowedCallers: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case maxUses = "max_uses"
        case allowedCallers = "allowed_callers"
    }
}

/// Cevapta alıntılanan bir web sayfası.
public struct WebSource: Sendable, Equatable, Codable, Hashable {
    public let url: String
    public let title: String

    public init(url: String, title: String) {
        self.url = url
        self.title = title
    }
}

/// Adresin alan adı, başındaki "www." olmadan ("https://www.example.com/a" → "example.com"); adres çözülemezse adresin
/// kendisi. Saf fonksiyondur.
public func webSourceDomain(url: String) -> String {
    guard let host = URL(string: url)?.host(), !host.isEmpty else {
        return url
    }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

/// Akışlı cevabın sonucu: metin (web alıntıları `[wN]` işaretli), alıntılanan web sayfaları (N sırasıyla), modelin
/// yaptığı aramaların sorguları ve sunucunun aylık arama hakkı bittiği için aracı sunmadığı.
public struct LLMAnswer: Sendable, Equatable {
    public let text: String
    public let webSources: [WebSource]
    public let webQueries: [String]
    public let webSearchCapReached: Bool

    public init(text: String, webSources: [WebSource], webQueries: [String], webSearchCapReached: Bool) {
        self.text = text
        self.webSources = webSources
        self.webQueries = webQueries
        self.webSearchCapReached = webSearchCapReached
    }
}

/// Akıştaki bir içerik bloğu (yalnız cevabı oluşturanlar ayrılır; düşünme ve diğerleri `other`).
enum ClaudeAnswerBlock: Sendable, Equatable {
    /// Metin ve alıntıladığı web sayfaları.
    case text(String, citations: [WebSource])
    /// Web araması: o ana kadar gelen sorgu JSON'u (`input_json_delta` parçaları).
    case search(inputJSON: String)
    /// Arama sonucu (sayfalar ya da hata).
    case searchResult
    case other
}

/// Claude akışının (SSE) cevaba dönüşen durumu: blok sırası akıştaki `index`'tir.
struct ClaudeAnswerState: Sendable, Equatable {
    var blocks: [Int: ClaudeAnswerBlock]
}

/// Akış satırını duruma işler; cevabı değiştiren bir olaysa (metin, alıntı, arama) true. Çözülemeyen satır (ör. `ping`,
/// bilinmeyen olay) yok sayılır: tüm akış bitince `classifyClaudeResponse` ile doğrulanır. Saf fonksiyondur.
func consumeClaudeAnswerLine(state: ClaudeAnswerState, line: Substring) -> (state: ClaudeAnswerState, changed: Bool) {
    guard line.hasPrefix("data:") else {
        return (state, false)
    }
    let payload: Substring = line.dropFirst("data:".count).drop { $0 == " " }
    guard let event = try? JSONDecoder().decode(RawAnswerEvent.self, from: Data(payload.utf8)), let index = event.index else {
        return (state, false)
    }
    var blocks: [Int: ClaudeAnswerBlock] = state.blocks
    switch event.type {
    case "content_block_start":
        guard let block = event.content_block else {
            return (state, false)
        }
        switch block.type {
        case "text":
            blocks[index] = .text(block.text ?? "", citations: [])
        case "server_tool_use" where block.name == "web_search":
            blocks[index] = .search(inputJSON: "")
        case "web_search_tool_result":
            blocks[index] = .searchResult
        default:
            blocks[index] = .other
        }
        return (ClaudeAnswerState(blocks: blocks), blocks[index] != .other)
    case "content_block_delta":
        guard let delta = event.delta, let current = blocks[index] else {
            return (state, false)
        }
        switch (current, delta.type) {
        case (.text(let text, let citations), "text_delta"):
            blocks[index] = .text(text + (delta.text ?? ""), citations: citations)
        case (.text(let text, let citations), "citations_delta"):
            guard let citation = delta.citation, citation.type == "web_search_result_location", let url = citation.url else {
                return (state, false)
            }
            let source: WebSource = WebSource(url: url, title: citation.title ?? url)
            blocks[index] = .text(text, citations: citations.contains(source) ? citations : citations + [source])
        case (.search(let json), "input_json_delta"):
            blocks[index] = .search(inputJSON: json + (delta.partial_json ?? ""))
        default:
            return (state, false)
        }
        return (ClaudeAnswerState(blocks: blocks), true)
    default:
        return (state, false)
    }
}

/// Aramadan hemen önceki kısa metin ("Önce webde arayayım.") cevaba girmez: arama sürerken arayüz "Web'de aranıyor…"
/// gösterir. Daha uzun metin cevabın parçasıdır ve kalır.
let searchPreambleMaxChars: Int = 280

/// Durumun cevabı: metin blokları sırasıyla birleşir; web alıntısı olan bloğun ardına (sondaki boşluktan önce) alıntılanan
/// sayfaların `[wN]` işaretleri gelir (N, sayfanın cevaptaki ilk alıntı sırası). Aramadan hemen önceki kısa metin
/// atılır. Sorgular arama sırasıyla. Saf fonksiyondur.
func claudeAnswer(state: ClaudeAnswerState, webSearchCapReached: Bool) -> LLMAnswer {
    let ordered: [ClaudeAnswerBlock] = state.blocks.sorted { $0.key < $1.key }.map(\.value)
    let kept: [ClaudeAnswerBlock] = ordered.enumerated().filter { (item: (offset: Int, element: ClaudeAnswerBlock)) -> Bool in
        guard case .text(let text, _) = item.element, text.trimmingCharacters(in: .whitespacesAndNewlines).count <= searchPreambleMaxChars else {
            return true
        }
        // Sonraki ilk boş olmayan blok bir aramaysa bu metin aramanın ön sözüdür.
        let next: ClaudeAnswerBlock? = ordered.dropFirst(item.offset + 1).first { (block: ClaudeAnswerBlock) -> Bool in
            if case .text(let following, _) = block {
                return !following.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return block != .other
        }
        if case .search = next {
            return false
        }
        return true
    }.map(\.element)
    var sources: [WebSource] = []
    var text: String = ""
    for block in kept {
        guard case .text(let body, let citations) = block else {
            continue
        }
        for citation in citations where !sources.contains(citation) {
            sources.append(citation)
        }
        let markers: String = citations.compactMap { (citation: WebSource) -> String? in
            sources.firstIndex(of: citation).map { "[w\($0 + 1)]" }
        }.joined()
        guard !markers.isEmpty else {
            text += body
            continue
        }
        let trailingCount: Int = body.reversed().prefix { $0.isWhitespace }.count
        let core: String = String(body.dropLast(trailingCount))
        let trailing: String = String(body.suffix(trailingCount))
        text += core + (core.isEmpty || core.last?.isWhitespace == true ? "" : " ") + markers + trailing
    }
    let queries: [String] = ordered.compactMap { (block: ClaudeAnswerBlock) -> String? in
        guard case .search(let json) = block else {
            return nil
        }
        return searchQuery(inputJSON: json)
    }
    return LLMAnswer(
        text: text.trimmingCharacters(in: .whitespacesAndNewlines), webSources: sources, webQueries: queries, webSearchCapReached: webSearchCapReached
    )
}

/// Arama girdisinin sorgusu (`{"query":"…"}`); JSON henüz tamamlanmadıysa boş. Saf fonksiyondur.
func searchQuery(inputJSON: String) -> String {
    struct Input: Decodable {
        let query: String
    }
    guard let input = try? JSONDecoder().decode(Input.self, from: Data(inputJSON.utf8)) else {
        return ""
    }
    return input.query
}

/// Abonelik sunucusunun arama durumu başlığı (`x-web-search`): `cap_reached` ise bu ayın arama hakkı bitmiştir ve araç
/// sunulmamıştır. Saf fonksiyondur.
func webSearchCapReached(header: String?) -> Bool {
    header == "cap_reached"
}

// Claude JSON alan adları snake_case olduğu için ara tipler aynı adları kullanır.
private struct RawAnswerEvent: Decodable {
    let type: String
    let index: Int?
    let content_block: RawAnswerBlock?
    let delta: RawAnswerDelta?
}

private struct RawAnswerBlock: Decodable {
    let type: String
    let text: String?
    let name: String?
}

private struct RawAnswerDelta: Decodable {
    let type: String?
    let text: String?
    let partial_json: String?
    let citation: RawAnswerCitation?
}

private struct RawAnswerCitation: Decodable {
    let type: String
    let url: String?
    let title: String?
}
