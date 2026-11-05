import Testing
@testable import AINotepadUI

@Suite struct NowPlayingTests {
    // Duraklatılmışken sistem konumu ilerletmesin (hız 0); seçili hız ayrıca bildirilir, konum süreyle sınırlanır.
    @Test func snapshotReflectsPlaybackState() {
        let playing: NowPlayingSnapshot = nowPlayingSnapshot(
            title: "Weekly sync", dateText: "5 November 2026", appName: "Gistsmith", duration: 600, elapsed: 42, rate: 1.5,
            isPlaying: true
        )
        #expect(playing.playbackRate == 1.5)
        #expect(playing.defaultPlaybackRate == 1.5)
        #expect(playing.elapsed == 42)
        #expect(playing.artist == "5 November 2026")
        #expect(playing.album == "Gistsmith")

        let paused: NowPlayingSnapshot = nowPlayingSnapshot(
            title: "Weekly sync", dateText: "5 November 2026", appName: nil, duration: 600, elapsed: 900, rate: 2, isPlaying: false
        )
        #expect(paused.playbackRate == 0)
        #expect(paused.defaultPlaybackRate == 2)
        #expect(paused.elapsed == 600)
        #expect(paused.album == nil)
        #expect(!paused.isPlaying)
    }
}
