import Foundation
import Testing
@testable import AINotepadCore

@Suite struct ReviewPromptTests {
    private let start: Date = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(id: String, status: MeetingStatus, hasNote: Bool) -> MeetingRecord {
        MeetingRecord(
            id: id, title: "Kayıt \(id)", startedAt: start, endedAt: nil, language: .turkish, status: status, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
            note: hasNote ? MeetingNote(title: "Not \(id)", summary: "S", decisions: [], tasks: [], glossary: []) : nil,
            audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
        )
    }

    private func context(version: String, now: Date) -> ReviewPromptContext {
        ReviewPromptContext(appVersion: version, isRecording: false, isAppActive: true, isOtherPromptVisible: false, now: now)
    }

    /// Toplantıları sırayla işler; her birinin kararını döndürür, istek açıldıysa geçmişe yazar.
    private func run(records: [MeetingRecord], history: ReviewPromptHistory, version: String, now: Date) -> (decisions: [ReviewPromptDecision], history: ReviewPromptHistory) {
        records.reduce((decisions: [ReviewPromptDecision](), history: history)) { (state, record) in
            let updated: ReviewPromptHistory = reviewPromptHistory(afterProcessing: record, history: state.history, now: now)
            let decision: ReviewPromptDecision = reviewPromptDecision(record: record, history: updated, context: context(version: version, now: now))
            let next: ReviewPromptHistory = decision == .request ? reviewPromptHistory(afterPromptIn: version, history: updated, now: now) : updated
            return (decisions: state.decisions + [decision], history: next)
        }
    }

    // Üçüncü başarılı not isteği açar; aynı sürümde bir daha açılmaz, yeni sürümde açılır.
    @Test func asksOnThirdSuccessfulNoteOncePerVersion() {
        let notes: [MeetingRecord] = (1...4).map { record(id: "m\($0)", status: .done, hasNote: true) }
        let first = run(records: notes, history: .empty, version: "0.2.1", now: start)
        #expect(first.decisions == [.skip(.tooFewNotes), .skip(.tooFewNotes), .request, .skip(.alreadyAskedThisVersion)])
        #expect(first.history.promptedVersions == ["0.2.1"])
        let next = run(records: [record(id: "m5", status: .done, hasNote: true)], history: first.history, version: "0.2.2", now: start.addingTimeInterval(86_400))
        #expect(next.decisions == [.request])
    }

    // Aynı toplantının tekrar işlenmesi ikinci kez sayılmaz; örnek toplantı sayılmaz ve istek açmaz.
    @Test func reprocessingAndSampleMeetingDoNotCount() {
        let again: [MeetingRecord] = [record(id: "a", status: .done, hasNote: true), record(id: "a", status: .done, hasNote: true), record(id: "b", status: .done, hasNote: true)]
        #expect(run(records: again, history: .empty, version: "1", now: start).decisions.last == .skip(.tooFewNotes))
        let sample: MeetingRecord = record(id: "s", status: .done, hasNote: true).markedAsSample()
        let history: ReviewPromptHistory = ReviewPromptHistory(notedMeetingIDs: ["a", "b", "c"], lastFailureAt: nil, promptedAt: [], promptedVersions: [])
        #expect(reviewPromptHistory(afterProcessing: sample, history: history, now: start) == history)
        #expect(reviewPromptDecision(record: sample, history: history, context: context(version: "1", now: start)) == .skip(.sampleMeeting))
        #expect(reviewPromptHistory(afterProcessing: record(id: "s", status: .failed, hasNote: false).markedAsSample(), history: history, now: start) == history)
    }

    // Not yazılamadıysa istek açılmaz ve sonraki 24 saat de açılmaz; çevrimdışı sıra hata sayılmaz.
    @Test func noPromptRightAfterAFailure() {
        let noted: ReviewPromptHistory = ReviewPromptHistory(notedMeetingIDs: ["a", "b"], lastFailureAt: nil, promptedAt: [], promptedVersions: [])
        for failed in [record(id: "f", status: .failed, hasNote: false), record(id: "f", status: .interrupted, hasNote: false), record(id: "f", status: .done, hasNote: false)] {
            let afterFailure: ReviewPromptHistory = reviewPromptHistory(afterProcessing: failed, history: noted, now: start)
            #expect(afterFailure.lastFailureAt == start)
            #expect(reviewPromptDecision(record: failed, history: afterFailure, context: context(version: "1", now: start)) == .skip(.noteNotWritten))
            let soon = run(records: [record(id: "c", status: .done, hasNote: true)], history: afterFailure, version: "1", now: start.addingTimeInterval(3_600))
            #expect(soon.decisions == [.skip(.recentFailure)])
            let later = run(records: [record(id: "c", status: .done, hasNote: true)], history: afterFailure, version: "1", now: start.addingTimeInterval(reviewPromptFailureCooldownSec))
            #expect(later.decisions == [.request])
        }
        #expect(reviewPromptHistory(afterProcessing: record(id: "q", status: .queued, hasNote: false), history: noted, now: start) == noted)
    }

    // Kayıt sürerken, uygulama arkadayken ya da başka bir teklif açıkken sorulmaz.
    @Test func skipsWhileBusyOrCovered() {
        let ready: ReviewPromptHistory = ReviewPromptHistory(notedMeetingIDs: ["a", "b", "c"], lastFailureAt: nil, promptedAt: [], promptedVersions: [])
        let done: MeetingRecord = record(id: "c", status: .done, hasNote: true)
        let cases: [(ReviewPromptContext, ReviewPromptDecision)] = [
            (ReviewPromptContext(appVersion: "1", isRecording: true, isAppActive: true, isOtherPromptVisible: false, now: start), .skip(.recording)),
            (ReviewPromptContext(appVersion: "1", isRecording: false, isAppActive: false, isOtherPromptVisible: false, now: start), .skip(.inBackground)),
            (ReviewPromptContext(appVersion: "1", isRecording: false, isAppActive: true, isOtherPromptVisible: true, now: start), .skip(.otherPromptVisible)),
            (context(version: "1", now: start), .request),
        ]
        for (situation, expected) in cases {
            #expect(reviewPromptDecision(record: done, history: ready, context: situation) == expected)
        }
    }

    // Son 365 günde en çok üç istek (Apple'ın sınırı); eski anlar düşer.
    @Test func atMostThreePerYear() {
        let year: Double = 365 * 86_400
        let asked: [Date] = [start.addingTimeInterval(-300 * 86_400), start.addingTimeInterval(-200 * 86_400), start.addingTimeInterval(-100 * 86_400)]
        let history: ReviewPromptHistory = ReviewPromptHistory(notedMeetingIDs: ["a", "b", "c"], lastFailureAt: nil, promptedAt: asked, promptedVersions: ["1", "2", "3"])
        let done: MeetingRecord = record(id: "c", status: .done, hasNote: true)
        #expect(reviewPromptDecision(record: done, history: history, context: context(version: "4", now: start)) == .skip(.yearlyLimit))
        #expect(reviewPromptDecision(record: done, history: history, context: context(version: "4", now: asked[0].addingTimeInterval(year))) == .request)
        let after: ReviewPromptHistory = reviewPromptHistory(afterPromptIn: "4", history: history, now: asked[0].addingTimeInterval(year))
        #expect(after.promptedAt.count == 3)
        #expect(after.promptedVersions == ["1", "2", "3", "4"])
    }

    // Geçmiş UserDefaults'ta gidip gelir; hiç yazılmadıysa boş, bozuksa hata (yutulmaz).
    @Test func historyRoundTripsThroughDefaults() throws {
        let suite: String = "ReviewPromptTests.\(UUID().uuidString)"
        let defaults: UserDefaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(try loadReviewPromptHistory(defaults: defaults) == .empty)
        let history: ReviewPromptHistory = ReviewPromptHistory(notedMeetingIDs: ["a"], lastFailureAt: start, promptedAt: [start], promptedVersions: ["1"])
        try saveReviewPromptHistory(history: history, defaults: defaults)
        #expect(try loadReviewPromptHistory(defaults: defaults) == history)
        defaults.set(Data("bozuk".utf8), forKey: reviewPromptHistoryDefaultsKey)
        #expect(throws: DecodingError.self) { try loadReviewPromptHistory(defaults: defaults) }
    }

    // Aynı anda biten toplantılar tek istek açar; geçmişe hepsi işlenir.
    @Test func stepAsksOnceForSeveralFinishedMeetings() {
        let records: [MeetingRecord] = (1...4).map { record(id: "m\($0)", status: .done, hasNote: true) }
        let step: ReviewPromptStep = reviewPromptStep(finished: records, history: .empty, context: context(version: "1", now: start))
        #expect(step.shouldRequest)
        #expect(step.history.notedMeetingIDs == ["m1", "m2", "m3", "m4"])
        #expect(step.history.promptedAt == [start])
        let again: ReviewPromptStep = reviewPromptStep(finished: [record(id: "m5", status: .done, hasNote: true)], history: step.history, context: context(version: "1", now: start))
        #expect(!again.shouldRequest)
        let quiet: ReviewPromptStep = reviewPromptStep(finished: Array(records.prefix(2)), history: .empty, context: context(version: "1", now: start))
        #expect(!quiet.shouldRequest && quiet.history.promptedAt.isEmpty)
    }

    // Yalnızca kaydediliyor/işleniyor/sırada → bitti, hata ya da yarıda geçişi sayılır; yeni gelen, değişmeyen ve
    // silinen toplantı sayılmaz.
    @Test func detectsOnlyTransitionsOutOfProcessing() {
        let mark = { (id: String, status: MeetingStatus) -> MeetingProcessingMark in MeetingProcessingMark(id: id, status: status) }
        let previous: [MeetingProcessingMark] = [mark("a", .processing), mark("b", .recording), mark("c", .queued), mark("d", .done), mark("e", .processing)]
        let current: [MeetingProcessingMark] = [mark("new", .done), mark("a", .done), mark("b", .processing), mark("c", .failed), mark("d", .done), mark("e", .processing)]
        #expect(meetingsFinishedProcessing(previous: previous, current: current) == ["a", "c"])
        #expect(meetingsFinishedProcessing(previous: [], current: current).isEmpty)
        #expect(meetingsFinishedProcessing(previous: previous, current: []).isEmpty)
        #expect(meetingProcessingMarks(records: [record(id: "x", status: .done, hasNote: true)]) == [mark("x", .done)])
    }
}
