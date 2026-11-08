import AINotepadCore
import Foundation
import Testing

@Suite struct LifecycleRulesTests {
    // 0.1.4'ün tek açık oturum kaydı yeni listeye katılır (tekrar eklenmez); yoksa liste değişmez.
    @Test func legacyOpenMeetingIsMerged() {
        #expect(mergingLegacyOpenMeeting(ids: ["a"], legacy: "b") == ["a", "b"])
        #expect(mergingLegacyOpenMeeting(ids: ["a"], legacy: "a") == ["a"])
        #expect(mergingLegacyOpenMeeting(ids: ["a"], legacy: nil) == ["a"])
        #expect(mergingLegacyOpenMeeting(ids: [], legacy: "") == [])
    }

    // Biten kayıt işlemeye devredilirken (sunucu oturumu kapatılıyor) kaydedici meşgul sayılır: yeni kayıt, kuyruk,
    // çıkış ve güncellemeyle yeniden başlatma bu aralıkta araya giremez.
    @Test func handoffKeepsRecorderBusy() {
        let id: RecordingID = RecordingID(rawValue: "r")
        let closing: RecorderState = .finishing(RecorderFinishing(
            id: id, server: .online(meetingID: "m"), startedAt: Date(timeIntervalSince1970: 0), stoppedAt: Date(timeIntervalSince1970: 60),
            clock: .running, discardRequested: false, stage: .closing
        ))
        #expect(isRecorderBusy(state: closing, processingCount: 0, importingCount: 0))
        #expect(!isRecorderBusy(state: .idle, processingCount: 0, importingCount: 0))
        #expect(!isRecorderBusy(state: .failed(id), processingCount: 0, importingCount: 0))
        #expect(isRecorderBusy(state: .idle, processingCount: 1, importingCount: 0))
    }

    // Kayıt başlarken (ses diske yazılıyor, toplantı kaydı henüz yok) kaydedici meşguldür: ⌘Q çıkışı uyarıyla bekletir,
    // ses toplantısız kalmaz.
    @Test func startingKeepsRecorderBusy() {
        let intents: RecorderStartIntents = RecorderStartIntents(stop: false, cancel: false, micMuted: false, interrupted: false)
        let starting: RecorderState = .starting(RecorderStarting(id: RecordingID(rawValue: "r"), stage: .awaitingCapture, intents: intents, capturedAt: nil, server: nil))
        #expect(isRecorderBusy(state: starting, processingCount: 0, importingCount: 0))
    }

    // Geç dönen kapatma yalnızca kendi oturumunu temizler; bu arada başlayan kaydın oturumuna dokunmaz.
    @Test func lateEndDoesNotClearNewMeeting() {
        #expect(shouldClearCurrentMeeting(currentMeetingID: "eski", endedMeetingID: "eski"))
        #expect(!shouldClearCurrentMeeting(currentMeetingID: "yeni", endedMeetingID: "eski"))
        #expect(!shouldClearCurrentMeeting(currentMeetingID: nil, endedMeetingID: "eski"))
    }

    // Kapatılamamış oturumların hepsi saklanır (yenisi eskisini ezmez) ve kayıt sürenin dışındakiler kapatılır.
    @Test func openMeetingsAccumulateAndOrphansExcludeRecording() {
        var ids: [String] = []
        ids = addingOpenMeeting(ids: ids, meetingID: "a")
        ids = addingOpenMeeting(ids: ids, meetingID: "b")
        ids = addingOpenMeeting(ids: ids, meetingID: "a")
        #expect(ids == ["a", "b"])
        #expect(orphanedMeetingIDs(openIDs: ids, recordingMeetingID: "b") == ["a"])
        #expect(removingOpenMeeting(ids: ids, meetingID: "a") == ["b"])
    }
}
