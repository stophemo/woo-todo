import Foundation
import Testing
@testable import WooTodoMacApp
import WooTodoStorage
import WooTodoSync

@Suite("同步方式切换", .serialized)
struct SyncBackendSelectionTests {
    @Test("显式选择决定同时保存两套凭据时启用哪一套")
    func explicitSelectionWins() throws {
        let defaults = try testDefaults()
        SyncBackendSelection.webDav.persist(in: defaults)

        #expect(SyncBackendSelection.resolve(
            defaults: defaults,
            hasWorkerOrLocalCredentials: true,
            hasWebDavCredentials: true
        ) == .webDav)
    }

    @Test("旧版本未保存选择时保持原有 Worker 优先行为")
    func legacySelectionPrefersWorker() throws {
        let defaults = try testDefaults()

        #expect(SyncBackendSelection.resolve(
            defaults: defaults,
            hasWorkerOrLocalCredentials: true,
            hasWebDavCredentials: true
        ) == .workerOrLocal)
    }

    @MainActor
    @Test("WebDAV 未启用时仍从安全存储回填配置")
    func inactiveWebDavConfigurationIsRestored() throws {
        let credentials = WebDavCredentials(
            endpoint: URL(string: "https://dav.example.com/woo-todo/")!,
            username: "saved@example.com",
            appPassword: "saved-app-password",
            vaultId: "saved-vault",
            deviceId: "saved-device-01",
            vaultKey: Data(repeating: 7, count: AES256GCM.keyByteCount)
        )
        let webDavStore = TestWebDavCredentialsStore()
        try webDavStore.save(credentials)
        let store = WebDavSettingsStore(
            repository: try SQLiteTaskRepository(path: ":memory:"),
            credentialsStore: webDavStore,
            workerCredentialsStore: TestSyncCredentialsStore(),
            workerSyncConfigured: true,
            defaults: try testDefaults()
        )

        #expect(store.connection == nil)
        #expect(store.endpointText == credentials.endpoint.absoluteString)
        #expect(store.username == credentials.username)
        #expect(store.appPassword == credentials.appPassword)
        #expect(store.vaultId == credentials.vaultId)
        #expect(store.vaultKeyText == Base64URL.encode(credentials.vaultKey))
    }

    @MainActor
    @Test("切换到 WebDAV 时只停用原同步身份而不删除凭据")
    func deactivatingWorkerPreservesCredentials() throws {
        let credentials = SyncCredentials(
            endpoint: try #require(URL(string: "http://192.168.8.21:48473")),
            vaultId: "saved-local-vault",
            deviceId: "saved-macos-device",
            deviceToken: Base64URL.encode(Data(repeating: 3, count: 32)),
            vaultKey: Data(repeating: 4, count: AES256GCM.keyByteCount)
        )
        let credentialsStore = TestSyncCredentialsStore()
        try credentialsStore.save(credentials)
        let store = try SyncSettingsStore(
            repository: SQLiteTaskRepository(
                path: ":memory:",
                syncConfiguration: SQLiteSyncConfiguration(
                    vaultId: credentials.vaultId,
                    deviceId: credentials.deviceId,
                    vaultKey: credentials.vaultKey
                )
            ),
            credentialsStore: credentialsStore,
            webDavCredentialsStore: TestWebDavCredentialsStore(),
            credentials: credentials,
            defaults: try testDefaults()
        )

        store.finishReplacement()

        #expect(try credentialsStore.load() == credentials)
        #expect(store.connection == nil)
    }

    private func testDefaults() throws -> UserDefaults {
        let name = "SyncBackendSelectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private final class TestWebDavCredentialsStore: WebDavCredentialsStoring, @unchecked Sendable {
    private var credentials: WebDavCredentials?

    func save(_ credentials: WebDavCredentials) throws {
        self.credentials = credentials
    }

    func load() throws -> WebDavCredentials? { credentials }

    func delete() throws { credentials = nil }
}

private final class TestSyncCredentialsStore: SyncCredentialsStoring, @unchecked Sendable {
    private var credentials: SyncCredentials?

    func save(_ credentials: SyncCredentials) throws {
        self.credentials = credentials
    }

    func load() throws -> SyncCredentials? { credentials }

    func delete() throws { credentials = nil }
}
