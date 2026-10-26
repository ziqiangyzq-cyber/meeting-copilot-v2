import Foundation
import Security
import APIIntelligence

public protocol BackendCredentialStore {
    func save(_ secret: String, reference: String) throws
    func read(reference: String) throws -> String?
    func remove(reference: String) throws
}

/// Local generic passwords. Only an opaque account reference is written to settings.json.
public struct KeychainBackendCredentialStore: BackendCredentialStore, APICredentialProvider, Sendable {
    private let service = ProductIdentity.keychainService
    private let legacyServices = [
        LegacyProductMigration.legacyV2KeychainService,
        "org.local.foresight-rebuild.backend-api"
    ]
    public init() {}

    private func query(_ reference: String, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: reference,
         kSecAttrSynchronizable as String: false]
    }

    public func save(_ secret: String, reference: String) throws {
        let query = query(reference)
        let attributes: [String: Any] = [kSecValueData as String: Data(secret.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw failure(updateStatus) }
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw failure(addStatus) }
    }

    public func read(reference: String) throws -> String? {
        if let secret = try read(reference: reference, service: service) {
            return secret
        }
        // Existing installations kept the API key under older service names. Copy it into the public
        // identity once, then continue using the new service. A read failure on a legacy item is not hidden.
        for legacyService in legacyServices {
            guard let secret = try read(reference: reference, service: legacyService) else { continue }
            try? save(secret, reference: reference)
            return secret
        }
        return nil
    }

    private func read(reference: String, service: String) throws -> String? {
        var item = query(reference, service: service)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw failure(errSecDecode)
        }
        return secret
    }

    public func remove(reference: String) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "MeetingCopilotKeychain", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "钥匙串操作失败（\(status)）"])
    }

    public func credential(for reference: String) async throws -> String {
        if reference.hasPrefix("KEYCHAIN_") {
            guard let secret = try read(reference: reference), !secret.isEmpty else {
                throw APIIntelligenceError.invalidConfiguration
            }
            return secret
        }
        guard let secret = ProcessInfo.processInfo.environment[reference], !secret.isEmpty else {
            throw APIIntelligenceError.invalidConfiguration
        }
        return secret
    }
}
