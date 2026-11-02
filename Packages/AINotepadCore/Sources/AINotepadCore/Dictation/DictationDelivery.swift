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

/// Yazılan metnin hedef uygulamaya nasıl ulaşacağı.
public enum DictationDelivery: Sendable, Equatable {
    /// Panoya yazılıp ⌘V ile yapıştırılır; pano sonra eski haline döner.
    case paste
    /// Erişilebilirlik izni yok: metin panoda kalır, kullanıcı kendisi yapıştırır.
    case copyOnly
    /// Odakta parola alanı var: ne yapıştırılır ne panoya yazılır.
    case refuse(DictationError)
}

/// Metnin teslim yolu. Saf fonksiyondur.
public func dictationDelivery(isAccessibilityTrusted: Bool, isSecureInputActive: Bool) -> DictationDelivery {
    if isSecureInputActive {
        return .refuse(.secureInputActive)
    }
    return isAccessibilityTrusted ? .paste : .copyOnly
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

/// Panodaki bir öğe: tüm türleriyle.
public struct PasteboardItemSnapshot: Sendable, Equatable {
    public let representations: [PasteboardRepresentation]

    public init(representations: [PasteboardRepresentation]) {
        self.representations = representations
    }
}

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
    /// Pano önceden boştu: dikte metni silinir.
    case clear
    /// Bu arada panoya başka bir şey kopyalandı: dokunulmaz.
    case keep
}

/// Yapıştırmadan sonra pano planı: dikte metni yazıldıktan sonra pano değiştiyse (sayaç farklı) kullanıcının yeni
/// kopyası korunur; değişmediyse eski içerik geri gelir. Saf fonksiyondur.
public func pasteboardRestore(snapshot: PasteboardSnapshot, writtenChangeCount: Int, currentChangeCount: Int) -> PasteboardRestore {
    guard currentChangeCount == writtenChangeCount else {
        return .keep
    }
    return snapshot.items.isEmpty ? .clear : .restore(snapshot.items)
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
