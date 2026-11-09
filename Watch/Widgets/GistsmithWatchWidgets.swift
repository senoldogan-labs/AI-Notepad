import AINotepadWatchLink
import AppIntents
import os
import SwiftUI
import WidgetKit

/// The Watch widget extension: the glance (complication and Smart Stack) and the "Record on Watch" control.
@main
struct GistsmithWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        GistsmithGlanceWidget()
        RecordOnWatchControl()
    }
}

private let widgetLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.watch", category: "Widgets")

/// Reads the glance state the app stored. A new entry follows when the next meeting ends (the glance moves on).
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), content: .idle)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now: Date = Date()
        let first: GlanceEntry = entry(at: now)
        guard case .nextMeeting(let meeting) = first.content else {
            completion(Timeline(entries: [first], policy: .never))
            return
        }
        // When this meeting ends the next one (or "Record") shows.
        completion(Timeline(entries: [first, entry(at: meeting.end)], policy: .never))
    }

    private func entry(at date: Date) -> GlanceEntry {
        do {
            return GlanceEntry(date: date, content: watchGlanceContent(state: try loadWatchGlance(), now: date))
        } catch {
            widgetLogger.error("Glance state could not be read, error: \(String(describing: error), privacy: .public)")
            return GlanceEntry(date: date, content: .idle)
        }
    }
}

/// Reads the family from the widget environment.
struct GlanceFamilyView: View {
    @Environment(\.widgetFamily) private var family: WidgetFamily
    let entry: GlanceEntry

    var body: some View {
        GlanceView(entry: entry, family: family)
    }
}

struct GistsmithGlanceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.senoldogan.AINotepad.watch.glance", provider: GlanceProvider()) { (entry: GlanceEntry) in
            GlanceFamilyView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName(Text(verbatim: "Gistsmith"))
        .description(Text("Kaydı ve sıradaki toplantıyı gösterir; dokununca Gistsmith açılır."))
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

/// "Record on Watch" in Control Center, the Smart Stack and on the Action button (watchOS 26).
struct RecordOnWatchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.senoldogan.AINotepad.watch.record") {
            ControlWidgetButton(action: RecordOnWatchIntent()) {
                Label("Saatte kaydet", systemImage: "mic.fill")
            }
        }
        .displayName("Saatte kaydet")
        .description("Gistsmith'i açar ve toplantıyı saatte kaydetmeye başlar.")
    }
}
