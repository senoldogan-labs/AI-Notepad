import Foundation

/// Geniş telefon ekranının (açılmış iPhone Duo'nun iç ekranı: dikeyde 669×951 pt, yan çevrilince 951×669 pt; iki boyutta
/// da "regular" boyut sınıfı) ölçüleri. Normal iPhone'lar (dikeyde hep "compact" genişlik) ve Duo'nun dış ekranı (466×678
/// pt, "compact") bu düzenlere hiç girmez: oralarda arayüz değişmeden tek sütundur.
public enum WideLayout {
    /// Yan yana düzene geçilen en dar genişlik (pt): 280 pt kenar sütunu ve en az 360 pt'lik içerik (iPhone mini'den
    /// biraz dar) sığar. Duo'da Split View'daki yarım pencere (~330 pt) "compact"tır, zaten girmez.
    public static let minimumWidth: Double = 640
    /// Kenar sütununun (ana ekran: toplantılar ve görevler) en dar ve en geniş hâli (pt).
    public static let sidebarMinimumWidth: Double = 280
    public static let sidebarMaximumWidth: Double = 380
    /// Kayıt ekranında canlı metnin yanındaki "Notlarım" sütununun en dar ve en geniş hâli (pt).
    public static let notesMinimumWidth: Double = 260
    public static let notesMaximumWidth: Double = 360
}

/// Ekran yan yana düzene uygun mu: yatay boyut sınıfı "regular" ve genişlik en az `WideLayout.minimumWidth`. Boyut
/// sınıfı tek başına yetmez (Duo'da iki uygulama yan yana açıkken pencere daralır); genişlik tek başına da yetmez (Pro Max
/// yan çevrilince "regular" olsa da uygulama yalnız dikeydir). Saf fonksiyondur.
public func usesWideLayout(isRegularWidth: Bool, width: Double) -> Bool {
    isRegularWidth && width >= WideLayout.minimumWidth
}

/// Kenar sütununun genişliği: pencerenin %42'si, `sidebarMinimumWidth`…`sidebarMaximumWidth` arasında (dikey Duo'da
/// ~281 pt, yan çevrilince 380 pt). Saf fonksiyondur.
public func wideSidebarWidth(containerWidth: Double) -> Double {
    min(max(containerWidth * 0.42, WideLayout.sidebarMinimumWidth), WideLayout.sidebarMaximumWidth)
}

/// Kayıt ekranındaki "Notlarım" sütununun genişliği: pencerenin %40'ı, `notesMinimumWidth`…`notesMaximumWidth` arasında;
/// canlı metne kalan pay hep daha geniştir. Saf fonksiyondur.
public func wideNotesColumnWidth(containerWidth: Double) -> Double {
    min(max(containerWidth * 0.4, WideLayout.notesMinimumWidth), WideLayout.notesMaximumWidth)
}
