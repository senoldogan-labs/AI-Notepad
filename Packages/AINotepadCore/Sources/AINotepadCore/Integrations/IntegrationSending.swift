import Foundation

// Mac ve iPhone uygulamalarının ortak gönderim kuralları: toplantı sayfasındaki gönderim durumu, bağlı hedefin türü
// (ayarlardaki kart), kendiliğinden gönderim kuyruğu ve görev aracına gidecek görevler.

/// Toplantı başına gönderimin (kanala not, görev aracına görevler) durumu; toplantı sayfasında görünür.
public enum WebhookSendState: Sendable, Equatable {
    case sending
    case sent
    /// Bitti, kısa özetle (ör. açılan Linear işleri).
    case done(String)
    case failed(String)
}

/// Gönderim sonucunun kalkma süresi: gitti 3,5 sn, hata 5 sn; gönderilirken kalır. Saf fonksiyondur.
public func sendResultFadeDelay(state: WebhookSendState) -> Duration? {
    switch state {
    case .sending: nil
    case .sent, .done: .seconds(3.5)
    case .failed: .seconds(5)
    }
}

/// Bağlı hedefin türü (ayarlardaki ekleme kartı): hesapla bağlanan servisler, Notion ve adresle bağlananlar.
public enum DestinationKind: String, Sendable, CaseIterable, Identifiable {
    case slack
    case teams
    case discord
    case notion
    case zoom
    case webhook

    public var id: String { rawValue }

    /// Hesapla girişin servisi (Slack, Teams, Discord); diğerlerinde nil.
    public var channelService: ChannelService? {
        switch self {
        case .slack: .slack
        case .teams: .teams
        case .discord: .discord
        case .notion, .zoom, .webhook: nil
        }
    }
}

/// Hedefin türü: hesap bağlantısında servis, webhook'ta adresin servisi (Slack, Discord, Teams, Zoom; diğerleri genel
/// webhook). Saf fonksiyondur.
public func destinationKind(destination: NoteDestination) -> DestinationKind {
    switch destination.target {
    case .account(let connection):
        switch connection.service {
        case .slack: .slack
        case .teams: .teams
        case .discord: .discord
        }
    case .notion: .notion
    case .discordSignIn: .discord
    case .webhook(let url):
        switch webhookKind(url: url) {
        case .slack: .slack
        case .discord: .discord
        case .teams: .teams
        case .zoom: .zoom
        case .generic: .webhook
        }
    }
}

/// Toplantı ve hedef çiftinin anahtarı (süren ve sonucu belirsiz gönderimler): `toplantı|hedef`. Saf fonksiyondur.
public func meetingDestinationKey(meetingID: String, destinationID: String) -> String {
    "\(meetingID)|\(destinationID)"
}

/// Bu turda kendiliğinden gönderilecek (toplantı, hedef) çiftleri (bkz. `pendingAutoSends`): gönderildi işareti henüz
/// kayda yazılamamış olanlar (`pendingMarks`: toplantı → hedef kimlikleri), kayıtta ya da işlenmekte olan toplantılar
/// (`locked`) ve sonucu belirsiz kalan gönderimler (`uncertain`, `meetingDestinationKey` anahtarları) atlanır: not iki
/// kez düşmesin. Saf fonksiyondur.
public func autoSendQueue(
    records: [MeetingRecord], destinations: [NoteDestination], now: Date, pendingMarks: [String: Set<String>], locked: Set<String>, uncertain: Set<String>
) -> [(meetingID: String, destinationID: String)] {
    pendingAutoSends(records: records, destinations: destinations, now: now).filter { (item: (meetingID: String, destinationID: String)) -> Bool in
        !(pendingMarks[item.meetingID] ?? []).contains(item.destinationID) && !locked.contains(item.meetingID)
            && !uncertain.contains(meetingDestinationKey(meetingID: item.meetingID, destinationID: item.destinationID))
    }
}

/// Görev aracına gidecek görevler: kapsamdakiler (`scope`), bu araca daha önce gönderilmemiş ve tamamlanmamış olanlar.
/// Saf fonksiyondur.
public func tasksToSend(record: MeetingRecord, note: MeetingNote, tracker: TaskTracker, scope: TaskSendScope) -> [NoteTask] {
    tasksInScope(tasks: note.tasks, scope: scope)
        .filter { !isTaskSent(record: record, tracker: tracker, task: $0) && !isTaskDone(record: record, task: $0) }
}

/// Hesabın kendi Anahtar Zinciri servisi (not hedefleri, görev araçları): `<uygulamanın servisi>.account.<anahtar>`.
/// Mac'teki Gistsmith ve iPhone aynı biçimi kullanır; anahtar geçersizse `StorageError.invalidAccountKey`. Saf
/// fonksiyondur.
public func accountKeychainService(appService: String, accountKey: String) throws -> String {
    guard isValidAccountDataKey(key: accountKey) else {
        throw StorageError.invalidAccountKey(key: accountKey)
    }
    return "\(appService).account.\(accountKey)"
}
