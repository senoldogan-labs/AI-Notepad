import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI
import os

private let recommendLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ReviewPrompt")

/// Mac'teki değerlendirme isteğinin karşılığı. Gistsmith Mac'te App Store dışında (notarize edilmiş DMG) dağıtılır: Mac App
/// Store değerlendirmesi yoktur, `requestReview` hiçbir şey göstermez; iPhone uygulamasını değerlendirmesini istemek de
/// iPhone'u olmayan kullanıcıya anlamsızdır. Bu yüzden aynı olumlu anda (bkz. `reviewPromptStep`) ana pencerenin
/// üstünde, açılır pencere olmadan, kapatılabilir bir şerit bir kez görünür: "Bir arkadaşına öner" (abonenin davet
/// bağlantısıyla, yoksa sitenin adresiyle) ve "Geri bildirim yaz…" (alıntı izni kutusu olan form).
@MainActor
@Observable
final class HostedRecommendPrompt {
    static let shared: HostedRecommendPrompt = HostedRecommendPrompt()

    /// Şerit görünüyor mu (kapatılınca ya da bir eylem seçilince kalkar; yeniden açılışta görünmez).
    private(set) var isVisible: Bool = false

    private init() {
        #if DEBUG
        // Görsel kontrol: `--oneri-seridi` şeridi açık başlatır.
        isVisible = CommandLine.arguments.contains("--oneri-seridi")
        #endif
    }

    /// İşlemesi biten toplantılar: karar açarsa şerit gösterilir ve davet bağlantısı okunur.
    func meetingsFinished(records: [MeetingRecord], context: ReviewPromptContext) {
        do {
            let step: ReviewPromptStep = reviewPromptStep(finished: records, history: try loadReviewPromptHistory(defaults: .standard), context: context)
            try saveReviewPromptHistory(history: step.history, defaults: .standard)
            guard step.shouldRequest else {
                return
            }
            recommendLogger.info("Öneri şeridi gösteriliyor, sürüm: \(context.appVersion, privacy: .public), not sayısı: \(step.history.notedMeetingIDs.count, privacy: .public)")
            isVisible = true
            Task { await HostedAccount.shared.loadReferral() }
        } catch {
            recommendLogger.error("Değerlendirme isteğinin geçmişi okunamadı ya da yazılamadı, hata: \(String(describing: error), privacy: .public)")
        }
    }

    func dismiss() {
        isVisible = false
    }
}

/// Ana penceredeki toplantı listesini izler (kayıt ve işleme koduna dokunmaz): işlemesi biten toplantılar
/// `HostedRecommendPrompt`'a verilir.
struct HostedRecommendPromptObserver: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.onChange(of: meetingProcessingMarks(records: model.meetings)) { (previous: [MeetingProcessingMark], current: [MeetingProcessingMark]) in
            let finishedIDs: [String] = meetingsFinishedProcessing(previous: previous, current: current)
            guard !finishedIDs.isEmpty else {
                return
            }
            let account: HostedAccount = .shared
            HostedRecommendPrompt.shared.meetingsFinished(
                records: model.meetings.filter { finishedIDs.contains($0.id) },
                context: ReviewPromptContext(
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                    isRecording: model.isRecording,
                    isAppActive: NSApp.isActive,
                    isOtherPromptVisible: account.upsell != nil || account.visibleNotice != nil,
                    now: Date()
                )
            )
        }
    }
}

/// Öneri şeridi: güncelleme ve çökme şeritleriyle aynı sakin görünüm.
struct HostedRecommendBanner: View {
    let prompt: HostedRecommendPrompt
    let account: HostedAccount
    let makeDiagnostics: @MainActor () async -> String
    @State private var isFeedbackOpen: Bool = false

    var body: some View {
        NoticeBar(
            severity: .info,
            title: Text("Gistsmith işine yarıyor mu?"),
            detail: Text("Bir arkadaşına öner ya da ne düşündüğünü bize yaz."),
            onDismiss: { prompt.dismiss() }
        ) {
            if let text = shareText {
                ShareLink(item: text) {
                    Text("Bir arkadaşına öner")
                }
                .buttonStyle(.pill)
            }
            Button("Geri bildirim yaz…") { isFeedbackOpen = true }
                .buttonStyle(.pill)
        }
        .sheet(isPresented: $isFeedbackOpen, onDismiss: { prompt.dismiss() }) {
            FeedbackSheet(makeDiagnostics: makeDiagnostics) { isFeedbackOpen = false }
                .frame(width: 520)
                .modifier(AppSheetChrome())
        }
    }

    /// Abonenin davet bağlantısı varsa davet metni; yoksa sitenin adresiyle kısa öneri. Site adresi okunamazsa (Info.plist
    /// eksik) paylaşım düğmesi gösterilmez.
    private var shareText: String? {
        if let referral = account.referral, referral.enabled, let inviteURL = referral.inviteUrl {
            return hostedInviteText(inviteURL: inviteURL)
        }
        do {
            return hostedRecommendText(siteURL: try HostedServices.siteBase())
        } catch {
            recommendLogger.error("Site adresi okunamadı, hata: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Davet bağlantısı olmayan kullanıcının paylaştığı öneri (sitenin adresiyle; iPhone'daki davet metniyle aynı cümle).
/// Saf fonksiyondur.
func hostedRecommendText(siteURL: URL) -> String {
    String(localized: "Toplantılarım için Gistsmith kullanıyorum: konuşulanı canlı yazıya döküyor, toplantı bitince notu ve görevleri hazırlıyor. Sen de bak: \(siteURL.absoluteString)")
}
