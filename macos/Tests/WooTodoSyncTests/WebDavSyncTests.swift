import Foundation
import Testing
@testable import WooTodoSync

@Suite("WebDAV 同步内核", .serialized)
struct WebDavSyncTests {
    private func account(
        endpoint: URL = URL(string: "https://dav.example.test/remote.php/dav/files/person/woo-todo/")!
    ) -> WebDavAccount {
        WebDavAccount(
            endpoint: endpoint,
            username: "user@example.com",
            appPassword: "application-password"
        )
    }

    private func identity() -> WebDavIdentity {
        WebDavIdentity(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            vaultKey: Data(repeating: 1, count: 32)
        )
    }

    @Test("共享 WebDAV 对象可严格解码并往返")
    func sharedFixtureRoundTrip() throws {
        let data = try Data(contentsOf: fixtureURL())
        let operation = try JSONDecoder().decode(WebDavOperation.self, from: data)
        #expect(operation.vaultId == "personal-vault")
        #expect(operation.deviceId == "device-mac-01")
        #expect(operation.lamport == 12)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(operation)
        #expect(try JSONDecoder().decode(WebDavOperation.self, from: encoded) == operation)
    }

    @Test("WebDAV 对象拒绝未知字段、非法 nonce 与路径分隔符")
    func rejectsInvalidObject() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL())) as? [String: Any]
        )
        object["unexpected"] = true
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                WebDavOperation.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
        object.removeValue(forKey: "unexpected")
        object["nonce"] = "AA"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                WebDavOperation.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
        object["nonce"] = "AAECAwQFBgcICQoL"
        object["opId"] = "..unsafe-operation"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                WebDavOperation.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("WebDAV 分片接受标识符允许的冒号且拒绝路径分隔符")
    func shardValidationMatchesOperationIdentifiers() {
        #expect(WebDavOperation.isValidShard("a:"))
        #expect(WebDavOperation.path(vaultId: "personal-vault", opId: "a:bcdefgh")[3] == "a:")
        #expect(!WebDavOperation.isValidShard("a/"))
    }

    @Test("WebDAV 端点策略接受 HTTPS 子路径并拒绝凭据外送")
    func endpointPolicy() throws {
        #expect(WebDavEndpointPolicy.isAllowed(account().endpoint))
        #expect(WebDavEndpointPolicy.isAllowed(
            try #require(URL(string: "https://another.example.net/storage/woo-todo"))
        ))
        #expect(!WebDavEndpointPolicy.isAllowed(
            try #require(URL(string: "http://dav.example.com/dav/"))
        ))
        #expect(!WebDavEndpointPolicy.isAllowed(
            try #require(URL(string: "https://user@dav.example.com/dav/"))
        ))
        #expect(!WebDavEndpointPolicy.isAllowed(
            try #require(URL(string: "https://dav.example.com/dav/?token=secret"))
        ))
        #expect(throws: WebDavError.invalidCredentials) {
            try WebDavIdentity(
                vaultId: "..",
                deviceId: "device-macos-01",
                vaultKey: Data(repeating: 0, count: AES256GCM.keyByteCount)
            ).validate()
        }
    }

    @Test("WebDAV 账号限制用户名与应用密码长度")
    func accountLengthLimits() throws {
        try WebDavAccount(
            endpoint: account().endpoint,
            username: String(repeating: "u", count: 320),
            appPassword: String(repeating: "p", count: 256)
        ).validate()
        #expect(throws: WebDavError.invalidCredentials) {
            try WebDavAccount(
                endpoint: account().endpoint,
                username: String(repeating: "u", count: 321),
                appPassword: "password"
            ).validate()
        }
        #expect(throws: WebDavError.invalidCredentials) {
            try WebDavAccount(
                endpoint: account().endpoint,
                username: "user@example.com",
                appPassword: String(repeating: "p", count: 257)
            ).validate()
        }
    }

    @Test("PROPFIND 支持 DAV 命名空间、绝对路径与百分号编码")
    func propfindHrefParsing() throws {
        let endpoint = account().endpoint
        let source = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>https://dav.example.test/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/ab/op%20one.json?ignored=1</D:href>
          </D:response>
          <D:response>
            <D:href>/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/cd/%E4%BB%BB%E5%8A%A1.json/</D:href>
          </D:response>
          <D:response><D:href>v1/personal-vault/ops/ef/relative.json</D:href></D:response>
          <D:response><D:href>/remote.php/dav/files/person/other/path</D:href></D:response>
        </D:multistatus>
        """

        #expect(try WebDavHrefParser.parse(Data(source.utf8), baseURL: endpoint) == [
            ["v1", "personal-vault", "ops", "ab", "op one.json"],
            ["v1", "personal-vault", "ops", "cd", "任务.json"],
            ["v1", "personal-vault", "ops", "ef", "relative.json"],
        ])
    }

    @Test("PROPFIND 拒绝格式错误的 href")
    func rejectsMalformedPropfindHref() {
        let endpoint = account().endpoint
        for href in [
            "/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/ab/operation%ZZ.json",
            "/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/%2e%2e/operation.json",
            "/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/ab/operation%2fescape.json",
            "/remote.php/dav/files/person/woo-todo/v1/personal-vault/ops/ab/operation%5cescape.json",
        ] {
            let source = """
            <D:multistatus xmlns="DAV:">
              <D:response><D:href>\(href)</D:href></D:response>
            </D:multistatus>
            """

            #expect(throws: WebDavError.self) {
                try WebDavHrefParser.parse(Data(source.utf8), baseURL: endpoint)
            }
        }
    }

    @Test("WebDAV 批次数不在五百条后截断")
    func pageCountCoversAllOperations() {
        #expect(WebDavSyncRunner.webDavPageCount(0) == 1)
        #expect(WebDavSyncRunner.webDavPageCount(500) == 1)
        #expect(WebDavSyncRunner.webDavPageCount(501) == 2)
        #expect(WebDavSyncRunner.webDavPageCount(1_001) == 3)
    }

    @Test("WebDAV 服务临时 503 会短退避重试后继续")
    func retriesTemporaryServiceFailures() async throws {
        let counter = WebDavRequestCounter()
        WebDavMockURLProtocol.handler = { request in
            let requestNumber = counter.next()
            let statusCode = requestNumber <= 3 ? 503 : 201
            return (try makeResponse(request, status: statusCode), Data())
        }
        defer { WebDavMockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavMockURLProtocol.self]
        let client = try WebDavClient(
            account: account(),
            identity: identity(),
            session: URLSession(configuration: configuration),
            retryDelaysNanoseconds: [0, 0, 0],
            retrySleep: { _ in }
        )

        try await client.ensureCollections()

        #expect(counter.value == 6)
    }

    @Test("WebDAV 网络错误与 429 会重试")
    func retriesNetworkAndRateLimitFailures() async throws {
        let counter = WebDavRequestCounter()
        WebDavMockURLProtocol.handler = { request in
            switch counter.next() {
            case 1:
                throw URLError(.timedOut)
            case 2:
                return (try makeResponse(request, status: 429), Data())
            default:
                return (try makeResponse(request, status: 201), Data())
            }
        }
        defer { WebDavMockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavMockURLProtocol.self]
        let client = try WebDavClient(
            account: account(),
            identity: identity(),
            session: URLSession(configuration: configuration),
            retryDelaysNanoseconds: [0, 0, 0, 0],
            retrySleep: { _ in }
        )

        try await client.ensureCollections()

        #expect(counter.value == 5)
    }

    @Test("WebDAV 拒绝 HTTP 重定向")
    func rejectsRedirects() async throws {
        let counter = WebDavRequestCounter()
        WebDavMockURLProtocol.handler = { request in
            _ = counter.next()
            return (try makeResponse(request, status: 302), Data())
        }
        defer { WebDavMockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavMockURLProtocol.self]
        let client = try WebDavClient(
            account: account(),
            identity: identity(),
            session: URLSession(configuration: configuration),
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )

        await #expect(throws: WebDavError.http(302)) {
            try await client.ensureCollections()
        }
        #expect(counter.value == 1)
    }

    @Test("WebDAV PUT 相同内容幂等，不同内容报告冲突")
    func putIsIdempotentAndDetectsConflict() async throws {
        let server = FakeWebDavServer()
        WebDavMockURLProtocol.handler = { request in
            try server.handle(request)
        }
        defer { WebDavMockURLProtocol.handler = nil }

        let client = try makeClient(server: server)
        let operation = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            operation: SyncPushOperation(
                opId: "op-00000001",
                entityId: "entity-00000001",
                kind: .upsert,
                lamport: 1,
                ciphertext: Base64URL.encode(Data(repeating: 1, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 2, count: 12))
            )
        )

        try await client.put(operation)
        try await client.put(operation)

        let conflicting = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-mac-01",
            operation: SyncPushOperation(
                opId: operation.opId,
                entityId: operation.entityId,
                kind: .upsert,
                lamport: 2,
                ciphertext: Base64URL.encode(Data(repeating: 3, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 4, count: 12))
            )
        )
        await #expect(throws: WebDavError.objectConflict(
            "v1/personal-vault/ops/op/op-00000001.json"
        )) {
            try await client.put(conflicting)
        }
    }

    @Test("WebDAV runner 推送、拉取、幂等且确认 outbox")
    func runnerPushesPullsAndIsIdempotent() async throws {
        let server = FakeWebDavServer()
        WebDavMockURLProtocol.handler = { request in
            try server.handle(request)
        }
        defer { WebDavMockURLProtocol.handler = nil }

        let remote = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-android-02",
            operation: SyncPushOperation(
                opId: "remote-00000001",
                entityId: "entity-remote-01",
                kind: .upsert,
                lamport: 5,
                ciphertext: Base64URL.encode(Data(repeating: 5, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 6, count: 12))
            )
        )
        try server.putObject(path: WebDavOperation.path(
            vaultId: "personal-vault",
            opId: remote.opId
        ), data: JSONEncoder().encode(remote))

        let local = FakeWebDavLocal()
        let outbox = FakeWebDavOutbox(
            operations: [SyncPushOperation(
                opId: "local-00000001",
                entityId: "entity-local-01",
                kind: .upsert,
                lamport: 6,
                ciphertext: Base64URL.encode(Data(repeating: 7, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 8, count: 12))
            )]
        )
        let client = try makeClient(server: server)
        let runner = WebDavSyncRunner(client: client, outbox: outbox, local: local)

        let first = try await runner.synchronize()
        #expect(first.pushed == 1)
        // 自己的 outbox 操作也会出现在远端目录中；本地应用按幂等处理。
        #expect(first.pulled == 2)
        #expect(await outbox.pending.isEmpty)
        #expect(await local.appliedIDs == ["local-00000001", remote.opId])

        let second = try await runner.synchronize()
        #expect(second.pushed == 0)
        #expect(second.pulled == 0)
        #expect(await local.appliedIDs == ["local-00000001", remote.opId])
    }

    @Test("WebDAV runner 跳过无法解码的对象并按 opId 记录")
    func runnerSkipsUndecodableOperations() async throws {
        let server = FakeWebDavServer()
        WebDavMockURLProtocol.handler = { request in
            try server.handle(request)
        }
        defer { WebDavMockURLProtocol.handler = nil }

        let good = try WebDavOperation(
            vaultId: "personal-vault",
            deviceId: "device-android-02",
            operation: SyncPushOperation(
                opId: "good-op-00001",
                entityId: "entity-good-01",
                kind: .upsert,
                lamport: 5,
                ciphertext: Base64URL.encode(Data(repeating: 5, count: 20)),
                nonce: Base64URL.encode(Data(repeating: 6, count: 12))
            )
        )
        try server.putObject(
            path: WebDavOperation.path(vaultId: "personal-vault", opId: good.opId),
            data: JSONEncoder().encode(good)
        )
        let brokenOpID = "broken-op-0001"
        try server.putObject(
            path: WebDavOperation.path(vaultId: "personal-vault", opId: brokenOpID),
            data: Data("{not-json".utf8)
        )

        let local = FakeWebDavLocal()
        let runner = WebDavSyncRunner(
            client: try makeClient(server: server),
            outbox: FakeWebDavOutbox(operations: []),
            local: local
        )

        let first = try await runner.synchronize()
        #expect(first.pulled == 1)
        #expect(await local.appliedIDs == [good.opId])
        #expect(await local.skippedIDs == [brokenOpID])

        // 已记录的坏对象不会再次读取，也不会阻塞后续同步。
        let second = try await runner.synchronize()
        #expect(second.pulled == 0)
        #expect(await local.skippedIDs == [brokenOpID])
    }

    private func makeClient(server: FakeWebDavServer) throws -> WebDavClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavMockURLProtocol.self]
        return try WebDavClient(
            account: account(),
            identity: identity(),
            session: URLSession(configuration: configuration),
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("webdav-operation.json")
    }
}

private func makeResponse(_ request: URLRequest, status: Int) throws -> HTTPURLResponse {
    guard let url = request.url else { throw URLError(.badURL) }
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

private final class WebDavRequestCounter: @unchecked Sendable {
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

private final class WebDavHandlerStorage: @unchecked Sendable {
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

private final class WebDavMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = WebDavHandlerStorage()

    static var handler: WebDavHandlerStorage.Handler? {
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

private final class FakeWebDavServer: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]

    func putObject(path: [String], data: Data) throws {
        lock.withLock {
            objects[path.joined(separator: "/")] = data
        }
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        let basePath = "/remote.php/dav/files/person/woo-todo"
        guard url.path.hasPrefix(basePath) else {
            return (try makeResponse(request, status: 404), Data())
        }
        let relative = String(url.path.dropFirst(basePath.count))
        let components = relative.split(separator: "/").map(String.init)
        let key = components.joined(separator: "/")
        let method = request.httpMethod ?? "GET"

        if method == "MKCOL" {
            return (try makeResponse(request, status: 201), Data())
        }
        if method == "PUT" {
            let body = requestBody(request)
            return lock.withLock {
                if let existing = objects[key] {
                    return existing == body
                        ? (try! makeResponse(request, status: 201), Data())
                        : (try! makeResponse(request, status: 412), Data())
                }
                objects[key] = body
                return (try! makeResponse(request, status: 201), Data())
            }
        }
        if method == "DELETE" {
            lock.withLock { objects[key] = nil }
            return (try makeResponse(request, status: 204), Data())
        }
        if method == "GET" {
            guard let data = lock.withLock({ objects[key] }) else {
                return (try makeResponse(request, status: 404), Data())
            }
            return (try makeResponse(request, status: 200), Data(data))
        }
        if method == "PROPFIND" {
            let depth = request.value(forHTTPHeaderField: "Depth") ?? "1"
            guard depth == "1" else {
                return (try makeResponse(request, status: 400), Data())
            }
            let rootComponents = components
            let prefix = rootComponents.joined(separator: "/")
            let children = lock.withLock { () -> Set<String> in
                var result = Set<String>()
                let prefixWithSlash = prefix + "/"
                for objectKey in objects.keys where objectKey.hasPrefix(prefixWithSlash) {
                    let remainder = objectKey.dropFirst(prefixWithSlash.count)
                    if let first = remainder.split(separator: "/").first {
                        result.insert(String(first))
                    }
                }
                return result
            }
            var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?><D:multistatus xmlns:D=\"DAV:\">"
            for child in children.sorted() {
                let childPath = "/remote.php/dav/files/person/woo-todo/" + prefix + "/" + child
                body += "<D:response><D:href>\(childPath)</D:href></D:response>"
            }
            body += "</D:multistatus>"
            return (try makeResponse(request, status: 207), Data(body.utf8))
        }
        return (try makeResponse(request, status: 405), Data())
    }
}

private actor FakeWebDavOutbox: SyncOutbox {
    private var operations: [SyncPushOperation]

    init(operations: [SyncPushOperation]) {
        self.operations = operations
    }

    var pending: [SyncPushOperation] { operations }

    func pendingOperations(limit: Int) async throws -> [SyncPushOperation] {
        Array(operations.prefix(limit))
    }

    func acknowledgeOperations(opIds: [String]) async throws {
        let acknowledged = Set(opIds)
        operations.removeAll { acknowledged.contains($0.opId) }
    }
}

private actor FakeWebDavLocal: WebDavLocalApplying {
    private var applied = Set<String>()
    private var skipped = Set<String>()
    private let lock = NSLock()

    var appliedIDs: [String] {
        lock.withLock { applied.sorted() }
    }

    var skippedIDs: [String] {
        lock.withLock { skipped.sorted() }
    }

    func pendingWebDavOperationIDs(_ operationIDs: [String]) async throws -> Set<String> {
        Set(operationIDs).subtracting(applied).subtracting(skipped)
    }

    func applyWebDavOperations(_ operations: [WebDavOperation]) async throws {
        for operation in operations {
            applied.insert(operation.opId)
        }
    }

    func skipWebDavOperations(opIds: [String]) async throws {
        lock.withLock {
            skipped.formUnion(opIds)
        }
    }
}
