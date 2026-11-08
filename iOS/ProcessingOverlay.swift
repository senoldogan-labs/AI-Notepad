import AINotepadCore
import AINotepadUI
import SwiftUI

/// Hazırlığın adımları (katman ve ana ekrandaki kart aynı adımları gösterir); iPhone'da son geçiş her zaman sunucuda.
@MainActor let phoneProcessingStepTitles: [LocalizedStringKey] = ["Kayıt bitiriliyor", "Ses kaydı hazırlanıyor", "Kaydın tamamı işleniyor", "Not hazırlanıyor"]

/// Hazırlık katmanının durumu: hangi toplantı (bitirilirken henüz yok) ve kaçıncı adım.
struct PhoneProcessingProgress: Equatable {
    let meetingID: String?
    /// 0: kayıt bitiriliyor, 1: ses, 2: son geçiş, 3: not.
    let stepIndex: Int
}

/// Gösterilecek hazırlık: kayıt bitiriliyorsa ilk adım, son biten toplantı işleniyorsa onun adımı; kullanıcı katmanı
/// kapattıysa nil (hazırlık kartı ana ekranda kalır). Saf fonksiyondur.
func phoneProcessingProgress(
    phase: RecorderPhase, lastMeetingID: String?, processingSteps: [String: ProcessingStep], finishingDismissed: Bool, dismissedMeetingIDs: Set<String>
) -> PhoneProcessingProgress? {
    if phase == .finishing {
        return finishingDismissed ? nil : PhoneProcessingProgress(meetingID: nil, stepIndex: 0)
    }
    guard phase == .idle, !finishingDismissed, let id = lastMeetingID, let step = processingSteps[id], !dismissedMeetingIDs.contains(id) else {
        return nil
    }
    return PhoneProcessingProgress(meetingID: id, stepIndex: step.rawValue + 1)
}

/// Kayıt bitirilirken ve biten toplantı işlenirken (Mac'teki işleme katmanı gibi): arkadaki ekran durağan bulanıklaşır,
/// ortada küçük animasyonlu simge, adımlar ve ilerleme. "Arka planda devam et" katmanı kapatır (hazırlık kartı ana
/// ekranda kalır). Kullanıcı ana ekranda beklediyse işleme bitince toplantının sayfası açılır. Katman açıkken gezinme
/// çubuğu gizlidir (görevler, arama ve ayarlar düğmeleri katmanın üstünde dokunulabilir kalmasın).
struct PhoneProcessingOverlayHost: ViewModifier {
    let recorder: PhoneRecorder
    let store: PhoneStore
    let router: PhoneRouter
    @State private var finishingDismissed: Bool = false
    @State private var dismissedMeetingIDs: Set<String> = []

    func body(content: Content) -> some View {
        let progress: PhoneProcessingProgress? = phoneProcessingProgress(
            phase: recorder.phase, lastMeetingID: recorder.lastMeetingID, processingSteps: recorder.processingSteps,
            finishingDismissed: finishingDismissed, dismissedMeetingIDs: dismissedMeetingIDs
        )
        content
            // Durağan bulanıklık: yalnız kart içindeki küçük simge hareket eder (bulanık katman yeniden çizilmez).
            .blur(radius: progress == nil ? 0 : 10)
            .overlay {
                if progress != nil {
                    Theme.background.opacity(0.35)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(progress == nil)
            .overlay {
                if let progress {
                    PhoneProcessingCard(progress: progress) {
                        if let id = progress.meetingID {
                            dismissedMeetingIDs.insert(id)
                        } else {
                            finishingDismissed = true
                        }
                    }
                    .padding(.horizontal, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: progress)
            .toolbar(progress == nil ? .automatic : .hidden, for: .navigationBar)
            .onChange(of: recorder.phase) { (_: RecorderPhase, phase: RecorderPhase) in
                // Yeni kayıt: önceki kayıtta kapatılan katman bu kayıtta yeniden görünür.
                if phase == .recording {
                    finishingDismissed = false
                }
            }
            .onChange(of: progress) { (previous: PhoneProcessingProgress?, current: PhoneProcessingProgress?) in
                // İşleme bitti ve kullanıcı katmanı kapatmadan bekledi: toplantının sayfası açılır (Mac'teki gibi).
                guard current == nil, let id = previous?.meetingID, recorder.processingSteps[id] == nil, !dismissedMeetingIDs.contains(id),
                      router.isOnHome, store.meetings.contains(where: { (record: MeetingRecord) -> Bool in record.id == id }) else {
                    return
                }
                router.show(meetingID: id)
            }
    }
}

/// Ortadaki hazırlık kartı: küçük animasyonlu dalga simgesi (hareketi azalt açıkken durgun), adımlar (biten ✓, süren
/// gösterge, bekleyen soluk), ilerleme çubuğu ve "Arka planda devam et".
private struct PhoneProcessingCard: View {
    let progress: PhoneProcessingProgress
    let onDismiss: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    private let steps: [LocalizedStringKey] = phoneProcessingStepTitles

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(appearance.accent.color.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "waveform")
                    .appFont(size: 28, weight: .medium)
                    .foregroundStyle(appearance.accent.color)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating, isActive: !reduceMotion)
            }
            .accessibilityHidden(true)
            Text("Toplantı hazırlanıyor")
                .appFont(size: 18, weight: .semibold)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(steps.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                    HStack(spacing: 10) {
                        Group {
                            if item.offset < progress.stepIndex {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(appearance.accent.color)
                            } else if item.offset == progress.stepIndex {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(Theme.muted.opacity(0.6))
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(item.element)
                            .appFont(size: 14, weight: item.offset == progress.stepIndex ? .semibold : .regular)
                            .foregroundStyle(item.offset > progress.stepIndex ? Theme.muted : Theme.ink)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ProgressView(value: Double(progress.stepIndex) + 0.5, total: Double(steps.count))
                .tint(appearance.accent.color)
            Text("Bitince toplantının sayfası açılır; görevlerin en üstte.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button(action: onDismiss) {
                Text("Arka planda devam et")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
    }
}
