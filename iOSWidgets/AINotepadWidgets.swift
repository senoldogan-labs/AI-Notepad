import ActivityKit
import AppIntents
import os
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

private let widgetLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Widgets")

/// Uygulamanın varsayılan görünümü: Kor, Kor vurgusuyla.
private let defaultWidgetLook: WidgetLook = WidgetLook(palette: .ember, ember: .standard, classicFill: widgetClassicOrangeFill)

/// Uygulamanın App Group'a yazdığı görünüm (bkz. `WidgetLook`). Uygulama bu sürümle henüz açılmadıysa dosya yoktur:
/// uygulamanın varsayılan görünümü (Kor) çizilir. Dosya okunamazsa widget boş kalamayacağı için hata günlüğe yazılır ve
/// Kor çizilir.
private func sharedWidgetPalette() -> WidgetLook {
    do {
        let url: URL = try widgetPaletteFileURL()
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return defaultWidgetLook
        }
        let contents: String = try String(contentsOf: url, encoding: .utf8)
        do {
            return try widgetLook(fileContents: contents)
        } catch {
            widgetLogger.error(
                "Unknown widget look in the App Group file; drawing Ember. contents: \(contents, privacy: .public), error: \(String(describing: error), privacy: .public)"
            )
            return defaultWidgetLook
        }
    } catch {
        widgetLogger.error("Widget look could not be read; drawing Ember. error: \(String(describing: error), privacy: .public)")
        return defaultWidgetLook
    }
}

/// Klasik paletin turuncu vurgusu (paletten önceki widget'larla aynı).
private let classicAccent: Color = Color(red: 0.91, green: 0.36, blue: 0.11)

/// Onaltılık sRGB renk.
private func widgetColor(hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
}

/// The "Finish" button's fill in the palette (`widgetStopButtonFillHex`: white text at AA in both palettes).
private func stopButtonFill(look: WidgetLook) -> Color {
    widgetColor(hex: widgetStopButtonFillHex(look: look))
}

/// Kayıt düğmesinin Kor küresi, vurgunun tonunda (uygulamadaki `EmberOrbGradient.recordButton` ile aynı duraklar).
private func emberOrb(colors: WidgetEmberColors) -> RadialGradient {
    RadialGradient(
        stops: zip(colors.orb, [0, 0.26, 0.55, 1]).map { (hex: UInt32, location: Double) -> Gradient.Stop in
            Gradient.Stop(color: widgetColor(hex: hex), location: location)
        },
        center: UnitPoint(x: 0.22, y: 0.18), startRadius: 0, endRadius: 59
    )
}

/// Widget zemini: Kor'un krem ve sıcak siyah zemini (renkli ana ekranda sistem kaldırır).
private let emberField: Color = Color(uiColor: UIColor { (traits: UITraitCollection) -> UIColor in
    traits.userInterfaceStyle == .dark
        ? UIColor(red: 0x10 / 255, green: 0x0E / 255, blue: 0x0D / 255, alpha: 1)
        : UIColor(red: 0xF6 / 255, green: 0xF0 / 255, blue: 0xE7 / 255, alpha: 1)
})

/// Kayıt sürerken kilit ekranı ve Dynamic Island: kırmızı nokta, toplantının adı, süre (sistem saatiyle akar,
/// duraklatılınca ve "Bitir"de durur), durum, son cümle (konuşmacısıyla), "Duraklat"/"Devam" ve "Bitir". Etkinliğe dokunmak uygulamayı açar. Dynamic Island'da uygulama
/// öndeyken kendi etkinliği gösterilmez (sistem davranışı); arka planda ya da başka uygulamadayken görünür.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { (context: ActivityViewContext<RecordingActivityAttributes>) in
            LockScreenRecording(context: context, palette: sharedWidgetPalette())
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { (context: ActivityViewContext<RecordingActivityAttributes>) in
            let palette: WidgetLook = sharedWidgetPalette()
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        StatusDot(state: context.state, size: 8)
                        Text(statusTitle(state: context.state))
                            .font(.system(.footnote, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(startedAt: context.attributes.startedAt, state: context.state)
                        .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 80, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.isStale {
                        StaleRecording(title: context.attributes.title)
                            .padding(.horizontal, 4)
                    } else {
                        HStack(alignment: .center, spacing: 8) {
                            LastLine(state: context.state, palette: palette)
                            MarkButton(state: context.state)
                            PauseButton(state: context.state, recordingID: context.attributes.recordingID)
                            StopButton(isFinishing: context.state.status.isFinishing, recordingID: context.attributes.recordingID, palette: palette)
                        }
                        .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    StatusDot(state: context.state, size: 7)
                    Image(systemName: statusSymbol(state: context.state, running: "waveform"))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(statusColor(state: context.state))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(statusTitle(state: context.state)))
            } compactTrailing: {
                if context.isStale {
                    // Eskimiş etkinlikte süre akmaz (uygulama kaydı sürdürmüyor olabilir).
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Kayıt durmuş olabilir"))
                } else {
                    ElapsedText(startedAt: context.attributes.startedAt, state: context.state)
                        .font(.system(.footnote, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 52, alignment: .trailing)
                }
            } minimal: {
                Image(systemName: statusSymbol(state: context.state, running: "mic.fill"))
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(statusColor(state: context.state))
                    .accessibilityLabel(Text(statusTitle(state: context.state)))
            }
            .keylineTint(statusColor(state: context.state))
        }
    }
}

/// Kaydın durum başlığı: bitiriliyor, duraklatıldı, mikrofon bekleniyor ya da kaydediliyor.
private func statusTitle(state: RecordingActivityAttributes.ContentState) -> LocalizedStringResource {
    switch state.status {
    case .finishing:
        "Bitiriliyor…"
    case .paused:
        "Duraklatıldı"
    case .waitingForMicrophone:
        "Mikrofon bekleniyor"
    case .recording:
        "Kaydediliyor"
    }
}

/// Durumun rengi: kayıtta kırmızı, mikrofon beklenirken turuncu, duraklatılmışken ve bitirilirken gri.
private func statusColor(state: RecordingActivityAttributes.ContentState) -> Color {
    switch state.status {
    case .finishing, .paused:
        .gray
    case .waitingForMicrophone:
        .orange
    case .recording:
        .red
    }
}

/// Dynamic Island'daki durum simgesi: duraklatılmışken duraklatma, mikrofon beklenirken kapalı mikrofon.
private func statusSymbol(state: RecordingActivityAttributes.ContentState, running: String) -> String {
    switch state.status {
    case .paused:
        "pause.fill"
    case .waitingForMicrophone:
        "mic.slash.fill"
    case .recording, .finishing:
        running
    }
}

/// Kilit ekranındaki durum başlığının rengi: mikrofon beklenirken turuncu, değilse soluk beyaz.
private func statusTitleColor(status: LiveRecordingStatus) -> Color {
    if case .waitingForMicrophone = status {
        return .orange
    }
    return .white.opacity(0.6)
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
            timerInterval: startedAt.addingTimeInterval(state.pausedSec)...Date.distantFuture, pauseTime: state.status.timerStoppedAt,
            countsDown: false, showsHours: true
        )
    }
}

/// Kilit ekranındaki kart.
private struct LockScreenRecording: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    let palette: WidgetLook

    var body: some View {
        if context.isStale {
            StaleRecording(title: context.attributes.title)
        } else {
            live
        }
    }

    private var live: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusDot(state: context.state, size: 9)
                Text(context.attributes.title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                ElapsedText(startedAt: context.attributes.startedAt, state: context.state)
                    .font(.system(.subheadline, weight: .semibold).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80, alignment: .trailing)
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusTitle(state: context.state))
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(statusTitleColor(status: context.state.status))
                    LastLine(state: context.state, palette: palette)
                }
                MarkButton(state: context.state)
                PauseButton(state: context.state, recordingID: context.attributes.recordingID)
                StopButton(isFinishing: context.state.status.isFinishing, recordingID: context.attributes.recordingID, palette: palette)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Uygulama kayıt sürerken etkinliği yenilemeyi bıraktı (çöktü ya da sistem kapattı): süre akmaya devam etmesin,
/// "Kaydediliyor" yanıltmasın. Dokununca uygulama açılır; o ana kadarki ses saklıdır.
private struct StaleRecording: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
            }
            Text("Kayıt durmuş olabilir")
                .font(.system(.subheadline, weight: .semibold))
            Text("Durumunu görmek için uygulamayı aç; o ana kadarki ses saklandı.")
                .font(.system(.footnote))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// Şu anı uygulamayı açmadan işaretler (notta öne çıkar); süre durmuşken (duraklatma, kesinti) ve bitirilirken gizlenir.
private struct MarkButton: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.status.timerStoppedAt == nil {
            Button(intent: MarkMomentIntent()) {
                Image(systemName: "bookmark.fill")
            }
            .font(.system(.footnote, weight: .semibold))
            .buttonStyle(.bordered)
            .tint(.white)
            .accessibilityLabel(Text("Bu anı işaretle"))
        }
    }
}

/// Son kesinleşen cümle; henüz yoksa "Dinliyor…".
private struct LastLine: View {
    let state: RecordingActivityAttributes.ContentState
    let palette: WidgetLook

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !state.speaker.isEmpty {
                Text(state.speaker)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(palette.palette == .ember ? widgetColor(hex: palette.ember.onDark) : classicAccent)
            }
            Text(state.lastLine.isEmpty ? String(localized: "Dinliyor…") : state.lastLine)
                .font(.system(.subheadline))
                .lineLimit(2)
                .foregroundStyle(.white.opacity(state.lastLine.isEmpty ? 0.6 : 0.95))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Kaydı uygulamayı açmadan bitiren düğme (App Intent); bitirilirken gizlenir. Düğme etkinliğin kaydını hedefler: eski
/// bir etkinlikten basılırsa yeni kaydı bitirmez (eski sürümün etkinliğinde kimlik yoksa süren kaydı bitirir).
private struct StopButton: View {
    let isFinishing: Bool
    let recordingID: String?
    let palette: WidgetLook

    var body: some View {
        if !isFinishing {
            Group {
                if let recordingID {
                    Button(intent: StopLiveRecordingIntent(recordingID: recordingID)) {
                        Label("Bitir", systemImage: "stop.fill")
                    }
                } else {
                    Button(intent: StopRecordingIntent()) {
                        Label("Bitir", systemImage: "stop.fill")
                    }
                }
            }
            .font(.system(.footnote, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .tint(stopButtonFill(look: palette))
        }
    }
}

/// Kaydı uygulamayı açmadan duraklatan ya da sürdüren düğme (App Intent); bitirilirken gizlenir. Düğme etkinliğin kaydını
/// hedefler (bkz. `StopButton`).
private struct PauseButton: View {
    let state: RecordingActivityAttributes.ContentState
    let recordingID: String?

    var body: some View {
        if !state.status.isFinishing {
            Group {
                if state.status.isPausedByUser {
                    resumeButton
                        .accessibilityLabel(Text("Kayda devam et"))
                } else {
                    pauseButton
                        .accessibilityLabel(Text("Kaydı duraklat"))
                }
            }
            .font(.system(.footnote, weight: .semibold))
            .buttonStyle(.bordered)
            .tint(.white)
        }
    }

    @ViewBuilder private var resumeButton: some View {
        if let recordingID {
            Button(intent: ResumeLiveRecordingIntent(recordingID: recordingID)) {
                Image(systemName: "play.fill")
            }
        } else {
            Button(intent: ResumeRecordingIntent()) {
                Image(systemName: "play.fill")
            }
        }
    }

    @ViewBuilder private var pauseButton: some View {
        if let recordingID {
            Button(intent: PauseLiveRecordingIntent(recordingID: recordingID)) {
                Image(systemName: "pause.fill")
            }
        } else {
            Button(intent: PauseRecordingIntent()) {
                Image(systemName: "pause.fill")
            }
        }
    }
}

/// Denetim Merkezi ve Eylem düğmesi: kaydı başlatır ya da süren kaydı bitirir (aç/kapa). Uygulama açılmaz; kayıt kilit
/// ekranında görünür. Durum kaydın canlı etkinliğinden okunur; uygulama durum değişince düğmeyi yeniler.
struct RecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: recordControlKind, provider: RecordingControlValueProvider()) { (isRecording: Bool) in
            ControlWidgetToggle("Toplantıyı kaydet", isOn: isRecording, action: ToggleRecordingIntent()) { (isOn: Bool) in
                Label(isOn ? "Kaydediliyor" : "Toplantıyı kaydet", systemImage: isOn ? "stop.circle.fill" : "mic.fill")
            }
            .tint(.red)
        }
        .displayName("Toplantıyı kaydet")
        .description("Yüz yüze toplantıyı uygulamayı açmadan kaydetmeye başlar; yeniden basınca bitirir.")
    }
}

/// Denetim Merkezi düğmesinin durumu: süren (bitirilmeyen) bir kayıt etkinliği varsa açık.
struct RecordingControlValueProvider: ControlValueProvider {
    let previewValue: Bool = false

    func currentValue() async throws -> Bool {
        Activity<RecordingActivityAttributes>.activities.contains { (activity: Activity<RecordingActivityAttributes>) -> Bool in
            activity.activityState == .active && !activity.content.state.status.isFinishing
        }
    }
}

/// Ana ekran ve kilit ekranı widget'ı: tek dokunuşla kayıt.
struct QuickRecordWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.senoldogan.AINotepad.quickRecord", provider: QuickRecordProvider()) { (entry: QuickRecordEntry) in
            QuickRecordView(palette: entry.palette)
                // Kor'da krem ve sıcak siyah, Klasik'te sistemin zemini (açıkta beyaz, koyuda koyu); renkli (tinted) ana
                // ekranda sistem kaldırır.
                .containerBackground(for: .widget) { entry.palette.palette == .ember ? emberField : Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Toplantıyı kaydet")
        .description("Tek dokunuşla yüz yüze toplantıyı kaydetmeye başla.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

/// Widget içeriği değişmez: tek bir giriş yeter; uygulama palet değişince zaman çizelgesini yeniler.
struct QuickRecordEntry: TimelineEntry {
    let date: Date
    let palette: WidgetLook
}

struct QuickRecordProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickRecordEntry {
        QuickRecordEntry(date: Date(), palette: sharedWidgetPalette())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickRecordEntry) -> Void) {
        completion(QuickRecordEntry(date: Date(), palette: sharedWidgetPalette()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickRecordEntry>) -> Void) {
        completion(Timeline(entries: [QuickRecordEntry(date: Date(), palette: sharedWidgetPalette())], policy: .never))
    }
}

/// Küçük widget: Kor küresinde (Klasik'te vurgu renginde dairede) mikrofon ve "Toplantıyı kaydet"; kilit ekranında yalnız daire.
/// Yazılar temanın birincil/ikincil renginde (koyu ve renkli ana ekranda da okunur); renkli ana ekranda daire vurgu
/// katmanına girer.
private struct QuickRecordView: View {
    let palette: WidgetLook
    @Environment(\.widgetFamily) private var family: WidgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode: WidgetRenderingMode

    var body: some View {
        Button(intent: StartRecordingIntent()) {
            if family == .accessoryCircular {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "mic.fill").font(.system(.title2, weight: .semibold))
                }
                // Yalnız simge var: VoiceOver simgenin adını değil eylemi okusun.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Toplantıyı kaydet"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack {
                        // Renkli ana ekranda dolu daire sistemin vurgu tonunu alır, simge onun üstünde zemin renginde kalır.
                        Circle()
                            .fill(renderingMode == .fullColor ? fullColorFill : AnyShapeStyle(Color.primary.opacity(0.25)))
                            .frame(width: 52, height: 52)
                            .widgetAccentable()
                        Image(systemName: "mic.fill")
                            .font(.system(.title2, weight: .semibold))
                            .foregroundStyle(renderingMode == .fullColor ? Color.white : Color.primary)
                    }
                    Spacer(minLength: 0)
                    Text("Toplantıyı kaydet")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(verbatim: "Gistsmith")
                        .font(.system(.caption))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    /// Tam renkli ana ekranda dairenin dolgusu: Kor küresi ya da Klasik'te vurgu rengi.
    private var fullColorFill: AnyShapeStyle {
        switch palette.palette {
        case .ember: AnyShapeStyle(emberOrb(colors: palette.ember))
        case .classic: AnyShapeStyle(widgetColor(hex: palette.classicFill))
        }
    }
}
