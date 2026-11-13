import Foundation

/// The lowest iPhone system the Apple Watch app works with: the Watch app needs watchOS 26 (project.yml
/// `deploymentTarget.watchOS`), and a watch on watchOS 26 pairs only with an iPhone on iOS 26 or later.
public let watchAppMinimumPhoneSystemMajorVersion: Int = 26

/// What the iPhone knows about its Apple Watch, read from `WCSession` (the adapter in `iOS/PhoneWatchLink.swift`).
public struct WatchSessionFacts: Sendable, Equatable {
    /// `WCSession.isSupported()`: false on devices without WatchConnectivity.
    public let isSupported: Bool
    /// The session finished activating; before that `isPaired` and `isWatchAppInstalled` are always false.
    public let isActivated: Bool
    public let isPaired: Bool
    public let isWatchAppInstalled: Bool
    /// The iPhone's iOS major version (e.g. 26).
    public let systemMajorVersion: Int

    public init(isSupported: Bool, isActivated: Bool, isPaired: Bool, isWatchAppInstalled: Bool, systemMajorVersion: Int) {
        self.isSupported = isSupported
        self.isActivated = isActivated
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
        self.systemMajorVersion = systemMajorVersion
    }
}

/// The Settings › Apple Watch page's state.
public enum WatchSetupState: Sendable, Equatable {
    /// This device has no WatchConnectivity (e.g. an iPad-class device).
    case unsupported
    /// The iPhone's iOS is older than the Watch app needs (`requiredMajorVersion`).
    case needsNewerSystem(requiredMajorVersion: Int)
    /// The session is still activating: pairing is not known yet.
    case checking
    /// No Apple Watch is paired with this iPhone.
    case noWatchPaired
    /// A watch is paired but Gistsmith is not installed on it.
    case appNotInstalled
    /// Gistsmith is on the paired watch.
    case ready
}

/// The page's state from the session facts: support first, then the iPhone's system (a watch that runs the Watch app
/// pairs only with iOS 26+), then activation, pairing and installation. Pure function.
public func watchSetupState(facts: WatchSessionFacts, requiredMajorVersion: Int) -> WatchSetupState {
    guard facts.isSupported else {
        return .unsupported
    }
    guard facts.systemMajorVersion >= requiredMajorVersion else {
        return .needsNewerSystem(requiredMajorVersion: requiredMajorVersion)
    }
    guard facts.isActivated else {
        return .checking
    }
    guard facts.isPaired else {
        return .noWatchPaired
    }
    guard facts.isWatchAppInstalled else {
        return .appNotInstalled
    }
    return .ready
}
