import Foundation
import Security
import Testing
@testable import WooTodoSync

@Suite("WebDAV 本机加密配置", .serialized)
struct EncryptedFileWebDavCredentialsStoreTests {
    @Test("账号与身份分开加密保存且文件仅当前用户可读")
    func accountAndIdentityAreSeparatelyEncrypted() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let credentials = fixtureCredentials()

        try store.saveAccount(credentials.account)
        try store.saveIdentity(credentials.identity)

        #expect(try store.loadAccount() == credentials.account)
        #expect(try store.loadIdentity() == credentials.identity)

        let accountURL = directory.appendingPathComponent("webdav-account.enc")
        let identityURL = directory.appendingPathComponent("webdav-identity.enc")
        let accountText = try String(contentsOf: accountURL, encoding: .utf8)
        let identityText = try String(contentsOf: identityURL, encoding: .utf8)
        #expect(!accountText.contains(credentials.username))
        #expect(!accountText.contains(credentials.appPassword))
        #expect(!accountText.contains(credentials.endpoint.absoluteString))
        #expect(!identityText.contains(credentials.vaultId))
        #expect(!identityText.contains(Base64URL.encode(credentials.vaultKey)))
        #expect(try permissions(of: directory) == 0o700)
        #expect(try permissions(of: accountURL) == 0o600)
        #expect(try permissions(of: identityURL) == 0o600)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("webdav-credentials.enc").path
        ))
    }

    @Test("旧 webdav-credentials.enc 会迁移为账号加身份并删除旧文件")
    func migratesLegacyCombinedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let credentials = fixtureCredentials()

        try store.saveLegacyCredentialsForTesting(credentials)
        let legacyURL = directory.appendingPathComponent("webdav-credentials.enc")
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))

        #expect(try store.loadAccount() == credentials.account)
        #expect(try store.loadIdentity() == credentials.identity)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("webdav-account.enc").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("webdav-identity.enc").path
        ))
    }

    @Test("账号密文被篡改后拒绝回填，身份仍可单独读取")
    func tamperedAccountIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let credentials = fixtureCredentials()
        try store.saveAccount(credentials.account)
        try store.saveIdentity(credentials.identity)

        let accountURL = directory.appendingPathComponent("webdav-account.enc")
        let source = try Data(contentsOf: accountURL)
        var object = try #require(
            JSONSerialization.jsonObject(with: source) as? [String: Any]
        )
        let ciphertext = try #require(object["ciphertext"] as? String)
        let replacement = ciphertext.first == "A" ? "B" : "A"
        object["ciphertext"] = replacement + String(ciphertext.dropFirst())
        try JSONSerialization.data(withJSONObject: object).write(
            to: accountURL,
            options: .atomic
        )

        #expect(throws: EncryptedFileCredentialsStoreError.invalidCredentialsFile) {
            _ = try store.loadAccount()
        }
        #expect(try store.loadIdentity() == credentials.identity)
    }

    @Test("删除身份保留账号")
    func deleteIdentityKeepsAccount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(directory: directory)
        let credentials = fixtureCredentials()
        try store.saveAccount(credentials.account)
        try store.saveIdentity(credentials.identity)

        try store.deleteIdentity()

        #expect(try store.loadIdentity() == nil)
        #expect(try store.loadAccount() == credentials.account)
    }

    @Test("旧 Keychain 凭据迁移一次后删除并写迁移标记")
    func migratesLegacyKeychainOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacy = InMemoryLegacyWebDavCredentialStore(credentials: credentials)
        let store = makeStore(directory: directory, legacy: legacy)

        #expect(try store.loadAccount() == credentials.account)
        #expect(try store.loadIdentity() == credentials.identity)
        #expect(!legacy.hasCredentials)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".webdav-keychain-migrated").path
        ))

        // 再次读取不会重新导入。
        try store.deleteIdentity()
        #expect(try store.loadIdentity() == nil)
        #expect(!legacy.hasCredentials)
    }

    @Test("旧 webdav-credentials.enc 迁移成功后也删除 Keychain 凭据")
    func fileMigrationDeletesLegacyKeychainCredentials() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacy = InMemoryLegacyWebDavCredentialStore(credentials: credentials)
        let store = makeStore(directory: directory, legacy: legacy)
        try store.saveLegacyCredentialsForTesting(credentials)

        #expect(try store.loadAccount() == credentials.account)
        #expect(try store.loadIdentity() == credentials.identity)
        #expect(!legacy.hasCredentials)
    }

    @Test("清除本机数据后旧 Keychain 凭据不会回填")
    func deletedCredentialsAreNotRestoredFromKeychain() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacy = InMemoryLegacyWebDavCredentialStore(credentials: credentials)
        let store = makeStore(directory: directory, legacy: legacy)
        #expect(try store.loadAccount() == credentials.account)
        #expect(!legacy.hasCredentials)

        // 模拟“清除本机数据”：先删目录，再调用删除接口写回迁移标记。
        try FileManager.default.removeItem(at: directory)
        try store.deleteIdentity()
        try store.deleteAccount()

        let reopened = makeStore(directory: directory, legacy: legacy)
        #expect(try reopened.loadAccount() == nil)
        #expect(try reopened.loadIdentity() == nil)
        #expect(!legacy.hasCredentials)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(".webdav-keychain-migrated").path
        ))
    }

    @Test("直接删除身份与账号也会清理旧 Keychain 凭据")
    func directDeletionClearsLegacyKeychainCredentials() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = fixtureCredentials()
        let legacy = InMemoryLegacyWebDavCredentialStore(credentials: credentials)
        let store = makeStore(directory: directory, legacy: legacy)

        try store.deleteIdentity()
        try store.deleteAccount()

        #expect(!legacy.hasCredentials)
        #expect(try store.loadAccount() == nil)
        #expect(try store.loadIdentity() == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "woo-todo-webdav-credentials-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeStore(
        directory: URL,
        legacy: any WebDavLegacyCredentialStoring = EmptyWebDavLegacyCredentialStore()
    ) -> EncryptedFileWebDavCredentialsStore {
        EncryptedFileWebDavCredentialsStore(
            directoryURL: directory,
            fileManager: .default,
            preferSecureEnclave: false,
            keychainService: "dev.woo-todo.webdav.tests.\(UUID().uuidString)",
            keychainAccount: "webdav-credentials-key",
            legacyCredentialStore: legacy
        )
    }

    private func fixtureCredentials() -> WebDavCredentials {
        WebDavCredentials(
            endpoint: URL(string: "https://dav.example.test/woo-todo/")!,
            username: "user@example.com",
            appPassword: "application-password",
            vaultId: "vault-test",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 7, count: 32)
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }
}

private final class InMemoryLegacyWebDavCredentialStore:
    WebDavLegacyCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: WebDavCredentials?

    init(credentials: WebDavCredentials?) {
        self.credentials = credentials
    }

    var hasCredentials: Bool {
        lock.withLock { credentials != nil }
    }

    func loadLegacyCredentials() throws -> WebDavCredentials? {
        lock.withLock { credentials }
    }

    func deleteLegacyCredentials() throws {
        lock.withLock { credentials = nil }
    }
}
