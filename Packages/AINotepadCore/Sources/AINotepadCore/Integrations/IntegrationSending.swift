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
/// (`locked`), sonucu belirsiz kalan gönderimler (`uncertain`: not iki kez düşmesin) ve hedefin kalıcı olarak reddettiği
/// gönderimler (`rejected`: yeniden denemek aynı hatayı verir, bkz. `isPermanentDeliveryFailure`) atlanır; son ikisi
/// `meetingDestinationKey` anahtarlarıdır. Saf fonksiyondur.
public func autoSendQueue(
    records: [MeetingRecord], destinations: [NoteDestination], now: Date, pendingMarks: [String: Set<String>], locked: Set<String>, uncertain: Set<String>,
    rejected: Set<String>
) -> [(meetingID: String, destinationID: String)] {
    pendingAutoSends(records: records, destinations: destinations, now: now).filter { (item: (meetingID: String, destinationID: String)) -> Bool in
        let key: String = meetingDestinationKey(meetingID: item.meetingID, destinationID: item.destinationID)
        return !(pendingMarks[item.meetingID] ?? []).contains(item.destinationID) && !locked.contains(item.meetingID)
            && !uncertain.contains(key) && !rejected.contains(key)
    }
}

/// Gönderim hatası kalıcı mı: hedef isteği bilerek reddetti (400, 401, 403, 404, 410, 422 gibi 4xx; webhook silinmiş,
/// adres ya da içerik geçersiz) ya da adres bozuk. Saatte bir yeniden denemek aynı hatayı verir: kendiliğinden gönderim
/// bu (toplantı, hedef) için bırakılır. 408 ve 429, 5xx ve ağ hataları geçicidir (yeniden denenir). Saf fonksiyondur.
public func isPermanentDeliveryFailure(error: any Error) -> Bool {
    switch error {
    case WebhookError.invalidURL:
        return true
    case WebhookError.http(_, let status, _), ChannelAuthError.http(_, let status, _), MCPRemoteError.http(_, let status, _):
        return isPermanentHTTPRejection(status: status)
    default:
        return false
    }
}

/// Kendiliğinden gönderim kalıcı hatayla bırakıldı: hata bir kez, ne yapılacağıyla gösterilir. `destinationName`:
/// hedefin arayüzdeki adı. Saf fonksiyondur.
public func permanentAutoSendFailureMessage(destinationName: String, error: any Error) -> String {
    String(localized: "\(destinationName): \(userFacingMessage(error: error)) Bu toplantı artık kendiliğinden gönderilmeyecek; hedefi Ayarlar'da kontrol edip notu toplantı sayfasından yeniden gönder.")
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
