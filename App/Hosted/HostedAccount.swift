import AINotepadCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AuthenticationServices
import Foundation
import Network
import Observation
import os

private let accountLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedAccount")

extension Notification.Name {
    /// Sunucu oturumu kapattı (yenileme reddedildi; ör. yenileme jetonu yeniden kullanıldığı için tüm oturumlar düştü).
    static let hostedSessionEnded: Notification.Name = Notification.Name("com.senoldogan.AINotepad.hosted.sessionEnded")
}

/// Info.plist'teki adresi okur ve doğrular: Debug'da yerel http kabul edilir, yayında yalnızca https.
private func hostedURL(bundle: Bundle, key: String) throws -> URL {
    let value: String = bundle.object(forInfoDictionaryKey: key) as? String ?? ""
    let url: URL = try parseHostedBaseURL(value: value)
    #if !DEBUG
    try requireSecureHostedBaseURL(url: url)
    #endif
    return url
}

/// Uygulama boyunca tek sunucu bağlantısı; oturum Anahtar Zinciri'nde Info.plist'teki servis adıyla saklanır (Debug ve
/// Release ayrı: Debug derlemesi yayındaki oturumu okumaz, silmez).
private func makeHostedClient(bundle: Bundle) -> Result<HostedClient, HostedClientError> {
    do {
        let client: HostedClient = HostedClient(
            clientInfo: try hostedClientInfo(
                shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                system: hostedThisOperatingSystem,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersion
            ),
            baseURL: try hostedURL(bundle: bundle, key: "HostedAPIBase"),
            storage: HostedKeychainTokenStorage(service: try hostedKeychainService(bundle: bundle))
        ) { () async -> Void in
            await MainActor.run {
                NotificationCenter.default.post(name: .hostedSessionEnded, object: nil)
            }
        }
        return .success(client)
    } catch let error as HostedClientError {
        accountLogger.error("Sunucu bağlantısı kurulamadı, hata: \(String(describing: error), privacy: .private)")
        return .failure(error)
    } catch {
        // `hostedClientInfo`, `hostedURL` ve `hostedKeychainService` yalnızca `HostedClientError` fırlatır.
        return .failure(.invalidBaseURL(value: String(describing: error)))
    }
}

/// Paylaşılan sunucu bağlantısı ve site adresi.
enum HostedServices {
    static let client: Result<HostedClient, HostedClientError> = makeHostedClient(bundle: .main)

    /// Bağlantı; adres geçersizse hata.
    static func requireClient() throws -> HostedClient {
        try client.get()
    }

    /// Sitenin adresi (giriş sayfası orada).
    static func siteBase() throws -> URL {
        try hostedURL(bundle: .main, key: "HostedSiteBase")
    }
}

/// Davet kodunun ödeme öncesi doğrulaması.
enum HostedReferralCheck: Equatable {
    /// Geçerli; sunucunun sadeleştirdiği kod ödeme sayfasına gönderilir.
    case valid(code: String)
    /// Geçersiz; kullanıcıya gösterilecek neden.
    case invalid(message: String)
}

/// Hesap ekranının durumu.
enum HostedAccountState: Equatable {
    /// İlk okuma sürüyor.
    case loading
    case signedOut
    case signedIn(HostedEntitlements)
    /// Oturum var ama hak durumu okunamadı (ağ yok ya da sunucu yanıt vermiyor). Bağlantı gelince ve uygulama öne
    /// gelince yeniden okunur; kullanıcı çıkış yapmış sayılmaz.
    case signedInStatusUnknown(message: String)
    /// Sunucu adresi ayarlanmamış ya da güvensiz, ya da Anahtar Zinciri okunamıyor: hesap kullanılamaz.
    case unavailable(message: String)
}

/// Uygulama içi giriş penceresinin (ASWebAuthenticationSession) sonucu.
private enum HostedWebSignInOutcome {
    /// Site dönüş adresine yönlendirdi (henüz doğrulanmadı).
    case callback(URL)
    /// Kullanıcı pencereyi kapattı ya da "Vazgeç"e bastı.
    case canceled
}

/// Bu uygulamanın işletim sistemi (sunucuya `x-os-version` adıyla bildirilir).
#if os(macOS)
private let hostedThisOperatingSystem: HostedOperatingSystem = .macOS
#else
private let hostedThisOperatingSystem: HostedOperatingSystem = .iOS
#endif

/// Giriş penceresinin bağlandığı pencere (AuthenticationServices sunum sağlayıcısı; dış sistem bağlantısı, NSObject
/// gerekir). Mac'te giriş düğmesi ana penceredeyken anahtar pencere odur; iPhone'da öndeki sahnenin anahtar penceresi.
@MainActor
private final class HostedWebSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        // Anahtar ya da ana pencere yoksa (ör. uygulama arka planda) sistem giriş penceresini kendi başına açar.
        NSApp.keyWindow ?? NSApp.mainWindow ?? ASPresentationAnchor()
        #else
        // Giriş düğmesi öndeki sahnededir; sahnesi olmayan pencere sistemin giriş sayfasını gösteremez.
        let scenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active: UIWindowScene? = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene = active else {
            preconditionFailure("Giriş penceresi istendi ama uygulamanın sahnesi yok")
        }
        return scene.keyWindow ?? scene.windows.first ?? UIWindow(windowScene: scene)
        #endif
    }
}

/// Uygulama öne geldi ve kapanıyor bildirimleri (hak durumu yenileme, açık sunucu oturumunu kapatma).
#if os(macOS)
private let hostedDidBecomeActiveNotification: Notification.Name = NSApplication.didBecomeActiveNotification
private let hostedWillTerminateNotification: Notification.Name = NSApplication.willTerminateNotification
#else
private let hostedDidBecomeActiveNotification: Notification.Name = UIApplication.didBecomeActiveNotification
private let hostedWillTerminateNotification: Notification.Name = UIApplication.willTerminateNotification
#endif

/// Girişte jetondan gelen kimlik (sağlayıcı ve e-posta): yalnızca bu cihazda, hesap ekranında kimin giriş yaptığını
/// göstermek için saklanır.
struct HostedSignInIdentity: Codable, Equatable {
    let provider: HostedSignInProvider
    let email: String?
}

/// Hesabın giriş kimliğinin anahtarı (hesap başına, yalnızca bu cihazda). Saf fonksiyondur.
private func hostedIdentityKey(userId: String) -> String {
    "hosted.identity.\(userId)"
}

/// Girişteki kimliği hesaba yazar; yazılamazsa uyarı loglanır (hesap ekranı kimliği göstermez, giriş etkilenmez).
private func saveHostedIdentity(identity: HostedSignInIdentity, userId: String) {
    do {
        UserDefaults.standard.set(try JSONEncoder().encode(identity), forKey: hostedIdentityKey(userId: userId))
    } catch {
        accountLogger.warning("Giriş kimliği saklanamadı, hata: \(String(describing: error), privacy: .private)")
    }
}

/// Hesabın saklanan giriş kimliği; yoksa nil, bozuksa nil ve hata loglanır.
private func loadHostedIdentity(userId: String) -> HostedSignInIdentity? {
    guard let data = UserDefaults.standard.data(forKey: hostedIdentityKey(userId: userId)) else {
        return nil
    }
    do {
        return try JSONDecoder().decode(HostedSignInIdentity.self, from: data)
    } catch {
        accountLogger.error("Giriş kimliği okunamadı, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// Hesabın profil resmi adresinin anahtarı (hesap başına, yalnızca bu Mac'te). Saf fonksiyondur.
private func hostedAvatarKey(userId: String) -> String {
    "hosted.avatarURL.\(userId)"
}

/// Girişte jetondan gelen profil resmini hesaba yazar; resim yoksa (Apple) eskisi silinir.
private func saveHostedAvatar(picture: URL?, userId: String) {
    if let picture {
        UserDefaults.standard.set(picture, forKey: hostedAvatarKey(userId: userId))
    } else {
        UserDefaults.standard.removeObject(forKey: hostedAvatarKey(userId: userId))
    }
}

/// Ödeme ya da portaldan uygulamaya dönünce aboneliğin beklendiği aralıklar (sn): 5 sn arayla 2 dk. Abonelik bu sürede
/// görünmezse kullanıcı vazgeçmiş sayılır; sonraki her öne gelişte hak durumu zaten bir dakikadan eskiyse yenilenir.
private let hostedBillingReturnPollDelays: [Double] = Array(repeating: 5, count: 24)
/// Ödeme sayfası açıkken aboneliğin beklendiği aralıklar (sn): ilk 2 dk 5 sn'de bir (ödemelerin çoğu bu sürede biter),
/// 5. dakikaya dek 15 sn'de bir, 15. dakikaya dek 30 sn'de bir (kart bilgisi girmeye yeter). Her okuma sunucu isteği,
/// çevrimdışı kuyruk turu ve Anahtar Zinciri okumasıdır: sabit 5 sn'lik 180 okuma yerine 56.
private let hostedCheckoutWatchDelays: [Double] =
    Array(repeating: 5, count: 24) + Array(repeating: 15, count: 12) + Array(repeating: 30, count: 20)

/// Sunucunun bu hesabın denemesini bu Mac'te reddettiği anın kaydı (hesap başına; abone olunca etkisizdir, bir gün
/// sonra sunucuya yeniden sorulur: bkz. `hostedTrialRefusalMaxAgeSec`). Saf fonksiyondur.
private func hostedTrialRefusedKey(userId: String) -> String {
    "hosted.trialRefusedOnThisMac.\(userId)"
}

/// Yeni girişten önce bu Mac'teki eski oturum sunucuda kapatılır. Sunucuya ulaşılamazsa yerel oturum yine silinir
/// (bkz. `HostedClient.signOut`) ve uyarı loglanır; sunucudaki yenileme jetonu kullanılmadığı için en geç
/// `REFRESH_TOKEN_DAYS` (60) gün içinde kendiliğinden geçersizleşir.
private func endPreviousSession(client: HostedClient) async throws {
    guard try await client.isSignedIn() else {
        return
    }
    do {
        try await client.signOut()
        accountLogger.info("Yeni giriş öncesi eski oturum kapatıldı")
    } catch HostedClientError.network(let path, _) {
        accountLogger.warning("Eski oturum sunucuda kapatılamadı (ağ), yerelde silindi, yol: \(path, privacy: .public)")
    } catch let error as HostedAPIError {
        accountLogger.warning("Eski oturum sunucuda kapatılamadı, yerelde silindi, kod: \(error.rawCode, privacy: .public), durum: \(error.status, privacy: .public)")
    }
}

/// Abonelik hesabının arayüz bağlantısı: giriş (Apple, Google), hak durumu, ödeme sayfaları, hesap silme,
/// toplantı oturumu ve cihaz doğrulaması. Sunucuya `HostedClient` ile bağlanır (dış sistem bağlantısı olduğu için
/// sınıftır). Hata metinleri kullanıcıya gösterilir; jeton ve içerik loglanmaz.
@MainActor
@Observable
final class HostedAccount {
    static let shared: HostedAccount = HostedAccount()

    private(set) var state: HostedAccountState = .loading
    /// Son işlemin hatası (giriş, ödeme, silme); yeni işlem başlayınca temizlenir.
    var errorMessage: String?
    /// Bir işlem sürüyor (düğmeler kilitli).
    private(set) var isWorking: Bool = false
    /// Giriş penceresi açık, dönüşü beklenen deneme (ham nonce yalnızca burada, bellekte; tek kullanımlık).
    private(set) var pendingBrowserSignIn: HostedBrowserSignInAttempt?
    /// Açık giriş penceresinin sağlayıcısı (düğmede bekleme göstergesi için).
    private(set) var pendingSignInProvider: HostedSignInProvider?
    /// Ana pencerede açılacak abone olma teklifi (bkz. `meetingNoteReady`); kayıt ya da işleme sürerken açılmaz.
    private(set) var upsell: HostedUpsellMoment?
    /// Alttaki teklif şeridinden planlar açıldı (bkz. `hostedUpsellPresentation`); teklif değişince ya da kapanınca
    /// sıfırlanır.
    private(set) var isUpsellExpanded: Bool = false
    /// Abonenin davet kodu ve sayıları (Ayarlar › Hesap açılınca okunur; bkz. `loadReferral`); yoksa nil.
    private(set) var referral: HostedReferral?
    /// Sunucu bu hesabın ücretsiz denemesini bu Mac'te reddetti (Mac denemesini başka bir hesapla kullandı); hak durumu
    /// kalan deneme 0 olarak gösterilir (bkz. `hostedEntitlementsOnThisMac`).
    private(set) var isTrialRefusedOnThisMac: Bool = false
    /// Son başlatılan toplantının sınırları (kayıt panelinde ve Ayarlar'da gösterilir).
    private(set) var currentMeeting: HostedStartedMeeting?
    /// Ana penceredeki kullanım bildirimi (%80, %100, son deneme toplantısı, deneme bitti). Her biri dönem başına bir
    /// kez gösterilir (UserDefaults'ta `hostedNoticeStorageKey` ile işaretlenir); kapatılınca ya da durum değişince kalkar.
    private(set) var visibleNotice: HostedUsageNotice?
    /// Bu Mac'te kayıtlı oturum var mı: açılışta Anahtar Zinciri'nden (ağsız) okunur, her yenilemede ve çıkışta
    /// güncellenir; okunamadıysa nil. Giriş kapısı buna bakar (bkz. `requiresSignIn`).
    private(set) var hasSession: Bool?
    /// Kayıt sunucuya ulaşılamadan (çevrimdışı) sürüyor: canlı metin Mac'te, toplantı sonra işlenecek.
    private(set) var isOfflineRecording: Bool = false
    /// Bekleyen (çevrimdışı) kayıtların işlenmesini tetikler: ağ gelince, hak durumu okununca ve uygulama öne gelince
    /// artar (uygulama izler; bkz. `AppModel.runOfflineQueue`).
    private(set) var queueTrigger: Int = 0
    /// Ödeme ya da müşteri portalı tarayıcıda açıldı: uygulama öne gelince hak durumu beklemeden yeniden okunur.
    @ObservationIgnored private var awaitingBillingReturn: Bool = false
    /// Ödeme sayfası açıkken aboneliği bekleyen izleme (bkz. `watchCheckout`); yoksa nil.
    @ObservationIgnored private var checkoutWatch: Task<Void, Never>?
    /// "Abonelik gerekli" teklifinin son açılışı (bkz. `subscriptionRequiredByServer`).
    @ObservationIgnored private var lastSubscriptionPromptAt: Date?
    /// Süren hak durumu okumaları (eşzamanlı okumalar birbirinin bayrağını indirmesin).
    @ObservationIgnored private var refreshesInFlight: Int = 0
    private var isRefreshing: Bool { refreshesInFlight > 0 }
    /// Hesap durumunun kuşağı: her okuma, çıkış ve hesap silme artırır; geç dönen eski okuma yeni durumu ezmez (çıkıştan
    /// sonra dönen okuma oturumu "giriş yapıldı" göstermez; bkz. `isCurrentSessionGeneration`).
    @ObservationIgnored private var stateGeneration: Int = 0
    /// En yeni hesap okumasının beklediği adım (ilk okuma süresinde bitmezse loglanır; bkz. `reportOverdueLoad`).
    @ObservationIgnored private var loadStep: HostedAccountLoadStep = .session
    /// Oturumdaki kullanıcı (Anahtar Zinciri'nden, her okumada); oturum yoksa nil. Çevrimdışı kayıt izni buna göre
    /// denetlenir (başka hesabın izni kullanılmaz).
    private(set) var signedInUserIDCache: String?
    /// Avatar resmi kaydedildikçe artar (aynı hesap yeniden girince de görünüm yenilensin; bkz. `avatarURL`).
    private(set) var avatarRevision: Int = 0
    /// Son silinen hesabın süren App Store aboneliği (`DELETE /v1/me` yanıtı): Apple onu hesapla birlikte iptal etmez;
    /// giriş kapısı kullanıcıya Apple'da iptal etmesini söyler. Yeni girişte kalkar; yoksa nil.
    private(set) var deletedAppStoreSubscription: HostedDeletedAppStoreSubscription?

    /// Oturumdaki hesabın profil resmi (Google ile girişte jetondan alınır, yalnızca bu cihazda saklanır); yoksa nil
    /// (Apple resim vermez): avatar baş harfi gösterir (bkz. `ProfileAvatar`).
    var avatarURL: URL? {
        _ = avatarRevision
        return signedInUserIDCache.flatMap { (userID: String) -> URL? in UserDefaults.standard.url(forKey: hostedAvatarKey(userId: userID)) }
    }

    /// Oturumdaki hesabın girişteki kimliği (sağlayıcı ve e-posta; bu cihazda saklanır); bu sürümden önce giriş yapıldıysa
    /// nil.
    var signedInIdentity: HostedSignInIdentity? {
        _ = avatarRevision
        return signedInUserIDCache.flatMap { (userID: String) -> HostedSignInIdentity? in loadHostedIdentity(userId: userID) }
    }
    /// Son başarılı hak durumu okuması (uygulama öne gelince eskimişse yenilenir).
    @ObservationIgnored private var lastRefreshAt: Date?
    /// Yenilemenin gösterdiği hata: sonraki başarılı yenileme onu kaldırır (bağlantı gelince eski hata kalmasın).
    @ObservationIgnored private var refreshErrorMessage: String?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// Ağ geri gelince hak durumu yeniden okunur (bkz. `readUnknownStatus`).
    @ObservationIgnored private let pathMonitor: NWPathMonitor = NWPathMonitor()
    /// Açık giriş penceresi: oturum bitene dek tutulmalı (yoksa sistem pencereyi kapatır).
    @ObservationIgnored private var webSession: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter: HostedWebSignInPresenter = HostedWebSignInPresenter()

    private init() {
        do {
            let userID: String? = try hostedStoredUserID(bundle: .main)
            hasSession = userID != nil
            signedInUserIDCache = userID
        } catch {
            // Kapı kapalı kalır; ilk yenileme hesabı "kullanılamıyor" yapar ve nedeni kapıda görünür.
            accountLogger.error("Kayıtlı oturum okunamadı, hata: \(String(describing: error), privacy: .private)")
            hasSession = nil
        }
        // Açılışta oturum varsa o hesabın verisi, toplantılar okunmadan önce yüklenir (bkz. `syncAccountData`).
        syncAccountData(userID: signedInUserIDCache)
        observers.append(NotificationCenter.default.addObserver(forName: .hostedSubscriptionRequired, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.promptSubscriptionIfDue()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .hostedSessionEnded, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                self?.currentMeeting = nil
                self?.hasSession = false
                // Biten oturumun abonelik isteği ve davet kodu sonraki girişe (başka hesap olabilir) kalmasın.
                self?.upsell = nil
                self?.isUpsellExpanded = false
                self?.referral = nil
                clearHostedOfflinePermit()
                self?.state = .signedOut
                self?.errorMessage = userFacingMessage(error: HostedClientError.sessionEnded)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: hostedDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                Task {
                    await self.readUnknownStatus()
                    await self.refreshOnActivation()
                    await self.closeOrphanedMeeting()
                    self.queueTrigger += 1
                }
            }
        })
        pathMonitor.pathUpdateHandler = { [weak self] (path: NWPath) -> Void in
            guard path.status == .satisfied else {
                return
            }
            Task { @MainActor in
                await self?.networkBecameAvailable()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.senoldogan.AINotepad.hosted.path"))
        // Uygulama kapanırken açık kalan sunucu oturumu kapatılmaya çalışılır (en çok 3 sn); olmazsa sonraki açılışta.
        observers.append(NotificationCenter.default.addObserver(forName: hostedWillTerminateNotification, object: nil, queue: .main) { [weak self] (_: Notification) -> Void in
            MainActor.assumeIsolated {
                endOpenMeetingBeforeQuit(userID: self?.signedInUserIDCache)
            }
        })
    }

    /// Giriş kapısı kapalı mı: bu Mac'te oturum yoksa (ya da okunamadıysa) ana arayüz, kayıt, kısayollar ve menü
    /// eylemleri açılmaz. Oturum varken hak durumu bilinmese de (çevrimdışı) kapı açıktır. Tanıtım modu (yalnız Debug)
    /// sunucuya bağlanmadığı için kapıya takılmaz.
    var requiresSignIn: Bool {
        #if DEBUG
        if isDemoMode {
            return isSignInShownForDemo
        }
        #endif
        return hasSession != true || !isAccountDataLoaded
    }

    #if DEBUG
    /// Tanıtım modunda giriş kapısı gösteriliyor (`DemoScene.signIn`).
    private(set) var isSignInShownForDemo: Bool = false

    /// Tanıtım modu (bkz. `DemoScene.signIn`): oturum yokmuş gibi giriş kapısı açılır; sunucuya bağlanılmaz.
    func showSignedOutForDemo() {
        state = .signedOut
        isSignInShownForDemo = true
    }
    #endif

    // MARK: Hesap verisi

    /// Bu süreçte yüklü hesap verisinin durumu (bkz. `syncAccountData`). Giriş yapan hesabın verisi yüklü değilse giriş
    /// kapısı kapalı kalır ve nedeni kapıda görünür: hiçbir hesap başka bir hesabın toplantılarını görmez.
    private(set) var dataState: HostedDataState = .notLoaded
    /// Hesap verisi bu süreçte ilk kez yüklendiğinde artar (açılışta oturum yoktu, sonra giriş yapıldı): uygulama
    /// toplantıları, kişileri ve geçmişi o zaman okur (bkz. `AppModel.performStartupMaintenance`).
    private(set) var dataActivations: Int = 0

    /// Giriş yapan hesabın verisi yüklü mü.
    var isAccountDataLoaded: Bool {
        if case .loaded = dataState {
            return true
        }
        return false
    }

    /// Yüklü hesap verisini giriş yapan hesapla eşler (açılışta ve her hesap okumasında): giriş yoksa yüklü veri kalır
    /// (çıkış yerel veriyi silmez, kapı gizler); henüz hesap yüklenmediyse giriş yapanınki yüklenir (önceki veri
    /// sahiplenilmediyse ona taşınır); başka bir hesabınki yüklüyse hesap değişimi bekler (`switchPending`; kayıt ve
    /// işleme yokken Mac yeniden başlar, iPhone hesabı yerinde değiştirir).
    private func syncAccountData(userID: String?) {
        let loadedKey: String? = AppPaths.activeAccountKey()
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: açılışta yüklenen tanıtım hesabı kalır (bkz. App/DemoData.swift).
        if isDemoMode {
            if let loadedKey {
                dataState = .loaded(accountKey: loadedKey)
            }
            return
        }
        #endif
        switch accountDataTransition(loadedKey: loadedKey, signedInKey: userID.map { (id: String) -> String in accountDataKey(userId: id) }) {
        case .keep:
            if let loadedKey {
                dataState = .loaded(accountKey: loadedKey)
            }
        case .activate:
            guard let userID else {
                return
            }
            do {
                let key: String = try prepareHostedAccountData(userId: userID)
                dataState = .loaded(accountKey: key)
                dataActivations += 1
            } catch {
                accountLogger.error("Hesap verisi hazırlanamadı, hata: \(String(describing: error), privacy: .private)")
                dataState = .failed(message: userFacingMessage(error: error))
            }
        case .switchAccount(_, let accountKey):
            if dataState != .switchPending(accountKey: accountKey) {
                accountLogger.info("Başka bir hesapla giriş yapıldı, hesap verisi boşta olunca değişecek")
            }
            dataState = .switchPending(accountKey: accountKey)
        }
    }

    #if os(iOS)
    /// Bekleyen hesap değişimini yerinde tamamlar (iPhone kendini yeniden başlatamaz): yüklü hesap giriş yapan hesapla
    /// değiştirilir ve onun verisi yüklenir. Çağıran, yazan her işin kapandığını kanıtlar (`writers`) ve eski hesabın
    /// bellekteki verisini önceden bırakır; yeni hesabın verisini bu çağrıdan sonra kurar. Değişim bekleyen bir hesap
    /// yoksa (`switchPending` değil ya da oturum bu arada değişti) `noPendingSwitch`; yeni hesabın verisi hazırlanamazsa
    /// neden kapıda görünür (`failed`; "Yeniden dene" değişimi yeniden ister) ve eski hesap yüklü kalır.
    func completeAccountSwitch(writers: ClosedAccountWriters) throws(HostedAccountSwitchError) {
        guard case .switchPending(let accountKey) = dataState, let userID = signedInUserIDCache, accountDataKey(userId: userID) == accountKey,
              let loadedKey = AppPaths.activeAccountKey() else {
            throw HostedAccountSwitchError.noPendingSwitch(state: dataState)
        }
        do {
            let key: String = try switchHostedAccountData(userId: userID, from: loadedKey, writers: writers)
            dataState = .loaded(accountKey: key)
            dataActivations += 1
            accountLogger.info("Hesap verisi yerinde değiştirildi")
        } catch {
            accountLogger.error("Hesap değiştirilemedi, hata: \(String(describing: error), privacy: .private)")
            dataState = .failed(message: userFacingMessage(error: error))
        }
    }
    #endif

    /// Hazırlanamayan hesap verisini yeniden dener (kapıdaki "Yeniden dene"); hesap değişimi (Mac'te yeniden başlatma,
    /// iPhone'da yerinde değişim) başarısız olduysa değişimi yeniden ister.
    func retryAccountData() {
        syncAccountData(userID: signedInUserIDCache)
    }

    /// Hesap değişiminde uygulama yeniden başlatılamadı: neden kapıda görünür, "Yeniden dene" yeniden ister.
    func reportRelaunchFailure(message: String) {
        dataState = .failed(message: message)
    }

    /// Bu Mac'te oturum var mı (hak durumu okunmuş olsun ya da olmasın).
    var isSignedIn: Bool {
        switch state {
        case .signedIn, .signedInStatusUnknown:
            true
        case .loading, .signedOut, .unavailable:
            false
        }
    }

    /// Son okunan hak durumu deneme mi. Bilinmiyorsa (okunamadı) false: DeviceCheck jetonu yalnızca deneme olduğu
    /// bilinen hesapta ya da sunucu isteyince gönderilir (abonelerin hiç gerekmez).
    private var isKnownTrial: Bool {
        if case .signedIn(let entitlements) = state {
            return entitlements.plan == .trial
        }
        return false
    }

    // MARK: Durum

    /// Oturumu ve hak durumunu sunucudan yeniden okur; App Attest destekleniyorsa cihaz önce doğrulanır (sessizce
    /// atlanır, bkz. `HostedDeviceAttestation`). Oturum varken hak durumu okunamazsa (ağ, sunucu) çıkış yapılmış
    /// sayılmaz: önceden okunmuş hak durumu kalır ve hata gösterilir; hiç okunmamışsa durum "bilinmiyor" olur.
    func refresh() async {
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz ve Anahtar Zinciri'ni okumaz: sahnenin yazdığı durum kalır.
        if isDemoMode {
            return
        }
        #endif
        refreshesInFlight += 1
        defer { refreshesInFlight -= 1 }
        stateGeneration += 1
        let generation: Int = stateGeneration
        loadStep = .session
        // İlk okuma sınırlı sürede bitmezse hesap "durumu okunamadı" gösterir (sonsuza dek "okunuyor" kalmaz).
        let deadline: Task<Void, Never>? = state == .loading ? Task { [weak self] in await self?.reportOverdueLoad(generation: generation) } : nil
        defer { deadline?.cancel() }
        let client: HostedClient
        let hasSession: Bool
        let userID: String?
        do {
            client = try HostedServices.requireClient()
            hasSession = try await client.isSignedIn()
            userID = try await client.signedInUserID()
        } catch {
            accountLogger.error("Hesap okunamadı, hata: \(String(describing: error), privacy: .private)")
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            state = .unavailable(message: userFacingMessage(error: error))
            return
        }
        guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
            return
        }
        self.hasSession = hasSession
        signedInUserIDCache = userID
        // Giriş yapan hesabın verisi, kapı açılmadan önce (aynı ana iş parçacığı adımında) yüklenir ya da yeniden
        // başlatma istenir: başka hesabın toplantıları bir an bile görünmez.
        syncAccountData(userID: userID)
        guard hasSession else {
            state = .signedOut
            return
        }
        do {
            loadStep = .deviceAttestation
            await HostedDeviceAttestation.prepare(client: client)
            if isCurrentSessionGeneration(started: generation, current: stateGeneration) {
                loadStep = .entitlements
            }
            let received: HostedEntitlements = try await client.entitlements()
            // Bu arada çıkış yapıldıysa ya da daha yeni bir okuma başladıysa eski sonuç yazılmaz.
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            isTrialRefusedOnThisMac = isHostedTrialRefusalActive(
                refusedAt: UserDefaults.standard.object(forKey: hostedTrialRefusedKey(userId: received.userId)) as? Date,
                now: Date(),
                maxAgeSec: hostedTrialRefusalMaxAgeSec
            )
            let entitlements: HostedEntitlements = hostedEntitlementsOnThisMac(entitlements: received, trialRefusedOnThisMac: isTrialRefusedOnThisMac)
            state = .signedIn(entitlements)
            lastRefreshAt = Date()
            saveHostedOfflinePermit(permit: hostedOfflinePermit(entitlements: entitlements, now: Date()))
            queueTrigger += 1
            if let refreshErrorMessage, errorMessage == refreshErrorMessage {
                errorMessage = nil
            }
            refreshErrorMessage = nil
            updateNotice(entitlements: entitlements, now: Date())
        } catch HostedClientError.notSignedIn, HostedClientError.sessionEnded {
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            self.hasSession = false
            signedInUserIDCache = nil
            clearHostedOfflinePermit()
            state = .signedOut
        } catch {
            accountLogger.error("Hak durumu okunamadı, hata: \(String(describing: error), privacy: .private)")
            guard isCurrentSessionGeneration(started: generation, current: stateGeneration) else {
                return
            }
            let message: String = userFacingMessage(error: error)
            if case .signedIn = state {
                errorMessage = message
                refreshErrorMessage = message
            } else {
                state = .signedInStatusUnknown(message: message)
            }
        }
    }

    /// İlk hesap okuması `hostedAccountLoadDeadlineSec` içinde bitmediyse (oturum var, durum hâlâ "okunuyor") hesap
    /// "durumu okunamadı" olur: ekran "Yeniden dene" gösterir, bağlantı gelince ve uygulama öne gelince yeniden okunur.
    /// Okuma sürer; dönünce gerçek durumu yazar. Okuma süresinde biterse görev iptal edilir.
    private func reportOverdueLoad(generation: Int) async {
        do {
            try await Task.sleep(for: .seconds(hostedAccountLoadDeadlineSec))
        } catch {
            // Okuma süresinde bitti (görev iptal edildi).
            return
        }
        guard isHostedAccountLoadOverdue(
            isAwaitingFirstRead: state == .loading, hasSession: hasSession, started: generation, current: stateGeneration
        ) else {
            return
        }
        accountLogger.warning("Hesap okuması süresinde bitmedi, adım: \(self.loadStep.rawValue, privacy: .public), süre: \(hostedAccountLoadDeadlineSec, privacy: .public)")
        state = .signedInStatusUnknown(message: hostedAccountLoadTimeoutMessage())
    }

    /// Bildirimi hak durumuna göre günceller: yeni eşik aşıldıysa ve bu dönemde gösterilmediyse gösterilir ve
    /// "gösterildi" diye işaretlenir; eşik artık geçerli değilse kalkar.
    private func updateNotice(entitlements: HostedEntitlements, now: Date) {
        guard let notice = hostedUsageNotice(entitlements: entitlements) else {
            visibleNotice = nil
            return
        }
        if visibleNotice == notice {
            return
        }
        // Son deneme toplantısı açılınca kalan hak 0'a iner; o toplantı sürerken "deneme bitti" gösterilmez (kayıt
        // duracak sanılmasın), toplantı kapanınca yapılan yenilemede gösterilir. Deneme bu Mac'te reddedildiyse de
        // gösterilmez: deneme hiç bitmedi, nedeni Başlat düğmesinin yanında yazar.
        if notice == .trialEnded && (currentMeeting != nil || isTrialRefusedOnThisMac) {
            visibleNotice = nil
            return
        }
        let key: String = hostedNoticeStorageKey(notice: notice, userId: entitlements.userId, now: now)
        guard !UserDefaults.standard.bool(forKey: key) else {
            visibleNotice = nil
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        visibleNotice = notice
        accountLogger.info("Kullanım bildirimi gösteriliyor, tür: \(notice.rawValue, privacy: .public)")
    }

    /// Bir toplantının notu hazır: hak durumu yenilenir; hesap denemedeyse ve zamanı geldiyse (günde en çok bir, deneme
    /// bitince bir kez; bkz. `hostedUpsellMoment`) abone olma teklifi açılır ve gösterim hesap başına kaydedilir.
    func meetingNoteReady() async {
        await refresh()
        guard case .signedIn(let entitlements) = state else {
            return
        }
        let lastShownKey: String = "hosted.upsell.lastShownAt.\(entitlements.userId)"
        let trialEndedKey: String = "hosted.upsell.trialEndedShown.\(entitlements.userId)"
        let trialEndingKey: String = "hosted.upsell.trialEndingShown.\(entitlements.userId)"
        guard let moment = hostedUpsellMoment(
            entitlements: entitlements,
            lastShownAt: UserDefaults.standard.object(forKey: lastShownKey) as? Date,
            trialEndedShown: UserDefaults.standard.bool(forKey: trialEndedKey),
            trialEndingShown: UserDefaults.standard.bool(forKey: trialEndingKey),
            now: Date(),
            intervalSec: hostedUpsellIntervalSec
        ) else {
            return
        }
        UserDefaults.standard.set(Date(), forKey: lastShownKey)
        if moment == .trialEnded {
            UserDefaults.standard.set(true, forKey: trialEndedKey)
        }
        if moment == .trialEnding {
            UserDefaults.standard.set(true, forKey: trialEndingKey)
        }
        upsell = moment
        isUpsellExpanded = false
        accountLogger.info("Abone olma teklifi gösteriliyor, an: \(moment.rawValue, privacy: .public)")
    }

    #if DEBUG
    /// Tanıtım modu (bkz. `DemoScene.upsell`): teklif sunucuya sorulmadan açılır.
    func showUpsellForDemo(moment: HostedUpsellMoment) {
        upsell = moment
        isUpsellExpanded = false
    }

    /// Tanıtım modu: hak durumu ve davet bilgisi sunucuya sorulmadan yazılır (bkz. `App/DemoData.swift`).
    func showAccountForDemo(entitlements: HostedEntitlements, referral: HostedReferral?) {
        state = .signedIn(entitlements)
        self.referral = referral
    }

    /// Tanıtım modu (`--hesap-degistir`, Simülatör'de denetim): başka bir sahte hesapla (`userId`) giriş yapılmış gibi
    /// hesap değişimini başlatır; sunucuya bağlanılmaz.
    func beginAccountSwitchForDemo(userId: String) {
        signedInUserIDCache = userId
        dataState = .switchPending(accountKey: accountDataKey(userId: userId))
    }
    #endif

    /// "Abone ol"a basıldı (Ayarlar › Hesap, kullanım bildirimi): planlar ana pencerede açılır. Deneme bittiyse ya da
    /// abonelik sona erdiyse teklif nedenini de söyler (`subscriptionRequired`).
    func showPlans() {
        upsell = requiresSubscription ? .subscriptionRequired : .planChoice
        isUpsellExpanded = false
    }

    /// Ücretli özellikler (kayıt, Sor, not) için abone olmak gerekiyor mu: deneme bitti ya da abonelik sona erdi (aylık
    /// sınırın dolması abonelikle çözülmez; hak durumu bilinmiyorsa sunucu karar verir).
    var requiresSubscription: Bool {
        guard case .signedIn(let entitlements) = state, let block = hostedStartBlock(entitlements: entitlements) else {
            return false
        }
        switch block {
        case .trialEnded, .subscriptionEnded:
            return true
        case .monthlyCapReached, .paymentOverdue:
            // Ödeme alınamadıysa yeni abonelik açılamaz (sunucu `subscription_exists` der): kart "Hesabı yönet"ten güncellenir.
            return false
        }
    }

    /// Kullanıcı abonelik gerektiren bir şey denedi (Başlat'a bastı) ama hakkı yok: abone olma teklifi hemen açılır.
    func requestSubscription() {
        lastSubscriptionPromptAt = Date()
        upsell = .subscriptionRequired
        isUpsellExpanded = false
    }

    /// Abonelik gerektiren bir istek durdu ya da sunucu reddetti (bkz. `hostedSubscriptionRequired`): teklif en çok
    /// `hostedSubscriptionPromptIntervalSec`'te bir açılır (arka plandaki işler art arda açmasın); hak durumu yenilenir.
    func promptSubscriptionIfDue() {
        if let last = lastSubscriptionPromptAt, Date().timeIntervalSince(last) < hostedSubscriptionPromptIntervalSec {
            return
        }
        lastSubscriptionPromptAt = Date()
        upsell = .subscriptionRequired
        isUpsellExpanded = false
        Task { await refresh() }
    }

    /// Alttaki teklif şeridinden planları açar (aynı an, tam teklif).
    func expandUpsell() {
        isUpsellExpanded = true
    }

    /// Ana pencerede planlar (tam teklif) açık mı: istenen anlarda hemen, kendiliğinden gelenlerde şeritten açılınca.
    var isUpsellSheetVisible: Bool {
        guard let upsell else {
            return false
        }
        return hostedUpsellPresentation(moment: upsell) == .sheet || isUpsellExpanded
    }

    /// Teklifi kapatır. Deneme bitti teklifi görüldüyse aynı şeyi söyleyen şerit de kalkar (iki kez söylenmesin).
    func dismissUpsell() {
        if upsell == .trialEnded && visibleNotice == .trialEnded {
            visibleNotice = nil
        }
        upsell = nil
        isUpsellExpanded = false
    }

    /// Bildirimi kapatır (bu dönemde yeniden gösterilmez).
    func dismissNotice() {
        visibleNotice = nil
    }

    /// Uygulama öne gelince hak durumunu yeniler: ödeme ya da portal sayfasından dönüldüyse hemen, değilse son okuma
    /// `hostedStaleRefreshIntervalSec`'ten eskiyse (kullanım göstergeleri, bildirimler ve başlat engeli eskimesin).
    private func refreshOnActivation() async {
        guard case .signedIn = state, !isRefreshing else {
            return
        }
        guard awaitingBillingReturn || isHostedRefreshDue(lastRefresh: lastRefreshAt, now: Date(), intervalSec: hostedStaleRefreshIntervalSec) else {
            return
        }
        let returnedFromBilling: Bool = awaitingBillingReturn
        awaitingBillingReturn = false
        // Kullanıcı uygulamaya döndü: ödeme sayfasının izlemesi (bkz. `watchCheckout`) durur, yerini aşağıdaki kısa
        // bekleme alır (uygulama zaten önde; 15 dk boyunca arka planda okuma sürmesin).
        if returnedFromBilling {
            stopCheckoutWatch()
        }
        await refresh()
        if returnedFromBilling {
            _ = await pollForSubscription(delays: hostedBillingReturnPollDelays)
        }
    }

    /// Abonelik görünene dek `delays` aralıklarıyla (sn) hak durumunu yeniler (Stripe bildirimi birkaç saniye
    /// gecikebilir; Başlat düğmesi uygulamaya yeniden geçmeyi beklemeden açılsın). Abonelik zaten görünüyorsa (ör.
    /// portaldan dönüş) hemen biter; görev iptal edilirse durur. Döner: abonelik göründü mü.
    private func pollForSubscription(delays: [Double]) async -> Bool {
        for delay in delays {
            guard case .signedIn(let entitlements) = state else {
                return false
            }
            switch hostedPlanStatus(entitlements: entitlements) {
            case .subscribed, .complimentary, .ending, .grace:
                return true
            case .trial, .expired, .paymentOverdue:
                break
            }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch is CancellationError {
                return false
            } catch {
                accountLogger.error("Abonelik beklemesi bozuldu, hata: \(String(describing: error), privacy: .private)")
                return false
            }
            await refresh()
        }
        accountLogger.warning("Abonelik beklendi ama görünmedi, deneme: \(delays.count, privacy: .public)")
        return false
    }

    #if os(macOS)
    /// Ödeme sayfası tarayıcıda açıldı: kullanıcı uygulamaya dönmeden abonelik beklenir (en çok 15 dk, giderek seyrelen
    /// aralıklarla; bkz. `hostedCheckoutWatchDelays`); görününce uygulama öne gelir, kullanıcı tarayıcıdan geri dönmek
    /// zorunda kalmaz. Önceki izleme varsa durdurulur; kullanıcı uygulamaya dönünce de durur (bkz. `refreshOnActivation`).
    private func watchCheckout() {
        stopCheckoutWatch()
        checkoutWatch = Task { [weak self] in
            guard let self else {
                return
            }
            let subscribed: Bool = await self.pollForSubscription(delays: hostedCheckoutWatchDelays)
            // İptal edilen (yerine yenisi açılan) izleme, yenisinin referansını silmesin.
            if !Task.isCancelled {
                self.checkoutWatch = nil
            }
            if subscribed, !NSApp.isActive {
                accountLogger.info("Abonelik göründü, uygulama öne getiriliyor")
                NSApp.activate()
            }
        }
    }
    #endif

    /// İstemcinin jetonundaki (oturumdaki) hesabın açık sunucu oturumları alanı: oturumlar o hesabın jetonuyla açılır
    /// ve kapatılır. Oturum yoksa `notSignedIn`.
    private func signedInOpenMeetingsDefaults(client: HostedClient) async throws -> UserDefaults {
        guard let userID = try await client.signedInUserID() else {
            throw HostedClientError.notSignedIn
        }
        return try hostedOpenMeetingsDefaults(userID: userID)
    }

    /// Ödeme sayfasının izlemesini durdurur (yoksa bir şey yapmaz).
    private func stopCheckoutWatch() {
        checkoutWatch?.cancel()
        checkoutWatch = nil
    }

    /// Ağ geri geldi: hak durumu bilinmiyorsa yeniden okunur, kapatılamamış sunucu oturumu kapatılır ve bekleyen
    /// (çevrimdışı) kayıtlar işlenmeye başlar.
    private func networkBecameAvailable() async {
        await readUnknownStatus()
        await closeOrphanedMeeting()
        queueTrigger += 1
    }

    /// Hak durumu henüz okunmadıysa (açılış), okunamadıysa (çevrimdışı açılış) ya da hesap hizmeti kullanılamadıysa (ör.
    /// Anahtar Zinciri cihazın ilk kilit açılışından önce okunamadı) ve süren okuma yoksa okur: iPhone'da açılışta, iki
    /// platformda ağ geri gelince ve uygulama öne gelince çağrılır.
    func readUnknownStatus() async {
        switch state {
        case .loading, .signedInStatusUnknown, .unavailable:
            break
        case .signedIn, .signedOut:
            return
        }
        guard !isRefreshing else {
            return
        }
        accountLogger.info("Hak durumu okunuyor (açılış, bağlantı ya da uygulama etkinleşti)")
        await refresh()
    }

    // MARK: Giriş ve çıkış

    /// Seçilen sağlayıcıyla (Apple ya da Google) uygulama içi giriş penceresinde (ASWebAuthenticationSession) girer:
    /// yeni ham nonce üretilir, sitedeki giriş sayfası nonce'un SHA-256'sı ve sağlayıcıyla açılır, site doğrudan
    /// sağlayıcıya yönlendirir; giriş bitince site `com.senoldogan.ainotepad.hosted://auth/<apple|google>#idToken=…`
    /// adresine yönlendirir ve dönüş Launch Services'e uğramadan doğrudan bu pencereye gelir (başka bir uygulama ya da
    /// eski bir kopya dönüşü alamaz). Dönüş bu denemenin nonce'uyla eşleşirse varsa eski oturum kapatılır ve kimlik
    /// jetonu ham nonce'la sağlayıcının giriş ucuna gider. Kullanıcı pencereyi kapatırsa hata gösterilmez. (Developer ID
    /// ile dağıtılan uygulama Apple ile girişi kendisi yapamaz; giriş sitede yapılır.)
    func signIn(provider: HostedSignInProvider) async {
        defer { avatarRevision += 1 }
        guard pendingBrowserSignIn == nil else {
            return
        }
        errorMessage = nil
        let attempt: HostedBrowserSignInAttempt
        let page: URL
        do {
            attempt = try makeHostedBrowserSignInAttempt(now: Date())
            page = hostedBrowserSignInPage(siteBase: try HostedServices.siteBase(), nonceHash: hostedNonceHash(nonce: attempt.rawNonce), provider: provider)
        } catch {
            accountLogger.error("Giriş başlatılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            reportHostedFunnel(step: .signInFailed(.window))
            return
        }
        reportHostedFunnel(step: .signInStarted(provider))
        deletedAppStoreSubscription = nil
        pendingBrowserSignIn = attempt
        pendingSignInProvider = provider
        defer {
            pendingBrowserSignIn = nil
            pendingSignInProvider = nil
            webSession = nil
        }
        accountLogger.info("Giriş penceresi açılıyor, sağlayıcı: \(provider.rawValue, privacy: .public)")
        let callbackURL: URL
        do {
            switch try await runWebSignIn(page: page) {
            case .canceled:
                accountLogger.info("Giriş penceresi kapatıldı")
                reportHostedFunnel(step: .signInCanceled(provider))
                return
            case .callback(let url):
                callbackURL = url
                #if os(macOS)
                // Giriş varsayılan tarayıcıda (ör. Chrome penceresinde) bittiyse odak orada kalmasın: kullanıcı
                // doğrudan uygulamaya döner.
                NSApp.activate()
                #endif
            }
        } catch {
            accountLogger.error("Giriş penceresi açılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            reportHostedFunnel(step: .signInFailed(.window))
            return
        }
        let callback: HostedBrowserSignInCallback
        do {
            callback = try resolveHostedBrowserCallback(url: callbackURL, pending: attempt, now: Date(), lifetimeSec: hostedBrowserSignInLifetimeSec)
        } catch {
            accountLogger.error("Giriş dönüşü reddedildi, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
            reportHostedFunnel(step: .signInFailed(.callback))
            return
        }
        let picture: URL?
        do {
            picture = try hostedIDTokenPicture(identityToken: callback.identityToken)
        } catch {
            // Avatar girişe engel değil: resim yerine küre görünür.
            accountLogger.warning("Profil resmi jetondan okunamadı, hata: \(String(describing: error), privacy: .private)")
            picture = nil
        }
        let email: String?
        do {
            email = try hostedIDTokenEmail(identityToken: callback.identityToken)
        } catch {
            // Kimlik girişe engel değil: hesap ekranı e-postasız sağlayıcıyı gösterir.
            accountLogger.warning("E-posta jetondan okunamadı, hata: \(String(describing: error), privacy: .private)")
            email = nil
        }
        await perform { (client: HostedClient) async throws -> Void in
            do {
                try await endPreviousSession(client: client)
                switch callback.provider {
                case .apple:
                    try await client.signInWithApple(identityToken: callback.identityToken, nonce: callback.rawNonce)
                case .google:
                    try await client.signInWithGoogle(identityToken: callback.identityToken, nonce: callback.rawNonce)
                }
            } catch {
                // Hata `perform`'da kullanıcıya gösterilir; burada yalnızca huninin aşaması bildirilip yeniden fırlatılır.
                reportHostedFunnel(step: .signInFailed(hostedSignInFailureStage(error: error)))
                throw error
            }
            reportHostedFunnel(step: .signedIn(callback.provider))
            if let userID = try await client.signedInUserID() {
                saveHostedAvatar(picture: picture, userId: userID)
                saveHostedIdentity(identity: HostedSignInIdentity(provider: callback.provider, email: email), userId: userID)
            }
        }
    }

    /// Giriş penceresini açar ve dönüşü bekler. Pencere açılamazsa `HostedBrowserSignInError.sessionNotStarted`.
    private func runWebSignIn(page: URL) async throws -> HostedWebSignInOutcome {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HostedWebSignInOutcome, any Error>) -> Void in
            // Tamamlanma bir kez sürdürülür: başlatılamayan oturum da tamamlanma bildirebilir.
            let pending: OSAllocatedUnfairLock<CheckedContinuation<HostedWebSignInOutcome, any Error>?> = OSAllocatedUnfairLock(initialState: continuation)
            let finish: @Sendable (Result<HostedWebSignInOutcome, any Error>) -> Void = { (result: Result<HostedWebSignInOutcome, any Error>) -> Void in
                pending.withLock { (waiting: inout CheckedContinuation<HostedWebSignInOutcome, any Error>?) -> Void in
                    waiting?.resume(with: result)
                    waiting = nil
                }
            }
            // Tamamlanma bloğu `@Sendable` (ana aktöre bağlı değil): sistem onu arka plandaki XPC kuyruğunda çağırır;
            // bu sınıfın ana aktör bağlamını devralsaydı Swift'in yalıtım denetimi uygulamayı çökertirdi.
            let completion: @Sendable (URL?, (any Error)?) -> Void = { (url: URL?, error: (any Error)?) -> Void in
                if let url {
                    finish(.success(.callback(url)))
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    finish(.success(.canceled))
                } else {
                    finish(.failure(HostedBrowserSignInError.sessionNotStarted(reason: error.map { String(describing: $0) } ?? "dönüş adresi yok")))
                }
            }
            let session: ASWebAuthenticationSession = ASWebAuthenticationSession(url: page, callback: .customScheme(hostedURLScheme), completionHandler: completion)
            session.presentationContextProvider = presenter
            // Tarayıcıdaki Apple ve Google oturumları kullanılabilsin (her girişte parola sorulmasın).
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            guard session.start() else {
                finish(.failure(HostedBrowserSignInError.sessionNotStarted(reason: "start() false döndü")))
                return
            }
        }
    }

    /// Çıkış: sunucuda oturum kapatılır, yerel oturum her durumda silinir. Sunucuya ulaşılamazsa (çevrimdışı) bu Mac'te
    /// çıkış yine yapılır ve bu söylenir: sunucudaki yenileme jetonu kullanılmadığı için en geç `REFRESH_TOKEN_DAYS`
    /// (60) gün içinde kendiliğinden geçersizleşir.
    func signOut() async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        // Süren hak durumu okuması çıkıştan sonra dönerse oturumu "giriş yapıldı" göstermesin.
        stateGeneration += 1
        referral = nil
        upsell = nil
        isUpsellExpanded = false
        do {
            try await HostedServices.requireClient().signOut()
        } catch HostedClientError.network(let path, _) {
            accountLogger.warning("Çıkış sunucuya iletilemedi (ağ), yerelde yapıldı, yol: \(path, privacy: .public)")
            errorMessage = hostedLocalSignOutMessage()
        } catch let error as HostedAPIError {
            accountLogger.warning("Çıkış sunucuda reddedildi, yerelde yapıldı, kod: \(error.rawCode, privacy: .public), durum: \(error.status, privacy: .public)")
            errorMessage = hostedLocalSignOutMessage()
        } catch {
            accountLogger.error("Çıkış yapılamadı, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
        }
        currentMeeting = nil
        clearHostedOfflinePermit()
        await refresh()
    }

    /// Hesabı ve sunucudaki tüm verilerini siler (bitmemiş abonelik Stripe'ta iptal edilir).
    func deleteAccount() async {
        stateGeneration += 1
        // Silinen hesabın açık oturum listesi (silmeden sonra oturum yoktur, hesap ondan önce okunur).
        let userID: String? = signedInUserIDCache
        await perform { (client: HostedClient) async throws -> Void in
            // Yerel temizlik yalnızca silme başarılıysa: başarısızsa (ör. çevrimdışı) hesap durur, kapatılamamış oturumları
            // izlenmeye ve çevrimdışı kayıt izni geçerli kalmalı.
            do {
                let deletion: HostedAccountDeletion? = try await client.deleteAccount()
                await self.finishAccountDeletion(deletion: deletion, userID: userID)
            } catch let failure as HostedAccountDeletedLocalFailure {
                // Sunucu hesabı sildi, bu cihazdaki son adım başarısız oldu: hesap silinmiş sayılır, hata da gösterilir.
                await self.finishAccountDeletion(deletion: failure.deletion, userID: userID)
                throw failure
            }
        }
    }

    /// Sunucuda silinen hesabın bu cihazdaki sonu: süren App Store aboneliği giriş kapısında gösterilmek üzere tutulur,
    /// yerel izler temizlenir.
    private func finishAccountDeletion(deletion: HostedAccountDeletion?, userID: String?) {
        if let subscription = deletion?.appStoreSubscription {
            // Kullanıcı silmeden önce uyarıyı gördü; Apple aboneliği kendisi iptal etmeli. Uyarı silmeden sonra da
            // görünür (iPhone'da giriş kapısında, Apple'ın abonelik penceresini açan düğmeyle).
            accountLogger.info("Silinen hesabın App Store aboneliği sürüyor, yenilenecek: \(subscription.willRenew, privacy: .public)")
        }
        rememberDeletedAppStoreSubscription(subscription: deletion?.appStoreSubscription)
        clearAfterAccountDeletion(userID: userID)
    }

    /// Silinen hesabın süren App Store aboneliğini (yoksa nil) giriş kapısında göstermek için tutar.
    private func rememberDeletedAppStoreSubscription(subscription: HostedDeletedAppStoreSubscription?) {
        deletedAppStoreSubscription = subscription
    }

    #if os(iOS)
    /// App Store satın almasından ya da geri yüklemeden sonra hakkın sunucuya gelmesini bekler: önce sunucu aboneliği
    /// RevenueCat'ten okur (`POST /v1/billing/app-store/sync`), gelmediyse webhook beklenir ve `GET /v1/me`
    /// `hostedAppStoreEntitlementDelays` aralıklarıyla yeniden okunur. Hak gelince hesap durumu yenilenir; gelmezse
    /// `HostedAppStoreEntitlementMissing` fırlar (ödeme Apple'da alınmıştır, yeniden denemek ödemeyi yinelemez).
    func confirmAppStorePurchase() async throws {
        let client: HostedClient = try HostedServices.requireClient()
        var attempts: Int = 0
        var lastError: String?
        while true {
            let latest: HostedEntitlements?
            do {
                latest = attempts == 0 ? try await client.syncAppStoreSubscription() : try await client.entitlements()
                lastError = nil
            } catch {
                accountLogger.warning("App Store hakkı okunamadı, deneme: \(attempts + 1, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                latest = nil
                lastError = userFacingMessage(error: error)
            }
            attempts += 1
            switch hostedEntitlementWaitStep(latest: latest, completedAttempts: attempts, delays: hostedAppStoreEntitlementDelays) {
            case .arrived:
                accountLogger.info("App Store hakkı sunucuda göründü, deneme: \(attempts, privacy: .public)")
                await refresh()
                return
            case .retry(let seconds):
                try await Task.sleep(for: .seconds(seconds))
            case .gaveUp:
                accountLogger.error("App Store hakkı sunucuda görünmedi, deneme: \(attempts, privacy: .public)")
                await refresh()
                throw HostedAppStoreEntitlementMissing(attempts: attempts, lastError: lastError)
            }
        }
    }
    #endif

    /// Silinen hesabın yerel izleri: şimdiki toplantı, abonelik isteği, davet kodu, çevrimdışı kayıt izni, girişteki kimlik
    /// (e-posta), profil resminin adresi ve açık oturum listesi. Toplantılar silinmez; hesap bu cihazda silinmiş olarak
    /// kaydedilir (yeni hesaba taşınabilsin).
    private func clearAfterAccountDeletion(userID: String?) {
        currentMeeting = nil
        upsell = nil
        isUpsellExpanded = false
        referral = nil
        clearHostedOfflinePermit()
        guard let userID else {
            return
        }
        UserDefaults.standard.removeObject(forKey: hostedIdentityKey(userId: userID))
        UserDefaults.standard.removeObject(forKey: hostedAvatarKey(userId: userID))
        // Sunucudaki eşitleme kopyası hesapla silindi; bu cihazdaki eşitleme anahtarı ve kayıtları da gider (toplantılar
        // kalır).
        Task { await HostedSyncCenter.shared.forgetAfterAccountDeletion(userID: userID) }
        // Asistan kopyası da hesapla silindi; bu cihazdaki yükleme defteri gider.
        HostedAssistantCenter.shared.forgetAfterAccountDeletion(userID: userID)
        do {
            clearHostedOpenMeetingIDs(defaults: try hostedOpenMeetingsDefaults(userID: userID))
        } catch {
            accountLogger.error("Silinen hesabın açık oturum listesi temizlenemedi, hata: \(String(describing: error), privacy: .private)")
        }
        // Toplantılar bu cihazda kalır: hesap bu cihazda silindi diye kaydedilir, yeniden açılan hesaba taşınması önerilir
        // (bkz. `HostedDeletedMeetings`). Kaydedilemezse neden görünür (toplantılar yine yerinde kalır).
        do {
            try recordDeletedAccount(dataRoot: try AppPaths.applicationSupport(), accountKey: accountDataKey(userId: userID))
        } catch {
            accountLogger.error("Silinen hesap bu cihazda kaydedilemedi, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
        }
    }

    // MARK: Davet

    /// Abonenin davet kodunu ve sayılarını okur (Ayarlar › Hesap açılınca; Mac ve iPhone). Abonelik erişimi yoksa ya da okunamazsa
    /// davet bölümü görünmez (hata loglanır; davet isteğe bağlıdır, hesap ekranını bozmaz).
    func loadReferral() async {
        #if DEBUG
        if isDemoMode {
            return
        }
        #endif
        guard case .signedIn(let entitlements) = state, let subscription = entitlements.subscription, subscription.access != .none else {
            referral = nil
            return
        }
        do {
            referral = try await HostedServices.requireClient().referral()
        } catch {
            accountLogger.error("Davet bilgisi okunamadı, hata: \(String(describing: error), privacy: .private)")
            referral = nil
        }
    }

    // MARK: Ödeme

    // Ödeme, müşteri portalı ve davet kodu girme yalnızca Mac'te: iPhone uygulaması içinde App Store dışı bir satın alma
    // yoluna yönlendirilmez (App Store 3.1.1); iPhone'da abonelik uygulama içi satın almayla alınır. Davet bağlantısını
    // arkadaşa göndermek (yukarıda) iki yerde de vardır.
    #if os(macOS)

    /// Seçilen planın Stripe Checkout'unu tarayıcıda açar (`referralCode`: doğrulanmış davet kodu, yoksa nil) ve
    /// abonelik görününce uygulamayı öne getirir (bkz. `watchCheckout`); bitmemiş abonelik varsa Müşteri Portalı açılır.
    /// Hata yoksa true; açılamadıysa false ve neden `errorMessage`'da (teklif açık kalır, neden orada görünür).
    func subscribe(plan: HostedBillingPlan, referralCode: String?) async -> Bool {
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz ve Anahtar Zinciri'ni okumaz.
        if isDemoMode {
            return true
        }
        #endif
        await perform { (client: HostedClient) async throws -> Void in
            do {
                NSWorkspace.shared.open(try await client.checkoutURL(plan: plan, referralCode: referralCode))
                await self.markAwaitingBillingReturn()
                await self.watchCheckout()
            } catch let error as HostedAPIError where error.code == .subscriptionExists {
                NSWorkspace.shared.open(try await client.portalURL())
                await self.markAwaitingBillingReturn()
            } catch let error as HostedAPIError where error.code == .complimentarySubscription {
                // Hesaba bu arada ücretsiz erişim verildi: ödenecek bir şey yok; `perform` hak durumunu yeniler ve
                // arayüz "Ücretsiz tam erişim" gösterir.
                accountLogger.info("Abone olma gereksiz, hesapta ücretsiz erişim var, kod: \(error.rawCode, privacy: .public)")
            }
        }
        return errorMessage == nil
    }

    /// Davet kodunu ödemeden önce sunucuya doğrulatır: biçimsiz kod sunucuya sorulmaz; geçerliyse sadeleşmiş kod,
    /// değilse kullanıcıya gösterilecek neden.
    func validateReferral(input: String) async -> HostedReferralCheck {
        let code: String = normalizedHostedReferralCode(input: input)
        guard isWellFormedHostedReferralCode(code: code) else {
            return .invalid(message: String(localized: "Davet kodu 8 karakterdir, ör. K7M2QX9D."))
        }
        #if DEBUG
        // Tanıtım modu sunucuya bağlanmaz: biçimi doğru kod geçerli sayılır.
        if isDemoMode {
            return .valid(code: code)
        }
        #endif
        do {
            return .valid(code: try await HostedServices.requireClient().validateReferral(code: code).code)
        } catch {
            accountLogger.warning("Davet kodu doğrulanmadı, hata: \(String(describing: error), privacy: .private)")
            return .invalid(message: userFacingMessage(error: error))
        }
    }

    /// Stripe Müşteri Portalı (kart, iptal; makbuzlar Link'ten e-postayla gelir).
    func manageSubscription() async {
        await perform { (client: HostedClient) async throws -> Void in
            NSWorkspace.shared.open(try await client.portalURL())
            await self.markAwaitingBillingReturn()
        }
    }

    /// Ödeme ya da portal sayfası gerçekten açıldı: uygulamaya dönünce hak durumu beklemeden okunur (sayfa açılamadıysa
    /// boşuna yoklama başlamasın).
    private func markAwaitingBillingReturn() {
        awaitingBillingReturn = true
    }
    #endif

    // MARK: Toplantı

    /// Kayıt başında kaydın sunucu oturumunu açar (deneme hakkı ya da abonelik süresi buradan düşer; `recordID` aynı
    /// kayıt için yinelenen başlatmanın aynı oturumu döndürmesini sağlar). Oturum açık kalırken kimliği saklanır (uygulama
    /// çökse de sonra kapatılır) ve kayıt oturuma bağlanır (son geçiş ve not o oturumla). Sunucuya ulaşılamazsa
    /// (bkz. `isOfflineStartError`) ve son bilinen hak durumu son 7 günde kayda izin verdiyse kayıt çevrimdışı sürer;
    /// yoksa ya da sunucu reddederse hata fırlar ve kayıt başlamaz.
    func startMeeting(recordID: String) async throws -> HostedMeetingStart {
        let client: HostedClient = try HostedServices.requireClient()
        // Ödeme sonrası eski "deneme" durumu DeviceCheck istemesin: deneme görünen hesapta durum önce tazelenir.
        if isKnownTrial {
            await refresh()
        }
        do {
            // Yerel kayıt yerleri (açık oturum listesi, kayıt–oturum bağları) oturum açılmadan denetlenir: açıldıktan sonra
            // yazılamasaydı izlenmeyen oturum deneme toplantısını ya da aylık süreyi boşa harcardı.
            let openDefaults: UserDefaults = try await signedInOpenMeetingsDefaults(client: client)
            _ = try loadHostedMeetingLinks()
            let started: HostedStartedMeeting = try await openServerMeeting(client: client, clientRef: recordID, deferred: false)
            do {
                try saveHostedMeetingLink(link: HostedMeetingLink(recordID: recordID, serverMeetingID: started.meetingId, createdAt: Date()))
            } catch {
                await abandonServerMeeting(client: client, meetingID: started.meetingId)
                throw error
            }
            currentMeeting = started
            isOfflineRecording = false
            addHostedOpenMeetingID(meetingID: started.meetingId, defaults: openDefaults)
            accountLogger.info("Toplantı oturumu açıldı, en çok dakika: \(started.maxDurationMinutes, privacy: .public)")
            Task { await refresh() }
            return .online(started)
        } catch where isOfflineStartError(error: error) {
            let userID: String? = try await client.signedInUserID()
            guard let minutes = hostedOfflineRecordingMinutes(permit: loadHostedOfflinePermit(), userId: userID, now: Date(), maxAgeSec: hostedOfflinePermitMaxAgeSec) else {
                accountLogger.warning("Sunucuya ulaşılamadı; son hak durumu eski ya da izin vermiyor, kayıt başlatılmadı")
                throw HostedClientError.offlineNotAllowed
            }
            if let userID {
                saveHostedRecordOwner(recordID: recordID, userId: userID)
            }
            // Canlı istekler önceki toplantının bütçesine yazılmasın.
            await client.clearCurrentMeeting()
            currentMeeting = nil
            isOfflineRecording = true
            accountLogger.info("Sunucuya ulaşılamadı, kayıt çevrimdışı başlıyor, en çok dakika: \(minutes, privacy: .public)")
            return .offline(maxMinutes: minutes)
        }
    }

    /// Açılan ama bu Mac'te kayda bağlanamayan sunucu oturumunu kapatır (deneme ya da aylık süre boşa akmasın).
    /// Kapatılamazsa uyarı loglanır; sunucu onu sonraki canlı başlatmada kapatır. Asıl hata çağırana döner.
    private func abandonServerMeeting(client: HostedClient, meetingID: String) async {
        await client.clearCurrentMeeting()
        do {
            _ = try await client.endMeeting(meetingID: meetingID)
            accountLogger.info("Kayda bağlanamayan toplantı oturumu kapatıldı")
        } catch {
            accountLogger.warning("Kayda bağlanamayan toplantı oturumu kapatılamadı, hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Sunucuda oturum açar. App Attest destekleniyorsa onay eklenir. Apple DeviceCheck jetonu yalnızca hesabın deneme
    /// olduğu biliniyorsa gönderilir; sunucu `device_check_required` derse bir kez jetonla yinelenir (aboneler
    /// DeviceCheck'e hiç takılmaz). Jeton üretilemezse hata fırlar.
    /// `deferred`: sonradan işlenen kayıt (bekleyen, içe aktarılan); sunucu süren canlı toplantıyı kapatmaz.
    /// Sunucu bu Mac'te denemeyi reddederse (`trial_device_used`) bu hesap için hatırlanır ve hak durumu yenilenir: kenar
    /// çubuğu, Hesap kartı ve Başlat düğmesi "denemen yok, abone ol" der; Başlat bir daha sunucuya gitmez.
    private func openServerMeeting(client: HostedClient, clientRef: String, deferred: Bool) async throws -> HostedStartedMeeting {
        do {
            return try await requestServerMeeting(client: client, clientRef: clientRef, deferred: deferred)
        } catch let error as HostedAPIError where error.code == .trialDeviceUsed {
            if let userID = try await client.signedInUserID() {
                UserDefaults.standard.set(Date(), forKey: hostedTrialRefusedKey(userId: userID))
                accountLogger.info("Deneme bu Mac'te reddedildi (Mac denemesini başka hesapla kullandı); hesap için hatırlandı")
                Task { await refresh() }
            }
            throw error
        }
    }

    /// Toplantı oturumu isteği; sunucu DeviceCheck isterse jetonla bir kez yinelenir.
    private func requestServerMeeting(client: HostedClient, clientRef: String, deferred: Bool) async throws -> HostedStartedMeeting {
        let device: HostedDeviceAssertion? = await HostedDeviceAttestation.assertion(client: client, action: "meetings.start")
        // Jeton yalnızca bilinen denemede ve üretilebilirse gönderilir: Apple'a ulaşılamazsa ya da Mac desteklemiyorsa jetonsuz
        // denenir (denemenin 2. ve 3. toplantısı jeton istemez); sunucu isterse aşağıda jetonla yinelenir ve o zaman hata
        // kullanıcıya gösterilir.
        let deviceCheckToken: String?
        if isKnownTrial {
            do {
                deviceCheckToken = try await HostedDeviceCheck.token()
            } catch {
                accountLogger.warning("DeviceCheck jetonu üretilemedi, jetonsuz deneniyor, hata: \(String(describing: error), privacy: .private)")
                deviceCheckToken = nil
            }
        } else {
            deviceCheckToken = nil
        }
        do {
            return try await client.startMeeting(device: device, deviceCheckToken: deviceCheckToken, clientRef: clientRef, deferred: deferred)
        } catch let error as HostedAPIError where error.code == .deviceCheckRequired && deviceCheckToken == nil {
            accountLogger.info("Sunucu DeviceCheck istedi, jetonla bir kez yeniden deneniyor")
            // App Attest meydan okuması tek kullanımlık: yeniden denemede yeni onay.
            let retryDevice: HostedDeviceAssertion? = await HostedDeviceAttestation.assertion(client: client, action: "meetings.start")
            return try await client.startMeeting(device: retryDevice, deviceCheckToken: try await HostedDeviceCheck.token(), clientRef: clientRef, deferred: deferred)
        }
    }

    /// Kayıt bitince toplantı oturumunu kapatır; not ve son geçiş sunucunun ek süresinde aynı toplantıyla sürer.
    /// Kapatılamazsa oturum kimliği saklı kalır, ağ gelince ya da sonraki açılışta yeniden denenir (aylık süre boşuna
    /// akmasın). Her durumda hak durumu yenilenir (göstergeler güncel kalsın).
    func endMeeting(meetingID: String?) async throws {
        isOfflineRecording = false
        guard let meetingID else {
            return
        }
        defer { Task { await refresh() } }
        let client: HostedClient = try HostedServices.requireClient()
        do {
            let ended: HostedEndedMeeting = try await client.endMeeting(meetingID: meetingID)
            removeHostedOpenMeetingID(meetingID: meetingID, defaults: try await signedInOpenMeetingsDefaults(client: client))
            accountLogger.info("Toplantı oturumu kapandı, dakika: \(ended.minutes ?? 0, privacy: .public)")
        } catch {
            // Kapatılamadı: kimlik açık oturumlar listesinde kalır, yetim kapatma (ağ gelince, öne gelince, açılışta)
            // kapatır. "Şimdiki toplantı" yine bırakılır; yoksa yetim sayılmaz ve aylık süre en çok süreye kadar akardı.
            if shouldClearCurrentMeeting(currentMeetingID: currentMeeting?.meetingId, endedMeetingID: meetingID) {
                currentMeeting = nil
            }
            throw error
        }
        // Bu arada yeni kayıt başladıysa onun oturumuna dokunulmaz.
        if shouldClearCurrentMeeting(currentMeetingID: currentMeeting?.meetingId, endedMeetingID: meetingID) {
            currentMeeting = nil
        }
    }

    /// Oturumdaki hesabın kapatılamamış sunucu oturumlarını (uygulama çöktü, kapatma isteği başarısız oldu) kapatır; o
    /// oturumla kayıt sürüyorsa dokunmaz. Sunucu oturumu zaten kapalı ya da bilinmiyorsa kayıt silinir; ağ hatasında
    /// sonra yeniden denenir. Oturum yoksa bir şey yapmaz (başka hesapların listesi o hesap girince kapatılır).
    func closeOrphanedMeeting() async {
        let client: HostedClient
        let defaults: UserDefaults
        do {
            client = try HostedServices.requireClient()
            guard let userID = try await client.signedInUserID() else {
                return
            }
            defaults = try hostedOpenMeetingsDefaults(userID: userID)
        } catch {
            accountLogger.warning("Açık kalan toplantı oturumları okunamadı, sonra yeniden denenecek, hata: \(String(describing: error), privacy: .private)")
            return
        }
        migrateLegacyHostedOpenMeetingIDs(defaults: defaults)
        for meetingID in orphanedMeetingIDs(openIDs: loadHostedOpenMeetingIDs(defaults: defaults), recordingMeetingID: currentMeeting?.meetingId) {
            do {
                let ended: HostedEndedMeeting = try await client.endMeeting(meetingID: meetingID)
                removeHostedOpenMeetingID(meetingID: meetingID, defaults: defaults)
                accountLogger.info("Açık kalan toplantı oturumu kapatıldı, dakika: \(ended.minutes ?? 0, privacy: .public)")
            } catch let error as HostedAPIError where !isRetryableHostedError(error: error) {
                removeHostedOpenMeetingID(meetingID: meetingID, defaults: defaults)
                accountLogger.warning("Açık kalan toplantı oturumu sunucuda yok ya da kapalı, kod: \(error.rawCode, privacy: .public)")
            } catch {
                accountLogger.warning("Açık kalan toplantı oturumu kapatılamadı, sonra yeniden denenecek, hata: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Bekleyen kaydın (çevrimdışı kaydedilmiş ya da içe aktarılmış) sunucu oturumunu hazırlar. Kayıt daha önce bir oturuma bağlandıysa o kullanılır;
    /// yoksa oturum "ertelenmiş" açılır (sunucu hakları denetler, süren canlı kaydın oturumunu kapatmaz; `clientRef`
    /// yinelenen denemenin ikinci oturum açmasını önler), kayda bağlanır ve hemen kapatılır: toplantı süresi sayılmaz,
    /// aylık kullanıma sesin gerçek süresi yazılır (son geçiş); not ve son geçiş sunucunun işleme süresinde (24 saat) bu
    /// oturumla üretilir. Bağlı oturum kapandıysa (önceki deneme yarıda kaldı) son geçiş ve not oturumu `meeting_not_active`
    /// alınca yeniden işleme için açar (bkz. `HostedFinalTranscriber`, `withRecordedMeetingReopen`).
    func prepareQueuedMeeting(recordID: String) async -> HostedQueuedMeetingPreparation {
        if case .signedIn(let entitlements) = state, hostedStartBlock(entitlements: entitlements) != nil, hostedServerMeetingIDOrNil(recordID: recordID) == nil {
            return .blocked(reason: queuedBlockReason(entitlements: entitlements))
        }
        do {
            let client: HostedClient = try HostedServices.requireClient()
            if let linked = hostedServerMeetingIDOrNil(recordID: recordID) {
                do {
                    _ = try await client.endMeeting(meetingID: linked)
                    accountLogger.info("Bekleyen kaydın bağlı sunucu oturumu hazır")
                    Task { await refresh() }
                    return .ready(serverMeetingID: linked)
                } catch let error as HostedAPIError where error.code == .notFound {
                    // Oturum sunucuda yok (temizlendi ya da başka hesabındı): bağ silinir, kayıt yeni oturum açar.
                    accountLogger.warning("Bekleyen kaydın bağlı oturumu sunucuda yok, bağ silindi")
                    try removeHostedMeetingLink(recordID: recordID)
                }
            }
            let started: HostedStartedMeeting = try await openServerMeeting(client: client, clientRef: recordID, deferred: true)
            let serverMeetingID: String = started.meetingId
            try saveHostedMeetingLink(link: HostedMeetingLink(recordID: recordID, serverMeetingID: serverMeetingID, createdAt: Date()))
            _ = try await client.endMeeting(meetingID: serverMeetingID)
            accountLogger.info("Çevrimdışı kaydın sunucu oturumu hazır")
            Task { await refresh() }
            return .ready(serverMeetingID: serverMeetingID)
        } catch where isOfflineStartError(error: error) {
            return .waitingForNetwork
        } catch {
            accountLogger.warning("Çevrimdışı kayıt sunucuda işlenemiyor, hata: \(String(describing: error), privacy: .private)")
            return .rejected(reason: userFacingMessage(error: error))
        }
    }

    /// İçe aktarılan kaydı oturumdaki kullanıcıya yazar (kuyruğa alınırken); oturum yoksa `notSignedIn`.
    func claimQueuedRecord(recordID: String) async throws {
        guard let userID = try await HostedServices.requireClient().signedInUserID() else {
            throw HostedClientError.notSignedIn
        }
        saveHostedRecordOwner(recordID: recordID, userId: userID)
    }

    /// Oturumdaki kullanıcı (Anahtar Zinciri'nden, ağsız); oturum yoksa nil.
    func signedInUserID() async throws -> String? {
        try await HostedServices.requireClient().signedInUserID()
    }

    /// Bekleyen kaydın şimdilik işlenememe nedeni (hak durumundan).
    private func queuedBlockReason(entitlements: HostedEntitlements) -> String {
        #if os(iOS)
        // iPhone'da abone olma önerilmez (App Store 3.1.1): yalnızca durum ve ne zaman kendiliğinden işleneceği.
        switch hostedStartBlock(entitlements: entitlements) {
        case .trialEnded, .subscriptionEnded, .paymentOverdue:
            return String(localized: "Hesabında etkin bir plan olmadığı için bu toplantı işlenemedi. Ses bu iPhone'da kalır; plan etkinleşince kendiliğinden işlenir.")
        case .monthlyCapReached:
            return String(localized: "Bu ayki kullanım sınırın dolduğu için bu toplantı işlenemedi. Ses bu iPhone'da kalır; sınır sıfırlanınca kendiliğinden işlenir.")
        case .none:
            return String(localized: "Bu toplantı şimdilik işlenemedi; kendiliğinden yeniden denenecek.")
        }
        #else
        return switch hostedStartBlock(entitlements: entitlements) {
        case .trialEnded:
            String(localized: "Ücretsiz denemen bittiği için bu toplantı işlenemedi. Ses bu Mac'te kalır; abone olunca kendiliğinden işlenir.")
        case .monthlyCapReached:
            String(localized: "Bu ayki kullanım sınırın dolduğu için bu toplantı işlenemedi. Ses bu Mac'te kalır; sınır sıfırlanınca kendiliğinden işlenir.")
        case .subscriptionEnded:
            String(localized: "Aboneliğin sona erdiği için bu toplantı işlenemedi. Ses bu Mac'te kalır; yeniden abone olunca kendiliğinden işlenir.")
        case .paymentOverdue:
            String(localized: "Ödeme alınamadığı için bu toplantı işlenemedi. Ses bu Mac'te kalır; kartını \"Hesabı yönet\"ten güncelleyince kendiliğinden işlenir.")
        case .none:
            String(localized: "Bu toplantı şimdilik işlenemedi; kendiliğinden yeniden denenecek.")
        }
        #endif
    }

    /// İşlemi çalıştırır, sonra durumu yeniler; hata kullanıcıya gösterilir.
    private func perform(operation: @escaping @Sendable (HostedClient) async throws -> Void) async {
        errorMessage = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation(try HostedServices.requireClient())
        } catch {
            accountLogger.error("Hesap işlemi başarısız, hata: \(String(describing: error), privacy: .private)")
            errorMessage = userFacingMessage(error: error)
        }
        await refresh()
    }
}

/// İlk hesap okuması süresinde bitmedi (bkz. `reportOverdueLoad`): kullanıcıya gösterilen metin.
private func hostedAccountLoadTimeoutMessage() -> String {
    String(localized: "Sunucu \(Int(hostedAccountLoadDeadlineSec)) saniyede yanıt vermedi.")
}

/// Çıkış sunucuya iletilemedi ama bu cihazda yapıldı: kullanıcıya gösterilen metin.
private func hostedLocalSignOutMessage() -> String {
    #if os(macOS)
    String(localized: "Bu Mac'te çıkış yapıldı. Sunucuya ulaşılamadı; sunucudaki oturum en geç 60 gün içinde kendiliğinden kapanır.")
    #else
    String(localized: "Bu iPhone'da çıkış yapıldı. Sunucuya ulaşılamadı; sunucudaki oturum en geç 60 gün içinde kendiliğinden kapanır.")
    #endif
}

/// İlk açılış hunisinin adımını arka planda bildirir; giriş ve arayüz beklemez (bkz. `HostedTelemetryCenter.send`).
private func reportHostedFunnel(step: HostedFunnelStep) {
    Task { @MainActor in await HostedTelemetryCenter.shared.send(funnel: step) }
}

/// Kayıt başında sunucu oturumunun sonucu.
enum HostedMeetingStart {
    /// Sunucu oturumu açıldı.
    case online(HostedStartedMeeting)
    /// Sunucuya ulaşılamadı; kayıt çevrimdışı, en çok bu kadar dakika (son bilinen hak durumundan).
    case offline(maxMinutes: Int)
}

/// Açık (kapatılamamış) sunucu oturumlarının anahtarı (uygulama çökse de sonra kapatılır). Liste oturumu açan hesabın
/// ayar alanındadır (bkz. `hostedOpenMeetingsDefaults`); önceki sürümlerde ortak ayarlardaydı.
private let hostedOpenMeetingsKey: String = "hosted.openMeetingIDs"
/// Çevrimdışı kayıt izninin UserDefaults anahtarı.
private let hostedOfflinePermitKey: String = "hosted.offlinePermit"

/// 0.1.4'ün tek açık oturum anahtarı: yeni listeye taşınır (bkz. `migrateLegacyHostedOpenMeetingIDs`).
private let legacyHostedOpenMeetingKey: String = "hosted.openMeetingID"

/// Hesabın açık sunucu oturumlarının tutulduğu ayar alanı (bkz. `hostedAccountDefaults`). Liste hesap başınadır:
/// başka bir hesapla giriş yapılınca önceki hesabın oturumları yeni hesabın jetonuyla kapatılmaya çalışılıp (sunucu
/// bulamaz) listeden düşmez; o hesap yeniden girince kapatılır.
private func hostedOpenMeetingsDefaults(userID: String) throws -> UserDefaults {
    try hostedAccountDefaults(accountKey: accountDataKey(userId: userID))
}

/// Önceki sürümlerin ortak ayarlardaki açık oturumlarını (liste ve 0.1.4'ün tek kaydı) oturumdaki hesabın listesine
/// katar ve eskilerini siler (yetim kapatma sonra kapatır). Başka bir hesabın oturumuysa sunucu bulamaz ve yetim kapatma
/// onu listeden siler (önceki davranış).
private func migrateLegacyHostedOpenMeetingIDs(defaults: UserDefaults) {
    let shared: [String] = UserDefaults.standard.stringArray(forKey: hostedOpenMeetingsKey) ?? []
    let legacy: String? = UserDefaults.standard.string(forKey: legacyHostedOpenMeetingKey)
    guard !shared.isEmpty || legacy != nil else {
        return
    }
    let merged: [String] = shared.reduce(loadHostedOpenMeetingIDs(defaults: defaults)) { (ids: [String], meetingID: String) -> [String] in
        addingOpenMeeting(ids: ids, meetingID: meetingID)
    }
    defaults.set(mergingLegacyOpenMeeting(ids: merged, legacy: legacy), forKey: hostedOpenMeetingsKey)
    UserDefaults.standard.removeObject(forKey: hostedOpenMeetingsKey)
    UserDefaults.standard.removeObject(forKey: legacyHostedOpenMeetingKey)
    accountLogger.info("Önceki sürümden kalan açık toplantı oturumları hesabın listesine taşındı, sayı: \(shared.count + (legacy == nil ? 0 : 1), privacy: .public)")
}

/// Hesabın saklanan açık sunucu oturumları (yoksa boş).
private func loadHostedOpenMeetingIDs(defaults: UserDefaults) -> [String] {
    defaults.stringArray(forKey: hostedOpenMeetingsKey) ?? []
}

/// Açık sunucu oturumunu hesabın listesine ekler.
private func addHostedOpenMeetingID(meetingID: String, defaults: UserDefaults) {
    defaults.set(addingOpenMeeting(ids: loadHostedOpenMeetingIDs(defaults: defaults), meetingID: meetingID), forKey: hostedOpenMeetingsKey)
}

/// Kapatılan oturumu hesabın listesinden çıkarır.
private func removeHostedOpenMeetingID(meetingID: String, defaults: UserDefaults) {
    defaults.set(removingOpenMeeting(ids: loadHostedOpenMeetingIDs(defaults: defaults), meetingID: meetingID), forKey: hostedOpenMeetingsKey)
}

private func clearHostedOpenMeetingIDs(defaults: UserDefaults) {
    defaults.removeObject(forKey: hostedOpenMeetingsKey)
}

/// Kaydın sunucu oturumu; bağ yoksa ya da bağlar okunamazsa nil (okunamazsa hata loglanır).
private func hostedServerMeetingIDOrNil(recordID: String) -> String? {
    do {
        return hostedServerMeetingID(recordID: recordID, links: try loadHostedMeetingLinks())
    } catch {
        accountLogger.error("Kayıt–oturum bağları okunamadı, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

/// Çevrimdışı kayıt iznini saklar (nil: izin yok, saklı olan silinir).
private func saveHostedOfflinePermit(permit: HostedOfflinePermit?) {
    guard let permit else {
        clearHostedOfflinePermit()
        return
    }
    do {
        UserDefaults.standard.set(try JSONEncoder().encode(permit), forKey: hostedOfflinePermitKey)
    } catch {
        accountLogger.error("Çevrimdışı kayıt izni saklanamadı, hata: \(String(describing: error), privacy: .private)")
    }
}

/// Saklanan çevrimdışı kayıt izni; yoksa ya da bozuksa nil (bozuksa hata loglanır, izin yok sayılır).
func loadHostedOfflinePermit() -> HostedOfflinePermit? {
    guard let data = UserDefaults.standard.data(forKey: hostedOfflinePermitKey) else {
        return nil
    }
    do {
        return try JSONDecoder().decode(HostedOfflinePermit.self, from: data)
    } catch {
        accountLogger.error("Çevrimdışı kayıt izni okunamadı, hata: \(String(describing: error), privacy: .private)")
        return nil
    }
}

private func clearHostedOfflinePermit() {
    UserDefaults.standard.removeObject(forKey: hostedOfflinePermitKey)
}

/// Uygulama kapanırken oturumdaki hesabın (`userID`; yoksa bir şey yapılmaz) açık sunucu oturumlarını kapatmayı dener
/// (en çok 3 sn bekler; olmazsa sonraki açılışta kapatılır).
@MainActor
private func endOpenMeetingBeforeQuit(userID: String?) {
    guard let userID else {
        return
    }
    let defaults: UserDefaults
    do {
        defaults = try hostedOpenMeetingsDefaults(userID: userID)
    } catch {
        accountLogger.error("Kapanışta açık oturum listesi okunamadı, hata: \(String(describing: error), privacy: .private)")
        return
    }
    let meetingIDs: [String] = loadHostedOpenMeetingIDs(defaults: defaults)
    guard !meetingIDs.isEmpty else {
        return
    }
    let client: HostedClient
    switch HostedServices.client {
    case .success(let value):
        client = value
    case .failure(let error):
        accountLogger.error("Kapanışta sunucu bağlantısı yok, hata: \(String(describing: error), privacy: .private)")
        return
    }
    let done: DispatchSemaphore = DispatchSemaphore(value: 0)
    Task.detached {
        for meetingID in meetingIDs {
            do {
                _ = try await client.endMeeting(meetingID: meetingID)
                // Ana aktöre geçilmez: ana iş parçacığı aşağıda bu görevi bekliyor (geçseydi kapanış her seferinde 3 sn
                // takılırdı); UserDefaults iş parçacığı güvenlidir.
                removeHostedOpenMeetingID(meetingID: meetingID, defaults: defaults)
            } catch {
                accountLogger.warning("Kapanışta toplantı oturumu kapatılamadı, sonraki açılışta denenecek, hata: \(String(describing: error), privacy: .private)")
            }
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 3)
}
