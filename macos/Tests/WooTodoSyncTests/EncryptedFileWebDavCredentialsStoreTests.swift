import Foundation
import CryptoKit
import Testing
@testable import WooTodoSync

@Suite("WebDAV 本机加密配置", .serialized)
struct EncryptedFileWebDavCredentialsStoreTests {
    @Test("完整配置加密往返且文件仅当前用户可读")
    func encryptedRoundTripUsesProtectedFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
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
        #expect(try permissions(of: keyURL) == 0o600)
    }

    @Test("密文被篡改后拒绝回填")
    func tamperedCiphertextIsRejected() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
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
            preferSecureEnclave: true
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

    @Test("旧 Keychain 配置只迁移一次")
    func legacyCredentialsAreMigratedOnlyOnce() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacyStore = CountingWebDavCredentialsStore(credentials: credentials)
        let firstStore = makeStore(directory: directory, legacyStore: legacyStore)

        #expect(try firstStore.load() == credentials)
        #expect(legacyStore.loadCount == 1)

        let secondStore = makeStore(directory: directory, legacyStore: legacyStore)
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
        legacyStore: (any WebDavCredentialsStoring)? = nil
    ) -> EncryptedFileWebDavCredentialsStore {
        EncryptedFileWebDavCredentialsStore(
            directoryURL: directory,
            legacyStore: legacyStore,
            fileManager: .default,
            preferSecureEnclave: false
        )
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
