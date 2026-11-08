import Foundation

// What a device keeps about shared folders, inside the account's own data folder (`Accounts/<key>/SharedFolders/`, the
// same protection as the account's meetings; removed with the account's data): the notes of joined folders for offline
// reading, the version pins (rollback protection) and the publisher's ledger of published items.

/// Name of the shared-folder folder inside an account's data folder.
let sharedFoldersFolderName: String = "SharedFolders"

extension AppPaths {
    /// `<data folder>/Accounts/<key>/SharedFolders`. Pure function.
    public static func accountSharedFoldersDirectory(dataRoot: URL, accountKey: String) -> URL {
        accountDataDirectory(dataRoot: dataRoot, accountKey: accountKey).appending(path: sharedFoldersFolderName, directoryHint: .isDirectory)
    }
}

/// A device's shared-folder bookkeeping.
public struct SharedFolderDeviceState: Sendable, Equatable, Codable {
    /// This device's random publisher id (no hardware identifier).
    public let deviceID: String
    /// Folder id → highest key epoch and roster version seen.
    public let pins: [String: SharedFolderVersionPin]
    /// Folder id → item ids this device published.
    public let ledgers: [String: [String]]

    public init(deviceID: String, pins: [String: SharedFolderVersionPin], ledgers: [String: [String]]) {
        self.deviceID = deviceID
        self.pins = pins
        self.ledgers = ledgers
    }

    /// A fresh state with a new device id.
    public static func fresh() -> SharedFolderDeviceState {
        SharedFolderDeviceState(deviceID: UUID().uuidString.lowercased(), pins: [:], ledgers: [:])
    }

    /// The state without folders that are gone (stopped, left, removed). Pure function.
    public func keeping(folderIDs: Set<String>) -> SharedFolderDeviceState {
        SharedFolderDeviceState(deviceID: deviceID, pins: pins.filter { folderIDs.contains($0.key) }, ledgers: ledgers.filter { folderIDs.contains($0.key) })
    }

    public func with(pin: SharedFolderVersionPin, folderID: String) -> SharedFolderDeviceState {
        var next: [String: SharedFolderVersionPin] = pins
        next[folderID] = pin
        return SharedFolderDeviceState(deviceID: deviceID, pins: next, ledgers: ledgers)
    }

    public func with(ledger: Set<String>, folderID: String) -> SharedFolderDeviceState {
        var next: [String: [String]] = ledgers
        next[folderID] = ledger.sorted()
        return SharedFolderDeviceState(deviceID: deviceID, pins: pins, ledgers: next)
    }
}

private func readJSON<Value: Decodable>(_ type: Value.Type, url: URL) throws -> Value? {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return nil
    }
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw StorageError.readFailed(path: url.path, reason: error.localizedDescription)
    }
    return try JSONDecoder().decode(type, from: data)
}

private func writeJSON<Value: Encodable>(_ value: Value, url: URL) throws {
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: [.atomic])
    } catch let error as EncodingError {
        throw error
    } catch {
        throw StorageError.writeFailed(path: url.path, reason: error.localizedDescription)
    }
}

/// The device state; a missing file is a fresh state (new device id).
public func loadSharedFolderDeviceState(directory: URL) throws -> SharedFolderDeviceState {
    try readJSON(SharedFolderDeviceState.self, url: directory.appending(path: "device.json")) ?? .fresh()
}

public func saveSharedFolderDeviceState(state: SharedFolderDeviceState, directory: URL) throws {
    try writeJSON(state, url: directory.appending(path: "device.json"))
}

/// The cached notes of a joined folder (empty when none were read yet).
public func loadSharedFolderNotes(directory: URL, folderID: String) throws -> [SharedFolderCachedItem] {
    try readJSON([SharedFolderCachedItem].self, url: directory.appending(path: "\(folderID).json")) ?? []
}

public func saveSharedFolderNotes(notes: [SharedFolderCachedItem], directory: URL, folderID: String) throws {
    try writeJSON(notes, url: directory.appending(path: "\(folderID).json"))
}

/// Deletes the cached notes of folders not in `keep` (stopped, left or removed).
public func pruneSharedFolderNotes(directory: URL, keep: Set<String>) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else {
        return
    }
    let files: [URL]
    do {
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    } catch {
        throw StorageError.readFailed(path: directory.path, reason: error.localizedDescription)
    }
    for file in files where file.pathExtension == "json" && file.lastPathComponent != "device.json" {
        let folderID: String = file.deletingPathExtension().lastPathComponent
        guard !keep.contains(folderID) else {
            continue
        }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            throw StorageError.deleteFailed(path: file.path, reason: error.localizedDescription)
        }
    }
}
