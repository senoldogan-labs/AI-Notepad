import CryptoKit
import Foundation
import Testing
@testable import AINotepadCore

/// Shared Swift ↔ web test vector: the web share page decrypts the same file (`web/scripts/share-crypto.test.ts`).
/// Rewrite it with `AINOTEPAD_WRITE_SHARE_VECTOR=1 swift test --filter NoteShareVectorTests` after a format change.
private let vectorURL: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/NoteShareVector.json")

/// The vector file: a sealed note and everything needed to open it.
private struct NoteShareVector: Codable {
    let shareId: String
    let key: String
    let link: String
    let blobBase64: String
    let payload: SharedNotePayload
}

/// Fixed secret of the vector (key bytes 0…31, id bytes 0…15).
private func vectorSecret() throws -> NoteShareSecret {
    try noteShareSecret(shareID: base64URLEncoded(Data(0..<16)), keyText: base64URLEncoded(Data(0..<32)))
}

/// A payload with every section, non-Latin text and markup that the page must show as plain text.
private let vectorPayload: SharedNotePayload = SharedNotePayload(
    v: 1, lang: "tr", rtl: false, title: "Bütçe toplantısı <img src=x onerror=alert(1)>", subtitle: "6 Kasım 2026 10:00 · 32 dk",
    headings: SharedNoteHeadings(
        summary: "Özet", outline: "Konu akışı", decisions: "Kararlar", openQuestions: "Açık konular", tasks: "Görevler", glossary: "Sözlük",
        transcript: "Transkript"
    ),
    summary: "Pazarlama bütçesi %10 artacak. <script>alert('x')</script> 日本語 · עברית 🎉",
    outline: [SharedOutlineItem(time: "00:05", title: "Bütçe", summary: "Rakamlar konuşuldu.")],
    decisions: ["Bütçe artırılacak.", "<b>kalın değil</b>"],
    openQuestions: ["Ajans seçilecek mi?"],
    tasks: [SharedTask(owner: "Senol", description: "Sunumu hazırlamak", due: "Perşembe"), SharedTask(owner: "Aino", description: "Teklif", due: nil)],
    glossary: [SharedGlossaryEntry(term: "CAC", meaning: "Müşteri edinme maliyeti")],
    transcript: [SharedTranscriptParagraph(time: "00:01", speaker: "Senol", text: "Başlayalım. javascript:alert(1)")]
)

@Suite struct NoteShareTests {
    // The payload carries the note's sections in the sender's language, formatted times, task owners and dates, and the
    // transcript only when asked for.
    @Test func payloadCarriesTheNoteSections() throws {
        let note: MeetingNote = MeetingNote(
            title: "Bütçe toplantısı", summary: "Pazarlama bütçesi artacak.", decisions: ["Bütçe artırılacak."],
            tasks: [NoteTask(owner: "Senol", description: "Sunumu hazırlamak", dueDate: "Perşembe", isMine: true)],
            glossary: [GlossaryEntry(term: "CAC", meaning: "Edinme maliyeti")]
        )
        .with(outline: [OutlineItem(startSec: 65, title: "Bütçe", summary: "Rakamlar.")])
        .with(openQuestions: ["Ajans?"])
        let record: MeetingRecord = MeetingRecord(
            id: "s1", title: "Toplantı", startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: Date(timeIntervalSince1970: 1_800_001_920),
            language: .finnish, status: .done, failureMessage: nil, liveSegments: [],
            finalSegments: [stored("final-0", .others, 1, 3, "Budjetti on 10 000 euroa.")], translations: [:], speakerNames: [1: "Aino"],
            note: note, audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
        let german: SharedNotePayload = sharedNotePayload(record: record, note: note, language: .german, transcript: nil)
        #expect(german.v == 1 && german.lang == "de" && !german.rtl)
        #expect(german.headings.decisions == "Entscheidungen")
        #expect(german.subtitle.hasSuffix(" · 32 min"))
        #expect(german.title == "Bütçe toplantısı" && german.summary == "Pazarlama bütçesi artacak.")
        #expect(german.outline == [SharedOutlineItem(time: "01:05", title: "Bütçe", summary: "Rakamlar.")])
        #expect(german.decisions == ["Bütçe artırılacak."] && german.openQuestions == ["Ajans?"])
        #expect(german.tasks == [SharedTask(owner: "Senol", description: "Sunumu hazırlamak", due: "Perşembe")])
        #expect(german.glossary == [SharedGlossaryEntry(term: "CAC", meaning: "Edinme maliyeti")])
        #expect(german.transcript == nil)

        let withTranscript: SharedNotePayload = sharedNotePayload(record: record, note: note, language: nil, transcript: transcriptParagraphs(record: record))
        #expect(withTranscript.transcript == [SharedTranscriptParagraph(time: "00:03", speaker: "Aino", text: "Budjetti on 10 000 euroa.")])
        #expect(sharedNotePayload(record: record, note: note, language: .arabic, transcript: nil).rtl)
    }

    // Sealing and opening round-trips; the blob starts with the format marker and is never the plain JSON.
    @Test func sealAndOpenRoundTrip() throws {
        let secret: NoteShareSecret = newNoteShareSecret()
        #expect(isNoteShareID(secret.shareID) && secret.keyText.count == 43)
        let blob: Data = try sealNoteShare(payload: vectorPayload, secret: secret, nonce: nil)
        #expect(blob.prefix(4) == Data("GSS1".utf8))
        #expect(blob.range(of: Data("Pazarlama".utf8)) == nil)
        #expect(try openNoteShare(blob: blob, secret: secret) == vectorPayload)
        // Two shares of the same note: different ids, keys and ciphertexts.
        let other: NoteShareSecret = newNoteShareSecret()
        #expect(other.shareID != secret.shareID && other.keyText != secret.keyText)
        #expect(try sealNoteShare(payload: vectorPayload, secret: other, nonce: nil) != blob)
    }

    // A wrong key, a blob moved to another share id, a flipped byte or a foreign format never open.
    @Test func tamperedOrMovedBlobsDoNotOpen() throws {
        let secret: NoteShareSecret = newNoteShareSecret()
        let blob: Data = try sealNoteShare(payload: vectorPayload, secret: secret, nonce: nil)
        #expect(throws: NoteShareError.authenticationFailed) { try openNoteShare(blob: blob, secret: newNoteShareSecret()) }
        let moved: NoteShareSecret = try noteShareSecret(shareID: newNoteShareSecret().shareID, keyText: secret.keyText)
        #expect(throws: NoteShareError.authenticationFailed) { try openNoteShare(blob: blob, secret: moved) }
        var flipped: Data = blob
        flipped[flipped.count - 20] ^= 0x01
        #expect(throws: NoteShareError.authenticationFailed) { try openNoteShare(blob: flipped, secret: secret) }
        #expect(throws: NoteShareError.malformedBlob(byteCount: 10)) { try openNoteShare(blob: Data("GSY1012345".utf8), secret: secret) }
    }

    // The link keeps the key in the fragment only; parsing gives the same secret back and rejects broken links.
    @Test func linkCarriesKeyInFragment() throws {
        let secret: NoteShareSecret = try vectorSecret()
        let link: URL = noteShareLink(siteOrigin: try #require(URL(string: "https://gistsmith.com")), secret: secret)
        #expect(link.absoluteString == "https://gistsmith.com/s#AAECAwQFBgcICQoLDA0ODw.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        #expect(link.query() == nil && link.path() == "/s")
        #expect(try noteShareSecret(link: link) == secret)
        let local: URL = noteShareLink(siteOrigin: try #require(URL(string: "http://localhost:8788")), secret: secret)
        #expect(local.absoluteString.hasPrefix("http://localhost:8788/s#"))
        for broken in ["https://gistsmith.com/s", "https://gistsmith.com/s#abc.def", "https://gistsmith.com/x#AAECAwQFBgcICQoLDA0ODw.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"] {
            #expect(throws: NoteShareError.invalidLink) { try noteShareSecret(link: try #require(URL(string: broken))) }
        }
    }

    // A note too big for the server (a very long transcript) is refused before upload.
    @Test func oversizedNoteIsRefused() throws {
        var generator: SystemRandomNumberGenerator = SystemRandomNumberGenerator()
        // Random letters compress to ~75%, so twice the cap seals to more than the cap.
        let noise: String = String((0..<(noteShareMaxBytes * 2)).map { _ in Character(UnicodeScalar(UInt8.random(in: 0x41...0x7A, using: &generator))) })
        let big: SharedNotePayload = SharedNotePayload(
            v: 1, lang: "en", rtl: false, title: "t", subtitle: "s", headings: vectorPayload.headings, summary: "x", outline: [], decisions: [],
            openQuestions: [], tasks: [], glossary: [], transcript: [SharedTranscriptParagraph(time: "00:00", speaker: "A", text: noise)]
        )
        #expect {
            try sealNoteShare(payload: big, secret: newNoteShareSecret(), nonce: nil)
        } throws: { (error: any Error) -> Bool in
            if case NoteShareError.tooLarge = error { return true }
            return false
        }
    }

    // The device's link book: add, keep only the server's live links, remove, and list a meeting's links newest first.
    @Test func linkBookKeepsLiveLinksPerMeeting() throws {
        let link: URL = try #require(URL(string: "https://gistsmith.com/s#a.b"))
        let older: NoteShareLinkEntry = NoteShareLinkEntry(
            shareID: "a", meetingID: "m1", link: link, createdAt: Date(timeIntervalSince1970: 10), expiresAt: Date(timeIntervalSince1970: 99), includesTranscript: false
        )
        let newer: NoteShareLinkEntry = NoteShareLinkEntry(
            shareID: "b", meetingID: "m1", link: link, createdAt: Date(timeIntervalSince1970: 20), expiresAt: Date(timeIntervalSince1970: 99), includesTranscript: true
        )
        let otherMeeting: NoteShareLinkEntry = NoteShareLinkEntry(
            shareID: "c", meetingID: "m2", link: link, createdAt: Date(timeIntervalSince1970: 30), expiresAt: Date(timeIntervalSince1970: 99), includesTranscript: false
        )
        let book: NoteShareLinks = [older, newer, otherMeeting].reduce(NoteShareLinks.empty) { addingNoteShareLink(links: $0, entry: $1) }
        #expect(noteShareLinks(links: book, meetingID: "m1").map(\.shareID) == ["b", "a"])
        #expect(keepingLiveNoteShareLinks(links: book, liveShareIDs: ["b", "c"]).entries.map(\.shareID) == ["b", "c"])
        #expect(removingNoteShareLink(links: book, shareID: "b").entries.map(\.shareID) == ["a", "c"])

        let directory: URL = FileManager.default.temporaryDirectory.appending(path: "note-share-links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file: URL = directory.appending(path: "NoteShareLinks.json")
        #expect(try loadNoteShareLinks(url: file) == .empty)
        try saveNoteShareLinks(links: book, url: file)
        #expect(try loadNoteShareLinks(url: file) == book)
        let permissions: Int = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int)
        #expect(permissions == 0o600)
    }
}

@Suite struct NoteShareVectorTests {
    // The committed vector opens to the expected payload; sealing it again with the same key and nonce opens too.
    // The web page opens the same file (web/scripts/share-crypto.test.ts), so the two implementations agree.
    @Test func vectorOpens() throws {
        let secret: NoteShareSecret = try vectorSecret()
        if ProcessInfo.processInfo.environment["AINOTEPAD_WRITE_SHARE_VECTOR"] == "1" {
            let nonce: AES.GCM.Nonce = try AES.GCM.Nonce(data: Data(100..<112))
            let blob: Data = try sealNoteShare(payload: vectorPayload, secret: secret, nonce: nonce)
            let vector: NoteShareVector = NoteShareVector(
                shareId: secret.shareID, key: secret.keyText,
                link: noteShareLink(siteOrigin: try #require(URL(string: "https://gistsmith.com")), secret: secret).absoluteString,
                blobBase64: blob.base64EncodedString(), payload: vectorPayload
            )
            let encoder: JSONEncoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try (encoder.encode(vector) + Data("\n".utf8)).write(to: vectorURL, options: .atomic)
        }
        let vector: NoteShareVector = try JSONDecoder().decode(NoteShareVector.self, from: Data(contentsOf: vectorURL))
        #expect(vector.shareId == secret.shareID && vector.key == secret.keyText)
        #expect(vector.payload == vectorPayload)
        let blob: Data = try #require(Data(base64Encoded: vector.blobBase64))
        #expect(try openNoteShare(blob: blob, secret: try noteShareSecret(link: try #require(URL(string: vector.link)))) == vectorPayload)
    }
}
