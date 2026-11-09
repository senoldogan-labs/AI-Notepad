import AppIntents
import SwiftUI
import WatchKit

/// Gistsmith on Apple Watch: records meetings with the Watch's microphone and sends them to the iPhone, controls the
/// iPhone's recording, and shows today's meetings and the user's open tasks. Everything of the account comes from the
/// iPhone app (WatchConnectivity); the Watch holds no secret and never talks to the server.
@main
struct GistsmithWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    private let model: WatchAppModel = WatchAppModel.shared

    init() {
        WatchAppModel.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(model: model)
                .onChange(of: scenePhase, initial: true) { (_: ScenePhase, phase: ScenePhase) in
                    if phase == .active {
                        model.appBecameActive()
                    } else {
                        model.appLeftForeground()
                    }
                }
        }
        // The iPhone's snapshot or a finished transfer woke the app in the background: keep it running until
        // WatchConnectivity has delivered everything (the delegate updates the state and the glances).
        .backgroundTask(.watchConnectivity) {
            await waitForWatchConnectivity()
        }
    }
}

/// Waits (at most a few seconds) until WatchConnectivity has no content left to deliver.
@MainActor
private func waitForWatchConnectivity() async {
    for _ in 0..<20 where WatchAppModel.shared.hasContentPending {
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
    }
}
