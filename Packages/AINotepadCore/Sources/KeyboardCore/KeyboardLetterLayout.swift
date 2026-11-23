import Foundation

/// How the letters are arranged (Settings › Keyboard, per language). The language's accents, extra letters and
/// autocorrect stay the language's; only the 26 base letters move.
public enum KeyboardLetterLayout: String, Sendable, Hashable, Codable, CaseIterable {
    case qwerty
    case qwertz
    case azerty
}

/// The layout a language ships with.
public func keyboardNativeLayout(language: KeyboardLanguage) -> KeyboardLetterLayout {
    switch language {
    case .german:
        .qwertz
    case .french:
        .azerty
    case .english, .turkish, .spanish, .italian, .portuguese, .dutch, .swedish, .finnish, .norwegian, .danish:
        .qwerty
    }
}

private func keyboardBaseRows(layout: KeyboardLetterLayout) -> [String] {
    switch layout {
    case .qwerty:
        ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    case .qwertz:
        ["qwertzuiop", "asdfghjkl", "yxcvbnm"]
    case .azerty:
        ["azertyuiop", "qsdfghjklm", "wxcvbn"]
    }
}

private func keyboardIsBaseLetter(_ character: Character) -> Bool {
    character.isASCII && character.isLetter
}

/// The language's letter rows in the chosen layout. In its own layout these are the language's rows as designed. In
/// another layout the 26 base letters take that layout's places and the language's extra letters (ğ ü ş ı ö ç, ä å ñ,
/// the French apostrophe…) are appended to the row they sit on natively; a row that would grow wider than the
/// language's own widest row (the third row has to leave room for Shift and Delete, three units) hands its last
/// extras to the shortest row, so every letter stays reachable.
/// Pure function.
public func keyboardLetterRows(language: KeyboardLanguage, layout: KeyboardLetterLayout) -> [String] {
    let nativeRows: [String] = keyboardNativeLetterRows(language: language)
    guard layout != keyboardNativeLayout(language: language) else {
        return nativeRows
    }
    let limit: Int = nativeRows.prefix(2).map(\.count).max() ?? 10
    let base: [String] = keyboardBaseRows(layout: layout)
    var extras: [[Character]] = nativeRows.map { (row: String) -> [Character] in row.filter { !keyboardIsBaseLetter($0) } }
    func count(_ index: Int) -> Int {
        base[index].count + extras[index].count
    }
    func rowLimit(_ index: Int) -> Int {
        index == 2 ? limit - 3 : limit
    }
    while let over = extras.indices.first(where: { count($0) > rowLimit($0) && !extras[$0].isEmpty }) {
        let targets: [Int] = extras.indices.filter { $0 != over && count($0) < rowLimit($0) }
        guard let target = targets.min(by: { count($0) < count($1) }), let moved = extras[over].popLast() else {
            break
        }
        extras[target].append(moved)
    }
    return extras.indices.map { base[$0] + String(extras[$0]) }
}
