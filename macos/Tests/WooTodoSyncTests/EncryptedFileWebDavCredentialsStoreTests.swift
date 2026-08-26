import Foundation
import CryptoKit
import Security
import Testing
@testable import WooTodoSync

@Suite("WebDAV 本机加密配置", .serialized)
struct EncryptedFileWebDavCredentialsStoreTests {
    @Test("完整配置加密往返且文件仅当前用户可读")
    func encryptedRoundTripUsesProtectedFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        defer { try? store.delete() }
        let credentials = fixtureCredentials()

        try store.save(credentials)

        #expect(try store.load() == credentials)
        let credentialsURL = directory.appendingPathComponent("webdav-credentials.enc")
        let keyURL = directory.appendingPathComponent("webdav-local-key.json")
        let storedText = try String(contentsOf: credentialsURL, encoding: .utf8)
        #expect(!storedText.contains(credentials.username))
        #expect(!storedText.contains(credentials.appPassword))
        #expect(!storedText.contains(credentials.endpoint.absoluteString))
        #expect(!storedText.contains(Base64URL.encode(credentials.vaultKey)))
        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: credentialsURL) == 0o600)
        // SE 不可用（preferSecureEnclave: false）时降级密钥存入 Keychain，不再写明文密钥文件。
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))
        #expect(keychainHasRawKey(service: store.keychainService, account: store.keychainAccount))
    }

    @Test("删除配置时同步清理 Keychain 中的降级密钥")
    func deleteRemovesRawKeyFromKeychain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        try store.save(fixtureCredentials())
        #expect(keychainHasRawKey(service: store.keychainService, account: store.keychainAccount))

        try store.delete()

        #expect(!keychainHasRawKey(service: store.keychainService, account: store.keychainAccount))
        #expect(try store.load() == nil)
    }

    @Test("密文被篡改后拒绝回填")
    func tamperedCiphertextIsRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        defer { try? store.delete() }
        try store.save(fixtureCredentials())

        let credentialsURL = directory.appendingPathComponent("webdav-credentials.enc")
        let source = try Data(contentsOf: credentialsURL)
        var object = try #require(
            JSONSerialization.jsonObject(with: source) as? [String: Any]
        )
        let ciphertext = try #require(object["ciphertext"] as? String)
        let replacement = ciphertext.first == "A" ? "B" : "A"
        object["ciphertext"] = replacement + ciphertext.dropFirst()
        try JSONSerialization.data(withJSONObject: object).write(
            to: credentialsURL,
            options: .atomic
        )

        #expect(throws: EncryptedFileCredentialsStoreError.invalidCredentialsFile) {
            _ = try store.load()
        }
    }

    @Test("可用时使用 Secure Enclave 透明解锁配置")
    func secureEnclaveRoundTrip() throws {
        guard SecureEnclave.isAvailable else { return }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedFileWebDavCredentialsStore(
            directoryURL: directory,
            legacyStore: nil,
            fileManager: .default,
            preferSecureEnclave: true,
            keychainService: "woo-todo-test-\(UUID().uuidString)",
            keychainAccount: "webdav-credentials-key"
        )
        let credentials = fixtureCredentials()

        try store.save(credentials)

        #expect(try store.load() == credentials)
        let keyText = try String(
            contentsOf: directory.appendingPathComponent("webdav-local-key.json"),
            encoding: .utf8
        )
        #expect(keyText.contains("secure-enclave-p256"))
    }

    @Test("旧明文 raw 密钥文件读取后迁移到 Keychain 并删除文件")
    func legacyRawKeyFileIsMigratedToKeychain() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = "woo-todo-test-\(UUID().uuidString)"
        let store = makeStore(directory: directory, keychainService: service)
        defer { try? store.delete() }
        let keyURL = directory.appendingPathComponent("webdav-local-key.json")
        let key = Data(repeating: 9, count: AES256GCM.keyByteCount)

        // 模拟旧版本遗留的明文 raw 密钥文件（密钥本身不变，只换存放位置）。
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let legacyKeyFile: [String: Any] = [
            "format": "woo-todo-local-credentials-key",
            "version": 1,
            "kind": "raw-aes-256",
            "value": Base64URL.encode(key),
        ]
        try JSONSerialization.data(withJSONObject: legacyKeyFile).write(
            to: keyURL,
            options: .atomic
        )

        // 保存/读取应透明使用迁移后的密钥：密文兼容、文件被删除、Keychain 有密钥。
        let credentials = fixtureCredentials()
        try store.save(credentials)
        #expect(try store.load() == credentials)
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))
        #expect(keychainHasRawKey(service: service, account: "webdav-credentials-key"))

        // 重启（新实例）后仍能读取：密钥已完全从 Keychain 恢复，无需旧文件。
        let restarted = makeStore(directory: directory, keychainService: service)
        #expect(try restarted.load() == credentials)
    }

    @Test("旧 Keychain 配置只迁移一次")
    func legacyCredentialsAreMigratedOnlyOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacyStore = CountingWebDavCredentialsStore(credentials: credentials)
        let service = "woo-todo-test-\(UUID().uuidString)"
        let firstStore = makeStore(
            directory: directory,
            legacyStore: legacyStore,
            keychainService: service
        )
        defer { try? firstStore.delete() }

        #expect(try firstStore.load() == credentials)
        #expect(legacyStore.loadCount == 1)

        let secondStore = makeStore(
            directory: directory,
            legacyStore: legacyStore,
            keychainService: service
        )
        #expect(try secondStore.load() == credentials)
        #expect(legacyStore.loadCount == 1)
    }

    @Test("删除本机配置后不会重新导入旧 Keychain 项")
    func deletionKeepsMigrationTombstone() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacyStore = CountingWebDavCredentialsStore(credentials: credentials)
        let store = makeStore(directory: directory, legacyStore: legacyStore)
        #expect(try store.load() == credentials)

        try store.delete()

        #expect(try store.load() == nil)
        #expect(legacyStore.loadCount == 1)
    }

    private func makeStore(
        directory: URL,
        legacyStore: (any WebDavCredentialsStoring)? = nil,
        keychainService: String = "woo-todo-test-\(UUID().uuidString)",
        keychainAccount: String = "webdav-credentials-key"
    ) -> EncryptedFileWebDavCredentialsStore {
        EncryptedFileWebDavCredentialsStore(
            directoryURL: directory,
            legacyStore: legacyStore,
            fileManager: .default,
            preferSecureEnclave: false,
            keychainService: keychainService,
            keychainAccount: keychainAccount
        )
    }

    private func keychainHasRawKey(service: String, account: String) -> Bool {
        let request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        return status == errSecSuccess
    }

    private func fixtureCredentials() -> WebDavCredentials {
        WebDavCredentials(
            endpoint: URL(string: "https://dav.example.com/woo-todo/")!,
            username: "saved@example.com",
            appPassword: "saved-app-password",
            vaultId: "saved-vault",
            deviceId: "saved-device-01",
            vaultKey: Data(repeating: 7, count: AES256GCM.keyByteCount)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "woo-todo-webdav-store-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private final class CountingWebDavCredentialsStore: WebDavCredentialsStoring,
    @unchecked Sendable {
    private var credentials: WebDavCredentials?
    private(set) var loadCount = 0

    init(credentials: WebDavCredentials?) {
        self.credentials = credentials
    }

    func save(_ credentials: WebDavCredentials) throws {
        self.credentials = credentials
    }

    func load() throws -> WebDavCredentials? {
        loadCount += 1
        return credentials
    }

    func delete() throws {
        credentials = nil
    }
}
