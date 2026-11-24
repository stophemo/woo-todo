import Foundation
import Testing
import WooTodoCore
import WooTodoStorage
@testable import WooTodoSync
@testable import WooTodoMacApp

@Suite("跨设备 WebDAV 设置", .serialized)
@MainActor
struct SyncSettingsStoreTests {
    @Test("测试连接并保存只保存 WebDAV 账号，不创建身份")
    func savesAccountWithoutIdentity() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        await fixture.store.testAndSaveAccount()

        #expect(fixture.store.account != nil)
        #expect(fixture.store.connection == nil)
        #expect(try fixture.credentialsStore.loadAccount() != nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(fixture.store.actionErrorMessage == nil)
        #expect(fixture.store.statusMessage != nil)
    }

    @Test("建立同步空间会生成身份、绑定数据库并保留任务")
    func createVaultBindsIdentityAndKeepsTasks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-old",
            deviceId: "device-old",
            vaultKey: Data(repeating: 3, count: 32)
        ))
        let task = try TodoTask(title: "保留任务", categoryID: TaskCategory.inboxID)
        try fixture.repository.save(task)

        await fixture.store.createVault()

        let identity = try #require(try fixture.credentialsStore.loadIdentity())
        try identity.validate()
        #expect(fixture.store.connection?.vaultId == identity.vaultId)
        #expect(fixture.store.connection?.deviceId == identity.deviceId)
        #expect(fixture.store.account != nil)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["保留任务"])
        #expect(fixture.store.statusMessage?.contains("已建立") == true)
        fixture.store.stop()
    }

    @Test("退出同步空间只删本机身份，保留账号与任务")
    func exitSpaceKeepsAccountAndTasks() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let identity = try makeIdentity()
        try fixture.credentialsStore.saveIdentity(identity)
        let store = SyncSettingsStore(
            repository: fixture.repository,
            credentialsStore: fixture.credentialsStore,
            defaults: fixture.defaults,
            clientFactory: fixture.clientFactory
        )
        let task = try TodoTask(title: "退出后保留", categoryID: TaskCategory.inboxID)
        try fixture.repository.save(task)
        #expect(store.connection != nil)

        await store.exitSpace()

        #expect(store.connection == nil)
        #expect(store.account != nil)
        #expect(try fixture.credentialsStore.loadAccount() != nil)
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(try fixture.repository.fetchAll().map(\.title) == ["退出后保留"])
        // 绑定已重置：可以绑定另一个空间而不触发身份冲突。
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-new",
            deviceId: "device-new",
            vaultKey: Data(repeating: 2, count: 32)
        ))
        store.stop()
    }

    @Test("legacy 提示只出现一次且不会删除旧凭据")
    func legacyNoticeIsShownOnce() throws {
        let suite = "woo-todo-webdav-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = InMemoryWebDavCredentialsStore()

        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            defaults: defaults,
            legacyNotice: SyncLegacyNotice.webDavMigrationText
        )
        #expect(store.legacyNotice == SyncLegacyNotice.webDavMigrationText)
        store.acknowledgeLegacyNotice()
        #expect(store.legacyNotice == nil)

        let reopened = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            defaults: defaults,
            legacyNotice: SyncLegacyNotice.webDavMigrationText
        )
        #expect(reopened.legacyNotice == nil)
    }

    @Test("账号表单会拒绝非 HTTPS 地址")
    func rejectsInvalidEndpoint() async throws {
        let fixture = try makeFixture(withSavedAccount: false)
        defer { fixture.cleanup() }
        fixture.store.endpointText = "http://dav.example.test"
        fixture.store.username = "user"
        fixture.store.appPassword = "password"

        await fixture.store.testAndSaveAccount()

        #expect(fixture.store.account == nil)
        #expect(fixture.store.actionErrorMessage != nil)
        #expect(try fixture.credentialsStore.loadAccount() == nil)
    }

    @Test("读取远端最大 Lamport 作为加入已有空间的水位")
    func readsRemoteLamportFloor() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let account = try #require(try fixture.credentialsStore.loadAccount())
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let remote = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-android-01",
            operation: SyncPushOperation(
                opId: "ab-remote-op-01",
                entityId: "entity-remote-01",
                kind: .upsert,
                lamport: 77,
                ciphertext: Base64URL.encode(Data(repeating: 5, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 6, count: 12))
            )
        )
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "PROPFIND":
                let hrefs: [String]
                if path.hasSuffix("/ops") {
                    hrefs = ["v1/personal-vault/ops/ab"]
                } else if path.hasSuffix("/ops/ab") {
                    hrefs = ["v1/personal-vault/ops/ab/ab-remote-op-01.json"]
                } else {
                    hrefs = []
                }
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                return (
                    try makeWebDavTestResponse(request, status: 200),
                    try JSONEncoder().encode(remote)
                )
            default:
                return (try makeWebDavTestResponse(request, status: 201), Data())
            }
        }

        let floor = try await fixture.store.remoteLamportFloor(
            account: account,
            identity: identity
        )
        #expect(floor == 77)
    }

    @Test("启动加载已有身份时先取远端 Lamport 水位再绑定")
    func startupBindingUsesRemoteLamportFloor() async throws {
        let suite = "woo-todo-webdav-startup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try SQLiteTaskRepository(path: ":memory:")
        try repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-old",
            deviceId: "device-old",
            vaultKey: Data(repeating: 3, count: 32)
        ))
        try repository.save(TodoTask(
            title: "升级后保留",
            categoryID: TaskCategory.inboxID
        ))
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        let identity = WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
        let credentials = InMemoryWebDavCredentialsStore(
            account: account,
            identity: identity
        )
        let remote = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-android-01",
            operation: SyncPushOperation(
                opId: "ab-startup-op-01",
                entityId: "entity-startup-01",
                kind: .upsert,
                lamport: 77,
                ciphertext: Base64URL.encode(Data(repeating: 5, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 6, count: 12))
            )
        )
        WebDavTestURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch request.httpMethod {
            case "PROPFIND":
                let hrefs: [String]
                if path.hasSuffix("/ops") {
                    hrefs = ["v1/personal-vault/ops/ab"]
                } else if path.hasSuffix("/ops/ab") {
                    hrefs = ["v1/personal-vault/ops/ab/ab-startup-op-01.json"]
                } else {
                    hrefs = []
                }
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                return (
                    try makeWebDavTestResponse(request, status: 200),
                    try JSONEncoder().encode(remote)
                )
            case "PUT":
                // 保持 outbox 不确认，便于断言本地快照的 Lamport 水位。
                return (try makeWebDavTestResponse(request, status: 503), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 201), Data())
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentials,
            defaults: defaults,
            pollInterval: 0.02,
            clientFactory: { account, identity in
                try WebDavClient(
                    account: account,
                    identity: identity,
                    session: session,
                    retryDelaysNanoseconds: [],
                    retrySleep: { _ in }
                )
            }
        )
        defer {
            store.stop()
            WebDavTestURLProtocol.handler = nil
        }
        #expect(store.connection != nil)

        store.start()
        var operations: [SyncPushOperation] = []
        let waitUntil = Date().addingTimeInterval(3)
        while Date() < waitUntil {
            operations = try await repository.pendingOperations(limit: 50)
            if !operations.isEmpty, operations.allSatisfy({ $0.lamport > 77 }) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!operations.isEmpty)
        #expect(operations.allSatisfy { $0.lamport > 77 })
    }

    @Test("切回已有空间后本地快照从远端 Lamport 水位之后继续")
    func bindingUsesRemoteLamportFloor() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try fixture.repository.configureSync(SQLiteSyncConfiguration(
            vaultId: "vault-old",
            deviceId: "device-old",
            vaultKey: Data(repeating: 3, count: 32)
        ))
        try fixture.repository.save(TodoTask(
            title: "切回空间保留",
            categoryID: TaskCategory.inboxID
        ))
        let identity = WebDavIdentity(
            vaultId: "vault-return",
            deviceId: "device-return-01",
            vaultKey: Data(repeating: 4, count: 32)
        )

        try fixture.store.applyBinding(identity, remoteLamportFloor: 77)

        let operations = try await fixture.repository.pendingOperations(limit: 50)
        #expect(!operations.isEmpty)
        #expect(operations.allSatisfy { $0.lamport > 77 })
    }

    @Test("Path A：对方批准后仍需本机确认才保存身份")
    func pathAClaimRequiresLocalConfirmation() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let pairingId = "pairing-store-confirm-01"
        let code = "445566"
        let offerKey = try PairingKeyPair.generate()
        let pairingSecret = try SecureRandom.bytes(count: 32)
        let now = Date()
        let vaultId = "vault-remote-confirm"
        let vaultKey = Data(repeating: 8, count: 32)
        let offer = WebDavPairingOffer(
            pairingId: pairingId,
            createdAt: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
            expiresAt: Int64((now.addingTimeInterval(300).timeIntervalSince1970 * 1_000).rounded()),
            code: code,
            publicKey: offerKey.publicKeyBase64URL,
            pairingSecret: Base64URL.encode(pairingSecret),
            vaultId: vaultId,
            deviceName: "Mac A",
            platform: .macos
        )
        let server = PairingFlowServer()
        server.put(
            name: WebDavPairingFileName(
                kind: .offer,
                code: code,
                pairingId: pairingId
            ).string,
            data: try WebDavPairingFileCodec.encode(.offer(offer))
        )
        WebDavTestURLProtocol.handler = { request in
            try server.handle(request)
        }

        fixture.store.claimByShortCode(code)
        let waitUntil = Date().addingTimeInterval(3)
        while Date() < waitUntil, server.claimData == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let claimData = try #require(server.claimData)
        guard case let .claim(claim) = try WebDavPairingFileCodec.decode(claimData) else {
            Issue.record("应写入 claim")
            return
        }
        let sessionKey = try offerKey.sessionKey(
            peerPublicKey: Base64URL.decode(claim.publicKey),
            pairingId: pairingId,
            pairingSecret: pairingSecret
        )
        let approvedAt = Date()
        let approval = WebDavPairingApproval(
            pairingId: pairingId,
            createdAt: Int64((approvedAt.timeIntervalSince1970 * 1_000).rounded()),
            expiresAt: Int64((approvedAt.addingTimeInterval(300).timeIntervalSince1970 * 1_000).rounded()),
            deviceId: claim.deviceId,
            vaultId: vaultId,
            vaultKeyEnvelope: WebDavPairingEnvelope(
                try PairingSessionCrypto.sealVaultKey(
                    vaultKey,
                    sessionKey: sessionKey,
                    pairingId: pairingId,
                    claimedDeviceId: claim.deviceId
                )
            ),
            initiatorPublicKey: offer.publicKey
        )
        server.put(
            name: WebDavPairingFileName(
                kind: .approval,
                code: nil,
                pairingId: pairingId
            ).string,
            data: try WebDavPairingFileCodec.encode(.approval(approval))
        )

        while Date() < waitUntil {
            if case .awaitingConfirmation = fixture.store.pathAClaimPhase {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case let .awaitingConfirmation(deviceName, platform, verificationCode, shownVaultId, _) =
            fixture.store.pathAClaimPhase else {
            Issue.record("应先进入本机确认状态")
            return
        }
        #expect(deviceName == "Mac A")
        #expect(platform == .macos)
        let expectedCode = try PairingSessionCrypto.verificationCode(
            sessionKey: sessionKey,
            initiatorPublicKey: offerKey.publicKey,
            claimPublicKey: Base64URL.decode(claim.publicKey)
        )
        #expect(verificationCode == expectedCode)
        #expect(shownVaultId == vaultId)
        // 尚未点击“核对一致，完成加入”前不得保存身份。
        #expect(try fixture.credentialsStore.loadIdentity() == nil)
        #expect(fixture.store.connection == nil)

        await fixture.store.confirmShortCodeClaim()

        let saved = try #require(try fixture.credentialsStore.loadIdentity())
        #expect(saved.vaultId == vaultId)
        #expect(saved.deviceId == claim.deviceId)
        #expect(saved.vaultKey == vaultKey)
        #expect(fixture.store.connection != nil)
        #expect(fixture.store.pathAClaimPhase == .confirmed)
    }

    @Test("Path A 认领轮询遇到 5xx 时在配对码有效期内继续重试")
    func claimPollingRetriesTransientServerErrors() async throws {
        let fixture = try makeFixture(pollInterval: 0.02)
        defer { fixture.cleanup() }
        let now = Date()
        let pairingId = "pairing-retry-claim-01"
        let code = "112233"
        let offerName = WebDavPairingFileName(
            kind: .offer,
            code: code,
            pairingId: pairingId
        ).string
        let offerKey = try PairingKeyPair.generate()
        let offer = WebDavPairingOffer(
            pairingId: pairingId,
            createdAt: Int64((now.timeIntervalSince1970 * 1_000).rounded()),
            expiresAt: Int64((now.addingTimeInterval(300).timeIntervalSince1970 * 1_000).rounded()),
            code: code,
            publicKey: offerKey.publicKeyBase64URL,
            pairingSecret: Base64URL.encode(try SecureRandom.bytes(count: 32)),
            vaultId: "vault-remote",
            deviceName: "Mac A",
            platform: .macos
        )
        let offerData = try WebDavPairingFileCodec.encode(.offer(offer))
        let counter = PairingListCounter()
        WebDavTestURLProtocol.handler = { request in
            switch request.httpMethod {
            case "MKCOL":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "PROPFIND":
                if counter.next() == 3 {
                    // 第一次轮询模拟 429/5xx：客户端不内部重试，交给配对轮询继续。
                    return (try makeWebDavTestResponse(request, status: 503), Data())
                }
                let hrefs = ["v1/pairing/\(offerName)"]
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                return (try makeWebDavTestResponse(request, status: 200), offerData)
            case "PUT":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 200), Data())
            }
        }

        fixture.store.claimByShortCode(code)
        let waitUntil = Date().addingTimeInterval(3)
        while Date() < waitUntil, counter.value < 5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(counter.value >= 5)
        switch fixture.store.pathAClaimPhase {
        case .failed(let message):
            Issue.record("临时服务错误不应终止配对：\(message)")
        case .awaitingApproval:
            break
        default:
            Issue.record("配对应继续等待对方批准")
        }
        fixture.store.cancelShortCodeClaim()
    }

    private func makeFixture(
        withSavedAccount: Bool = true,
        pollInterval: TimeInterval = WebDavPairingProtocol.pollIntervalSeconds
    ) throws -> Fixture {
        let suite = "woo-todo-webdav-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let repository = try SQLiteTaskRepository(path: ":memory:")
        let credentialsStore = InMemoryWebDavCredentialsStore()
        let account = WebDavAccount(
            endpoint: try #require(URL(string: "https://dav.example.test/woo-todo/")),
            username: "user@example.com",
            appPassword: "application-password"
        )
        if withSavedAccount {
            try credentialsStore.saveAccount(account)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let clientFactory: SyncSettingsStore.ClientFactory = { account, identity in
            try WebDavClient(
                account: account,
                identity: identity,
                session: session,
                retryDelaysNanoseconds: [],
                retrySleep: { _ in }
            )
        }
        WebDavTestURLProtocol.handler = { request in
            switch request.httpMethod {
            case "PROPFIND":
                let body = """
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:"></D:multistatus>
                """
                return (try makeWebDavTestResponse(request, status: 207), Data(body.utf8))
            case "MKCOL":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "PUT":
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 200), Data())
            }
        }
        let store = SyncSettingsStore(
            repository: repository,
            credentialsStore: credentialsStore,
            defaults: defaults,
            pollInterval: pollInterval,
            clientFactory: clientFactory
        )
        return Fixture(
            suite: suite,
            defaults: defaults,
            repository: repository,
            credentialsStore: credentialsStore,
            store: store,
            clientFactory: clientFactory
        )
    }

    private func makeIdentity() throws -> WebDavIdentity {
        WebDavIdentity(
            vaultId: "vault-test",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 7, count: 32)
        )
    }

    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let repository: SQLiteTaskRepository
        let credentialsStore: InMemoryWebDavCredentialsStore
        let store: SyncSettingsStore
        let clientFactory: SyncSettingsStore.ClientFactory

        @MainActor
        func cleanup() {
            store.stop()
            WebDavTestURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private func webDavMultistatus(_ hrefs: [String]) -> String {
    var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        + "<D:multistatus xmlns:D=\"DAV:\">"
    for href in hrefs {
        body += "<D:response><D:href>\(href)</D:href></D:response>"
    }
    body += "</D:multistatus>"
    return body
}

private final class PairingListCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class PairingFlowServer: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private var storedClaim: Data?

    var claimData: Data? {
        lock.withLock { storedClaim }
    }

    func put(name: String, data: Data) {
        lock.withLock {
            objects[name] = data
            if name.hasPrefix("claim-") {
                storedClaim = data
            }
        }
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        let method = request.httpMethod ?? "GET"
        let path = url.path
        if method == "MKCOL" {
            return (try makeWebDavTestResponse(request, status: 201), Data())
        }
        if path.contains("/v1/pairing") {
            let name = String(path.split(separator: "/").last ?? "")
            switch method {
            case "PROPFIND":
                let hrefs = lock.withLock {
                    objects.keys.sorted().map { "v1/pairing/\($0)" }
                }
                return (
                    try makeWebDavTestResponse(request, status: 207),
                    Data(webDavMultistatus(hrefs).utf8)
                )
            case "GET":
                guard let data = lock.withLock({ objects[name] }) else {
                    return (try makeWebDavTestResponse(request, status: 404), Data())
                }
                return (try makeWebDavTestResponse(request, status: 200), data)
            case "PUT":
                let body = requestBody(request)
                let existing = lock.withLock { objects[name] }
                if let existing, existing != body {
                    return (try makeWebDavTestResponse(request, status: 412), Data())
                }
                put(name: name, data: body)
                return (try makeWebDavTestResponse(request, status: 201), Data())
            case "DELETE":
                lock.withLock { objects[name] = nil }
                return (try makeWebDavTestResponse(request, status: 204), Data())
            default:
                return (try makeWebDavTestResponse(request, status: 405), Data())
            }
        }
        if method == "PROPFIND" {
            return (
                try makeWebDavTestResponse(request, status: 207),
                Data(webDavMultistatus([]).utf8)
            )
        }
        return (try makeWebDavTestResponse(request, status: 405), Data())
    }
}

private func requestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

private func makeWebDavTestResponse(
    _ request: URLRequest,
    status: Int
) throws -> HTTPURLResponse {
    guard let url = request.url else {
        throw URLError(.badURL)
    }
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: nil
    ) else {
        throw URLError(.badServerResponse)
    }
    return response
}

private final class WebDavTestHandlerStorage: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private let lock = NSLock()
    private var value: Handler?

    func set(_ handler: Handler?) {
        lock.withLock { value = handler }
    }

    func get() -> Handler? {
        lock.withLock { value }
    }
}

private final class WebDavTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = WebDavTestHandlerStorage()

    static var handler: WebDavTestHandlerStorage.Handler? {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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
}
