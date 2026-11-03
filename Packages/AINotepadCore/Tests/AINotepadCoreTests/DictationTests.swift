import Foundation
import Synchronization
import Testing
@testable import AINotepadCore

/// Sesle yazmanın saf parçaları: kısayol durum makinesi, başlatma engelleri, teslim yolu, metin ve pano planı.
@Suite struct DictationTests {
    private func step(_ state: DictationKeyState, _ event: DictationKeyEvent) -> DictationKeyTransition {
        dictationTransition(state: state, event: event, holdThresholdSec: dictationHoldThresholdSec)
    }

    // Basılı tutup bırakmak bas-konuştur: bırakınca yazılır. Kısa dokunuş eller serbest dinlemeye geçer.
    @Test func holdFinishesOnReleaseAndTapStaysHandsFree() {
        let pressed: DictationKeyTransition = step(.idle, .keyDown(at: 100))
        #expect(pressed == DictationKeyTransition(state: .pressed(since: 100), effect: .startListening))
        #expect(step(.pressed(since: 100), .keyUp(at: 100.8)) == DictationKeyTransition(state: .transcribing, effect: .finishListening))
        #expect(step(.pressed(since: 100), .keyUp(at: 100.35)) == DictationKeyTransition(state: .transcribing, effect: .finishListening))
        #expect(step(.pressed(since: 100), .keyUp(at: 100.1)) == DictationKeyTransition(state: .handsFree, effect: .enterHandsFree))
    }

    // Eller serbest dinleme yeniden dokunma, Esc ya da süre sınırıyla biter; bırakma olayları onu bitirmez.
    @Test func handsFreeEndsOnTapEscapeOrTimeLimit() {
        let finish: DictationKeyTransition = DictationKeyTransition(state: .transcribing, effect: .finishListening)
        #expect(step(.handsFree, .keyDown(at: 5)) == finish)
        #expect(step(.handsFree, .escape) == finish)
        #expect(step(.handsFree, .timeLimit) == finish)
        #expect(step(.pressed(since: 0), .timeLimit) == finish)
        #expect(step(.handsFree, .keyUp(at: 5)) == DictationKeyTransition(state: .handsFree, effect: nil))
    }

    // İptal dinlerken sesi, yazıya dökülürken metni atar; yazıya dökülürken kısayol yok sayılır, bitince boşa döner.
    @Test func cancelAndTranscribingAreGuarded() {
        #expect(step(.pressed(since: 0), .cancel) == DictationKeyTransition(state: .idle, effect: .cancelListening))
        #expect(step(.handsFree, .cancel) == DictationKeyTransition(state: .idle, effect: .cancelListening))
        #expect(step(.transcribing, .keyDown(at: 1)) == DictationKeyTransition(state: .transcribing, effect: nil))
        #expect(step(.transcribing, .cancel) == DictationKeyTransition(state: .idle, effect: .discardText))
        #expect(step(.transcribing, .finished) == DictationKeyTransition(state: .idle, effect: nil))
        #expect(step(.idle, .escape) == DictationKeyTransition(state: .idle, effect: nil))
        #expect(step(.idle, .keyUp(at: 1)) == DictationKeyTransition(state: .idle, effect: nil))
        // Tuş tekrarı (basılıyken yeniden basma) dinlemeyi bozmaz.
        #expect(step(.pressed(since: 0), .keyDown(at: 0.5)) == DictationKeyTransition(state: .pressed(since: 0), effect: nil))
        #expect(dictationIsListening(state: .handsFree) && !dictationIsListening(state: .transcribing))
    }

    // Engel sırası: giriş, kayıt, parola alanı. Teslim: parola alanında hiç, izinsiz panoya, izinle yapıştırma.
    @Test func refusalsAndDelivery() {
        #expect(dictationStartRefusal(isSignedIn: false, isMeetingActive: true, isSecureInputActive: true) == .signInRequired)
        #expect(dictationStartRefusal(isSignedIn: true, isMeetingActive: true, isSecureInputActive: true) == .meetingInProgress)
        #expect(dictationStartRefusal(isSignedIn: true, isMeetingActive: false, isSecureInputActive: true) == .secureInputActive)
        #expect(dictationStartRefusal(isSignedIn: true, isMeetingActive: false, isSecureInputActive: false) == nil)
        #expect(dictationDelivery(isAccessibilityTrusted: true, isSecureInputActive: true) == .refuse(.secureInputActive))
        #expect(dictationDelivery(isAccessibilityTrusted: false, isSecureInputActive: false) == .copyOnly)
        #expect(dictationDelivery(isAccessibilityTrusted: true, isSecureInputActive: false) == .paste)
    }

    // Boşluklar düzelir, satır sonları kalır; boş metin yapıştırılmaz. Dikte edilen "Thank you." silinmez.
    @Test func insertTextIsNormalized() {
        #expect(dictationInsertText(raw: "  Merhaba   dünya.  ") == "Merhaba dünya.")
        #expect(dictationInsertText(raw: "Birinci\tsatır\n  ikinci  satır ") == "Birinci satır\nikinci satır")
        #expect(dictationInsertText(raw: " \n\t ") == nil)
        #expect(dictationInsertText(raw: "Thank you.") == "Thank you.")
    }

    // Pano eski haline döner; arada başka bir şey kopyalandıysa dokunulmaz; önceden boşsa temizlenir.
    @Test func pasteboardRestorePlan() {
        let item: PasteboardItemSnapshot = PasteboardItemSnapshot(representations: [
            PasteboardRepresentation(type: "public.utf8-plain-text", data: Data("eski".utf8)),
            PasteboardRepresentation(type: "public.html", data: Data("<b>eski</b>".utf8)),
        ])
        let snapshot: PasteboardSnapshot = PasteboardSnapshot(items: [item])
        #expect(pasteboardRestore(snapshot: snapshot, writtenChangeCount: 7, currentChangeCount: 7) == .restore([item]))
        #expect(pasteboardRestore(snapshot: snapshot, writtenChangeCount: 7, currentChangeCount: 8) == .keep)
        #expect(pasteboardRestore(snapshot: PasteboardSnapshot(items: []), writtenChangeCount: 3, currentChangeCount: 3) == .clear)
    }

    // Dikte yerel ayarı: kullanıcının bölgesi, sonra dilin kendi ülkesi; Norveççe Bokmål; desteklenmeyen dil nil (sessizce
    // başka dile geçilmez).
    @Test func dictationLocaleChoice() {
        let locales: [String] = ["en_GB", "en_US", "fi_FI", "nb_NO", "tr_TR"]
        #expect(appleDictationLocale(language: .english, dictationLocales: locales, regionCode: "GB") == "en_GB")
        #expect(appleDictationLocale(language: .english, dictationLocales: locales, regionCode: "US") == "en_US")
        #expect(appleDictationLocale(language: .finnish, dictationLocales: locales, regionCode: "SE") == "fi_FI")
        #expect(appleDictationLocale(language: .norwegian, dictationLocales: locales, regionCode: nil) == "nb_NO")
        #expect(appleDictationLocale(language: .finnish, dictationLocales: ["en_US"], regionCode: "FI") == nil)
    }

    // Canlı dikte: kesin sonuç eklenir ve geçiciyi siler; geçici sonuç öncekinin yerini alır; boş parçalar atlanır.
    @Test func liveTranscriptMergesFinalAndVolatile() {
        let empty: DictationTranscript = DictationTranscript(finalized: [], volatile: "")
        let first: DictationTranscript = dictationTranscriptApplying(transcript: empty, text: "Please send", isFinal: false)
        let revised: DictationTranscript = dictationTranscriptApplying(transcript: first, text: "Please send the", isFinal: false)
        #expect(dictationTranscriptText(transcript: revised) == "Please send the")
        let final: DictationTranscript = dictationTranscriptApplying(transcript: revised, text: " Please send the report. ", isFinal: true)
        #expect(final == DictationTranscript(finalized: [" Please send the report. "], volatile: ""))
        let next: DictationTranscript = dictationTranscriptApplying(transcript: final, text: "Thanks", isFinal: false)
        #expect(dictationTranscriptText(transcript: next) == "Please send the report. Thanks")
        #expect(dictationTranscriptText(transcript: dictationTranscriptApplying(transcript: next, text: "  ", isFinal: true)) == "Please send the report.")
        #expect(dictationTranscriptText(transcript: empty) == "")
    }

    // Varsayılan sesle yazma kısayolu diğer varsayılanlarla çakışmaz ve global kısayol olarak kullanılabilir.
    @Test func defaultDictateBindingIsDistinct() {
        #expect(keyBindingDisplay(binding: defaultDictateBinding) == "⌃⌥D")
        #expect(isUsableGlobalBinding(binding: defaultDictateBinding))
        #expect(defaultDictateBinding != defaultRecordBinding && defaultDictateBinding != defaultWindowsBinding)
    }
}

/// Sesle yazmanın gerçek cihaz içi yolu (macOS 26+, Apple diktesi): yalnızca `AINOTEPAD_ONDEVICE_TESTS=1` iken. Dil modeli
/// yoksa sistem indirir.
@Suite(.enabled(if: onDeviceTestsEnabled), .serialized)
struct DictationOnDeviceTests {
    // İngilizce ve Fince fikstür, yapıştırılacak noktalamalı metne dönüşür; ses hiçbir yere gönderilmez.
    @Test func dictatesFixturesOnDevice() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let engine: AppleDictationEngine = AppleDictationEngine()
        try await engine.prepare(language: .english) { (_: Double) -> Void in }
        let english: String = try #require(dictationInsertText(raw: try await engine.transcribe(samples: loadFixture(name: "en-meeting"), language: .english)))
        #expect(english.lowercased().contains("report"), "metin: \(english)")
        // Noktalama açık: sentetik seste duraklar nokta olmayabilir, soru işareti gelir.
        #expect(english.contains { ".?!,".contains($0) }, "noktalama yok: \(english)")
        try await engine.prepare(language: .finnish) { (_: Double) -> Void in }
        let finnish: String = try #require(dictationInsertText(raw: try await engine.transcribe(samples: loadFixture(name: "fi-meeting"), language: .finnish)))
        #expect(finnish.lowercased().contains("raport"), "metin: \(finnish)")
    }

    // Akış yolu: fikstür mikrofon gibi gerçek zamanlı parçalarla gelir; dinlerken ara metin oluşur, akış bitince tüm metin
    // döner.
    @Test func streamsFixtureWhileListening() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let engine: AppleDictationEngine = AppleDictationEngine()
        try await engine.prepare(language: .english) { (_: Double) -> Void in }
        let partials: PartialRecorder = PartialRecorder()
        let feed: RealTimeFeed = realTimeFeed(samples: try loadFixture(name: "en-meeting"))
        let raw: String = try await engine.transcribe(chunks: feed.chunks, language: .english) { (text: String) -> Void in
            partials.record(text: text)
        }
        let text: String = try #require(dictationInsertText(raw: raw))
        #expect(text.lowercased().contains("report"), "metin: \(text)")
        // Ara metin dinlerken (akış bitmeden) geldi.
        let earliest: ContinuousClock.Instant = try #require(partials.firstAt())
        #expect(earliest < (try await feed.endedAt.value), "ara metin akış bitmeden gelmedi")
    }

    // Bırakma → metin gecikmesi: eski yol (kayıt bitince tümü) ve akış yolu (yalnız kuyruk), ~3 sn ve ~15 sn dikte.
    // Sayılar test çıktısına yazılır (PR'daki ölçüm).
    @Test func measuresReleaseLatency() async throws {
        guard #available(macOS 26.0, *) else {
            return
        }
        let engine: AppleDictationEngine = AppleDictationEngine()
        try await engine.prepare(language: .english) { (_: Double) -> Void in }
        // Isınma: model belleğe yüklenir (uygulamada hazırlık dinlerken biter).
        _ = try await engine.transcribe(samples: loadFixture(name: "en-dictation-short"), language: .english)
        let clock: ContinuousClock = ContinuousClock()
        for name in ["en-dictation-short", "en-dictation-long"] {
            let samples: [Float] = try loadFixture(name: name)
            for round in 1...3 {
                let batchStart: ContinuousClock.Instant = clock.now
                let batch: String = try await engine.transcribe(samples: samples, language: .english)
                let batchLatency: Duration = clock.now - batchStart
                let feed: RealTimeFeed = realTimeFeed(samples: samples)
                let streamed: String = try await engine.transcribe(chunks: feed.chunks, language: .english) { (_: String) -> Void in }
                let streamLatency: Duration = clock.now - (try await feed.endedAt.value)
                print("dictation-latency \(name) round \(round) audio \(Double(samples.count) / 16000)s batch \(batchLatency) stream \(streamLatency)")
                print("  batch:  \(batch)")
                print("  stream: \(streamed)")
                #expect(streamed.lowercased().contains("report"), "metin: \(streamed)")
            }
        }
    }
}

/// Fikstürü mikrofon gibi gerçek zamanlı (~85 ms'lik parçalar) veren akış ve akışın bittiği an.
struct RealTimeFeed {
    let chunks: AsyncStream<[Float]>
    let endedAt: Task<ContinuousClock.Instant, any Error>
}

/// Örnekleri mikrofonun tampon boyunda (1360 örnek ≈ 85 ms) ve hızında akıtır.
func realTimeFeed(samples: [Float]) -> RealTimeFeed {
    let (chunks, continuation): (AsyncStream<[Float]>, AsyncStream<[Float]>.Continuation) = AsyncStream.makeStream(of: [Float].self)
    let size: Int = 1360
    let endedAt: Task<ContinuousClock.Instant, any Error> = Task {
        let clock: ContinuousClock = ContinuousClock()
        let start: ContinuousClock.Instant = clock.now
        for (index, offset) in stride(from: 0, to: samples.count, by: size).enumerated() {
            // Mutlak zamana göre beklenir: kayma birikmez.
            try await clock.sleep(until: start + .milliseconds(85 * index))
            continuation.yield(Array(samples[offset..<min(offset + size, samples.count)]))
        }
        try await clock.sleep(until: start + .milliseconds(85 * ((samples.count + size - 1) / size)))
        continuation.finish()
        return clock.now
    }
    return RealTimeFeed(chunks: chunks, endedAt: endedAt)
}

/// Ara metinlerin ilk geliş anını tutar (motorun geri çağrısı başka iş parçacığından gelir).
final class PartialRecorder: Sendable {
    private let first: Mutex<ContinuousClock.Instant?> = Mutex(nil)

    func record(text: String) {
        guard !text.isEmpty else {
            return
        }
        first.withLock { (value: inout ContinuousClock.Instant?) -> Void in
            if value == nil {
                value = ContinuousClock.now
            }
        }
    }

    func firstAt() -> ContinuousClock.Instant? {
        first.withLock { $0 }
    }
}

