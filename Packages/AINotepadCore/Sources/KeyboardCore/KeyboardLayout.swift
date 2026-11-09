import Foundation

/// Klavyenin sayfası: harfler, rakamlar ve noktalama, ek simgeler.
public enum KeyboardPage: Sendable, Hashable {
    case letters
    case numbers
    case symbols
}

/// Tuşun işi. Harf tuşu küçük harfi taşır; büyük harf o anki büyük harf durumundan türetilir.
public enum KeyboardKeyKind: Sendable, Hashable {
    case character(String)
    case shift
    case delete
    case space
    case returnKey
    /// Sayfa değiştirme (ör. "123", "#+=", "ABC").
    case page(KeyboardPage)
    /// Sonraki klavye (yalnız `needsInputModeSwitchKey` iken).
    case globe
    case emoji
    /// Sesle yazma (yalnız kullanılabilirken görünür).
    case microphone
    /// Klavye dilleri arasında geçiş (birden çok dil seçiliyken).
    case language
}

/// Bir tuş: işi ve satırdaki genişliği (harf tuşu = 1 birim).
public struct KeyboardKey: Sendable, Hashable {
    public let kind: KeyboardKeyKind
    public let widthUnits: Double

    public init(kind: KeyboardKeyKind, widthUnits: Double) {
        self.kind = kind
        self.widthUnits = widthUnits
    }
}

/// Yazılan alanın türü: e-posta ve adres alanlarında boşluğun yanında "@", "." ve "/" tuşları çıkar.
public enum KeyboardFieldKind: Sendable, Hashable {
    case text
    case email
    case url
}

/// Düzeni etkileyen koşullar.
public struct KeyboardLayoutOptions: Sendable, Hashable {
    public let showsGlobe: Bool
    public let showsMicrophone: Bool
    public let showsLanguage: Bool
    public let field: KeyboardFieldKind

    public init(showsGlobe: Bool, showsMicrophone: Bool, showsLanguage: Bool, field: KeyboardFieldKind) {
        self.showsGlobe = showsGlobe
        self.showsMicrophone = showsMicrophone
        self.showsLanguage = showsLanguage
        self.field = field
    }
}

/// Dilin harf satırları (küçük harf, yukarıdan aşağı). Saf fonksiyondur.
public func keyboardLetterRows(language: KeyboardLanguage) -> [String] {
    switch language {
    case .english, .dutch, .italian, .portuguese:
        ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    case .turkish:
        ["qwertyuıopğü", "asdfghjklşi", "zxcvbnmöç"]
    case .german:
        ["qwertzuiopü", "asdfghjklöä", "yxcvbnm"]
    case .french:
        ["azertyuiop", "qsdfghjklm", "wxcvbn'"]
    case .spanish:
        ["qwertyuiop", "asdfghjklñ", "zxcvbnm"]
    case .swedish, .finnish:
        ["qwertyuiopå", "asdfghjklöä", "zxcvbnm"]
    case .norwegian:
        ["qwertyuiopå", "asdfghjkløæ", "zxcvbnm"]
    case .danish:
        ["qwertyuiopå", "asdfghjklæø", "zxcvbnm"]
    }
}

/// Dilin para birimi simgesi (rakam sayfasında).
public func keyboardCurrencySymbol(language: KeyboardLanguage) -> String {
    switch language {
    case .english:
        "$"
    case .turkish:
        "₺"
    case .german, .french, .spanish, .italian, .portuguese, .dutch, .finnish:
        "€"
    case .swedish, .norwegian, .danish:
        "kr"
    }
}

/// Sayfanın tuş satırları. Son satır her sayfada aynı yapıdadır: sayfa tuşu, (küre), (dil), emoji, (mikrofon), boşluk,
/// (alan tuşları), dönüş. Saf fonksiyondur.
public func keyboardRows(language: KeyboardLanguage, page: KeyboardPage, options: KeyboardLayoutOptions) -> [[KeyboardKey]] {
    let characterRows: [[String]]
    switch page {
    case .letters:
        characterRows = keyboardLetterRows(language: language).map { (row: String) -> [String] in row.map(String.init) }
    case .numbers:
        characterRows = [
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
            ["-", "/", ":", ";", "(", ")", keyboardCurrencySymbol(language: language), "&", "@", "\""],
            [".", ",", "?", "!", "'"],
        ]
    case .symbols:
        characterRows = [
            ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
            ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
            [".", ",", "?", "!", "'"],
        ]
    }
    let widest: Int = characterRows.prefix(2).map(\.count).max() ?? 10
    var rows: [[KeyboardKey]] = characterRows.prefix(2).map { (row: [String]) -> [KeyboardKey] in
        row.map { KeyboardKey(kind: .character($0), widthUnits: 1) }
    }
    // Üçüncü satır: solda büyük harf ya da sayfa tuşu, sağda silme; ikisi satırı en geniş satıra tamamlar.
    let third: [String] = characterRows[2]
    let sideWidth: Double = max(1.25, (Double(widest) - Double(third.count) * (page == .letters ? 1 : 1.4)) / 2)
    let thirdKeyWidth: Double = page == .letters ? 1 : 1.4
    let leading: KeyboardKey
    switch page {
    case .letters:
        leading = KeyboardKey(kind: .shift, widthUnits: sideWidth)
    case .numbers:
        leading = KeyboardKey(kind: .page(.symbols), widthUnits: sideWidth)
    case .symbols:
        leading = KeyboardKey(kind: .page(.numbers), widthUnits: sideWidth)
    }
    rows.append(
        [leading] + third.map { KeyboardKey(kind: .character($0), widthUnits: thirdKeyWidth) } + [KeyboardKey(kind: .delete, widthUnits: sideWidth)]
    )
    rows.append(keyboardBottomRow(page: page, options: options, totalUnits: Double(widest)))
    return rows
}

/// Alt satır: yan tuşlar sabit genişlikte, boşluk kalan yeri alır. Saf fonksiyondur.
func keyboardBottomRow(page: KeyboardPage, options: KeyboardLayoutOptions, totalUnits: Double) -> [KeyboardKey] {
    let sideUnit: Double = totalUnits >= 11 ? 1.3 : 1.2
    var leading: [KeyboardKey] = [KeyboardKey(kind: .page(page == .letters ? .numbers : .letters), widthUnits: sideUnit)]
    if options.showsGlobe {
        leading.append(KeyboardKey(kind: .globe, widthUnits: sideUnit))
    }
    if options.showsLanguage {
        leading.append(KeyboardKey(kind: .language, widthUnits: sideUnit))
    }
    leading.append(KeyboardKey(kind: .emoji, widthUnits: sideUnit))
    if options.showsMicrophone {
        leading.append(KeyboardKey(kind: .microphone, widthUnits: sideUnit))
    }
    let fieldKeys: [KeyboardKey]
    switch options.field {
    case .text:
        fieldKeys = []
    case .email:
        fieldKeys = [KeyboardKey(kind: .character("@"), widthUnits: 1), KeyboardKey(kind: .character("."), widthUnits: 1)]
    case .url:
        fieldKeys = [KeyboardKey(kind: .character("/"), widthUnits: 1), KeyboardKey(kind: .character("."), widthUnits: 1)]
    }
    let returnKey: KeyboardKey = KeyboardKey(kind: .returnKey, widthUnits: sideUnit * 1.6)
    let used: Double = (leading + fieldKeys + [returnKey]).reduce(0) { $0 + $1.widthUnits }
    let space: KeyboardKey = KeyboardKey(kind: .space, widthUnits: max(2, totalUnits - used))
    return leading + [space] + fieldKeys + [returnKey]
}

/// Uzun basınca çıkan seçenekler: üst harf satırında önce rakam, sonra dilin aksanlı harfleri (dilin kendi harfleri
/// öne). Seçenek yoksa boş dizi. Saf fonksiyondur.
public func keyboardAlternates(character: String, language: KeyboardLanguage) -> [String] {
    let base: String = character.lowercased()
    var result: [String] = []
    let topRow: [String] = (keyboardLetterRows(language: language).first ?? "").map(String.init)
    if let index = topRow.firstIndex(of: base), index < 10 {
        result.append(String((index + 1) % 10))
    }
    let accents: [String] = (keyboardAccents[base] ?? []).filter { !keyboardLetterRows(language: language).joined().contains($0) }
    let preferred: [String] = (keyboardPreferredAccents[language] ?? []).filter { accents.contains($0) }
    result += preferred + accents.filter { !preferred.contains($0) }
    result += keyboardPunctuationAlternates[character] ?? []
    return result
}

private let keyboardAccents: [String: [String]] = [
    "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
    "c": ["ç", "ć", "č"],
    "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
    "g": ["ğ"],
    "i": ["î", "ï", "í", "ī", "į", "ì", "ı"],
    "l": ["ł"],
    "n": ["ñ", "ń"],
    "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
    "s": ["ß", "ś", "š", "ş"],
    "u": ["û", "ü", "ù", "ú", "ū"],
    "y": ["ÿ"],
    "z": ["ž", "ź", "ż"],
]

/// Dilin en sık aksanlı harfleri: seçeneklerde öne alınır.
private let keyboardPreferredAccents: [KeyboardLanguage: [String]] = [
    .english: ["é"],
    .turkish: ["ç", "ğ", "ı", "ö", "ş", "ü", "â", "î", "û"],
    .german: ["ä", "ö", "ü", "ß"],
    .french: ["é", "è", "ê", "à", "ç", "ù", "â", "î", "ô", "û", "ë", "ï", "œ"],
    .spanish: ["á", "é", "í", "ó", "ú", "ñ", "ü"],
    .italian: ["à", "è", "é", "ì", "ò", "ù"],
    .portuguese: ["ã", "á", "â", "à", "ç", "é", "ê", "í", "õ", "ó", "ô", "ú"],
    .dutch: ["ë", "é", "ï", "ö", "ü"],
    .swedish: ["é"],
    .finnish: ["š", "ž"],
    .norwegian: ["é", "ö", "ä"],
    .danish: ["é", "ö", "ä"],
]

private let keyboardPunctuationAlternates: [String: [String]] = [
    ".": ["…"],
    "'": ["’", "‘", "`"],
    "\"": ["“", "”", "„", "«", "»"],
    "-": ["–", "—", "•"],
    "?": ["¿"],
    "!": ["¡"],
    "$": ["€", "£", "¥", "₺", "₩"],
    "0": ["°"],
    "/": ["\\"],
    "&": ["§"],
]
