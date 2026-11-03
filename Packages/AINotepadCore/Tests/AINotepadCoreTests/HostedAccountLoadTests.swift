import Testing
@testable import AINotepadCore

/// İlk hesap okumasının süresi dolunca hesabın "durumu okunamadı" olup olmayacağı.
struct HostedAccountLoadTests {
    @Test func overdueFirstReadWithSessionShowsStatusUnknown() {
        #expect(isHostedAccountLoadOverdue(isAwaitingFirstRead: true, hasSession: true, started: 3, current: 3))
    }

    @Test func readThatAlreadyWroteAStateIsNotOverdue() {
        #expect(!isHostedAccountLoadOverdue(isAwaitingFirstRead: false, hasSession: true, started: 3, current: 3))
    }

    @Test func supersededReadLeavesTheDeadlineToTheNewerRead() {
        #expect(!isHostedAccountLoadOverdue(isAwaitingFirstRead: true, hasSession: true, started: 3, current: 4))
    }

    @Test func withoutAStoredSessionTheSignInGateShowsInstead() {
        #expect(!isHostedAccountLoadOverdue(isAwaitingFirstRead: true, hasSession: false, started: 3, current: 3))
        #expect(!isHostedAccountLoadOverdue(isAwaitingFirstRead: true, hasSession: nil, started: 3, current: 3))
    }
}
