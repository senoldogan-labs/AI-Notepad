import Foundation
import Testing
@testable import AINotepadCore

/// Transkripti verilen toplantı (canlı bölümler; çevirileri anahtarla).
private func meeting(id: String, title: String, segments: [(startSec: Double, text: String)], translations: [String: String]) -> MeetingRecord {
    MeetingRecord(
        id: id, title: title, startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, language: .english, status: .done,
        failureMessage: nil,
        liveSegments: segments.enumerated().map { (item: (offset: Int, element: (startSec: Double, text: String))) -> StoredSegment in
            StoredSegment(key: "others-\(item.offset)", speaker: .others, person: 1, startSec: item.element.startSec, endSec: item.element.startSec + 5, text: item.element.text, words: nil)
        },
        finalSegments: [], translations: translations, speakerNames: [1: "Aino"], note: nil, audioDeleted: false, engine: .cloud, notice: nil,
        meNeedsFinalPass: nil
    )
}

@Suite struct MeetingSearchCacheTests {
    private let records: [MeetingRecord] = [
        meeting(id: "a", title: "Product weekly", segments: [(0, "Good morning everyone."), (62, "The beta opens on Friday. Pricing stays the same.")], translations: [:]),
        meeting(id: "b", title: "Işık review", segments: [(10, "Nothing here.")], translations: ["others-0": "Burada fiyat yok."]),
    ]

    @Test func transcriptHitCarriesSentenceAndTime() {
        let hits: [MeetingSearchHit] = searchMeetings(index: .empty, records: records, query: "pricing")
        #expect(hits == [MeetingSearchHit(meetingID: "a", field: .transcript, snippet: "Pricing stays the same.", startSec: 62)])
    }

    @Test func titleMatchIsCaseAccentAndDotlessIInsensitive() {
        let hits: [MeetingSearchHit] = searchMeetings(index: .empty, records: records, query: "ISIK")
        #expect(hits.map(\.meetingID) == ["b"])
        #expect(hits.first?.field == .title)
    }

    @Test func translationMatchUsesSegmentTime() {
        let hits: [MeetingSearchHit] = searchMeetings(index: .empty, records: records, query: "fiyat")
        #expect(hits == [MeetingSearchHit(meetingID: "b", field: .transcript, snippet: "Burada fiyat yok.", startSec: 10)])
    }

    @Test func emptyQueryFindsNothing() {
        #expect(searchMeetings(index: .empty, records: records, query: "  ").isEmpty)
    }

    @Test func indexReusesUnchangedAndRefoldsChangedMeetings() {
        let index: MeetingSearchIndex = refreshedSearchIndex(index: .empty, records: records)
        #expect(index.count == 2)
        let changed: MeetingRecord = meeting(id: "a", title: "Product weekly", segments: [(0, "Roadmap only.")], translations: [:])
        let refreshed: MeetingSearchIndex = refreshedSearchIndex(index: index, records: [changed])
        // Silinen toplantı dizinden çıkar, değişen yeniden katlanır.
        #expect(refreshed.count == 1)
        #expect(searchMeetings(index: refreshed, records: [changed], query: "pricing").isEmpty)
        #expect(searchMeetings(index: refreshed, records: [changed], query: "roadmap").map(\.meetingID) == ["a"])
    }

    @Test func searchMatchesFilterMeetings() {
        // Önbellekli arama ile listelerin süzgeci aynı toplantıları bulur.
        for query in ["pricing", "aino", "fiyat", "review", "nothing at all"] {
            #expect(searchMeetings(index: .empty, records: records, query: query).map(\.meetingID) == filterMeetings(records: records, query: query).map(\.id))
        }
    }

    @Test func cacheSearchesOffMain() async {
        let cache: MeetingSearchCache = MeetingSearchCache()
        let hits: [MeetingSearchHit] = await cache.search(records: records, query: "beta")
        #expect(hits.map(\.meetingID) == ["a"])
    }

    @Test func longSentenceIsShortened() {
        let long: String = String(repeating: "word ", count: 60) + "needle."
        let sentence: String? = matchingSentence(text: long, needle: "needle")
        #expect(sentence?.count == searchSnippetLength)
        #expect(sentence?.hasSuffix("…") == true)
    }

    @Test func stampChangesWhenTranscriptGrows() {
        let first: MeetingSearchStamp = searchStamp(record: records[0])
        let grown: MeetingRecord = meeting(id: "a", title: "Product weekly", segments: [(0, "a"), (1, "b"), (2, "c")], translations: [:])
        #expect(first != searchStamp(record: grown))
        #expect(first == searchStamp(record: records[0]))
    }

    @Test func transcriptFindMatchesParagraphIndices() {
        #expect(searchMatchingIndices(texts: ["Hyvää huomenta", "Pricing", "PRICİNG later"], query: "pricing") == [1, 2])
        #expect(searchMatchingIndices(texts: ["x"], query: "").isEmpty)
    }
}

@Suite struct AudioRetentionTests {
    @Test func neverDeleteKeepsEveryAudio() {
        let old: MeetingRecord = record(id: "old", startedAt: Date(timeIntervalSince1970: 0), status: .done, audioDeleted: false)
        #expect(effectiveAudioRetentionDays(setting: audioRetentionNever) == nil)
        #expect(audioDeletedByRetentionChange(records: [old], now: Date(), setting: audioRetentionNever).isEmpty)
    }

    @Test func shorterRetentionListsAudioDeletedNow() {
        let now: Date = Date(timeIntervalSince1970: 1_800_000_000)
        let tenDaysAgo: MeetingRecord = record(id: "ten", startedAt: now.addingTimeInterval(-10 * 86_400), status: .done, audioDeleted: false)
        #expect(audioDeletedByRetentionChange(records: [tenDaysAgo], now: now, setting: 7) == ["ten"])
        #expect(audioDeletedByRetentionChange(records: [tenDaysAgo], now: now, setting: 30).isEmpty)
    }

    @Test func settingIsClampedExceptNever() {
        #expect(effectiveAudioRetentionDays(setting: 1) == 7)
        #expect(effectiveAudioRetentionDays(setting: 9_999) == 365)
        #expect(audioRetentionChoices.last == audioRetentionNever)
    }
}

@Suite struct ConsentNoticeTests {
    @Test func meetingLanguageThenEnglish() {
        #expect(consentNoticeSentences(language: .finnish) == [
            "Hei! Tallennan tämän kokouksen, jotta voin tehdä siitä muistiinpanot.", "Hi! I'm recording this meeting so I can take notes.",
        ])
        #expect(consentNoticeSentences(language: .english) == ["Hi! I'm recording this meeting so I can take notes."])
        // Tabloda olmayan dilde yalnız İngilizce.
        #expect(consentNoticeSentences(language: .thai) == ["Hi! I'm recording this meeting so I can take notes."])
    }
}

@Suite struct LanguageNameTests {
    @Test func standaloneNameIsCapitalized() {
        #expect(capitalizedLanguageName(name: "englanti", locale: Locale(identifier: "fi")) == "Englanti")
        #expect(capitalizedLanguageName(name: "ingilizce", locale: Locale(identifier: "tr")) == "İngilizce")
        #expect(capitalizedLanguageName(name: "", locale: Locale(identifier: "en")) == "")
    }
}

@Suite struct LoadFailureMessageTests {
    @Test func corruptMeetingReasonIsUserFacing() throws {
        let sessions: URL = try temporaryDirectory()
        let bad: URL = sessions.appending(path: "20261026-110000", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{bozuk".utf8).write(to: bad.appending(path: "meeting.json"))
        let failure: MeetingLoadFailure? = loadMeetings(sessionsDirectory: sessions).failures.first
        // Ham hata dökümü (`String(describing:)`) değil, arayüz metni.
        #expect(failure?.reason.contains("DecodingError") == false)
        #expect(failure?.reason.contains("dataCorrupted") == false)
    }
}
