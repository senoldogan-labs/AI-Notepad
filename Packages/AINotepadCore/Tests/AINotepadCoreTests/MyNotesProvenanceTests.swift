import Foundation
import Testing
@testable import AINotepadCore

@Suite struct MyNotesProvenanceTests {
    /// A note answer with quotes from the user's own notes: one summary sentence, one decision (quoted with its anchor
    /// and a different case), a quote that matches no line, and a one-word quote too short to mark by containment.
    private let answer: String = #"""
    {"baslik":"Bütçe","ozet":"Pilot iki hafta sürecek. Reklam bütçesi araştırmaya kaydırıldı.",
     "kararlar":[{"zaman":"01:10","karar":"Pilot Nordia'nın güvenlik incelemesinden sonra başlar"},{"zaman":"","karar":"Fiyatlar değişmez"}],
     "gorevler":[],"acikKonular":[{"zaman":"02:00","konu":"Pilot ekibi kimlerden oluşacak"}],"sozluk":[],"akis":[],
     "benimNotlarimdan":["Reklam bütçesi araştırmaya kaydırıldı.","[01:10] pilot nordia'nın güvenlik incelemesinden sonra başlar",
       "Toplantıda olmayan bir satır","Pilot"]}
    """#

    @Test func parserMarksOnlyRealLinesWithTheirOwnText() throws {
        let note: MeetingNote = try parseMeetingNote(text: answer)
        #expect(note.myNotesLines == ["Reklam bütçesi araştırmaya kaydırıldı.", "Pilot Nordia'nın güvenlik incelemesinden sonra başlar"])
        #expect(noteLineOrigin(note: note, line: "Reklam bütçesi araştırmaya kaydırıldı.") == .myNotes)
        #expect(noteLineOrigin(note: note, line: "Pilot iki hafta sürecek.") == .added)
        #expect(noteLineOrigin(note: note, line: "Fiyatlar değişmez") == .added)
    }

    @Test func noteWithoutQuotesStaysUnmarked() throws {
        let note: MeetingNote = try parseMeetingNote(text: #"{"baslik":"B","ozet":"Bir cümle.","kararlar":[],"gorevler":[],"sozluk":[]}"#)
        #expect(note.myNotesLines == nil)
        #expect(noteLineOrigin(note: note, line: "Bir cümle.") == .unmarked)
        let unmatched: MeetingNote = withMyNotesQuotes(note: note, quotes: ["Başka bir şey"])
        #expect(unmatched.myNotesLines == nil)
    }

    @Test func quoteMayCoverTwoSentencesOrPartOfOne() {
        let note: MeetingNote = MeetingNote(
            title: "B", summary: "Pilot iki hafta sürecek. Reklam bütçesi araştırmaya kaydırıldı.", decisions: [], tasks: [], glossary: []
        )
        let both: MeetingNote = withMyNotesQuotes(note: note, quotes: ["Pilot iki hafta sürecek. Reklam bütçesi araştırmaya kaydırıldı."])
        #expect(both.myNotesLines == ["Pilot iki hafta sürecek.", "Reklam bütçesi araştırmaya kaydırıldı."])
        let part: MeetingNote = withMyNotesQuotes(note: note, quotes: ["bütçesi araştırmaya kaydırıldı"])
        #expect(part.myNotesLines == ["Reklam bütçesi araştırmaya kaydırıldı."])
        // A line that only sits inside a longer quoted sentence stays the model's.
        let decided: MeetingNote = MeetingNote(title: "B", summary: "Kısa.", decisions: ["Fiyatlar beta boyunca değişmez"], tasks: [], glossary: [])
        let wide: MeetingNote = withMyNotesQuotes(note: decided, quotes: ["Pilot sürer ve fiyatlar beta boyunca değişmez, reklam azalır."])
        #expect(wide.myNotesLines == nil)
    }

    @Test func requestAsksForQuotesOnlyWithOwnNotes() throws {
        let segments: [StoredSegment] = [stored("final-0", .others, 1, 5, "Pilot iki hafta.")]
        let plain: LLMRequest = try #require(meetingNoteRequest(
            segments: segments, speakerNames: [:], userName: "Ada", profile: .empty, template: .general, myNotes: " ", language: .turkish, screens: []
        ))
        #expect(plain.jsonSchema == meetingNoteSchema)
        #expect(!plain.system.contains(myNotesQuotesField))
        let withNotes: LLMRequest = try #require(meetingNoteRequest(
            segments: segments, speakerNames: [:], userName: "Ada", profile: .empty, template: .general, myNotes: "- pilot", language: .turkish, screens: []
        ))
        #expect(withNotes.jsonSchema == meetingNoteSchemaWithMyNotes)
        #expect(withNotes.system.contains(myNotesQuotesField))
        // The quotes come last, after the lines they name; the on-device model reads the schema too.
        guard case .object(let properties) = try parseJSONSchema(text: meetingNoteSchemaWithMyNotes) else {
            Issue.record("not şeması nesne değil")
            return
        }
        #expect(properties.last?.name == myNotesQuotesField)
        #expect(properties.last?.node == .array(item: .string(choices: nil)))
        let overview: LLMRequest = noteOverviewRequest(
            state: .empty, userName: "Ada", profile: .empty, template: .general, myNotes: "- pilot", language: .turkish, screens: []
        )
        #expect(overview.jsonSchema == noteOverviewSchemaWithMyNotes)
    }

    @Test func marksFollowNamingCleaningEditsAndTranslation() throws {
        let note: MeetingNote = MeetingNote(
            title: "B", summary: "Konuşmacı 2 bütçeyi araştırmaya kaydırdı. Pilot sürüyor.", decisions: ["[01:10] Fiyatlar değişmez"], tasks: [], glossary: []
        )
        .with(myNotesLines: ["Konuşmacı 2 bütçeyi araştırmaya kaydırdı.", "Fiyatlar değişmez"])
        // Speaker names change the shown text: the marks are named the same way.
        let named: MeetingNote = namedNote(note: note, speakerNames: [2: "Elif"], userName: "Ada")
        #expect(noteLineOrigin(note: named, line: "Elif bütçeyi araştırmaya kaydırdı.") == .myNotes)
        // An edit keeps the marks of lines it left unchanged; a rewritten line loses its mark.
        let edited: MeetingNote = MeetingNote(
            title: "B", summary: "Elif'in bütçe kararı. Pilot sürüyor.", decisions: ["[01:10] Fiyatlar değişmez"], tasks: [], glossary: []
        )
        #expect(withCarriedMyNotesLines(old: note, new: edited).myNotesLines == ["Fiyatlar değişmez"])
        // A translation keeps the marks by position.
        let translated: MeetingNote = try parseSharedNote(
            text: #"{"baslik":"B","ozet":"Speaker 2 moved the budget to research. The pilot goes on.","kararlar":[{"zaman":"01:10","karar":"Prices stay"}],"gorevler":[],"acikKonular":[],"sozluk":[],"akis":[]}"#,
            original: note
        )
        #expect(translated.myNotesLines == ["Speaker 2 moved the budget to research.", "Prices stay"])
    }

    @Test func oldNoteJSONDecodesAndNewFieldIsOptional() throws {
        let old: MeetingNote = try JSONDecoder().decode(
            MeetingNote.self, from: Data(#"{"title":"B","summary":"S.","decisions":[],"tasks":[],"glossary":[]}"#.utf8)
        )
        #expect(old.myNotesLines == nil)
        let encoded: String = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        #expect(!encoded.contains("myNotesLines"))
        let marked: MeetingNote = old.with(myNotesLines: ["S."])
        let roundTrip: MeetingNote = try JSONDecoder().decode(MeetingNote.self, from: JSONEncoder().encode(marked))
        #expect(roundTrip == marked)
    }
}
