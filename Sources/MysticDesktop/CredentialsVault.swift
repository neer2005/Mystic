import Foundation
import Security
import MysticKit

public protocol CredentialsStorage: Sendable {
    func identity() throws -> ClientIdentity
    func certificate(for endpoint: String) throws -> String?
    func saveCertificate(_ certificate: String, for endpoint: String) throws
}

/// Secrets stay in the user's login Keychain; preferences contain only host labels and endpoints.
public final class CredentialsVault: CredentialsStorage, @unchecked Sendable {
    private let lock = NSLock()
    public init() {}
    public func identity() throws -> ClientIdentity {
        lock.lock(); defer { lock.unlock() }
        if let data = try read("identity") { return try JSONDecoder().decode(ClientIdentity.self, from: data) }
        let identity = try HostConnection.generateIdentity()
        try save(JSONEncoder().encode(identity), account: "identity")
        return identity
    }
    public func certificate(for endpoint: String) throws -> String? {
        try read("host:" + endpoint).map { String(decoding: $0, as: UTF8.self) }
    }
    public func saveCertificate(_ certificate: String, for endpoint: String) throws {
        try save(Data(certificate.utf8), account: "host:" + endpoint)
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.mystic.streaming",
         kSecAttrAccount as String: account]
    }
    private func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw HostConnectionError("Keychain returned invalid credential data.") }
        return data
    }
    private func save(_ data: Data, account: String) throws {
        let query = query(account)
        let updates = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw HostConnectionError("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
    }
}
