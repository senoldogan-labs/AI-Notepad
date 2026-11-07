import Foundation
import Testing
@testable import AINotepadCore

/// Kararların zamanı, açık konular ve Sor kapsamı: saf dönüşümler ve eski kayıtlarla uyum.
@Suite struct NoteSectionsDataTests {
    // Satır başındaki an ayrılır; anı olmayan (eski) satır aynen kalır; saatli zaman da okunur.
    @Test func anchoredLineSplitsLeadingTimestamp() {
        #expect(anchoredLine(text: "[01:28] Android 25 Kasım'a ertelendi, çünkü çökme oranı %2,1.")
            == AnchoredLine(startSec: 88, text: "Android 25 Kasım'a ertelendi, çünkü çökme oranı %2,1."))
        #expect(anchoredLine(text: "[1:02:05] Bütçe onaylandı.") == AnchoredLine(startSec: 3725, text: "Bütçe onaylandı."))
        #expect(anchoredLine(text: "Bütçe onaylandı.") == AnchoredLine(startSec: nil, text: "Bütçe onaylandı."))
        #expect(anchoredLine(text: "Fiyat [12] dolar.") == AnchoredLine(startSec: nil, text: "Fiyat [12] dolar."))
        #expect(anchoredText(startSec: 88, text: " Karar ") == "[01:28] Karar")
        #expect(anchoredText(startSec: nil, text: "Karar") == "Karar")
    }

    // Yeni şemada kararlar ve açık konular zamanla saklanır; okunamayan zaman satırı zamansız bırakır.
    @Test func parsesDecisionsAndOpenQuestionsWithTimes() throws {
        let note: MeetingNote = try parseMeetingNote(text: """
        {"baslik":"Sürüm","ozet":"iOS önce çıkıyor.","kararlar":[{"zaman":"01:28","karar":"Android 25 Kasım'a ertelendi, çünkü çökme oranı %2,1."},\
        {"zaman":"","karar":"Yük testi dış firmayla."}],"gorevler":[],"acikKonular":[{"zaman":"[03:42]","konu":"Sözleşmede çıkış maddesi var mı bilinmiyor; Selin dönünce sorulacak."}],\
        "sozluk":[],"akis":[]}
        """)
        #expect(note.decisions == ["[01:28] Android 25 Kasım'a ertelendi, çünkü çökme oranı %2,1.", "Yük testi dış firmayla."])
        #expect(note.openQuestions == ["[03:42] Sözleşmede çıkış maddesi var mı bilinmiyor; Selin dönünce sorulacak."])
    }

    // Şemayı uygulamayan sunucunun eski biçimli yanıtı (düz metin kararlar, açık konu yok) da okunur.
    @Test func parsesLegacyShapedResponse() throws {
        let note: MeetingNote = try parseMeetingNote(text: #"{"baslik":"B","ozet":"Ö","kararlar":["A kararı"],"gorevler":[],"sozluk":[]}"#)
        #expect(note.decisions == ["A kararı"])
        #expect(note.openQuestions == nil)
    }

    // Açık konular bölümünden önce saklanan not çözülür, bölümsüz kalır ve aynen geri yazılır.
    @Test func oldStoredNoteDecodesWithoutOpenQuestions() throws {
        let json: String = #"{"title":"T","summary":"S","decisions":["D"],"tasks":[],"glossary":[],"outline":[{"startSec":5,"title":"A","summary":"B"}]}"#
        let note: MeetingNote = try JSONDecoder().decode(MeetingNote.self, from: Data(json.utf8))
        #expect(note.openQuestions == nil)
        #expect(note.outline?.count == 1)
        let again: MeetingNote = try JSONDecoder().decode(MeetingNote.self, from: JSONEncoder().encode(note))
        #expect(again == note)
        // Başlık değişince bölümler korunur.
        let withQuestions: MeetingNote = note.with(openQuestions: ["[00:10] Q"])
        #expect(withQuestions.with(title: "Yeni").openQuestions == ["[00:10] Q"])
    }

    // Çeviride kararların ve açık konuların anı asıl nottan gelir; sayısı farklı çeviri yeniden istenir.
    @Test func sharedNoteKeepsOriginalAnchors() throws {
        let original: MeetingNote = MeetingNote(title: "T", summary: "S", decisions: ["[01:28] Android ertelendi."], tasks: [], glossary: [])
            .with(openQuestions: ["[03:42] Çıkış maddesi bilinmiyor."])
        let translated: MeetingNote = try parseSharedNote(text: """
        {"baslik":"T","ozet":"S","kararlar":[{"zaman":"09:99","karar":"Android postponed."}],"gorevler":[],\
        "acikKonular":[{"zaman":"","konu":"Exit clause unknown."}],"sozluk":[],"akis":[]}
        """, original: original)
        #expect(translated.decisions == ["[01:28] Android postponed."])
        #expect(translated.openQuestions == ["[03:42] Exit clause unknown."])
        #expect(isSharedNoteComplete(shared: translated, original: original))
        #expect(!isSharedNoteComplete(shared: translated.with(openQuestions: []), original: original))
        #expect(throws: LLMError.self) {
            try parseSharedNote(text: #"{"baslik":"T","ozet":"S","kararlar":[{"zaman":"","karar":"x"}],"gorevler":[],"acikKonular":[],"sozluk":[],"akis":[]}"#, original: original)
        }
    }

    // Toplantı süresini aşan an atılır, metin kalır.
    @Test func dropsAnchorsBeyondMeeting() {
        let note: MeetingNote = MeetingNote(title: "T", summary: "S", decisions: ["[01:00] A", "[59:00] B"], tasks: [], glossary: [])
            .with(openQuestions: ["[70:00] C"])
        let checked: MeetingNote = withValidAnchors(note: note, durationSec: 600)
        #expect(checked.decisions == ["[01:00] A", "B"])
        #expect(checked.openQuestions == ["C"])
    }

    // Uzun notun konu akışı her parçaya en az bir bölüm ayırabilsin.
    @Test func outlineRangeGrowsWithParts() {
        #expect(outlineRange(parts: 2) == "5–12")
        #expect(outlineRange(parts: 9) == "9–18")
        #expect(outlineRange(parts: 30) == "20")
    }

    // Açık konular Markdown'a, paylaşım metnine ve Sor parçalarına girer; eski notta bölüm yok.
    @Test func openQuestionsReachExports() {
        let note: MeetingNote = MeetingNote(title: "T", summary: "S", decisions: ["[01:28] D"], tasks: [], glossary: []).with(openQuestions: ["[03:42] Q"])
        let record: MeetingRecord = MeetingRecord(
            id: "20261026-100000", title: "T", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil,
            language: .finnish, status: .done, failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: note, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        #expect(meetingMarkdown(record: record).contains("- [03:42] Q"))
        #expect(shareText(record: record, note: note, language: .english).contains("## Open questions\n\n- [03:42] Q"))
        #expect(archivePassages(records: [record], userLabel: promptUserLabel, speakerWord: "Konuşmacı").first?.text.contains("Açık konu: [03:42] Q") == true)
        let old: MeetingNote = MeetingNote(title: "T", summary: "S", decisions: [], tasks: [], glossary: [])
        #expect(!shareText(record: record, note: old, language: .english).contains("Open questions"))
    }

    // Kapsam: okunan toplantılar tarih sırasıyla; adaylardan hiç parçası okunmayanlar "okunmayan" sayılır.
    @Test func archiveCoverageListsReadAndSkippedMeetings() {
        let passage: (String, Double) -> ArchivePassage = { (meeting: String, day: Double) -> ArchivePassage in
            ArchivePassage(id: "\(meeting)-note", meetingID: meeting, meetingTitle: meeting.uppercased(), meetingDate: Date(timeIntervalSince1970: day * 86_400), kind: .note, startSec: 0, text: "x")
        }
        let read: [ArchivePassage] = [passage("b", 3), passage("a", 1)]
        let coverage: ArchiveCoverage = archiveCoverage(read: read, candidates: read + [passage("c", 5), passage("a", 1)])
        #expect(coverage.read.map(\.id) == ["a", "b"])
        #expect(coverage.skipped.map(\.id) == ["c"])
        #expect(readMeetings(passages: read + [passage("a", 1)]).map(\.id) == ["a", "b"])
    }

    // Kapsam dipnotunun tarih aralığı arayüz dilinde: aynı gün tek tarih, aynı ay "3–6", yıl dışına taşınca yıl da.
    @Test func coverageDateRangeFollowsTheInterfaceLanguage() throws {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Helsinki"))
        let day: (Int, Int, Int) throws -> Date = { (year: Int, month: Int, day: Int) throws -> Date in
            try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10)))
        }
        let meetings: [ArchiveMeetingRef] = [
            ArchiveMeetingRef(id: "a", title: "A", date: try day(2026, 11, 3)), ArchiveMeetingRef(id: "b", title: "B", date: try day(2026, 11, 6)),
        ]
        let now: Date = try day(2026, 11, 7)
        let english: String = try #require(coverageDateRange(meetings: meetings, now: now, locale: Locale(identifier: "en_GB"), calendar: calendar))
        #expect(english.contains("3") && english.contains("6") && english.contains("Nov") && !english.contains("2026"), "\(english)")
        let turkish: String = try #require(coverageDateRange(meetings: meetings, now: now, locale: Locale(identifier: "tr_TR"), calendar: calendar))
        #expect(turkish.contains("Kas") && !turkish.contains("Nov"), "\(turkish)")
        let single: String = try #require(coverageDateRange(meetings: [meetings[1]], now: now, locale: Locale(identifier: "en_GB"), calendar: calendar))
        #expect(single.contains("6") && single.contains("Nov") && !single.contains("3"), "\(single)")
        let lastYear: String = try #require(coverageDateRange(meetings: meetings, now: try day(2027, 1, 2), locale: Locale(identifier: "en_GB"), calendar: calendar))
        #expect(lastYear.contains("2026"), "\(lastYear)")
        #expect(coverageDateRange(meetings: [], now: now, locale: Locale(identifier: "en_GB"), calendar: calendar) == nil)
    }

    // "Bunlara da sor" okunmayan toplantıların en yeni `coverageAskMoreLimit` tanesine, tarih sırasıyla sorar.
    @Test func askMoreTakesTheNewestSkippedMeetings() {
        let skipped: [ArchiveMeetingRef] = (1...12).reversed().map { (index: Int) -> ArchiveMeetingRef in
            ArchiveMeetingRef(id: "m\(index)", title: "M\(index)", date: Date(timeIntervalSince1970: Double(index) * 86_400))
        }
        #expect(askMoreMeetingIDs(skipped: skipped) == (5...12).map { "m\($0)" })
        #expect(askMoreMeetingIDs(skipped: []).isEmpty)
    }
}
