import AINotepadWatchLink
import AppIntents
import Foundation
import os
import SwiftUI
#if !WIDGET_EXTENSION
import WidgetKit
#endif

// Shared by the Watch app and its widget extension: the glance state in the App Group and the "Record on Watch" intent.

/// The App Group the Watch app shares with its widgets (only what the glances draw: no task text).
let watchAppGroup: String = "group.com.senoldogan.AINotepad.hosted.watch"

/// Gistsmith's orange accent (the same as the iPhone's widgets).
let watchAccent: Color = Color(red: 0.91, green: 0.36, blue: 0.11)

private let glanceKey: String = "glance"
private let sharedLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad.watch", category: "Glance")

/// Errors of the shared glance store.
enum WatchGlanceStoreError: Error {
    /// The App Group container is not available (entitlement missing in this build).
    case appGroupUnavailable
}

/// The App Group's defaults.
func watchGroupDefaults() throws -> UserDefaults {
    guard let defaults = UserDefaults(suiteName: watchAppGroup) else {
        throw WatchGlanceStoreError.appGroupUnavailable
    }
    return defaults
}

/// The stored glance state; `.empty` when none was written yet.
func loadWatchGlance() throws -> WatchGlanceState {
    guard let data = try watchGroupDefaults().data(forKey: glanceKey) else {
        return .empty
    }
    return try watchValue(type: WatchGlanceState.self, data: data)
}

#if !WIDGET_EXTENSION
/// Stores the glance state and reloads the glances when it changed (the reload budget is spent only on real changes).
func saveWatchGlance(state: WatchGlanceState) {
    do {
        let defaults: UserDefaults = try watchGroupDefaults()
        let data: Data? = try watchPayload(value: state)[watchPayloadKey]
        guard defaults.data(forKey: glanceKey) != data else {
            return
        }
        defaults.set(data, forKey: glanceKey)
        WidgetCenter.shared.reloadAllTimelines()
    } catch {
        sharedLogger.error("Glance state could not be saved, error: \(String(describing: error), privacy: .public)")
    }
}
#endif

/// "Record on Watch" (Control Center, Smart Stack, Action button): opens the app and starts recording on the Watch.
/// A recording session can start only in the foreground, so the intent always opens the app.
struct RecordOnWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Saatte kaydet"
    static let description: IntentDescription = IntentDescription("Gistsmith'i açar ve toplantıyı saatin mikrofonuyla kaydetmeye başlar.")
    static let supportedModes: IntentModes = .foreground

    /// Whichever process runs it (the app or the widget extension: not documented for watchOS controls), it leaves a
    /// start request in the App Group; the app starts the recording once its scene is active, the only time the
    /// microphone can start.
    @MainActor
    func perform() async throws -> some IntentResult {
        try watchGroupDefaults().set(Date(), forKey: watchPendingStartKey)
        #if !WIDGET_EXTENSION
        WatchAppModel.shared.startPendingRecordingIfActive()
        #endif
        return .result()
    }
}

/// App Group key of a "Record on Watch" request not started yet (the time it was made).
let watchPendingStartKey: String = "pendingRecordStart"

