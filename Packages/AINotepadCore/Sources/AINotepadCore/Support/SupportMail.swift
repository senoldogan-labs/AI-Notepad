import Foundation

/// The support address on the site (`web/src/legal/operator.ts`, the contact page).
public let supportEmailAddress: String = "contact@senoldogan.dev"

/// The device facts a support email carries: nothing about meetings or the account.
public struct SupportMailFacts: Sendable, Equatable {
    /// e.g. "0.2.6 (53)".
    public let appVersion: String
    /// e.g. "iOS 26.1".
    public let systemVersion: String
    /// The hardware model identifier, e.g. "iPhone17,1".
    public let deviceModel: String

    public init(appVersion: String, systemVersion: String, deviceModel: String) {
        self.appVersion = appVersion
        self.systemVersion = systemVersion
        self.deviceModel = deviceModel
    }
}

/// A `mailto:` link to `address` with `subject` and a body of an empty line for the user's message, then app version,
/// system version and device model. Never meeting content, names or account details. Pure function.
public func supportMailURL(address: String, subject: String, facts: SupportMailFacts) -> URL? {
    let body: String = "\n\n—\nGistsmith \(facts.appVersion)\n\(facts.systemVersion)\n\(facts.deviceModel)"
    var components: URLComponents = URLComponents()
    components.scheme = "mailto"
    components.path = address
    components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
    return components.url
}
