#if CALL_CAPTURE_EXPERIMENT
import AINotepadCore
import AINotepadUI
import SwiftUI

// Metinler `Text(verbatim:)`: deneysel ekran metin kataloğuna girmez (yalnız bayraklı derlemede var).

/// "Bu iPhone'daki görüşmeyi kaydet (deneysel)": Toplantılar › İçe aktar menüsünden açılan sayfa. iOS 27 öncesinde
/// yalnız nedenini söyler.
struct CallCaptureExperimentScreen: View {
    let recorder: PhoneRecorder
    /// Yüz yüze kayıt sürüyor: aynı anda başlatılmaz (mikrofon ve ses oturumu paylaşılır).
    let isRecording: Bool
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            Group {
                #if canImport(ScreenCaptureKit)
                if #available(iOS 27.0, *) {
                    CallCaptureExperimentContent(recorder: recorder, isRecording: isRecording) { dismiss() }
                } else {
                    Text(verbatim: "Bu deneme iOS 27'nin ScreenCaptureKit'ini kullanır; iOS 27 gerekir.")
                        .foregroundStyle(Theme.muted)
                        .padding(24)
                }
                #else
                Text(verbatim: "ScreenCaptureKit iOS Simulator'da yok; gerçek iPhone'da (iOS 27) dene.")
                    .foregroundStyle(Theme.muted)
                    .padding(24)
                #endif
            }
            .background(Theme.background)
            .navigationTitle(Text(verbatim: "Görüşme kaydı (deneysel)"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#if canImport(ScreenCaptureKit)
@available(iOS 27.0, *)
private struct CallCaptureExperimentContent: View {
    let recorder: PhoneRecorder
    let isRecording: Bool
    let onClose: @MainActor () -> Void
    @State private var controller: CallCaptureController = CallCaptureController()

    var body: some View {
        let phase: CallCapturePhase = controller.phase
        List {
            Section {
                Text(verbatim: "Görüşmeyi kaydetmeden önce katılımcılara haber ver. Başlat'a basınca açılan sistem penceresinde mikrofonu aç ve ekranı paylaş; yalnız ses kaydedilir. Sonra Teams'e ya da Zoom'a geç; dönünce sayaçlar sistem sesinin gelip gelmediğini gösterir.")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            if !controller.errorMessages.isEmpty {
                Section {
                    ForEach(Array(controller.errorMessages.enumerated()), id: \.offset) { (item: (offset: Int, element: String)) in
                        Text(verbatim: item.element)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(verbatim: "Hatalar")
                }
            }
            Section {
                CallSourceRow(title: "Sistem sesi (karşı taraf)", levels: controller.systemLevels, stats: controller.systemStats, isEnabled: true)
                CallSourceRow(
                    title: "Mikrofon (sen)", levels: controller.microphoneLevels, stats: controller.microphoneStats,
                    isEnabled: controller.microphoneEnabled || phase == .idle || phase == .picking
                )
            } header: {
                Text(verbatim: "Kaynaklar")
            }
            Section {
                controls(phase: phase)
            }
            if !controller.rawFiles.isEmpty {
                Section {
                    ShareLink(items: controller.rawFiles) {
                        Label { Text(verbatim: "Ham dosyaları paylaş") } icon: { Image(systemName: "square.and.arrow.up") }
                    }
                } footer: {
                    Text(verbatim: controller.rawFiles.map(\.lastPathComponent).joined(separator: ", "))
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { onClose() } label: { Text(verbatim: "Kapat") }
                    .disabled(isBusy(phase: phase))
            }
        }
        // Akış sayfanın denetleyicisinde yaşar: kayıt sürerken sayfa kaydırılarak kapatılamaz.
        .interactiveDismissDisabled(isBusy(phase: phase))
    }

    @ViewBuilder
    private func controls(phase: CallCapturePhase) -> some View {
        switch phase {
        case .idle:
            Button { controller.start() } label: { Label { Text(verbatim: "Başlat") } icon: { Image(systemName: "record.circle") } }
                .disabled(isRecording || !controller.isAvailable)
            if isRecording {
                Text(verbatim: "Önce süren kaydı bitir.").foregroundStyle(Theme.muted)
            } else if !controller.isAvailable {
                Text(verbatim: "Bu cihazda ekran kaydı kullanılamıyor (Ekran Süresi kısıtlaması olabilir).").foregroundStyle(Theme.muted)
            }
        case .picking:
            HStack(spacing: 8) {
                ProgressView()
                Text(verbatim: "Sistem penceresi bekleniyor…")
            }
        case .capturing(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                Text(verbatim: "Kayıt sürüyor: \(Duration.seconds(context.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))")
                    .monospacedDigit()
            }
            Button(role: .destructive) {
                Task { await controller.stop() }
            } label: {
                Label { Text(verbatim: "Durdur") } icon: { Image(systemName: "stop.circle") }
            }
        case .finishing:
            HStack(spacing: 8) {
                ProgressView()
                Text(verbatim: "Dosyalar karıştırılıyor…")
            }
        case .finished:
            Button {
                Task {
                    await controller.importAsMeeting(recorder: recorder)
                    onClose()
                }
            } label: {
                Label { Text(verbatim: "Toplantı olarak içe aktar") } icon: { Image(systemName: "square.and.arrow.down") }
            }
            Button { controller.start() } label: { Label { Text(verbatim: "Yeniden kaydet (bu kayıt silinir)") } icon: { Image(systemName: "arrow.clockwise") } }
        }
    }

    private func isBusy(phase: CallCapturePhase) -> Bool {
        switch phase {
        case .picking, .capturing, .finishing: true
        case .idle, .finished: false
        }
    }
}

#endif

/// Bir kaynağın canlı ölçeri ve sayaçları (cihaz testinin raporu bunlarla verilir).
private struct CallSourceRow: View {
    let title: String
    let levels: AudioLevels
    let stats: CallSourceStats
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: title).appFont(size: 15, weight: .semibold)
                Spacer()
                if !isEnabled {
                    Text(verbatim: "seçicide kapalı").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                }
            }
            LevelMeter(levels: levels)
            Text(verbatim: callStatsSummary(stats: stats))
                .appFont(size: 12, weight: .regular)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 4)
    }
}

/// Sayaçların tek satırlık özeti. Saf fonksiyondur.
func callStatsSummary(stats: CallSourceStats) -> String {
    let peak: Int = Int((stats.peakLevel * 100).rounded())
    return "\(Int(stats.seconds)) sn ses · \(Int(stats.loudSeconds)) sn sesli · tepe %\(peak) · \(stats.buffers) parça · boşluk \(Int(stats.gapSeconds)) sn"
}
#endif
