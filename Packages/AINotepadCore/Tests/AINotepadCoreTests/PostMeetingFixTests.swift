import Foundation
import Testing
@testable import AINotepadCore

@Suite struct PostMeetingFixTests {
    @Test func userFacingMessagesAreTurkishAndActionable() {
        #expect(userFacingMessage(error: LLMError.http(status: 401, body: "x", model: "claude-opus-5-5", requestID: nil)).contains("Anthropic anahtarı kabul edilmedi"))
        #expect(userFacingMessage(error: LLMError.http(status: 429, body: "x", model: "claude-opus-5-5", requestID: nil)).contains("yeniden dene"))
        #expect(userFacingMessage(error: CloudSTTError.http(service: "elevenlabs", status: 401, body: "x")).contains("ElevenLabs anahtarı kabul edilmedi"))
        #expect(userFacingMessage(error: KeychainError.notFound(service: "AINotepad", account: "anthropic")).contains("Ayarlar"))
        #expect(!userFacingMessage(error: LLMError.empty).contains("operation couldn"))
    }
}
