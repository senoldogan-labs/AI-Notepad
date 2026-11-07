import AINotepadCore

/// Üst satırdaki dil metni: kilitli dil, sabit seçim ya da otomatik algılama durumu. Saf fonksiyondur.
public func languageText(locked: MeetingLanguage?, mode: LanguageMode, isRecording: Bool) -> String {
    if let locked {
        return languageName(language: locked)
    }
    switch mode {
    case .fixed(let language):
        return languageName(language: language)
    case .automatic:
        return isRecording ? String(localized: "Dil algılanıyor…") : String(localized: "Dil: Otomatik")
    }
}

/// Dil adı, arayüz dilinde. Bayraksız: diller ülke değildir (İngilizce için İngiltere bayrağı, Portekizce için hangisi?).
public func languageName(language: MeetingLanguage) -> String {
    capitalizedLanguageName(name: meetingLanguageName(language: language), locale: interfaceLocale())
}
