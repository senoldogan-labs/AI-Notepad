import AINotepadCore
import AINotepadUI
import os
import SwiftUI
import UserNotifications

private let macAppLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "GetMacApp")

/// "Sonra hatırlat" bildiriminin kimliği ve türü: yeniden kurulunca eskisinin yerini alır; dokununca Mac uygulamasının
/// sayfası yeniden açılır (`PhoneNotificationDelegate`).
let macAppReminderID: String = "mac-app-reminder"
let macAppReminderCategory: String = "mac-app-reminder"

/// Ayarlar'da plan kartının altındaki "Mac için Gistsmith" satırı: dokununca Mac uygulamasının tanıtım sayfası
/// açılır, sağdaki ✕ satırı bu iPhone'da kalıcı olarak gizler. Sunucu hesabın hangi cihazlarda kullanıldığını
/// söylemez: Mac'i zaten kullanan da görür, gizleyebilir. Görünüşü (açılış başına bir kez) ve dokunuşu (kullanım
/// istatistikleri açıksa) sayılır.
struct PhoneMacAppBanner: View {
    let router: PhoneRouter
    @AppStorage(PhoneSettingsKey.macAppBannerDismissed) private var isDismissed: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        if !isDismissed {
            Section {
                HStack(spacing: 12) {
                    Button {
                        recordTelemetryCount(kind: .macPromoOpened)
                        router.isMacAppIntroOpen = true
                    } label: {
                        HStack(spacing: 12) {
                            PhoneSettingLabel(icon: "laptopcomputer", title: Text("Gistsmith'i Mac'e indir")) {
                                Text("Zoom, Teams ve Meet görüşmelerinin notunu al.")
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .appFont(size: 13, weight: .semibold)
                                .foregroundStyle(Theme.muted)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Mac uygulamasını tanıtan sayfayı açar"))
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { isDismissed = true }
                    } label: {
                        Image(systemName: "xmark")
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(Theme.muted)
                            .frame(width: 30, height: 30)
                            .background(Theme.soft, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Text("Mac uygulaması önerisini gizle"))
                }
                .listRowBackground(appearance.accent.softFill(tintOpacity: 0.10))
            }
            .onAppear {
                guard !otherAppPromoShownCounted else {
                    return
                }
                otherAppPromoShownCounted = true
                recordTelemetryCount(kind: .macPromoShown)
            }
        }
    }
}

/// "Sonra hatırlat"ın durumu.
enum MacAppReminderState: Equatable {
    case idle
    /// İzin soruluyor ya da bildirim kuruluyor.
    case scheduling
    /// Bildirim kuruldu (yerel saatle ertesi sabahın anı).
    case scheduled(Date)
    /// Kurulamadı (izin yok ya da sistem hatası).
    case failed(NotificationError)
}

/// Mac uygulamasının tanıtım sayfası: pastel zeminde Mac'teki not penceresinin gerçek görüntüsü, başlık ve tek cümle,
/// "Bağlantıyı paylaş" (indirme sayfası, sistemin paylaşım sayfasıyla; ör. AirDrop ile Mac'e) ve "Sonra hatırlat"
/// (ertesi sabah 09:00'da tek bildirim; bildirim izni yalnız burada, gerekirse sorulur; izin yoksa nedeni ve iPhone
/// Ayarları'na giden düğme görünür).
struct PhoneMacAppSheet: View {
    @State private var reminder: MacAppReminderState = .idle
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        // Erişilebilirlik yazı boyutlarında görsel küçülür: başlık ve eylemler daha az kaydırmayla görünür.
        let heroRatio: CGFloat = dynamicTypeSize.isAccessibilitySize ? 0.26 : 0.42
        GeometryReader { (geometry: GeometryProxy) in
            HeroSheet(
                palette: .violet,
                seed: "mac-uygulamasi",
                heroHeight: phoneHeroHeight(screenHeight: geometry.size.height, ratio: heroRatio, minimum: 180, maximum: 400),
                title: Text("Mac'inde toplantı notları"),
                subtitle: Text("Mac'teki Gistsmith Zoom, Teams ve Meet görüşmelerini iki taraflı kaydeder; görüşmeye bot katılmaz."),
                doneTitle: Text("Bitti"),
                onDone: { dismiss() }
            ) { (size: CGSize) in
                // Pencere sağdan ve alttan taşar (kırpılır): görüntünün üst kısmı, not başlığı ve özet görünür.
                HeroMacWindow(screenshot: Image("hero-mac-note"))
                    .frame(width: min(size.width * 1.08, 620))
                    // Yükseklik görüntünün oranından gelir (görsel alanın yüksekliğine sığdırılmaz; alttan kırpılır).
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: size.width * 0.12, y: size.height * 0.16)
            } actions: {
                VStack(spacing: 12) {
                    HeroTileRow {
                        ShareLink(item: gistsmithMacDownloadURL, subject: Text("Mac için Gistsmith"), message: Text("Gistsmith'i Mac'ine buradan indir.")) {
                            HeroTileLabel(systemImage: "square.and.arrow.up", title: Text("Bağlantıyı paylaş"), detail: Text(verbatim: "gistsmith.com/download"))
                        }
                        .buttonStyle(HeroTileButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded { recordTelemetryCount(kind: .macPromoShared) })
                        Button {
                            Task { await remind() }
                        } label: {
                            reminderTile
                        }
                        .buttonStyle(HeroTileButtonStyle())
                        .disabled(reminder == .scheduling)
                    }
                    if case .failed(let error) = reminder {
                        reminderProblem(error: error)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reminderTile: some View {
        switch reminder {
        case .scheduled(let date):
            HeroTileLabel(
                systemImage: "checkmark", title: Text("Hatırlatma kuruldu"),
                detail: Text("Yarın \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale())))")
            )
        case .idle, .scheduling, .failed:
            HeroTileLabel(systemImage: "bell", title: Text("Sonra hatırlat"), detail: Text("Yarın sabah"))
        }
    }

    private func reminderProblem(error: NotificationError) -> some View {
        VStack(spacing: 8) {
            Label(notificationMessage(error: error), systemImage: "bell.slash")
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(NoticeSeverity.attention.tint)
                .fixedSize(horizontal: false, vertical: true)
            if error == .denied, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                Button("Ayarlar'ı aç") { openURL(url) }
                    .appFont(size: 15, weight: .semibold)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func remind() async {
        reminder = .scheduling
        do {
            let date: Date = try await scheduleMacAppReminder(now: Date(), calendar: Calendar.current)
            recordTelemetryCount(kind: .macPromoReminded)
            reminder = .scheduled(date)
        } catch {
            macAppLogger.warning("Mac uygulaması hatırlatması kurulamadı, hata: \(String(describing: error), privacy: .public)")
            reminder = .failed(error)
        }
    }
}

/// "Sonra hatırlat": bildirim izni sorulmadıysa sorar, yoksa `NotificationError.denied`; varsa yerel saatle ertesi
/// sabahın bildirimini kurar (aynı kimlik: yeniden basmak eskisinin yerini alır; tetik yerel saatin takvim bileşenleri,
/// yolculukta da sabah gelir) ve kurulan anı döndürür.
@MainActor
func scheduleMacAppReminder(now: Date, calendar: Calendar) async throws(NotificationError) -> Date {
    let center: UNUserNotificationCenter = UNUserNotificationCenter.current()
    switch await center.notificationSettings().authorizationStatus {
    case .notDetermined:
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            throw NotificationError.authorizationFailed(reason: error.localizedDescription)
        }
        guard granted else {
            throw NotificationError.denied
        }
    case .denied:
        throw NotificationError.denied
    case .authorized, .provisional, .ephemeral:
        break
    @unknown default:
        throw NotificationError.authorizationFailed(reason: "unknown authorization status")
    }
    let date: Date
    do {
        date = try otherAppReminderDate(now: now, calendar: calendar, hour: otherAppReminderHour)
    } catch {
        throw NotificationError.scheduleFailed(reason: userFacingMessage(error: error))
    }
    let components: DateComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let content: UNMutableNotificationContent = UNMutableNotificationContent()
    content.title = String(localized: "Gistsmith'i Mac'ine kur")
    content.body = String(localized: "İndirme bağlantısını Mac'ine göndermek için dokun.")
    content.categoryIdentifier = macAppReminderCategory
    content.sound = .default
    let request: UNNotificationRequest = UNNotificationRequest(
        identifier: macAppReminderID, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    )
    do {
        try await center.add(request)
    } catch {
        throw NotificationError.scheduleFailed(reason: error.localizedDescription)
    }
    return date
}
