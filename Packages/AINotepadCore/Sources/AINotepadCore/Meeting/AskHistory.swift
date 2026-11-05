import Foundation

/// Sor sohbetinde cevaplanmış bir soru: soru, cevap, kaynakları ve nasıl cevaplandığı (arama terimleri, okunan
/// parçalar). Okunan parçalar metinsiz saklanır (yalnız hangi toplantıdan kaç parça okunduğu gösterilir). Eski
/// sürümlerin yazdığı `modelName` alanı okunurken yok sayılır (bilinmeyen anahtar).
public struct AskConversationTurn: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let question: String
    /// `@` ile seçilen toplantılar (soru yalnız onlara soruldu); boşsa tüm arşiv.
    public let scopeMeetingIDs: [String]
    public let scopeTitles: [String]
    /// Soru bir tariften geldiyse tarifin adı.
    public let recipeTitle: String?
    public let startedAt: Date
    public let finishedAt: Date
    public let terms: [String]
    public let readPassages: [ArchivePassage]
    /// Cevapla gönderilen ekran görüntüsü sayısı; bu alan eklenmeden önce saklanan turlarda nil (bilinmiyor).
    public let readScreens: Int?
    public let answer: String
    public let sources: [ArchivePassage]
    /// Cevabın alıntıladığı web sayfaları (`[w1]` ilk sayfa); bu alan eklenmeden önce saklanan turlarda nil.
    public let webSources: [WebSource]?
    /// Modelin yaptığı web aramalarının sorguları; bu alan eklenmeden önce saklanan turlarda nil.
    public let webQueries: [String]?
    /// Web araması yapılamadıysa cevabın altındaki not (hak bitti, şu an yok); bu alan eklenmeden önce saklanan turlarda nil.
    public let webSearchNotice: WebSearchNotice?

    public init(
        id: UUID, question: String, scopeMeetingIDs: [String], scopeTitles: [String], recipeTitle: String?, startedAt: Date, finishedAt: Date,
        terms: [String], readPassages: [ArchivePassage], readScreens: Int?, answer: String, sources: [ArchivePassage], webSources: [WebSource]?,
        webQueries: [String]?, webSearchNotice: WebSearchNotice?
    ) {
        self.id = id
        self.question = question
        self.scopeMeetingIDs = scopeMeetingIDs
        self.scopeTitles = scopeTitles
        self.recipeTitle = recipeTitle
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.terms = terms
        self.readPassages = readPassages
        self.readScreens = readScreens
        self.answer = answer
        self.sources = sources
        self.webSources = webSources
        self.webQueries = webQueries
        self.webSearchNotice = webSearchNotice
    }
}

/// Kullanıcının verdiği sohbet adı ve verildiği an: eşitlemede iki cihazdaki adlardan en son verilen kalır.
public struct AskCustomTitle: Sendable, Equatable, Codable {
    public let text: String
    public let editedAt: Date

    public init(text: String, editedAt: Date) {
        self.text = text
        self.editedAt = editedAt
    }
}

/// Saklanan bir Sor sohbeti (`AskHistory/<id>.json`). `title` ilk sorudan türetilir; kullanıcı adını değiştirdiyse
/// listede `customTitle` görünür (bkz. `askConversationDisplayTitle`).
public struct AskConversation: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let title: String
    /// Kullanıcının verdiği ad; bu alan eklenmeden önce saklanan ve hiç adı değiştirilmeyen sohbetlerde nil.
    public let customTitle: AskCustomTitle?
    public let turns: [AskConversationTurn]

    public init(id: UUID, createdAt: Date, updatedAt: Date, title: String, customTitle: AskCustomTitle?, turns: [AskConversationTurn]) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.customTitle = customTitle
        self.turns = turns
    }
}

/// Saklanan en fazla sohbet; daha eskileri silinir.
public let askHistoryLimit: Int = 200

/// Sohbet başlığının en fazla uzunluğu (karakter).
let askConversationTitleChars: Int = 80

/// Okunamayan sohbet dosyası.
public struct AskHistoryLoadFailure: Error, Sendable, Equatable {
    public let file: String
    public let reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

/// Saklanan sohbetler (yeniden eskiye) ve okunamayan dosyalar; bir bozuk dosya diğerlerini engellemez.
public struct AskHistoryLoadResult: Sendable, Equatable {
    public let conversations: [AskConversation]
    public let failures: [AskHistoryLoadFailure]
}

/// Sohbetin başlığı: ilk sorunun (tariften geldiyse tarifin adının) tek satırlık, kısaltılmış hali. Saf fonksiyondur.
public func askConversationTitle(turn: AskConversationTurn) -> String {
    let text: String = turn.recipeTitle ?? turn.question
    let line: String = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.count > askConversationTitleChars ? String(line.prefix(askConversationTitleChars - 1)) + "…" : line
}

/// Sohbetin güncel hali: turlar değişir, başlık ilk turdan, oluşturulma zamanı ve kullanıcının verdiği ad varsa eski
/// sohbetten gelir. Saf fonksiyondur.
public func askConversation(existing: AskConversation?, id: UUID, turns: [AskConversationTurn], now: Date) -> AskConversation {
    AskConversation(
        id: id, createdAt: existing?.createdAt ?? now, updatedAt: now,
        title: turns.first.map { askConversationTitle(turn: $0) } ?? "", customTitle: existing?.customTitle, turns: turns
    )
}

/// Listede ve sohbet başlığında görünen ad: kullanıcının verdiği ad, yoksa ilk sorudan türetilen başlık. Saf fonksiyondur.
public func askConversationDisplayTitle(conversation: AskConversation) -> String {
    conversation.customTitle?.text ?? conversation.title
}

/// Sohbetin yeni adıyla hali: ad tek satıra indirilir; boşsa ya da görünen ad zaten buysa nil (değişiklik yok, toplantı
/// adındaki gibi boş ad yok sayılır). Son güncellenme zamanı değişmez: ad vermek sohbeti listenin başına taşımaz. Saf
/// fonksiyondur.
public func renamedAskConversation(conversation: AskConversation, title: String, now: Date) -> AskConversation? {
    let line: String = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !line.isEmpty, line != askConversationDisplayTitle(conversation: conversation) else {
        return nil
    }
    return AskConversation(
        id: conversation.id, createdAt: conversation.createdAt, updatedAt: conversation.updatedAt, title: conversation.title,
        customTitle: AskCustomTitle(text: line, editedAt: now), turns: conversation.turns
    )
}

/// İki cihazdaki adlardan en son verileni (aynı anda verildiyse metni sıralamada önce geleni: iki cihaz da aynı sonuca
/// varır); yalnız biri varsa o. Saf fonksiyondur.
public func newerAskCustomTitle(first: AskCustomTitle?, second: AskCustomTitle?) -> AskCustomTitle? {
    guard let first, let second else {
        return first ?? second
    }
    if first.editedAt != second.editedAt {
        return first.editedAt > second.editedAt ? first : second
    }
    return first.text <= second.text ? first : second
}

/// Geçmiş listesinin süzgeci: tüm sohbetler, `@` ile belirli toplantılara sorulanlar ya da cevabında web kaynağı olanlar.
public enum AskHistoryFilter: String, Sendable, CaseIterable {
    case all
    case meetings
    case web
}

/// Sohbette `@` ile belirli toplantılara sorulan bir soru var. Saf fonksiyondur.
public func askConversationAskedMeetings(conversation: AskConversation) -> Bool {
    conversation.turns.contains { !$0.scopeMeetingIDs.isEmpty }
}

/// Sohbette web sayfalarını kaynak gösteren bir cevap var. Saf fonksiyondur.
public func askConversationUsedWeb(conversation: AskConversation) -> Bool {
    conversation.turns.contains { !($0.webSources ?? []).isEmpty }
}

/// Sohbet süzgece uyuyor. Saf fonksiyondur.
public func askConversationMatches(conversation: AskConversation, filter: AskHistoryFilter) -> Bool {
    switch filter {
    case .all:
        return true
    case .meetings:
        return askConversationAskedMeetings(conversation: conversation)
    case .web:
        return askConversationUsedWeb(conversation: conversation)
    }
}

/// Sohbet aramaya uyuyor: görünen adda, sorularda, tarif adlarında, etiketli toplantı adlarında ya da cevaplarda geçen
/// her kelime (büyük/küçük harf, aksan ve ı/i duyarsız, `searchFolded`); boş arama hepsine uyar. Saf fonksiyondur.
public func askConversationMatches(conversation: AskConversation, query: String) -> Bool {
    let words: [String] = searchFolded(query).split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else {
        return true
    }
    let fields: [String] = [askConversationDisplayTitle(conversation: conversation), conversation.title]
        + conversation.turns.flatMap { (turn: AskConversationTurn) -> [String] in
            [turn.question, turn.recipeTitle ?? "", turn.answer] + turn.scopeTitles
        }
    let haystack: String = searchFolded(fields.joined(separator: "\n"))
    return words.allSatisfy { haystack.contains($0) }
}

/// Geçmiş listesinde görünen sohbetler: süzgece ve aramaya uyanlar, sırası korunarak. Saf fonksiyondur.
public func filteredAskConversations(conversations: [AskConversation], query: String, filter: AskHistoryFilter) -> [AskConversation] {
    conversations.filter { (conversation: AskConversation) -> Bool in
        askConversationMatches(conversation: conversation, filter: filter) && askConversationMatches(conversation: conversation, query: query)
    }
}

/// Sohbeti listeye yazar (aynı kimlikli eskisinin yerine) ve listeyi yeniden eskiye sıralar. Saf fonksiyondur.
public func upsertAskConversation(conversations: [AskConversation], conversation: AskConversation) -> [AskConversation] {
    newestAskConversationsFirst(conversations: conversations.filter { $0.id != conversation.id } + [conversation])
}

/// Sohbetler, en son güncellenen önce. Saf fonksiyondur.
func newestAskConversationsFirst(conversations: [AskConversation]) -> [AskConversation] {
    conversations.sorted { (first: AskConversation, second: AskConversation) -> Bool in
        first.updatedAt != second.updatedAt ? first.updatedAt > second.updatedAt : first.id.uuidString < second.id.uuidString
    }
}

/// Sınırı aşan (en eski) sohbetler: silinecekler. Saf fonksiyondur.
public func askConversationsBeyondLimit(conversations: [AskConversation], limit: Int) -> [AskConversation] {
    Array(newestAskConversationsFirst(conversations: conversations).dropFirst(limit))
}

/// Sohbetin dosyası: `<klasör>/<id>.json`.
func askConversationFile(id: UUID, directory: URL) -> URL {
    directory.appending(path: "\(id.uuidString).json")
}

/// Sohbeti klasöründeki dosyasına atomik yazar.
public func saveAskConversation(conversation: AskConversation, directory: URL) throws {
    let file: URL = askConversationFile(id: conversation.id, directory: directory)
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data: Data
    do {
        data = try encoder.encode(conversation)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
    do {
        try data.write(to: file, options: .atomic)
    } catch {
        throw StorageError.writeFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Klasördeki tüm sohbetleri okur (yeniden eskiye). Klasör yoksa boş; okunamayan dosyalar `failures`'a yazılır.
public func loadAskConversations(directory: URL) throws -> AskHistoryLoadResult {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return AskHistoryLoadResult(conversations: [], failures: [])
    }
    let files: [URL]
    do {
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: error.localizedDescription)
    }
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let loaded: [Result<AskConversation, AskHistoryLoadFailure>] = files.map { (file: URL) -> Result<AskConversation, AskHistoryLoadFailure> in
        do {
            return .success(try decoder.decode(AskConversation.self, from: Data(contentsOf: file)))
        } catch {
            return .failure(AskHistoryLoadFailure(file: file.lastPathComponent, reason: error.localizedDescription))
        }
    }
    let conversations: [AskConversation] = loaded.compactMap { (result: Result<AskConversation, AskHistoryLoadFailure>) -> AskConversation? in
        if case .success(let conversation) = result {
            return conversation
        }
        return nil
    }
    let failures: [AskHistoryLoadFailure] = loaded.compactMap { (result: Result<AskConversation, AskHistoryLoadFailure>) -> AskHistoryLoadFailure? in
        if case .failure(let failure) = result {
            return failure
        }
        return nil
    }
    return AskHistoryLoadResult(conversations: newestAskConversationsFirst(conversations: conversations), failures: failures)
}

/// Tek bir sohbeti okur; dosyası yoksa nil, okunamazsa `StorageError.readFailed`.
public func loadAskConversation(id: UUID, directory: URL) throws -> AskConversation? {
    let file: URL = askConversationFile(id: id, directory: directory)
    guard FileManager.default.fileExists(atPath: file.path) else {
        return nil
    }
    let decoder: JSONDecoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
        return try decoder.decode(AskConversation.self, from: Data(contentsOf: file))
    } catch {
        throw StorageError.readFailed(path: file.path, reason: error.localizedDescription)
    }
}

/// Sohbetin dosyasını siler; dosya zaten yoksa bir şey yapmaz.
public func deleteAskConversation(id: UUID, directory: URL) throws {
    let file: URL = askConversationFile(id: id, directory: directory)
    guard FileManager.default.fileExists(atPath: file.path) else {
        return
    }
    do {
        try FileManager.default.removeItem(at: file)
    } catch {
        throw StorageError.deleteFailed(path: file.path, reason: error.localizedDescription)
    }
}
