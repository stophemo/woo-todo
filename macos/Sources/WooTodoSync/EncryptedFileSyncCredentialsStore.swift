import CryptoKit
import Foundation
import Security

public enum EncryptedFileSyncCredentialsStoreError: Error, Equatable, LocalizedError {
    case invalidKeyFile
    case secureEnclaveKeyUnavailable
    case invalidCredentialsFile
    case keychainUnavailable(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyFile:
            "本机同步凭据密钥文件无效"
        case .secureEnclaveKeyUnavailable:
            "本机同步凭据密钥无法由 Secure Enclave 解锁"
        case .invalidCredentialsFile:
            "本机同步凭据无效或已损坏"
        case .keychainUnavailable(let message):
            "本机同步凭据密钥无法读写 Keychain：\(message)"
        case .fileSystem(let message):
            "无法访问本机同步凭据：\(message)"
        }
    }
}

/// 将同步凭据加密保存在应用数据目录，避免 ad-hoc 签名更新后反复触发 Keychain 授权。
/// 加密密钥优先使用 Secure Enclave；SE 不可用时才降级到 Keychain 中的软件随机密钥。
public final class EncryptedFileSyncCredentialsStore: SyncCredentialsStoring,
    @unchecked Sendable {
    private let directoryURL: URL
    private let credentialsURL: URL
    private let keyURL: URL
    private let migrationMarkerURL: URL
    private let legacyStore: (any SyncCredentialsStoring)?
    private let fileManager: FileManager
    private let preferSecureEnclave: Bool
    let keychainService: String
    let keychainAccount: String
    private let lock = NSLock()

    private static let credentialsFileName = "sync-credentials.enc"
    private static let keyFileName = "sync-local-key.json"
    private static let migrationMarkerFileName = ".sync-keychain-migrated"
    private static let credentialsFormat = "woo-todo-sync-credentials"
    private static let keyFormat = "woo-todo-local-credentials-key"
    private static let version = 1
    private static let cipher = "AES-256-GCM"
    private static let aad = Data("woo-todo-sync-credentials-v1".utf8)
    private static let keyDerivationSalt = Data(
        "io.github.stophemo.woo-todo.sync-credentials".utf8
    )
    private static let defaultKeychainService = "dev.woo-todo.sync-key"
    private static let defaultKeychainAccount = "sync-credentials-key"

    public convenience init(
        directoryURL: URL,
        legacyStore: (any SyncCredentialsStoring)? = KeychainCredentialsStore()
    ) {
        self.init(
            directoryURL: directoryURL,
            legacyStore: legacyStore,
            fileManager: .default,
            preferSecureEnclave: true
        )
    }

    init(
        directoryURL: URL,
        legacyStore: (any SyncCredentialsStoring)?,
        fileManager: FileManager,
        preferSecureEnclave: Bool,
        keychainService: String = EncryptedFileSyncCredentialsStore.defaultKeychainService,
        keychainAccount: String = EncryptedFileSyncCredentialsStore.defaultKeychainAccount
    ) {
        self.directoryURL = directoryURL
        self.credentialsURL = directoryURL.appendingPathComponent(
            Self.credentialsFileName,
            isDirectory: false
        )
        self.keyURL = directoryURL.appendingPathComponent(
            Self.keyFileName,
            isDirectory: false
        )
        self.migrationMarkerURL = directoryURL.appendingPathComponent(
            Self.migrationMarkerFileName,
            isDirectory: false
        )
        self.legacyStore = legacyStore
        self.fileManager = fileManager
        self.preferSecureEnclave = preferSecureEnclave
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    public func save(_ credentials: SyncCredentials) throws {
        try credentials.validate()
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(credentials)
    }

    public func load() throws -> SyncCredentials? {
        lock.lock()
        defer { lock.unlock() }

        if fileManager.fileExists(atPath: credentialsURL.path) {
            return try loadEncryptedCredentials()
        }
        if fileManager.fileExists(atPath: migrationMarkerURL.path) {
            return nil
        }

        let legacyCredentials = try legacyStore?.load()
        if let legacyCredentials {
            try saveUnlocked(legacyCredentials)
        } else {
            try writeMigrationMarker()
        }
        return legacyCredentials
    }

    public func delete() throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureDirectory()
        // 先写迁移标记，避免旧 Keychain 项在删除后被重新导入。
        try writeMigrationMarker()
        if fileManager.fileExists(atPath: credentialsURL.path) {
            do {
                try fileManager.removeItem(at: credentialsURL)
            } catch {
                throw Self.fileSystemError(error)
            }
        }
        // 旧版本可能仍保留在 Keychain；删除成功与否不再阻塞本地清理。
        _ = try? legacyStore?.delete()
        _ = SecItemDelete(keychainQuery() as CFDictionary)
        try? fileManager.removeItem(at: keyURL)
    }

    private func saveUnlocked(_ credentials: SyncCredentials) throws {
        try ensureDirectory()
        let key = try loadOrCreateEncryptionKey()
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(credentials)
        } catch {
            throw EncryptedFileSyncCredentialsStoreError.invalidCredentialsFile
        }
        let envelope: EncryptedEnvelope
        do {
            envelope = try AES256GCM.seal(
                plaintext,
                key: key,
                authenticating: Self.aad
            )
        } catch {
            throw EncryptedFileSyncCredentialsStoreError.invalidCredentialsFile
        }
        let file = CredentialsFile(
            format: Self.credentialsFormat,
            version: Self.version,
            cipher: Self.cipher,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writeProtectedData(encoder.encode(file), to: credentialsURL)
            try writeMigrationMarker()
        } catch let error as EncryptedFileSyncCredentialsStoreError {
            throw error
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    private func loadEncryptedCredentials() throws -> SyncCredentials {
        do {
            let file = try JSONDecoder().decode(
                CredentialsFile.self,
                from: Data(contentsOf: credentialsURL)
            )
            guard file.format == Self.credentialsFormat,
                  file.version == Self.version,
                  file.cipher == Self.cipher else {
                throw EncryptedFileSyncCredentialsStoreError.invalidCredentialsFile
            }
            let key = try loadExistingEncryptionKey()
            let plaintext = try AES256GCM.open(
                EncryptedEnvelope(ciphertext: file.ciphertext, nonce: file.nonce),
                key: key,
                authenticating: Self.aad
            )
            let credentials = try JSONDecoder().decode(
                SyncCredentials.self,
                from: plaintext
            )
            try credentials.validate()
            return credentials
        } catch let error as CredentialsStoreError {
            // 保留“地址已不被支持”等语义，供旧同步方式检测使用。
            throw error
        } catch let error as EncryptedFileSyncCredentialsStoreError {
            throw error
        } catch {
            throw EncryptedFileSyncCredentialsStoreError.invalidCredentialsFile
        }
    }

    private func loadOrCreateEncryptionKey() throws -> Data {
        if fileManager.fileExists(atPath: keyURL.path) {
            return try loadExistingEncryptionKey()
        }
        if let rawKey = try loadRawKeyFromKeychain() {
            return rawKey
        }

        if preferSecureEnclave, SecureEnclave.isAvailable {
            do {
                let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey()
                let keyFile = KeyFile(
                    format: Self.keyFormat,
                    version: Self.version,
                    kind: .secureEnclaveP256,
                    value: Base64URL.encode(privateKey.dataRepresentation)
                )
                try writeKeyFile(keyFile)
                return try Self.deriveEncryptionKey(from: privateKey)
            } catch {
                // Secure Enclave 创建失败时降级为 Keychain 中的软件随机密钥。
            }
        }

        let key = try SecureRandom.bytes(count: AES256GCM.keyByteCount)
        try saveRawKeyToKeychain(key)
        return key
    }

    private func loadExistingEncryptionKey() throws -> Data {
        if fileManager.fileExists(atPath: keyURL.path) {
            return try loadEncryptionKeyFromFile()
        }
        if let rawKey = try loadRawKeyFromKeychain() {
            return rawKey
        }
        throw EncryptedFileSyncCredentialsStoreError.invalidKeyFile
    }

    private func loadEncryptionKeyFromFile() throws -> Data {
        let keyFile: KeyFile
        do {
            keyFile = try JSONDecoder().decode(
                KeyFile.self,
                from: Data(contentsOf: keyURL)
            )
        } catch {
            throw EncryptedFileSyncCredentialsStoreError.invalidKeyFile
        }
        guard keyFile.format == Self.keyFormat,
              keyFile.version == Self.version,
              let value = try? Base64URL.decode(keyFile.value) else {
            throw EncryptedFileSyncCredentialsStoreError.invalidKeyFile
        }

        switch keyFile.kind {
        case .secureEnclaveP256:
            do {
                let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: value
                )
                return try Self.deriveEncryptionKey(from: privateKey)
            } catch {
                throw EncryptedFileSyncCredentialsStoreError.secureEnclaveKeyUnavailable
            }
        case .rawAES256:
            guard value.count == AES256GCM.keyByteCount else {
                throw EncryptedFileSyncCredentialsStoreError.invalidKeyFile
            }
            return value
        }
    }

    private static func deriveEncryptionKey(
        from privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey
    ) throws -> Data {
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(
            with: privateKey.publicKey
        )
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: keyDerivationSalt,
            sharedInfo: Data(),
            outputByteCount: AES256GCM.keyByteCount
        )
        return symmetricKey.withUnsafeBytes { Data($0) }
    }

    private func writeKeyFile(_ keyFile: KeyFile) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writeProtectedData(encoder.encode(keyFile), to: keyURL)
        } catch let error as EncryptedFileSyncCredentialsStoreError {
            throw error
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    private func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private func saveRawKeyToKeychain(_ key: Data) throws {
        var attributes = keychainQuery()
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                keychainQuery() as CFDictionary,
                [kSecValueData as String: key] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw EncryptedFileSyncCredentialsStoreError.keychainUnavailable(
                    "错误码 \(updateStatus)"
                )
            }
        } else if status != errSecSuccess {
            throw EncryptedFileSyncCredentialsStoreError.keychainUnavailable(
                "错误码 \(status)"
            )
        }
    }

    private func loadRawKeyFromKeychain() throws -> Data? {
        var request = keychainQuery()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw EncryptedFileSyncCredentialsStoreError.keychainUnavailable(
                "错误码 \(status)"
            )
        }
        guard data.count == AES256GCM.keyByteCount else {
            throw EncryptedFileSyncCredentialsStoreError.invalidKeyFile
        }
        return data
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    private func writeMigrationMarker() throws {
        do {
            try writeProtectedData(Data("1".utf8), to: migrationMarkerURL)
        } catch let error as EncryptedFileSyncCredentialsStoreError {
            throw error
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    private func writeProtectedData(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    private static func fileSystemError(_ error: Error) -> Error {
        EncryptedFileSyncCredentialsStoreError.fileSystem(error.localizedDescription)
    }
}

private struct CredentialsFile: Codable {
    let format: String
    let version: Int
    let cipher: String
    let nonce: String
    let ciphertext: String
}

private struct KeyFile: Codable {
    enum Kind: String, Codable {
        case secureEnclaveP256 = "secure-enclave-p256"
        case rawAES256 = "raw-aes-256"
    }

    let format: String
    let version: Int
    let kind: Kind
    let value: String
}
