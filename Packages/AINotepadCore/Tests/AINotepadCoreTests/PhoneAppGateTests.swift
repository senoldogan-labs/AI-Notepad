import AINotepadCore
import Testing

struct PhoneAppGateTests {
    // Oturum kayıt sürerken kapanırsa (ya da hesabın onayı okunamazsa) kayıt ekranı ve "Bitir" kalır; kayıt yokken önce
    // giriş, sonra açıklama.
    @Test func recordingOutlivesSessionAndConsent() {
        #expect(phoneAppGate(requiresSignIn: true, isRecording: true, aiConsentGiven: false) == .main)
        #expect(phoneAppGate(requiresSignIn: true, isRecording: false, aiConsentGiven: true) == .signIn)
        #expect(phoneAppGate(requiresSignIn: true, isRecording: false, aiConsentGiven: false) == .signIn)
        #expect(phoneAppGate(requiresSignIn: false, isRecording: false, aiConsentGiven: false) == .aiConsent)
        #expect(phoneAppGate(requiresSignIn: false, isRecording: false, aiConsentGiven: true) == .main)
    }

    // Karşılama sürerken istenen abonelik ekranı karşılama bitince açılır.
    @Test func paywallWaitsForOnboarding() {
        #expect(phoneRootCover(onboardingCompleted: false, upsell: .trialNoteReady) == .onboarding)
        #expect(phoneRootCover(onboardingCompleted: true, upsell: .trialNoteReady) == .paywall(.trialNoteReady))
        #expect(phoneRootCover(onboardingCompleted: true, upsell: nil) == nil)
    }
}
