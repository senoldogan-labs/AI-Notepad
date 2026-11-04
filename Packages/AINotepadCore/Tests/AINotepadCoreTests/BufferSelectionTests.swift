// Sistem sesi yakalamanın tampon seçimi (yalnızca macOS'ta var).
#if os(macOS)
import CoreAudio
import Foundation
import Testing
@testable import AINotepadCore

/// Verilen bayt boyutlarıyla (boş veri) bir tampon listesi oluşturur.
func makeBufferList(byteSizes: [UInt32]) -> UnsafeMutableAudioBufferListPointer {
    let list: UnsafeMutableAudioBufferListPointer = AudioBufferList.allocate(maximumBuffers: byteSizes.count)
    for (index, size) in byteSizes.enumerated() {
        list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: size, mData: nil)
    }
    return list
}

@Suite struct BufferSelectionTests {
    // Alt cihazın (ör. AirPods mikrofonu) akışları önce, tap akışı en sonda gelir.
    @Test func picksTrailingTapBuffer() {
        let source: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [10, 20, 30])
        let destination: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [0])
        #expect(copyTrailingBuffers(source: source, destination: destination))
        #expect(destination[0].mDataByteSize == 30)
        free(source.unsafeMutablePointer)
        free(destination.unsafeMutablePointer)
    }

    @Test func picksTrailingNonInterleavedChannels() {
        let source: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [10, 20, 30])
        let destination: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [0, 0])
        #expect(copyTrailingBuffers(source: source, destination: destination))
        #expect(destination.map(\.mDataByteSize) == [20, 30])
        free(source.unsafeMutablePointer)
        free(destination.unsafeMutablePointer)
    }

    // Çıkış değişirken (AirPods, HDMI) gelen uyuşmaz tampon akışı bitirmez: toplu cihaz yeniden kurulur. Ses gelen her
    // kurmadan sonra sayaç baştan başlar; art arda sessiz kurmalar sınırı aşınca vazgeçilir (sonsuz döngü yok).
    @Test func mismatchRebuildsUntilAudioFlowsAgain() {
        #expect(tapRecoveryDecision(previousRebuilds: 0, deliveredSinceLastRebuild: true, maxRebuilds: 3) == .rebuild(attempt: 1))
        #expect(tapRecoveryDecision(previousRebuilds: 2, deliveredSinceLastRebuild: true, maxRebuilds: 3) == .rebuild(attempt: 1))
        #expect(tapRecoveryDecision(previousRebuilds: 0, deliveredSinceLastRebuild: false, maxRebuilds: 3) == .rebuild(attempt: 1))
        #expect(tapRecoveryDecision(previousRebuilds: 2, deliveredSinceLastRebuild: false, maxRebuilds: 3) == .rebuild(attempt: 3))
        #expect(tapRecoveryDecision(previousRebuilds: 3, deliveredSinceLastRebuild: false, maxRebuilds: 3) == .giveUp)
    }

    // IO bloğunun durumu: yeniden kurma isteği her toplu cihaz için bir kez; ses gelişi işaretlenir.
    @Test func mismatchIsReportedOncePerDevice() {
        let state: TapIOState = TapIOState()
        #expect(!state.hasDelivered)
        #expect(state.markMismatch())
        #expect(!state.markMismatch())
        state.markDelivered()
        #expect(state.hasDelivered)
    }

    @Test func failsWhenSourceHasTooFewBuffers() {
        let source: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [10])
        let destination: UnsafeMutableAudioBufferListPointer = makeBufferList(byteSizes: [0, 0])
        #expect(!copyTrailingBuffers(source: source, destination: destination))
        free(source.unsafeMutablePointer)
        free(destination.unsafeMutablePointer)
    }
}
#endif
