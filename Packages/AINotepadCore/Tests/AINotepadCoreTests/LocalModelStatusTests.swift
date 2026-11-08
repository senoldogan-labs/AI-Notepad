import AINotepadCore
import Testing

struct LocalModelStatusTests {
    // Apple modeli indirilirken WhisperKit seçildi; Apple'ın geç gelen "hazır"ı ya da "başarısız"ı WhisperKit'in
    // durumunu değiştirmez.
    @Test func lateResultOfOneEngineLeavesTheOtherAlone() {
        let start: LocalModelStatuses = LocalModelStatuses(whisperKit: .loading, appleSpeech: .loading)
        let appleReady: LocalModelStatuses = start.with(model: .appleSpeech, status: .ready)
        #expect(appleReady.status(of: .whisperKit) == .loading)
        #expect(appleReady.status(of: .appleSpeech) == .ready)
        let whisperReady: LocalModelStatuses = LocalModelStatuses(whisperKit: .ready, appleSpeech: .loading)
        #expect(whisperReady.with(model: .appleSpeech, status: .failed("x")).status(of: .whisperKit) == .ready)
    }
}
