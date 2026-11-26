import Foundation

/// Sağlayıcıya göre not ve arşiv istemlerinin boyutu.
public struct NoteLimits: Sendable, Equatable {
    /// Transkript bu kadar karaktere kadar tek istekte, uzunu bu boyutta parçalar halinde yazılır.
    public let chunkChars: Int
    /// A chunk's UTF-8 size limit as well (the free plan's per-call input cap; `Int.max` when only characters count).
    public let chunkBytes: Int
    /// Uzun notta önceki parçaların özetleri en fazla bu kadar karakter yer tutar (küçük bağlamlı model); nil ise sınır
    /// yok.
    public let summaryChars: Int?
    /// "Sor"da arşivden isteme konan en fazla karakter.
    public let archiveChars: Int
    /// The whole Ask request's UTF-8 size limit (archive, prompt, history, question; the free plan's per-call input cap;
    /// `Int.max` when only characters count). See `askArchiveCharBudget`.
    public let requestBytes: Int

    public init(chunkChars: Int, summaryChars: Int?, archiveChars: Int) {
        self.init(chunkChars: chunkChars, chunkBytes: Int.max, summaryChars: summaryChars, archiveChars: archiveChars, requestBytes: Int.max)
    }

    public init(chunkChars: Int, chunkBytes: Int, summaryChars: Int?, archiveChars: Int, requestBytes: Int) {
        self.chunkChars = chunkChars
        self.chunkBytes = chunkBytes
        self.summaryChars = summaryChars
        self.archiveChars = archiveChars
        self.requestBytes = requestBytes
    }
}

/// The free plan's limits (Gistsmith; see `HostedLLMScope.freeNote`, `.freeAccount`): the server estimates a call's input
/// as UTF-8 bytes / 3 and caps a free call at 30 000, so note chunks and Ask requests are also cut by bytes; in
/// Latin-script languages the character limits stay the ones that apply.
private let freePlanLimits: NoteLimits = NoteLimits(
    chunkChars: noteChunkMaxChars, chunkBytes: hostedFreeNoteChunkBytes, summaryChars: nil, archiveChars: 60_000, requestBytes: hostedFreeAskRequestBytes
)

/// Bulut ve yerel sunucu modellerinin sınırları (bkz. `noteChunkMaxChars`; arşivde ~60 bin karakter ≈ 35 dk konuşma).
private let largeContextLimits: NoteLimits = NoteLimits(chunkChars: noteChunkMaxChars, summaryChars: nil, archiveChars: 60_000)

/// Cihaz içi modelde parça isteminin sabit kısmı (yönerge, kurallar, şema) ve yanıt için ayrılan token: ölçümde
/// (macOS 26.6, `tokenCount`) parça yönergesi + kurallar ~570, şema ~350 token; yanıt (özet, görevler, sözlük) ~900.
private let onDeviceReservedTokens: Int = 2_000
/// Cihaz içi modelde önceki parça özetlerine ayrılan bağlam payı.
private let onDeviceSummaryShare: Double = 0.2

/// Sağlayıcının sınırları: küçük bağlamlı cihaz içi modelde parça, özet ve arşiv bağlam penceresine göre küçülür (4096
/// token'da parça ~3.200, özetler ~2.000, arşiv ~5.100 karakter). Saf fonksiyondur.
public func noteLimits(provider: LLMProvider) -> NoteLimits {
    if isHostedFreePlanProvider(provider: provider) {
        return freePlanLimits
    }
    guard case .onDevice(let config) = provider else {
        return largeContextLimits
    }
    let free: Double = Double(max(config.contextTokens - onDeviceReservedTokens, 0))
    let summaryTokens: Double = Double(config.contextTokens) * onDeviceSummaryShare
    return NoteLimits(
        chunkChars: max(Int((free - summaryTokens) * onDeviceCharsPerToken), 1_500),
        summaryChars: Int(summaryTokens * onDeviceCharsPerToken),
        archiveChars: max(Int(Double(config.contextTokens / 2) * onDeviceCharsPerToken), 1_500)
    )
}

/// Uzun notun istemlerde kullanılan hali: parça özetleri toplamı `maxChars`'ı aşarsa her özet eşit paya (kelime
/// sınırında, "…" ile) kısaltılır; görevler ve kararlar aynen kalır (görev numaraları değişmesin). Saf fonksiyondur.
public func condensedNoteState(state: ChunkedNoteState, maxChars: Int) -> ChunkedNoteState {
    let total: Int = state.partSummaries.map(\.count).reduce(0, +)
    guard total > maxChars, !state.partSummaries.isEmpty else {
        return state
    }
    let share: Int = max(maxChars / state.partSummaries.count, 1)
    return ChunkedNoteState(
        partSummaries: state.partSummaries.map { truncatedAtWord(text: $0, maxChars: share) },
        decisions: state.decisions, tasks: state.tasks, glossary: state.glossary, openQuestions: state.openQuestions
    )
}

/// Metni en fazla `maxChars` karaktere, son tam kelimede keser ve "…" ekler; sığıyorsa aynen döner. Saf fonksiyondur.
func truncatedAtWord(text: String, maxChars: Int) -> String {
    guard text.count > maxChars else {
        return text
    }
    let prefix: Substring = text.prefix(max(maxChars - 1, 0))
    let cut: Substring = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
    return String(cut) + "…"
}

/// The Ask prompt's fixed part and the answer's instructions, kept out of the archive's share of a byte-capped request
/// (the system prompt is a few KB; measured in `FreePlanTests`).
let askFixedPromptBytes: Int = 8_000

/// How many characters of the archive go into one Ask request: `limits.archiveChars`, and when the request is capped
/// by bytes (`limits.requestBytes`) also what fits in the bytes left after the prompt, history and question
/// (`otherBytes`), counted at the most bytes per character of any candidate passage, so the request stays under the cap
/// in every script. Pure function.
public func askArchiveCharBudget(limits: NoteLimits, passages: [ArchivePassage], otherBytes: Int) -> Int {
    guard limits.requestBytes != Int.max else {
        return limits.archiveChars
    }
    let bytesPerChar: Double = passages.reduce(1) { (widest: Double, passage: ArchivePassage) -> Double in
        max(widest, Double(passage.text.utf8.count) / Double(max(1, passage.text.count)))
    }
    let room: Int = max(0, limits.requestBytes - askFixedPromptBytes - otherBytes)
    return min(limits.archiveChars, Int(Double(room) / bytesPerChar))
}
