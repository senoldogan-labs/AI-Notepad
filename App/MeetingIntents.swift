import AINotepadCore
import AppIntents
import CoreSpotlight
import Foundation
import os

// Kısayollar, Siri ve Spotlight için toplantılar ve görevler (Mac ve iPhone ortak): toplantı ve görev varlıkları, onları
// bulan sorgular ve "Toplantılarına sor", "Görevlerim ne?", "Toplantıyı aç" niyetleri. Uygulamaya özgü kısım (toplantı
// listesi, Sor hattı, gezinme) `MeetingIntentsBackend`'dedir: Mac'te AppModel, iPhone'da yüklü hesabın deposu. Örnek
// toplantı hiçbir yerde önerilmez (`realMeetings`); transkript ve ses niyetlerden çıkmaz.

/// Niyetlerin uygulamaya ulaştığı yer.
@MainActor
protocol MeetingIntentsBackend: AnyObject {
    /// Yüklü hesabın toplantıları (henüz okunmadıysa okunur). Hesap yoksa ya da yüklü değilse `notReady`.
    func intentMeetings() async throws -> [MeetingRecord]
    /// Notlardaki "Sen"in adı (görevler ve adlandırılmış konuşmacılar için).
    func intentUserName() -> String
    /// Toplantıyı uygulamada açar.
    func openMeeting(id: String)
    /// Soruyu bütün toplantılara Sor'daki hatla sorar (sohbet Sor geçmişinde kalır) ve cevabın metnini döndürür.
    func askAcrossMeetings(question: String) async throws -> String
}

/// Spotlight sonucunun toplantısını açar: uygulama sonuçla açıldıysa önce toplantılar okunur (liste henüz boş olabilir).
/// Hesapta olmayan (silinmiş, başka hesabın) toplantı açılmaz; nedeni loglanır.
@MainActor
func openSpotlightMeeting(meetingID: String) async {
    do {
        let backend: any MeetingIntentsBackend = try MeetingIntentsHost.require()
        guard try await backend.intentMeetings().contains(where: { $0.id == meetingID }) else {
            meetingIntentsLogger.warning("Spotlight sonucundaki toplantı bulunamadı, toplantı: \(meetingID, privacy: .public)")
            return
        }
        backend.openMeeting(id: meetingID)
    } catch {
        meetingIntentsLogger.error("Spotlight sonucu açılamadı, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .public)")
    }
}

private let meetingIntentsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "MeetingIntents")

/// Uygulamanın açılışta kurduğu arka uç; kurulmadan çalışan niyet `notReady` verir.
@MainActor
enum MeetingIntentsHost {
    static var backend: (any MeetingIntentsBackend)?

    static func require() throws -> any MeetingIntentsBackend {
        guard let backend else {
            throw MeetingIntentError.notReady
        }
        return backend
    }
}

/// Niyetin kullanıcıya söylenen hatası.
enum MeetingIntentError: Error, CustomLocalizedStringResourceConvertible {
    /// Uygulama hazır değil: oturum yok ya da hesabın verisi yüklenmedi.
    case notReady
    /// İstenen toplantı artık yok (silindi ya da başka hesabındı).
    case meetingNotFound
    /// Soru sorulamadı; nedeni (abonelik, deneme, ağ…) metinde.
    case askFailed(reason: String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            "Önce uygulamayı açıp giriş yap; toplantıların yüklenince yeniden dene."
        case .meetingNotFound:
            "Bu toplantı bulunamadı; silinmiş olabilir."
        case .askFailed(let reason):
            "Soru cevaplanamadı: \(reason)"
        }
    }
}

// MARK: Toplantı

/// Bir toplantı (Kısayollar'da seçilir, Spotlight sonucuna bağlanır, Siri'ye verilir).
struct MeetingEntity: IndexedEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Toplantı", numericFormat: "\(placeholder: .int) toplantı")
    static let defaultQuery: MeetingEntityQuery = MeetingEntityQuery()

    let id: String
    @Property(title: "Başlık")
    var title: String
    @Property(title: "Tarih")
    var date: Date
    @Property(title: "Özet")
    var summary: String

    init(record: MeetingRecord) {
        id = record.id
        title = record.note?.title ?? record.title
        date = record.startedAt
        summary = record.note?.summary ?? ""
    }

    var displayRepresentation: DisplayRepresentation {
        let when: String = date.formatted(date: .abbreviated, time: .shortened)
        return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title), subtitle: LocalizedStringResource(stringLiteral: when), image: .init(systemName: "waveform"))
    }
}

/// Toplantıları kimlikle, aramayla ya da son toplantılar olarak bulur.
struct MeetingEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [MeetingEntity.ID]) async throws -> [MeetingEntity] {
        let wanted: Set<String> = Set(identifiers)
        return realMeetings(records: try await MeetingIntentsHost.require().intentMeetings())
            .filter { wanted.contains($0.id) }
            .map { MeetingEntity(record: $0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MeetingEntity] {
        shortcutMeetings(records: try await MeetingIntentsHost.require().intentMeetings(), query: string).prefix(shortcutSuggestedMeetingCount * 2).map { MeetingEntity(record: $0) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MeetingEntity] {
        shortcutMeetings(records: try await MeetingIntentsHost.require().intentMeetings(), query: "").prefix(shortcutSuggestedMeetingCount).map { MeetingEntity(record: $0) }
    }
}

// MARK: Görev

/// Kullanıcıya düşen açık bir görev.
struct MeetingTaskEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = TypeDisplayRepresentation(name: "Görev", numericFormat: "\(placeholder: .int) görev")
    static let defaultQuery: MeetingTaskEntityQuery = MeetingTaskEntityQuery()

    let id: String
    @Property(title: "Görev")
    var title: String
    @Property(title: "Son tarih")
    var dueDate: String?
    @Property(title: "Toplantı")
    var meetingTitle: String
    let meetingID: String

    init(task: ShortcutTask) {
        id = task.id
        meetingID = task.meetingID
        title = task.description
        dueDate = task.dueDate
        meetingTitle = task.meetingTitle
    }

    var displayRepresentation: DisplayRepresentation {
        let subtitle: String = [dueDate, meetingTitle].compactMap { $0 }.joined(separator: " · ")
        return DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title), subtitle: LocalizedStringResource(stringLiteral: subtitle), image: .init(systemName: "checklist"))
    }
}

/// Açık görevleri kimlikle ya da hepsini bulur.
struct MeetingTaskEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [MeetingTaskEntity.ID]) async throws -> [MeetingTaskEntity] {
        let wanted: Set<String> = Set(identifiers)
        return try await openTasks().filter { wanted.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [MeetingTaskEntity] {
        try await openTasks()
    }

    @MainActor
    private func openTasks() async throws -> [MeetingTaskEntity] {
        let backend: any MeetingIntentsBackend = try MeetingIntentsHost.require()
        return openShortcutTasks(records: try await backend.intentMeetings(), userName: backend.intentUserName()).map { MeetingTaskEntity(task: $0) }
    }
}

// MARK: Niyetler

/// "Toplantılarına sor": soruyu bütün toplantılara sorar, cevabı söyler ve döndürür (Kısayollar'da sonraki adıma geçer).
/// Uygulamayı açmaz; sohbet Sor geçmişinde kalır.
struct AskMeetingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Toplantılarına sor"
    static let description: IntentDescription = IntentDescription("Bütün toplantılarına bir soru sorar ve cevabı söyler; sohbet Sor geçmişinde kalır.")
    /// Toplantı içeriğini söyler: kilitli cihazda önce kilit açılmalı (Siri kilit ekranında okumasın).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Soru", requestValueDialog: IntentDialog("Toplantılarına ne sormak istiyorsun?"))
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Toplantılarına sor: \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer: String = plainAnswerText(text: try await MeetingIntentsHost.require().askAcrossMeetings(question: question))
        return .result(value: answer, dialog: IntentDialog(LocalizedStringResource(stringLiteral: answer)))
    }
}

/// "Görevlerim ne?": açık görevlerini (yeniden eskiye) söyler ve döndürür.
struct MyTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Açık görevlerim"
    static let description: IntentDescription = IntentDescription("Toplantılarından sana düşen ve henüz bitmemiş görevleri söyler.")
    /// Toplantı içeriğini söyler: kilitli cihazda önce kilit açılmalı (Siri kilit ekranında okumasın).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    /// Siri'nin yüksek sesle okuduğu en fazla görev.
    private static let spokenLimit: Int = 3

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[MeetingTaskEntity]> & ProvidesDialog {
        let backend: any MeetingIntentsBackend = try MeetingIntentsHost.require()
        let tasks: [ShortcutTask] = openShortcutTasks(records: try await backend.intentMeetings(), userName: backend.intentUserName())
        let entities: [MeetingTaskEntity] = tasks.map { MeetingTaskEntity(task: $0) }
        guard !tasks.isEmpty else {
            return .result(value: entities, dialog: IntentDialog("Açık görevin yok."))
        }
        let spoken: String = tasks.prefix(Self.spokenLimit).map(\.description).joined(separator: "; ")
        return .result(value: entities, dialog: IntentDialog("\(tasks.count) açık görevin var: \(spoken)"))
    }
}

/// "Toplantıyı aç": seçilen toplantıyı uygulamada açar (Spotlight'taki sonuç da bunu kullanır).
struct OpenMeetingIntent: OpenIntent {
    static let title: LocalizedStringResource = "Toplantıyı aç"
    static let description: IntentDescription = IntentDescription("Seçtiğin toplantının notunu uygulamada açar.")
    static let openAppWhenRun: Bool = true
    /// Toplantı içeriğini söyler: kilitli cihazda önce kilit açılmalı (Siri kilit ekranında okumasın).
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Toplantı", requestValueDialog: IntentDialog("Hangi toplantı?"))
    var target: MeetingEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let backend: any MeetingIntentsBackend = try MeetingIntentsHost.require()
        guard try await backend.intentMeetings().contains(where: { $0.id == target.id }) else {
            throw MeetingIntentError.meetingNotFound
        }
        backend.openMeeting(id: target.id)
        return .result()
    }
}
