import Foundation

// Abonelik sürümünün istemci telemetrisi: Ayarlar'daki "Anonim kullanım istatistiklerini paylaş" açıkken güvenilirlik
// ve süre olayları (`POST /v1/telemetry`) ve günde bir özellik kullanımı (`POST /v1/telemetry/features`). Gövdeler
// yalnızca sabit listelerden değerler, sayılar ve süreler taşır: ses, metin, not, istem, başlık, ad, adres ya da dosya
// yolu taşıyamaz. Listeler sunucunun `server/src/telemetry.ts` dizileriyle birebir aynıdır (bkz. `ServerParityTests`).
// Geliştirici sürümü hiçbir şey göndermez (bkz. `telemetrySendingAllowed`).

/// Uygulamanın sürümü: telemetri yalnızca abonelik sürümünde (Gistsmith) gönderilir.
public enum AppEdition: Sendable, Equatable {
    /// Kendi anahtarlı geliştirici sürümü (AI-Notepad): sunucusu yoktur, telemetri göndermez.
    case developer
    /// Abonelik sürümü (Gistsmith).
    case hosted
}

/// Telemetri kaydedilip gönderilebilir mi: yalnızca abonelik sürümünde ve kullanıcı paylaşımı açık bıraktıysa. Saf
/// fonksiyondur.
public func telemetrySendingAllowed(edition: AppEdition, sharingEnabled: Bool) -> Bool {
    edition == .hosted && sharingEnabled
}

/// "Anonim kullanım istatistiklerini paylaş" ayarının UserDefaults anahtarı (Mac ve iPhone'da aynı; varsayılan açık).
public let shareUsageStatisticsDefaultsKey: String = "privacy.shareUsageStatistics"

/// Sayılan olaylar: güvenilirlik olayları ve "öbür uygulamayı al" tanıtımının adımları.
public enum TelemetryCountKind: String, Sendable, Codable, CaseIterable {
    /// Deepgram canlı metin bağlantısı koptu.
    case deepgramSocketDrop = "deepgram_socket_drop"
    /// Kopan Deepgram bağlantısı yeniden kuruldu.
    case deepgramReconnect = "deepgram_reconnect"
    /// Son geçiş yarıda bırakıldı ya da hiç tamamlanamadı (canlı metin kullanıldı).
    case finalPassGiveUp = "final_pass_give_up"
    /// Not yazılamadı.
    case noteGenerationFailed = "note_generation_failed"
    /// Kayıt toplantının süre sınırına ulaştı ve kendiliğinden bitirildi.
    case recordingOverrun = "recording_overrun"
    /// iPhone: Ayarlar'daki "Mac için Gistsmith" satırı göründü (uygulama açılışı başına bir kez).
    case macPromoShown = "mac_promo_shown"
    /// iPhone: satıra dokunuldu, Mac uygulamasının sayfası açıldı.
    case macPromoOpened = "mac_promo_opened"
    /// iPhone: "Bağlantıyı paylaş"a dokunuldu (paylaşım sayfası açıldı; paylaşılıp paylaşılmadığı bilinmez).
    case macPromoShared = "mac_promo_shared"
    /// iPhone: "Sonra hatırlat" ertesi sabahın bildirimini kurdu.
    case macPromoReminded = "mac_promo_reminded"
    /// Mac: Ayarlar'daki "iPhone için Gistsmith" kartı göründü (uygulama açılışı başına bir kez).
    case iPhonePromoShown = "iphone_promo_shown"
    /// Mac: karta tıklandı, iPhone uygulamasının sayfası açıldı.
    case iPhonePromoOpened = "iphone_promo_opened"
    /// Mac: App Store bağlantısı kopyalandı.
    case iPhonePromoCopied = "iphone_promo_copied"
    /// A recording's live transcript started on the device (on-device live preview).
    case onDeviceLiveStarted = "on_device_live_started"
    /// The user was in the on-device live preview rollout but this device could not use it for the meeting (language,
    /// system, model not installed yet); the live transcript ran where the server offered (cloud, or the local engine).
    case onDeviceLiveUnavailable = "on_device_live_unavailable"
    /// The on-device live preview stopped mid-meeting (the recording continued; the final pass covers it).
    case onDeviceLiveFailed = "on_device_live_failed"
}

/// Süresi ölçülen işler (saniye).
public enum TelemetryDurationKind: String, Sendable, Codable, CaseIterable {
    /// Bir kaydın sunucuda son geçişi (yükleme dahil).
    case finalPassDuration = "final_pass_duration"
    /// Notun yazılması.
    case noteGenerationDuration = "note_generation_duration"
}

/// Notun gönderildiği entegrasyonun türü (hedefin adı ya da adresi değil).
public enum TelemetryIntegration: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case slack
    case teams
    case discord
    case webhook
    case notion
    case appleNotes = "apple_notes"
    case markdownFolder = "markdown_folder"
    case trackerLinear = "tracker_linear"
    case trackerJira = "tracker_jira"
    case trackerNotion = "tracker_notion"
}

/// Dışa aktarma biçimi.
public enum TelemetryExportFormat: String, Sendable, Codable, CaseIterable, CodingKeyRepresentable {
    case pdf
    case html
    case markdown
    case docx
    case transcriptText = "transcript_text"
    case srt
    case copyMarkdown = "copy_markdown"
    case email
    case pdfShare = "pdf_share"
    case linkShare = "link_share"
    case audioClip = "audio_clip"
}

/// Bir sayım ya da süre gövdesinde en çok olay (sunucunun sınırı 50).
public let telemetryMaxEventsPerBatch: Int = 50
/// Olay başına en büyük sayı (sunucunun sınırı).
public let telemetryMaxCount: Int = 1000
/// En uzun süre (saniye; sunucunun sınırı).
public let telemetryMaxSeconds: Double = 86_400

/// Bir olay türünün birikmiş sayısı.
public struct TelemetryCount: Sendable, Equatable, Codable {
    public let kind: TelemetryCountKind
    public let count: Int

    public init(kind: TelemetryCountKind, count: Int) {
        self.kind = kind
        self.count = count
    }
}

/// Bir süre ölçümü.
public struct TelemetryDurationSample: Sendable, Equatable, Codable {
    public let kind: TelemetryDurationKind
    public let seconds: Double

    public init(kind: TelemetryDurationKind, seconds: Double) {
        self.kind = kind
        self.seconds = seconds
    }
}

/// Gönderilmeyi bekleyen olaylar (uygulama kapanınca da kalsın diye UserDefaults'ta JSON olarak durur).
public struct TelemetryPendingEvents: Sendable, Equatable, Codable {
    public let counts: [TelemetryCount]
    public let durations: [TelemetryDurationSample]
    /// Abonelik hunisi olayları, aynı olay birleşmiş (bkz. `addingConversion`).
    public let conversions: [ConversionCount]

    public init(counts: [TelemetryCount], durations: [TelemetryDurationSample], conversions: [ConversionCount]) {
        self.counts = counts
        self.durations = durations
        self.conversions = conversions
    }

    /// Önceki sürümlerin diske yazdığı bekleyen olaylar (`conversions` alanı yok) da okunur: o sürümler huni olayı
    /// kaydetmiyordu.
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        counts = try container.decode([TelemetryCount].self, forKey: .counts)
        durations = try container.decode([TelemetryDurationSample].self, forKey: .durations)
        conversions = try container.decodeIfPresent([ConversionCount].self, forKey: .conversions) ?? []
    }

    /// Bekleyen olay yok.
    public var isEmpty: Bool {
        counts.isEmpty && durations.isEmpty && conversions.isEmpty
    }
}

/// Boş bekleyen olaylar. Saf fonksiyondur.
public func emptyTelemetryPendingEvents() -> TelemetryPendingEvents {
    TelemetryPendingEvents(counts: [], durations: [], conversions: [])
}

/// Olay türünün sayısını bir artırır (sınırda kalır). Saf fonksiyondur.
public func addingTelemetryCount(pending: TelemetryPendingEvents, kind: TelemetryCountKind) -> TelemetryPendingEvents {
    let current: Int = pending.counts.first { $0.kind == kind }?.count ?? 0
    let others: [TelemetryCount] = pending.counts.filter { $0.kind != kind }
    return TelemetryPendingEvents(
        counts: others + [TelemetryCount(kind: kind, count: min(current + 1, telemetryMaxCount))], durations: pending.durations, conversions: pending.conversions
    )
}

/// Süre ölçümünü ekler (sunucunun aralığına kırpılır). Tek gövdeye sığsın diye en yeni
/// `telemetryMaxEventsPerBatch - TelemetryCountKind.allCases.count` ölçüm tutulur, eskileri düşer. Saf fonksiyondur.
public func addingTelemetryDuration(pending: TelemetryPendingEvents, kind: TelemetryDurationKind, seconds: Double) -> TelemetryPendingEvents {
    let clamped: Double = min(max(seconds.isFinite ? seconds : 0, 0), telemetryMaxSeconds)
    let capacity: Int = telemetryMaxEventsPerBatch - TelemetryCountKind.allCases.count
    let durations: [TelemetryDurationSample] = Array((pending.durations + [TelemetryDurationSample(kind: kind, seconds: clamped)]).suffix(capacity))
    return TelemetryPendingEvents(counts: pending.counts, durations: durations, conversions: pending.conversions)
}

/// `POST /v1/telemetry` gövdesindeki tek olay: sayım (`count`) ya da süre (`seconds`); boş alan yazılmaz.
private struct TelemetryEventBody: Encodable {
    let kind: String
    let count: Int?
    let seconds: Double?
}

/// Gövdedeki olay: güvenilirlik sayımı ya da süresi, ya da abonelik hunisi olayı (alanları türüne göre).
private enum TelemetryWireEvent: Encodable {
    case reliability(TelemetryEventBody)
    case conversion(ConversionEventBody)

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .reliability(let body): try body.encode(to: encoder)
        case .conversion(let body): try body.encode(to: encoder)
        }
    }
}

private struct TelemetryEventsBody: Encodable {
    let events: [TelemetryWireEvent]
}

/// Tek gövdeye sığan bekleyenler (sunucunun sınırı `telemetryMaxEventsPerBatch`): önce sayımlar, sonra süreler, sonra
/// huni olayları; gönderilen bu kısım bekleyenlerden düşülür, kalanlar sonraki gönderime kalır. Saf fonksiyondur.
public func telemetryBatch(pending: TelemetryPendingEvents) -> TelemetryPendingEvents {
    let counts: [TelemetryCount] = Array(pending.counts.filter { $0.count > 0 }.prefix(telemetryMaxEventsPerBatch))
    let durations: [TelemetryDurationSample] = Array(pending.durations.prefix(telemetryMaxEventsPerBatch - counts.count))
    let conversions: [ConversionCount] = Array(pending.conversions.filter { $0.count > 0 }.prefix(telemetryMaxEventsPerBatch - counts.count - durations.count))
    return TelemetryPendingEvents(counts: counts, durations: durations, conversions: conversions)
}

/// Bekleyen olayların gövdesi (`{"events": [...]}`; en çok `telemetryMaxEventsPerBatch` olay, bkz. `telemetryBatch`);
/// bekleyen olay yoksa nil. Saf fonksiyondur.
public func hostedTelemetryEventsBody(pending: TelemetryPendingEvents) throws -> Data? {
    let batch: TelemetryPendingEvents = telemetryBatch(pending: pending)
    guard !batch.isEmpty else {
        return nil
    }
    let counts: [TelemetryWireEvent] = batch.counts.map { .reliability(TelemetryEventBody(kind: $0.kind.rawValue, count: $0.count, seconds: nil)) }
    let durations: [TelemetryWireEvent] = batch.durations.map { .reliability(TelemetryEventBody(kind: $0.kind.rawValue, count: nil, seconds: $0.seconds)) }
    let conversions: [TelemetryWireEvent] = batch.conversions.map { .conversion(conversionEventBody(count: $0)) }
    return try JSONEncoder().encode(TelemetryEventsBody(events: counts + durations + conversions))
}

/// Gönderilen kısmı (`sent`, bkz. `telemetryBatch`) güncel bekleyenlerden çıkarır: sayımlardan ve huni olaylarından
/// gönderilen kadar düşülür, gönderilen süre ölçümleri (baştan, sırayla) atılır. Gönderim sürerken gelen yeni olaylar
/// kalır. Saf fonksiyondur.
public func subtractingTelemetry(sent: TelemetryPendingEvents, from current: TelemetryPendingEvents) -> TelemetryPendingEvents {
    let counts: [TelemetryCount] = current.counts.compactMap { (count: TelemetryCount) -> TelemetryCount? in
        let remaining: Int = count.count - (sent.counts.first { $0.kind == count.kind }?.count ?? 0)
        return remaining > 0 ? TelemetryCount(kind: count.kind, count: remaining) : nil
    }
    let durations: [TelemetryDurationSample] = Array(current.durations.dropFirst(min(sent.durations.count, current.durations.count)))
    let conversions: [ConversionCount] = current.conversions.compactMap { (count: ConversionCount) -> ConversionCount? in
        let remaining: Int = count.count - (sent.conversions.first { $0.event == count.event }?.count ?? 0)
        return remaining > 0 ? ConversionCount(event: count.event, count: remaining) : nil
    }
    return TelemetryPendingEvents(counts: counts, durations: durations, conversions: conversions)
}

/// Özellik kullanımı kaydı.
public enum TelemetryFeature: Sendable, Equatable {
    /// Canlı çeviri kullanıldı (hedef dil).
    case liveTranslation(ShareLanguage)
    /// Sor kullanıldı.
    case ask
    /// Not ya da görevler bir entegrasyona gönderildi.
    case integration(TelemetryIntegration)
    /// Toplantı dışa aktarıldı.
    case export(TelemetryExportFormat)
    /// Toplantı arşivi MCP ile açıldı (bir MCP istemcisi yerel sunucuyu başlattı).
    case mcp
    /// Kaydın canlı metni bu Mac'te üretildi (bulut değil).
    case onDeviceLive
    /// Sesle yazma (dikte) metni başka bir uygulamaya yapıştırdı ya da panoya kopyaladı.
    case dictation
    /// Kayıt sırasında paylaşılan ekranın görüntüsü saklandı.
    case screenSnapshots
    /// A note was written with shared-screen snapshots (Gistsmith setting "Use screen snapshots in notes").
    case screenNotes
    /// Mac ↔ iPhone sync was on for the account that day.
    case sync
}

/// Bir günün (UTC) özellik kullanımı.
public struct TelemetryFeatureUsage: Sendable, Equatable, Codable {
    /// `yyyy-MM-dd` (UTC; bkz. `telemetryDayKey`).
    public let day: String
    public let liveTranslation: Bool
    /// Canlı çevirinin son kullanılan hedef dili; çeviri yoksa nil.
    public let translationLanguage: ShareLanguage?
    public let ask: Bool
    public let integrations: [TelemetryIntegration: Int]
    public let exports: [TelemetryExportFormat: Int]
    public let mcp: Bool
    public let onDeviceLive: Bool
    public let dictation: Bool
    public let screenSnapshots: Bool
    public let screenNotes: Bool
    public let sync: Bool

    public init(
        day: String, liveTranslation: Bool, translationLanguage: ShareLanguage?, ask: Bool, integrations: [TelemetryIntegration: Int],
        exports: [TelemetryExportFormat: Int], mcp: Bool, onDeviceLive: Bool, dictation: Bool, screenSnapshots: Bool, screenNotes: Bool,
        sync: Bool
    ) {
        self.day = day
        self.liveTranslation = liveTranslation
        self.translationLanguage = translationLanguage
        self.ask = ask
        self.integrations = integrations
        self.exports = exports
        self.mcp = mcp
        self.onDeviceLive = onDeviceLive
        self.dictation = dictation
        self.screenSnapshots = screenSnapshots
        self.screenNotes = screenNotes
        self.sync = sync
    }

    /// Önceki sürümlerin diske yazdığı kullanım (`dictation`, `screenSnapshots`, `screenNotes`, `sync` alanları yok) da okunur: o sürümlerde
    /// bu özellikler yoktu.
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        day = try container.decode(String.self, forKey: .day)
        liveTranslation = try container.decode(Bool.self, forKey: .liveTranslation)
        translationLanguage = try container.decodeIfPresent(ShareLanguage.self, forKey: .translationLanguage)
        ask = try container.decode(Bool.self, forKey: .ask)
        integrations = try container.decode([TelemetryIntegration: Int].self, forKey: .integrations)
        exports = try container.decode([TelemetryExportFormat: Int].self, forKey: .exports)
        mcp = try container.decode(Bool.self, forKey: .mcp)
        onDeviceLive = try container.decode(Bool.self, forKey: .onDeviceLive)
        dictation = try container.decodeIfPresent(Bool.self, forKey: .dictation) ?? false
        screenSnapshots = try container.decodeIfPresent(Bool.self, forKey: .screenSnapshots) ?? false
        screenNotes = try container.decodeIfPresent(Bool.self, forKey: .screenNotes) ?? false
        sync = try container.decodeIfPresent(Bool.self, forKey: .sync) ?? false
    }
}

/// Günün boş kullanımı. Saf fonksiyondur.
public func emptyFeatureUsage(day: String) -> TelemetryFeatureUsage {
    TelemetryFeatureUsage(day: day, liveTranslation: false, translationLanguage: nil, ask: false, integrations: [:], exports: [:], mcp: false, onDeviceLive: false, dictation: false, screenSnapshots: false, screenNotes: false, sync: false)
}

/// Kullanıma özelliği işler (sayılar sınırda kalır). Saf fonksiyondur.
public func recordingFeature(usage: TelemetryFeatureUsage, feature: TelemetryFeature) -> TelemetryFeatureUsage {
    let incremented: (Int?) -> Int = { (count: Int?) -> Int in min((count ?? 0) + 1, telemetryMaxCount) }
    switch feature {
    case .liveTranslation(let language):
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: true, translationLanguage: language, ask: usage.ask, integrations: usage.integrations, exports: usage.exports,
            mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots, screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .ask:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: true, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots, screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .integration(let integration):
        var integrations: [TelemetryIntegration: Int] = usage.integrations
        integrations[integration] = incremented(integrations[integration])
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots, screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .export(let format):
        var exports: [TelemetryExportFormat: Int] = usage.exports
        exports[format] = incremented(exports[format])
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots, screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .mcp:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: true, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots, screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .onDeviceLive:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: true, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots, screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .dictation:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: true, screenSnapshots: usage.screenSnapshots, screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .screenSnapshots:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: true,
            screenNotes: usage.screenNotes, sync: usage.sync
        )
    case .screenNotes:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots,
            screenNotes: true, sync: usage.sync
        )
    case .sync:
        return TelemetryFeatureUsage(
            day: usage.day, liveTranslation: usage.liveTranslation, translationLanguage: usage.translationLanguage, ask: usage.ask, integrations: usage.integrations,
            exports: usage.exports, mcp: usage.mcp, onDeviceLive: usage.onDeviceLive, dictation: usage.dictation, screenSnapshots: usage.screenSnapshots,
            screenNotes: usage.screenNotes, sync: true
        )
    }
}

/// `POST /v1/telemetry/features` gövdesi: entegrasyon ve dışa aktarma sayıları her tür için yazılır (sunucu hepsini
/// ister; kullanılmayan 0).
private struct FeatureUsageBody: Encodable {
    let day: String
    let liveTranslation: Bool
    let translationLanguage: String?
    let ask: Bool
    let integrations: [String: Int]
    let exports: [String: Int]
    let mcp: Bool
    let onDeviceLive: Bool
    let dictation: Bool
    let screenSnapshots: Bool
    let screenNotes: Bool
    let sync: Bool

    enum CodingKeys: String, CodingKey {
        case day, liveTranslation, translationLanguage, ask, integrations, exports, mcp, onDeviceLive, dictation, screenSnapshots, screenNotes, sync
    }

    /// `translationLanguage` nil iken de yazılır (`null`): sunucu alanı her zaman ister.
    func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(day, forKey: .day)
        try container.encode(liveTranslation, forKey: .liveTranslation)
        try container.encode(translationLanguage, forKey: .translationLanguage)
        try container.encode(ask, forKey: .ask)
        try container.encode(integrations, forKey: .integrations)
        try container.encode(exports, forKey: .exports)
        try container.encode(mcp, forKey: .mcp)
        try container.encode(onDeviceLive, forKey: .onDeviceLive)
        try container.encode(dictation, forKey: .dictation)
        try container.encode(screenSnapshots, forKey: .screenSnapshots)
        try container.encode(screenNotes, forKey: .screenNotes)
        try container.encode(sync, forKey: .sync)
    }
}

/// Günün özellik kullanımı gövdesi. Hedef dil yalnızca canlı çeviri kullanıldıysa yazılır. Saf fonksiyondur.
public func hostedFeatureUsageBody(usage: TelemetryFeatureUsage) throws -> Data {
    let body: FeatureUsageBody = FeatureUsageBody(
        day: usage.day,
        liveTranslation: usage.liveTranslation,
        translationLanguage: usage.liveTranslation ? usage.translationLanguage?.rawValue : nil,
        ask: usage.ask,
        integrations: Dictionary(uniqueKeysWithValues: TelemetryIntegration.allCases.map { ($0.rawValue, usage.integrations[$0] ?? 0) }),
        exports: Dictionary(uniqueKeysWithValues: TelemetryExportFormat.allCases.map { ($0.rawValue, usage.exports[$0] ?? 0) }),
        mcp: usage.mcp,
        onDeviceLive: usage.onDeviceLive,
        dictation: usage.dictation,
        screenSnapshots: usage.screenSnapshots,
        screenNotes: usage.screenNotes, sync: usage.sync
    )
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(body)
}

/// Sunucunun özellik raporu yanıtı: gün bu hesap için ilk kez mi sayıldı.
struct HostedFeatureUsageResponse: Decodable {
    let counted: Bool
}

/// Telemetri günü: UTC `yyyy-MM-dd` (sunucunun gün anahtarıyla aynı). Saf fonksiyondur.
public func telemetryDayKey(date: Date) -> String {
    var calendar: Calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let parts: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

/// Özellik kullanımının saklanan durumu: bugünün süren kaydı ve gönderilmeyi bekleyen tamamlanmış bir gün.
public struct TelemetryFeatureState: Sendable, Equatable, Codable {
    public let current: TelemetryFeatureUsage?
    public let completed: TelemetryFeatureUsage?

    public init(current: TelemetryFeatureUsage?, completed: TelemetryFeatureUsage?) {
        self.current = current
        self.completed = completed
    }
}

/// Özelliği bugünün kaydına işler. Kayıt başka bir güne aitse o gün tamamlanmış sayılır ve gönderilmeyi bekler (daha
/// önce bekleyen gün varsa yerine geçer: en çok bir gün bekler). Saf fonksiyondur.
public func recordingFeature(state: TelemetryFeatureState, feature: TelemetryFeature, today: String) -> TelemetryFeatureState {
    let rolled: TelemetryFeatureState = rollingFeatureState(state: state, today: today)
    return TelemetryFeatureState(current: recordingFeature(usage: rolled.current ?? emptyFeatureUsage(day: today), feature: feature), completed: rolled.completed)
}

/// Gün döndüyse bugünden önceki kayıt tamamlanmış güne geçer. Saf fonksiyondur.
public func rollingFeatureState(state: TelemetryFeatureState, today: String) -> TelemetryFeatureState {
    guard let current = state.current, current.day != today else {
        return state
    }
    return TelemetryFeatureState(current: nil, completed: current)
}

/// Not yazımının telemetri sonucu.
public enum NoteGenerationOutcome: Sendable, Equatable {
    /// Not yazıldı.
    case written
    /// Not yazılamadı (toplantı başarısız ya da yenileme hatası eski notu korudu).
    case failed
    /// Not yazılacak metin yoktu.
    case notWritten
}

/// İşlenmiş toplantının not sonucu. Saf fonksiyondur.
public func noteGenerationOutcome(record: MeetingRecord) -> NoteGenerationOutcome {
    if record.status == .failed || record.failureMessage != nil {
        return .failed
    }
    return record.note == nil ? .notWritten : .written
}

/// Not hedefinin entegrasyon türü (adı ya da adresi değil). Saf fonksiyondur.
public func telemetryIntegration(target: DestinationTarget) -> TelemetryIntegration {
    switch target {
    case .account(let connection):
        switch connection.service {
        case .slack: .slack
        case .teams: .teams
        case .discord: .discord
        }
    case .webhook: .webhook
    case .discordSignIn: .discord
    case .notion: .notion
    }
}

/// Görev aracının entegrasyon türü. Saf fonksiyondur.
public func telemetryIntegration(tracker: MCPService) -> TelemetryIntegration {
    switch tracker {
    case .linear: .trackerLinear
    case .atlassian: .trackerJira
    case .notion: .trackerNotion
    }
}

// MARK: Abonelik hunisi

// Abonelik ekranının ve teklif anlarının adımları (`POST /v1/telemetry`, öbür olaylarla aynı gövdede): ne zaman
// gösterildi, hangi plan seçildi, satın alma başladı mı, bitti mi, neden olmadı. Değerler yalnızca sabit listelerden
// gelir; sunucu günlük toplamlar tutar, hesaba bağlamaz (`server/src/conversion.ts`). Fiyat, ürün kimliği, App Store ya
// da Stripe kimliği, hata metni gönderilmez. Listeler sunucunun dizileriyle birebir aynıdır (bkz. `ServerParityTests`).

/// Huni olayının türü (sunucunun `conversionKinds`'ı).
public enum ConversionEventKind: String, Sendable, Codable, CaseIterable {
    case paywallShown = "paywall_shown"
    case paywallClosed = "paywall_closed"
    case planSelected = "plan_selected"
    case purchaseStarted = "purchase_started"
    case purchaseCancelled = "purchase_cancelled"
    case purchaseCompleted = "purchase_completed"
    case purchaseFailed = "purchase_failed"
    case purchaseRestored = "purchase_restored"
    case trialReminderShown = "trial_reminder_shown"
    case trialReminderTapped = "trial_reminder_tapped"
    case trialReminderOptIn = "trial_reminder_opt_in"
    case upsellShown = "upsell_shown"
    case upsellTapped = "upsell_tapped"
    case heardAbout = "heard_about"
}

/// Karşılamadaki "Bizi nereden duydun?" yanıtı (sunucunun `acquisitionSources`'ı): tek dokunuş, yalnızca günlük toplam.
public enum AcquisitionSource: String, Sendable, Codable, CaseIterable {
    case search
    case appStore = "app_store"
    case social
    case friend
    case aiAssistant = "ai_assistant"
    case video
    case blog
    case ad
    case other
}

/// Olayın göründüğü yer.
public enum ConversionSurface: String, Sendable, Codable, CaseIterable {
    /// iPhone'un tam ekran abonelik ekranı.
    case paywall
    /// Mac'teki planlar sayfası.
    case sheet
    /// Mac'te alttaki teklif şeridi, iPhone'da ana ekrandaki teklif kartı.
    case strip
    /// Kullanım bildirimi (aylık sınır).
    case banner
    /// Yerel bildirim.
    case notification
    /// Ayarlar.
    case settings
    /// Hesap ekranı ("Abone ol", "Planı değiştir").
    case account
    /// Satın almadan sonraki onay.
    case confirmation
}

/// Teklifin açılma nedeni (sunucunun `conversionTriggers`'ı).
public enum ConversionTrigger: String, Sendable, Codable, CaseIterable {
    case trialNoteReady = "trial_note_ready"
    case trialEnding = "trial_ending"
    case trialEnded = "trial_ended"
    case subscriptionRequired = "subscription_required"
    case planChoice = "plan_choice"
    case monthlyWarning = "monthly_warning"
    case monthlyFull = "monthly_full"
    case winBack = "win_back"
    case trialReminder = "trial_reminder"
    /// Kullanıcı kaydı başlatmak istedi ama hakkı yok (toplantı başlıyor).
    case meetingStart = "meeting_start"
}

/// Ekranda sunulan katmanlar.
public enum ConversionTiersOffered: String, Sendable, Codable, CaseIterable {
    case personal
    case personalPro = "personal_pro"
}

/// Satın almanın başarısız olma nedeni (sabit sınıf; hata metni gönderilmez).
public enum ConversionReason: String, Sendable, Codable, CaseIterable {
    case productsUnavailable = "products_unavailable"
    case storeError = "store_error"
    case paymentPending = "payment_pending"
    case purchaseNotAllowed = "purchase_not_allowed"
    case network
    case server
    case entitlementTimeout = "entitlement_timeout"
    case notSignedIn = "not_signed_in"
    case configuration
}

/// Geri yükleme ("Satın Alımları Geri Yükle", Mac'te "Planımı yenile") sonucu.
public enum ConversionRestoreResult: String, Sendable, Codable, CaseIterable {
    case restored
    case nothingFound = "nothing_found"
}

/// Deneme hatırlatmasının kanalı.
public enum ConversionChannel: String, Sendable, Codable, CaseIterable {
    case inApp = "in_app"
    case notification
}

/// Huni olayı: her tür yalnızca kendi alanlarını taşır (sunucunun katı şemasıyla aynı).
public enum ConversionEvent: Sendable, Hashable, Codable {
    case paywallShown(surface: ConversionSurface, trigger: ConversionTrigger, tiersOffered: ConversionTiersOffered)
    case paywallClosed(surface: ConversionSurface, trigger: ConversionTrigger)
    case planSelected(surface: ConversionSurface, trigger: ConversionTrigger, tier: HostedTier, plan: HostedBillingPlan)
    case purchaseStarted(surface: ConversionSurface, trigger: ConversionTrigger, tier: HostedTier, plan: HostedBillingPlan)
    case purchaseCancelled(surface: ConversionSurface, trigger: ConversionTrigger, tier: HostedTier, plan: HostedBillingPlan)
    case purchaseCompleted(surface: ConversionSurface, trigger: ConversionTrigger, tier: HostedTier, plan: HostedBillingPlan)
    case purchaseFailed(surface: ConversionSurface, trigger: ConversionTrigger, reason: ConversionReason)
    case purchaseRestored(surface: ConversionSurface, result: ConversionRestoreResult)
    case trialReminderShown(channel: ConversionChannel)
    case trialReminderTapped(channel: ConversionChannel)
    case trialReminderOptIn
    case upsellShown(trigger: ConversionTrigger)
    case upsellTapped(trigger: ConversionTrigger)
    case heardAbout(source: AcquisitionSource)

    /// Olayın türü.
    public var kind: ConversionEventKind {
        switch self {
        case .paywallShown: .paywallShown
        case .paywallClosed: .paywallClosed
        case .planSelected: .planSelected
        case .purchaseStarted: .purchaseStarted
        case .purchaseCancelled: .purchaseCancelled
        case .purchaseCompleted: .purchaseCompleted
        case .purchaseFailed: .purchaseFailed
        case .purchaseRestored: .purchaseRestored
        case .trialReminderShown: .trialReminderShown
        case .trialReminderTapped: .trialReminderTapped
        case .trialReminderOptIn: .trialReminderOptIn
        case .upsellShown: .upsellShown
        case .upsellTapped: .upsellTapped
        case .heardAbout: .heardAbout
        }
    }
}

/// Bir huni olayının birikmiş sayısı (aynı olay, aynı alanlar).
public struct ConversionCount: Sendable, Equatable, Codable {
    public let event: ConversionEvent
    public let count: Int

    public init(event: ConversionEvent, count: Int) {
        self.event = event
        self.count = count
    }
}

/// Huni olayını bekleyenlere ekler: aynı olay (tür ve bütün alanlar aynı) tek satırda toplanır, sayı sınırda kalır. Saf
/// fonksiyondur.
public func addingConversion(pending: TelemetryPendingEvents, event: ConversionEvent) -> TelemetryPendingEvents {
    let current: Int = pending.conversions.first { $0.event == event }?.count ?? 0
    let others: [ConversionCount] = pending.conversions.filter { $0.event != event }
    return TelemetryPendingEvents(
        counts: pending.counts, durations: pending.durations,
        conversions: others + [ConversionCount(event: event, count: min(current + 1, telemetryMaxCount))]
    )
}

/// Gövdedeki huni olayı: yalnızca türün alanları yazılır (boş alan gönderilmez; sunucu fazla alanı reddeder).
struct ConversionEventBody: Encodable {
    let kind: String
    let surface: String?
    let trigger: String?
    let tiersOffered: String?
    let tier: String?
    let plan: String?
    let reason: String?
    let result: String?
    let channel: String?
    let source: String?
    let count: Int
}

/// Huni olayının gövdesi. Saf fonksiyondur.
func conversionEventBody(count: ConversionCount) -> ConversionEventBody {
    let kind: String = count.event.kind.rawValue
    switch count.event {
    case .paywallShown(let surface, let trigger, let tiersOffered):
        return ConversionEventBody(
            kind: kind, surface: surface.rawValue, trigger: trigger.rawValue, tiersOffered: tiersOffered.rawValue, tier: nil, plan: nil, reason: nil,
            result: nil, channel: nil, source: nil, count: count.count
        )
    case .paywallClosed(let surface, let trigger):
        return ConversionEventBody(
            kind: kind, surface: surface.rawValue, trigger: trigger.rawValue, tiersOffered: nil, tier: nil, plan: nil, reason: nil, result: nil,
            channel: nil, source: nil, count: count.count
        )
    case .planSelected(let surface, let trigger, let tier, let plan), .purchaseStarted(let surface, let trigger, let tier, let plan),
         .purchaseCancelled(let surface, let trigger, let tier, let plan), .purchaseCompleted(let surface, let trigger, let tier, let plan):
        return ConversionEventBody(
            kind: kind, surface: surface.rawValue, trigger: trigger.rawValue, tiersOffered: nil, tier: tier.rawValue, plan: plan.rawValue, reason: nil,
            result: nil, channel: nil, source: nil, count: count.count
        )
    case .purchaseFailed(let surface, let trigger, let reason):
        return ConversionEventBody(
            kind: kind, surface: surface.rawValue, trigger: trigger.rawValue, tiersOffered: nil, tier: nil, plan: nil, reason: reason.rawValue,
            result: nil, channel: nil, source: nil, count: count.count
        )
    case .purchaseRestored(let surface, let result):
        return ConversionEventBody(
            kind: kind, surface: surface.rawValue, trigger: nil, tiersOffered: nil, tier: nil, plan: nil, reason: nil, result: result.rawValue,
            channel: nil, source: nil, count: count.count
        )
    case .trialReminderShown(let channel), .trialReminderTapped(let channel):
        return ConversionEventBody(
            kind: kind, surface: nil, trigger: nil, tiersOffered: nil, tier: nil, plan: nil, reason: nil, result: nil, channel: channel.rawValue,
            source: nil, count: count.count
        )
    case .trialReminderOptIn:
        return ConversionEventBody(
            kind: kind, surface: nil, trigger: nil, tiersOffered: nil, tier: nil, plan: nil, reason: nil, result: nil, channel: nil, source: nil, count: count.count
        )
    case .upsellShown(let trigger), .upsellTapped(let trigger):
        return ConversionEventBody(
            kind: kind, surface: nil, trigger: trigger.rawValue, tiersOffered: nil, tier: nil, plan: nil, reason: nil, result: nil, channel: nil,
            source: nil, count: count.count
        )
    case .heardAbout(let source):
        return ConversionEventBody(
            kind: kind, surface: nil, trigger: nil, tiersOffered: nil, tier: nil, plan: nil, reason: nil, result: nil, channel: nil,
            source: source.rawValue, count: count.count
        )
    }
}

/// iPhone'da kullanıcının "Anonim kullanım istatistiklerini paylaş"ı kendisinin açtığının kaydı (UserDefaults, Bool):
/// varsayılan açık ayar tek başına izin sayılmaz (App Store 5.1.1(ii)); kullanıcı açınca true, kapatınca false olur.
public let shareUsageStatisticsExplicitOptInDefaultsKey: String = "privacy.shareUsageStatistics.explicitOptIn"

/// Huni olaylarının hangi izinle gönderildiği.
public enum ConversionTelemetryConsent: Sendable, Equatable {
    /// Mac: "Anonim kullanım istatistiklerini paylaş" ayarı yeter (App Store dışında dağıtılır; öbür olaylarla aynı).
    case sharingSetting
    /// iPhone: kullanıcı paylaşımı kendisi açmış olmalı (`given`: açık izin kaydı var mı).
    case explicitOptIn(given: Bool)
}

/// Huni olayları kaydedilip gönderilebilir mi: telemetri izni (`telemetrySendingAllowed`) ve iPhone'da açık izin. Saf
/// fonksiyondur.
public func conversionTelemetryAllowed(edition: AppEdition, sharingEnabled: Bool, consent: ConversionTelemetryConsent) -> Bool {
    guard telemetrySendingAllowed(edition: edition, sharingEnabled: sharingEnabled) else {
        return false
    }
    switch consent {
    case .sharingSetting:
        return true
    case .explicitOptIn(let given):
        return given
    }
}

/// Ekranda sunulan katmanların huni değeri: Pro da sunuluyorsa `personal_pro`. Saf fonksiyondur.
public func conversionTiersOffered(tiers: [HostedTier]) -> ConversionTiersOffered {
    tiers.contains(.pro) ? .personalPro : .personal
}

/// İstemci hatasının huni nedeni (her durum açıkça eşlenir). Saf fonksiyondur.
public func conversionReason(clientError: HostedClientError) -> ConversionReason {
    switch clientError {
    case .notSignedIn, .sessionEnded:
        .notSignedIn
    case .insecureBaseURL, .invalidBaseURL, .keychainServiceNotConfigured, .invalidAppVersion, .aiConsentRequired:
        .configuration
    case .offlineNotAllowed, .offlineRecording, .network:
        .network
    case .noActiveMeeting, .malformedResponse, .serverOutdated:
        .server
    }
}

/// Mac'te ödeme sayfası açılamadı ya da iPhone'da hak beklenirken gelen hatanın huni nedeni: istemci hatası kendi
/// eşlemesiyle (`conversionReason(clientError:)`), sunucunun reddi `server`, satın alınan hakkın gelmemesi
/// `entitlement_timeout`. Başka türler (ör. Anahtar Zinciri) uygulamanın kendi yapılandırmasındandır: `configuration`.
/// Saf fonksiyondur.
public func conversionReason(error: any Error) -> ConversionReason {
    switch error {
    case let clientError as HostedClientError:
        conversionReason(clientError: clientError)
    case is HostedAPIError:
        .server
    case is HostedAppStoreEntitlementMissing:
        .entitlementTimeout
    default:
        .configuration
    }
}
