import AINotepadCore
import Foundation
import Testing

struct AppUpdateStateTests {
    private let update: AvailableAppUpdate = AvailableAppUpdate(version: "0.3.0", releaseNotes: nil, releaseNotesURL: nil, isReadyToInstall: false)
    private let downloaded: AvailableAppUpdate = AvailableAppUpdate(version: "0.3.0", releaseNotes: nil, releaseNotesURL: nil, isReadyToInstall: true)

    private func run(_ events: [AppUpdateEvent]) -> AppUpdateState {
        events.reduce(AppUpdateState.idle) { (state: AppUpdateState, event: AppUpdateEvent) -> AppUpdateState in
            appUpdateTransition(state: state, event: event)
        }
    }

    @Test func foundUpdateClearsWhenSessionEnds() {
        #expect(run([.found(update)]) == .found(update))
        #expect(run([.found(update), .sessionFinished]) == .idle)
    }

    // İndirilmiş güncelleme çıkışta kurulacak: sonradan gelen "bulundu" ya da oturum sonu onu kaybettirmez.
    @Test func downloadedUpdateSurvivesLaterFoundAndSessionEnd() {
        #expect(run([.downloaded(downloaded), .found(update), .sessionFinished]) == .ready(downloaded))
    }

    // Hemen kurma bir kez: ikinci basış kurma bloğunu yeniden çağırmaz.
    @Test func installStartsOnce() {
        let installing: AppUpdateState = run([.downloaded(downloaded), .installStarted])
        #expect(installing == .installing(downloaded))
        #expect(appUpdateTransition(state: installing, event: .installStarted) == installing)
        #expect(appUpdateTransition(state: installing, event: .found(update)) == installing)
        #expect(appUpdateTransition(state: installing, event: .downloaded(downloaded)) == installing)
        // Kurulum yarıda kaldı: oturum biter, kart kalkar.
        #expect(appUpdateTransition(state: installing, event: .sessionFinished) == .idle)
    }

    @Test func installWithoutDownloadIsIgnored() {
        #expect(run([.found(update), .installStarted]) == .found(update))
    }

    @Test func postponedRelaunchResumesIntoInstalling() {
        let postponed: AppUpdateState = run([.downloaded(downloaded), .installStarted, .relaunchPostponed])
        #expect(postponed == .relaunchPostponed(downloaded))
        #expect(postponed.isRelaunchPostponed)
        #expect(postponed.update == downloaded)
        #expect(appUpdateTransition(state: postponed, event: .found(update)) == postponed)
        #expect(appUpdateTransition(state: postponed, event: .relaunchResumed) == .installing(downloaded))
        // Ertelenmemişken sürdürme bir şey yapmaz.
        #expect(run([.relaunchResumed]) == .idle)
    }
}
