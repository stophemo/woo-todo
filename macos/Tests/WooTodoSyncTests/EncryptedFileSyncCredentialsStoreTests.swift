import Foundation
import CryptoKit
import Security
import Testing
@testable import WooTodoSync

@Suite("同步凭据本机加密存储", .serialized)
struct EncryptedFileSyncCredentialsStoreTests {
    @Test("同步凭据加密往返且文件仅当前用户可读")
    func encryptedRoundTripUsesProtectedFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        defer { try? store.delete() }
        let credentials = fixtureCredentials()

        try store.save(credentials)

        #expect(try store.load() == credentials)
        let credentialsURL = directory.appendingPathComponent("sync-credentials.enc")
        let keyURL = directory.appendingPathComponent("sync-local-key.json")
        let storedText = try String(contentsOf: credentialsURL, encoding: .utf8)
        #expect(!storedText.contains(credentials.endpoint.absoluteString))
        #expect(!storedText.contains(credentials.vaultId))
        #expect(!storedText.contains(credentials.deviceToken))
        #expect(!storedText.contains(Base64URL.encode(credentials.vaultKey)))
        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: credentialsURL) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: keyURL.path))
        #expect(keychainHasRawKey(service: store.keychainService, account: store.keychainAccount))
    }

    @Test("旧 Keychain 同步凭据只迁移一次")
    func legacyCredentialsAreMigratedOnlyOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacyStore = CountingSyncCredentialsStore(credentials: credentials)
        let service = "woo-todo-test-\(UUID().uuidString)"
        let firstStore = makeStore(
            directory: directory,
            legacyStore: legacyStore,
            keychainService: service
        )
        defer { try? firstStore.delete() }

        #expect(try firstStore.load() == credentials)
        #expect(legacyStore.loadCount == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("sync-credentials.enc").path
            )
        )

        let secondStore = makeStore(
            directory: directory,
            legacyStore: legacyStore,
            keychainService: service
        )
        #expect(try secondStore.load() == credentials)
        #expect(legacyStore.loadCount == 1)
    }

    @Test("删除同步凭据后不会重新导入旧 Keychain 项")
    func deletionKeepsMigrationTombstone() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacyStore = CountingSyncCredentialsStore(credentials: credentials)
        let store = makeStore(directory: directory, legacyStore: legacyStore)
        #expect(try store.load() == credentials)

        try store.delete()

        #expect(try store.load() == nil)
        #expect(legacyStore.loadCount == 1)
        #expect(legacyStore.deleteCount == 1)
    }

    @Test("密文被篡改后拒绝回填")
    func tamperedCiphertextIsRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        defer { try? store.delete() }
        try store.save(fixtureCredentials())

        let credentialsURL = directory.appendingPathComponent("sync-credentials.enc")
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

        #expect(throws: EncryptedFileSyncCredentialsStoreError.invalidCredentialsFile) {
            _ = try store.load()
        }
    }

    @Test("可用时使用 Secure Enclave 透明解锁同步凭据")
    func secureEnclaveRoundTrip() throws {
        guard SecureEnclave.isAvailable else { return }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EncryptedFileSyncCredentialsStore(
            directoryURL: directory,
            legacyStore: nil,
            fileManager: .default,
            preferSecureEnclave: true,
            keychainService: "woo-todo-test-\(UUID().uuidString)",
            keychainAccount: "sync-credentials-key"
        )
        defer { try? store.delete() }
        let credentials = fixtureCredentials()

        try store.save(credentials)

        #expect(try store.load() == credentials)
        let keyText = try String(
            contentsOf: directory.appendingPathComponent("sync-local-key.json"),
            encoding: .utf8
        )
        #expect(keyText.contains("secure-enclave-p256"))
    }

    private func makeStore(
        directory: URL,
        legacyStore: (any SyncCredentialsStoring)? = nil,
        keychainService: String = "woo-todo-test-\(UUID().uuidString)",
        keychainAccount: String = "sync-credentials-key"
    ) -> EncryptedFileSyncCredentialsStore {
        EncryptedFileSyncCredentialsStore(
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

    private func fixtureCredentials() -> SyncCredentials {
        SyncCredentials(
            endpoint: URL(string: "https://sync.example.com")!,
            vaultId: "saved-vault",
            deviceId: "saved-device-01",
            deviceToken: Base64URL.encode(Data(repeating: 3, count: 32)),
            vaultKey: Data(repeating: 7, count: AES256GCM.keyByteCount)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "woo-todo-sync-store-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private final class CountingSyncCredentialsStore: SyncCredentialsStoring,
    @unchecked Sendable {
    private var credentials: SyncCredentials?
    private(set) var loadCount = 0
    private(set) var deleteCount = 0

    init(credentials: SyncCredentials?) {
        self.credentials = credentials
    }

    func save(_ credentials: SyncCredentials) throws {
        self.credentials = credentials
    }

    func load() throws -> SyncCredentials? {
        loadCount += 1
        return credentials
    }

    func delete() throws {
        deleteCount += 1
        credentials = nil
    }
}
