import Foundation
import OSLog

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

/// 新账号自动使用的专属目录，避免和同一 WebDAV 账号下的其他应用混用。
public enum WebDavStorageLayout {
    public static let appFolder = "WooTodo"

    public static func isAppFolder(_ endpoint: URL) -> Bool {
        let normalized = endpoint.absoluteString.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return normalized.split(separator: "/").last?
            .caseInsensitiveCompare(appFolder) == .orderedSame
    }

    public static func appendingAppFolder(to endpoint: URL) -> URL {
        endpoint.appendingPathComponent(appFolder)
    }

    /**
     新账号落到 `<地址>/WooTodo`；已有空间的旧目录保持不变。
     先看专属目录，再看旧目录，避免同一个账号下同时存在两种布局时误判。
     */
    @MainActor
    public static func resolveEndpoint(
        _ endpoint: URL,
        vaultId: String?,
        hasVaultAt: (URL) async throws -> Bool,
        hasPairingAt: (URL) async throws -> Bool
    ) async rethrows -> URL {
        if isAppFolder(endpoint) { return endpoint }
        let namespaced = appendingAppFolder(to: endpoint)
        if let vaultId {
            if try await hasVaultAt(namespaced) { return namespaced }
            if try await hasVaultAt(endpoint) { return endpoint }
            return namespaced
        }
        if try await hasPairingAt(namespaced) { return namespaced }
        if try await hasPairingAt(endpoint) { return endpoint }
        return namespaced
    }
}

/// MKCOL 结果缓存；目录创建成功一次后，同一客户端不再重复请求。
private actor EnsuredCollectionCache {
    private var values: Set<String> = []

    func contains(_ key: String) -> Bool { values.contains(key) }

    func insert(_ key: String) { values.insert(key) }

    func removeAll() { values.removeAll() }
}

public final class WebDavClient: WebDavPairingFileTransport, @unchecked Sendable {
    internal typealias RetrySleep = @Sendable (UInt64) async throws -> Void

    public let account: WebDavAccount
    public let identity: WebDavIdentity?
    private let session: URLSession
    private let baseURL: URL
    private let retryDelaysNanoseconds: [UInt64]
    private let retrySleep: RetrySleep
    private let ensuredCollections = EnsuredCollectionCache()

    private static let deviceLogger = Logger(
        subsystem: "io.github.stophemo.woo-todo",
        category: "跨设备"
    )
    /// 第三方 WebDAV 服务常有并发限制：探测与拉取都用小窗口并发，既缩短首次同步又避免被限流。
    internal static let fetchParallelism = 4

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
            try await ensureCollection(path)
        }
    }

    /// MKCOL 成功一次后记住结果；同一客户端后续请求不再重复建目录。
    private func ensureCollection(_ path: [String]) async throws {
        let key = path.joined(separator: "/")
        if await ensuredCollections.contains(key) { return }
        _ = try await request(
            method: "MKCOL",
            path: path,
            body: nil,
            headers: [:],
            accepted: [201, 405, 409]
        )
        await ensuredCollections.insert(key)
    }

    /// 远端目录被删除后，下一轮重新 MKCOL，而不是永久失败。
    private func invalidateEnsuredCollections() async {
        await ensuredCollections.removeAll()
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
        try await ensureCollection(Array(path.dropLast()))
        let result: (data: Data, statusCode: Int)
        do {
            result = try await request(
                method: "PUT",
                path: path,
                body: data,
                headers: ["Content-Type": "application/json", "If-None-Match": "*"],
                accepted: [200, 201, 204, 405, 409, 412]
            )
        } catch WebDavError.http(let status) where status == 404 || status == 409 {
            // 目录可能被远端删除：丢弃缓存，下一轮重新创建。
            await invalidateEnsuredCollections()
            throw WebDavError.http(status)
        }
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
        let sortedShards = Set(shards).sorted()
        var result: [[String]] = []
        var index = 0
        while index < sortedShards.count {
            let end = min(index + Self.fetchParallelism, sortedShards.count)
            let chunk = Array(sortedShards[index..<end])
            let listings = try await withThrowingTaskGroup(
                of: (Int, [[String]]).self
            ) { group in
                for (offset, shard) in chunk.enumerated() {
                    group.addTask {
                        (offset, try await self.propfind(path: root + [shard], depth: 1))
                    }
                }
                var items = [[[String]]](repeating: [], count: chunk.count)
                for try await (offset, paths) in group {
                    items[offset] = paths
                }
                return items
            }
            for paths in listings {
                result.append(contentsOf: paths.filter { path in
                    path.count == root.count + 2 && path.last?.hasSuffix(".json") == true
                })
            }
            index = end
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
        var index = 0
        while index < paths.count {
            let end = min(index + Self.fetchParallelism, paths.count)
            let chunk = Array(paths[index..<end])
            // 小窗口并发 GET，结果按原路径顺序合并，保持应用顺序稳定。
            let datas = try await withThrowingTaskGroup(
                of: (Int, Data?).self
            ) { group in
                for (offset, path) in chunk.enumerated() {
                    group.addTask {
                        do {
                            return (offset, try await self.get(path: path))
                        } catch WebDavError.http(404) {
                            // 列举后文件被删除：本轮跳过，不写入已处理记录。
                            return (offset, nil)
                        }
                    }
                }
                var items = [Data?](repeating: nil, count: chunk.count)
                for try await (offset, data) in group {
                    items[offset] = data
                }
                return items
            }
            for (offset, data) in datas.enumerated() {
                guard let data else { continue }
                let path = chunk[offset]
                let operationID = path.last
                    .map { String($0.dropLast(".json".count)) } ?? ""
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
            index = end
        }
        return (operations, skippedOpIDs)
    }


    /// 只探测不创建，用于判断账号根目录或专属目录是否已经有同步数据。
    public func hasPairingDirectory() async throws -> Bool {
        try await directoryExists(["v1", "pairing"])
    }

    public func hasVaultDirectory(vaultId: String) async throws -> Bool {
        try await directoryExists(["v1", vaultId])
    }

    private func directoryExists(_ path: [String]) async throws -> Bool {
        do {
            _ = try await propfind(path: path, depth: 0)
            return true
        } catch WebDavError.http(let status) where [403, 404, 409].contains(status) {
            return false
        }
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

    // MARK: - WebDAV 设备心跳

    /// 设备目录不参与任务同步，只在写入心跳时按需创建。
    public func ensureDeviceCollection() async throws {
        let vaultId = try vaultId
        _ = try await request(
            method: "MKCOL",
            path: ["v1", vaultId, "devices"],
            body: nil,
            headers: [:],
            accepted: [201, 405, 409]
        )
    }

    /// PUT 覆盖本机自己的 `<deviceId>.json`，不写其他设备。
    public func putDeviceHeartbeat(_ heartbeat: WebDavDeviceHeartbeat) async throws {
        guard let identity else { throw WebDavError.invalidCredentials }
        let envelope = try WebDavDeviceHeartbeatCodec.seal(
            heartbeat,
            vaultId: identity.vaultId,
            deviceId: identity.deviceId,
            vaultKey: identity.vaultKey
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(envelope)
        } catch {
            throw WebDavError.encoding(error.localizedDescription)
        }
        try await ensureDeviceCollection()
        _ = try await request(
            method: "PUT",
            path: WebDavDeviceHeartbeatEnvelope.path(
                vaultId: identity.vaultId,
                deviceId: identity.deviceId
            ),
            body: data,
            headers: ["Content-Type": "application/json"],
            accepted: [200, 201, 204]
        )
    }

    /// 列举并解密设备心跳。单个坏文件或未知版本只跳过并记录，不删除。
    public func listDevices() async throws -> [WebDavDevice] {
        guard let identity else { throw WebDavError.invalidCredentials }
        let root = ["v1", identity.vaultId, "devices"]
        let paths: [[String]]
        do {
            paths = try await propfind(path: root, depth: 1)
        } catch WebDavError.http(404) {
            return []
        }
        var devices: [WebDavDevice] = []
        for path in paths {
            guard path.count == root.count + 1,
                  let fileName = path.last,
                  fileName.hasSuffix(".json") else { continue }
            let deviceId = String(fileName.dropLast(".json".count))
            guard WebDavDeviceIdentifier.isValid(deviceId) else { continue }
            let data: Data
            do {
                data = try await get(path: path)
            } catch WebDavError.http(404) {
                // 列举后文件被删除：跳过。
                continue
            }
            do {
                let envelope = try JSONDecoder().decode(
                    WebDavDeviceHeartbeatEnvelope.self,
                    from: data
                )
                guard envelope.deviceId == deviceId,
                      path == WebDavDeviceHeartbeatEnvelope.path(
                        vaultId: identity.vaultId,
                        deviceId: deviceId
                      ) else {
                    throw WebDavError.malformedObject("设备心跳文件名与 deviceId 不匹配")
                }
                let heartbeat = try WebDavDeviceHeartbeatCodec.open(
                    envelope,
                    vaultId: identity.vaultId,
                    vaultKey: identity.vaultKey
                )
                devices.append(WebDavDevice(
                    deviceId: deviceId,
                    name: heartbeat.name,
                    platform: heartbeat.platform,
                    lastSeenAt: heartbeat.lastSeenDate,
                    appVersion: heartbeat.appVersion
                ))
            } catch {
                Self.deviceLogger.notice(
                    "跳过无法解析的 WebDAV 设备心跳：\(path.joined(separator: "/"), privacy: .public)"
                )
                continue
            }
        }
        return devices.sorted {
            if $0.lastSeenAt != $1.lastSeenAt {
                return $0.lastSeenAt > $1.lastSeenAt
            }
            return $0.deviceId < $1.deviceId
        }
    }

    /// 退出空间时尽力删除自己的心跳；删除失败不会阻止本地退出。
    public func deleteOwnDeviceHeartbeat() async throws {
        guard let identity else { throw WebDavError.invalidCredentials }
        _ = try await request(
            method: "DELETE",
            path: WebDavDeviceHeartbeatEnvelope.path(
                vaultId: identity.vaultId,
                deviceId: identity.deviceId
            ),
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

        // 单轮最多推送 200 项；每批上传成功就确认，下一批失败不会重复上传。
        var pushed = 0
        var hasBacklog = false
        while pushed < Self.maximumPushOpsPerRun {
            try Task.checkCancellation()
            let remaining = Self.maximumPushOpsPerRun - pushed
            let pending = try await outbox.pendingOperations(
                limit: min(Self.pushBatchSize, remaining)
            )
            guard !pending.isEmpty else { break }
            for operation in pending {
                try await client.put(WebDavOperation(
                    vaultId: identity.vaultId,
                    deviceId: identity.deviceId,
                    operation: operation
                ))
            }
            try await outbox.acknowledgeOperations(opIds: pending.map(\.opId))
            pushed += pending.count
            if pushed >= Self.maximumPushOpsPerRun {
                let leftover = try await outbox.pendingOperations(limit: 1)
                hasBacklog = !leftover.isEmpty
            }
            if pending.count < Self.pushBatchSize { break }
        }

        // 有积压时只推不拉：先把本机改动送上去，下一轮立即继续，避免首次同步被大历史拖住。
        if hasBacklog {
            return SyncRunSummary(
                pushed: pushed,
                pulled: 0,
                pages: 1,
                finalCursor: 0,
                moreWork: true
            )
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
        return SyncRunSummary(
            pushed: pushed,
            pulled: operations.count,
            pages: Self.webDavPageCount(operations.count),
            finalCursor: 0
        )
    }

    /// 与 Android 保持一致：单轮最多 200 项、每批 50 项。
    internal static let maximumPushOpsPerRun = 200
    internal static let pushBatchSize = SyncCoordinator.maximumPushBatch
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
