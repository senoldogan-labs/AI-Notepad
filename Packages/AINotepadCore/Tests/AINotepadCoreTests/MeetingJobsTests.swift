import AINotepadCore
import Testing

struct MeetingJobsTests {
    // Not yeniden yazılırken aynı toplantıya "Tekrar işle" ya da çeviri denemesi başlamaz; başka toplantı başlar.
    @Test func secondJobOnTheSameMeetingIsRefused() throws {
        let rewriting: [String: MeetingJob] = try #require(beginningMeetingJob(jobs: [:], meetingID: "a", job: .rewritingNote))
        #expect(beginningMeetingJob(jobs: rewriting, meetingID: "a", job: .processing(.convertingAudio)) == nil)
        #expect(beginningMeetingJob(jobs: rewriting, meetingID: "a", job: .retryingTranslations) == nil)
        let both: [String: MeetingJob] = try #require(beginningMeetingJob(jobs: rewriting, meetingID: "b", job: .processing(.convertingAudio)))
        #expect(both == ["a": .rewritingNote, "b": .processing(.convertingAudio)])
        #expect(endingMeetingJob(jobs: both, meetingID: "a") == ["b": .processing(.convertingAudio)])
    }

    // İşlemenin geç gelen adımı biten işlemeyi ya da başka işi diriltmez; ilerleme kartı yalnız işlemeyi gösterir.
    @Test func lateStepDoesNotReviveAJob() {
        let jobs: [String: MeetingJob] = ["a": .processing(.convertingAudio), "b": .editingNote]
        let advanced: [String: MeetingJob] = advancingMeetingJob(jobs: jobs, meetingID: "a", step: .writingNote)
        #expect(advanced["a"] == .processing(.writingNote))
        #expect(advancingMeetingJob(jobs: advanced, meetingID: "b", step: .finalPass) == advanced)
        #expect(advancingMeetingJob(jobs: endingMeetingJob(jobs: advanced, meetingID: "a"), meetingID: "a", step: .finalPass)["a"] == nil)
        #expect(processingSteps(jobs: advanced) == ["a": .writingNote])
    }

    // "Not yazılıyor…" yalnız işleme dışındaki işlerde görünür; işleme sürerken aynı toplantıda not işi başlamaz (iPhone'da
    // işleme kaydedicide, not işleri depoda başlar; ikisi aynı haritayı paylaşır).
    @Test func noteJobsExcludeProcessing() {
        let jobs: [String: MeetingJob] = ["a": .processing(.writingNote), "b": .editingNote, "c": .retryingTranslations]
        #expect(noteJobMeetingIDs(jobs: jobs) == ["b", "c"])
        #expect(beginningMeetingJob(jobs: jobs, meetingID: "a", job: .rewritingNote) == nil)
        #expect(beginningMeetingJob(jobs: jobs, meetingID: "b", job: .processing(.convertingAudio)) == nil)
    }
}
