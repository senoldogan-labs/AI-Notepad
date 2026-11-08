import Foundation
import Testing
@testable import AINotepadCore

struct RecordingReliabilityTests {
    private let now: Date = Date(timeIntervalSince1970: 100_000)

    // Yalnız taze bildirimin "Kaydı başlat" eylemi kayıt başlatır; bildirime dokunmak, eski bildirim ya da süren kayıt
    // Ana sayfayı açar.
    @Test func onlyFreshStartActionStartsRecording() {
        #expect(meetingNotificationTap(isStartAction: true, deliveredAt: now.addingTimeInterval(-60), now: now, isRecording: false) == .startRecording)
        #expect(meetingNotificationTap(isStartAction: false, deliveredAt: now.addingTimeInterval(-60), now: now, isRecording: false) == .openHome)
        #expect(meetingNotificationTap(isStartAction: true, deliveredAt: now.addingTimeInterval(-3 * 3600), now: now, isRecording: false) == .openHome)
        #expect(meetingNotificationTap(isStartAction: true, deliveredAt: now.addingTimeInterval(-60), now: now, isRecording: true) == .openHome)
    }

    @Test func microphoneOutageAlertsOncePerOutage() {
        let started: Date = now.addingTimeInterval(-25)
        #expect(isMicrophoneOutageAlertDue(outageStartedAt: started, now: now, alreadyAlerted: false, thresholdSec: 20))
        #expect(!isMicrophoneOutageAlertDue(outageStartedAt: started, now: now, alreadyAlerted: true, thresholdSec: 20))
        #expect(!isMicrophoneOutageAlertDue(outageStartedAt: now.addingTimeInterval(-5), now: now, alreadyAlerted: false, thresholdSec: 20))
        #expect(!isMicrophoneOutageAlertDue(outageStartedAt: nil, now: now, alreadyAlerted: false, thresholdSec: 20))
    }

    // Takvim bitişi payla, uzun sessizlik ayrıca; duraklatılmış kayıtta ve sorulmuş nedende sorulmaz.
    @Test func meetingOverIsAskedOncePerReason() {
        let recent: Date = now.addingTimeInterval(-30)
        #expect(meetingOverReason(now: now, calendarEnd: now.addingTimeInterval(-150), lastActivityAt: recent, isPaused: false, asked: [], calendarGraceSec: 120, silenceSec: 600) == .calendarEnded)
        #expect(meetingOverReason(now: now, calendarEnd: now.addingTimeInterval(-60), lastActivityAt: recent, isPaused: false, asked: [], calendarGraceSec: 120, silenceSec: 600) == nil)
        #expect(meetingOverReason(now: now, calendarEnd: now.addingTimeInterval(-150), lastActivityAt: recent, isPaused: false, asked: [.calendarEnded], calendarGraceSec: 120, silenceSec: 600) == nil)
        #expect(meetingOverReason(now: now, calendarEnd: nil, lastActivityAt: now.addingTimeInterval(-700), isPaused: false, asked: [], calendarGraceSec: 120, silenceSec: 600) == .longSilence)
        #expect(meetingOverReason(now: now, calendarEnd: nil, lastActivityAt: now.addingTimeInterval(-700), isPaused: true, asked: [], calendarGraceSec: 120, silenceSec: 600) == nil)
    }
}
