import Foundation
import Testing
@testable import WooTodoSync

@Suite("WebDAV 设备心跳", .serialized)
struct WebDavDeviceHeartbeatTests {
    private let vaultKey = Data(repeating: 9, count: AES256GCM.keyByteCount)

    @Test("共享设备心跳 fixture 与严格信封字段")
    func sharedFixtureDecodesStrictly() throws {
        let data = try Data(contentsOf: fixtureURL("webdav-device.json"))
        let envelope = try JSONDecoder().decode(
            WebDavDeviceHeartbeatEnvelope.self,
            from: data
        )
        #expect(envelope.format == "woo-todo-webdav-device")
        #expect(envelope.protocolVersion == 1)
        #expect(envelope.deviceId == "device-mac-01")
        #expect(try Base64URL.decode(envelope.nonce).count == AES256GCM.nonceByteCount)
        #expect(
            try Base64URL.decode(envelope.ciphertext).count >= AES256GCM.tagByteCount
        )

        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["extra"] = true
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                WebDavDeviceHeartbeatEnvelope.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
        object.removeValue(forKey: "extra")
        object["protocolVersion"] = 2
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                WebDavDeviceHeartbeatEnvelope.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test("设备心跳加解密并绑定 vaultId、deviceId 与密文")
    func encryptsAndBindsAAD() throws {
        let heartbeat = try makeHeartbeat()
        let envelope = try WebDavDeviceHeartbeatCodec.seal(
            heartbeat,
            vaultId: "vault-a",
            deviceId: "device-mac-01",
            vaultKey: vaultKey
        )
        #expect(try WebDavDeviceHeartbeatCodec.open(
            envelope,
            vaultId: "vault-a",
            vaultKey: vaultKey
        ) == heartbeat)
        #expect(throws: WebDavError.self) {
            try WebDavDeviceHeartbeatCodec.open(
                envelope,
                vaultId: "vault-b",
                vaultKey: vaultKey
            )
        }
        #expect(throws: WebDavError.self) {
            try WebDavDeviceHeartbeatCodec.open(
                envelope,
                vaultId: "vault-a",
                vaultKey: Data(repeating: 8, count: AES256GCM.keyByteCount)
            )
        }

        // 信封 deviceId 参与 AAD：替换后无法解密。
        let otherDevice = try WebDavDeviceHeartbeatEnvelope(
            deviceId: "device-mac-02",
            nonce: envelope.nonce,
            ciphertext: envelope.ciphertext
        )
        #expect(throws: WebDavError.self) {
            try WebDavDeviceHeartbeatCodec.open(
                otherDevice,
                vaultId: "vault-a",
                vaultKey: vaultKey
            )
        }

        // 密文任意字节被篡改都会被认证标签拒绝。
        var tamperedBytes = try Base64URL.decode(envelope.ciphertext)
        tamperedBytes[0] ^= 0xFF
        let tampered = try WebDavDeviceHeartbeatEnvelope(
            deviceId: "device-mac-01",
            nonce: envelope.nonce,
            ciphertext: Base64URL.encode(tamperedBytes)
        )
        #expect(throws: WebDavError.self) {
            try WebDavDeviceHeartbeatCodec.open(
                tampered,
                vaultId: "vault-a",
                vaultKey: vaultKey
            )
        }
    }

    @Test("设备心跳明文拒绝未知或缺失字段与越界值")
    func rejectsInvalidPlaintext() throws {
        func decode(_ object: [String: Any]) throws -> WebDavDeviceHeartbeat {
            try JSONDecoder().decode(
                WebDavDeviceHeartbeat.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        let valid: [String: Any] = [
            "name": "MacBook Pro",
            "platform": "macos",
            "lastSeenAt": 1_760_000_000_000,
            "appVersion": "0.2.23",
        ]
        let decoded = try decode(valid)
        #expect(decoded.name == "MacBook Pro")
        #expect(decoded.platform == .macos)
        #expect(decoded.lastSeenAt == 1_760_000_000_000)
        #expect(decoded.appVersion == "0.2.23")

        for key in ["name", "platform", "lastSeenAt", "appVersion"] {
            var object = valid
            object.removeValue(forKey: key)
            #expect(throws: (any Error).self) { try decode(object) }
        }
        var extra = valid
        extra["deviceId"] = "device-mac-01"
        #expect(throws: (any Error).self) { try decode(extra) }

        for name in ["", String(repeating: "a", count: 81), "a\nb"] {
            var object = valid
            object["name"] = name
            #expect(throws: (any Error).self) { try decode(object) }
        }
        var zeroTime = valid
        zeroTime["lastSeenAt"] = 0
        #expect(throws: (any Error).self) { try decode(zeroTime) }
        var negativeTime = valid
        negativeTime["lastSeenAt"] = -1
        #expect(throws: (any Error).self) { try decode(negativeTime) }
        for version in ["", String(repeating: "1", count: 33), "1.0\n"] {
            var object = valid
            object["appVersion"] = version
            #expect(throws: (any Error).self) { try decode(object) }
        }
        var unknownPlatform = valid
        unknownPlatform["platform"] = "ios"
        #expect(throws: (any Error).self) { try decode(unknownPlatform) }
    }

    @Test("解密时拒绝密文内多余的明文字段")
    func openRejectsUnexpectedPlaintextField() throws {
        let plaintext = Data("""
        {"name":"Mac","platform":"macos","lastSeenAt":1,"appVersion":"0.2.23","extra":true}
        """.utf8)
        let envelope = try WebDavDeviceHeartbeatCodec.sealPlaintext(
            plaintext,
            vaultId: "vault-a",
            deviceId: "device-mac-01",
            vaultKey: vaultKey
        )
        #expect(throws: WebDavError.self) {
            try WebDavDeviceHeartbeatCodec.open(
                envelope,
                vaultId: "vault-a",
                vaultKey: vaultKey
            )
        }
    }

    @Test("写入覆盖同一 deviceId 且不写其他设备")
    func putOverwritesOwnHeartbeat() async throws {
        let server = DeviceHeartbeatServer()
        DeviceHeartbeatURLProtocol.handler = { try server.handle($0) }
        defer { DeviceHeartbeatURLProtocol.handler = nil }
        let client = try makeClient()

        try await client.putDeviceHeartbeat(try makeHeartbeat(
            name: "旧名字",
            lastSeenAt: 1_000
        ))
        try await client.putDeviceHeartbeat(try makeHeartbeat(
            name: "新名字",
            lastSeenAt: 2_000
        ))

        #expect(server.keys == ["v1/personal-vault/devices/device-mac-01.json"])
        let devices = try await client.listDevices()
        #expect(devices.count == 1)
        #expect(devices.first?.deviceId == "device-mac-01")
        #expect(devices.first?.name == "新名字")
        #expect(devices.first?.lastSeenAt == Date(timeIntervalSince1970: 2))
    }

    @Test("设备列表按 lastSeenAt 降序排列")
    func sortsDevicesByLastSeenDescending() async throws {
        let server = DeviceHeartbeatServer()
        try server.put(
            path: ["v1", "personal-vault", "devices", "device-older-01.json"],
            data: try heartbeatData(
                name: "旧设备",
                platform: .android,
                deviceId: "device-older-01",
                lastSeenAt: 1_000
            )
        )
        try server.put(
            path: ["v1", "personal-vault", "devices", "device-newer-01.json"],
            data: try heartbeatData(
                name: "新设备",
                platform: .windows,
                deviceId: "device-newer-01",
                lastSeenAt: 3_000
            )
        )
        try server.put(
            path: ["v1", "personal-vault", "devices", "device-middle-1.json"],
            data: try heartbeatData(
                name: "中间设备",
                platform: .macos,
                deviceId: "device-middle-1",
                lastSeenAt: 2_000
            )
        )
        DeviceHeartbeatURLProtocol.handler = { try server.handle($0) }
        defer { DeviceHeartbeatURLProtocol.handler = nil }

        let devices = try await makeClient().listDevices()
        #expect(devices.map(\.name) == ["新设备", "中间设备", "旧设备"])
        #expect(devices.map(\.platform) == [.windows, .macos, .android])
    }

    @Test("未知版本、坏文件与文件名不匹配会被跳过但不删除")
    func skipsInvalidHeartbeatsWithoutDeleting() async throws {
        let server = DeviceHeartbeatServer()
        let validPath = ["v1", "personal-vault", "devices", "device-good-01.json"]
        try server.put(
            path: validPath,
            data: try heartbeatData(
                name: "正常设备",
                platform: .macos,
                deviceId: "device-good-01",
                lastSeenAt: 5_000
            )
        )
        let unknownVersionPath = [
            "v1", "personal-vault", "devices", "device-unknown-01.json",
        ]
        try server.put(
            path: unknownVersionPath,
            data: Data("""
            {
              "format": "woo-todo-webdav-device",
              "protocolVersion": 2,
              "deviceId": "device-unknown-01",
              "nonce": "\(Base64URL.encode(Data(repeating: 0, count: 12)))",
              "ciphertext": "\(Base64URL.encode(Data(repeating: 1, count: 20)))"
            }
            """.utf8)
        )
        let corruptPath = ["v1", "personal-vault", "devices", "device-broken-01.json"]
        try server.put(path: corruptPath, data: Data("{not-json".utf8))
        let mismatchPath = [
            "v1", "personal-vault", "devices", "device-other-02.json",
        ]
        try server.put(
            path: mismatchPath,
            data: try heartbeatData(
                name: "文件名不匹配",
                platform: .android,
                deviceId: "device-other-01",
                lastSeenAt: 6_000
            )
        )
        let invalidNamePath = ["v1", "personal-vault", "devices", "short.json"]
        try server.put(path: invalidNamePath, data: Data("{}".utf8))
        DeviceHeartbeatURLProtocol.handler = { try server.handle($0) }
        defer { DeviceHeartbeatURLProtocol.handler = nil }

        let devices = try await makeClient().listDevices()
        #expect(devices.map(\.deviceId) == ["device-good-01"])
        // 坏文件不删除：后续升级或修复后仍可被识别。
        for path in [validPath, unknownVersionPath, corruptPath, mismatchPath, invalidNamePath] {
            #expect(server.object(path: path) != nil)
        }
    }

    @Test("空设备目录返回空列表")
    func emptyDeviceDirectoryReturnsNoDevices() async throws {
        let server = DeviceHeartbeatServer()
        DeviceHeartbeatURLProtocol.handler = { try server.handle($0) }
        defer { DeviceHeartbeatURLProtocol.handler = nil }

        #expect(try await makeClient().listDevices().isEmpty)
    }

    @Test("设备目录不存在时返回空列表")
    func missingDeviceDirectoryReturnsNoDevices() async throws {
        DeviceHeartbeatURLProtocol.handler = { request in
            (try makeResponse(request, status: 404), Data())
        }
        defer { DeviceHeartbeatURLProtocol.handler = nil }

        #expect(try await makeClient().listDevices().isEmpty)
    }

    private func makeHeartbeat(
        name: String = "MacBook Pro",
        lastSeenAt: Int64 = 1_760_000_000_000
    ) throws -> WebDavDeviceHeartbeat {
        try WebDavDeviceHeartbeat(
            name: name,
            platform: .macos,
            lastSeenAt: lastSeenAt,
            appVersion: "0.2.23"
        )
    }

    private func heartbeatData(
        name: String,
        platform: DevicePlatform,
        deviceId: String,
        lastSeenAt: Int64
    ) throws -> Data {
        let heartbeat = try WebDavDeviceHeartbeat(
            name: name,
            platform: platform,
            lastSeenAt: lastSeenAt,
            appVersion: "0.2.23"
        )
        let envelope = try WebDavDeviceHeartbeatCodec.seal(
            heartbeat,
            vaultId: "personal-vault",
            deviceId: deviceId,
            vaultKey: vaultKey
        )
        return try JSONEncoder().encode(envelope)
    }

    private func makeClient() throws -> WebDavClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceHeartbeatURLProtocol.self]
        return try WebDavClient(
            account: WebDavAccount(
                endpoint: try #require(URL(
                    string: "https://dav.example.test/remote.php/dav/files/person/woo-todo/"
                )),
                username: "user@example.com",
                appPassword: "application-password"
            ),
            identity: WebDavIdentity(
                vaultId: "personal-vault",
                deviceId: "device-mac-01",
                vaultKey: vaultKey
            ),
            session: URLSession(configuration: configuration),
            retryDelaysNanoseconds: [],
            retrySleep: { _ in }
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("shared")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(name)
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

private final class DeviceHeartbeatHandlerStorage: @unchecked Sendable {
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

private final class DeviceHeartbeatURLProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = DeviceHeartbeatHandlerStorage()

    static var handler: DeviceHeartbeatHandlerStorage.Handler? {
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

private final class DeviceHeartbeatServer: @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: Data] = [:]
    private let basePath = "/remote.php/dav/files/person/woo-todo"

    var keys: [String] {
        lock.withLock { objects.keys.sorted() }
    }

    func put(path: [String], data: Data) {
        lock.withLock {
            objects[path.joined(separator: "/")] = data
        }
    }

    func object(path: [String]) -> Data? {
        lock.withLock { objects[path.joined(separator: "/")] }
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw URLError(.badURL) }
        guard url.path.hasPrefix(basePath) else {
            return (try makeResponse(request, status: 404), Data())
        }
        let relative = String(url.path.dropFirst(basePath.count))
        let components = relative.split(separator: "/").map(String.init)
        let key = components.joined(separator: "/")
        let method = request.httpMethod ?? "GET"

        switch method {
        case "MKCOL":
            return (try makeResponse(request, status: 201), Data())
        case "PUT":
            let body = requestBody(request)
            lock.withLock { objects[key] = body }
            return (try makeResponse(request, status: 201), Data())
        case "GET":
            guard let data = lock.withLock({ objects[key] }) else {
                return (try makeResponse(request, status: 404), Data())
            }
            return (try makeResponse(request, status: 200), data)
        case "DELETE":
            lock.withLock { objects[key] = nil }
            return (try makeResponse(request, status: 204), Data())
        case "PROPFIND":
            let depth = request.value(forHTTPHeaderField: "Depth") ?? "1"
            guard depth == "1" else {
                return (try makeResponse(request, status: 400), Data())
            }
            let prefixWithSlash = key + "/"
            let children = lock.withLock { () -> Set<String> in
                var result = Set<String>()
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
                let path = "/remote.php/dav/files/person/woo-todo/"
                    + key + "/" + child
                body += "<D:response><D:href>\(path)</D:href></D:response>"
            }
            body += "</D:multistatus>"
            return (try makeResponse(request, status: 207), Data(body.utf8))
        default:
            return (try makeResponse(request, status: 405), Data())
        }
    }
}
