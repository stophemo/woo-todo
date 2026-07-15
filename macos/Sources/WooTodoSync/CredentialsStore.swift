import Foundation
import Security

public struct SyncCredentials: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let vaultId: String
    public let deviceId: String
    public let deviceToken: String
    public let vaultKey: Data

    public init(
        endpoint: URL,
        vaultId: String,
        deviceId: String,
        deviceToken: String,
        vaultKey: Data
    ) {
        self.endpoint = endpoint
        self.vaultId = vaultId
        self.deviceId = deviceId
        self.deviceToken = deviceToken
        self.vaultKey = vaultKey
    }

    public func validate() throws {
        guard SyncEndpointPolicy.isAllowed(endpoint),
              !vaultId.isEmpty,
              !deviceId.isEmpty else {
            throw CredentialsStoreError.invalidCredentials
        }
        let token = try Base64URL.decode(deviceToken)
        guard token.count == 32, vaultKey.count == AES256GCM.keyByteCount else {
            throw CredentialsStoreError.invalidCredentials
        }
    }
}

public protocol SyncCredentialsStoring: Sendable {
    func save(_ credentials: SyncCredentials) throws
    func load() throws -> SyncCredentials?
    func delete() throws
}

public enum CredentialsStoreError: Error, Equatable, LocalizedError {
    case invalidCredentials
    case encodingFailed
    case decodingFailed
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "同步凭据格式无效"
        case .encodingFailed: "同步凭据编码失败"
        case .decodingFailed: "Keychain 中的同步凭据无法解析"
        case .keychain(let status): "Keychain 操作失败，状态码：\(status)"
        }
    }
}

public final class KeychainCredentialsStore: SyncCredentialsStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = "dev.woo-todo.sync",
        account: String = "primary-device",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func save(_ credentials: SyncCredentials) throws {
        try credentials.validate()
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw CredentialsStoreError.encodingFailed
        }
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw CredentialsStoreError.keychain(updateStatus)
            }
        } else if status != errSecSuccess {
            throw CredentialsStoreError.keychain(status)
        }
    }

    public func load() throws -> SyncCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialsStoreError.keychain(status)
        }
        guard let data = item as? Data,
              let credentials = try? JSONDecoder().decode(SyncCredentials.self, from: data) else {
            throw CredentialsStoreError.decodingFailed
        }
        try credentials.validate()
        return credentials
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialsStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
