import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// Widget eklentisi: kaydın canlı etkinliği, Denetim Merkezi düğmesi ve ana ekran / kilit ekranı widget'ı.
@main
struct AINotepadWidgetBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivity()
        RecordControl()
        QuickRecordWidget()
    }
}

/// Uygulamanın turuncu vurgusu (Mac'teki varsayılan vurgu).
private let accent: Color = Color(red: 0.91, green: 0.36, blue: 0.11)

/// Kayıt sürerken kilit ekranı ve Dynamic Island: kırmızı nokta, toplantının adı, süre (sistem saatiyle akar,
/// duraklatılınca ve "Bitir"de durur), durum, son cümle (konuşmacısıyla), "Duraklat"/"Devam" ve "Bitir". Etkinliğe dokunmak uygulamayı açar. Dynamic Island'da uygulama
/// öndeyken kendi etkinliği gösterilmez (sistem davranışı); arka planda ya da başka uygulamadayken görünür.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { (context: ActivityViewContext<RecordingActivityAttributes>) in
            LockScreenRecording(context: context)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { (context: ActivityViewContext<RecordingActivityAttributes>) in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        StatusDot(state: context.state, size: 8)
                        Text(statusTitle(state: context.state))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(startedAt: context.attributes.startedAt, state: context.state)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 8) {
                        LastLine(state: context.state)
                        PauseButton(state: context.state)
                        StopButton(isFinishing: context.state.isFinishing)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    StatusDot(state: context.state, size: 7)
                    Image(systemName: statusSymbol(state: context.state, running: "waveform"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor(state: context.state))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(statusTitle(state: context.state)))
            } compactTrailing: {
                ElapsedText(startedAt: context.attributes.startedAt, state: context.state)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 52, alignment: .trailing)
            } minimal: {
                Image(systemName: statusSymbol(state: context.state, running: "mic.fill"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor(state: context.state))
                    .accessibilityLabel(Text(statusTitle(state: context.state)))
            }
            .keylineTint(statusColor(state: context.state))
        }
    }
}

/// Kaydın durum başlığı: bitiriliyor, duraklatıldı, mikrofon bekleniyor ya da kaydediliyor.
private func statusTitle(state: RecordingActivityAttributes.ContentState) -> LocalizedStringResource {
    if state.isFinishing {
        return "Bitiriliyor…"
    }
    if state.isPaused {
        return "Duraklatıldı"
    }
    return state.isMicrophonePaused ? "Mikrofon bekleniyor" : "Kaydediliyor"
}

/// Durumun rengi: kayıtta kırmızı, mikrofon beklenirken turuncu, duraklatılmışken ve bitirilirken gri.
private func statusColor(state: RecordingActivityAttributes.ContentState) -> Color {
    if state.isFinishing || state.isPaused {
        return .gray
    }
    return state.isMicrophonePaused ? .orange : .red
}

/// Dynamic Island'daki durum simgesi: duraklatılmışken duraklatma, mikrofon beklenirken kapalı mikrofon.
private func statusSymbol(state: RecordingActivityAttributes.ContentState, running: String) -> String {
    if state.isPaused {
        return "pause.fill"
    }
    return state.isMicrophonePaused ? "mic.slash.fill" : running
}

/// Durum noktası (renk `statusColor`).
private struct StatusDot: View {
    let state: RecordingActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(statusColor(state: state))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Kaydın süresi: sistem saatiyle akar (uygulama her saniye güncellemez); duraklatılan süreyi saymaz, duraklatılınca ve
/// "Bitir"e basılınca o anda durur.
private struct ElapsedText: View {
    let startedAt: Date
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(
            timerInterval: startedAt.addingTimeInterval(state.pausedSec)...Date.distantFuture, pauseTime: state.pausedAt ?? state.stoppedAt,
            countsDown: false, showsHours: true
        )
    }
}

/// Kilit ekranındaki kart.
private struct LockScreenRecording: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(state: context.state, size: 9)
                Text(context.attributes.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                ElapsedText(startedAt: context.attributes.startedAt, state: context.state)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80, alignment: .trailing)
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle(state: context.state))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(context.state.isMicrophonePaused && !context.state.isFinishing && !context.state.isPaused ? .orange : .white.opacity(0.6))
                    LastLine(state: context.state)
                }
                PauseButton(state: context.state)
                StopButton(isFinishing: context.state.isFinishing)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Son kesinleşen cümle; henüz yoksa "Dinliyor…".
private struct LastLine: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.speaker.isEmpty {
                Text(state.speaker)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }
            Text(state.lastLine.isEmpty ? String(localized: "Dinliyor…") : state.lastLine)
                .font(.system(size: 14))
                .lineLimit(2)
                .foregroundStyle(.white.opacity(state.lastLine.isEmpty ? 0.6 : 0.95))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kaydı uygulamayı açmadan bitiren düğme (App Intent); bitirilirken gizlenir.
private struct StopButton: View {
    let isFinishing: Bool

    var body: some View {
        if !isFinishing {
            Button(intent: StopRecordingIntent()) {
                Label("Bitir", systemImage: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
        }
    }
}

/// Kaydı uygulamayı açmadan duraklatan ya da sürdüren düğme (App Intent); bitirilirken gizlenir.
private struct PauseButton: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if !state.isFinishing {
            Group {
                if state.isPaused {
                    Button(intent: ResumeRecordingIntent()) {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel(Text("Kayda devam et"))
                } else {
                    Button(intent: PauseRecordingIntent()) {
                        Image(systemName: "pause.fill")
                    }
                    .accessibilityLabel(Text("Kaydı duraklat"))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }
}

/// Denetim Merkezi ve Eylem düğmesi: "Toplantıyı kaydet".
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.senoldogan.AINotepad.record") {
            ControlWidgetButton(action: StartRecordingIntent()) {
                Label("Toplantıyı kaydet", systemImage: "mic.fill")
            }
        }
        .displayName("Toplantıyı kaydet")
        .description("Gistsmith'i açar ve yüz yüze toplantıyı kaydetmeye başlar.")
    }
}

/// Ana ekran ve kilit ekranı widget'ı: tek dokunuşla kayıt.
struct QuickRecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.senoldogan.AINotepad.quickRecord", provider: QuickRecordProvider()) { (_: QuickRecordEntry) in
            QuickRecordView()
                // Sistemin widget zemini: açık temada beyaz, koyu temada koyu; renkli (tinted) ana ekranda sistem kaldırır.
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Toplantıyı kaydet")
        .description("Tek dokunuşla yüz yüze toplantıyı kaydetmeye başla.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// Widget içeriği değişmez: tek bir giriş yeter.
struct QuickRecordEntry: TimelineEntry {
    let date: Date
}

struct QuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordEntry {
        QuickRecordEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordEntry) -> Void) {
        completion(QuickRecordEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordEntry(date: Date())], policy: .never))
    }
}

/// Küçük widget: turuncu mikrofon dairesi ve "Toplantıyı kaydet"; kilit ekranında yalnız daire. Yazılar temanın
/// birincil/ikincil renginde (koyu ve renkli ana ekranda da okunur); renkli ana ekranda daire vurgu katmanına girer.
private struct QuickRecordView: View {
    @Environment(\.widgetFamily) private var family: WidgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode: WidgetRenderingMode

    var body: some View {
        Button(intent: StartRecordingIntent()) {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill").font(.system(size: 22, weight: .semibold))
                }
                // Yalnız simge var: VoiceOver simgenin adını değil eylemi okusun.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Toplantıyı kaydet"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        // Renkli ana ekranda dolu daire sistemin vurgu tonunu alır, simge onun üstünde zemin renginde kalır.
                        Circle()
                            .fill(renderingMode == .fullColor ? accent : Color.primary.opacity(0.25))
                            .frame(width: 52, height: 52)
                            .widgetAccentable()
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(renderingMode == .fullColor ? Color.white : Color.primary)
                    }
                    Spacer(minLength: 0)
                    Text("Toplantıyı kaydet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: "Gistsmith")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}
