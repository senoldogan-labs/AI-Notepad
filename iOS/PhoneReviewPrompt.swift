import AINotepadCore
import StoreKit
import SwiftUI
import os

private let phoneReviewPromptLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ReviewPrompt")

/// App Store değerlendirme isteği: toplantı listesindeki işleme durumlarını izler (kayıt ve işleme koduna dokunmaz) ve
/// bu iPhone'da notu yazılan üçüncü (ve sonraki) toplantıdan hemen sonra, karar `reviewPromptStep`'teki kurallarla
/// açılırsa Apple'ın kendi penceresini ister (`RequestReviewAction`; Apple yılda en çok üç kez gösterir, TestFlight'ta
/// hiç göstermez). Kayıt sürerken, karşılama ya da abonelik ekranı açıkken ve uygulama arkadayken sorulmaz.
struct PhoneReviewPrompt: ViewModifier {
    let store: PhoneStore
    let recorder: PhoneRecorder
    let account: HostedAccount
    /// Karşılama bitti mi (bitmediyse tam ekran karşılama açıktır).
    let onboardingCompleted: Bool
    @Environment(\.requestReview) private var requestReview: RequestReviewAction
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content.onChange(of: meetingProcessingMarks(records: store.meetings)) { (previous: [MeetingProcessingMark], current: [MeetingProcessingMark]) in
            let finishedIDs: [String] = meetingsFinishedProcessing(previous: previous, current: current)
            guard !finishedIDs.isEmpty else {
                return
            }
            meetingsFinished(ids: finishedIDs)
        }
    }

    private func meetingsFinished(ids: [String]) {
        let finished: [MeetingRecord] = store.meetings.filter { ids.contains($0.id) }
        let context: ReviewPromptContext = ReviewPromptContext(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            isRecording: recorder.phase != .idle,
            isAppActive: scenePhase == .active,
            isOtherPromptVisible: !onboardingCompleted || account.upsell != nil,
            now: Date()
        )
        do {
            let step: ReviewPromptStep = reviewPromptStep(finished: finished, history: try loadReviewPromptHistory(defaults: .standard), context: context)
            try saveReviewPromptHistory(history: step.history, defaults: .standard)
            guard step.shouldRequest else {
                return
            }
            phoneReviewPromptLogger.info("App Store değerlendirmesi isteniyor, sürüm: \(context.appVersion, privacy: .public), not sayısı: \(step.history.notedMeetingIDs.count, privacy: .public)")
            requestReview()
        } catch {
            phoneReviewPromptLogger.error("Değerlendirme isteğinin geçmişi okunamadı ya da yazılamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }
}
