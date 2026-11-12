import Foundation
import Testing
@testable import AINotepadCore

@Suite struct HostedPauseReportsTests {
    private let meeting: String = "m1"
    private let start: Date = Date(timeIntervalSince1970: 1_000_000)

    /// Kuyruğun ilk bildirimini gönderir ve verilen yanıtla onaylar.
    private func acknowledgeNext(queue: PauseReportQueue, paused: Bool, pausedSeconds: Int, at: Date) throws -> PauseReportQueue {
        let next: (queue: PauseReportQueue, report: PauseReport) = try #require(nextPauseReport(queue: queue))
        #expect(next.report.paused == paused)
        return acknowledgingPauseReport(queue: next.queue, paused: paused, pausedSeconds: pausedSeconds, at: at)
    }

    // Çevrimiçi duraklatma: sınır ancak sunucu onaylayınca ve onaydan itibaren ileri gider; sürdürme onayında sunucunun
    // sayılan süresi geçerli olur.
    @Test func onlyAcknowledgedPausesMoveTheLimit() throws {
        let paused: PauseReportQueue = queueingPauseReport(queue: .empty, meetingID: meeting, paused: true)
        #expect(confirmedPauseSec(queue: paused, meetingID: meeting, now: start.addingTimeInterval(60), maxPauseSec: 3600) == 0)
        let acked: PauseReportQueue = try acknowledgeNext(queue: paused, paused: true, pausedSeconds: 0, at: start.addingTimeInterval(1))
        #expect(confirmedPauseSec(queue: acked, meetingID: meeting, now: start.addingTimeInterval(121), maxPauseSec: 3600) == 120)
        #expect(confirmedPauseSec(queue: acked, meetingID: meeting, now: start.addingTimeInterval(121), maxPauseSec: 100) == 100)
        let resuming: PauseReportQueue = queueingPauseReport(queue: acked, meetingID: meeting, paused: false)
        // Sürdürme sunucuya varana dek sunucu duraklatmayı saymayı sürdürür; yerel hesap da.
        #expect(confirmedPauseSec(queue: resuming, meetingID: meeting, now: start.addingTimeInterval(301), maxPauseSec: 3600) == 300)
        let resumed: PauseReportQueue = try acknowledgeNext(queue: resuming, paused: false, pausedSeconds: 290, at: start.addingTimeInterval(302))
        #expect(confirmedPauseSec(queue: resumed, meetingID: meeting, now: start.addingTimeInterval(900), maxPauseSec: 3600) == 290)
        #expect(confirmedPauseSec(queue: resumed, meetingID: "baska", now: start.addingTimeInterval(900), maxPauseSec: 3600) == 0)
        #expect(pauseConfirmation(queue: resumed, meetingID: meeting) == .confirmed)
    }

    // Çevrimdışı duraklatma: gönderim başarısızsa bildirim kuyrukta kalır, uyarı görünür ve sınır ilerlemez; ağ gelip
    // onaylanınca uyarı kalkar.
    @Test func failedReportStaysQueuedUntilAcknowledged() throws {
        let queued: PauseReportQueue = queueingPauseReport(queue: .empty, meetingID: meeting, paused: true)
        let sending: (queue: PauseReportQueue, report: PauseReport) = try #require(nextPauseReport(queue: queued))
        #expect(nextPauseReport(queue: sending.queue)?.report == nil)
        let failed: PauseReportQueue = failingPauseReport(queue: sending.queue)
        #expect(failed.pending == [PauseReport(paused: true, attempted: true)])
        #expect(pauseConfirmation(queue: failed, meetingID: meeting) == .unconfirmed)
        #expect(confirmedPauseSec(queue: failed, meetingID: meeting, now: start.addingTimeInterval(600), maxPauseSec: 3600) == 0)
        let acked: PauseReportQueue = try acknowledgeNext(queue: failed, paused: true, pausedSeconds: 0, at: start.addingTimeInterval(600))
        #expect(pauseConfirmation(queue: acked, meetingID: meeting) == .confirmed)
        #expect(acked.pending.isEmpty)
    }

    // Hiç gönderilmeye çalışılmamış duraklatmayı izleyen sürdürme ikisini de düşürür (sunucu ancak varış anından sayardı).
    // Denenmiş duraklatma (gönderiliyor ya da ağ hatası: istek sunucuya varmış olabilir) geri alınmaz, sürdürme sıraya
    // girer; yoksa sunucuda duraklatma toplantının sonuna dek açık kalabilirdi.
    @Test func onlyNeverSentPauseCancelsOutWithResume() throws {
        let queuedBehindSend: PauseReportQueue = queueingPauseReport(
            queue: try #require(nextPauseReport(queue: queueingPauseReport(queue: .empty, meetingID: meeting, paused: true))).queue, meetingID: meeting, paused: false
        )
        let unsent: PauseReportQueue = queueingPauseReport(queue: queuedBehindSend, meetingID: meeting, paused: true)
        #expect(queueingPauseReport(queue: unsent, meetingID: meeting, paused: false).pending == queuedBehindSend.pending)
        let failed: PauseReportQueue = failingPauseReport(queue: try #require(nextPauseReport(queue: queueingPauseReport(queue: .empty, meetingID: meeting, paused: true))).queue)
        let resumedAfterFailure: PauseReportQueue = queueingPauseReport(queue: failed, meetingID: meeting, paused: false)
        #expect(resumedAfterFailure.pending == [PauseReport(paused: true, attempted: true), PauseReport(paused: false, attempted: false)])
        #expect(pauseConfirmation(queue: resumedAfterFailure, meetingID: meeting) == .unconfirmed)
        let sending: PauseReportQueue = try #require(nextPauseReport(queue: queueingPauseReport(queue: .empty, meetingID: meeting, paused: true))).queue
        #expect(queueingPauseReport(queue: sending, meetingID: meeting, paused: false).pending == [PauseReport(paused: true, attempted: true), PauseReport(paused: false, attempted: false)])
    }

    // Sunucunun reddi (ör. duraklatma sınırı) düşer, uyarı toplantı boyunca kalır; yeni toplantı kuyruğu sıfırlar.
    @Test func refusalIsStickyForTheMeeting() throws {
        let sending: PauseReportQueue = try #require(nextPauseReport(queue: queueingPauseReport(queue: .empty, meetingID: meeting, paused: true))).queue
        let refused: PauseReportQueue = refusingPauseReport(queue: sending)
        #expect(refused.pending.isEmpty)
        #expect(pauseConfirmation(queue: refused, meetingID: meeting) == .refused)
        let next: PauseReportQueue = queueingPauseReport(queue: refused, meetingID: "m2", paused: true)
        #expect(pauseConfirmation(queue: next, meetingID: "m2") == .confirmed)
        #expect(next.pending == [PauseReport(paused: true, attempted: false)])
    }

    // Canlı metin jetonu duraklatmada ve sürdürme sunucuya varana dek bekler.
    @Test func liveTokenWaitsUntilResumeReachesServer() throws {
        let acked: PauseReportQueue = try acknowledgeNext(queue: queueingPauseReport(queue: .empty, meetingID: meeting, paused: true), paused: true, pausedSeconds: 0, at: start)
        #expect(pauseBlocksLiveToken(queue: acked, meetingID: meeting, locallyPaused: true))
        let resuming: PauseReportQueue = queueingPauseReport(queue: acked, meetingID: meeting, paused: false)
        #expect(pauseBlocksLiveToken(queue: resuming, meetingID: meeting, locallyPaused: false))
        let resumed: PauseReportQueue = try acknowledgeNext(queue: resuming, paused: false, pausedSeconds: 30, at: start.addingTimeInterval(30))
        #expect(!pauseBlocksLiveToken(queue: resumed, meetingID: meeting, locallyPaused: false))
    }

    // P02/P10: the close of meeting A finishes after recording B started and paused (A's last pause report waits up to
    // ten seconds, its server close runs on in the background). B stays paused, so its live token keeps waiting, and an
    // online close does not end B's offline state.
    @Test func oldMeetingCloseKeepsNewRecording() throws {
        let aPaused: HostedRecordingFlags = [
            HostedRecordingFlagsEvent.startedOnline, .pauseReported(meetingID: "a", paused: true), .meetingEnded(meetingID: "a"),
        ].reduce(HostedRecordingFlags.idle) { hostedRecordingFlagsStep(flags: $0, event: $1) }
        let bPaused: HostedRecordingFlags = hostedRecordingFlagsStep(
            flags: hostedRecordingFlagsStep(flags: aPaused, event: .startedOnline), event: .pauseReported(meetingID: "b", paused: true)
        )
        let aCleared: HostedRecordingFlags = hostedRecordingFlagsStep(flags: bPaused, event: .pauseReportsCleared(meetingID: "a"))
        #expect(isMeetingLocallyPaused(flags: aCleared, meetingID: "b"))
        #expect(!isMeetingLocallyPaused(flags: aCleared, meetingID: "a"))
        let bQueue: PauseReportQueue = try acknowledgeNext(
            queue: queueingPauseReport(queue: .empty, meetingID: "b", paused: true), paused: true, pausedSeconds: 0, at: start
        )
        #expect(pauseBlocksLiveToken(queue: bQueue, meetingID: "b", locallyPaused: isMeetingLocallyPaused(flags: aCleared, meetingID: "b")))
        let bResumed: HostedRecordingFlags = hostedRecordingFlagsStep(flags: aCleared, event: .pauseReported(meetingID: "b", paused: false))
        #expect(bResumed.pausedMeetingIDs.isEmpty)

        // An abandoned online start of A closes after B started offline.
        let bOffline: HostedRecordingFlags = hostedRecordingFlagsStep(
            flags: hostedRecordingFlagsStep(flags: .idle, event: .startedOnline), event: .startedOffline
        )
        #expect(hostedRecordingFlagsStep(flags: bOffline, event: .meetingEnded(meetingID: "a")).isOfflineRecording)
        #expect(!hostedRecordingFlagsStep(flags: bOffline, event: .meetingEnded(meetingID: nil)).isOfflineRecording)
        #expect(!hostedRecordingFlagsStep(flags: bOffline, event: .startedOnline).isOfflineRecording)
    }

    @Test func retryDelaysDoubleUpToAMinute() {
        #expect((0..<7).map { pauseReportRetryDelaySec(attempt: $0) } == [2, 4, 8, 16, 32, 60, 60])
    }
}
