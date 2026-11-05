import Foundation
import Testing
@testable import AINotepadCore

private let t0: Date = Date(timeIntervalSinceReferenceDate: 815_100_000)
private let t1: Date = t0.addingTimeInterval(60)
private let t2: Date = t0.addingTimeInterval(120)

private func setting(_ value: SyncedSettingValue, _ changedAt: Date?) -> SyncedSetting {
    SyncedSetting(value: value, changedAt: changedAt)
}

/// `SyncPrefs` as the first sync release encoded it (an older app: no `settings` field).
private struct OlderSyncPrefs: Codable, Equatable {
    let schema: Int
    let folders: [String]
    let recipes: [Recipe]
}

/// Two throwaway preferences domains (the app's values and the account's bookkeeping), removed afterwards.
private struct TestDomains {
    let domains: SyncedSettingsDomains = SyncedSettingsDomains(
        valuesDomain: "ainotepad.test.values.\(UUID().uuidString)", accountSuite: "ainotepad.test.account.\(UUID().uuidString)"
    )

    func values() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: domains.valuesDomain))
    }

    func remove() {
        UserDefaults().removePersistentDomain(forName: domains.valuesDomain)
        UserDefaults().removePersistentDomain(forName: domains.accountSuite)
    }
}

@Suite struct SyncedSettingsTests {
    // Per key the later change wins; a value nobody changed loses to a changed one; equal times keep the server's.
    @Test func mergeIsLastWriterWinsPerKey() {
        let local: [String: SyncedSetting] = [
            "language.note": setting(.string("fi"), t2),
            "displayMode": setting(.string("bilingual"), t0),
            "missedWindowMinutes": setting(.int(5), nil),
            "noteTemplate": setting(.string("sales"), t1),
            "askWebSearch": setting(.bool(true), t1),
        ]
        let remote: [String: SyncedSetting] = [
            "language.note": setting(.string("en"), t1),
            "displayMode": setting(.string("originalOnly"), t1),
            "missedWindowMinutes": setting(.int(10), nil),
            "noteTemplate": setting(.string("general"), t1),
            "customTemplate": setting(.string("Bullets"), nil),
        ]
        let merged: [String: SyncedSetting]? = mergeSyncedSettings(local: local, remote: remote)
        #expect(merged == [
            "language.note": setting(.string("fi"), t2),
            "displayMode": setting(.string("originalOnly"), t1),
            "missedWindowMinutes": setting(.int(10), nil),
            "noteTemplate": setting(.string("general"), t1),
            "askWebSearch": setting(.bool(true), t1),
            "customTemplate": setting(.string("Bullets"), nil),
        ])
    }

    // A missing map (an older app re-wrote the prefs) or a missing key is "no information": nothing is deleted.
    // Settings of a newer app version (unknown keys) are merged and kept like any other.
    @Test func missingSettingsAreNotDeletions() {
        let local: [String: SyncedSetting] = ["language.note": setting(.string("fi"), t1), "future.key": setting(.string("x"), t0)]
        #expect(mergeSyncedSettings(local: local, remote: nil) == local)
        #expect(mergeSyncedSettings(local: nil, remote: local) == local)
        #expect(mergeSyncedSettings(local: nil, remote: nil) == nil)
        #expect(mergeSyncedSettings(local: [:], remote: [:]) == nil)
        let prefs: SyncPrefs = mergeSyncPrefs(
            base: SyncPrefs(schema: 1, folders: ["A"], recipes: [], settings: local),
            local: SyncPrefs(schema: 1, folders: ["A"], recipes: [], settings: local),
            remote: SyncPrefs(schema: 1, folders: ["A", "B"], recipes: [], settings: nil)
        )
        #expect(prefs.folders == ["A", "B"] && prefs.settings == local)
    }

    // First run for the account: present values are adopted without a stamp (they must not beat another device's);
    // later changes are stamped in whole seconds; an unset value is no change; a newly listed key is adopted.
    @Test func stampingRecordsOnlyLocalChanges() {
        let keys: [SyncedSettingKey] = [SyncedSettingKey(name: "language.note", kind: .string), SyncedSettingKey(name: "missedWindowMinutes", kind: .int)]
        let first: SyncedSettingsStamp = stampingSettingChanges(state: .empty, current: ["language.note": .string("fi")], keys: keys, now: t0)
        #expect(first.changedKeys.isEmpty && first.state.clocks.isEmpty && first.state.trackedKeys == ["language.note", "missedWindowMinutes"])
        let changed: SyncedSettingsStamp = stampingSettingChanges(
            state: first.state, current: ["language.note": .string("en"), "missedWindowMinutes": .int(5)], keys: keys, now: t1.addingTimeInterval(0.7)
        )
        #expect(changed.changedKeys == ["language.note", "missedWindowMinutes"])
        #expect(changed.state.clocks == ["language.note": t1, "missedWindowMinutes": t1])
        let unchanged: SyncedSettingsStamp = stampingSettingChanges(state: changed.state, current: ["language.note": .string("en")], keys: keys, now: t2)
        #expect(unchanged.changedKeys.isEmpty && unchanged.state.clocks == changed.state.clocks)
        let grown: [SyncedSettingKey] = keys + [SyncedSettingKey(name: "displayMode", kind: .string)]
        let adopted: SyncedSettingsStamp = stampingSettingChanges(
            state: unchanged.state, current: ["language.note": .string("en"), "displayMode": .string("bilingual")], keys: grown, now: t2
        )
        #expect(adopted.changedKeys.isEmpty && adopted.state.trackedKeys.contains("displayMode") && adopted.state.clocks["displayMode"] == nil)
    }

    // Applying merged settings: changed values are written, clocks follow the merge, the snapshot holds the new values (so
    // they are not taken for local changes), unknown keys go to passthrough and come back out in the shared settings.
    @Test func applicationPlansValuesClocksAndPassthrough() throws {
        let keys: [SyncedSettingKey] = [SyncedSettingKey(name: "language.note", kind: .string), SyncedSettingKey(name: "askWebSearch", kind: .bool)]
        let state: SyncedSettingsLocalState = SyncedSettingsLocalState(
            clocks: ["askWebSearch": t0], snapshot: ["language.note": .string("fi"), "askWebSearch": .bool(true)], trackedKeys: ["askWebSearch", "language.note"],
            passthrough: [:]
        )
        let values: [String: SyncedSettingValue] = ["language.note": .string("fi"), "askWebSearch": .bool(true)]
        let merged: [String: SyncedSetting] = [
            "language.note": setting(.string("en"), t1), "askWebSearch": setting(.bool(true), t0), "future.key": setting(.int(2), t2),
        ]
        let application: SyncedSettingsApplication = try syncedSettingsApplication(merged: merged, values: values, state: state, keys: keys)
        #expect(application.values == ["language.note": .string("en")])
        #expect(application.state.clocks == ["language.note": t1, "askWebSearch": t0])
        #expect(application.state.snapshot == ["language.note": .string("en"), "askWebSearch": .bool(true)])
        #expect(application.state.passthrough == ["future.key": setting(.int(2), t2)])
        let after: [String: SyncedSettingValue] = values.merging(application.values) { (_: SyncedSettingValue, new: SyncedSettingValue) -> SyncedSettingValue in new }
        #expect(localSyncedSettings(values: after, state: application.state, keys: keys) == merged)
        #expect(stampingSettingChanges(state: application.state, current: after, keys: keys, now: t2).changedKeys.isEmpty)
        // An older app's payload (no map) changes nothing.
        #expect(try syncedSettingsApplication(merged: nil, values: values, state: state, keys: keys) == SyncedSettingsApplication(values: [:], state: state))
        #expect(throws: SyncedSettingsError.unexpectedSyncedKind(key: "language.note", expected: .string, found: .bool)) {
            try syncedSettingsApplication(merged: ["language.note": setting(.bool(true), t1)], values: values, state: state, keys: keys)
        }
        #expect(localSyncedSettings(values: [:], state: .empty, keys: keys) == nil)
    }

    // The field was added without a schema bump: an older payload decodes (settings nil) and keeps its exact bytes, an
    // older app decodes a newer payload (ignoring the field), and values travel as bare JSON values.
    @Test func prefsStayCompatibleWithOlderApps() throws {
        let older: OlderSyncPrefs = OlderSyncPrefs(schema: 1, folders: ["Board"], recipes: [])
        let decoded: SyncPrefs = try decodeSyncPayload(type: SyncPrefs.self, data: try encodeSyncPayload(value: older))
        #expect(decoded == SyncPrefs(schema: 1, folders: ["Board"], recipes: [], settings: nil))
        #expect(try canonicalSyncJSON(value: decoded) == canonicalSyncJSON(value: older))
        let newer: SyncPrefs = SyncPrefs(
            schema: syncPayloadSchema, folders: ["Board"], recipes: [],
            settings: ["language.note": setting(.string("fi"), Date(timeIntervalSinceReferenceDate: 10)), "askWebSearch": setting(.bool(false), nil), "missedWindowMinutes": setting(.int(5), nil)]
        )
        #expect(String(decoding: try canonicalSyncJSON(value: newer), as: UTF8.self)
            == #"{"folders":["Board"],"recipes":[],"schema":1,"settings":{"askWebSearch":{"value":false},"language.note":{"changedAt":10,"value":"fi"},"missedWindowMinutes":{"value":5}}}"#)
        #expect(try decodeSyncPayload(type: OlderSyncPrefs.self, data: try encodeSyncPayload(value: newer)) == older)
        #expect(try decodeSyncPayload(type: SyncPrefs.self, data: try encodeSyncPayload(value: newer)) == newer)
    }

    // Through real preferences domains: registered defaults do not count, a user change is stamped once, a value applied
    // from another device is not stamped (no ping-pong), and a stored value of another type is an error.
    @MainActor
    @Test func defaultsAdapterRecordsAndAppliesWithoutPingPong() throws {
        let test: TestDomains = TestDomains()
        defer { test.remove() }
        let values: UserDefaults = try test.values()
        values.register(defaults: ["displayMode": "bilingual", "missedWindowMinutes": 3])
        values.set("fi", forKey: "language.note")
        values.set("dark", forKey: "theme")
        #expect(try recordSyncedSettingChanges(domains: test.domains, now: t0).isEmpty)
        #expect(try currentSyncedSettings(domains: test.domains) == ["language.note": setting(.string("fi"), nil)])

        values.set("en", forKey: "language.note")
        values.set(false, forKey: "askWebSearch")
        #expect(try recordSyncedSettingChanges(domains: test.domains, now: t1) == ["language.note", "askWebSearch"])
        #expect(try recordSyncedSettingChanges(domains: test.domains, now: t2).isEmpty)
        #expect(try currentSyncedSettings(domains: test.domains) == ["language.note": setting(.string("en"), t1), "askWebSearch": setting(.bool(false), t1)])

        let remote: [String: SyncedSetting] = [
            "language.note": setting(.string("de"), t2), "askWebSearch": setting(.bool(false), t1), "missedWindowMinutes": setting(.int(7), t2),
            "future.key": setting(.string("kept"), t2),
        ]
        #expect(try syncedSettingsWouldChange(merged: remote, domains: test.domains))
        try applySyncedSettings(merged: remote, domains: test.domains)
        #expect(values.string(forKey: "language.note") == "de" && values.integer(forKey: "missedWindowMinutes") == 7)
        #expect(values.object(forKey: "future.key") == nil)
        #expect(try recordSyncedSettingChanges(domains: test.domains, now: t2.addingTimeInterval(60)).isEmpty)
        #expect(try currentSyncedSettings(domains: test.domains) == remote)
        #expect(try !syncedSettingsWouldChange(merged: remote, domains: test.domains))

        values.set("seven", forKey: "missedWindowMinutes")
        #expect(throws: SyncedSettingsError.self) { try recordSyncedSettingChanges(domains: test.domains, now: t2) }
    }

    // The store writes folders and settings together, but never changes a setting while a recording runs (the engine
    // retries the download later); a write that leaves the settings alone goes through.
    @Test func storeDefersSettingChangesDuringRecording() async throws {
        let test: TestDomains = TestDomains()
        defer { test.remove() }
        let recording: RecordingFlag = RecordingFlag()
        let store: SyncAccountFolderStore = SyncAccountFolderStore(
            accountDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), defaultsSuite: test.domains.accountSuite,
            valuesDomain: test.domains.valuesDomain, busy: { () async -> Set<String> in [] },
            recordingInProgress: { () -> Bool in recording.isOn }, now: { () -> Date in t0 }
        )
        let empty: SyncPrefs = try await store.prefs()
        #expect(empty == SyncPrefs(schema: syncPayloadSchema, folders: [], recipes: [], settings: nil))
        let incoming: SyncPrefs = SyncPrefs(schema: syncPayloadSchema, folders: ["Board"], recipes: [], settings: ["language.note": setting(.string("fi"), t1)])
        await recording.set(on: true)
        #expect(try await store.writePrefs(prefs: incoming, replacing: empty) == .changedMeanwhile)
        #expect(try await store.prefs() == empty)
        let foldersOnly: SyncPrefs = SyncPrefs(schema: syncPayloadSchema, folders: ["Board"], recipes: [], settings: nil)
        #expect(try await store.writePrefs(prefs: foldersOnly, replacing: empty) == .written)
        await recording.set(on: false)
        #expect(try await store.writePrefs(prefs: incoming, replacing: foldersOnly) == .written)
        #expect(try await store.prefs() == incoming)
        #expect(try test.values().string(forKey: "language.note") == "fi")
    }
}

/// Whether the test's "recording" runs (read on the main actor, as the apps' recorders are).
@MainActor
private final class RecordingFlag {
    var isOn: Bool = false

    func set(on: Bool) {
        isOn = on
    }
}
