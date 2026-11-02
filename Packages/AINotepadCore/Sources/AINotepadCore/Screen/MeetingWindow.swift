import Foundation

/// Ekrandaki bir pencerenin görüntü alma kararı için gereken bilgisi.
public struct ScreenWindowInfo: Sendable, Equatable {
    public let windowID: UInt32
    public let bundleID: String
    public let title: String
    public let width: Double
    public let height: Double
    /// Pencere katmanı: 0 normal pencere; menüler, paneller ve sistem öğeleri daha yüksek.
    public let layer: Int
    public let isOnScreen: Bool

    public init(windowID: UInt32, bundleID: String, title: String, width: Double, height: Double, layer: Int, isOnScreen: Bool) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
        self.layer = layer
        self.isOnScreen = isOnScreen
    }
}

/// Toplantı uygulamaları: pencerelerinden biri görüşmenin kendisidir (paylaşılan ekran orada görünür). Başlıkta aranan
/// sözcükler küçük harftir; boşsa uygulamanın her penceresi uyar.
private let meetingApps: [String: [String]] = [
    "us.zoom.xos": ["zoom meeting", "zoom webinar", "zoom-toplantı", "zoom-kokous"],
    "com.microsoft.teams2": ["meeting", "call", "toplantı", "arama", "kokous", "puhelu"],
    "com.microsoft.teams": ["meeting", "call", "toplantı", "arama", "kokous", "puhelu"],
    "com.cisco.webexmeetingsapp": [],
    "Cisco-Systems.Spark": ["meeting", "toplantı", "kokous"],
    "com.apple.FaceTime": [],
    "com.tinyspeck.slackmacgap": ["huddle"],
    "com.hnc.Discord": ["voice", "stage"],
]

/// Tarayıcılar: görüşme bir sekmedeyse pencere başlığı sekmenin başlığıdır.
private let browserBundleIDs: Set<String> = [
    "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac", "org.mozilla.firefox", "company.thebrowser.Browser",
    "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
]

/// Tarayıcı sekmesi başlığında görüşmeyi gösteren sözcükler (küçük harf).
private let browserMeetingTitles: [String] = ["meet -", "google meet", "meet.google.com", "zoom", "microsoft teams", "webex", "whereby", "jitsi"]

/// Görüşme penceresi en az bu boyutta olmalı (küçük kontrol pencereleri ve bildirimler atlanır).
private let meetingWindowMinWidth: Double = 400
private let meetingWindowMinHeight: Double = 300

/// Görüntüsü alınacak görüşme penceresi: ekranda, normal katmanda, yeterince büyük ve bir toplantı uygulamasının görüşme
/// penceresi ya da görüşme sekmesi açık bir tarayıcı penceresi; birden çok varsa en büyüğü. Hiçbiri yoksa nil (o zaman
/// ana ekranın tamamı alınır). Saf fonksiyondur.
public func meetingWindow(windows: [ScreenWindowInfo]) -> ScreenWindowInfo? {
    windows
        .filter { (window: ScreenWindowInfo) -> Bool in
            guard window.isOnScreen, window.layer == 0, window.width >= meetingWindowMinWidth, window.height >= meetingWindowMinHeight else {
                return false
            }
            let title: String = window.title.lowercased()
            if let words = meetingApps[window.bundleID] {
                return words.isEmpty ? true : words.contains { title.contains($0) }
            }
            return browserBundleIDs.contains(window.bundleID) && browserMeetingTitles.contains { title.contains($0) }
        }
        .max { (left: ScreenWindowInfo, right: ScreenWindowInfo) -> Bool in left.width * left.height < right.width * right.height }
}

/// Yakalanan görüntünün boyutu: kaynağın piksel boyutu uzun kenar `maxPixelSize`'ı geçmeyecek biçimde orantılı
/// küçültülür (büyütülmez); en az 1 piksel. Saf fonksiyondur.
public func screenCaptureSize(width: Double, height: Double, maxPixelSize: Int) -> (width: Int, height: Int) {
    let longest: Double = max(width, height)
    let scale: Double = longest > Double(maxPixelSize) ? Double(maxPixelSize) / longest : 1
    return (width: max(1, Int((width * scale).rounded())), height: max(1, Int((height * scale).rounded())))
}
