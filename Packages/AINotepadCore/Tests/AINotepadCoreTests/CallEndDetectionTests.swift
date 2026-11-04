import Foundation
import Testing
@testable import AINotepadCore

@Suite struct CallEndDetectionTests {
    private let base: Date = Date(timeIntervalSince1970: 1_800_000_000)
    private let rules: CallEndRules = .standard

    /// Ölçümleri (saniye, başka uygulama mikrofonda mı) sırayla uygular; her adımın işini döndürür.
    private func run(samples: [(sec: Double, active: Bool)], from state: CallEndState) -> (state: CallEndState, actions: [CallEndAction]) {
        samples.reduce(into: (state: state, actions: [CallEndAction]())) { (result: inout (state: CallEndState, actions: [CallEndAction]), sample: (sec: Double, active: Bool)) in
            let step: CallEndStep = callEndStep(state: result.state, callInputActive: sample.active, now: base.addingTimeInterval(sample.sec), rules: rules)
            result.state = step.state
            result.actions.append(step.action)
        }
    }

    /// `from`dan `to`ya (dahil) `every` saniyede bir aynı ölçüm.
    private func samples(from: Double, to: Double, every: Double, active: Bool) -> [(sec: Double, active: Bool)] {
        stride(from: from, through: to, by: every).map { (sec: $0, active: active) }
    }

    // Görüşme biter, 15 sn sessizlikten sonra 30 sn geri sayım başlar ve dolunca kayıt biter.
    @Test func stopsAfterCallEndsAndCountdownRunsOut() {
        let call: [(sec: Double, active: Bool)] = samples(from: 0, to: 60, every: 3, active: true)
        let quiet: [(sec: Double, active: Bool)] = samples(from: 63, to: 120, every: 3, active: false)
        let result: (state: CallEndState, actions: [CallEndAction]) = run(samples: call + quiet, from: .initial)
        let started: [Date] = result.actions.compactMap { (action: CallEndAction) -> Date? in
            if case .countdownStarted(let deadline) = action {
                return deadline
            }
            return nil
        }
        // Sessizlik 63. sn'de başladı: 78. sn'de geri sayım, 108. sn'de bitiş.
        #expect(started == [base.addingTimeInterval(108)])
        #expect(result.actions.filter { $0 == .stop }.count == 1)
        let stopIndex: Int? = result.actions.firstIndex(of: .stop)
        #expect(stopIndex.map { (call + quiet)[$0].sec } == 108)
        #expect(result.state == .initial)
    }

    // Görüşme uygulaması geri sayımda mikrofonu yeniden açarsa geri sayım iptal olur, kayıt sürer.
    @Test func cancelsCountdownWhenCallResumes() {
        let before: (state: CallEndState, actions: [CallEndAction]) = run(
            samples: samples(from: 0, to: 30, every: 3, active: true) + samples(from: 33, to: 51, every: 3, active: false), from: .initial
        )
        #expect(before.state.stopDeadline != nil)
        let resumed: CallEndStep = callEndStep(state: before.state, callInputActive: true, now: base.addingTimeInterval(54), rules: rules)
        #expect(resumed.action == .countdownCancelled)
        #expect(resumed.state.stopDeadline == nil && resumed.state.callSeen)
        // Görüşme yeniden bitince yeni geri sayım başlar.
        let again: (state: CallEndState, actions: [CallEndAction]) = run(samples: samples(from: 57, to: 75, every: 3, active: false), from: resumed.state)
        #expect(again.actions.contains { if case .countdownStarted = $0 { true } else { false } })
    }

    // Yüz yüze kayıt (başka uygulama hiç kullanmadı) ve kısa süreli kullanım (Siri, dikte) asla kaydı bitirmez.
    @Test func neverStopsWithoutConfirmedCall() {
        let inPerson: (state: CallEndState, actions: [CallEndAction]) = run(samples: samples(from: 0, to: 600, every: 3, active: false), from: .initial)
        #expect(inPerson.actions.allSatisfy { $0 == .none })
        // 6 sn'lik kullanım (onaylama süresi 10 sn) görüşme sayılmaz.
        let brief: [(sec: Double, active: Bool)] = samples(from: 0, to: 30, every: 3, active: false)
            + samples(from: 33, to: 39, every: 3, active: true) + samples(from: 42, to: 300, every: 3, active: false)
        #expect(run(samples: brief, from: .initial).actions.allSatisfy { $0 == .none })
    }

    // "Kayda devam et" görülen görüşmeyi unutturur: sessizlik sürse de yeniden geri sayılmaz.
    @Test func keepRecordingForgetsTheCall() {
        let counting: (state: CallEndState, actions: [CallEndAction]) = run(
            samples: samples(from: 0, to: 30, every: 3, active: true) + samples(from: 33, to: 51, every: 3, active: false), from: .initial
        )
        #expect(counting.state.stopDeadline != nil)
        let kept: (state: CallEndState, actions: [CallEndAction]) = run(samples: samples(from: 54, to: 400, every: 3, active: false), from: .initial)
        #expect(kept.actions.allSatisfy { $0 == .none })
    }

    // Bu uygulamanın kendi süreci (kayıt, sesle yazma) görüşme sayılmaz.
    @Test func ownProcessIsNotACall() {
        let processes: [AudioInputProcess] = [AudioInputProcess(pid: 42, bundleID: "com.senoldogan.AINotepad"), AudioInputProcess(pid: 7, bundleID: "us.zoom.xos")]
        #expect(callInputProcesses(processes: processes, ownPID: 42, excludedBundlePrefixes: systemSpeechBundlePrefixes) == [AudioInputProcess(pid: 7, bundleID: "us.zoom.xos")])
        #expect(callInputProcesses(processes: [processes[0]], ownPID: 42, excludedBundlePrefixes: systemSpeechBundlePrefixes).isEmpty)
    }

    // Siri, dikte ve erişilebilirlik servisleri (büyük/küçük harf duyarsız) ve paketsiz sistem süreçleri görüşme sayılmaz;
    // FaceTime, Safari/web görüşmesi (WebKit.GPU), iPhone aramaları ve üçüncü taraf uygulamalar sayılır. Kimlikler bu
    // Mac'in Core Audio süreç listesinden.
    @Test func systemSpeechServicesAreNotACall() {
        let ignored: [AudioInputProcess] = [
            AudioInputProcess(pid: 765, bundleID: "com.apple.CoreSpeech"),
            AudioInputProcess(pid: 77595, bundleID: "com.apple.assistantd"),
            AudioInputProcess(pid: 42370, bundleID: "com.apple.Siri"),
            AudioInputProcess(pid: 43560, bundleID: "com.apple.SiriNCService"),
            AudioInputProcess(pid: 11, bundleID: "com.apple.SpeechRecognitionCore.speechrecognitiond"),
            AudioInputProcess(pid: 12, bundleID: "com.apple.speech.synthesisserver"),
            AudioInputProcess(pid: 13, bundleID: "com.apple.dictation.DictationIM"),
            AudioInputProcess(pid: 66759, bundleID: "com.apple.accessibility.heard"),
            AudioInputProcess(pid: 599, bundleID: "com.apple.universalaccessd"),
            AudioInputProcess(pid: 844, bundleID: ""),
        ]
        let calls: [AudioInputProcess] = [
            AudioInputProcess(pid: 20, bundleID: "com.apple.FaceTime"),
            AudioInputProcess(pid: 753, bundleID: "com.apple.avconferenced"),
            AudioInputProcess(pid: 15290, bundleID: "com.apple.WebKit.GPU"),
            AudioInputProcess(pid: 65952, bundleID: "com.apple.TelephonyUtilities"),
            AudioInputProcess(pid: 21, bundleID: "com.apple.MobileSMS"),
            AudioInputProcess(pid: 2236, bundleID: "com.google.Chrome"),
            AudioInputProcess(pid: 22, bundleID: "com.microsoft.teams2"),
        ]
        #expect(callInputProcesses(processes: ignored + calls, ownPID: 1, excludedBundlePrefixes: systemSpeechBundlePrefixes) == calls)
        // Liste yalnız verilen öneklerle süzülür (saf: başka liste verilirse o uygulanır).
        #expect(callInputProcesses(processes: [ignored[0], calls[0]], ownPID: 1, excludedBundlePrefixes: []).count == 2)
    }
}
