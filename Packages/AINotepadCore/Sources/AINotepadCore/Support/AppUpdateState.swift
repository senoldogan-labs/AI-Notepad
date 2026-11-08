import Foundation

/// Kartta ve menüde gösterilen güncelleme: sürüm, sürüm notları ve indirilip kurulmaya hazır olup olmadığı.
public struct AvailableAppUpdate: Equatable, Sendable {
    /// Kullanıcıya görünen sürüm (ör. "0.1.6").
    public let version: String
    /// Appcast'e gömülü sürüm notları (Markdown); yoksa nil.
    public let releaseNotes: String?
    /// Sürüm notlarının sayfası (güncelleme kartındaki "Tüm notlar" bunu açar); yoksa nil.
    public let releaseNotesURL: URL?
    /// İndirildi; uygulama yeniden başlatılınca (ya da çıkışta) kurulur.
    public let isReadyToInstall: Bool

    public init(version: String, releaseNotes: String?, releaseNotesURL: URL?, isReadyToInstall: Bool) {
        self.version = version
        self.releaseNotes = releaseNotes
        self.releaseNotesURL = releaseNotesURL
        self.isReadyToInstall = isReadyToInstall
    }
}

/// Mac güncelleyicisinin durumu. Sparkle'ın kurma blokları (hemen kur, ertelenen yeniden başlatma) bağlantıda bu
/// durumların yanında tutulur: `ready` dışında hemen kurma bloğu, `relaunchPostponed` dışında ertelenen blok yoktur.
public enum AppUpdateState: Equatable, Sendable {
    /// Bekleyen güncelleme yok.
    case idle
    /// Bulundu, indirilmedi (otomatik indirme kapalı ya da önceki oturumda indirilmiş ama kurma bloğu yok).
    case found(AvailableAppUpdate)
    /// İndirildi; çıkışta ya da karttaki düğmeyle kurulur.
    case ready(AvailableAppUpdate)
    /// Kurulum başladı (hemen kurma bloğu çağrıldı ya da ertelenen yeniden başlatma sürdü); uygulama kapanacak.
    case installing(AvailableAppUpdate?)
    /// Kayıt ya da işleme sürdüğü için yeniden başlatma bekliyor.
    case relaunchPostponed(AvailableAppUpdate?)
}

/// Güncelleyiciye gelen olaylar (Sparkle temsilcisinden ve karttan).
public enum AppUpdateEvent: Equatable, Sendable {
    /// Zamanlanmış denetim bir güncelleme buldu.
    case found(AvailableAppUpdate)
    /// Sparkle'ın güncelleme oturumu bitti (kullanıcı ilgilendi ya da oturum kapandı).
    case sessionFinished
    /// Güncelleme indirildi, hemen kurma bloğu geldi.
    case downloaded(AvailableAppUpdate)
    /// Hemen kurma bloğu çağrıldı.
    case installStarted
    /// Sparkle yeniden başlatmayı erteledi (kayıt ya da işleme sürüyor).
    case relaunchPostponed
    /// Ertelenen yeniden başlatma sürdürüldü.
    case relaunchResumed
}

/// Güncelleyicinin sonraki durumu. İndirilmiş güncelleme, sonradan gelen "bulundu" ya da oturum sonu yüzünden kaybolmaz
/// (çıkışta kurulmaya devam eder); hemen kurma bloğu bir kez kullanılır (`installing`'e geçer); kurulum ya da ertelenmiş yeniden başlatma sürerken yeni "bulundu" yok sayılır. Saf
/// fonksiyondur.
public func appUpdateTransition(state: AppUpdateState, event: AppUpdateEvent) -> AppUpdateState {
    switch (state, event) {
    case (.idle, .found(let update)), (.found, .found(let update)):
        return .found(update)
    case (.found, .sessionFinished), (.installing, .sessionFinished):
        // Kurulum sürerken oturumun bitmesi kurulumun yarıda kaldığı demektir (başarılı kurulum uygulamayı kapatır).
        return .idle
    case (.idle, .downloaded(let update)), (.found, .downloaded(let update)), (.ready, .downloaded(let update)):
        return .ready(update)
    case (.ready(let update), .installStarted):
        return .installing(update)
    case (.relaunchPostponed(let update), .relaunchResumed):
        return .installing(update)
    case (_, .relaunchPostponed):
        return .relaunchPostponed(state.update)
    default:
        return state
    }
}

extension AppUpdateState {
    /// Kartta ve menüde gösterilecek güncelleme; yoksa nil.
    public var update: AvailableAppUpdate? {
        switch self {
        case .idle:
            return nil
        case .found(let update), .ready(let update):
            return update
        case .installing(let update), .relaunchPostponed(let update):
            return update
        }
    }

    /// Yeniden başlatma, kayıt ya da işleme bitince yapılacak.
    public var isRelaunchPostponed: Bool {
        if case .relaunchPostponed = self {
            return true
        }
        return false
    }
}
