import Foundation
import Security

/// Keychain account name of the sync key item (inside the account's own Keychain service).
public let syncKeyKeychainAccount: String = "syncAccountKey"

/// `SyncKeyStore` over one Keychain item of the account's own service (`<app service>.account.<key>`), on this device
/// only: never synchronized through iCloud Keychain (the key reaches other devices with the link code). On iPhone it is
/// readable after the first unlock, so a background sync can open it.
public struct SyncKeychainStore: SyncKeyStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: syncKeyKeychainAccount,
        ]
    }

    public func load() throws -> SyncDeviceKey? {
        var query: [String: Any] = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(operation: "SecItemCopyMatching(syncKey)", status: status)
        }
        return try decodedSyncDeviceKey(text: String(decoding: data, as: UTF8.self))
    }

    public func save(key: SyncDeviceKey) throws {
        let data: Data = Data(try encodedSyncDeviceKey(key: key).utf8)
        let updateStatus: OSStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "SecItemUpdate(syncKey)", status: updateStatus)
        }
        var attributes: [String: Any] = baseQuery
        attributes[kSecValueData as String] = data
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        let addStatus: OSStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unexpectedStatus(operation: "SecItemAdd(syncKey)", status: addStatus)
        }
    }

    public func delete() throws {
        let status: OSStatus = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(operation: "SecItemDelete(syncKey)", status: status)
        }
    }
}
