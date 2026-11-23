import Foundation
import Testing
import WooTodoCore
import WooTodoStorage
import WooTodoSync
@testable import WooTodoMacApp

@Suite("跨设备设置", .serialized)
@MainActor
struct SyncSettingsStoreTests {
    @Test("退出同步空间会撤销当前设备、清除凭据并保留本地任务")
    func exitSpaceRevokesCurrentDevice() async throws {
        let suite = "woo-todo-sync-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = TestSyncCredentialsStore()
        let credentials = SyncCredentials(
            endpoint: try #require(URL(string: "https://sync.example.test")),
            vaultId: "vault-test",
            deviceId: "device-mac",
            deviceToken: Base64URL.encode(Data(repeating: 1, count: 32)),
            vaultKey: Data(repeating: 7, count: 32)
        )
        try credentialsStore.save(credentials)
        try repository.configureSync(SQLiteSyncConfiguration(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId,
            vaultKey: credentials.vaultKey
        ))
        try repository.save(TodoTask(
            title: "保留任务",
            categoryID: TaskCategory.inboxID
        ))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExitSpaceURLProtocol.self]
        ExitSpaceURLProtocol.handler = { request in
            guard request.url?.path == "/v1/devices/current/revoke",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer \(credentials.deviceToken)" else {
                throw TestURLProtocolError.requestMismatch
            }
            return ExitSpaceURLProtocol.response(
                for: request,
                status: 200,
                json: """
                {
                  "ok": true,
                  "data": {"deviceId": "device-mac", "revokedAt": 1000},
                  "requestId": "req-revoke"
                }
                """
            )
        }
        defer { ExitSpaceURLProtocol.handler = nil }
        let client = try SyncAPIClient(
            endpoint: credentials.endpoint,
            session: URLSession(configuration: configuration)
        )
        let store = try SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            credentials: credentials,
            defaultSyncEndpoint: nil,
            apiClientFactory: { _ in client },
            defaults: defaults
        )
        #expect(store.connection != nil)

        await store.exitSpace()

        #expect(store.connection == nil)
        #expect(store.isExitingSpace == false)
        #expect(store.statusMessage != nil)
        #expect(try credentialsStore.load() == nil)
        #expect(try repository.fetchAll().map(\.title) == ["保留任务"])
        // 绑定已重置：可以绑定另一个空间而不触发身份冲突。
        try repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-new",
            deviceId: "device-new",
            vaultKey: Data(repeating: 2, count: 32)
        ))
    }

    @Test("构建期地址优先于持久化手填地址")
    func bundledEndpointWins() throws {
        let suite = "woo-todo-sync-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("https://manual.example.test", forKey: "sync.endpoint")
        let repository = try SQLiteTaskRepository(path: ":memory:")

        let store = try SyncSettingsStore(
            repository: repository,
            credentialsStore: TestSyncCredentialsStore(),
            credentials: nil,
            defaultSyncEndpoint: try #require(URL(string: "https://bundled.example.test")),
            defaults: defaults
        )
        #expect(store.hasBundledEndpoint)
        #expect(!store.endpointFieldIsEditable)
        #expect(store.endpointText == "https://bundled.example.test")
        #expect(store.canCreateVault)
    }

    @Test("无构建期地址时读取并校验首台手填地址")
    func manualEndpointPersists() throws {
        let suite = "woo-todo-sync-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")

        let store = try SyncSettingsStore(
            repository: repository,
            credentialsStore: TestSyncCredentialsStore(),
            credentials: nil,
            defaultSyncEndpoint: nil,
            defaults: defaults
        )
        #expect(store.endpointFieldIsEditable)
        #expect(!store.canCreateVault)

        store.endpointText = "http://192.168.1.2:48473"
        #expect(!store.saveManualEndpoint())
        #expect(defaults.string(forKey: "sync.endpoint") == nil)

        store.endpointText = "https://sync.example.test"
        #expect(store.saveManualEndpoint())
        #expect(defaults.string(forKey: "sync.endpoint") == "https://sync.example.test")
        #expect(store.canCreateVault)
    }

    @Test("legacy 提示只出现一次且不会删除旧凭据")
    func legacyNoticeIsShownOnce() throws {
        let suite = "woo-todo-sync-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = TestSyncCredentialsStore()

        let store = try SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            credentials: nil,
            defaultSyncEndpoint: nil,
            legacyDetection: SyncLegacyDetection(
                credentialsInvalidated: true,
                legacyStoragePresent: true
            ),
            defaults: defaults
        )
        #expect(store.legacyNotice == SyncLegacyNotice.text)
        store.acknowledgeLegacyNotice()
        #expect(store.legacyNotice == nil)

        let reopened = try SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            credentials: nil,
            defaultSyncEndpoint: nil,
            legacyDetection: SyncLegacyDetection(
                credentialsInvalidated: true,
                legacyStoragePresent: true
            ),
            defaults: defaults
        )
        #expect(reopened.legacyNotice == nil)
    }

    @Test("有效凭据与旧文件并存时仍激活且不提示 legacy")
    func validCredentialsSuppressLegacyNotice() throws {
        let suite = "woo-todo-sync-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentials = SyncCredentials(
            endpoint: try #require(URL(string: "https://sync.example.test")),
            vaultId: "vault-test",
            deviceId: "device-mac",
            deviceToken: Base64URL.encode(Data(repeating: 1, count: 32)),
            vaultKey: Data(repeating: 7, count: 32)
        )
        let store = try SyncSettingsStore(
            repository: repository,
            credentialsStore: TestSyncCredentialsStore(),
            credentials: credentials,
            defaultSyncEndpoint: nil,
            legacyDetection: SyncLegacyDetection(
                credentialsInvalidated: false,
                legacyStoragePresent: true
            ),
            hasStoredValidCredentials: true,
            defaults: defaults
        )
        #expect(store.connection != nil)
        #expect(store.legacyNotice == nil)
    }
}

private final class TestSyncCredentialsStore: SyncCredentialsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: SyncCredentials?

    func save(_ credentials: SyncCredentials) throws {
        try credentials.validate()
        lock.lock()
        defer { lock.unlock() }
        self.credentials = credentials
    }

    func load() throws -> SyncCredentials? {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        credentials = nil
    }
}

private enum TestURLProtocolError: Error, LocalizedError {
    case missingHandler
    case requestMismatch

    var errorDescription: String? {
        switch self {
        case .missingHandler: "URLProtocol 未配置处理器"
        case .requestMismatch: "请求与预期不一致"
        }
    }
}

private final class ExitSpaceHandlerStorage: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private let lock = NSLock()
    private var value: Handler?

    func set(_ handler: Handler?) {
        lock.lock()
        value = handler
        lock.unlock()
    }

    func get() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ExitSpaceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = ExitSpaceHandlerStorage()

    static var handler: ExitSpaceHandlerStorage.Handler? {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: TestURLProtocolError.missingHandler)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(
        for request: URLRequest,
        status: Int,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}
