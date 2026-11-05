import Foundation

// User settings that follow the account to every device (`SyncPrefs.settings`), last writer wins per setting. Values
// live in the app's own preferences domain (the `@AppStorage` keys); each device keeps, in the account's preferences
// domain, when it last changed each one (`SyncedSettingsLocalState`). Device-specific settings (audio retention,
// shortcuts, in-person mode, microphone, model and provider, appearance, reminders, voice recognition, window and list
// visibility) are not in the list and never sync.

/// How a synced setting is stored in `UserDefaults`.
public enum SyncedSettingKind: Sendable, Equatable {
    case string
    case bool
    case int
}

/// One synced setting: its `UserDefaults` key (the same raw name on Mac `SettingsKey` and iPhone `PhoneSettingsKey`) and
/// how it is stored.
public struct SyncedSettingKey: Sendable, Equatable {
    public let name: String
    public let kind: SyncedSettingKind

    public init(name: String, kind: SyncedSettingKind) {
        self.name = name
        self.kind = kind
    }
}

/// The settings this app version syncs. A key a device does not list (added by a newer app) is kept as it came and
/// passed on unchanged (`SyncedSettingsLocalState.passthrough`); a listed key that no app version registers yet is
/// harmless (it only syncs once some device stores a value for it).
public let syncedSettingKeys: [SyncedSettingKey] = [
    SyncedSettingKey(name: "language.note", kind: .string),
    SyncedSettingKey(name: "language.mode", kind: .string),
    SyncedSettingKey(name: "language.primary", kind: .string),
    SyncedSettingKey(name: "displayMode", kind: .string),
    SyncedSettingKey(name: "noteTemplate", kind: .string),
    SyncedSettingKey(name: "customTemplate", kind: .string),
    SyncedSettingKey(name: "noteTemplate.fromTitle", kind: .bool),
    SyncedSettingKey(name: "meeting.noteDisplayLanguage", kind: .string),
    SyncedSettingKey(name: askWebSearchSettingKey, kind: .bool),
    SyncedSettingKey(name: "missedWindowMinutes", kind: .int),
    SyncedSettingKey(name: "notify.noteReady", kind: .bool),
    SyncedSettingKey(name: "notify.taskDue", kind: .bool),
    SyncedSettingKey(name: "notify.weeklySummary", kind: .bool),
    SyncedSettingKey(name: "notify.inactive", kind: .bool),
]

/// A synced setting's value. Encoded as the bare JSON value (`"fi"`, `true`, `3`). The set of kinds is fixed for
/// `syncPayloadSchema` 1: an older app cannot decode a new kind, so a new setting must use one of these.
public enum SyncedSettingValue: Sendable, Equatable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)

    public init(from decoder: any Decoder) throws {
        let container: any SingleValueDecodingContainer = try decoder.singleValueContainer()
        // `JSONDecoder` is strict: `true` is no `Int` and `1` no `Bool`, so the order only matters for readability.
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container: any SingleValueEncodingContainer = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }

    /// The kind of this value.
    public var kind: SyncedSettingKind {
        switch self {
        case .string: .string
        case .bool: .bool
        case .int: .int
        }
    }
}

/// A synced setting as it travels: the value and when a device last changed it. `changedAt` nil: no device changed it
/// since it started recording changes (a value set before; it loses to any changed one).
public struct SyncedSetting: Sendable, Equatable, Codable {
    public let value: SyncedSettingValue
    public let changedAt: Date?

    public init(value: SyncedSettingValue, changedAt: Date?) {
        self.value = value
        self.changedAt = changedAt
    }
}

/// A synced setting could not be read or applied.
public enum SyncedSettingsError: Error, Sendable, Equatable {
    /// A preferences domain could not be opened.
    case domainUnavailable(name: String)
    /// A stored value is not of the setting's kind (`found` is the stored type's name, not the value).
    case unexpectedStoredType(key: String, expected: SyncedSettingKind, found: String)
    /// Another device sent a value of a different kind for a setting this app knows.
    case unexpectedSyncedKind(key: String, expected: SyncedSettingKind, found: SyncedSettingKind)
    /// The account's synced-settings bookkeeping (JSON) could not be read; `reason` is the decoder's message.
    case malformedLocalState(reason: String)
}

/// What a device keeps per account (in the account's preferences domain) to sync the settings.
public struct SyncedSettingsLocalState: Sendable, Equatable, Codable {
    /// Setting → when this device's value last changed (locally, or adopted from another device with that device's time).
    public let clocks: [String: Date]
    /// The values last seen, to tell a local change (`stampingSettingChanges`) from one already recorded.
    public let snapshot: [String: SyncedSettingValue]
    /// The settings `snapshot` covers (a value absent from `snapshot` but listed here was unset).
    public let trackedKeys: [String]
    /// Settings from a newer app version that this one does not know: kept and synced on unchanged.
    public let passthrough: [String: SyncedSetting]

    public init(clocks: [String: Date], snapshot: [String: SyncedSettingValue], trackedKeys: [String], passthrough: [String: SyncedSetting]) {
        self.clocks = clocks
        self.snapshot = snapshot
        self.trackedKeys = trackedKeys
        self.passthrough = passthrough
    }

    /// A device that never recorded anything for the account.
    public static let empty: SyncedSettingsLocalState = SyncedSettingsLocalState(clocks: [:], snapshot: [:], trackedKeys: [], passthrough: [:])
}

/// Whether `candidate` beats `incumbent`: a later change time wins; a setting nobody changed (nil) loses to any change.
/// Pure function.
private func isNewer(candidate: Date?, incumbent: Date?) -> Bool {
    switch (candidate, incumbent) {
    case (.some(let candidate), .some(let incumbent)):
        candidate > incumbent
    case (.some, .none):
        true
    case (.none, _):
        false
    }
}

/// Merges two versions of the synced settings, per setting: a setting only one side has is kept (a missing map, as an
/// older app writes it, or a missing key means "no information", never "deleted"); when both have it the later change
/// wins, and on equal times (or neither changed) `remote` wins, so devices converge on the server's copy. Unknown keys
/// are merged the same way and kept. Empty result: nil. Pure function.
public func mergeSyncedSettings(local: [String: SyncedSetting]?, remote: [String: SyncedSetting]?) -> [String: SyncedSetting]? {
    var merged: [String: SyncedSetting] = remote ?? [:]
    for (key, mine) in local ?? [:] {
        guard let theirs = merged[key] else {
            merged[key] = mine
            continue
        }
        if isNewer(candidate: mine.changedAt, incumbent: theirs.changedAt) {
            merged[key] = mine
        }
    }
    return merged.isEmpty ? nil : merged
}

/// Result of comparing the current values with the last snapshot.
public struct SyncedSettingsStamp: Sendable, Equatable {
    /// The bookkeeping to store (unchanged when `changedKeys` is empty and nothing new was tracked).
    public let state: SyncedSettingsLocalState
    /// Settings the user changed on this device since the snapshot (stamped with `now`): they need an upload.
    public let changedKeys: [String]
}

/// Stamps the settings whose value differs from the snapshot with `now` (whole seconds, as every sync clock). A setting
/// not tracked yet (first run for the account, or a key a newer app version added to the list) is adopted without a
/// stamp: its value predates this bookkeeping, so it must not beat another device's. A value that disappears is not a
/// change (absence never syncs). Pure function.
public func stampingSettingChanges(state: SyncedSettingsLocalState, current: [String: SyncedSettingValue], keys: [SyncedSettingKey], now: Date) -> SyncedSettingsStamp {
    let tracked: Set<String> = Set(state.trackedKeys)
    var clocks: [String: Date] = state.clocks
    var changed: [String] = []
    for key in keys.map(\.name) where tracked.contains(key) {
        if let value = current[key], value != state.snapshot[key] {
            clocks[key] = syncWholeSecond(date: now)
            changed.append(key)
        }
    }
    let updated: SyncedSettingsLocalState = SyncedSettingsLocalState(
        clocks: clocks, snapshot: current, trackedKeys: Array(tracked.union(keys.map(\.name))).sorted(), passthrough: state.passthrough
    )
    return SyncedSettingsStamp(state: updated, changedKeys: changed)
}

/// The settings this device shares: the listed keys it has a value for (with its clock) plus the passthrough keys of
/// newer app versions. Nothing to share: nil (an older payload without the field compares equal). Pure function.
public func localSyncedSettings(values: [String: SyncedSettingValue], state: SyncedSettingsLocalState, keys: [SyncedSettingKey]) -> [String: SyncedSetting]? {
    let known: Set<String> = Set(keys.map(\.name))
    var settings: [String: SyncedSetting] = state.passthrough.filter { !known.contains($0.key) }
    for key in keys {
        if let value = values[key.name] {
            settings[key.name] = SyncedSetting(value: value, changedAt: state.clocks[key.name])
        }
    }
    return settings.isEmpty ? nil : settings
}

/// How to store merged settings on this device.
public struct SyncedSettingsApplication: Sendable, Equatable {
    /// Listed settings whose stored value changes (written into the app's preferences domain).
    public let values: [String: SyncedSettingValue]
    /// The bookkeeping after the write: the merged clocks, the new values in the snapshot (so the write is not taken for
    /// a local change) and the unknown keys as passthrough.
    public let state: SyncedSettingsLocalState
}

/// Plans the write of merged settings over the current values. A setting missing from `merged` (or a nil map, as an
/// older app writes it) is left alone. Throws when another device sent a value of another kind for a listed setting.
/// Pure function.
public func syncedSettingsApplication(
    merged: [String: SyncedSetting]?, values: [String: SyncedSettingValue], state: SyncedSettingsLocalState, keys: [SyncedSettingKey]
) throws -> SyncedSettingsApplication {
    guard let merged else {
        return SyncedSettingsApplication(values: [:], state: state)
    }
    var changes: [String: SyncedSettingValue] = [:]
    var clocks: [String: Date] = state.clocks
    var snapshot: [String: SyncedSettingValue] = state.snapshot
    for key in keys {
        guard let setting = merged[key.name] else {
            continue
        }
        guard setting.value.kind == key.kind else {
            throw SyncedSettingsError.unexpectedSyncedKind(key: key.name, expected: key.kind, found: setting.value.kind)
        }
        if values[key.name] != setting.value {
            changes[key.name] = setting.value
        }
        snapshot[key.name] = setting.value
        clocks[key.name] = setting.changedAt
    }
    let known: Set<String> = Set(keys.map(\.name))
    let passthrough: [String: SyncedSetting] = merged.filter { !known.contains($0.key) }
    return SyncedSettingsApplication(
        values: changes, state: SyncedSettingsLocalState(clocks: clocks, snapshot: snapshot, trackedKeys: state.trackedKeys, passthrough: passthrough)
    )
}
