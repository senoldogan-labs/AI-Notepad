import Foundation

// The note is written before the user names the speakers, so it refers to people by generic labels ("Speaker 2",
// "Konuşmacı 2", "Puhuja 2"). Names live in `MeetingRecord.speakerNames` and are applied when the note is shown or
// leaves the app (`namedNote`, `namedRecord`); the stored note keeps the generic labels so renaming again or removing a
// name always works.

/// The word a note in `language` uses for an unnamed speaker ("Speaker" in "Speaker 2"); the note prompt asks for
/// exactly this form (see `noteRules`). Pure function.
public func speakerLabelWord(language: ShareLanguage) -> String {
    switch language {
    case .finnish: "Puhuja"
    case .english: "Speaker"
    case .swedish: "Talare"
    case .norwegian: "Taler"
    case .danish: "Taler"
    case .estonian: "Kõneleja"
    case .german: "Sprecher"
    case .dutch: "Spreker"
    case .french: "Intervenant"
    case .spanish: "Hablante"
    case .portuguese: "Orador"
    case .italian: "Relatore"
    case .polish: "Mówca"
    case .czech: "Mluvčí"
    case .slovak: "Rečník"
    case .hungarian: "Beszélő"
    case .romanian: "Vorbitor"
    case .bulgarian: "Говорител"
    case .croatian: "Govornik"
    case .greek: "Ομιλητής"
    case .latvian: "Runātājs"
    case .lithuanian: "Kalbėtojas"
    case .russian: "Спикер"
    case .ukrainian: "Спікер"
    case .turkish: "Konuşmacı"
    case .azerbaijani: "Natiq"
    case .arabic: "المتحدث"
    case .hebrew: "דובר"
    case .persian: "گوینده"
    case .hindi: "वक्ता"
    case .chineseSimplified: "发言人"
    case .chineseTraditional: "發言人"
    case .japanese: "話者"
    case .korean: "화자"
    case .indonesian: "Pembicara"
    case .vietnamese: "Người nói"
    case .thai: "ผู้พูด"
    }
}

/// Other words models use for the same label (notes written before the prompt fixed the form, or translated shared
/// versions); matched like `speakerLabelWord`.
private let alternativeSpeakerWords: [String] = [
    "Sprecherin", "Locuteur", "Orateur", "Orador", "Falante", "Oratore", "Parlante", "Řečník", "Felszólaló",
    "Vorbitorul", "Говорящий", "Докладчик", "Мовець", "Danışan", "متحدث", "说话人", "說話人", "說話者", "スピーカー", "발표자",
]

/// Words of scripts written without spaces (Chinese, Japanese, Thai): the label may directly follow other letters.
private func isUnspacedScript(word: String) -> Bool {
    word.unicodeScalars.first.map { (scalar: Unicode.Scalar) -> Bool in
        switch scalar.value {
        case 0x0E00...0x0E7F, 0x3040...0x30FF, 0x3400...0x9FFF, 0xF900...0xFAFF: true
        default: false
        }
    } ?? false
}

/// "<word> N" in any note language, case-insensitive; group 1 is the number. A label inside a longer word or number
/// does not match ("Speaker 1" never matches in "Speaker 12" or "Loudspeaker 1").
private let speakerLabelPattern: NSRegularExpression = {
    let words: [String] = Array(Set(ShareLanguage.allCases.map { speakerLabelWord(language: $0) } + alternativeSpeakerWords))
        .sorted { (left: String, right: String) -> Bool in left.count == right.count ? left < right : left.count > right.count }
    let spaced: [String] = words.filter { !isUnspacedScript(word: $0) }.map(NSRegularExpression.escapedPattern(for:))
    let unspaced: [String] = words.filter(isUnspacedScript(word:)).map(NSRegularExpression.escapedPattern(for:))
    let pattern: String = "(?:(?<![\\p{L}\\p{M}])(?:\(spaced.joined(separator: "|")))|(?:\(unspaced.joined(separator: "|"))))[ \\u00A0]?#?(\\d+)(?!\\d)"
    do {
        return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    } catch {
        preconditionFailure("Speaker label pattern does not compile: \(error) pattern: \(pattern)")
    }
}()

/// Replaces generic speaker labels ("Speaker 2", "Konuşmacı 2", "Puhuja 2", "发言人2") with the names the user gave
/// (`speakerNames`: person number → name). Labels of unnamed people stay as they are. Pure function.
public func namingSpeakers(text: String, speakerNames: [Int: String]) -> String {
    let names: [Int: String] = speakerNames.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !names.isEmpty, !text.isEmpty else {
        return text
    }
    let source: NSString = text as NSString
    let matches: [NSTextCheckingResult] = speakerLabelPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
    return matches.reversed().reduce(into: text) { (result: inout String, match: NSTextCheckingResult) -> Void in
        let digits: String = source.substring(with: match.range(at: 1))
        let number: Int? = digits.reduce(Optional(0)) { (total: Int?, character: Character) -> Int? in
            total.flatMap { (value: Int) -> Int? in character.wholeNumberValue.map { value * 10 + $0 } }
        }
        guard let number, let name = names[number], let range = Range(match.range, in: result) else {
            return
        }
        result.replaceSubrange(range, with: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Whether `name` (a task owner or a speaker's name) is the user: the same name, or the user's first name ("Şenol" for
/// "Şenol Doğan"); case-insensitive. Always false without a user name. Pure function.
public func isUserName(name: String, userName: String) -> Bool {
    let trimmedName: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedUser: String = userName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty, !trimmedUser.isEmpty else {
        return false
    }
    let firstName: String = trimmedUser.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? trimmedUser
    return trimmedName.caseInsensitiveCompare(trimmedUser) == .orderedSame || trimmedName.caseInsensitiveCompare(firstName) == .orderedSame
}

/// The task with speaker names applied to its owner, description and date. It is the user's task when it was already
/// or its owner now names the user (see `isUserName`). Its tracking key stays the stored task's (`taskKey`), so done,
/// reminded and sent marks keep matching. Pure function.
public func namedTask(task: NoteTask, speakerNames: [Int: String], userName: String) -> NoteTask {
    let owner: String = namingSpeakers(text: task.owner, speakerNames: speakerNames)
    let named: NoteTask = NoteTask(
        owner: owner,
        description: namingSpeakers(text: task.description, speakerNames: speakerNames),
        dueDate: task.dueDate.map { namingSpeakers(text: $0, speakerNames: speakerNames) },
        isMine: task.isMine || isUserName(name: owner, userName: userName)
    )
    // Elle eklenmiş görev görüntü kopyasında da öyle görünsün (silinebilir).
    return (task.isAdded == true ? named.markedAdded() : named).with(storedKey: taskKey(task: task))
}

/// The note with speaker names applied to every text (title, summary, topic flow, decisions, open questions, tasks,
/// glossary meanings);
/// language and topic flow are kept. Pure function.
public func namedNote(note: MeetingNote, speakerNames: [Int: String], userName: String) -> MeetingNote {
    let name: (String) -> String = { (text: String) -> String in namingSpeakers(text: text, speakerNames: speakerNames) }
    let named: MeetingNote = MeetingNote(
        title: name(note.title),
        summary: name(note.summary),
        decisions: note.decisions.map(name),
        tasks: note.tasks.map { namedTask(task: $0, speakerNames: speakerNames, userName: userName) },
        glossary: note.glossary.map { GlossaryEntry(term: $0.term, meaning: name($0.meaning)) }
    )
    let withOutline: MeetingNote = note.outline.map { (outline: [OutlineItem]) -> MeetingNote in
        named.with(outline: outline.map { OutlineItem(startSec: $0.startSec, title: name($0.title), summary: name($0.summary)) })
    } ?? named
    let withQuestions: MeetingNote = note.openQuestions.map { withOutline.with(openQuestions: $0.map(name)) } ?? withOutline
    return note.language.map { withQuestions.with(language: $0) } ?? withQuestions
}

/// The record as shown and shared: speaker names applied to its note and shared-language versions (`namedNote`).
/// Only for reading (views, exports, sends, Ask, MCP); save the stored record, never this one, so the stored note
/// keeps the generic labels. Pure function.
public func namedRecord(record: MeetingRecord, userName: String) -> MeetingRecord {
    guard record.note != nil, !record.speakerNames.isEmpty else {
        return record
    }
    let name: (MeetingNote) -> MeetingNote = { (note: MeetingNote) -> MeetingNote in
        namedNote(note: note, speakerNames: record.speakerNames, userName: userName)
    }
    return record.presenting(note: record.note.map(name), sharedNotes: record.sharedNotes?.mapValues(name))
}

/// `namedRecord` for each meeting. Pure function.
public func namedRecords(records: [MeetingRecord], userName: String) -> [MeetingRecord] {
    records.map { namedRecord(record: $0, userName: userName) }
}

/// The note's tasks as `namedRecord` shows them, without naming the rest of the note (the label search over a whole
/// note is the costly part). Pure function.
public func namedTasks(record: MeetingRecord, userName: String) -> [NoteTask] {
    let tasks: [NoteTask] = record.note?.tasks ?? []
    guard !record.speakerNames.isEmpty else {
        return tasks
    }
    return tasks.map { namedTask(task: $0, speakerNames: record.speakerNames, userName: userName) }
}

/// One meeting's named note and shared-language versions (see `namedRecord`) with everything they depend on.
public struct NamedNotes: Sendable, Equatable {
    let userName: String
    let speakerNames: [Int: String]
    let note: MeetingNote?
    let sharedNotes: [String: MeetingNote]?
    let namedNote: MeetingNote?
    let namedSharedNotes: [String: MeetingNote]?
}

/// Named notes of the last named list by meeting id (see `namedRecords(records:userName:cache:)`).
public struct NamedRecordsCache: Sendable, Equatable {
    let entries: [String: NamedNotes]

    public static let empty: NamedRecordsCache = NamedRecordsCache(entries: [:])
}

/// `namedRecords`, reusing the cached named notes of meetings whose note, shared-language versions and speaker names
/// and the user name are unchanged, so a list where one meeting changed (a recording checkpoint, a renamed speaker) runs
/// the label search only for that meeting. Returns the named records in the given order and the cache for the next
/// call (holding only these meetings). Pure function.
public func namedRecords(records: [MeetingRecord], userName: String, cache: NamedRecordsCache) -> (records: [MeetingRecord], cache: NamedRecordsCache) {
    let named: [(record: MeetingRecord, entry: NamedNotes)] = records.map { (record: MeetingRecord) -> (record: MeetingRecord, entry: NamedNotes) in
        if let cached = cache.entries[record.id], cached.userName == userName, cached.speakerNames == record.speakerNames,
           cached.note == record.note, cached.sharedNotes == record.sharedNotes {
            return (record: record.presenting(note: cached.namedNote, sharedNotes: cached.namedSharedNotes), entry: cached)
        }
        let shown: MeetingRecord = namedRecord(record: record, userName: userName)
        let entry: NamedNotes = NamedNotes(
            userName: userName, speakerNames: record.speakerNames, note: record.note, sharedNotes: record.sharedNotes,
            namedNote: shown.note, namedSharedNotes: shown.sharedNotes
        )
        return (record: shown, entry: entry)
    }
    let entries: [String: NamedNotes] = Dictionary(named.map { (key: $0.record.id, value: $0.entry) }) { (_: NamedNotes, last: NamedNotes) -> NamedNotes in last }
    return (records: named.map(\.record), cache: NamedRecordsCache(entries: entries))
}
