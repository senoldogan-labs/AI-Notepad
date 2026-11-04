import AINotepadCore
import Foundation

// App Store ekran görüntülerinin örnek verisi: iPhone'da kaydedilmiş yüz yüze toplantılar (İngilizce) ve kaynaklı bir
// Sor sohbeti. Mac'in tanıtım verisinden (App/DemoData.swift) iPhone'a uyarlanmıştır: görüşmeler masa başında, telefon
// mikrofonuyla kaydedilmiş gibidir (iPhone Zoom ya da telefon görüşmesi kaydetmez).
// Kullanım: swift run --package-path scripts/appstore-screenshots/seeder AppStoreSeeder <çıktı klasörü>
// Çıktı: <klasör>/Sessions/<kimlik>/meeting.json, <klasör>/AskHistory/<kimlik>.json ve sahnelerin kullandığı kimlikleri
// taşıyan <klasör>/seed-manifest.json. İlk ikisi uygulamanın veri klasörüne (Simülatör'de Library/Application
// Support/AINotepad) kopyalanır.

/// Komut satırı hatası.
enum SeederError: Error, CustomStringConvertible {
    /// Çıktı klasörü verilmedi.
    case missingOutputDirectory(arguments: [String])
    /// Çıktı klasörü boş değil: eski veri karışmasın diye araç yalnız boş ya da olmayan klasöre yazar.
    case outputNotEmpty(path: String, entries: [String])

    var description: String {
        switch self {
        case .missingOutputDirectory(let arguments):
            "Çıktı klasörü eksik (gelen: \(arguments)). Kullanım: AppStoreSeeder <çıktı klasörü>"
        case .outputNotEmpty(let path, let entries):
            "Çıktı klasörü boş değil: \(path) (içinde: \(entries.prefix(5).joined(separator: ", "))). Boş bir klasör ver."
        }
    }
}

/// Sahnelerin başlatma argümanlarında kullandığı kimlikler (`seed-manifest.json`).
struct SeedManifest: Codable {
    /// "Product weekly" toplantısının klasör adı (`--toplanti`).
    let productWeekly: String
    /// Saklı Sor sohbetinin kimliği.
    let askConversation: String
}

/// Bir toplantının yazılı satırı: konuşmacı (nil "Sen"), başlangıç saniyesi ve metin.
struct SeedLine {
    let person: Int?
    let start: Double
    let text: String
}

/// Bir toplantının tanımı.
struct SeedMeeting {
    let title: String
    let startedAt: Date
    let minutes: Int
    let folder: String
    let people: [Int: String]
    let attendees: [String]
    let lines: [SeedLine]
    let summary: String
    let decisions: [String]
    let tasks: [NoteTask]
    let glossary: [GlossaryEntry]
    let outline: [OutlineItem]
    /// Tamamlanmış görevlerin açıklamaları.
    let doneTasks: [String]
}

/// Toplantının kimliği: oturum klasörünün adı (`yyyyMMdd-HHmmss`, yerel saat; Simülatör Mac'in saat dilimini kullanır).
/// Saf fonksiyondur.
func seedMeetingID(startedAt: Date, timeZone: TimeZone) -> String {
    let formatter: DateFormatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: startedAt)
}

/// `days` gün önceki verilen saat (yerel); bugün için saat henüz gelmediyse bir gün geriye kayar. Saf fonksiyondur.
func seedDate(now: Date, calendar: Calendar, days: Int, hour: Int, minute: Int) -> Date {
    let start: Date = calendar.startOfDay(for: now)
    let candidate: Date = start.addingTimeInterval(Double(hour * 3600 + minute * 60))
    let today: Date = candidate < now ? candidate : candidate.addingTimeInterval(-86_400)
    return today.addingTimeInterval(-Double(days) * 86_400)
}

/// Görev kısaltması: kullanıcıya düşen görev.
func mine(description: String, due: String?) -> NoteTask {
    NoteTask(owner: "Alex", description: description, dueDate: due, isMine: true)
}

/// Görev kısaltması: başkasına düşen görev.
func theirs(owner: String, description: String, due: String?) -> NoteTask {
    NoteTask(owner: owner, description: description, dueDate: due, isMine: false)
}

/// Tanımdan saklanan toplantıyı üretir. Saf fonksiyondur.
func seedRecord(meeting: SeedMeeting, timeZone: TimeZone) -> MeetingRecord {
    let segments: [StoredSegment] = meeting.lines.enumerated().map { (item: (offset: Int, element: SeedLine)) -> StoredSegment in
        let next: Double = item.offset + 1 < meeting.lines.count ? meeting.lines[item.offset + 1].start : item.element.start + 12
        return StoredSegment(
            key: "final-\(item.offset)", speaker: item.element.person == nil ? .me : .others, person: item.element.person,
            startSec: item.element.start, endSec: max(item.element.start + 2, next - 0.6), text: item.element.text, words: nil
        )
    }
    let note: MeetingNote = MeetingNote(
        title: meeting.title, summary: meeting.summary, decisions: meeting.decisions, tasks: meeting.tasks, glossary: meeting.glossary
    )
    .with(outline: meeting.outline)
    .with(language: .english)
    let done: [String] = meeting.tasks.filter { meeting.doneTasks.contains($0.description) }.map { taskKey(task: $0) }
    return MeetingRecord(
        id: seedMeetingID(startedAt: meeting.startedAt, timeZone: timeZone), title: meeting.title, startedAt: meeting.startedAt,
        endedAt: meeting.startedAt.addingTimeInterval(Double(meeting.minutes * 60)), language: .english, status: .done,
        failureMessage: nil, liveSegments: [], finalSegments: segments, translations: [:], speakerNames: meeting.people, note: note,
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
    .with(folder: meeting.folder)
    .with(attendees: meeting.attendees)
    .with(completedTasks: done)
}

/// "Product weekly"nin başlangıcı (bugün sabah); sahne bu toplantının notunu açar. Hat, tohumlayıcıyı ve uygulamayı yerel saat
/// sabah 10'a yakın olacak bir saat dilimiyle (`TZ`) çalıştırır: toplantı her zaman "bugün" ve geçmiştedir.
func productWeeklyStart(now: Date, calendar: Calendar) -> Date {
    seedDate(now: now, calendar: calendar, days: 0, hour: 8, minute: 30)
}

/// "Investor update"in başlangıcı (üç hafta önce); Sor cevabının kaynağı.
func investorUpdateStart(now: Date, calendar: Calendar) -> Date {
    seedDate(now: now, calendar: calendar, days: 22, hour: 16, minute: 0)
}

/// Örnek toplantılar (yeniden eskiye). Saf fonksiyondur.
func seedMeetings(now: Date, calendar: Calendar) -> [SeedMeeting] {
    [
        SeedMeeting(
            title: "Product weekly", startedAt: productWeeklyStart(now: now, calendar: calendar), minutes: 42, folder: "Product",
            people: [1: "Elif", 2: "Mikko", 3: "Ayşe"], attendees: ["Elif Kaya", "Mikko Virtanen", "Ayşe Demir"],
            lines: [
                SeedLine(person: 1, start: 4, text: "Morning, everyone. Three things today: the beta date, pricing, and how we support the first customers."),
                SeedLine(person: 1, start: 14, text: "Engineering says the release candidate is stable. I'd like to open the beta on the fourteenth of November."),
                SeedLine(person: 2, start: 25, text: "From our side that works. The export sync bug is the last blocker, and I'll have it fixed by Thursday."),
                SeedLine(person: nil, start: 37, text: "Works for me. I'll write the release notes by Friday so they're ready a week ahead."),
                SeedLine(person: 3, start: 48, text: "Sales has eighty customers who asked to join. Can we invite all of them in the first wave?"),
                SeedLine(person: 1, start: 59, text: "Let's cap the first wave at two hundred accounts in total and confirm the list on Monday."),
                SeedLine(person: 3, start: 612, text: "On pricing: I'm visiting Nordia on Thursday and I need the latest pricing table before then."),
                SeedLine(person: nil, start: 624, text: "I'll send you the pricing table today, right after this meeting."),
                SeedLine(person: 1, start: 636, text: "And we keep the current tiers for the beta. No discounts until we see the usage numbers."),
                SeedLine(person: 2, start: 1310, text: "One more thing: support should have a weekly sync with us while the beta runs."),
                SeedLine(person: nil, start: 1322, text: "Agreed. I'll set up a Wednesday meeting with the support team."),
                SeedLine(person: 1, start: 2390, text: "Great. Beta on the fourteenth, release notes Friday, pricing table today. Thanks, everyone."),
            ],
            summary: "The team agreed to open the beta on 14 November once the export sync bug is fixed. The first wave is capped at 200 accounts, including the 80 customers sales has lined up; the list is confirmed on Monday. Pricing stays on the current tiers during the beta, and support gets a weekly sync with product and engineering.",
            decisions: [
                "The beta opens on 14 November.",
                "The first wave is capped at 200 accounts.",
                "Pricing stays on the current tiers during the beta.",
                "Support gets a weekly sync while the beta runs.",
            ],
            tasks: [
                mine(description: "Send Ayşe the latest pricing table", due: "Today"),
                mine(description: "Write the beta release notes", due: "Friday"),
                mine(description: "Set up a weekly Wednesday sync with support", due: "Wednesday"),
                theirs(owner: "Mikko", description: "Fix the export sync bug", due: "Thursday"),
                theirs(owner: "Elif", description: "Confirm the first-wave invite list with sales", due: "Monday"),
            ],
            glossary: [
                GlossaryEntry(term: "RC", meaning: "Release candidate: the build that becomes the beta if no blocker is found."),
                GlossaryEntry(term: "First wave", meaning: "The first 200 accounts invited to the beta."),
            ],
            outline: [
                OutlineItem(startSec: 4, title: "Beta date", summary: "The release candidate is stable; the beta opens on 14 November."),
                OutlineItem(startSec: 48, title: "Who gets invited", summary: "The first wave is capped at 200 accounts and confirmed on Monday."),
                OutlineItem(startSec: 612, title: "Pricing", summary: "Current tiers stay; Ayşe gets the pricing table before the Nordia visit."),
                OutlineItem(startSec: 1310, title: "Support during the beta", summary: "A weekly Wednesday sync with the support team."),
            ],
            doneTasks: []
        ),
        SeedMeeting(
            title: "Client visit · Nordia", startedAt: seedDate(now: now, calendar: calendar, days: 1, hour: 14, minute: 0), minutes: 35,
            folder: "Clients", people: [1: "Jonas", 2: "Ayşe"], attendees: ["Jonas Berg", "Ayşe Demir"],
            lines: [
                SeedLine(person: 1, start: 6, text: "Thanks for coming over. Our team runs about forty meetings a week across Helsinki and Stockholm."),
                SeedLine(person: 1, start: 18, text: "Half of them are in Finnish or Swedish, so translation is the main reason we're looking at this."),
                SeedLine(person: nil, start: 31, text: "That's exactly the use case. The transcript is translated live, and the note can be written in English."),
                SeedLine(person: 2, start: 44, text: "We can set up a two-week pilot for your leadership team."),
                SeedLine(person: 1, start: 57, text: "Good. Our security team will want to see where the audio goes before we start."),
                SeedLine(person: nil, start: 69, text: "I'll send the security overview and the data flow diagram tomorrow."),
            ],
            summary: "Nordia runs about 40 meetings a week across Helsinki and Stockholm, half of them in Finnish or Swedish; live translation is their main need. Both sides agreed on a two-week pilot for the leadership team, starting after Nordia's security review.",
            decisions: ["Two-week pilot for Nordia's leadership team.", "The pilot starts after Nordia's security review."],
            tasks: [
                mine(description: "Send the security overview and data flow diagram", due: "Tomorrow"),
                theirs(owner: "Ayşe", description: "Draft the pilot agreement", due: "Next Tuesday"),
                theirs(owner: "Jonas", description: "Book the security review", due: "This week"),
            ],
            glossary: [GlossaryEntry(term: "Pilot", meaning: "A two-week trial with Nordia's leadership team.")],
            outline: [
                OutlineItem(startSec: 6, title: "Nordia's meetings", summary: "40 meetings a week, half in Finnish or Swedish."),
                OutlineItem(startSec: 44, title: "Pilot", summary: "Two weeks with the leadership team after a security review."),
            ],
            doneTasks: []
        ),
        SeedMeeting(
            title: "Design review", startedAt: seedDate(now: now, calendar: calendar, days: 3, hour: 11, minute: 0), minutes: 50,
            folder: "Product", people: [1: "Elif", 2: "Lena"], attendees: ["Elif Kaya", "Lena Fischer"],
            lines: [
                SeedLine(person: 2, start: 5, text: "I simplified the onboarding to three screens: welcome, permissions, and sign in."),
                SeedLine(person: 1, start: 19, text: "Much better. Can the permission screen explain why we need the microphone?"),
                SeedLine(person: nil, start: 31, text: "Yes, one sentence each. And let's move tasks above the summary in the note."),
                SeedLine(person: 2, start: 44, text: "Agreed. I'll update the note layout and the empty states."),
            ],
            summary: "Lena presented a three-screen onboarding. The team agreed to explain each permission in one sentence and to show tasks above the summary in every note.",
            decisions: ["Onboarding has three screens.", "Tasks appear above the summary in every note."],
            tasks: [
                mine(description: "Write one-sentence copy for each permission", due: "Thursday"),
                mine(description: "Review the new empty states", due: nil),
                theirs(owner: "Lena", description: "Update the note layout so tasks come first", due: "Friday"),
                theirs(owner: "Lena", description: "Redesign the empty states", due: "Next week"),
                theirs(owner: "Elif", description: "Share the onboarding with five beta users", due: "Next week"),
            ],
            glossary: [],
            outline: [OutlineItem(startSec: 5, title: "Onboarding", summary: "Three screens; each permission explained in one sentence.")],
            doneTasks: ["Review the new empty states"]
        ),
        SeedMeeting(
            title: "Hiring sync", startedAt: seedDate(now: now, calendar: calendar, days: 4, hour: 15, minute: 30), minutes: 25,
            folder: "Company", people: [1: "Elif", 2: "Daniel"], attendees: ["Elif Kaya", "Daniel Okafor"],
            lines: [
                SeedLine(person: 2, start: 4, text: "We have three strong candidates for the iOS role. Two of them can start in January."),
                SeedLine(person: 1, start: 16, text: "Let's do final interviews next week and decide by the twentieth."),
                SeedLine(person: nil, start: 28, text: "I can take the technical interview for the first two."),
            ],
            summary: "Three strong candidates for the iOS role; final interviews next week and a decision by 20 November.",
            decisions: ["Decision on the iOS role by 20 November."],
            tasks: [
                mine(description: "Run the technical interviews", due: "Next week"),
                theirs(owner: "Daniel", description: "Schedule the final interviews", due: "Monday"),
            ],
            glossary: [],
            outline: [OutlineItem(startSec: 4, title: "iOS role", summary: "Three candidates; final interviews next week.")],
            doneTasks: []
        ),
        SeedMeeting(
            title: "One-on-one: Elif", startedAt: seedDate(now: now, calendar: calendar, days: 7, hour: 10, minute: 0), minutes: 30,
            folder: "Team", people: [1: "Elif"], attendees: ["Elif Kaya"],
            lines: [
                SeedLine(person: 1, start: 3, text: "How are you feeling about the launch workload?"),
                SeedLine(person: nil, start: 11, text: "Busy but fine. I'd like to own the release notes and the beta onboarding emails."),
                SeedLine(person: 1, start: 24, text: "Sounds good. Let's revisit the support rotation after the beta."),
            ],
            summary: "Alex takes ownership of the release notes and the beta onboarding emails. The support rotation will be revisited after the beta.",
            decisions: ["Alex owns the release notes and onboarding emails."],
            tasks: [
                mine(description: "Draft the beta onboarding emails", due: "Next Friday"),
                theirs(owner: "Elif", description: "Propose a new support rotation", due: "After the beta"),
            ],
            glossary: [],
            outline: [OutlineItem(startSec: 3, title: "Launch workload", summary: "Alex owns release notes and onboarding emails.")],
            doneTasks: []
        ),
        SeedMeeting(
            title: "Roadmap planning", startedAt: seedDate(now: now, calendar: calendar, days: 10, hour: 13, minute: 0), minutes: 55,
            folder: "Product", people: [1: "Elif", 2: "Mikko"], attendees: ["Elif Kaya", "Mikko Virtanen"],
            lines: [
                SeedLine(person: 1, start: 5, text: "For the first quarter, I'd focus on the iPhone app and team workspaces."),
                SeedLine(person: 2, start: 18, text: "Workspaces need sync first. That's about six weeks of work."),
                SeedLine(person: nil, start: 31, text: "Then iPhone first, workspaces after sync is in place."),
            ],
            summary: "The first quarter focuses on the iPhone app; team workspaces follow once sync is in place, about six weeks of work.",
            decisions: ["iPhone app first in Q1.", "Workspaces follow after sync."],
            tasks: [
                mine(description: "Write the Q1 roadmap one-pager", due: nil),
                theirs(owner: "Mikko", description: "Estimate the sync work", due: "Next week"),
            ],
            glossary: [GlossaryEntry(term: "Workspaces", meaning: "Shared folders of meetings for a team.")],
            outline: [OutlineItem(startSec: 5, title: "Q1 focus", summary: "iPhone app first, then workspaces.")],
            doneTasks: ["Write the Q1 roadmap one-pager"]
        ),
        SeedMeeting(
            title: "Investor update", startedAt: investorUpdateStart(now: now, calendar: calendar), minutes: 45, folder: "Company",
            people: [1: "Maria", 2: "Elif"], attendees: ["Maria Santos", "Elif Kaya"],
            lines: [
                SeedLine(person: 1, start: 6, text: "Revenue grew eighteen percent this quarter. Where do you want to put the extra budget?"),
                SeedLine(person: nil, start: 19, text: "We'd move forty thousand euros from paid ads to customer research and the beta."),
                SeedLine(person: 2, start: 33, text: "And we keep hiring flat until the beta numbers are in."),
                SeedLine(person: 1, start: 46, text: "That's sensible. Send me the updated budget before the board meeting."),
            ],
            summary: "Revenue grew 18% this quarter. €40k of the marketing budget moves from paid ads to customer research and the beta; hiring stays flat until the beta results are in. Maria wants the updated budget before the board meeting.",
            decisions: ["€40k moves from paid ads to customer research and the beta.", "Hiring stays flat until the beta results are in."],
            tasks: [
                mine(description: "Send Maria the updated budget", due: "Before the board meeting"),
                mine(description: "Plan customer research interviews", due: "November"),
                theirs(owner: "Elif", description: "Prepare beta metrics for the board", due: "December"),
                theirs(owner: "Maria", description: "Share the board meeting agenda", due: "Next week"),
            ],
            glossary: [],
            outline: [OutlineItem(startSec: 6, title: "Budget", summary: "€40k from paid ads to research and the beta; hiring flat.")],
            doneTasks: ["Send Maria the updated budget"]
        ),
    ]
}

/// Saklı Sor sohbetinin kimliği (sabit: sahne ya da bir başlatma argümanı onu açabilir).
let seedAskConversationID: UUID = UUID(uuid: (0x6B, 0x1E, 0x7C, 0x52, 0x3A, 0x0F, 0x4C, 0x4B, 0x9E, 0x58, 0x2D, 0x6F, 0x3B, 0x1A, 0x9C, 0x10))

/// Bütçe sorusu ve kaynaklı cevabı (Investor update ve Product weekly). Saf fonksiyondur.
func seedAskConversation(now: Date, calendar: Calendar) -> AskConversation {
    let investorStart: Date = investorUpdateStart(now: now, calendar: calendar)
    let weeklyStart: Date = productWeeklyStart(now: now, calendar: calendar)
    let investorID: String = seedMeetingID(startedAt: investorStart, timeZone: calendar.timeZone)
    let weeklyID: String = seedMeetingID(startedAt: weeklyStart, timeZone: calendar.timeZone)
    let sources: [ArchivePassage] = [
        ArchivePassage(
            id: "seed-1", meetingID: investorID, meetingTitle: "Investor update", meetingDate: investorStart, kind: .note, startSec: 0,
            text: "€40k of the marketing budget moves from paid ads to customer research and the beta; hiring stays flat until the beta results are in."
        ),
        ArchivePassage(
            id: "seed-2", meetingID: investorID, meetingTitle: "Investor update", meetingDate: investorStart, kind: .transcript, startSec: 19,
            text: "We'd move forty thousand euros from paid ads to customer research and the beta."
        ),
        ArchivePassage(
            id: "seed-3", meetingID: weeklyID, meetingTitle: "Product weekly", meetingDate: weeklyStart, kind: .note, startSec: 0,
            text: "Pricing stays on the current tiers during the beta. No discounts until we see the usage numbers."
        ),
    ]
    let answer: String = """
    Two decisions shape the budget right now:

    - **€40k moves from paid ads to customer research and the beta.** You proposed it in the investor update and Maria agreed [1][2].
    - **Hiring stays flat** until the beta results are in [1].

    For the beta itself, pricing stays on the current tiers, with no discounts until the usage numbers are in [3].
    """
    let askedAt: Date = now.addingTimeInterval(-25 * 60)
    let turn: AskConversationTurn = AskConversationTurn(
        id: UUID(uuid: (0x0C, 0x9B, 0x6E, 0x3D, 0x7F, 0x21, 0x4E, 0x8A, 0xA1, 0xD4, 0x5B, 0x3C, 0x2E, 0x9F, 0x8A, 0x71)),
        question: "What did we decide about the budget?", scopeMeetingIDs: [], scopeTitles: [], recipeTitle: nil, startedAt: askedAt,
        finishedAt: askedAt.addingTimeInterval(6), terms: ["budget", "paid ads", "hiring", "pricing"], readPassages: sources, readScreens: 0, answer: answer,
        sources: sources, webSources: nil, webQueries: nil
    )
    return askConversation(existing: nil, id: seedAskConversationID, turns: [turn], now: askedAt.addingTimeInterval(6))
}

/// Örnek veriyi boş (ya da olmayan) çıktı klasörüne yazar.
func writeSeed(output: URL, now: Date, calendar: Calendar) throws {
    let fileManager: FileManager = FileManager.default
    if fileManager.fileExists(atPath: output.path) {
        let entries: [String] = try fileManager.contentsOfDirectory(atPath: output.path)
        guard entries.isEmpty else {
            throw SeederError.outputNotEmpty(path: output.path, entries: entries)
        }
    }
    let sessions: URL = output.appending(path: "Sessions", directoryHint: .isDirectory)
    for meeting in seedMeetings(now: now, calendar: calendar) {
        let record: MeetingRecord = seedRecord(meeting: meeting, timeZone: calendar.timeZone)
        let folder: URL = sessions.appending(path: record.id, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveMeeting(record: record, directory: folder)
        print("toplantı: \(record.id) \(record.title)")
    }
    let askHistory: URL = output.appending(path: "AskHistory", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: askHistory, withIntermediateDirectories: true)
    try saveAskConversation(conversation: seedAskConversation(now: now, calendar: calendar), directory: askHistory)
    let manifest: SeedManifest = SeedManifest(
        productWeekly: seedMeetingID(startedAt: productWeeklyStart(now: now, calendar: calendar), timeZone: calendar.timeZone),
        askConversation: seedAskConversationID.uuidString
    )
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(to: output.appending(path: "seed-manifest.json"), options: .atomic)
    print("sohbet: \(seedAskConversationID.uuidString)")
}

let arguments: [String] = CommandLine.arguments
guard arguments.count == 2 else {
    throw SeederError.missingOutputDirectory(arguments: Array(arguments.dropFirst()))
}
try writeSeed(output: URL(filePath: arguments[1], directoryHint: .isDirectory), now: Date(), calendar: Calendar.current)
