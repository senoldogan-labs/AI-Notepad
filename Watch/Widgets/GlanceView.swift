import AINotepadWatchLink
import SwiftUI
import WidgetKit

// The glance's views (complication and Smart Stack), apart from the widget so the Watch tests can draw them.

struct GlanceEntry: TimelineEntry {
    let date: Date
    let content: WatchGlanceContent
}

/// The glance for one widget family.
struct GlanceView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced: Bool
    let entry: GlanceEntry
    /// The widget's family (passed in, so the Watch tests can draw every family outside a widget).
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3)
                .widgetLabel { inlineText }
        case .accessoryInline:
            inlineText
        default:
            rectangular
        }
    }

    private var symbol: String {
        switch entry.content {
        case .watchRecording(_, let pausedAt):
            pausedAt == nil ? "mic.fill" : "pause.fill"
        case .phoneRecording(let recording):
            recording.phase == .paused ? "pause.fill" : "iphone"
        case .nextMeeting:
            "calendar"
        case .idle:
            "mic"
        }
    }

    @ViewBuilder private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .widgetAccentable()
                if let timer = timer {
                    timer
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(4)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .widgetAccentable()
                Text(verbatim: "Gistsmith")
                    .font(.headline)
                    .widgetAccentable()
            }
            switch entry.content {
            case .watchRecording(let timerStart, let pausedAt):
                Text(pausedAt == nil ? "Saatte kaydediliyor" : "Duraklatıldı")
                    .font(.footnote)
                WatchGlanceTimer(timerStart: timerStart, stoppedAt: pausedAt)
                    .font(.footnote.monospacedDigit())
            case .phoneRecording(let recording):
                Text(recording.phase == .paused ? "iPhone duraklatıldı" : "iPhone kaydediyor")
                    .font(.footnote)
                if let timerStart = recording.timerStart {
                    WatchGlanceTimer(timerStart: timerStart, stoppedAt: recording.timerStoppedAt)
                        .font(.footnote.monospacedDigit())
                }
            case .nextMeeting(let meeting):
                Text(verbatim: meeting.title)
                    .font(.footnote)
                    .lineLimit(1)
                    .privacySensitive()
                    .redacted(reason: isLuminanceReduced ? .privacy : [])
                Text(meeting.start, format: .dateTime.hour().minute())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .idle:
                Text("Kaydetmek için dokun")
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var inlineText: some View {
        switch entry.content {
        case .watchRecording(let timerStart, let pausedAt):
            WatchGlanceTimer(timerStart: timerStart, stoppedAt: pausedAt)
        case .phoneRecording(let recording):
            if let timerStart = recording.timerStart {
                WatchGlanceTimer(timerStart: timerStart, stoppedAt: recording.timerStoppedAt)
            } else {
                Text("iPhone kaydediyor")
            }
        case .nextMeeting(let meeting):
            Text(meeting.start, format: .dateTime.hour().minute())
        case .idle:
            Text("Kaydet")
        }
    }

    private var timer: WatchGlanceTimer? {
        switch entry.content {
        case .watchRecording(let timerStart, let pausedAt):
            WatchGlanceTimer(timerStart: timerStart, stoppedAt: pausedAt)
        case .phoneRecording(let recording):
            recording.timerStart.map { WatchGlanceTimer(timerStart: $0, stoppedAt: recording.timerStoppedAt) }
        case .nextMeeting, .idle:
            nil
        }
    }
}

/// The timer drawn by the system (no timeline entry per second).
struct WatchGlanceTimer: View {
    let timerStart: Date
    let stoppedAt: Date?

    var body: some View {
        if let stoppedAt {
            Text(Duration.seconds(max(0, stoppedAt.timeIntervalSince(timerStart))), format: .time(pattern: .minuteSecond))
        } else {
            Text(timerStart, style: .timer)
        }
    }
}
