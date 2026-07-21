import Foundation
import Security

public enum WebDavError: Error, Equatable, LocalizedError, Sendable {
    case invalidCredentials
    case invalidEndpoint
    case encoding(String)
    case transport(String)
    case invalidResponse
    case http(Int)
    case objectConflict(String)
    case malformedObject(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials: "坚果云同步凭据无效"
        case .invalidEndpoint: "坚果云 WebDAV 地址必须是 https://dav.jianguoyun.com/dav/"
        case .encoding(let message): "WebDAV 对象编码失败：\(message)"
        case .transport(let message): "坚果云网络请求失败：\(message)"
        case .invalidResponse: "坚果云返回了无效的 HTTP 响应"
        case .http(let status): "坚果云 WebDAV 返回 HTTP \(status)"
        case .objectConflict(let path): "坚果云对象发生冲突：\(path)"
        case .malformedObject(let message): "坚果云同步对象无效：\(message)"
        }
    }
}

public enum WebDavEndpointPolicy {
    public static let endpoint = URL(string: "https://dav.jianguoyun.com/dav/")!

    public static func isAllowed(_ value: URL) -> Bool {
        guard value.scheme?.lowercased() == "https",
              value.host?.lowercased() == "dav.jianguoyun.com",
              value.user == nil,
              value.password == nil,
              value.query == nil,
              value.fragment == nil else { return false }
        let path = value.path.hasSuffix("/") ? value.path : value.path + "/"
        return path == "/dav/"
    }
}

public struct WebDavCredentials: Codable, Equatable, Sendable {
    public let endpoint: URL
    public let username: String
    public let appPassword: String
    public let vaultId: String
    public let deviceId: String
    public let vaultKey: Data

    public init(
        endpoint: URL = WebDavEndpointPolicy.endpoint,
        username: String,
        appPassword: String,
        vaultId: String,
        deviceId: String,
        vaultKey: Data
    ) {
        self.endpoint = endpoint
        self.username = username
        self.appPassword = appPassword
        self.vaultId = vaultId
        self.deviceId = deviceId
        self.vaultKey = vaultKey
    }

    public func validate() throws {
        guard WebDavEndpointPolicy.isAllowed(endpoint),
              !username.isEmpty,
              !appPassword.isEmpty,
              username.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              username.rangeOfCharacter(from: .controlCharacters) == nil,
              appPassword.rangeOfCharacter(from: .controlCharacters) == nil,
              vaultId.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              deviceId.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$", options: .regularExpression) != nil,
              vaultKey.count == AES256GCM.keyByteCount else {
            throw WebDavError.invalidCredentials
        }
    }
}

/// 坚果云应用密码与同步密钥只进入 Keychain；WebDAV 服务端永远只看到密文对象。
public final class WebDavCredentialsStore: @unchecked Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "dev.woo-todo.webdav",
        account: String = "jianguoyun"
    ) {
        self.service = service
        self.account = account
    }

    public func save(_ credentials: WebDavCredentials) throws {
        try credentials.validate()
        let data: Data
        do {
            data = try JSONEncoder().encode(credentials)
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
        var attributes = query()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                query() as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw WebDavError.transport("Keychain 错误码 \(updateStatus)")
            }
        } else if status != errSecSuccess {
            throw WebDavError.transport("Keychain 错误码 \(status)")
        }
    }

    public func load() throws -> WebDavCredentials? {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw WebDavError.transport("Keychain 错误码 \(status)")
        }
        do {
            let credentials = try JSONDecoder().decode(WebDavCredentials.self, from: data)
            try credentials.validate()
            return credentials
        } catch let error as WebDavError {
            throw error
        } catch {
            throw WebDavError.invalidCredentials
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw WebDavError.transport("Keychain 错误码 \(status)")
        }
    }

    private func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct WebDavOperation: Codable, Equatable, Sendable {
    public let format: String
    public let protocolVersion: Int
    public let vaultId: String
    public let deviceId: String
    public let opId: String
    public let entityId: String
    public let kind: SyncOperationKind
    public let lamport: Int64
    public let nonce: String
    public let ciphertext: String

    public init(
        vaultId: String,
        deviceId: String,
        operation: SyncPushOperation
    ) throws {
        self.format = "woo-todo-webdav-operation"
        self.protocolVersion = 1
        self.vaultId = vaultId
        self.deviceId = deviceId
        self.opId = operation.opId
        self.entityId = operation.entityId
        self.kind = operation.kind
        self.lamport = operation.lamport
        self.nonce = operation.nonce
        self.ciphertext = operation.ciphertext
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        let expected = Set([
            "format", "protocolVersion", "vaultId", "deviceId", "opId",
            "entityId", "kind", "lamport", "nonce", "ciphertext",
        ])
        guard actual == expected else {
            throw WebDavError.malformedObject("字段不匹配")
        }
        self.format = try container.decode(String.self, forKey: AnyCodingKey("format"))
        self.protocolVersion = try container.decode(Int.self, forKey: AnyCodingKey("protocolVersion"))
        self.vaultId = try container.decode(String.self, forKey: AnyCodingKey("vaultId"))
        self.deviceId = try container.decode(String.self, forKey: AnyCodingKey("deviceId"))
        self.opId = try container.decode(String.self, forKey: AnyCodingKey("opId"))
        self.entityId = try container.decode(String.self, forKey: AnyCodingKey("entityId"))
        self.kind = try container.decode(SyncOperationKind.self, forKey: AnyCodingKey("kind"))
        self.lamport = try container.decode(Int64.self, forKey: AnyCodingKey("lamport"))
        self.nonce = try container.decode(String.self, forKey: AnyCodingKey("nonce"))
        self.ciphertext = try container.decode(String.self, forKey: AnyCodingKey("ciphertext"))
        try validate()
    }

    public func validate() throws {
        guard format == "woo-todo-webdav-operation",
              protocolVersion == 1,
              vaultId.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              validIdentifier(deviceId),
              validIdentifier(opId),
              validIdentifier(entityId),
              lamport >= 1,
              (try? Base64URL.decode(nonce).count) == AES256GCM.nonceByteCount,
              (try? Base64URL.decode(ciphertext).count).map({ $0 >= AES256GCM.tagByteCount }) == true else {
            throw WebDavError.malformedObject("元数据或密文长度无效")
        }
    }

    public func pushOperation() -> SyncPushOperation {
        SyncPushOperation(
            opId: opId,
            entityId: entityId,
            kind: kind,
            lamport: lamport,
            ciphertext: ciphertext,
            nonce: nonce
        )
    }

    public static func path(vaultId: String, opId: String) -> [String] {
        let shard = String(opId.prefix(2))
        return ["v1", vaultId, "ops", shard, "\(opId).json"]
    }

    internal static func isValidShard(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._:-]$",
            options: .regularExpression
        ) != nil
    }

    private func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$", options: .regularExpression) != nil
    }
}

public protocol WebDavLocalApplying: Sendable {
    func applyWebDavOperations(_ operations: [WebDavOperation]) async throws
}

public final class WebDavClient: @unchecked Sendable {
    public let credentials: WebDavCredentials
    private let session: URLSession
    private let baseURL: URL

    public init(credentials: WebDavCredentials, session: URLSession = .shared) throws {
        try credentials.validate()
        self.credentials = credentials
        self.session = session
        self.baseURL = credentials.endpoint
    }

    public func ensureCollections() async throws {
        for path in [
            ["v1"],
            ["v1", credentials.vaultId],
            ["v1", credentials.vaultId, "ops"],
        ] {
            _ = try await request(method: "MKCOL", path: path, body: nil, headers: [:], accepted: [201, 405, 409])
        }
    }

    public func put(_ operation: WebDavOperation) async throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(operation)
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
        let path = WebDavOperation.path(vaultId: credentials.vaultId, opId: operation.opId)
        _ = try await request(
            method: "MKCOL",
            path: Array(path.dropLast()),
            body: nil,
            headers: [:],
            accepted: [201, 405, 409]
        )
        let result = try await request(
            method: "PUT",
            path: path,
            body: data,
            headers: ["Content-Type": "application/json", "If-None-Match": "*"],
            accepted: [200, 201, 204, 405, 409, 412]
        )
        guard [405, 409, 412].contains(result.statusCode) else { return }
        let existing = try await get(path: path)
        guard existing == data else { throw WebDavError.objectConflict(path.joined(separator: "/")) }
    }

    public func listOperationPaths() async throws -> [[String]] {
        let root = ["v1", credentials.vaultId, "ops"]
        let shards = try await propfind(path: root, depth: 1).compactMap { path -> String? in
            guard path.count == root.count + 1,
                  path.dropFirst(root.count).first.map(WebDavOperation.isValidShard) == true
            else { return nil }
            return path.last
        }
        var result: [[String]] = []
        for shard in Set(shards).sorted() {
            let paths = try await propfind(path: root + [shard], depth: 1)
            result.append(contentsOf: paths.filter { path in
                path.count == root.count + 2 && path.last?.hasSuffix(".json") == true
            })
        }
        return result.sorted { $0.joined() < $1.joined() }
    }

    public func get(path: [String]) async throws -> Data {
        try await request(method: "GET", path: path, body: nil, headers: [:], accepted: [200]).data
    }

    private func propfind(path: [String], depth: Int) async throws -> [[String]] {
        let response = try await request(
            method: "PROPFIND",
            path: path,
            body: Data("<?xml version=\"1.0\" encoding=\"utf-8\" ?><propfind xmlns=\"DAV:\"><prop><resourcetype/></prop></propfind>".utf8),
            headers: ["Depth": String(depth), "Content-Type": "application/xml"],
            accepted: [207]
        )
        return try WebDavHrefParser.parse(response.data)
    }

    private func request(
        method: String,
        path: [String],
        body: Data?,
        headers: [String: String],
        accepted: Set<Int>
    ) async throws -> (data: Data, statusCode: Int) {
        var url = baseURL
        for component in path { url.appendPathComponent(component) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("Basic \(Data("\(credentials.username):\(credentials.appPassword)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WebDavError.invalidResponse }
            guard accepted.contains(http.statusCode) else { throw WebDavError.http(http.statusCode) }
            return (data, http.statusCode)
        } catch let error as WebDavError {
            throw error
        } catch {
            throw WebDavError.transport(error.localizedDescription)
        }
    }
}

public final class WebDavSyncRunner: @unchecked Sendable {
    private let client: WebDavClient
    private let outbox: any SyncOutbox
    private let local: any WebDavLocalApplying

    public init(client: WebDavClient, outbox: any SyncOutbox, local: any WebDavLocalApplying) {
        self.client = client
        self.outbox = outbox
        self.local = local
    }

    public func synchronize() async throws -> SyncRunSummary {
        try await client.ensureCollections()
        let pending = try await outbox.pendingOperations(limit: SyncCoordinator.maximumPushBatch)
        for operation in pending {
            try await client.put(WebDavOperation(
                vaultId: client.credentials.vaultId,
                deviceId: client.credentials.deviceId,
                operation: operation
            ))
        }

        let paths = try await client.listOperationPaths()
        var operations: [WebDavOperation] = []
        for path in paths {
            let data = try await client.get(path: path)
            do {
                let operation = try JSONDecoder().decode(WebDavOperation.self, from: data)
                guard operation.vaultId == client.credentials.vaultId else {
                    throw WebDavError.malformedObject("同步空间不匹配")
                }
                guard path == WebDavOperation.path(
                    vaultId: operation.vaultId,
                    opId: operation.opId
                ) else {
                    throw WebDavError.malformedObject("对象路径与 opId 不匹配")
                }
                operations.append(operation)
            } catch let error as WebDavError {
                throw error
            } catch {
                throw WebDavError.malformedObject(error.localizedDescription)
            }
        }
        for start in stride(from: 0, to: operations.count, by: Self.webDavApplyBatchSize) {
            let end = min(start + Self.webDavApplyBatchSize, operations.count)
            try await local.applyWebDavOperations(Array(operations[start..<end]))
        }
        try await outbox.acknowledgeOperations(opIds: pending.map(\.opId))
        return SyncRunSummary(
            pushed: pending.count,
            pulled: operations.count,
            pages: Self.webDavPageCount(operations.count),
            finalCursor: 0
        )
    }

    internal static let webDavApplyBatchSize = 500

    internal static func webDavPageCount(_ operationCount: Int) -> Int {
        max(1, (operationCount + webDavApplyBatchSize - 1) / webDavApplyBatchSize)
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue) }
}

internal final class WebDavHrefParser: NSObject, XMLParserDelegate {
    private var current: String?
    private var values: [String] = []

    static func parse(_ data: Data) throws -> [[String]] {
        let parser = WebDavHrefParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw WebDavError.malformedObject("PROPFIND XML 无法解析") }
        var paths: [[String]] = []
        for raw in parser.values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  let url = URL(string: value),
                  !url.path.isEmpty,
                  let decoded = url.path.removingPercentEncoding else {
                throw WebDavError.malformedObject("PROPFIND href 无效")
            }
            let parts = decoded.split(separator: "/").map(String.init)
            guard let start = parts.firstIndex(of: "v1") else { continue }
            paths.append(Array(parts[start...]))
        }
        return paths
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if Self.isHrefElement(elementName, qualifiedName: qName) { current = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let current else { return }
        self.current = current + string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard Self.isHrefElement(elementName, qualifiedName: qName),
              let current else { return }
        values.append(current)
        self.current = nil
    }

    private static func isHrefElement(_ elementName: String, qualifiedName: String?) -> Bool {
        let candidate = (qualifiedName ?? elementName).split(separator: ":").last.map(String.init)
        return candidate?.caseInsensitiveCompare("href") == .orderedSame
    }
}
