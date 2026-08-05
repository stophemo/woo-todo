import Foundation
import Testing
@testable import WooTodoSync

@Suite("坚果云 WebDAV 操作协议")
struct WebDavOperationTests {
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
        #expect(String(decoding: encoded, as: UTF8.self) ==
            "{\"ciphertext\":\"VGhpcy1pcy1hLXRlc3QtY2lwaGVydGV4dC1hbmQtdGFnIQ\"," +
            "\"deviceId\":\"device-mac-01\"," +
            "\"entityId\":\"550e8400-e29b-41d4-a716-446655440000\"," +
            "\"format\":\"woo-todo-webdav-operation\",\"kind\":\"upsert\"," +
            "\"lamport\":12,\"nonce\":\"AAECAwQFBgcICQoL\"," +
            "\"opId\":\"op_01JZ7X0B8E6V5P4N3M2K\",\"protocolVersion\":1," +
            "\"vaultId\":\"personal-vault\"}")
    }

    @Test("WebDAV 对象拒绝未知字段与非法 nonce")
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

    @Test("坚果云端点策略拒绝凭据外送")
    func endpointPolicy() throws {
        #expect(WebDavEndpointPolicy.isAllowed(WebDavEndpointPolicy.endpoint))
        #expect(!WebDavEndpointPolicy.isAllowed(try #require(URL(string: "https://example.com/dav/"))))
        #expect(!WebDavEndpointPolicy.isAllowed(try #require(URL(string: "http://dav.jianguoyun.com/dav/"))))
        #expect(throws: WebDavError.invalidCredentials) {
            try WebDavCredentials(
                username: "user@example.com",
                appPassword: "application-password",
                vaultId: "..",
                deviceId: "device-macos-01",
                vaultKey: Data(repeating: 0, count: AES256GCM.keyByteCount)
            ).validate()
        }
    }

    @Test("坚果云凭据统一限制账号与应用密码长度")
    func credentialLengthLimits() throws {
        func credentials(username: String, appPassword: String) -> WebDavCredentials {
            WebDavCredentials(
                username: username,
                appPassword: appPassword,
                vaultId: "personal-vault",
                deviceId: "device-macos-01",
                vaultKey: Data(repeating: 0, count: AES256GCM.keyByteCount)
            )
        }

        try credentials(
            username: String(repeating: "u", count: 320),
            appPassword: String(repeating: "p", count: 256)
        ).validate()
        #expect(throws: WebDavError.invalidCredentials) {
            try credentials(
                username: String(repeating: "u", count: 321),
                appPassword: "password"
            ).validate()
        }
        #expect(throws: WebDavError.invalidCredentials) {
            try credentials(
                username: "user@example.com",
                appPassword: String(repeating: "p", count: 257)
            ).validate()
        }
    }

    @Test("PROPFIND 支持 DAV 命名空间、绝对路径与百分号编码")
    func propfindHrefParsing() throws {
        let source = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>https://dav.jianguoyun.com/dav/v1/personal-vault/ops/ab/op%20one.json?ignored=1</D:href>
          </D:response>
          <D:response>
            <D:href>/dav/v1/personal-vault/ops/cd/%E4%BB%BB%E5%8A%A1.json/</D:href>
          </D:response>
          <D:response><D:href>/dav/other/path</D:href></D:response>
        </D:multistatus>
        """

        #expect(try WebDavHrefParser.parse(Data(source.utf8)) == [
            ["v1", "personal-vault", "ops", "ab", "op one.json"],
            ["v1", "personal-vault", "ops", "cd", "任务.json"],
        ])
    }

    @Test("PROPFIND 拒绝格式错误的 href 而不是静默漏掉远端操作")
    func rejectsMalformedPropfindHref() {
        let source = """
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/dav/v1/personal-vault/ops/ab/operation%ZZ.json</D:href>
          </D:response>
        </D:multistatus>
        """

        #expect(throws: WebDavError.self) {
            try WebDavHrefParser.parse(Data(source.utf8))
        }
    }

    @Test("WebDAV 批次数不在五百条后截断")
    func pageCountCoversAllOperations() {
        #expect(WebDavSyncRunner.webDavPageCount(0) == 1)
        #expect(WebDavSyncRunner.webDavPageCount(500) == 1)
        #expect(WebDavSyncRunner.webDavPageCount(501) == 2)
        #expect(WebDavSyncRunner.webDavPageCount(1_001) == 3)
    }

    @Test("坚果云临时 503 会短退避重试后继续")
    func retriesTemporaryServiceFailures() async throws {
        let counter = WebDavRequestCounter()
        WebDavMockURLProtocol.handler = { request in
            let requestNumber = counter.next()
            let statusCode = requestNumber <= 2 ? 503 : 201
            return (
                HTTPURLResponse(
                    url: try #require(request.url),
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { WebDavMockURLProtocol.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebDavMockURLProtocol.self]
        let client = try WebDavClient(
            credentials: WebDavCredentials(
                username: "user@example.com",
                appPassword: "application-password",
                vaultId: "personal-vault",
                deviceId: "device-macos-01",
                vaultKey: Data(repeating: 0, count: AES256GCM.keyByteCount)
            ),
            session: URLSession(configuration: configuration),
            retryDelaysNanoseconds: [0, 0],
            retrySleep: { _ in }
        )

        try await client.ensureCollections()

        #expect(counter.value == 5)
    }

    @Test("WebDAV 错误文案包含真实上下文")
    func errorDescriptionsInterpolateValues() {
        #expect(WebDavError.http(503).errorDescription == "坚果云 WebDAV 返回 HTTP 503")
        #expect(WebDavError.transport("超时").errorDescription == "坚果云网络请求失败：超时")
        #expect(WebDavError.objectConflict("v1/a.json").errorDescription ==
            "坚果云对象发生冲突：v1/a.json")
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
