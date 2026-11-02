import Foundation
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

    // İptal yalnızca dinlerken sesi atar; yazıya dökülürken kısayol ve iptal yok sayılır, bitince boşa döner.
    @Test func cancelAndTranscribingAreGuarded() {
        #expect(step(.pressed(since: 0), .cancel) == DictationKeyTransition(state: .idle, effect: .cancelListening))
        #expect(step(.handsFree, .cancel) == DictationKeyTransition(state: .idle, effect: .cancelListening))
        #expect(step(.transcribing, .keyDown(at: 1)) == DictationKeyTransition(state: .transcribing, effect: nil))
        #expect(step(.transcribing, .cancel) == DictationKeyTransition(state: .transcribing, effect: nil))
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
}
