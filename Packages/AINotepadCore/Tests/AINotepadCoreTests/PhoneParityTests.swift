import Foundation
import Testing
@testable import AINotepadCore

/// Mac ve iPhone'un ortak kullandığı saf mantık: konuşmacıya ad verince ses kaydı, bugün biten toplantılar, SKILL.md içe
/// aktarma ve tanılamanın alan adları.
@Suite struct PhoneParityTests {
    private let now: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func voice(_ values: [Float], seconds: Double) -> Voiceprint {
        Voiceprint(embedding: normalizedEmbedding(values: values), seconds: seconds)
    }

    // Ad verilen kişinin izi hatırlanır; ad düzeltilince iz eski addan geri alınıp yeni ada geçer; iz verilmezse (tanıma
    // kapalı) yalnızca düzeltme yapılır; aynı ad (büyük/küçük harf) yeniden verilince iz eski addan alınmaz.
    @Test func namingSpeakerLearnsAndCorrectsVoice() {
        let learned: [RegisteredVoice] = voicesAfterNamingSpeaker(
            voices: [], meetingID: "m", person: 1, previous: nil, name: " Aino ", voiceprint: voice([1, 0], seconds: 30), now: now
        )
        #expect(learned.map(\.name) == ["Aino"])
        let corrected: [RegisteredVoice] = voicesAfterNamingSpeaker(
            voices: learned, meetingID: "m", person: 1, previous: "Aino", name: "Mikko", voiceprint: voice([1, 0], seconds: 30), now: now
        )
        #expect(corrected.map(\.name) == ["Mikko"])
        let withoutVoice: [RegisteredVoice] = voicesAfterNamingSpeaker(
            voices: learned, meetingID: "m", person: 1, previous: "Aino", name: "Mikko", voiceprint: nil, now: now
        )
        #expect(withoutVoice.isEmpty)
        let sameName: [RegisteredVoice] = voicesAfterNamingSpeaker(
            voices: learned, meetingID: "m", person: 1, previous: "Aino", name: "aino", voiceprint: nil, now: now
        )
        #expect(sameName == learned)
    }

    // Birlikte ad verilince yalnız adı değişen kişiler işlenir: adı aynı kalan kişinin izi öğrenilmez.
    @Test func namingSpeakersOnlyTouchesChangedNames() {
        let voices: [RegisteredVoice] = voicesAfterNamingSpeakers(
            voices: [], meetingID: "m", previousNames: [1: "Aino"], edits: [1: "Aino", 2: "Mikko", 3: ""],
            voiceprints: [1: voice([1, 0], seconds: 30), 2: voice([0, 1], seconds: 30), 3: voice([1, 1], seconds: 30)], now: now
        )
        #expect(voices.map(\.name) == ["Mikko"])
        let cleared: [RegisteredVoice] = voicesAfterNamingSpeakers(
            voices: voices, meetingID: "m", previousNames: [2: "Mikko"], edits: [2: ""], voiceprints: [:], now: now
        )
        #expect(cleared.isEmpty)
    }

    // Kişinin adı değişince sesi yeni ada taşınır; boş ad değiştirmez.
    @Test func renamingVoiceMovesName() {
        let voices: [RegisteredVoice] = registering(voices: [], name: "Aino", voiceprint: voice([1, 0], seconds: 30), source: "m#1", now: now)
        #expect(renamingVoice(voices: voices, oldName: "aino", newName: " Aino Virtanen ").map(\.name) == ["Aino Virtanen"])
        #expect(renamingVoice(voices: voices, oldName: "Aino", newName: "  ") == voices)
    }

    // Bugün biten toplantılar: bitmiş ve bugün başlamış olanlar, en yeni önce; süren ve dünkü toplantı girmez.
    @Test func meetingsEndedTodayAreNewestFirst() {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki") ?? TimeZone.gmt
        let noon: Date = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
        let event: (String, Double, Double) -> CalendarMeeting = { (id: String, startHour: Double, endHour: Double) -> CalendarMeeting in
            CalendarMeeting(
                id: id, title: id, start: noon.addingTimeInterval(startHour * 3600), end: noon.addingTimeInterval(endHour * 3600), attendees: [], joinURL: nil
            )
        }
        let meetings: [CalendarMeeting] = [event("aamu", -3, -2.5), event("lounas", -1, -0.5), event("nyt", -0.25, 0.5), event("eilen", -20, -19)]
        #expect(meetingsEndedToday(meetings: meetings, now: noon, calendar: calendar).map(\.id) == ["lounas", "aamu"])
    }

    // SKILL.md içe aktarma: geçerli dosya tarif olur, ön bilgisi olmayan ve okunamayan dosyanın nedeni döner.
    @Test func importsSkillFiles() throws {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good: URL = directory.appending(path: "SKILL.md")
        try "---\nname: weekly-summary\ndescription: Haftanın özeti\n---\nKararları listele.".write(to: good, atomically: true, encoding: .utf8)
        let bad: URL = directory.appending(path: "notes.md")
        try "Sadece metin".write(to: bad, atomically: true, encoding: .utf8)
        let missing: URL = directory.appending(path: "missing.md")
        var counter: Int = 0
        let result: SkillImportResult = importSkillRecipes(files: [good, bad, missing]) { () -> String in
            counter += 1
            return "id-\(counter)"
        }
        #expect(result.recipes.map(\.title) == ["Weekly Summary"])
        #expect(result.recipes.first?.id == "id-1")
        #expect(result.failures.count == 2)
        #expect(result.failures.first?.hasPrefix("notes.md: ") == true)
        #expect(skillImportSummary(result: result).split(separator: "\n").count == 3)
        #expect(skillImportSummary(result: SkillImportResult(recipes: [], failures: [])).isEmpty)
    }

    // Tanılamada iPhone'un log kategorileri de kullanıcının anlayacağı alana düşer; bilinmeyen kategori "Uygulama".
    @Test func diagnosticAreasCoverPhoneCategories() {
        #expect(diagnosticErrorArea(code: "PhoneStore.error") == diagnosticErrorArea(code: "Meetings.error"))
        #expect(diagnosticErrorArea(code: "VoiceModel.error") == diagnosticErrorArea(code: "ProcessMeeting.error"))
        #expect(diagnosticErrorArea(code: "Bilinmeyen.fault") == diagnosticErrorArea(code: "App.error"))
    }

    // Gerçek indirme (AINOTEPAD_MODEL_TESTS=1, ~40 MB): boş klasörde model yok; indirme ilerleme bildirir ve sonrasında
    // model ağsız doğrulanır.
    @Test(.enabled(if: modelTestsEnabled)) func downloadsVoiceModelWithProgress() async throws {
        let directory: URL = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try await voiceModelIsDownloaded(modelsDirectory: directory) == false)
        let progress: LockedState<[Double]> = LockedState([])
        try await downloadVoiceModel(modelsDirectory: directory) { (fraction: Double) -> Void in
            progress.withLock { $0.append(fraction) }
        }
        #expect(try await voiceModelIsDownloaded(modelsDirectory: directory))
        #expect(progress.withLock { $0.max() ?? 0 } > 0.99)
        #expect(try directorySize(url: directory) > 10_000_000)
    }

    // Klasör boyutu alt klasörlerle toplanır; olmayan klasör 0.
    @Test func directorySizeSumsFiles() throws {
        let directory: URL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "alt"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 1, count: 10_000).write(to: directory.appending(path: "a.bin"))
        try Data(repeating: 1, count: 10_000).write(to: directory.appending(path: "alt/b.bin"))
        #expect(try directorySize(url: directory) >= 20_000)
        #expect(try directorySize(url: directory.appending(path: "yok")) == 0)
    }
}
