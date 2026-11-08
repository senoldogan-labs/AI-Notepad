import AINotepadCore
import Foundation
import Testing

struct ImportJobsTests {
    private let files: UUID = UUID()
    private let call: UUID = UUID()

    // Arka planda gelen arama kaydı, kullanıcının süren içe aktarmasının hatalarını silmez; sayılar toplanır.
    @Test func callRecordingDoesNotClearFileErrors() {
        let started: [ImportJob] = beginningImportJob(jobs: [], id: files, source: .files, count: 2)
        let failed: [ImportJob] = failingImportItem(jobs: started, id: files, message: "a.m4a")
        let withCall: [ImportJob] = beginningImportJob(jobs: failed, id: call, source: .callRecording, count: 1)
        #expect(importErrors(jobs: withCall) == ["a.m4a"])
        #expect(importingCount(jobs: withCall) == 2)
        let done: [ImportJob] = finishingImportItem(jobs: finishingImportItem(jobs: withCall, id: call), id: files)
        #expect(importingCount(jobs: done) == 0)
        #expect(importErrors(jobs: done) == ["a.m4a"])
    }

    // Yeni dosya içe aktarması yalnız aynı kaynağın biten işlerinin hatalarını temizler.
    @Test func newImportClearsOnlyFinishedErrorsOfItsSource() {
        let earlier: [ImportJob] = failingImportItem(jobs: beginningImportJob(jobs: [], id: files, source: .files, count: 1), id: files, message: "eski")
        let callFailed: [ImportJob] = failingImportItem(
            jobs: beginningImportJob(jobs: earlier, id: call, source: .callRecording, count: 1), id: call, message: "arama"
        )
        let restarted: [ImportJob] = beginningImportJob(jobs: callFailed, id: UUID(), source: .files, count: 1)
        #expect(importErrors(jobs: restarted) == ["arama"])
        #expect(importingCount(jobs: restarted) == 1)
    }

    // Süren dosya işi, aynı kaynaktan yeni iş başlayınca hatalarıyla kalır.
    @Test func runningJobKeepsItsErrors() {
        let running: [ImportJob] = failingImportItem(jobs: beginningImportJob(jobs: [], id: files, source: .files, count: 2), id: files, message: "a")
        let both: [ImportJob] = beginningImportJob(jobs: running, id: UUID(), source: .files, count: 1)
        #expect(importErrors(jobs: both) == ["a"])
        #expect(importingCount(jobs: both) == 2)
    }

    // Bilinmeyen ya da biten işin geç gelen sonucu sayacı eksiye düşürmez, hata eklemez.
    @Test func lateResultDoesNotUnderflow() {
        let done: [ImportJob] = finishingImportItem(jobs: beginningImportJob(jobs: [], id: files, source: .files, count: 1), id: files)
        #expect(finishingImportItem(jobs: done, id: files) == done)
        #expect(failingImportItem(jobs: done, id: files, message: "geç") == done)
        #expect(finishingImportItem(jobs: done, id: call) == done)
        #expect(importingCount(jobs: done) == 0)
    }
}
