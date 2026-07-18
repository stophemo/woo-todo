import Foundation
import Testing
@testable import WooTodoSync

@Suite("同步 API 客户端", .serialized)
struct SyncAPIClientTests {
    @Test("创建空间只通过专用请求头发送邀请码")
    func test创建空间只通过专用请求头发送邀请码() async throws {
        defer { MockURLProtocol.handler = nil }
        let inviteCode = "invite-secret-2026"
        MockURLProtocol.handler = { request in
            let body = MockURLProtocol.bodyData(for: request)
            let bodyText = body.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            guard request.url?.path == "/root/v1/vaults",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == nil,
                  request.value(forHTTPHeaderField: "X-Woo-Todo-Invite-Code") == inviteCode,
                  !bodyText.contains(inviteCode),
                  let body,
                  let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let device = object["device"] as? [String: Any],
                  device["name"] as? String == "测试 Mac",
                  device["platform"] as? String == "macos" else {
                throw MockError.requestMismatch("创建空间请求未按协议携带邀请码")
            }
            return MockURLProtocol.response(
                for: request,
                status: 200,
                json: """
                {
                  "ok": true,
                  "data": {
                    "vaultId": "vault-test",
                    "device": {
                      "id": "device-mac",
                      "name": "测试 Mac",
                      "platform": "macos",
                      "token": "device-token"
                    },
                    "serverTime": 1000
                  },
                  "requestId": "req-create-vault"
                }
                """
            )
        }

        let result = try await makeClient().createVault(
            CreateVaultRequest(device: DeviceRegistration(
                name: "测试 Mac",
                platform: .macos
            )),
            inviteCode: inviteCode
        )

        #expect(result.vaultId == "vault-test")
        #expect(result.device.id == "device-mac")
    }

    @Test("sync 发送 Bearer 与精确 JSON 并解析响应")
    func testSync发送Bearer与精确JSON并解析响应() async throws {
        defer { MockURLProtocol.handler = nil }
        let token = Base64URL.encode(Data(repeating: 1, count: 32))
        let metadata = SyncAADMetadata(
            vaultId: "vault-test",
            operationId: "op-1",
            entityId: "task-1",
            kind: .upsert,
            lamport: 8,
            deviceId: "device-test"
        )
        let encrypted = try AES256GCM.seal(
            Data("{\"entityType\":\"task\"}".utf8),
            key: Data(repeating: 6, count: 32),
            nonce: Data(repeating: 3, count: 12),
            authenticating: SyncAAD.data(metadata)
        )
        let operation = SyncPushOperation(
            opId: metadata.operationId,
            entityId: metadata.entityId,
            kind: metadata.kind,
            lamport: metadata.lamport,
            ciphertext: encrypted.ciphertext,
            nonce: encrypted.nonce
        )
        MockURLProtocol.handler = { request in
            guard request.url?.path == "/root/v1/sync",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)",
                  request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                  let body = MockURLProtocol.bodyData(for: request),
                  let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  object["cursor"] as? Int == 7,
                  object["ack"] as? Int == 7,
                  object["pullLimit"] as? Int == 100,
                  let push = object["push"] as? [[String: Any]],
                  push.first?["kind"] as? String == "upsert",
                  push.first?["ciphertext"] as? String == encrypted.ciphertext else {
                throw MockError.requestMismatch(
                    "path=\(request.url?.path ?? "nil"), method=\(request.httpMethod ?? "nil"), "
                        + "authorization=\(request.value(forHTTPHeaderField: "Authorization") ?? "nil"), "
                        + "contentType=\(request.value(forHTTPHeaderField: "Content-Type") ?? "nil"), "
                        + "body=\(MockURLProtocol.bodyData(for: request).flatMap { String(data: $0, encoding: .utf8) } ?? "nil")"
                )
            }
            return MockURLProtocol.response(
                for: request,
                status: 200,
                json: """
                {
                  "ok": true,
                  "data": {
                    "push": {"received": 1, "inserted": 1, "duplicates": 0},
                    "pull": [],
                    "cursor": 7,
                    "hasMore": false,
                    "serverTime": 1000
                  },
                  "requestId": "req-sync"
                }
                """
            )
        }
        let client = try makeClient()
        let result = try await client.sync(
            SyncRequest(cursor: 7, ack: 7, pullLimit: 100, push: [operation]),
            deviceToken: token
        )
        #expect(result.push.inserted == 1)
        #expect(result.cursor == 7)
    }

    @Test("配对结果将 HTTP 202 视为正常状态")
    func testPairingResult将HTTP202视为正常状态() async throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            guard request.url?.path == "/root/v1/pairings/pair-1/result",
                  request.value(forHTTPHeaderField: "Authorization") == nil else {
                throw MockError.requestMismatch("配对结果请求不一致")
            }
            return MockURLProtocol.response(
                for: request,
                status: 202,
                json: """
                {
                  "ok": true,
                  "data": {
                    "pairingId": "pair-1",
                    "status": "claimed",
                    "expiresAt": 123456
                  },
                  "requestId": "req-pair"
                }
                """
            )
        }
        let data = try await makeClient().pairingResult(
            pairingId: "pair-1",
            request: PairingResultRequest(
                pairingSecret: Base64URL.encode(Data(repeating: 4, count: 32)),
                deviceToken: Base64URL.encode(Data(repeating: 5, count: 32))
            )
        )
        #expect(data.status == .claimed)
        #expect(data.vaultKeyEnvelope == nil)
    }

    @Test("服务端错误保留状态码、错误码、详情和 requestId")
    func test服务端错误保留状态码错误码详情和RequestId() async throws {
        defer { MockURLProtocol.handler = nil }
        MockURLProtocol.handler = { request in
            MockURLProtocol.response(
                for: request,
                status: 400,
                json: """
                {
                  "ok": false,
                  "error": {
                    "code": "VALIDATION_ERROR",
                    "message": "参数无效",
                    "details": {"field": "push[0].nonce"}
                  },
                  "requestId": "req-error"
                }
                """
            )
        }
        do {
            _ = try await makeClient().listDevices(deviceToken: "token")
            Issue.record("预期服务端错误")
        } catch let SyncAPIError.server(statusCode, payload, requestId) {
            #expect(statusCode == 400)
            #expect(payload.code == "VALIDATION_ERROR")
            #expect(payload.details?["field"] == .string("push[0].nonce"))
            #expect(requestId == "req-error")
        } catch {
            Issue.record("错误类型不符：\(error)")
        }
    }

    private func makeClient() throws -> SyncAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return try SyncAPIClient(
            endpoint: URL(string: "https://sync.example.test/root")!,
            session: URLSession(configuration: configuration)
        )
    }
}

private enum MockError: Error, LocalizedError {
    case missingHandler
    case requestMismatch(String)

    var errorDescription: String? {
        switch self {
        case .missingHandler: "URLProtocol 未配置处理器"
        case .requestMismatch(let detail): "URLProtocol 请求不一致：\(detail)"
        }
    }
}

private final class HandlerStorage: @unchecked Sendable {
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

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = HandlerStorage()

    static var handler: HandlerStorage.Handler? {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: MockError.missingHandler)
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

    static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

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
