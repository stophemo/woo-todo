import Foundation

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
    func pendingWebDavOperationIDs(_ operationIDs: [String]) async throws -> Set<String>
    func applyWebDavOperations(_ operations: [WebDavOperation]) async throws
    /// 把无法解码或校验失败的远端对象按 opId 记为已处理，避免整批永久重试。
    func skipWebDavOperations(opIds: [String]) async throws
}

public extension WebDavLocalApplying {
    func pendingWebDavOperationIDs(_ operationIDs: [String]) async throws -> Set<String> {
        Set(operationIDs)
    }

    func skipWebDavOperations(opIds: [String]) async throws {}
}

public final class WebDavClient: WebDavPairingFileTransport, @unchecked Sendable {
    internal typealias RetrySleep = @Sendable (UInt64) async throws -> Void

    public let account: WebDavAccount
    public let identity: WebDavIdentity?
    private let session: URLSession
    private let baseURL: URL
    private let retryDelaysNanoseconds: [UInt64]
    private let retrySleep: RetrySleep

    private static let defaultRetryDelaysNanoseconds: [UInt64] = [
        1_000_000_000,
        2_000_000_000,
        4_000_000_000,
    ]
    private static let retryableHTTPStatuses: Set<Int> = [
        408, 425, 429, 500, 502, 503, 504,
    ]
    private static let retryableURLErrorCodes: Set<URLError.Code> = [
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .timedOut,
    ]

    public init(
        account: WebDavAccount,
        identity: WebDavIdentity? = nil,
        session: URLSession = .shared
    ) throws {
        try account.validate()
        try identity?.validate()
        self.account = account
        self.identity = identity
        self.session = session
        self.baseURL = account.endpoint
        self.retryDelaysNanoseconds = Self.defaultRetryDelaysNanoseconds
        self.retrySleep = { try await Task.sleep(nanoseconds: $0) }
    }

    public convenience init(credentials: WebDavCredentials, session: URLSession = .shared) throws {
        try credentials.validate()
        try self.init(
            account: credentials.account,
            identity: credentials.identity,
            session: session
        )
    }

    internal convenience init(
        credentials: WebDavCredentials,
        session: URLSession,
        retryDelaysNanoseconds: [UInt64],
        retrySleep: @escaping RetrySleep
    ) throws {
        try credentials.validate()
        try self.init(
            account: credentials.account,
            identity: credentials.identity,
            session: session,
            retryDelaysNanoseconds: retryDelaysNanoseconds,
            retrySleep: retrySleep
        )
    }

    internal init(
        account: WebDavAccount,
        identity: WebDavIdentity? = nil,
        session: URLSession,
        retryDelaysNanoseconds: [UInt64],
        retrySleep: @escaping RetrySleep
    ) throws {
        try account.validate()
        try identity?.validate()
        self.account = account
        self.identity = identity
        self.session = session
        self.baseURL = account.endpoint
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
        self.retrySleep = retrySleep
    }

    private var vaultId: String {
        get throws {
            guard let identity else { throw WebDavError.invalidCredentials }
            return identity.vaultId
        }
    }

    public func ensureCollections() async throws {
        let vaultId = try vaultId
        for path in [
            ["v1"],
            ["v1", vaultId],
            ["v1", vaultId, "ops"],
        ] {
            _ = try await request(method: "MKCOL", path: path, body: nil, headers: [:], accepted: [201, 405, 409])
        }
    }

    public func put(_ operation: WebDavOperation) async throws {
        let vaultId = try vaultId
        guard operation.vaultId == vaultId else {
            throw WebDavError.malformedObject("同步空间不匹配")
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(operation)
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
        let path = WebDavOperation.path(vaultId: vaultId, opId: operation.opId)
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
        let vaultId = try vaultId
        let root = ["v1", vaultId, "ops"]
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

    public func listOperations() async throws -> [WebDavOperation] {
        let paths = try await listOperationPaths()
        return try await listOperations(at: paths)
    }

    internal func listOperations(at paths: [[String]]) async throws -> [WebDavOperation] {
        try await listOperationsReportingSkipped(at: paths).operations
    }

    /// 逐个读取远端操作：单条 JSON/元数据损坏时记录其 opId 并跳过，
    /// 网络与认证错误仍然抛出，避免一个坏对象阻塞整批同步。
    internal func listOperationsReportingSkipped(
        at paths: [[String]]
    ) async throws -> (operations: [WebDavOperation], skippedOpIDs: [String]) {
        let vaultId = try vaultId
        var operations: [WebDavOperation] = []
        var skippedOpIDs: [String] = []
        for path in paths {
            let operationID = path.last
                .map { String($0.dropLast(".json".count)) } ?? ""
            let data: Data
            do {
                data = try await get(path: path)
            } catch WebDavError.http(404) {
                // 列举后文件被删除：本轮跳过，不写入已处理记录。
                continue
            }
            do {
                let operation = try JSONDecoder().decode(WebDavOperation.self, from: data)
                guard operation.vaultId == vaultId else {
                    throw WebDavError.malformedObject("同步空间不匹配")
                }
                guard path == WebDavOperation.path(
                    vaultId: operation.vaultId,
                    opId: operation.opId
                ) else {
                    throw WebDavError.malformedObject("对象路径与 opId 不匹配")
                }
                operations.append(operation)
            } catch {
                if !operationID.isEmpty {
                    skippedOpIDs.append(operationID)
                }
            }
        }
        return (operations, skippedOpIDs)
    }

    public func maximumLamport() async throws -> Int64 {
        let paths = try await listOperationPaths()
        let report = try await listOperationsReportingSkipped(at: paths)
        return report.operations.map(\.lamport).max() ?? 0
    }

    // MARK: - WebDAV 配对文件

    public func ensurePairingDirectory() async throws {
        for path in [
            ["v1"],
            ["v1", "pairing"],
        ] {
            _ = try await request(
                method: "MKCOL",
                path: path,
                body: nil,
                headers: [:],
                accepted: [201, 405, 409]
            )
        }
    }

    public func listPairingFileNames() async throws -> [String] {
        let root = ["v1", "pairing"]
        let paths = try await propfind(path: root, depth: 1)
        var names: [String] = []
        for path in paths where path.count == root.count + 1 {
            guard let name = path.last,
                  WebDavPairingFileName.parse(name) != nil else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    public func readPairingFile(name: String) async throws -> Data {
        try await get(path: ["v1", "pairing", name])
    }

    public func writePairingFile(name: String, data: Data) async throws {
        _ = try await request(
            method: "MKCOL",
            path: ["v1", "pairing"],
            body: nil,
            headers: [:],
            accepted: [201, 405, 409]
        )
        let path = ["v1", "pairing", name]
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

    public func deletePairingFile(name: String) async throws {
        _ = try await request(
            method: "DELETE",
            path: ["v1", "pairing", name],
            body: nil,
            headers: [:],
            accepted: [200, 202, 204, 404]
        )
    }

    private func propfind(path: [String], depth: Int) async throws -> [[String]] {
        let response = try await request(
            method: "PROPFIND",
            path: path,
            body: Data("<?xml version=\"1.0\" encoding=\"utf-8\" ?><propfind xmlns=\"DAV:\"><prop><resourcetype/></prop></propfind>".utf8),
            headers: ["Depth": String(depth), "Content-Type": "application/xml"],
            accepted: [207]
        )
        return try WebDavHrefParser.parse(response.data, baseURL: baseURL)
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
        request.setValue(
            "Basic \(Data("\(account.username):\(account.appPassword)".utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        var retryIndex = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(
                    for: request,
                    delegate: WebDavRedirectBlocker.shared
                )
                guard let http = response as? HTTPURLResponse else {
                    throw WebDavError.invalidResponse
                }
                if accepted.contains(http.statusCode) {
                    return (data, http.statusCode)
                }
                guard Self.retryableHTTPStatuses.contains(http.statusCode),
                      retryIndex < retryDelaysNanoseconds.count else {
                    throw WebDavError.http(http.statusCode)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled {
                    throw CancellationError()
                }
                guard Self.retryableURLErrorCodes.contains(error.code),
                      retryIndex < retryDelaysNanoseconds.count else {
                    throw WebDavError.transport(error.localizedDescription)
                }
            } catch let error as WebDavError {
                throw error
            } catch {
                guard retryIndex < retryDelaysNanoseconds.count else {
                    throw WebDavError.transport(error.localizedDescription)
                }
            }
            let delay = retryDelaysNanoseconds[retryIndex]
            retryIndex += 1
            try await retrySleep(delay)
        }
    }
}

private final class WebDavRedirectBlocker: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
    static let shared = WebDavRedirectBlocker()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
        guard let identity = client.identity else {
            throw WebDavError.invalidCredentials
        }
        try await client.ensureCollections()
        let pending = try await outbox.pendingOperations(limit: SyncCoordinator.maximumPushBatch)
        for operation in pending {
            try await client.put(WebDavOperation(
                vaultId: identity.vaultId,
                deviceId: identity.deviceId,
                operation: operation
            ))
        }

        let paths = try await client.listOperationPaths()
        let operationIDs = paths.compactMap(Self.operationID(from:))
        guard operationIDs.count == paths.count else {
            throw WebDavError.malformedObject("对象路径缺少有效的 opId")
        }
        let pendingIDs = try await local.pendingWebDavOperationIDs(operationIDs)
        let pendingPaths = zip(paths, operationIDs).compactMap { path, operationID in
            pendingIDs.contains(operationID) ? path : nil
        }
        let report = try await client.listOperationsReportingSkipped(at: pendingPaths)
        if !report.skippedOpIDs.isEmpty {
            // 坏对象按 opId 记为已处理，避免每次同步都重试并永久失败。
            try await local.skipWebDavOperations(opIds: report.skippedOpIDs)
        }
        let operations = report.operations
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

    private static func operationID(from path: [String]) -> String? {
        guard let fileName = path.last,
              fileName.hasSuffix(".json"),
              fileName.count > ".json".count else { return nil }
        return String(fileName.dropLast(".json".count))
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

    static func parse(_ data: Data, baseURL: URL) throws -> [[String]] {
        let parser = WebDavHrefParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw WebDavError.malformedObject("PROPFIND XML 无法解析") }
        let baseParts = try pathSegments(of: baseURL)
        var paths: [[String]] = []
        for raw in parser.values {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  hasValidPercentEncoding(value),
                  let components = URLComponents(string: value),
                  !components.percentEncodedPath.isEmpty else {
                throw WebDavError.malformedObject("PROPFIND href 无效")
            }
            let parts = try pathSegments(of: components.percentEncodedPath)
            let isRelativePath = components.scheme == nil
                && components.host == nil
                && !components.percentEncodedPath.hasPrefix("/")
            if isRelativePath {
                guard parts.first == "v1" else { continue }
                paths.append(parts)
                continue
            }
            guard parts.starts(with: baseParts) else { continue }
            let relative = Array(parts.dropFirst(baseParts.count))
            guard relative.first == "v1" else { continue }
            paths.append(relative)
        }
        return paths
    }

    private static func pathSegments(of url: URL) throws -> [String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WebDavError.invalidEndpoint
        }
        return try pathSegments(of: components.percentEncodedPath)
    }

    private static func hasValidPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x25 else {
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  bytes[index + 1].isASCIIHexDigit,
                  bytes[index + 2].isASCIIHexDigit else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func pathSegments(of encodedPath: String) throws -> [String] {
        try encodedPath.split(separator: "/").map { segment in
            guard let decoded = String(segment).removingPercentEncoding,
                  decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\") else {
                throw WebDavError.malformedObject("PROPFIND href 无效")
            }
            return decoded
        }
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

private extension UInt8 {
    var isASCIIHexDigit: Bool {
        (0x30...0x39).contains(self)
            || (0x41...0x46).contains(self)
            || (0x61...0x66).contains(self)
    }
}
