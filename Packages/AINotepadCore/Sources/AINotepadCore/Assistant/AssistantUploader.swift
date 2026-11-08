import Foundation
import os

private let assistantUploadLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Assistant")

// Asistan kopyasının yükleme kuyruğu. Kuyruk diskteki defterle (`AssistantUploadLedger`) yerel toplantılar
// arasındaki farktır: defter bu cihazın sunucuya yüklediği her toplantının parmak izini ve hangi dönemde (epoch)
// yüklendiğini tutar. Değişen ya da yeni toplantı yüklenir (en yeniden eskiye), yerelde artık olmayan silinir. Defter
// her adımdan sonra diske yazıldığı için uygulama kapanıp açılınca iş kaldığı yerden sürer; silinen toplantı da
// uygulama kapalıyken silinmiş olsa bile defterde durduğu için sunucudan silinir.

/// Bu cihazın asistan kopyasına yüklediklerinin defteri (hesap başına bir dosya).
public struct AssistantUploadLedger: Sendable, Equatable, Codable {
    /// Defterdeki yüklemelerin dönemi; özellik kapalıyken nil.
    public var epoch: Int64?
    /// Toplantı kimliği → sunucudaki kopyanın parmak izi.
    public var uploaded: [String: String]
    /// Sunucunun kalıcı olarak reddettiği (ör. çok büyük) kopyalar: kimlik → parmak izi. Toplantı değişince ya da
    /// kullanıcı "Yeniden dene" deyince yeniden denenir.
    public var rejected: [String: String]
    /// Reddedilen kopyaların nedeni: kimlik → neden. Bu alan eklenmeden önce yazılan defterlerin reddedilenlerinde
    /// neden yoktur.
    public var rejectionReasons: [String: AssistantRejectionReason]

    public init(epoch: Int64?, uploaded: [String: String], rejected: [String: String], rejectionReasons: [String: AssistantRejectionReason]) {
        self.epoch = epoch
        self.uploaded = uploaded
        self.rejected = rejected
        self.rejectionReasons = rejectionReasons
    }

    private enum CodingKeys: String, CodingKey {
        case epoch
        case uploaded
        case rejected
        case rejectionReasons
    }

    /// Eski sürümlerin defterinde `rejectionReasons` yoktur: o defterler nedensiz okunur (dosya biçiminin eski hâli).
    public init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try container.decodeIfPresent(Int64.self, forKey: .epoch)
        uploaded = try container.decode([String: String].self, forKey: .uploaded)
        rejected = try container.decode([String: String].self, forKey: .rejected)
        rejectionReasons = try container.decodeIfPresent([String: AssistantRejectionReason].self, forKey: .rejectionReasons) ?? [:]
    }

    public static let empty: AssistantUploadLedger = AssistantUploadLedger(epoch: nil, uploaded: [:], rejected: [:], rejectionReasons: [:])
}

/// Sunucunun bir kopyayı kalıcı olarak reddetme nedeni.
public enum AssistantRejectionReason: String, Sendable, Equatable, Codable {
    /// Not, kopyanın üst sınırından büyük (`payload_too_large` ya da istemcideki sınır).
    case tooLarge = "too_large"
    /// Sunucu isteği geçersiz buldu (`bad_request`, `invalid_body`).
    case invalid
}

/// Kopyaya girecek bir yerel toplantı: kopya ve parmak izi.
public struct AssistantLocalMeeting: Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public let copy: AssistantMeetingCopy
    public let fingerprint: String

    public init(id: String, startedAt: Date, copy: AssistantMeetingCopy, fingerprint: String) {
        self.id = id
        self.startedAt = startedAt
        self.copy = copy
        self.fingerprint = fingerprint
    }
}

/// Bir geçişte yapılacaklar: silinecekler ve yüklenecekler (en yeni toplantı önce).
public struct AssistantUploadPlan: Sendable, Equatable {
    public let deletions: [String]
    public let uploads: [String]

    public var isEmpty: Bool { deletions.isEmpty && uploads.isEmpty }
}

/// Bu cihazdaki toplantılardan kaçının kopyası güncel, kaçını sunucu kabul etmedi.
public struct AssistantUploadProgress: Sendable, Equatable {
    /// Kopyası sunucuda güncel olanlar.
    public let uploaded: Int
    /// Sunucunun bu hâliyle reddettiği toplantılar: güncel sayılmaz, toplantı değişene ya da yeniden denenene dek
    /// beklemede.
    public let rejected: Int
    /// Reddedilenlerin ortak nedeni; hiç yoksa, nedenler karışıksa ya da kaydedilmediyse nil.
    public let rejectionReason: AssistantRejectionReason?
    public let total: Int

    public init(uploaded: Int, rejected: Int, rejectionReason: AssistantRejectionReason?, total: Int) {
        self.uploaded = uploaded
        self.rejected = rejected
        self.rejectionReason = rejectionReason
        self.total = total
    }

    /// Yapılacak yükleme kalmadı (reddedilenler bekler; güncel oldukları anlamına gelmez).
    public var isComplete: Bool { uploaded + rejected >= total }
}

/// Toplantıların kopyaya girenleri (`assistantMeetingCopy`), parmak izleriyle. Saf fonksiyondur.
public func assistantLocalMeetings(records: [MeetingRecord], userName: String) throws -> [AssistantLocalMeeting] {
    try records.compactMap { (record: MeetingRecord) -> AssistantLocalMeeting? in
        guard let copy = assistantMeetingCopy(record: record, userName: userName) else {
            return nil
        }
        return AssistantLocalMeeting(id: record.id, startedAt: record.startedAt, copy: copy, fingerprint: try assistantFingerprint(copy: copy))
    }
}

/// Defter sunucunun ayarına göre: özellik kapalıysa boş (sunucu kopyayı zaten sildi); dönem değiştiyse (başka cihazda
/// kapatılıp açıldı) yüklemeler unutulur ve her şey yeni dönemde baştan yüklenir; aynı dönemse defter olduğu gibi. Saf
/// fonksiyondur.
public func assistantLedger(ledger: AssistantUploadLedger, settings: HostedAssistantSettings) -> AssistantUploadLedger {
    guard settings.enabled else {
        return .empty
    }
    guard ledger.epoch == settings.epoch else {
        return AssistantUploadLedger(epoch: settings.epoch, uploaded: [:], rejected: [:], rejectionReasons: [:])
    }
    return ledger
}

/// Reddedilenler unutulmuş defter: sonraki geçiş onları yeniden yükler ("Yeniden dene"). Saf fonksiyondur.
public func assistantLedgerRetryingRejected(ledger: AssistantUploadLedger) -> AssistantUploadLedger {
    AssistantUploadLedger(epoch: ledger.epoch, uploaded: ledger.uploaded, rejected: [:], rejectionReasons: [:])
}

/// Geçişin planı: defterde olup yerelde olmayanlar silinir; yeni ya da değişen (parmak izi farklı, reddedilen hâliyle de
/// aynı olmayan) toplantılar en yeniden eskiye yüklenir. Saf fonksiyondur.
public func assistantUploadPlan(local: [AssistantLocalMeeting], ledger: AssistantUploadLedger) -> AssistantUploadPlan {
    let localIDs: Set<String> = Set(local.map(\.id))
    let deletions: [String] = ledger.uploaded.keys.filter { !localIDs.contains($0) }.sorted()
    let uploads: [String] = local
        .filter { (meeting: AssistantLocalMeeting) -> Bool in
            ledger.uploaded[meeting.id] != meeting.fingerprint && ledger.rejected[meeting.id] != meeting.fingerprint
        }
        .sorted { (left: AssistantLocalMeeting, right: AssistantLocalMeeting) -> Bool in
            left.startedAt == right.startedAt ? left.id < right.id : left.startedAt > right.startedAt
        }
        .map(\.id)
    return AssistantUploadPlan(deletions: deletions, uploads: uploads)
}

/// Yerel toplantılardan kopyası güncel olanlar ve sunucunun bu hâliyle reddettikleri (ayrı sayılır: reddedilen güncel
/// değildir, yalnızca toplantı değişene ya da yeniden denenene dek yüklenmez). Saf fonksiyondur.
public func assistantUploadProgress(local: [AssistantLocalMeeting], ledger: AssistantUploadLedger) -> AssistantUploadProgress {
    let current: Int = local.filter { ledger.uploaded[$0.id] == $0.fingerprint }.count
    let refused: [String] = local
        .filter { ledger.uploaded[$0.id] != $0.fingerprint && ledger.rejected[$0.id] == $0.fingerprint }
        .map(\.id)
    let reasons: Set<AssistantRejectionReason?> = Set(refused.map { ledger.rejectionReasons[$0] })
    return AssistantUploadProgress(uploaded: current, rejected: refused.count, rejectionReason: reasons.count == 1 ? reasons.first.flatMap { $0 } : nil, total: local.count)
}

/// Bilinenlerde olmayan bağlantılar (yeni bağlanan asistan bildirimi). Bilinen liste hiç kaydedilmediyse (bu cihaz ilk
/// kez soruyor) hiçbiri yeni sayılmaz: o anki liste taban olur. Saf fonksiyondur.
public func newAssistantGrants(known: Set<String>?, current: [HostedAssistantGrant]) -> [HostedAssistantGrant] {
    guard let known else {
        return []
    }
    return current.filter { !known.contains($0.grantId) }
}

/// Bağlantının gösterilen adı: doğrulanmış üründe kendi adı; doğrulanmamışta yönlendirme adresinin sunucusu (adını
/// istemci kendisi seçer, güvenilmez). Saf fonksiyondur.
public func assistantGrantDisplayName(grant: HostedAssistantGrant) -> String {
    let name: String = grant.clientName.trimmingCharacters(in: .whitespacesAndNewlines)
    return grant.verified && !name.isEmpty ? name : grant.redirectHost
}

/// Sunucunun bir kopyayı kalıcı olarak reddettiği hatanın nedeni (yeniden denemek aynı sonucu verir); geçici ya da
/// başka bir hatada nil. Saf fonksiyondur.
func assistantRejectionReason(error: any Error) -> AssistantRejectionReason? {
    if case HostedAssistantError.copyTooLarge = error {
        return .tooLarge
    }
    guard let apiError = error as? HostedAPIError else {
        return nil
    }
    switch apiError.code {
    case .payloadTooLarge: return .tooLarge
    case .invalidBody, .badRequest: return .invalid
    default: return nil
    }
}

/// Defter dosyası.
public struct AssistantLedgerFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() throws -> AssistantUploadLedger {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            return try JSONDecoder().decode(AssistantUploadLedger.self, from: Data(contentsOf: url))
        } catch {
            throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public func write(ledger: AssistantUploadLedger) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try canonicalSyncJSON(value: ledger).write(to: url, options: .atomic)
        } catch {
            throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}

/// Bir geçiş sürerken defterde geçişin dışından yapılan değişikliklerin sayaçları: "unut" (`forgetUploads`) ve
/// "Yeniden dene" (`retryRejected`). Geçiş son gördüğü sayaçları her yazımdan önce güncelleriyle karşılaştırır
/// (`assistantLedgerWrite`).
public struct AssistantLedgerResets: Sendable, Equatable {
    public let forgets: UInt64
    public let retries: UInt64

    public init(forgets: UInt64, retries: UInt64) {
        self.forgets = forgets
        self.retries = retries
    }
}

/// Geçişin bellekteki defteri diske yazarken ne yapacağı.
public enum AssistantLedgerWrite: Sendable, Equatable {
    /// Bu defteri yaz (gerekirse reddedilenler unutulmuş hâliyle).
    case write(AssistantUploadLedger)
    /// Geçiş defteri okuduktan sonra defter unutuldu ("bu cihazı kaldır", kapatma): geçiş hiçbir şey yazmadan biter;
    /// yoksa eski defteri geri yazar ve sonraki geçiş unutulan toplantıları yüklenmiş sanardı.
    case abandon
}

/// Geçişin son gördüğü sayaçlarla şimdikilere göre yazım kararı: arada "unut" geldiyse yazılmaz; yalnızca "Yeniden
/// dene" geldiyse reddedilenler unutulmuş defter yazılır (isteği geri almasın). Saf fonksiyondur.
public func assistantLedgerWrite(ledger: AssistantUploadLedger, seen: AssistantLedgerResets, current: AssistantLedgerResets) -> AssistantLedgerWrite {
    guard seen.forgets == current.forgets else {
        return .abandon
    }
    guard seen.retries == current.retries else {
        return .write(assistantLedgerRetryingRejected(ledger: ledger))
    }
    return .write(ledger)
}

/// Yükleyicinin kendi hataları.
public enum AssistantUploaderError: Error, Sendable, Equatable {
    /// Geçiş sürerken defter unutuldu (`forgetUploads`): geçiş yazmadan durdu; yeni geçiş baştan başlar.
    case ledgerForgotten
}

/// Bir geçişin sonucu.
public struct AssistantPassReport: Sendable, Equatable {
    /// Geçişin sonundaki ayar (kapalıysa `enabled` false: başka cihazda kapatıldı).
    public let settings: HostedAssistantSettings
    public let uploaded: Int
    public let deleted: Int
    /// Sunucunun reddettiği toplantılar (değişince yeniden denenir).
    public let rejected: Int
    public let progress: AssistantUploadProgress
}

/// Bir hesabın bu cihazdaki asistan kopyası yükleyicisi. Geçişler sırayla çalışır (aktör); her adımdan sonra defter
/// diske yazılır. Dönem uyuşmazlığında (409: başka cihazda kapatılıp açıldı) ayar yeniden okunur ve her şey yeni dönemde
/// baştan yüklenir; özellik kapatıldıysa defter boşalır ve geçiş biter. Ağ ve geçici sunucu hataları istemcide yeniden
/// denenir (`sendHostedRequest`); yine de olmazsa hata fırlatılır, uygulama artan beklemeyle yeni geçiş başlatır.
/// İçerik ve başlık loglanmaz.
public actor AssistantUploader {
    private let client: any HostedAssistantAPI
    private let file: AssistantLedgerFile
    private let deviceID: String
    /// Bir geçişte en fazla bu kadar dönem değişikliği izlenir (sonsuz döngü olmasın).
    private let maxEpochRounds: Int = 3
    /// Defterin geçiş dışındaki değişikliklerinin sayaçları (`assistantLedgerWrite`). Her geçiş kendi gördüğünü tutar:
    /// aktör yeniden girişe açık olduğu için iki geçiş ya da geçişle "unut" iç içe çalışabilir.
    private var resets: AssistantLedgerResets = AssistantLedgerResets(forgets: 0, retries: 0)

    public init(client: any HostedAssistantAPI, file: AssistantLedgerFile, deviceID: String) {
        self.client = client
        self.file = file
        self.deviceID = deviceID
    }

    /// Diskteki defter.
    public func ledger() throws -> AssistantUploadLedger {
        try file.read()
    }

    /// Kopyayı yerel toplantılarla eşler: önce silinenler, sonra yeni ve değişenler en yeniden eskiye. Her yükleme ya da
    /// silmeden sonra `progress` çağrılır.
    public func pass(records: [MeetingRecord], userName: String, progress: @Sendable (AssistantUploadProgress) -> Void) async throws -> AssistantPassReport {
        let local: [AssistantLocalMeeting] = try assistantLocalMeetings(records: records, userName: userName)
        let byID: [String: AssistantLocalMeeting] = Dictionary(local.map { ($0.id, $0) }) { (first: AssistantLocalMeeting, _: AssistantLocalMeeting) -> AssistantLocalMeeting in first }
        var seen: AssistantLedgerResets = resets
        var settings: HostedAssistantSettings = try await client.settings()
        try requireLedger(seen: seen)
        var ledger: AssistantUploadLedger = try store(ledger: assistantLedger(ledger: try file.read(), settings: settings), seen: &seen)
        var uploaded: Int = 0
        var deleted: Int = 0
        var rejected: Int = 0
        var rounds: Int = 0
        progress(assistantUploadProgress(local: local, ledger: ledger))
        passLoop: while settings.enabled, let epoch = ledger.epoch {
            let plan: AssistantUploadPlan = assistantUploadPlan(local: local, ledger: ledger)
            for meetingID in plan.deletions {
                try Task.checkCancellation()
                try requireLedger(seen: seen)
                try await client.deleteMeeting(meetingID: meetingID)
                ledger.uploaded[meetingID] = nil
                ledger = try store(ledger: ledger, seen: &seen)
                deleted += 1
            }
            for meetingID in plan.uploads {
                try Task.checkCancellation()
                try requireLedger(seen: seen)
                guard let meeting = byID[meetingID] else {
                    continue
                }
                do {
                    try await client.putMeeting(meetingID: meetingID, upload: AssistantMeetingUpload(epoch: epoch, deviceId: deviceID, copy: meeting.copy))
                    ledger.uploaded[meetingID] = meeting.fingerprint
                    ledger.rejected[meetingID] = nil
                    ledger.rejectionReasons[meetingID] = nil
                    uploaded += 1
                } catch HostedAssistantError.epochMismatch, HostedAssistantError.notEnabled {
                    rounds += 1
                    assistantUploadLogger.warning("Assistant upload refused for an old epoch, rereading settings, round: \(rounds, privacy: .public)")
                    guard rounds < maxEpochRounds else {
                        throw HostedAssistantError.epochMismatch
                    }
                    settings = try await client.settings()
                    ledger = try store(ledger: assistantLedger(ledger: ledger, settings: settings), seen: &seen)
                    continue passLoop
                } catch let error where assistantRejectionReason(error: error) != nil {
                    assistantUploadLogger.error("Assistant copy refused, skipped until the meeting changes, error: \(String(describing: error), privacy: .private)")
                    // Sunucudaki eski kopya (varsa) defterde kalır: toplantı silinirse o da silinir; parmak izi farklı
                    // olduğu için güncel sayılmaz.
                    ledger.rejected[meetingID] = meeting.fingerprint
                    ledger.rejectionReasons[meetingID] = assistantRejectionReason(error: error)
                    rejected += 1
                }
                ledger = try store(ledger: ledger, seen: &seen)
                progress(assistantUploadProgress(local: local, ledger: ledger))
            }
            break
        }
        if settings.enabled, uploaded + deleted > 0 {
            // Sunucudaki toplantı sayısı (bütün cihazlardan) değişti.
            settings = try await client.settings()
        }
        let finalProgress: AssistantUploadProgress = assistantUploadProgress(local: local, ledger: ledger)
        progress(finalProgress)
        return AssistantPassReport(settings: settings, uploaded: uploaded, deleted: deleted, rejected: rejected, progress: finalProgress)
    }

    /// Özellik kapatıldı ya da bu cihazın toplantıları sunucudan kaldırıldı: defter boşalır (dönem kalır; kapatmada
    /// sonraki geçiş zaten yeni dönemi okur). Süren bir geçiş bundan sonra defteri yazmaz, yükleme de yapmaz
    /// (`AssistantUploaderError.ledgerForgotten`).
    public func forgetUploads() throws {
        resets = AssistantLedgerResets(forgets: resets.forgets + 1, retries: resets.retries)
        let current: AssistantUploadLedger = try file.read()
        try file.write(ledger: AssistantUploadLedger(epoch: current.epoch, uploaded: [:], rejected: [:], rejectionReasons: [:]))
    }

    /// Reddedilenleri unutur: sonraki geçiş onları yeniden yükler (Ayarlar'daki "Yeniden dene"). Süren bir geçişin
    /// sonraki yazımı da reddedilenleri unutur.
    public func retryRejected() throws {
        resets = AssistantLedgerResets(forgets: resets.forgets, retries: resets.retries + 1)
        try file.write(ledger: assistantLedgerRetryingRejected(ledger: try file.read()))
    }

    /// Geçiş defteri okuduktan sonra defter unutulduysa geçiş durur.
    private func requireLedger(seen: AssistantLedgerResets) throws {
        guard seen.forgets == resets.forgets else {
            throw AssistantUploaderError.ledgerForgotten
        }
    }

    /// Geçişin defterini `assistantLedgerWrite` kararına göre diske yazar; geçişin gördüğü sayaçlar güncellenir.
    private func store(ledger: AssistantUploadLedger, seen: inout AssistantLedgerResets) throws -> AssistantUploadLedger {
        switch assistantLedgerWrite(ledger: ledger, seen: seen, current: resets) {
        case .abandon:
            throw AssistantUploaderError.ledgerForgotten
        case .write(let next):
            try file.write(ledger: next)
            seen = resets
            return next
        }
    }
}

/// Asistanlara eklenen uzak bağlayıcının adresi (`gistsmith-mcp` Worker'ı, `server/wrangler.mcp.jsonc`; kaynak tam bu
/// adrestir, sonundaki eğik çizgi yok).
public let hostedAssistantConnectorURL: String = "https://mcp.gistsmith.com/mcp"

public extension AppPaths {
    /// Hesabın asistan kopyası defteri: `<veri klasörü>/Accounts/<anahtar>/Assistant/ledger.json`. Saf fonksiyondur.
    static func accountAssistantLedger(dataRoot: URL, accountKey: String) -> URL {
        accountDataDirectory(dataRoot: dataRoot, accountKey: accountKey)
            .appending(path: "Assistant", directoryHint: .isDirectory)
            .appending(path: "ledger.json", directoryHint: .notDirectory)
    }
}
