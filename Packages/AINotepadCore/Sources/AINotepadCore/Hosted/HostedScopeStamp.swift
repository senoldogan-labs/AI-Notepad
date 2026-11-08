import Foundation

/// Which run of an account feature (sync, assistant access) a piece of asynchronous work belongs to: the app center's
/// generation (bumped whenever it starts, stops or restarts the feature) and the account it was bound to. Work that
/// resumes after an `await` writes the center's state only while its stamp is still current.
public struct HostedScopeStamp: Sendable, Equatable {
    public let generation: Int
    public let accountKey: String
    public let userID: String

    public init(generation: Int, accountKey: String, userID: String) {
        self.generation = generation
        self.accountKey = accountKey
        self.userID = userID
    }
}

/// Whether work stamped `stamp` still belongs to the center's current run: same generation and the same account bound
/// (none bound means signed out, which is never current). Pure function.
public func hostedStampIsCurrent(stamp: HostedScopeStamp, generation: Int, accountKey: String?, userID: String?) -> Bool {
    guard let accountKey, let userID else {
        return false
    }
    return stamp == HostedScopeStamp(generation: generation, accountKey: accountKey, userID: userID)
}
