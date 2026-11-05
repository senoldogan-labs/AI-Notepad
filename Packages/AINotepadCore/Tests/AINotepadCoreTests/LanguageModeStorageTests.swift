import Testing
@testable import AINotepadCore

@Suite struct LanguageModeStorageTests {
    // Dil modu saklanan metne ve geri dönüşür; kayıt yoksa ya da tanınmıyorsa Otomatik.
    @Test func languageModeRoundTrips() {
        for mode in [LanguageMode.automatic, .fixed(.finnish), .fixed(.english), .fixed(.turkish)] {
            #expect(storedLanguageMode(value: languageModeStorageValue(mode: mode)) == mode)
        }
        #expect(storedLanguageMode(value: nil) == .automatic)
        #expect(storedLanguageMode(value: "xx") == .automatic)
    }
}
