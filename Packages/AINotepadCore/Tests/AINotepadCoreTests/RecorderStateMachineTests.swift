import Foundation
import Testing
@testable import AINotepadCore

@Suite struct RecorderStateMachineTests {
    private let base: Date = Date(timeIntervalSince1970: 1_800_000_000)
    private let id: RecordingID = RecordingID(rawValue: "rec-1")
    private let other: RecordingID = RecordingID(rawValue: "rec-2")
    private let limit: Double = 30

    private func at(_ sec: Double) -> Date {
        base.addingTimeInterval(sec)
    }

    /// Olayları sırayla uygular; son durumu ve bütün işleri döndürür.
    private func run(_ events: [RecorderEvent], from state: RecorderState) -> (state: RecorderState, effects: [RecorderEffect]) {
        events.reduce(into: (state: state, effects: [RecorderEffect]())) { (result: inout (state: RecorderState, effects: [RecorderEffect]), event: RecorderEvent) in
            let step: RecorderStep = recorderStep(state: result.state, event: event, finishingLimitSec: limit)
            result.state = step.state
            result.effects += step.effects
        }
    }

    /// Kayıt başlayana dek olaylar (sunucu oturumu `server`).
    private func startEvents(server: RecordingServerSession) -> [RecorderEvent] {
        [
            .startRequested(id: id, micMuted: false), .awaitingCapture(id: id), .captureOpened(id: id, at: at(1)),
            .serverStarted(id: id, server: server), .sessionStarted(id: id, at: at(2)),
        ]
    }

    private func recordingState(server: RecordingServerSession) -> RecorderState {
        run(startEvents(server: server), from: .idle).state
    }

    // Olağan akış: başlat, bitir, oturum biter, kapanır, toplantı işlenir.
    @Test func runsTheWholeLifecycle() {
        let online: RecordingServerSession = .online(meetingID: "m1")
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            startEvents(server: online) + [.stopRequested(target: .current, at: at(60)), .sessionDrained(id: id, at: at(61)), .closed(id: id)],
            from: .idle
        )
        #expect(result.state == .idle)
        #expect(result.effects == [
            .beginStart(id: id), .applyMicMuted(id: id, muted: false), .stopCapture(id: id),
            .scheduleFinishDeadline(id: id, deadline: at(90)), .close(id: id, server: online), .complete(id: id, server: online, discard: false, stoppedAt: at(60)),
        ])
    }

    // M3: Siri/kendiliğinden "başlat" süren başlatmayı ya da kaydı hiç iptal etmez.
    @Test func startRequestsNeverToggle() {
        let starting: RecorderState = run([.startRequested(id: id, micMuted: false), .awaitingCapture(id: id)], from: .idle).state
        let again: RecorderStep = recorderStep(state: starting, event: .startRequested(id: other, micMuted: false), finishingLimitSec: limit)
        #expect(again.state == starting)
        #expect(again.effects.isEmpty)
        let recording: RecorderState = recordingState(server: .local)
        #expect(recorderStep(state: recording, event: .startRequested(id: other, micMuted: false), finishingLimitSec: limit).state == recording)
    }

    // M2: başlarken "Sen" kapatıldı: kayıt başladığı anda mikrofon kapalı uygulanır (ve tersi).
    @Test func micMuteChangedDuringStartIsApplied() {
        let muted: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .awaitingCapture(id: id), .micMuteChanged(muted: true), .captureOpened(id: id, at: at(1)),
             .serverStarted(id: id, server: .local), .sessionStarted(id: id, at: at(2))],
            from: .idle
        )
        #expect(muted.effects.contains(.applyMicMuted(id: id, muted: true)))
        guard case .recording(let recording) = muted.state else {
            Issue.record("kayıt başlamadı")
            return
        }
        #expect(recording.micMuted)
        let unmuted: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: true), .micMuteChanged(muted: false), .captureOpened(id: id, at: at(1)), .sessionStarted(id: id, at: at(2))],
            from: .idle
        )
        #expect(unmuted.effects.contains(.applyMicMuted(id: id, muted: false)))
    }

    // İzin penceresi açıkken "İptal": akışlar bir kez kapatılır, kayıt başlamaz, sunucu oturumu açılmaz.
    @Test func stopWhileAwaitingCaptureAbandonsWithoutServer() {
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .awaitingCapture(id: id), .stopRequested(target: .current, at: at(1)),
             .stopRequested(target: .current, at: at(1)), .startFailed(id: id)],
            from: .idle
        )
        #expect(result.state == .idle)
        #expect(result.effects == [.beginStart(id: id), .cancelCapture(id: id), .abandonStart(id: id, server: nil)])
    }

    // Akışlar açıldıktan sonra gelen "İptal": sunucu oturumu açılmadan bırakılır.
    @Test func stopBeforeCaptureOpensAbandonsAtCapture() {
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .stopRequested(target: .current, at: at(1)), .captureOpened(id: id, at: at(1))],
            from: .idle
        )
        #expect(result.state == .idle)
        #expect(result.effects == [.beginStart(id: id), .abandonStart(id: id, server: nil)])
    }

    // M4: sunucu oturumu açılırken "İptal": 0 sn'lik toplantı oluşmaz, açılan oturum kapatılır.
    @Test func stopWhileServerStartsClosesServerMeeting() {
        let online: RecordingServerSession = .online(meetingID: "m1")
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .captureOpened(id: id, at: at(1)), .stopRequested(target: .current, at: at(2)),
             .serverStarted(id: id, server: online), .sessionStarted(id: id, at: at(3))],
            from: .idle
        )
        #expect(result.state == .idle)
        #expect(result.effects == [.beginStart(id: id), .abandonStart(id: id, server: online)])
    }

    // Canlı motor seçilirken "İptal": kayıt silinerek bitirilir (işlenmez), sunucu oturumu kapanır.
    @Test func stopWhileChoosingEngineDiscards() {
        let online: RecordingServerSession = .online(meetingID: "m1")
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .captureOpened(id: id, at: at(1)), .serverStarted(id: id, server: online),
             .stopRequested(target: .current, at: at(2)), .sessionStarted(id: id, at: at(3)), .sessionDrained(id: id, at: at(4)), .closed(id: id)],
            from: .idle
        )
        #expect(result.state == .idle)
        #expect(result.effects.last == .complete(id: id, server: online, discard: true, stoppedAt: at(3)))
        #expect(result.effects.contains(.close(id: id, server: online)))
    }

    // Başlatma başarısız: sunucu oturumu açıldıysa kapatılır; yeni kayıt başlatılabilir.
    @Test func failedStartClosesServerAndAllowsRetry() {
        let online: RecordingServerSession = .online(meetingID: "m1")
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .captureOpened(id: id, at: at(1)), .serverStarted(id: id, server: online), .startFailed(id: id)],
            from: .idle
        )
        #expect(result.state == .failed(id))
        #expect(result.effects.last == .abandonStart(id: id, server: online))
        let retry: RecorderStep = recorderStep(state: result.state, event: .startRequested(id: other, micMuted: false), finishingLimitSec: limit)
        #expect(retry.effects == [.beginStart(id: other)])
        #expect(retry.state.activeID == other)
    }

    // I1b: başlarken gelen kesinti kaybolmaz; kayıt kesinti duraklatmasıyla başlar (sessizlik kaydedilmez, sunucuya bildirilir).
    @Test func interruptionDuringStartPausesOnStart() {
        let online: RecordingServerSession = .online(meetingID: "m1")
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .captureOpened(id: id, at: at(1)), .interruptionChanged(interrupted: true, at: at(1.5)),
             .serverStarted(id: id, server: online), .sessionStarted(id: id, at: at(2))],
            from: .idle
        )
        #expect(result.state.pause == .interruption(since: at(2)))
        #expect(result.effects.suffix(2) == [.setAudioPaused(id: id, paused: true, at: at(2)), .reportPause(meetingID: "m1", paused: true)])
        // Kesinti başlamadan bittiyse kayıt olağan başlar.
        let ended: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.startRequested(id: id, micMuted: false), .interruptionChanged(interrupted: true, at: at(1)), .interruptionChanged(interrupted: false, at: at(1.2)),
             .captureOpened(id: id, at: at(1.5)), .sessionStarted(id: id, at: at(2))],
            from: .idle
        )
        #expect(ended.state.pause == .running)
    }

    // I1a: kayıt kendiliğinden bitmeye başladıktan sonra "Kaydı sil" yok sayılmaz.
    @Test func discardDuringFinishingIsHonoured() {
        let online: RecordingServerSession = .online(meetingID: "m1")
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.stopRequested(target: .current, at: at(60)), .discardRequested(target: .current, at: at(61)), .sessionDrained(id: id, at: at(62)), .closed(id: id)],
            from: recordingState(server: online)
        )
        #expect(result.effects.last == .complete(id: id, server: online, discard: true, stoppedAt: at(60)))
        // Kapanış sürerken de.
        let closing: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.stopRequested(target: .current, at: at(60)), .sessionDrained(id: id, at: at(62)), .discardRequested(target: .current, at: at(63)), .closed(id: id)],
            from: recordingState(server: online)
        )
        #expect(closing.effects.last == .complete(id: id, server: online, discard: true, stoppedAt: at(60)))
    }

    // I1d: kesinti sürerken "Devam" kaydı sürdürmez; kesinti bitince kullanıcının duraklatması kalır.
    @Test func userAndInterruptionPausesAreSeparate() {
        let start: RecorderState = recordingState(server: .offline)
        let duringCall: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.interruptionChanged(interrupted: true, at: at(10)), .resumeRequested(target: .current, at: at(11))],
            from: start
        )
        #expect(duringCall.state.pause == .interruption(since: at(10)))
        #expect(duringCall.effects == [.setAudioPaused(id: id, paused: true, at: at(10))])
        let userThenCall: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.pauseRequested(target: .current, at: at(10)), .interruptionChanged(interrupted: true, at: at(20)), .interruptionChanged(interrupted: false, at: at(30))],
            from: start
        )
        #expect(userThenCall.state.pause == .user(since: at(10)))
        #expect(userThenCall.effects == [.setAudioPaused(id: id, paused: true, at: at(10))])
        let callThenUser: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.interruptionChanged(interrupted: true, at: at(10)), .pauseRequested(target: .current, at: at(15)), .interruptionChanged(interrupted: false, at: at(20)),
             .resumeRequested(target: .current, at: at(25))],
            from: start
        )
        #expect(callThenUser.state.pause == .running)
        #expect(callThenUser.effects == [.setAudioPaused(id: id, paused: true, at: at(10)), .setAudioPaused(id: id, paused: false, at: at(25))])
        // Saat yalnız gerçekten duraklatılan süreyi (10…25) sayar.
        #expect(callThenUser.state.clock == PauseClock(pausedAt: nil, completedSec: 15))
    }

    // Duraklatma yalnız sunucu oturumu olan kayıtta sunucuya bildirilir, kaydın kendi oturum kimliğiyle.
    @Test func pauseIsReportedToTheRecordingsOwnServerMeeting() {
        let online: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.pauseRequested(target: .current, at: at(10)), .resumeRequested(target: .current, at: at(20))],
            from: recordingState(server: .online(meetingID: "m1"))
        )
        #expect(online.effects == [
            .setAudioPaused(id: id, paused: true, at: at(10)), .reportPause(meetingID: "m1", paused: true),
            .setAudioPaused(id: id, paused: false, at: at(20)), .reportPause(meetingID: "m1", paused: false),
        ])
        let local: (state: RecorderState, effects: [RecorderEffect]) = run([.pauseRequested(target: .current, at: at(10))], from: recordingState(server: .local))
        #expect(local.effects == [.setAudioPaused(id: id, paused: true, at: at(10))])
    }

    // I8: başka kaydın bildirimi ya da kilit ekranı eylemi yok sayılır; kendi kaydınınki uygulanır.
    @Test func actionsForAnotherRecordingAreIgnored() {
        let recording: RecorderState = recordingState(server: .local)
        for event in [
            RecorderEvent.stopRequested(target: .recording(other), at: at(10)), .discardRequested(target: .recording(other), at: at(10)),
            .pauseRequested(target: .recording(other), at: at(10)), .resumeRequested(target: .recording(other), at: at(10)),
            .finishNow(id: other), .sessionDrained(id: other, at: at(10)), .closed(id: other),
        ] {
            let step: RecorderStep = recorderStep(state: recording, event: event, finishingLimitSec: limit)
            #expect(step.state == recording)
            #expect(step.effects.isEmpty)
        }
        let own: RecorderStep = recorderStep(state: recording, event: .stopRequested(target: .recording(id), at: at(10)), finishingLimitSec: limit)
        #expect(own.state.isFinishing)
    }

    // M10/I2: kapanış ve tamamlama kaydın başta açılan oturumunu taşır (oturum sonradan kapansa da kimlik kaybolmaz).
    @Test func closeCarriesTheCapturedServerMeeting() {
        let online: RecordingServerSession = .online(meetingID: "m-captured")
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.stopRequested(target: .current, at: at(60)), .sessionDrained(id: id, at: at(61))],
            from: recordingState(server: online)
        )
        #expect(result.effects.last == .close(id: id, server: online))
        #expect(result.state.server == online)
    }

    // I1c: bitirme süresi dolunca canlı oturum bırakılır ve kapanış bir kez başlar; geç gelen oturum sonu ikinci kapanış açmaz.
    @Test func finishDeadlineClosesOnce() {
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.stopRequested(target: .current, at: at(60)), .finishNow(id: id), .sessionDrained(id: id, at: at(95)), .finishNow(id: id), .closed(id: id)],
            from: recordingState(server: .local)
        )
        #expect(result.state == .idle)
        #expect(result.effects.filter { if case .close = $0 { return true } else { return false } }.count == 1)
        #expect(result.effects.contains(.cancelLiveSession(id: id)))
        // Kapanış bitmeden gelen `closed` başka adımda yok sayılmaz ama süzme sürerken gelen yok sayılır.
        let early: RecorderState = run([.stopRequested(target: .current, at: at(60)), .closed(id: id)], from: recordingState(server: .local)).state
        #expect(early.isFinishing)
    }

    // M1: ses akışları kendiliğinden kapandı: kayıt hemen "bitiriliyor"a geçer (duraklat/bitir açık kalmaz).
    @Test func sessionEndingOnItsOwnFinishesImmediately() {
        let result: (state: RecorderState, effects: [RecorderEffect]) = run(
            [.pauseRequested(target: .current, at: at(10)), .sessionDrained(id: id, at: at(20))],
            from: recordingState(server: .offline)
        )
        guard case .finishing(let finishing) = result.state else {
            Issue.record("bitirilmiyor")
            return
        }
        #expect(finishing.stage == .closing)
        #expect(finishing.stoppedAt == at(20))
        #expect(finishing.clock == PauseClock(pausedAt: nil, completedSec: 10))
        #expect(result.effects.suffix(2) == [.stopCapture(id: id), .close(id: id, server: .offline)])
    }

    // Bitirme sürerken başlat, bitir, duraklat hiçbir şey yapmaz.
    @Test func finishingIgnoresStartStopAndPause() {
        let finishing: RecorderState = run([.stopRequested(target: .current, at: at(60))], from: recordingState(server: .local)).state
        for event in [
            RecorderEvent.startRequested(id: other, micMuted: false), .stopRequested(target: .current, at: at(61)),
            .pauseRequested(target: .current, at: at(61)), .resumeRequested(target: .current, at: at(61)),
        ] {
            #expect(recorderStep(state: finishing, event: event, finishingLimitSec: limit) == RecorderStep(state: finishing, effects: []))
        }
    }

    // Kayıt yokken kilit ekranından bitir/duraklat: kalan gösterge kalkar, kayıt başlamaz.
    @Test func idleStopDismissesStaleIndicators() {
        for event in [RecorderEvent.stopRequested(target: .current, at: at(1)), .pauseRequested(target: .recording(other), at: at(1)), .resumeRequested(target: .current, at: at(1))] {
            #expect(recorderStep(state: .idle, event: event, finishingLimitSec: limit) == RecorderStep(state: .idle, effects: [.dismissStaleIndicators]))
        }
    }

    // Eski kaydın geç olayları yeni başlatmayı bozmaz.
    @Test func lateEventsOfAnotherStartAreIgnored() {
        let starting: RecorderState = run([.startRequested(id: id, micMuted: false)], from: .idle).state
        for event in [
            RecorderEvent.captureOpened(id: other, at: at(1)), .serverStarted(id: other, server: .offline), .sessionStarted(id: other, at: at(2)),
            .startFailed(id: other), .stopRequested(target: .recording(other), at: at(1)),
        ] {
            #expect(recorderStep(state: starting, event: event, finishingLimitSec: limit).state == starting)
        }
    }
}
