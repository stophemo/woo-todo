import CryptoKit
import Foundation
import Security

public enum EncryptedFileCredentialsStoreError: Error, Equatable, LocalizedError {
    case invalidKeyFile
    case secureEnclaveKeyUnavailable
    case invalidCredentialsFile
    case keychainUnavailable(String)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyFile:
            "本机 WebDAV 配置密钥文件无效"
        case .secureEnclaveKeyUnavailable:
            "本机 WebDAV 配置密钥无法由 Secure Enclave 解锁"
        case .invalidCredentialsFile:
            "本机加密的 WebDAV 配置无效或已损坏"
        case .keychainUnavailable(let message):
            "本机 WebDAV 配置密钥无法读写 Keychain：\(message)"
        case .fileSystem(let message):
            "无法访问本机 WebDAV 配置：\(message)"
        }
    }
}

/// 早期版本把完整 WebDAV 凭据放在 Keychain。迁移与删除路径通过该协议访问，
/// 便于测试注入且确保“清除本机数据”后旧凭据不会再次回填。
protocol WebDavLegacyCredentialStoring: Sendable {
    func loadLegacyCredentials() throws -> WebDavCredentials?
    func deleteLegacyCredentials() throws
}

struct KeychainWebDavLegacyCredentialStore: WebDavLegacyCredentialStoring {
    let service: String
    let accounts: [String]

    private struct StoredCredentials: Codable {
        let endpoint: URL
        let username: String
        let appPassword: String
        let vaultId: String
        let deviceId: String
        let vaultKey: Data
    }

    func loadLegacyCredentials() throws -> WebDavCredentials? {
        for account in accounts {
            var request: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess, let data = result as? Data else {
                throw EncryptedFileCredentialsStoreError.keychainUnavailable("错误码 \(status)")
            }
            guard let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
                continue
            }
            let credentials = WebDavCredentials(
                endpoint: stored.endpoint,
                username: stored.username,
                appPassword: stored.appPassword,
                vaultId: stored.vaultId,
                deviceId: stored.deviceId,
                vaultKey: stored.vaultKey
            )
            if (try? credentials.validate()) != nil {
                return credentials
            }
        }
        return nil
    }

    func deleteLegacyCredentials() throws {
        for account in accounts {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw EncryptedFileCredentialsStoreError.keychainUnavailable("错误码 \(status)")
            }
        }
    }
}

struct EmptyWebDavLegacyCredentialStore: WebDavLegacyCredentialStoring {
    func loadLegacyCredentials() throws -> WebDavCredentials? { nil }
    func deleteLegacyCredentials() throws {}
}

/// 将 WebDAV 账号与同步身份分开加密保存在应用数据目录：
/// `webdav-account.enc` 只含地址、用户名与应用密码，`webdav-identity.enc`
/// 只含 vaultId/deviceId/vaultKey。两者使用独立 AAD，任一损坏不影响另一份。
/// 旧版单个 `webdav-credentials.enc` 在首次读取时迁移后删除。
public final class EncryptedFileWebDavCredentialsStore: WebDavCredentialsStoring,
    @unchecked Sendable {
    private let directoryURL: URL
    private let legacyCredentialsURL: URL
    private let accountURL: URL
    private let identityURL: URL
    private let keyURL: URL
    private let migrationMarkerURL: URL
    private let fileManager: FileManager
    private let preferSecureEnclave: Bool
    private let legacyCredentialStore: any WebDavLegacyCredentialStoring
    let keychainService: String
    let keychainAccount: String
    private let lock = NSLock()

    private static let legacyCredentialsFileName = "webdav-credentials.enc"
    private static let accountFileName = "webdav-account.enc"
    private static let identityFileName = "webdav-identity.enc"
    private static let keyFileName = "webdav-local-key.json"
    private static let migrationMarkerFileName = ".webdav-keychain-migrated"
    private static let accountFormat = "woo-todo-webdav-account"
    private static let identityFormat = "woo-todo-webdav-identity"
    private static let legacyFormat = "woo-todo-webdav-credentials"
    private static let keyFormat = "woo-todo-local-credentials-key"
    private static let version = 1
    private static let cipher = "AES-256-GCM"
    private static let accountAAD = Data("woo-todo-webdav-account-v1".utf8)
    private static let identityAAD = Data("woo-todo-webdav-identity-v1".utf8)
    private static let legacyAAD = Data("woo-todo-webdav-credentials-v1".utf8)
    private static let keyDerivationSalt = Data(
        "io.github.stophemo.woo-todo.local-credentials".utf8
    )
    private static let defaultKeychainService = "dev.woo-todo.webdav"
    private static let defaultKeychainAccount = "webdav-credentials-key"
    private static let legacyCredentialService = "dev.woo-todo.webdav"
    private static let legacyCredentialAccounts = ["generic-webdav", "jianguoyun"]

    public convenience init(
        directoryURL: URL,
        preferSecureEnclave: Bool = true
    ) {
        self.init(
            directoryURL: directoryURL,
            fileManager: .default,
            preferSecureEnclave: preferSecureEnclave,
            legacyCredentialStore: KeychainWebDavLegacyCredentialStore(
                service: EncryptedFileWebDavCredentialsStore.legacyCredentialService,
                accounts: EncryptedFileWebDavCredentialsStore.legacyCredentialAccounts
            )
        )
    }

    init(
        directoryURL: URL,
        fileManager: FileManager,
        preferSecureEnclave: Bool,
        keychainService: String = EncryptedFileWebDavCredentialsStore.defaultKeychainService,
        keychainAccount: String = EncryptedFileWebDavCredentialsStore.defaultKeychainAccount,
        legacyCredentialStore: any WebDavLegacyCredentialStoring =
            EmptyWebDavLegacyCredentialStore()
    ) {
        self.directoryURL = directoryURL
        self.legacyCredentialsURL = directoryURL.appendingPathComponent(
            Self.legacyCredentialsFileName,
            isDirectory: false
        )
        self.accountURL = directoryURL.appendingPathComponent(
            Self.accountFileName,
            isDirectory: false
        )
        self.identityURL = directoryURL.appendingPathComponent(
            Self.identityFileName,
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
        self.fileManager = fileManager
        self.preferSecureEnclave = preferSecureEnclave
        self.legacyCredentialStore = legacyCredentialStore
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
    }

    // MARK: - 账号

    public func saveAccount(_ account: WebDavAccount) throws {
        try account.validate()
        lock.lock()
        defer { lock.unlock() }
        try saveEncrypted(
            account,
            format: Self.accountFormat,
            aad: Self.accountAAD,
            to: accountURL
        )
    }

    public func loadAccount() throws -> WebDavAccount? {
        lock.lock()
        defer { lock.unlock() }
        try migrateLegacyIfNeeded()
        guard fileManager.fileExists(atPath: accountURL.path) else { return nil }
        return try loadEncrypted(
            WebDavAccount.self,
            format: Self.accountFormat,
            aad: Self.accountAAD,
            from: accountURL
        )
    }

    public func deleteAccount() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeFileIfExists(accountURL)
        try clearLegacyCredentialsAndMarkMigrated()
    }

    // MARK: - 身份

    public func saveIdentity(_ identity: WebDavIdentity) throws {
        try identity.validate()
        lock.lock()
        defer { lock.unlock() }
        try saveEncrypted(
            identity,
            format: Self.identityFormat,
            aad: Self.identityAAD,
            to: identityURL
        )
    }

    public func loadIdentity() throws -> WebDavIdentity? {
        lock.lock()
        defer { lock.unlock() }
        try migrateLegacyIfNeeded()
        guard fileManager.fileExists(atPath: identityURL.path) else { return nil }
        return try loadEncrypted(
            WebDavIdentity.self,
            format: Self.identityFormat,
            aad: Self.identityAAD,
            from: identityURL
        )
    }

    public func deleteIdentity() throws {
        lock.lock()
        defer { lock.unlock() }
        try removeFileIfExists(identityURL)
        try clearLegacyCredentialsAndMarkMigrated()
    }

    /// 测试用：按 0.2.x 的单文件格式写入完整凭据，验证迁移路径。
    internal func saveLegacyCredentialsForTesting(_ credentials: WebDavCredentials) throws {
        try credentials.validate()
        lock.lock()
        defer { lock.unlock() }
        try saveEncrypted(
            LegacyCredentials(
                endpoint: credentials.endpoint,
                username: credentials.username,
                appPassword: credentials.appPassword,
                vaultId: credentials.vaultId,
                deviceId: credentials.deviceId,
                vaultKey: credentials.vaultKey
            ),
            format: Self.legacyFormat,
            aad: Self.legacyAAD,
            to: legacyCredentialsURL
        )
    }

    // MARK: - 旧版完整凭据迁移

    private struct LegacyCredentials: Codable {
        let endpoint: URL
        let username: String
        let appPassword: String
        let vaultId: String
        let deviceId: String
        let vaultKey: Data
    }

    private func migrateLegacyIfNeeded() throws {
        guard !fileManager.fileExists(atPath: accountURL.path)
                || !fileManager.fileExists(atPath: identityURL.path) else {
            return
        }
        if fileManager.fileExists(atPath: legacyCredentialsURL.path) {
            let legacy = try loadEncrypted(
                LegacyCredentials.self,
                format: Self.legacyFormat,
                aad: Self.legacyAAD,
                from: legacyCredentialsURL
            )
            let credentials = WebDavCredentials(
                endpoint: legacy.endpoint,
                username: legacy.username,
                appPassword: legacy.appPassword,
                vaultId: legacy.vaultId,
                deviceId: legacy.deviceId,
                vaultKey: legacy.vaultKey
            )
            try credentials.validate()
            if !fileManager.fileExists(atPath: accountURL.path) {
                try saveEncrypted(
                    credentials.account,
                    format: Self.accountFormat,
                    aad: Self.accountAAD,
                    to: accountURL
                )
            }
            if !fileManager.fileExists(atPath: identityURL.path) {
                try saveEncrypted(
                    credentials.identity,
                    format: Self.identityFormat,
                    aad: Self.identityAAD,
                    to: identityURL
                )
            }
            try? fileManager.removeItem(at: legacyCredentialsURL)
            // 旧文件导入成功后同样删除更早版本的 Keychain 凭据，避免清除本机数据后回填。
            try clearLegacyCredentialsAndMarkMigrated()
            return
        }
        // 更早版本把完整凭据放在 Keychain；迁移一次后写入迁移标记。
        guard !fileManager.fileExists(atPath: migrationMarkerURL.path),
              !fileManager.fileExists(atPath: accountURL.path),
              !fileManager.fileExists(atPath: identityURL.path) else { return }
        if let credentials = try legacyCredentialStore.loadLegacyCredentials() {
            try credentials.validate()
            try saveEncrypted(
                credentials.account,
                format: Self.accountFormat,
                aad: Self.accountAAD,
                to: accountURL
            )
            try saveEncrypted(
                credentials.identity,
                format: Self.identityFormat,
                aad: Self.identityAAD,
                to: identityURL
            )
        }
        try clearLegacyCredentialsAndMarkMigrated()
    }

    /// 删除旧 Keychain 凭据并写入迁移标记；标记存在时不会再从 Keychain 回填。
    private func clearLegacyCredentialsAndMarkMigrated() throws {
        var deletionError: Error?
        do {
            try legacyCredentialStore.deleteLegacyCredentials()
        } catch {
            deletionError = error
        }
        // 即使 Keychain 删除失败也写入迁移标记，保证下次启动不会再回填旧身份。
        try ensureDirectory()
        try writeMigrationMarker()
        if let deletionError {
            throw deletionError
        }
    }

    // MARK: - 加解密

    private func saveEncrypted<T: Encodable>(
        _ value: T,
        format: String,
        aad: Data,
        to url: URL
    ) throws {
        try ensureDirectory()
        let key = try loadOrCreateEncryptionKey()
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(value)
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
        let envelope: EncryptedEnvelope
        do {
            envelope = try AES256GCM.seal(plaintext, key: key, authenticating: aad)
        } catch {
            throw EncryptedFileCredentialsStoreError.invalidCredentialsFile
        }
        let file = CredentialsFile(
            format: format,
            version: Self.version,
            cipher: Self.cipher,
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writeProtectedData(encoder.encode(file), to: url)
            try writeMigrationMarker()
        } catch let error as EncryptedFileCredentialsStoreError {
            throw error
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    private func loadEncrypted<T: Decodable>(
        _ type: T.Type,
        format: String,
        aad: Data,
        from url: URL
    ) throws -> T {
        do {
            let file = try JSONDecoder().decode(
                CredentialsFile.self,
                from: Data(contentsOf: url)
            )
            guard file.format == format,
                  file.version == Self.version,
                  file.cipher == Self.cipher else {
                throw EncryptedFileCredentialsStoreError.invalidCredentialsFile
            }
            let key = try loadExistingEncryptionKey()
            let plaintext = try AES256GCM.open(
                EncryptedEnvelope(ciphertext: file.ciphertext, nonce: file.nonce),
                key: key,
                authenticating: aad
            )
            return try JSONDecoder().decode(type, from: plaintext)
        } catch let error as EncryptedFileCredentialsStoreError {
            throw error
        } catch {
            throw EncryptedFileCredentialsStoreError.invalidCredentialsFile
        }
    }

    private func removeFileIfExists(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    // MARK: - 本机密钥

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
        throw EncryptedFileCredentialsStoreError.invalidKeyFile
    }

    private func loadEncryptionKeyFromFile() throws -> Data {
        let keyFile: KeyFile
        do {
            keyFile = try JSONDecoder().decode(KeyFile.self, from: Data(contentsOf: keyURL))
        } catch {
            throw EncryptedFileCredentialsStoreError.invalidKeyFile
        }
        guard keyFile.format == Self.keyFormat, keyFile.version == Self.version,
              let value = try? Base64URL.decode(keyFile.value) else {
            throw EncryptedFileCredentialsStoreError.invalidKeyFile
        }

        switch keyFile.kind {
        case .secureEnclaveP256:
            do {
                let privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                    dataRepresentation: value
                )
                return try Self.deriveEncryptionKey(from: privateKey)
            } catch {
                throw EncryptedFileCredentialsStoreError.secureEnclaveKeyUnavailable
            }
        case .rawAES256:
            guard value.count == AES256GCM.keyByteCount else {
                throw EncryptedFileCredentialsStoreError.invalidKeyFile
            }
            do {
                try saveRawKeyToKeychain(value)
                try? fileManager.removeItem(at: keyURL)
            } catch {
                // 迁移失败时保留旧文件，读取不受影响。
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
        } catch let error as EncryptedFileCredentialsStoreError {
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
                throw EncryptedFileCredentialsStoreError.keychainUnavailable("错误码 \(updateStatus)")
            }
        } else if status != errSecSuccess {
            throw EncryptedFileCredentialsStoreError.keychainUnavailable("错误码 \(status)")
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
            throw EncryptedFileCredentialsStoreError.keychainUnavailable("错误码 \(status)")
        }
        guard data.count == AES256GCM.keyByteCount else {
            throw EncryptedFileCredentialsStoreError.invalidKeyFile
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
        } catch let error as EncryptedFileCredentialsStoreError {
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
        EncryptedFileCredentialsStoreError.fileSystem(error.localizedDescription)
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
