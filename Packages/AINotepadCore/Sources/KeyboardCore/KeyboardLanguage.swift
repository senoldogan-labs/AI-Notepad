import Foundation

/// Klavyenin yazma dilleri: Latin alfabeli düzenler (Japonca, Korece, Çince yazma 0.2.4'te; sesle yazma o dillerde de
/// çalışır). Ham değer BCP 47 dil kodudur; `UITextChecker` dili ve dikte dili bundan türetilir.
public enum KeyboardLanguage: String, Sendable, Hashable, Codable, CaseIterable {
    case english = "en"
    case turkish = "tr"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portuguese = "pt"
    case dutch = "nl"
    case swedish = "sv"
    case finnish = "fi"
    case norwegian = "nb"
    case danish = "da"

    /// Büyük/küçük harf dönüşümünün yerel ayarı (Türkçede i → İ, ı → I).
    public var casingLocale: Locale {
        Locale(identifier: rawValue)
    }

    /// Dilin kendi adıyla gösterimi (ör. "Türkçe"); boşluk tuşunda ve ayarlarda.
    public var endonym: String {
        let locale: Locale = Locale(identifier: rawValue)
        let name: String = locale.localizedString(forLanguageCode: rawValue) ?? rawValue
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}

/// Cihaz dil listesinden (ör. `Locale.preferredLanguages`) klavye dillerinin ilk seçimi: tanınan diller sırasıyla,
/// en fazla üç; hiçbiri tanınmazsa İngilizce. Saf fonksiyondur.
public func defaultKeyboardLanguages(preferredLanguages: [String]) -> [KeyboardLanguage] {
    var result: [KeyboardLanguage] = []
    for identifier in preferredLanguages {
        guard let language = keyboardLanguage(identifier: identifier), !result.contains(language) else {
            continue
        }
        result.append(language)
        if result.count == 3 {
            break
        }
    }
    return result.isEmpty ? [.english] : result
}

/// Yerel ayar kimliğinin ("tr-TR", "nb_NO", "no") klavye dili; düzeni yoksa nil. Saf fonksiyondur.
public func keyboardLanguage(identifier: String) -> KeyboardLanguage? {
    let code: String = String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    switch code {
    case "no", "nn":
        return .norwegian
    default:
        return KeyboardLanguage(rawValue: code)
    }
}

/// Metni klavye dilinin kurallarıyla büyük harfe çevirir (Türkçede "i" → "İ"). Saf fonksiyondur.
public func keyboardUppercased(_ text: String, language: KeyboardLanguage) -> String {
    text.uppercased(with: language.casingLocale)
}

/// Kelimenin ilk harfini dilin kurallarıyla büyütür, gerisine dokunmaz. Saf fonksiyondur.
public func keyboardCapitalizedFirst(_ word: String, language: KeyboardLanguage) -> String {
    guard let first = word.first else {
        return word
    }
    return keyboardUppercased(String(first), language: language) + word.dropFirst()
}
