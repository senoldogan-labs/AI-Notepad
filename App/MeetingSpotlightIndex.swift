import AINotepadCore
import CoreSpotlight
import Foundation
import os
import UniformTypeIdentifiers

// Toplantıların sistem aramasındaki (Spotlight) kopyası, Mac ve iPhone ortak. Ne girdiği `spotlightMeetingEntries`'te:
// başlık, tarih, kişiler, notun özeti ve görevleri; transkript, ses, ekranlar ve kendi notların girmez, örnek toplantı
// hiç girmez. Dizin bu cihazdadır (Apple'a gitmez). Ayar kapalıyken, oturum kapanınca ya da hesap silinince bütün
// dizin silinir; hesap değişince eski hesabın toplantıları farkla çıkar. Sonuca dokununca toplantı açılır
// (`spotlightMeetingID`).

/// Ayar anahtarı: toplantılar Spotlight'ta görünsün mü (varsayılan açık).
let spotlightMeetingsSettingKey: String = "spotlight.meetings.enabled"

/// Ayar açık mı (hiç değiştirilmediyse açık).
func isSpotlightMeetingsEnabled(defaults: UserDefaults) -> Bool {
    defaults.object(forKey: spotlightMeetingsSettingKey) as? Bool ?? true
}

/// Spotlight sonucunun (ya da bağlı niyetin) açtığı toplantı: etkinlik bir Spotlight sonucuysa kimliği, değilse nil.
func spotlightMeetingID(activity: NSUserActivity) -> String? {
    guard activity.activityType == CSSearchableItemActionType else {
        return nil
    }
    return activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
}

/// Dizinin bağdaştırıcısı: istenen son toplantı listesini kısa bir beklemeden sonra (art arda değişiklikler birleşir)
/// farkla yazar. İşlemler sırayla, ana iş parçacığını bekletmeden yapılır.
@MainActor
final class MeetingSpotlightIndex {
    static let shared: MeetingSpotlightIndex = MeetingSpotlightIndex()

    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Spotlight")
    /// Art arda gelen değişikliklerin birleştiği süre.
    private static let settleDelay: Duration = .seconds(1.5)
    /// Spotlight'taki alan: bütün öğeler bunun içinde (silme alanla yapılır).
    private static let domain: String = "meetings"

    private let index: CSSearchableIndex = CSSearchableIndex(name: "meetings")
    /// Bu süreçte dizine son yazılanlar; nil: dizinde ne olduğu bilinmiyor (açılış ya da başarısız yazma), sıradaki
    /// yazma alanı silip baştan kurar.
    private var indexed: [String: SpotlightMeetingEntry]?
    /// Yazılmayı bekleyen son istek (girdiler bekleme bitince bir kez hesaplanır); `isEmptying` dizinin boşalmasıdır.
    private var latest: (records: [MeetingRecord], userName: String, isEmptying: Bool)?
    private var worker: Task<Void, Never>?

    private init() {}

    /// Toplantılar değişti: `isAllowed` (ayar açık, abonelikte hesap yüklü) değilse dizin boşalır, öyleyse farkla yazılır.
    func update(records: [MeetingRecord], userName: String, isAllowed: Bool) {
        if isAllowed, isSpotlightMeetingsEnabled(defaults: .standard) {
            latest = (records: records, userName: userName, isEmptying: false)
        } else {
            latest = (records: [], userName: "", isEmptying: true)
        }
        startWorker()
    }

    /// Bütün dizini siler (ayar kapandı, oturum kapandı, hesap silindi).
    func removeAll() {
        latest = (records: [], userName: "", isEmptying: true)
        startWorker()
    }

    private func startWorker() {
        guard worker == nil else {
            return
        }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        defer { worker = nil }
        while latest != nil {
            do {
                try await Task.sleep(for: Self.settleDelay)
            } catch {
                return
            }
            // Beklerken yeni istek geldiyse en sonuncusu yazılır.
            guard let current = latest else {
                return
            }
            latest = nil
            let entries: [SpotlightMeetingEntry] = current.isEmptying ? [] : spotlightMeetingEntries(records: current.records, userName: current.userName)
            await apply(entries: entries, isEmptying: current.isEmptying)
        }
    }

    private func apply(entries: [SpotlightMeetingEntry], isEmptying: Bool) async {
        do {
            if isEmptying {
                if indexed?.isEmpty != true {
                    try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                    Self.logger.info("Spotlight dizini silindi")
                }
                indexed = [:]
                return
            }
            if indexed == nil {
                try await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
                indexed = [:]
            }
            let plan: SpotlightIndexPlan = spotlightIndexPlan(indexed: indexed ?? [:], current: entries)
            guard !plan.isEmpty else {
                return
            }
            if !plan.deletions.isEmpty {
                try await index.deleteSearchableItems(withIdentifiers: plan.deletions)
            }
            if !plan.upserts.isEmpty {
                try await index.indexSearchableItems(plan.upserts.map(searchableItem(entry:)))
            }
            indexed = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            Self.logger.info("Spotlight dizini güncellendi, yazılan: \(plan.upserts.count, privacy: .public), silinen: \(plan.deletions.count, privacy: .public)")
        } catch {
            // Dizinde ne kaldığı bilinmiyor: sıradaki güncelleme alanı silip baştan kurar.
            indexed = nil
            Self.logger.error("Spotlight dizini yazılamadı, kayıt: \(entries.count, privacy: .public), boşaltma: \(isEmptying, privacy: .public), hata: \(String(describing: error), privacy: .public)")
        }
    }

    /// Spotlight öğesi: başlık, özet ve görevler, kişiler ve klasör anahtar sözcük; tarih toplantının başı ve sonu.
    /// Kısayollar ve Siri aynı toplantıyı tanısın diye toplantı varlığına bağlanır.
    private func searchableItem(entry: SpotlightMeetingEntry) -> CSSearchableItem {
        let attributes: CSSearchableItemAttributeSet = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = entry.title
        attributes.contentDescription = entry.contentDescription
        attributes.keywords = entry.keywords
        attributes.contentCreationDate = entry.startedAt
        attributes.startDate = entry.startedAt
        attributes.endDate = entry.endedAt
        let item: CSSearchableItem = CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: Self.domain, attributeSet: attributes)
        item.associateAppEntity(MeetingEntity(entry: entry), priority: 0)
        return item
    }
}

extension MeetingEntity {
    /// Dizindeki kopyadan varlık (Spotlight'taki öğeye bağlanan).
    init(entry: SpotlightMeetingEntry) {
        id = entry.id
        title = entry.title
        date = entry.startedAt
        summary = entry.summary
    }
}
