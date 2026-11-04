import Foundation
import Testing
@testable import AINotepadCore

/// Canlı bölüm (yüz yüze kayıt: "Diğerleri").
private func segment(index: Int, text: String, isFinal: Bool) -> LiveSegment {
    LiveSegment(
        id: SegmentID(speaker: .others, index: index), startSec: Double(index * 5), endSec: Double(index * 5 + 4), text: text, isFinal: isFinal,
        failureMessage: nil, person: nil
    )
}

/// Saklanan "Diğerleri" bölümü.
private func stored(key: String, text: String) -> StoredSegment {
    StoredSegment(key: key, speaker: .others, person: 1, startSec: 0, endSec: 4, text: text, words: nil)
}

/// Toplantı kaydı (yalnızca kurtarma ve not denemesi için gereken alanlarla).
private func record(
    id: String, startedAt: Double, status: MeetingStatus, live: [StoredSegment], final: [StoredSegment], note: MeetingNote?, notice: String?
) -> MeetingRecord {
    MeetingRecord(
        id: id, title: id, startedAt: Date(timeIntervalSince1970: startedAt), endedAt: nil, language: nil, status: status, failureMessage: nil,
        liveSegments: live, finalSegments: final, translations: [:], speakerNames: [:], note: note, audioDeleted: false,
        engine: .cloud, notice: notice, meNeedsFinalPass: nil
    )
}

@Suite struct BackgroundRecordingTests {
    // Arka planda geçici bölümler bekletilir (bölüm başına en yenisi); kesin bölüm hemen uygulanır ve bekleyen geçici
    // hâlini düşürür; diğer olaylar hemen uygulanır.
    @Test func backgroundDefersOnlyPartials() {
        let first: BackgroundLiveRouting = routingLiveEvent(event: .segment(segment(index: 0, text: "Merhaba", isFinal: false)), deferredPartials: [:], isInBackground: true)
        #expect(!first.appliesNow)
        let newer: LiveSegment = segment(index: 0, text: "Merhaba herkes", isFinal: false)
        let second: BackgroundLiveRouting = routingLiveEvent(event: .segment(newer), deferredPartials: first.deferredPartials, isInBackground: true)
        #expect(!second.appliesNow)
        #expect(second.deferredPartials == [newer.id: newer])
        let final: BackgroundLiveRouting = routingLiveEvent(
            event: .segment(segment(index: 0, text: "Merhaba herkese.", isFinal: true)), deferredPartials: second.deferredPartials, isInBackground: true
        )
        #expect(final.appliesNow)
        #expect(final.deferredPartials.isEmpty)
        let locked: BackgroundLiveRouting = routingLiveEvent(event: .languageLocked(.turkish), deferredPartials: second.deferredPartials, isInBackground: true)
        #expect(locked.appliesNow)
        #expect(locked.deferredPartials == second.deferredPartials)
    }

    // Önde her olay hemen uygulanır; bekleyen geçici hâl yenisiyle düşer.
    @Test func foregroundAppliesEverything() {
        let pending: LiveSegment = segment(index: 3, text: "eski", isFinal: false)
        let routing: BackgroundLiveRouting = routingLiveEvent(
            event: .segment(segment(index: 3, text: "yeni", isFinal: false)), deferredPartials: [pending.id: pending], isInBackground: false
        )
        #expect(routing.appliesNow)
        #expect(routing.deferredPartials.isEmpty)
    }

    // Öne dönünce bekletilen geçici bölümler transkripte eklenir ve sıralı kalır; kesin bölümler yerinde durur.
    @Test func deferredPartialsCatchUpOnReturn() {
        let finals: [LiveSegment] = [segment(index: 0, text: "Bir.", isFinal: true), segment(index: 2, text: "Üç.", isFinal: true)]
        let partials: [SegmentID: LiveSegment] = [
            SegmentID(speaker: .others, index: 1): segment(index: 1, text: "iki", isFinal: false),
            SegmentID(speaker: .others, index: 3): segment(index: 3, text: "dört", isFinal: false),
        ]
        let caughtUp: [LiveSegment] = applyingDeferredPartials(transcript: finals, deferredPartials: partials)
        #expect(caughtUp.map(\.text) == ["Bir.", "iki", "Üç.", "dört"])
        #expect(applyingDeferredPartials(transcript: finals, deferredPartials: [:]) == finals)
    }

    // Açılışta yalnızca "kayıtta" kalanlar kesilmiş kayıttır; en yeni önce.
    @Test func interruptedRecordingsNewestFirst() {
        let records: [MeetingRecord] = [
            record(id: "eski", startedAt: 100, status: .recording, live: [], final: [], note: nil, notice: nil),
            record(id: "islenen", startedAt: 300, status: .processing, live: [], final: [], note: nil, notice: nil),
            record(id: "yeni", startedAt: 200, status: .recording, live: [], final: [], note: nil, notice: nil),
            record(id: "biten", startedAt: 400, status: .done, live: [], final: [], note: nil, notice: nil),
        ]
        #expect(interruptedRecordingIDs(records: records) == ["yeni", "eski"])
    }

    // Kesilen kaydın uyarısı başa eklenir; son geçiş uyarısı korunur.
    @Test func interruptedNoticeKeepsExistingNotice() throws {
        let plain: MeetingRecord = withInterruptedRecordingNotice(record: record(id: "a", startedAt: 0, status: .done, live: [], final: [], note: nil, notice: nil))
        let notice: String = try #require(plain.notice)
        #expect(!notice.isEmpty)
        let joined: MeetingRecord = withInterruptedRecordingNotice(
            record: record(id: "a", startedAt: 0, status: .done, live: [], final: [], note: nil, notice: "Son geçiş başarısız.")
        )
        #expect(joined.notice == "\(notice) Son geçiş başarısız.")
    }

    // Not yalnızca not adımında başarısız olduysa yeniden denenir: ses dönüştürüldü, metin var, not yok; bağlantı
    // koptuysa ya da uygulama arka plana geçtiyse üç, yoksa iki deneme.
    @Test func noteRetryOnlyForFailedNoteStep() {
        let live: [StoredSegment] = [stored(key: "others-0", text: "Bütçe cuma günü hazır.")]
        let failed: MeetingRecord = record(id: "a", startedAt: 0, status: .failed, live: live, final: [], note: nil, notice: nil)
        #expect(shouldRetryMeetingNote(result: failed, audioConverted: true, environmentInterrupted: true, attempt: 1))
        #expect(shouldRetryMeetingNote(result: failed, audioConverted: true, environmentInterrupted: true, attempt: 2))
        #expect(!shouldRetryMeetingNote(result: failed, audioConverted: true, environmentInterrupted: true, attempt: 3))
        #expect(shouldRetryMeetingNote(result: failed, audioConverted: true, environmentInterrupted: false, attempt: 1))
        #expect(!shouldRetryMeetingNote(result: failed, audioConverted: true, environmentInterrupted: false, attempt: 2))
        // Ses dönüştürülemedi: not yeniden yazılmaz ("Tekrar işle" sesi yeniden dönüştürür).
        #expect(!shouldRetryMeetingNote(result: failed, audioConverted: false, environmentInterrupted: true, attempt: 1))
        // Metin yok: yazılacak not yok.
        let empty: MeetingRecord = record(id: "a", startedAt: 0, status: .failed, live: [], final: [], note: nil, notice: nil)
        #expect(!shouldRetryMeetingNote(result: empty, audioConverted: true, environmentInterrupted: true, attempt: 1))
        // Başarılı ya da notu olan toplantı denenmez.
        let done: MeetingRecord = record(id: "a", startedAt: 0, status: .done, live: live, final: [], note: nil, notice: nil)
        #expect(!shouldRetryMeetingNote(result: done, audioConverted: true, environmentInterrupted: true, attempt: 1))
        let note: MeetingNote = MeetingNote(title: "Not", summary: "Özet", decisions: [], tasks: [], glossary: [])
        let withNote: MeetingRecord = record(id: "a", startedAt: 0, status: .failed, live: live, final: [], note: note, notice: nil)
        #expect(!shouldRetryMeetingNote(result: withNote, audioConverted: true, environmentInterrupted: true, attempt: 1))
        // Son geçiş metni varsa da not ondan yeniden denenir (son geçiş yeniden yapılmaz).
        let finalOnly: MeetingRecord = record(id: "a", startedAt: 0, status: .failed, live: [], final: live, note: nil, notice: nil)
        #expect(shouldRetryMeetingNote(result: finalOnly, audioConverted: true, environmentInterrupted: false, attempt: 1))
    }

    @Test func noteRetryDelaysGrow() {
        #expect(meetingNoteRetryDelaySec(attempt: 1) == 5)
        #expect(meetingNoteRetryDelaySec(attempt: 2) == 20)
        #expect(meetingNoteRetryDelaySec(attempt: 3) == 60)
        #expect(meetingNoteRetryDelaySec(attempt: 9) == 60)
    }
}
