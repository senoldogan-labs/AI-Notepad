import Foundation
import os

private let settingsSyncLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SyncedSettings")

/// Key of the account's `SyncedSettingsLocalState` (JSON) in the account's preferences domain.
public let syncedSettingsStateKey: String = "sync.settingsState"

/// Where the synced settings live on this device. Every read and write runs on the main actor, so a check-then-write
/// never interleaves with a settings view writing the same keys.
public struct SyncedSettingsDomains: Sendable, Equatable {
    /// Preferences domain of the values (the `@AppStorage` keys): the app's bundle identifier (its standard domain) or,
    /// in tests, a suite name.
    public let valuesDomain: String
    /// The account's own preferences domain (suite), holding the bookkeeping.
    public let accountSuite: String

    public init(valuesDomain: String, accountSuite: String) {
        self.valuesDomain = valuesDomain
        self.accountSuite = accountSuite
    }

    /// The values' domain: the standard one for the app's own bundle identifier (a suite may not be named after it).
    @MainActor
    func values() throws -> UserDefaults {
        if valuesDomain == Bundle.main.bundleIdentifier {
            return UserDefaults.standard
        }
        guard let defaults = UserDefaults(suiteName: valuesDomain) else {
            throw SyncedSettingsError.domainUnavailable(name: valuesDomain)
        }
        return defaults
    }

    @MainActor
    func account() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: accountSuite) else {
            throw SyncedSettingsError.domainUnavailable(name: accountSuite)
        }
        return defaults
    }
}

/// The listed settings this device stores a value for. Registered defaults do not count: a value the user (or the app)
/// never stored must not compete with another device's.
@MainActor
func storedSyncedSettingValues(domains: SyncedSettingsDomains, keys: [SyncedSettingKey]) throws -> [String: SyncedSettingValue] {
    let stored: [String: Any] = try domains.values().persistentDomain(forName: domains.valuesDomain) ?? [:]
    var values: [String: SyncedSettingValue] = [:]
    for key in keys {
        guard let raw = stored[key.name] else {
            continue
        }
        let value: SyncedSettingValue? = switch key.kind {
        case .string: (raw as? String).map { SyncedSettingValue.string($0) }
        case .bool: (raw as? Bool).map { SyncedSettingValue.bool($0) }
        case .int: (raw as? Int).map { SyncedSettingValue.int($0) }
        }
        guard let value else {
            throw SyncedSettingsError.unexpectedStoredType(key: key.name, expected: key.kind, found: String(describing: type(of: raw)))
        }
        values[key.name] = value
    }
    return values
}

@MainActor
func storedSyncedSettingsState(domains: SyncedSettingsDomains) throws -> SyncedSettingsLocalState {
    guard let data = try domains.account().data(forKey: syncedSettingsStateKey) else {
        return .empty
    }
    do {
        return try JSONDecoder().decode(SyncedSettingsLocalState.self, from: data)
    } catch let error as DecodingError {
        throw SyncedSettingsError.malformedLocalState(reason: String(describing: error))
    }
}

@MainActor
private func storeSyncedSettingsState(state: SyncedSettingsLocalState, domains: SyncedSettingsDomains) throws {
    let encoder: JSONEncoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try domains.account().set(try encoder.encode(state), forKey: syncedSettingsStateKey)
}

/// The settings this device shares with the account's other devices (`SyncPrefs.settings`).
@MainActor
public func currentSyncedSettings(domains: SyncedSettingsDomains) throws -> [String: SyncedSetting]? {
    localSyncedSettings(
        values: try storedSyncedSettingValues(domains: domains, keys: syncedSettingKeys), state: try storedSyncedSettingsState(domains: domains),
        keys: syncedSettingKeys
    )
}

/// Records the user's setting changes: call on every change of the app's preferences (`UserDefaults.didChangeNotification`)
/// while an account is loaded. Returns the settings changed on this device since the last call; they need a prefs upload
/// (the sync engine's `noteLocalChange(item: .prefs)`). Values written by `applySyncedSettings` are not returned (they are
/// in the snapshot already), so an applied value never bounces back. Writes nothing when nothing changed (the call's own
/// write would otherwise notify again).
@MainActor
@discardableResult
public func recordSyncedSettingChanges(domains: SyncedSettingsDomains, now: Date) throws -> [String] {
    let state: SyncedSettingsLocalState = try storedSyncedSettingsState(domains: domains)
    let stamp: SyncedSettingsStamp = stampingSettingChanges(
        state: state, current: try storedSyncedSettingValues(domains: domains, keys: syncedSettingKeys), keys: syncedSettingKeys, now: now
    )
    if stamp.state != state {
        try storeSyncedSettingsState(state: stamp.state, domains: domains)
    }
    if !stamp.changedKeys.isEmpty {
        settingsSyncLogger.info("Synced settings changed here, keys: \(stamp.changedKeys.joined(separator: ","), privacy: .public)")
    }
    return stamp.changedKeys
}

/// Whether storing `merged` would change a setting's value on this device.
@MainActor
func syncedSettingsWouldChange(merged: [String: SyncedSetting]?, domains: SyncedSettingsDomains) throws -> Bool {
    try !syncedSettingsApplication(
        merged: merged, values: try storedSyncedSettingValues(domains: domains, keys: syncedSettingKeys), state: try storedSyncedSettingsState(domains: domains),
        keys: syncedSettingKeys
    ).values.isEmpty
}

/// Stores merged settings from another device: the bookkeeping first (so the change notification of the values finds
/// them in the snapshot and does not stamp them as local changes), then the values on the main actor, so `@AppStorage`
/// views refresh. A nil map (an older app's payload) changes nothing.
@MainActor
func applySyncedSettings(merged: [String: SyncedSetting]?, domains: SyncedSettingsDomains) throws {
    let application: SyncedSettingsApplication = try syncedSettingsApplication(
        merged: merged, values: try storedSyncedSettingValues(domains: domains, keys: syncedSettingKeys), state: try storedSyncedSettingsState(domains: domains),
        keys: syncedSettingKeys
    )
    try storeSyncedSettingsState(state: application.state, domains: domains)
    let values: UserDefaults = try domains.values()
    for (key, value) in application.values.sorted(by: { $0.key < $1.key }) {
        switch value {
        case .string(let text):
            values.set(text, forKey: key)
        case .bool(let flag):
            values.set(flag, forKey: key)
        case .int(let number):
            values.set(number, forKey: key)
        }
    }
    if !application.values.isEmpty {
        settingsSyncLogger.info("Synced settings applied from another device, keys: \(application.values.keys.sorted().joined(separator: ","), privacy: .public)")
    }
}
