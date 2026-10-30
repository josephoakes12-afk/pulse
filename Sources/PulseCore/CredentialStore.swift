import Foundation
import Security

/// Connection secrets never enter configuration JSON, SQLite or logs.
public struct CredentialStore: Sendable {
    private let service: String

    public init(service: String = "local.pulse.credentials") { self.service = service }

    public func save(secret: String, for projectID: UUID) throws {
        guard !secret.isEmpty else { try delete(for: projectID); return }
        let value = Data(secret.utf8)
        let query = baseQuery(projectID)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData: value] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query
            item[kSecValueData] = value
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if update != errSecSuccess { throw failure(update) }
    }

    public func load(for projectID: UUID) throws -> String? {
        var query = baseQuery(projectID)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw failure(status)
        }
        return value
    }

    public func delete(for projectID: UUID) throws {
        let result = SecItemDelete(baseQuery(projectID) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw failure(result) }
    }

    private func baseQuery(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id.uuidString]
    }

    private func failure(_ status: OSStatus) -> PulseError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            .credential("Pulse could not access this connection’s Keychain item. Unlock Keychain and try again.")
        default: .credential("Pulse could not save or read this connection’s Keychain item.")
        }
    }
}
