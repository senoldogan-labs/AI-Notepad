import Foundation
import Security

/// API anahtarlarının Keychain'deki hesap adları.
public enum SecretAccount: String, Sendable, CaseIterable {
    case deepgram
    case elevenlabs
    case anthropic
    /// OpenAI uyumlu LLM sağlayıcısının anahtarı (OpenAI, OpenCode Go…); Ollama'da gerekmez.
    case openai
    /// Not hazır olunca gönderilen webhook adresi (Slack, Teams, Discord, Zapier, Make, n8n); adreste gizli anahtar var.
    case webhook
    /// Eski sürümün tek kanal bağlantısı (Slack ya da Teams); açılışta `destinations`'a taşınır.
    case channel
    /// Notun gönderildiği hedefler (hesap bağlantıları, webhook adresleri, Notion; JSON, bkz. `NoteDestination`).
    case destinations
    /// Görev araçları (Linear, Jira; JSON, bkz. `TaskTracker`).
    case taskTrackers
}

/// Uygulamanın Keychain servis adı.
public let keychainService: String = "AINotepad"

/// Keychain erişim hataları. Anahtar değeri hiçbir zaman hataya girmez.
public enum KeychainError: Error, Equatable {
    case notFound(service: String, account: String)
    case unexpectedStatus(operation: String, status: Int32)
}

/// Öğenin ne zaman okunabileceği (`kSecAttrAccessible`); nil ise sistemin varsayılanı (yalnız cihaz kilitli değilken).
/// iPhone'da notun kendiliğinden gönderildiği hedeflerin ve görev araçlarının sırları kilitli ekranda da okunabilmeli:
/// toplantı bitip not arka planda hazırlandığında telefon çoğu zaman kilitlidir ve gönderim kilit açılana dek beklerdi.
/// "Bu cihazda": yedekten başka cihaza taşınmaz. Mac'te (dosya tabanlı Anahtar Zinciri) değişmez. Saf fonksiyondur.
func secretAccessibility(account: SecretAccount) -> String? {
    #if os(iOS)
    switch account {
    case .destinations, .taskTrackers:
        return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    case .deepgram, .elevenlabs, .anthropic, .openai, .webhook, .channel:
        return nil
    }
    #else
    return nil
    #endif
}

/// Kayıtlı anahtarı okur; yoksa `.notFound`. Erişilebilirliği `secretAccessibility`'den farklı (eski sürümün yazdığı)
/// öğe okununca güncellenir: bir sonraki kilitli okumada da açılır.
public func readSecret(service: String, account: SecretAccount) throws -> String {
    var query: [String: Any] = baseQuery(service: service, account: account)
    query[kSecReturnData as String] = true
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
        throw KeychainError.notFound(service: service, account: account.rawValue)
    }
    guard status == errSecSuccess, let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else {
        throw KeychainError.unexpectedStatus(operation: "SecItemCopyMatching", status: status)
    }
    if let accessibility = secretAccessibility(account: account), item[kSecAttrAccessible as String] as? String != accessibility {
        try updateSecret(service: service, account: account, attributes: [kSecAttrAccessible as String: accessibility], operation: "SecItemUpdate(accessible)")
    }
    return String(decoding: data, as: UTF8.self)
}

/// Var olan öğenin özniteliklerini günceller; öğe yoksa `.notFound`.
private func updateSecret(service: String, account: SecretAccount, attributes: [String: Any], operation: String) throws {
    let status: OSStatus = SecItemUpdate(baseQuery(service: service, account: account) as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
        throw KeychainError.notFound(service: service, account: account.rawValue)
    }
    guard status == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: operation, status: status)
    }
}

/// Okumayı arka planda yapar: Keychain izin penceresi açıkken (ör. `security` aracıyla eklenmiş anahtar)
/// arayüz donmasın.
public func readSecretInBackground(service: String, account: SecretAccount) async throws -> String {
    try await runBlocking(qos: .userInitiated) { () throws -> String in
        try readSecret(service: service, account: account)
    }
}

/// Kayıtlı değilse nil; diğer Keychain hataları fırlatılır (yok sayılmaz).
public func optionalSecretInBackground(service: String, account: SecretAccount) async throws -> String? {
    do {
        return try await readSecretInBackground(service: service, account: account)
    } catch KeychainError.notFound {
        return nil
    }
}

/// Anahtarı kaydeder; varsa üzerine yazar. Erişilebilirlik `secretAccessibility`'dendir (üzerine yazımda da güncellenir).
public func saveSecret(service: String, account: SecretAccount, value: String) throws {
    var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
    if let accessibility = secretAccessibility(account: account) {
        attributes[kSecAttrAccessible as String] = accessibility
    }
    do {
        try updateSecret(service: service, account: account, attributes: attributes, operation: "SecItemUpdate")
        return
    } catch KeychainError.notFound {
        attributes.merge(baseQuery(service: service, account: account)) { (_: Any, new: Any) -> Any in new }
    }
    let addStatus: OSStatus = SecItemAdd(attributes as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
        throw KeychainError.unexpectedStatus(operation: "SecItemAdd", status: addStatus)
    }
}

/// Anahtarı siler; zaten yoksa hata değildir.
public func deleteSecret(service: String, account: SecretAccount) throws {
    let status: OSStatus = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
        throw KeychainError.unexpectedStatus(operation: "SecItemDelete", status: status)
    }
}

private func baseQuery(service: String, account: SecretAccount) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account.rawValue,
    ]
}

/// Anahtarın kayıtlı olup olmadığı. Değeri okumadığı için Keychain izin penceresi açmaz.
public func secretExists(service: String, account: SecretAccount) throws -> Bool {
    try exists(query: baseQuery(service: service, account: account), operation: "SecItemCopyMatching(attributes)")
}

private func exists(query base: [String: Any], operation: String) throws -> Bool {
    var query: [String: Any] = base
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess: return true
    case errSecItemNotFound: return false
    default: throw KeychainError.unexpectedStatus(operation: operation, status: status)
    }
}
