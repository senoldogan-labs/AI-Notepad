import Foundation
import Testing
@testable import KeyboardCore

/// In-place dictation: when the keyboard dictates by itself, its locale, the captured PCM and the inserted text.
@Suite struct KeyboardInPlaceTests {
    @Test func liveSessionWinsThenInPlaceThenApp() {
        #expect(keyboardDictationRoute(sessionIsLive: true, sessionMayBeAlive: true, inPlaceIsReady: true) == .appSession)
        #expect(keyboardDictationRoute(sessionIsLive: false, sessionMayBeAlive: true, inPlaceIsReady: true) == .appSessionOrOpen)
        #expect(keyboardDictationRoute(sessionIsLive: false, sessionMayBeAlive: false, inPlaceIsReady: true) == .inPlace)
        #expect(keyboardDictationRoute(sessionIsLive: false, sessionMayBeAlive: false, inPlaceIsReady: false) == .openApp)
    }

    @Test func readinessNeedsAccessPermissionModelAndMemory() {
        let enough: UInt64 = keyboardInPlaceHeadroomBytes
        #expect(keyboardInPlaceIsReady(hasFullAccess: true, microphoneAllowed: true, installedLocale: "tr_TR", headroomBytes: enough))
        #expect(keyboardInPlaceIsReady(hasFullAccess: true, microphoneAllowed: true, installedLocale: "tr_TR", headroomBytes: 0))
        #expect(!keyboardInPlaceIsReady(hasFullAccess: true, microphoneAllowed: true, installedLocale: "tr_TR", headroomBytes: enough - 1))
        #expect(!keyboardInPlaceIsReady(hasFullAccess: false, microphoneAllowed: true, installedLocale: "tr_TR", headroomBytes: enough))
        #expect(!keyboardInPlaceIsReady(hasFullAccess: true, microphoneAllowed: false, installedLocale: "tr_TR", headroomBytes: enough))
        #expect(!keyboardInPlaceIsReady(hasFullAccess: true, microphoneAllowed: true, installedLocale: nil, headroomBytes: enough))
    }

    @Test func localePrefersRegionThenLanguageCountry() {
        let installed: [String] = ["en_GB", "en_US", "tr_TR", "nb-NO"]
        #expect(keyboardDictationLocale(languageCode: "en", installed: installed, regionCode: "GB") == "en_GB")
        #expect(keyboardDictationLocale(languageCode: "en", installed: installed, regionCode: "FI") == "en_US")
        #expect(keyboardDictationLocale(languageCode: "tr", installed: installed, regionCode: nil) == "tr_TR")
        #expect(keyboardDictationLocale(languageCode: "nb", installed: installed, regionCode: "NO") == "nb-NO")
        #expect(keyboardDictationLocale(languageCode: "fi", installed: installed, regionCode: "FI") == nil)
    }

    @Test func pcmDecodesLittleEndianInt16() {
        let data: Data = Data([0x00, 0x00, 0x00, 0x80, 0xFF, 0x7F, 0x00, 0x40, 0x01])
        #expect(keyboardPCMSamples(int16LittleEndian: data) == [0, -1, Float(32767) / 32768, 0.5])
    }

    @Test func textNeedsSpeechAndLength() {
        #expect(keyboardInPlaceText(raw: "  Merhaba   dünya \n yarın  ", capturedSeconds: 2, minimumSeconds: 0.25) == "Merhaba dünya\nyarın")
        #expect(keyboardInPlaceText(raw: "   ", capturedSeconds: 2, minimumSeconds: 0.25) == nil)
        #expect(keyboardInPlaceText(raw: "Hi", capturedSeconds: 0.1, minimumSeconds: 0.25) == nil)
    }
}

@Suite struct KeyboardVoiceLevelTests {
    @Test func levelMapsSilenceAndVoice() {
        #expect(keyboardVoiceLevel(samples: []) == 0)
        #expect(keyboardVoiceLevel(samples: [Float](repeating: 0, count: 100)) == 0)
        #expect(keyboardVoiceLevel(samples: [Float](repeating: 0.5, count: 100)) == 1)
        let quiet: Double = keyboardVoiceLevel(samples: [Float](repeating: 0.01, count: 100))
        #expect(quiet > 0.2 && quiet < 0.5)
    }

    @Test func historyKeepsTheNewest() {
        #expect(keyboardLevelHistory(history: [0.1, 0.2, 0.3], appending: 0.4, limit: 3) == [0.2, 0.3, 0.4])
        #expect(keyboardLevelHistory(history: [], appending: 0.4, limit: 3) == [0.4])
    }
}
