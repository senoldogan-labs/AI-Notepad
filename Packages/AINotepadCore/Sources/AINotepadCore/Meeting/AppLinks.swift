import Foundation

// Uygulamayı dışarıdan açan bağlantılar (Gistsmith, Mac ve iPhone): `gistsmith://` adres şeması (App Store'daki uygulama
// içi etkinlik, sitedeki "Gistsmith'te aç" düğmesi) ve evrensel bağlantılar (`https://gistsmith.com/m/<kimlik>`: yapay
// zekâ asistanının verdiği toplantı adresi; `https://gistsmith.com/open/<yol>`). Sitenin
// `web/public/.well-known/apple-app-site-association` dosyası evrensel bağlantının yollarını bu ayrıştırıcıyla aynı tutar.

/// Bağlantının uygulamada açtığı yer. Hiçbiri kendiliğinden iş başlatmaz: `record` kayıt ekranını açar, kaydı kullanıcı
/// başlatır.
public enum AppLinkRoute: Sendable, Equatable {
    /// Kayıt ekranı (iPhone: ana ekran, kayıt düğmesi; Mac: Ana sayfa), kayıt başlamaz.
    case record
    /// Toplantı sayfası (bağlantıdaki kimlik; bkz. `linkedMeetingID`).
    case meeting(String)
    /// Sor.
    case ask
    /// Görevlerim.
    case tasks
    /// İstatistikler.
    case insights
    /// Paylaşılan klasör daveti (`gistsmith://join#…`, `https://gistsmith.com/j#…`): katılma ekranı bağlantının tamamıyla
    /// açılır; sır yalnızca `#` parçasındadır, uygulama onu sunucuya göndermez (bkz. `sharedFolderInvite(text:)`).
    case joinSharedFolder(link: String)
}

/// Bağlantı adresinin sabitleri.
public enum AppLinkAddress {
    /// Uygulamanın adres şeması (`gistsmith://record`).
    public static let scheme: String = "gistsmith"
    /// Evrensel bağlantıların alan adı (Associated Domains: `applinks:gistsmith.com`).
    public static let universalHost: String = "gistsmith.com"
    /// Toplantı bağlantısının yolu (`/m/<kimlik>`; sunucuda `meetingUrl`).
    public static let meetingPathPrefix: String = "m"
    /// Diğer yerlerin evrensel bağlantı yolu (`/open/record`).
    public static let openPathPrefix: String = "open"
}

/// Adresin uygulamadaki yeri; tanınmayan, eksik ya da fazla parçalı adres için nil (yok sayılır). Kabul edilenler:
/// `gistsmith://record|ask|tasks|insights`, `gistsmith://meeting/<kimlik>`, `https://gistsmith.com/m/<kimlik>` ve
/// `https://gistsmith.com/open/<şemadaki yol>`. Kullanıcı adı, parola ya da kapı taşıyan adres reddedilir; sorgu ve `#`
/// parçası yok sayılır. Saf fonksiyondur.
public func appLinkRoute(url: URL) -> AppLinkRoute? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let scheme = components.scheme?.lowercased(),
          components.user == nil, components.password == nil, components.port == nil,
          let host = components.host?.lowercased(), !host.isEmpty
    else {
        return nil
    }
    let segments: [String] = pathSegments(percentEncodedPath: components.percentEncodedPath)
    if let invite = sharedFolderInviteRoute(url: url, scheme: scheme, host: host, segments: segments) {
        return invite
    }
    if scheme == AppLinkAddress.scheme {
        return appLinkRoute(segments: [host] + segments)
    }
    guard scheme == "https", host == AppLinkAddress.universalHost || host == "www.\(AppLinkAddress.universalHost)",
          let first = segments.first
    else {
        return nil
    }
    switch first {
    case AppLinkAddress.meetingPathPrefix:
        return segments.count == 2 ? validAppLinkMeetingID(value: segments[1]).map(AppLinkRoute.meeting) : nil
    case AppLinkAddress.openPathPrefix:
        return appLinkRoute(segments: Array(segments.dropFirst()))
    default:
        return nil
    }
}

/// Davet bağlantısı: `gistsmith://join#<davet>` ya da `https://gistsmith.com/j#<davet>`; davet parçası geçerli değilse nil
/// (yok sayılır). Saf fonksiyondur.
private func sharedFolderInviteRoute(url: URL, scheme: String, host: String, segments: [String]) -> AppLinkRoute? {
    let isAppLink: Bool = scheme == AppLinkAddress.scheme && host == "join" && segments.isEmpty
    let isWebLink: Bool = scheme == "https" && (host == AppLinkAddress.universalHost || host == "www.\(AppLinkAddress.universalHost)") && segments == ["j"]
    guard isAppLink || isWebLink else {
        return nil
    }
    do {
        _ = try sharedFolderInvite(text: url.absoluteString)
    } catch {
        return nil
    }
    return .joinSharedFolder(link: url.absoluteString)
}

/// Yolun boş olmayan parçaları (sondaki `/` yok sayılır). Kodlanmış parça çözülmez: `%2F` ile gizlenen eğik çizgi ya da
/// kimlikte izin verilmeyen karakter kimlik denetiminde reddedilir. Saf fonksiyondur.
private func pathSegments(percentEncodedPath: String) -> [String] {
    percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
}

/// Şemadaki yolun (`record`, `meeting/<kimlik>` …) yeri; parça sayısı tutmazsa nil. Saf fonksiyondur.
private func appLinkRoute(segments: [String]) -> AppLinkRoute? {
    guard let first = segments.first?.lowercased() else {
        return nil
    }
    if first == "meeting" {
        return segments.count == 2 ? validAppLinkMeetingID(value: segments[1]).map(AppLinkRoute.meeting) : nil
    }
    guard segments.count == 1 else {
        return nil
    }
    switch first {
    case "record":
        return .record
    case "ask":
        return .ask
    case "tasks":
        return .tasks
    case "insights":
        return .insights
    default:
        return nil
    }
}

/// Uygulamaların toplantı kimliği: kaydın oturum klasörünün adı (`20261105-103000`) ya da UUID; harf, rakam, `-` ve `_`,
/// harf ya da rakamla başlar, en çok 64 karakter (sunucudaki `normalizedMeetingId` ile aynı kural). Uymazsa nil. Saf
/// fonksiyondur.
public func validAppLinkMeetingID(value: String) -> String? {
    guard let first = value.unicodeScalars.first, value.unicodeScalars.count <= 64, isASCIIAlphanumeric(first) else {
        return nil
    }
    let isValid: Bool = value.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
        isASCIIAlphanumeric(scalar) || scalar == "-" || scalar == "_"
    }
    return isValid ? value : nil
}

/// ASCII harf ya da rakam. Saf fonksiyondur.
private func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
}

/// Bağlantıdaki kimliğin cihazdaki toplantısı: önce birebir, sonra UUID ise büyük-küçük harf gözetmeden (sunucu UUID'yi
/// küçük harfle saklar, uygulama büyük harfle üretmiş olabilir). Yoksa nil. Saf fonksiyondur.
public func linkedMeetingID(linkID: String, meetingIDs: [String]) -> String? {
    if meetingIDs.contains(linkID) {
        return linkID
    }
    guard UUID(uuidString: linkID) != nil else {
        return nil
    }
    return meetingIDs.first { (id: String) -> Bool in
        UUID(uuidString: id) != nil && id.caseInsensitiveCompare(linkID) == .orderedSame
    }
}
