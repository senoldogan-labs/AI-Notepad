import Foundation

/// Sesle yazmanın hataları.
public enum DictationError: Error, Equatable {
    /// Abonelik sürümünde oturum yok.
    case signInRequired
    /// Toplantı kaydı sürüyor (mikrofon toplantıda).
    case meetingInProgress
    /// Odaktaki alan güvenli giriş (parola alanı): yapıştırılmaz.
    case secureInputActive
    /// Cihaz içi dikte bu dili (ana toplantı dili) desteklemiyor.
    case unsupportedLanguage(MeetingLanguage)
    /// Konuşma duyulmadı (ses çok kısa ya da sessiz).
    case noSpeech
    /// ⌘V klavye olayı oluşturulamadı.
    case pasteEventFailed
}

/// Dikte başlatılamaz mı: oturum yoksa giriş, toplantı kaydı sürüyorsa kayıt, odakta parola alanı varsa güvenli giriş
/// nedeniyle; başlatılabiliyorsa nil. Sıra: önce giriş, sonra kayıt, sonra güvenli giriş. Saf fonksiyondur.
public func dictationStartRefusal(isSignedIn: Bool, isMeetingActive: Bool, isSecureInputActive: Bool) -> DictationError? {
    if !isSignedIn {
        return .signInRequired
    }
    if isMeetingActive {
        return .meetingInProgress
    }
    if isSecureInputActive {
        return .secureInputActive
    }
    return nil
}

/// Odaktaki öğe (Erişilebilirlik): metin yazılabilir mi.
public enum DictationFocus: Sendable, Equatable {
    /// Metin alanı (alan, metin kutusu, arama, düzenlenebilir web içeriği): ⌘V buraya gider.
    case textInput
    /// Odakta açıkça metin almayan bir öğe (liste, tablo, düğme; ör. Finder'ın dosya listesi): ⌘V metni kaybeder.
    case notTextInput
    /// Okunamadı, odak bildirilmedi ya da kap/bilinmeyen rol: Electron ve Chromium uygulamaları (Slack, Teams, VS Code)
    /// erişilebilirlik ağacını çoğu zaman göstermez, odaktaki yazı alanı pencere ya da grup görünür; yapıştırmak denenir.
    case unknown
}

/// Metin alan rolleri (AXRole).
private let dictationTextRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
/// Metin almadığı açıkça bilinen roller: ⌘V'yi yutar ya da başka bir şey yapar. Kap roller (grup, pencere, kaydırma
/// alanı, uygulama) burada değildir: içlerinde gösterilmeyen bir yazı alanı olabilir.
private let dictationNonTextRoles: Set<String> = [
    "AXList", "AXOutline", "AXTable", "AXBrowser", "AXButton", "AXImage", "AXMenu", "AXMenuBar", "AXMenuItem",
    "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXSlider",
]

/// Odaktaki öğenin rolünden metin alıp almadığı: seçili metin aralığı olan öğe (metin imleci var) her zaman alır; rol
/// bilinen metin rolüyse alır, metin almadığı açıkça bilinen rolse almaz; rol yoksa ya da başka bir rolse bilinmez
/// (yapıştırmak denenir). Saf fonksiyondur.
public func dictationFocus(role: String?, hasSelectedTextRange: Bool) -> DictationFocus {
    if hasSelectedTextRange {
        return .textInput
    }
    guard let role else {
        return .unknown
    }
    if dictationTextRoles.contains(role) {
        return .textInput
    }
    return dictationNonTextRoles.contains(role) ? .notTextInput : .unknown
}

/// Yazılan metnin hedef uygulamaya nasıl ulaşacağı.
public enum DictationDelivery: Sendable, Equatable {
    /// Panoya yazılıp ⌘V ile yapıştırılır; pano sonra eski haline döner.
    case paste
    /// Erişilebilirlik izni yok: metin panoda kalır, kullanıcı kendisi yapıştırır.
    case copyOnly
    /// Odakta yazı alanı yok: metin panoda kalır (⌘V boşa gidip pano geri yüklenince metin kaybolurdu).
    case copyNoTextField
    /// Odakta parola alanı var: ne yapıştırılır ne panoya yazılır.
    case refuse(DictationError)
}

/// Metnin teslim yolu. Odak yalnız Erişilebilirlik izniyle okunur; izin yoksa kopyalanır. Saf fonksiyondur.
public func dictationDelivery(isAccessibilityTrusted: Bool, isSecureInputActive: Bool, focus: DictationFocus) -> DictationDelivery {
    if isSecureInputActive {
        return .refuse(.secureInputActive)
    }
    guard isAccessibilityTrusted else {
        return .copyOnly
    }
    return focus == .notTextInput ? .copyNoTextField : .paste
}

/// Yapıştırılacak metin: baştaki ve sondaki boşluklar atılır, satır içindeki art arda boşluklar teke iner (satır sonları
/// kalır). Metin kalmazsa nil. (WhisperKit'in sessizlikte uydurduğu ifadeler motorda atılır; dikte edilen "Thank you"
/// burada silinmez.) Saf fonksiyondur.
public func dictationInsertText(raw: String) -> String? {
    let lines: [String] = raw
        .components(separatedBy: .newlines)
        .map { (line: String) -> String in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
    let text: String = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// Panodaki bir öğenin tek bir türdeki verisi (ör. `public.utf8-plain-text`).
public struct PasteboardRepresentation: Sendable, Equatable {
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// Panodaki bir öğe: tüm türleriyle. `types` öğenin bildirdiği bütün türlerdir (verisi okunamayan işaret türleri
/// dahil); `representations` verisi okunanlardır.
public struct PasteboardItemSnapshot: Sendable, Equatable {
    public let types: [String]
    public let representations: [PasteboardRepresentation]

    public init(types: [String], representations: [PasteboardRepresentation]) {
        self.types = types
        self.representations = representations
    }
}

/// Başka bir uygulamanın geri yazılmamasını istediği içeriğin işaretleri (nspasteboard.org): gizli (parola
/// yöneticisinin kopyaladığı parola), geçici ve kendiliğinden üretilmiş içerik.
public let protectedPasteboardTypes: Set<String> = [
    "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
]

/// Yapıştırmadan önce panonun içeriği.
public struct PasteboardSnapshot: Sendable, Equatable {
    public let items: [PasteboardItemSnapshot]

    public init(items: [PasteboardItemSnapshot]) {
        self.items = items
    }
}

/// Yapıştırmadan sonra panoya ne yapılacağı.
public enum PasteboardRestore: Sendable, Equatable {
    /// Eski öğeler geri yazılır.
    case restore([PasteboardItemSnapshot])
    /// Pano önceden boştu ya da eski içerik geri yazılmamalı (gizli, geçici): dikte metni silinir.
    case clear
    /// Bu arada panoya başka bir şey kopyalandı: dokunulmaz.
    case keep
}

/// Yapıştırmadan sonra pano planı: dikte metni yazıldıktan sonra pano değiştiyse (sayaç farklı) kullanıcının yeni
/// kopyası korunur; değişmediyse eski içerik geri gelir. Eski içerikte gizli, geçici ya da kendiliğinden üretilmiş
/// işaretli bir öğe varsa (`protectedPasteboardTypes`; ör. parola yöneticisinin kopyaladığı parola) geri yazılmaz, pano
/// temizlenir: yeni sayaçla yeniden yayımlanan parola, yöneticinin "sayaç değişmediyse temizle" zamanlayıcısını atlatıp
/// panoda kalırdı. Saf fonksiyondur.
public func pasteboardRestore(snapshot: PasteboardSnapshot, writtenChangeCount: Int, currentChangeCount: Int) -> PasteboardRestore {
    guard currentChangeCount == writtenChangeCount else {
        return .keep
    }
    let isProtected: Bool = snapshot.items.contains { (item: PasteboardItemSnapshot) -> Bool in
        item.types.contains { protectedPasteboardTypes.contains($0) }
    }
    return snapshot.items.isEmpty || isProtected ? .clear : .restore(snapshot.items)
}

/// Hatanın kullanıcıya gösterilen açıklaması. Saf fonksiyondur.
func dictationMessage(error: DictationError) -> String {
    switch error {
    case .signInRequired:
        String(localized: "Sesle yazma için giriş yap.")
    case .meetingInProgress:
        String(localized: "Toplantı kaydı sürüyor; mikrofon toplantıda. Kayıt bitince sesle yazabilirsin.")
    case .secureInputActive:
        String(localized: "Parola alanına sesle yazılmaz.")
    case .unsupportedLanguage(let language):
        String(localized: "Bu Mac'teki cihaz içi dikte ana toplantı dilini (\(meetingLanguageName(language: language))) desteklemiyor. Ayarlar › Genel'den başka bir ana toplantı dili seç.")
    case .noSpeech:
        String(localized: "Konuşma duyulmadı.")
    case .pasteEventFailed:
        String(localized: "Metin yapıştırılamadı; panoya kopyalandı, ⌘V ile yapıştırabilirsin.")
    }
}
