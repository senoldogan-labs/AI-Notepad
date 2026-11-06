import Foundation
import Testing
@testable import AINotepadCore

@Suite struct FollowUpEmailTests {
    private let note: MeetingNote = MeetingNote(
        title: "Ürün haftalığı", summary: "Beta tarihi konuşuldu; Konuşmacı 2 sürüm notlarını üstlendi.",
        decisions: ["Beta 14 Kasım'da açılır."],
        tasks: [
            NoteTask(owner: "Konuşmacı 2", description: "Sürüm notlarını yaz", dueDate: "Cuma", isMine: false),
            NoteTask(owner: "Sen", description: "Fiyat tablosunu gönder", dueDate: nil, isMine: true),
        ],
        glossary: [GlossaryEntry(term: "GA", meaning: "Genel kullanıma açılış")]
    ).with(language: .turkish)

    // İstek yalnızca notu taşır (transkript yok): adlar uygulanır, kullanıcının görevinde sahibi kullanıcının adı, tarih
    // verilen saat diliminde gün, katılımcılar listelenir; çıktı küçük sınırlı, görselsiz ve şemalıdır.
    @Test func requestCarriesNamedNoteOnly() throws {
        let start: Date = Date(timeIntervalSince1970: 1_794_700_800)  // 2026-11-15T00:00:00Z
        let meeting: MeetingRecord = record(id: "m", startedAt: start, status: .done, audioDeleted: false)
            .with(speakerNames: [2: "Aino"])
            .with(attendees: ["Aino Virtanen", "Mikko"])
            .with(note: note)
        let request: LLMRequest = meetingFollowUpEmailRequest(
            record: meeting, note: note, userName: "Şenol", profile: .empty, language: .english, timeZone: try #require(TimeZone(identifier: "America/New_York"))
        )
        #expect(request.purpose == .followUpEmail)
        #expect(request.tier == .smart)
        #expect(request.images.isEmpty)
        #expect(request.maxTokens <= 16000)
        #expect(request.jsonSchema == followUpEmailSchema)
        #expect(request.userText.contains("Aino sürüm notlarını üstlendi"))
        #expect(request.userText.contains("- Aino | Sürüm notlarını yaz | Cuma"))
        #expect(request.userText.contains("- Şenol | Fiyat tablosunu gönder | "))
        #expect(!request.userText.contains("Sen |"))
        #expect(request.userText.contains("tarih: 2026-11-14"))
        #expect(request.userText.contains("katılımcılar: Aino Virtanen, Mikko"))
        #expect(request.userText.contains("- Beta 14 Kasım'da açılır."))
        // Sözlük e-postaya girmez.
        #expect(!request.userText.contains("Genel kullanıma açılış"))
        #expect(request.system.contains("English"))
        #expect(request.system.contains("(Şenol)"))
    }

    // Adı bilinmeyen kullanıcıda kapanışa ad yazılmaz; katılımcısız toplantıda katılımcılar bilinmiyor.
    @Test func requestWithoutUserNameOrAttendees() throws {
        let request: LLMRequest = followUpEmailRequest(
            note: note, startedAt: Date(timeIntervalSince1970: 0), attendees: [], userName: " ", profile: .empty, language: .finnish,
            timeZone: try #require(TimeZone(identifier: "UTC"))
        )
        #expect(request.system.contains("Kapanışa ad yazma"))
        #expect(request.userText.contains("katılımcılar: (bilinmiyor)"))
        #expect(request.userText.contains("- Sen | Fiyat tablosunu gönder | "))
        #expect(request.system.contains("Finnish"))
    }

    // Yanıt: konu tek satıra iner, boşluklar kırpılır; boş konu ya da gövde yeniden istenir, şemasız yanıt bozuktur.
    @Test func parsesDraft() throws {
        let draft: FollowUpEmailDraft = try parseFollowUpEmail(text: #"{"konu":" Product weekly:\nnext steps ","govde":"Hi all,\n\n- Beta opens 14 November.\n"}"#)
        #expect(draft == FollowUpEmailDraft(subject: "Product weekly: next steps", body: "Hi all,\n\n- Beta opens 14 November."))
        #expect(try parseFollowUpEmail(text: "```json\n{\"konu\":\"A\",\"govde\":\"B\"}\n```") == FollowUpEmailDraft(subject: "A", body: "B"))
        #expect(throws: LLMError.empty) { try parseFollowUpEmail(text: #"{"konu":"A","govde":"  "}"#) }
        #expect(throws: LLMError.empty) { try parseFollowUpEmail(text: #"{"konu":"","govde":"B"}"#) }
        #expect(throws: LLMError.self) { try parseFollowUpEmail(text: "Subject: A") }
    }

    // mailto: alıcılar virgülle, konu ve gövde yüzde kodlu (& ve = değer içinde kalır), satır sonları CRLF.
    @Test func buildsMailtoURL() throws {
        let draft: FollowUpEmailDraft = FollowUpEmailDraft(subject: "Q&A = next steps", body: "Hi,\n- Beta: 14.11.\nŞenol")
        let url: URL = try #require(followUpMailtoURL(draft: draft, recipients: ["aino@example.fi", "mikko+work@example.com"]))
        #expect(url.absoluteString == "mailto:aino@example.fi,mikko+work@example.com?subject=Q%26A%20%3D%20next%20steps&body=Hi%2C%0D%0A-%20Beta%3A%2014.11.%0D%0A%C5%9Eenol")
        #expect(try #require(followUpMailtoURL(draft: draft, recipients: [])).absoluteString.hasPrefix("mailto:?subject="))
    }

    // Takvim katılımcısının adresi: yalnız geçerli mailto; tekrarlar tek kalır.
    @Test func attendeeAddresses() throws {
        #expect(attendeeEmailAddress(url: try #require(URL(string: "mailto:aino.virtanen@example.fi"))) == "aino.virtanen@example.fi")
        #expect(attendeeEmailAddress(url: try #require(URL(string: "MAILTO:Mikko@Example.com?subject=x"))) == "Mikko@Example.com")
        #expect(attendeeEmailAddress(url: try #require(URL(string: "urn:uuid:1234"))) == nil)
        #expect(attendeeEmailAddress(url: try #require(URL(string: "mailto:not-an-address"))) == nil)
        #expect(uniqueEmailAddresses(addresses: ["a@x.fi", "A@X.fi", "b@x.fi"]) == ["a@x.fi", "b@x.fi"])
    }

    // Takvim toplantısı kimliği başlangıcı taşır; kimlikteki tire etkinlik kimliğini bozmaz.
    @Test func calendarMeetingIDRoundTrip() {
        let start: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let id: String = calendarMeetingID(eventIdentifier: "ABC-123:DEF", start: start)
        #expect(id == "ABC-123:DEF-1800000000")
        #expect(calendarMeetingStart(id: id) == start)
        #expect(calendarMeetingStart(id: "no-start-here") == nil)
    }
}
