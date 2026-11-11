import AINotepadCore
import Testing

struct PhoneAppGateTests {
    // Oturum kayıt sürerken kapanırsa (ya da hesabın onayı okunamazsa) kayıt ekranı ve "Bitir" kalır; kayıt yokken önce
    // giriş, sonra açıklama.
    @Test func recordingOutlivesSessionAndConsent() {
        #expect(phoneAppGate(requiresSignIn: true, isRecording: true, needsAIConsentPrompt: true) == .main)
        #expect(phoneAppGate(requiresSignIn: true, isRecording: false, needsAIConsentPrompt: false) == .signIn)
        #expect(phoneAppGate(requiresSignIn: true, isRecording: false, needsAIConsentPrompt: true) == .signIn)
        #expect(phoneAppGate(requiresSignIn: false, isRecording: false, needsAIConsentPrompt: true) == .aiConsent)
        #expect(phoneAppGate(requiresSignIn: false, isRecording: false, needsAIConsentPrompt: false) == .main)
    }

    // Karşılama sürerken istenen abonelik ekranı karşılama bitince açılır.
    @Test func paywallWaitsForOnboarding() {
        #expect(phoneRootCover(onboardingCompleted: false, upsell: .subscriptionRequired, isExpanded: false) == .onboarding)
        #expect(phoneRootCover(onboardingCompleted: true, upsell: .subscriptionRequired, isExpanded: false) == .paywall(.subscriptionRequired))
        #expect(phoneRootCover(onboardingCompleted: true, upsell: nil, isExpanded: false) == nil)
    }

    // Kendiliğinden gelen anlar ana ekranda kart olur; tam ekran yalnızca karttan "Planları gör" ile açılır.
    @Test func stripMomentsNeverOpenTheCoverByThemselves() {
        for moment in [HostedUpsellMoment.trialNoteReady, .trialEnding, .trialEnded, .winBack] {
            #expect(phoneRootCover(onboardingCompleted: true, upsell: moment, isExpanded: false) == nil)
            #expect(phoneRootCover(onboardingCompleted: true, upsell: moment, isExpanded: true) == .paywall(moment))
        }
        #expect(phoneRootCover(onboardingCompleted: true, upsell: .planChoice, isExpanded: false) == .paywall(.planChoice))
    }
}
