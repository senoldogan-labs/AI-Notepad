import AINotepadCore
#if os(macOS)
import CoreAudio
#endif
import Foundation
import UserNotifications

/// Bildirimlerin "Kaydı başlat" eylemi ve kategorileri.
enum MeetingNotificationID {
    static let category: String = "meeting.start"
    /// "Kayıt başlatılamadı" bildirimi: tıklanınca nedenin yazdığı Ana sayfa açılır.
    static let autoFailedCategory: String = "meeting.autoFailed"
    static let startAction: String = "meeting.start.listen"
    static let reminderPrefix: String = "meeting.reminder."
    static let micSuggestion: String = "meeting.mic"
    /// "Görüşme bitti gibi" bildirimi (yalnız Mac): kayıt geri sayımın sonunda biter; eylemler geri sayımı iptal eder ya
    /// da kaydı hemen bitirir, bildirime tıklama canlı paneli açar.
    static let callEndedCategory: String = "meeting.callEnded"
    static let callEnded: String = "meeting.callEnded"
    static let keepRecordingAction: String = "meeting.callEnded.keep"
    static let stopRecordingAction: String = "meeting.callEnded.stop"
    /// Kayıtta mikrofondan uzun süredir ses gelmiyor (yeniden bağlanıyor).
    static let microphoneLost: String = "recording.microphoneLost"
    /// Toplantının süre sınırına 5 dakika kaldı.
    static let recordingLimit: String = "recording.limit"
    /// iPhone: uygulama kayıt sürerken yenilemeyi bıraktı (çöktü, sistem kapattı); 90 sn ileri kurulup her 30 sn'de
    /// ertelenen bildirim.
    static let recordingStopped: String = "recording.stopped"
    /// iPhone: "Toplantı bitti mi?" (takvim etkinliği bitti ya da uzun sessizlik); eylemler kaydı bitirir ya da sürdürür.
    static let meetingOverCategory: String = "recording.meetingOver"
    static let meetingOver: String = "recording.meetingOver"
    static let finishMeetingAction: String = "recording.meetingOver.finish"
    static let continueMeetingAction: String = "recording.meetingOver.continue"
    /// Kayda bağlı bildirimlerin (`userInfo`) kayıt kimliği anahtarı: eylem yalnız o kayda uygulanır (bayat bildirim yeni
    /// kaydı bitirmez).
    static let recordingIDKey: String = "recordingID"
}

/// Bildirimin bağlı olduğu kayıt (`MeetingNotificationID.recordingIDKey`); kimliksiz bildirimde nil.
func notificationRecordingID(userInfo: [AnyHashable: Any]) -> RecordingID? {
    (userInfo[MeetingNotificationID.recordingIDKey] as? String).map { RecordingID(rawValue: $0) }
}

/// Bildirim izni ya da kurulumu hatası.
enum NotificationError: Error, Equatable {
    /// Bildirim izni yok (reddedildi ya da Sistem Ayarları'nda kapatıldı).
    case denied
    /// İzin istenemedi (sistem hatası).
    case authorizationFailed(reason: String)
    /// Bildirim kurulamadı.
    case scheduleFailed(reason: String)
}

/// Toplantı bildirimleri (UserNotifications): başlamadan 1 dk önce hatırlatma ve görüşme başladı önerisi; ikisinde de
/// "Kaydı başlat" düğmesi. iPhone yalnız hatırlatmayı kullanır (görüşme önerisi ve kendiliğinden kayıt Mac'e özgü).
@MainActor
final class MeetingNotifier {
    private let center: UNUserNotificationCenter = UNUserNotificationCenter.current()

    init() {
        let start: UNNotificationAction = UNNotificationAction(identifier: MeetingNotificationID.startAction, title: String(localized: "Kaydı başlat"), options: [.foreground])
        // Kategoriler tek seferde bütünüyle kurulur: hatırlatma ve görev bildirimlerininkiler de (bkz. `EngagementNotifier`).
        let common: Set<UNNotificationCategory> = engagementNotificationCategories().union([
            UNNotificationCategory(identifier: MeetingNotificationID.category, actions: [start], intentIdentifiers: []),
            UNNotificationCategory(identifier: MeetingNotificationID.autoFailedCategory, actions: [], intentIdentifiers: []),
        ])
        #if os(iOS)
        // Uygulamayı açmadan: "Bitir" kaydı bitirir (not hazırlanır), "Devam" yalnız bildirimi kapatır.
        let finish: UNNotificationAction = UNNotificationAction(identifier: MeetingNotificationID.finishMeetingAction, title: String(localized: "Kaydı bitir"), options: [])
        let keepGoing: UNNotificationAction = UNNotificationAction(identifier: MeetingNotificationID.continueMeetingAction, title: String(localized: "Sürüyor"), options: [])
        let phoneCategories: Set<UNNotificationCategory> = common.union([
            UNNotificationCategory(identifier: MeetingNotificationID.meetingOverCategory, actions: [finish, keepGoing], intentIdentifiers: []),
        ])
        #endif
        #if os(macOS)
        let keep: UNNotificationAction = UNNotificationAction(identifier: MeetingNotificationID.keepRecordingAction, title: keepRecordingTitle(), options: [])
        let stop: UNNotificationAction = UNNotificationAction(identifier: MeetingNotificationID.stopRecordingAction, title: String(localized: "Şimdi bitir"), options: [])
        center.setNotificationCategories(common.union([
            UNNotificationCategory(identifier: MeetingNotificationID.callEndedCategory, actions: [keep, stop], intentIdentifiers: []),
        ]))
        #else
        center.setNotificationCategories(phoneCategories)
        #endif
    }

    /// Bildirim izni ister.
    func requestAuthorization() async throws {
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            throw NotificationError.authorizationFailed(reason: error.localizedDescription)
        }
        guard granted else {
            throw NotificationError.denied
        }
    }

    /// Kurulu toplantı hatırlatmalarını kaldırır (hatırlatmalar ya da takvim kapandı).
    func removeReminders() async {
        let pending: [UNNotificationRequest] = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(MeetingNotificationID.reminderPrefix) })
    }

    /// Önceki toplantı hatırlatmalarını kaldırıp verilenler için başlangıçtan 1 dk önceye yenilerini kurar. Bildirim izni
    /// yoksa (sonradan Sistem Ayarları'nda kapatılmış olabilir) `NotificationError.denied`: sistemin İngilizce
    /// "bildirimlere izin verilmiyor" hatası yerine ne yapılacağı yazar.
    func scheduleReminders(meetings: [CalendarMeeting]) async throws {
        await removeReminders()
        let status: UNAuthorizationStatus = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else {
            throw NotificationError.denied
        }
        for meeting in meetings {
            let fire: Date = max(Date().addingTimeInterval(5), meeting.start.addingTimeInterval(-60))
            let content: UNMutableNotificationContent = UNMutableNotificationContent()
            content.title = String(localized: "1 dk sonra: \(meeting.title)")
            // Bildirime dokunmak Ana sayfayı açar; kaydı yalnız "Kaydı başlat" eylemi başlatır (eski bildirim kayıt
            // başlatmasın; bkz. `meetingNotificationTap`).
            content.body = meeting.attendees.isEmpty
                ? String(localized: "Kaydetmek için \"Kaydı başlat\"ı seç.")
                : String(localized: "\(meeting.attendees.prefix(3).joined(separator: ", ")) · Kaydetmek için \"Kaydı başlat\"ı seç.")
            content.categoryIdentifier = MeetingNotificationID.category
            content.sound = .default
            let trigger: UNTimeIntervalNotificationTrigger = UNTimeIntervalNotificationTrigger(timeInterval: fire.timeIntervalSinceNow, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.reminderPrefix + meeting.id, content: content, trigger: trigger))
            } catch {
                throw NotificationError.scheduleFailed(reason: error.localizedDescription)
            }
        }
    }

    /// Kayıt takvimdeki görüşme için kendiliğinden başladı (kullanıcı bilsin; katılımcılara haber vermeyi hatırlasın).
    func announceAutoRecording(title: String) async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = String(localized: "Kayıt başladı: \(title)")
        content.body = String(localized: "Takvimdeki görüşme başladı ve kayıt kendiliğinden açıldı. Katılımcılara kaydettiğini söylemeyi unutma.")
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.micSuggestion, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }

    /// Takvimdeki görüşme için kayıt kendiliğinden başlatılamadı (anahtar, model ya da izin eksik olabilir).
    func announceAutoRecordingFailed(title: String) async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = String(localized: "Kayıt başlatılamadı: \(title)")
        content.body = String(localized: "Takvimdeki görüşme başladı ama kayıt açılamadı. Nedenini görmek için \(appName)'i aç.")
        content.categoryIdentifier = MeetingNotificationID.autoFailedCategory
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.micSuggestion, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }

    /// Kayıt başladı: ekranda kalan toplantı bildirimleri (hatırlatma, görüşme önerisi) ve bekleyen hatırlatmalar kalkar;
    /// eski bir bildirime sonradan dokunmak ikinci bir kayıt denemesi olmasın, paylaşılan ekranda görünmesin.
    func removeMeetingNotifications() {
        let center: UNUserNotificationCenter = center
        center.removeDeliveredNotifications(withIdentifiers: [MeetingNotificationID.micSuggestion])
        Task {
            let delivered: [UNNotification] = await center.deliveredNotifications()
            center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(MeetingNotificationID.reminderPrefix) })
            await removeReminders()
        }
    }

    /// Kayıtta mikrofondan uzun süredir ses gelmiyor: kullanıcı paneli görmüyor olabilir.
    func announceMicrophoneLost() async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = String(localized: "Mikrofondan ses gelmiyor")
        content.body = String(localized: "Kayıt sürüyor ama mikrofon kesildi; yeniden bağlanmaya çalışılıyor. Mikrofonu ya da kulaklığı kontrol et.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.microphoneLost, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }

    /// Mikrofon yeniden ses veriyor ya da kayıt bitti: "Mikrofondan ses gelmiyor" kalkar.
    func removeMicrophoneLost() {
        center.removeDeliveredNotifications(withIdentifiers: [MeetingNotificationID.microphoneLost])
    }

    /// Toplantının süre sınırına az kaldı (panel kapalı olabilir).
    func announceRecordingLimit(message: String) async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = String(localized: "Toplantının süresi dolmak üzere")
        content.body = message
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.recordingLimit, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }

    /// Başka bir uygulama mikrofonu açtı: görüşme başlamış olabilir.
    func suggestRecording() async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = String(localized: "Bir görüşme başlamış olabilir")
        content.body = String(localized: "Mikrofon başka bir uygulamada açıldı. Toplantıyı kaydetmek için \"Kaydı başlat\"ı seç.")
        content.categoryIdentifier = MeetingNotificationID.category
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.micSuggestion, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }
}

#if os(macOS)
/// Görüşme sonu geri sayımındaki "Kayda devam et" düğmesi. Aynı Türkçe metin iPhone'da duraklatılan kaydı sürdürme
/// eylemidir ("Resume recording"); burada kayıt duraklatılmış değildir: İngilizcesi ayrı olsun diye kendi anahtarıyla.
func keepRecordingTitle() -> String {
    String(localized: "callEnd.keepRecording", defaultValue: "Kayda devam et")
}

extension MeetingNotifier {
    /// Görüşme bitti gibi görünüyor: kayıt `seconds` sn sonra bitecek (pencere gizliyken de görülsün). Bildirim kayda
    /// bağlıdır: "Şimdi bitir" yalnız o kaydı bitirir.
    func announceCallEnded(seconds: Int, recordingID: RecordingID) async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.userInfo = [MeetingNotificationID.recordingIDKey: recordingID.rawValue]
        content.title = String(localized: "Görüşme bitti gibi görünüyor")
        content.body = String(localized: "Kayıt \(seconds) sn sonra bitecek. Sürmesini istiyorsan \"Kayda devam et\".")
        content.categoryIdentifier = MeetingNotificationID.callEndedCategory
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.callEnded, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }

    /// Geri sayım iptal oldu ya da kayıt bitti: "Görüşme bitti gibi" bildirimi kaldırılır.
    func removeCallEnded() {
        center.removeDeliveredNotifications(withIdentifiers: [MeetingNotificationID.callEnded])
    }
}

/// Varsayılan mikrofonun herhangi bir uygulamada kullanılıp kullanılmadığını (Core Audio) 5 sn'de bir denetler;
/// kullanılmıyorken kullanılmaya başlayınca `onStart` çağrılır.
@MainActor
final class MicrophoneActivityMonitor {
    private var task: Task<Void, Never>?

    func start(onStart: @escaping @MainActor () -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            var wasRunning: Bool = defaultInputIsRunning()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                let running: Bool = defaultInputIsRunning()
                if running, !wasRunning {
                    onStart()
                }
                wasRunning = running
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Varsayılan giriş aygıtı herhangi bir süreçte çalışıyor mu; okunamazsa false.
private func defaultInputIsRunning() -> Bool {
    var device: AudioDeviceID = 0
    var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else {
        return false
    }
    var running: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
        return false
    }
    return running != 0
}
#endif

/// Bildirim izni ya da kurulumu hatasının kullanıcı metni. Saf fonksiyondur.
func notificationMessage(error: any Error) -> String {
    switch error {
    case NotificationError.denied:
        #if os(iOS)
        String(localized: "Bildirim izni yok: iPhone Ayarları › Bildirimler › \(appName) bölümünden izin ver.")
        #else
        String(localized: "Bildirim izni yok: Sistem Ayarları › Bildirimler › \(appName) bölümünden izin ver.")
        #endif
    case NotificationError.authorizationFailed(let reason):
        String(localized: "Bildirim izni istenemedi: \(reason)")
    case NotificationError.scheduleFailed(let reason):
        String(localized: "Bildirim kurulamadı: \(reason)")
    default:
        userFacingMessage(error: error)
    }
}

#if os(iOS)
extension MeetingNotifier {
    /// Kayıt sürüyor: "kayıt durmuş olabilir" bildirimi `seconds` sn ileri kurulur (aynı kimlikle eskisinin yerine).
    /// Uygulama yaşadıkça her yenilemede ertelenir; çöker ya da sistem kapatırsa bildirim çıkar.
    func deferRecordingStoppedAlert(seconds: Double) async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.title = String(localized: "Kayıt durmuş olabilir")
        content.body = String(localized: "Uygulama kaydı sürdüremedi. Açıp kaydın durumuna bak; o ana kadarki ses saklandı.")
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger: UNTimeIntervalNotificationTrigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.recordingStopped, content: content, trigger: trigger))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }

    /// Kayıt bitti: bekleyen "kayıt durmuş olabilir" ve "Toplantı bitti mi?" bildirimleri kalkar.
    func removeRecordingAlerts() {
        center.removePendingNotificationRequests(withIdentifiers: [MeetingNotificationID.recordingStopped])
        center.removeDeliveredNotifications(withIdentifiers: [MeetingNotificationID.recordingStopped, MeetingNotificationID.meetingOver])
    }

    /// Kayıt bitti ya da yenisi başladı: "Toplantı bitti mi?" sorusu kalkar.
    func removeMeetingOverPrompt() {
        center.removeDeliveredNotifications(withIdentifiers: [MeetingNotificationID.meetingOver])
    }

    /// Toplantı bitmiş gibi: kaydı bitirmek ya da sürdürmek sorulur (uygulamayı açmadan). Bildirim kayda bağlıdır: "Kaydı
    /// bitir" yalnız o kaydı bitirir.
    func askMeetingOver(reason: MeetingOverReason, recordingID: RecordingID) async throws {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.userInfo = [MeetingNotificationID.recordingIDKey: recordingID.rawValue]
        content.title = String(localized: "Toplantı bitti mi?")
        content.body = switch reason {
        case .calendarEnded: String(localized: "Takvimdeki toplantının süresi doldu ama kayıt sürüyor.")
        case .longSilence: String(localized: "10 dakikadır konuşma duyulmadı ama kayıt sürüyor.")
        }
        content.categoryIdentifier = MeetingNotificationID.meetingOverCategory
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: MeetingNotificationID.meetingOver, content: content, trigger: nil))
        } catch {
            throw NotificationError.scheduleFailed(reason: error.localizedDescription)
        }
    }
}
#endif
