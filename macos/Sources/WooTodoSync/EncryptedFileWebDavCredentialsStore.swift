import CryptoKit
import Foundation

public enum EncryptedFileCredentialsStoreError: Error, Equatable, LocalizedError {
    case invalidKeyFile
    case secureEnclaveKeyUnavailable
    case invalidCredentialsFile
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKeyFile:
            "本机 WebDAV 配置密钥文件无效"
        case .secureEnclaveKeyUnavailable:
            "本机 WebDAV 配置密钥无法由 Secure Enclave 解锁"
        case .invalidCredentialsFile:
            "本机加密的 WebDAV 配置无效或已损坏"
        case .fileSystem(let message):
            "无法访问本机 WebDAV 配置：\(message)"
        }
    }
}

/// 将 WebDAV 完整配置加密保存在应用数据目录，并仅在首次使用时迁移旧 Keychain 项。
public final class EncryptedFileWebDavCredentialsStore: WebDavCredentialsStoring,
    @unchecked Sendable {
    private let directoryURL: URL
    private let credentialsURL: URL
    private let keyURL: URL
    private let migrationMarkerURL: URL
    private let legacyStore: (any WebDavCredentialsStoring)?
    private let fileManager: FileManager
    private let preferSecureEnclave: Bool
    private let lock = NSLock()

    private static let credentialsFileName = "webdav-credentials.enc"
    private static let keyFileName = "webdav-local-key.json"
    private static let migrationMarkerFileName = ".webdav-keychain-migrated"
    private static let credentialsFormat = "woo-todo-webdav-credentials"
    private static let keyFormat = "woo-todo-local-credentials-key"
    private static let version = 1
    private static let cipher = "AES-256-GCM"
    private static let aad = Data("woo-todo-webdav-credentials-v1".utf8)
    private static let keyDerivationSalt = Data(
        "io.github.stophemo.woo-todo.local-credentials".utf8
    )

    public convenience init(
        directoryURL: URL,
        legacyStore: (any WebDavCredentialsStoring)? = WebDavCredentialsStore()
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
        legacyStore: (any WebDavCredentialsStoring)?,
        fileManager: FileManager,
        preferSecureEnclave: Bool
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
    }

    public func save(_ credentials: WebDavCredentials) throws {
        try credentials.validate()
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(credentials)
    }

    public func load() throws -> WebDavCredentials? {
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
    }

    private func saveUnlocked(_ credentials: WebDavCredentials) throws {
        try ensureDirectory()
        let key = try loadOrCreateEncryptionKey()
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(credentials)
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
        let envelope: EncryptedEnvelope
        do {
            envelope = try AES256GCM.seal(
                plaintext,
                key: key,
                authenticating: Self.aad
            )
        } catch {
            throw EncryptedFileCredentialsStoreError.invalidCredentialsFile
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
        } catch let error as EncryptedFileCredentialsStoreError {
            throw error
        } catch {
            throw Self.fileSystemError(error)
        }
    }

    private func loadEncryptedCredentials() throws -> WebDavCredentials {
        do {
            let file = try JSONDecoder().decode(
                CredentialsFile.self,
                from: Data(contentsOf: credentialsURL)
            )
            guard file.format == Self.credentialsFormat,
                  file.version == Self.version,
                  file.cipher == Self.cipher else {
                throw EncryptedFileCredentialsStoreError.invalidCredentialsFile
            }
            let key = try loadExistingEncryptionKey()
            let plaintext = try AES256GCM.open(
                EncryptedEnvelope(ciphertext: file.ciphertext, nonce: file.nonce),
                key: key,
                authenticating: Self.aad
            )
            let credentials = try JSONDecoder().decode(WebDavCredentials.self, from: plaintext)
            try credentials.validate()
            return credentials
        } catch let error as EncryptedFileCredentialsStoreError {
            throw error
        } catch {
            throw EncryptedFileCredentialsStoreError.invalidCredentialsFile
        }
    }

    private func loadOrCreateEncryptionKey() throws -> Data {
        if fileManager.fileExists(atPath: keyURL.path) {
            return try loadExistingEncryptionKey()
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
                // Secure Enclave 创建失败时仍允许使用仅当前用户可读的软件随机密钥。
            }
        }

        let key = try SecureRandom.bytes(count: AES256GCM.keyByteCount)
        try writeKeyFile(KeyFile(
            format: Self.keyFormat,
            version: Self.version,
            kind: .rawAES256,
            value: Base64URL.encode(key)
        ))
        return key
    }

    private func loadExistingEncryptionKey() throws -> Data {
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
