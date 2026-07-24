import CryptoKit
import Darwin
import Foundation
import Network

public enum LocalNetworkSyncConstants {
    public static let defaultPort: UInt16 = 48_473
    public static let bonjourServiceType = "_wootodo._tcp"
    public static let pairingLifetimeMilliseconds: Int64 = 10 * 60 * 1_000
}

public struct LocalSyncHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method.uppercased()
        self.path = path
        self.headers = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }
        )
        self.body = body
    }
}

public struct LocalSyncHTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum LocalSyncServerError: Error, LocalizedError, Equatable {
    case invalidBootstrapIdentity
    case identityMismatch
    case corruptedState
    case cannotResolveEndpoint
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBootstrapIdentity:
            "局域网同步身份无效"
        case .identityMismatch:
            "局域网主机数据与当前同步身份不一致"
        case .corruptedState:
            "局域网同步主机数据已损坏"
        case .cannotResolveEndpoint:
            "无法获取手机可访问的 Mac 局域网地址"
        case .listenerFailed(let message):
            "局域网同步服务启动失败：\(message)"
        }
    }
}

private struct LocalSyncPersistedState: Codable {
    static let currentVersion = 1

    var version: Int
    var vaultId: String
    var nextServerSequence: Int64
    var devices: [LocalSyncStoredDevice]
    var operations: [SyncPulledOperation]
}

private struct LocalSyncStoredDevice: Codable {
    let id: String
    let name: String
    let platform: DevicePlatform
    let publicKey: String?
    let tokenHash: String
    let createdAt: Int64
    var lastSeenAt: Int64?
    var revokedAt: Int64?
}

private struct LocalSyncPairingSession {
    let id: String
    let secretHash: String
    let initiatorDeviceId: String
    let initiatorPublicKey: String
    let createdAt: Int64
    let expiresAt: Int64
    var claimedDevice: LocalSyncClaimedDevice?
    var confirmedEnvelope: EncryptedEnvelope?
}

private struct LocalSyncClaimedDevice {
    let id: String
    let name: String
    let platform: DevicePlatform
    let publicKey: String
    let tokenHash: String
    let claimedAt: Int64
}

private struct LocalSyncSuccessEnvelope<Value: Encodable>: Encodable {
    let ok = true
    let data: Value
    let requestId: String
}

private struct LocalSyncFailureEnvelope: Encodable {
    let ok = false
    let error: ServerErrorPayload
    let requestId: String
}

private struct LocalSyncPairingResultResponse: Encodable {
    let pairingId: String
    let status: PairingStatus
    let vaultId: String?
    let deviceId: String?
    let initiatorPublicKey: String?
    let vaultKeyEnvelope: EncryptedEnvelope?
    let expiresAt: Int64
}

private struct LocalSyncHealthResponse: Encodable {
    let version = 1
    let service = "woo-todo-local-sync"
}

private struct LocalSyncServiceFailure: Error {
    let statusCode: Int
    let code: String
    let message: String
    let details: [String: JSONValue]?

    init(
        _ statusCode: Int,
        _ code: String,
        _ message: String,
        details: [String: JSONValue]? = nil
    ) {
        self.statusCode = statusCode
        self.code = code
        self.message = message
        self.details = details
    }
}

public actor LocalSyncServerStore {
    private static let maximumBodyBytes = 3 * 1_024 * 1_024
    private static let maximumDeviceNameCharacters = 80
    private static let maximumOperations = 50
    private static let maximumPullOperations = 100

    private let fileURL: URL
    private let now: @Sendable () -> Int64
    private var state: LocalSyncPersistedState
    private var pairings: [String: LocalSyncPairingSession] = [:]

    public init(
        fileURL: URL,
        bootstrapCredentials: SyncCredentials,
        now: @escaping @Sendable () -> Int64 = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded())
        }
    ) throws {
        do {
            try bootstrapCredentials.validate()
        } catch {
            throw LocalSyncServerError.invalidBootstrapIdentity
        }
        self.fileURL = fileURL
        self.now = now

        let tokenHash = Self.credentialHash(bootstrapCredentials.deviceToken)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL),
                  let loaded = try? JSONDecoder().decode(LocalSyncPersistedState.self, from: data),
                  loaded.version == LocalSyncPersistedState.currentVersion,
                  loaded.nextServerSequence >= 1,
                  loaded.operations.allSatisfy({ $0.serverSeq >= 1 }),
                  Set(loaded.operations.map(\.opId)).count == loaded.operations.count else {
                throw LocalSyncServerError.corruptedState
            }
            let maximumSequence = loaded.operations.map(\.serverSeq).max() ?? 0
            guard loaded.nextServerSequence > maximumSequence else {
                throw LocalSyncServerError.corruptedState
            }
            guard loaded.vaultId == bootstrapCredentials.vaultId,
                  loaded.devices.contains(where: {
                      $0.id == bootstrapCredentials.deviceId &&
                          $0.tokenHash == tokenHash && $0.revokedAt == nil
                  }) else {
                throw LocalSyncServerError.identityMismatch
            }
            self.state = loaded
        } else {
            let timestamp = now()
            let initial = LocalSyncPersistedState(
                version: LocalSyncPersistedState.currentVersion,
                vaultId: bootstrapCredentials.vaultId,
                nextServerSequence: 1,
                devices: [LocalSyncStoredDevice(
                    id: bootstrapCredentials.deviceId,
                    name: Host.current().localizedName ?? "Mac",
                    platform: .macos,
                    publicKey: nil,
                    tokenHash: tokenHash,
                    createdAt: timestamp,
                    lastSeenAt: timestamp,
                    revokedAt: nil
                )],
                operations: []
            )
            try Self.persist(initial, to: fileURL)
            self.state = initial
        }
    }

    public func handle(_ request: LocalSyncHTTPRequest) -> LocalSyncHTTPResponse {
        let requestId = UUID().uuidString.lowercased()
        guard request.body.count <= Self.maximumBodyBytes else {
            return failure(
                LocalSyncServiceFailure(413, "PAYLOAD_TOO_LARGE", "请求体超过局域网同步上限"),
                requestId: requestId
            )
        }
        do {
            return try route(request, requestId: requestId)
        } catch let error as LocalSyncServiceFailure {
            return failure(error, requestId: requestId)
        } catch {
            return failure(
                LocalSyncServiceFailure(500, "INTERNAL_ERROR", "局域网同步服务发生未预期错误"),
                requestId: requestId
            )
        }
    }

    private func route(
        _ request: LocalSyncHTTPRequest,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        guard !request.path.contains("?"), !request.path.contains("#") else {
            throw LocalSyncServiceFailure(400, "INVALID_PATH", "请求路径无效")
        }
        let normalizedPath = request.path.count > 1 && request.path.hasSuffix("/")
            ? String(request.path.dropLast())
            : request.path
        let components = normalizedPath.split(separator: "/").map(String.init)

        if components == ["health"] {
            try requireMethod(request, "GET")
            return try success(LocalSyncHealthResponse(), requestId: requestId)
        }
        if components == ["v1", "pairings"] {
            try requireMethod(request, "POST")
            let initiator = try authenticate(request)
            return try createPairing(request, initiator: initiator, requestId: requestId)
        }
        if components == ["v1", "sync"] {
            try requireMethod(request, "POST")
            let device = try authenticate(request)
            return try synchronize(request, device: device, requestId: requestId)
        }
        if components == ["v1", "devices"] {
            try requireMethod(request, "GET")
            let device = try authenticate(request)
            return try listDevices(currentDevice: device, requestId: requestId)
        }
        if components.count == 3, components[0] == "v1", components[1] == "pairings" {
            try requireMethod(request, "GET")
            let device = try authenticate(request)
            return try pairingStatus(
                id: components[2],
                initiator: device,
                requestId: requestId
            )
        }
        if components.count == 4, components[0] == "v1", components[1] == "pairings" {
            try requireMethod(request, "POST")
            switch components[3] {
            case "claim":
                return try claimPairing(request, id: components[2], requestId: requestId)
            case "confirm":
                let device = try authenticate(request)
                return try confirmPairing(
                    request,
                    id: components[2],
                    initiator: device,
                    requestId: requestId
                )
            case "result":
                return try pairingResult(request, id: components[2], requestId: requestId)
            default:
                break
            }
        }
        if components.count == 4,
           components[0] == "v1", components[1] == "devices", components[3] == "revoke" {
            try requireMethod(request, "POST")
            let device = try authenticate(request)
            return try revokeDevice(
                id: components[2],
                currentDevice: device,
                requestId: requestId
            )
        }
        throw LocalSyncServiceFailure(404, "NOT_FOUND", "请求的资源不存在")
    }

    private func createPairing(
        _ request: LocalSyncHTTPRequest,
        initiator: LocalSyncStoredDevice,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        let input: CreatePairingRequest = try decode(request.body)
        guard isValidKey(input.publicKey) else {
            throw validation("publicKey", "临时公钥必须是 32 字节 Base64URL")
        }
        expirePairings()
        let timestamp = now()
        let pairingId = "pair-\(UUID().uuidString.lowercased())"
        let secret = Base64URL.encode(try SecureRandom.bytes(count: 32))
        let session = LocalSyncPairingSession(
            id: pairingId,
            secretHash: Self.credentialHash(secret),
            initiatorDeviceId: initiator.id,
            initiatorPublicKey: input.publicKey,
            createdAt: timestamp,
            expiresAt: timestamp + LocalNetworkSyncConstants.pairingLifetimeMilliseconds,
            claimedDevice: nil,
            confirmedEnvelope: nil
        )
        pairings[pairingId] = session
        let data = CreatePairingData(
            pairingId: pairingId,
            pairingSecret: secret,
            initiatorPublicKey: input.publicKey,
            expiresAt: session.expiresAt,
            serverTime: timestamp
        )
        return try success(data, requestId: requestId, statusCode: 201)
    }

    private func pairingStatus(
        id: String,
        initiator: LocalSyncStoredDevice,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        let session = try activePairing(id)
        guard session.initiatorDeviceId == initiator.id else {
            throw LocalSyncServiceFailure(404, "PAIRING_NOT_FOUND", "配对会话不存在")
        }
        let status: PairingStatus
        if session.confirmedEnvelope != nil {
            status = .confirmed
        } else if session.claimedDevice != nil {
            status = .claimed
        } else {
            status = .open
        }
        let claim = session.claimedDevice.map {
            PairingClaimInfo(
                deviceId: $0.id,
                name: $0.name,
                platform: $0.platform,
                publicKey: $0.publicKey,
                claimedAt: $0.claimedAt
            )
        }
        return try success(
            PairingStatusData(
                pairingId: id,
                status: status,
                expiresAt: session.expiresAt,
                claim: claim
            ),
            requestId: requestId
        )
    }

    private func claimPairing(
        _ request: LocalSyncHTTPRequest,
        id: String,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        let input: PairingClaimRequest = try decode(request.body)
        var session = try activePairing(id)
        guard Self.matches(input.pairingSecret, hash: session.secretHash) else {
            throw LocalSyncServiceFailure(404, "PAIRING_NOT_FOUND", "配对会话或一次性凭据无效")
        }
        guard isValidToken(input.deviceToken) else {
            throw validation("deviceToken", "设备令牌必须是 32 字节 Base64URL")
        }
        guard isValidKey(input.device.publicKey) else {
            throw validation("device.publicKey", "临时公钥必须是 32 字节 Base64URL")
        }
        let name = input.device.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.maximumDeviceNameCharacters else {
            throw validation("device.name", "设备名称长度无效")
        }

        let tokenHash = Self.credentialHash(input.deviceToken)
        if let claimed = session.claimedDevice {
            guard claimed.tokenHash == tokenHash,
                  claimed.publicKey == input.device.publicKey,
                  claimed.name == name,
                  claimed.platform == input.device.platform else {
                throw LocalSyncServiceFailure(409, "PAIRING_ALREADY_CLAIMED", "配对会话已被其他设备认领")
            }
            return try success(
                PairingClaimData(
                    pairingId: id,
                    status: .claimed,
                    deviceId: claimed.id,
                    expiresAt: session.expiresAt
                ),
                requestId: requestId,
                statusCode: 202
            )
        }

        let claimed = LocalSyncClaimedDevice(
            id: UUID().uuidString.lowercased(),
            name: name,
            platform: input.device.platform,
            publicKey: input.device.publicKey,
            tokenHash: tokenHash,
            claimedAt: now()
        )
        session.claimedDevice = claimed
        pairings[id] = session
        return try success(
            PairingClaimData(
                pairingId: id,
                status: .claimed,
                deviceId: claimed.id,
                expiresAt: session.expiresAt
            ),
            requestId: requestId,
            statusCode: 202
        )
    }

    private func confirmPairing(
        _ request: LocalSyncHTTPRequest,
        id: String,
        initiator: LocalSyncStoredDevice,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        let input: PairingConfirmRequest = try decode(request.body)
        var session = try activePairing(id)
        guard session.initiatorDeviceId == initiator.id else {
            throw LocalSyncServiceFailure(404, "PAIRING_NOT_FOUND", "配对会话不存在")
        }
        guard let claimed = session.claimedDevice else {
            throw LocalSyncServiceFailure(409, "PAIRING_NOT_CLAIMED", "尚无设备认领此配对会话")
        }
        guard isValidEnvelope(input.vaultKeyEnvelope) else {
            throw validation("vaultKeyEnvelope", "同步密钥密文格式无效")
        }

        if let existingEnvelope = session.confirmedEnvelope {
            guard existingEnvelope == input.vaultKeyEnvelope else {
                throw LocalSyncServiceFailure(409, "PAIRING_ALREADY_CONFIRMED", "配对会话已使用其他密文确认")
            }
        } else {
            session.confirmedEnvelope = input.vaultKeyEnvelope
            if !state.devices.contains(where: { $0.id == claimed.id }) {
                var updatedState = state
                updatedState.devices.append(LocalSyncStoredDevice(
                    id: claimed.id,
                    name: claimed.name,
                    platform: claimed.platform,
                    publicKey: claimed.publicKey,
                    tokenHash: claimed.tokenHash,
                    createdAt: claimed.claimedAt,
                    lastSeenAt: nil,
                    revokedAt: nil
                ))
                try persist(updatedState)
                state = updatedState
            }
            pairings[id] = session
        }
        return try success(
            PairingConfirmData(pairingId: id, status: .confirmed, deviceId: claimed.id),
            requestId: requestId
        )
    }

    private func pairingResult(
        _ request: LocalSyncHTTPRequest,
        id: String,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        let input: PairingResultRequest = try decode(request.body)
        let session = try activePairing(id)
        guard Self.matches(input.pairingSecret, hash: session.secretHash),
              let claimed = session.claimedDevice,
              Self.matches(input.deviceToken, hash: claimed.tokenHash) else {
            throw LocalSyncServiceFailure(404, "PAIRING_NOT_FOUND", "配对会话或新设备凭据无效")
        }
        if let envelope = session.confirmedEnvelope {
            return try success(
                LocalSyncPairingResultResponse(
                    pairingId: id,
                    status: .confirmed,
                    vaultId: state.vaultId,
                    deviceId: claimed.id,
                    initiatorPublicKey: session.initiatorPublicKey,
                    vaultKeyEnvelope: envelope,
                    expiresAt: session.expiresAt
                ),
                requestId: requestId
            )
        }
        return try success(
            LocalSyncPairingResultResponse(
                pairingId: id,
                status: .claimed,
                vaultId: nil,
                deviceId: nil,
                initiatorPublicKey: nil,
                vaultKeyEnvelope: nil,
                expiresAt: session.expiresAt
            ),
            requestId: requestId,
            statusCode: 202
        )
    }

    private func synchronize(
        _ request: LocalSyncHTTPRequest,
        device: LocalSyncStoredDevice,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        let input: SyncRequest = try decode(request.body)
        let pullLimit = input.pullLimit ?? Self.maximumPullOperations
        guard input.cursor >= 0,
              input.ack.map({ $0 >= 0 && $0 <= input.cursor }) ?? true,
              (1...Self.maximumPullOperations).contains(pullLimit),
              input.push.count <= Self.maximumOperations else {
            throw validation("sync", "同步游标、分页或批次大小无效")
        }
        let maximumCursor = state.operations.last?.serverSeq ?? 0
        guard input.cursor <= maximumCursor else {
            throw LocalSyncServiceFailure(
                409,
                "CURSOR_AHEAD",
                "客户端游标超过服务端最新序号",
                details: [
                    "cursor": .number(Double(input.cursor)),
                    "maxCursor": .number(Double(maximumCursor)),
                ]
            )
        }
        try validatePush(input.push)

        let originalState = state
        var updatedState = state
        var inserted = 0
        let timestamp = now()
        for operation in input.push {
            if updatedState.operations.contains(where: { $0.opId == operation.opId }) {
                continue
            }
            updatedState.operations.append(SyncPulledOperation(
                serverSeq: updatedState.nextServerSequence,
                opId: operation.opId,
                deviceId: device.id,
                entityId: operation.entityId,
                kind: operation.kind,
                lamport: operation.lamport,
                ciphertext: operation.ciphertext,
                nonce: operation.nonce,
                createdAt: timestamp
            ))
            updatedState.nextServerSequence += 1
            inserted += 1
        }
        if let index = updatedState.devices.firstIndex(where: { $0.id == device.id }) {
            updatedState.devices[index].lastSeenAt = timestamp
        }
        do {
            try persist(updatedState)
        } catch {
            state = originalState
            throw error
        }
        state = updatedState

        let candidates = state.operations.filter { $0.serverSeq > input.cursor }
        let page = Array(candidates.prefix(pullLimit))
        let cursor = page.last?.serverSeq ?? input.cursor
        return try success(
            SyncData(
                push: SyncPushSummary(
                    received: input.push.count,
                    inserted: inserted,
                    duplicates: input.push.count - inserted
                ),
                pull: page,
                cursor: cursor,
                hasMore: candidates.count > page.count,
                serverTime: timestamp
            ),
            requestId: requestId
        )
    }

    private func listDevices(
        currentDevice: LocalSyncStoredDevice,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        let data = DeviceListData(devices: state.devices.map {
            DeviceInfo(
                id: $0.id,
                name: $0.name,
                platform: $0.platform,
                publicKey: $0.publicKey,
                createdAt: $0.createdAt,
                lastSeenAt: $0.lastSeenAt,
                revokedAt: $0.revokedAt,
                isCurrent: $0.id == currentDevice.id
            )
        })
        return try success(data, requestId: requestId)
    }

    private func revokeDevice(
        id: String,
        currentDevice: LocalSyncStoredDevice,
        requestId: String
    ) throws -> LocalSyncHTTPResponse {
        guard id != currentDevice.id else {
            throw LocalSyncServiceFailure(409, "CANNOT_REVOKE_SELF", "当前设备不能撤销自身")
        }
        guard let index = state.devices.firstIndex(where: { $0.id == id }) else {
            throw LocalSyncServiceFailure(404, "DEVICE_NOT_FOUND", "目标设备不存在")
        }
        let revokedAt: Int64
        if let existing = state.devices[index].revokedAt {
            revokedAt = existing
        } else {
            revokedAt = now()
            var updatedState = state
            updatedState.devices[index].revokedAt = revokedAt
            try persist(updatedState)
            state = updatedState
        }
        return try success(
            RevokeDeviceData(deviceId: id, revokedAt: revokedAt),
            requestId: requestId
        )
    }

    private func authenticate(_ request: LocalSyncHTTPRequest) throws -> LocalSyncStoredDevice {
        guard let authorization = request.headers["authorization"],
              authorization.hasPrefix("Bearer ") else {
            throw LocalSyncServiceFailure(401, "UNAUTHORIZED", "缺少设备认证凭据")
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard isValidToken(token) else {
            throw LocalSyncServiceFailure(401, "UNAUTHORIZED", "设备认证凭据无效")
        }
        let hash = Self.credentialHash(token)
        guard let device = state.devices.first(where: {
            $0.tokenHash == hash && $0.revokedAt == nil
        }) else {
            throw LocalSyncServiceFailure(401, "UNAUTHORIZED", "设备认证凭据无效或已撤销")
        }
        return device
    }

    private func validatePush(_ operations: [SyncPushOperation]) throws {
        var operationsById: [String: SyncPushOperation] = [:]
        for operation in operations {
            guard isValidIdentifier(operation.opId),
                  isValidIdentifier(operation.entityId),
                  operation.lamport >= 1,
                  isValidEnvelope(EncryptedEnvelope(
                      ciphertext: operation.ciphertext,
                      nonce: operation.nonce
                  )) else {
                throw validation("push", "同步操作字段或密文格式无效")
            }
            if let previous = operationsById[operation.opId], previous != operation {
                throw LocalSyncServiceFailure(
                    409,
                    "OP_ID_CONFLICT",
                    "同一 opId 对应了不同内容",
                    details: ["opId": .string(operation.opId)]
                )
            }
            operationsById[operation.opId] = operation
            if let stored = state.operations.first(where: { $0.opId == operation.opId }),
               !stored.matches(operation) {
                throw LocalSyncServiceFailure(
                    409,
                    "OP_ID_CONFLICT",
                    "opId 已存在且内容不同",
                    details: ["opId": .string(operation.opId)]
                )
            }
        }
    }

    private func activePairing(_ id: String) throws -> LocalSyncPairingSession {
        guard isValidIdentifier(id), let session = pairings[id] else {
            throw LocalSyncServiceFailure(404, "PAIRING_NOT_FOUND", "配对会话不存在")
        }
        guard session.expiresAt > now() else {
            pairings.removeValue(forKey: id)
            throw LocalSyncServiceFailure(410, "PAIRING_EXPIRED", "配对会话已过期")
        }
        return session
    }

    private func expirePairings() {
        let timestamp = now()
        pairings = pairings.filter { $0.value.expiresAt > timestamp }
    }

    private func requireMethod(_ request: LocalSyncHTTPRequest, _ method: String) throws {
        guard request.method == method else {
            throw LocalSyncServiceFailure(405, "METHOD_NOT_ALLOWED", "此资源不支持当前 HTTP 方法")
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw LocalSyncServiceFailure(400, "VALIDATION_ERROR", "请求 JSON 或字段格式无效")
        }
    }

    private func success<Value: Encodable>(
        _ value: Value,
        requestId: String,
        statusCode: Int = 200
    ) throws -> LocalSyncHTTPResponse {
        let body = try JSONEncoder().encode(
            LocalSyncSuccessEnvelope(data: value, requestId: requestId)
        )
        return LocalSyncHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json", "X-Request-Id": requestId],
            body: body
        )
    }

    private func failure(
        _ error: LocalSyncServiceFailure,
        requestId: String
    ) -> LocalSyncHTTPResponse {
        let payload = ServerErrorPayload(
            code: error.code,
            message: error.message,
            details: error.details
        )
        let body = (try? JSONEncoder().encode(
            LocalSyncFailureEnvelope(error: payload, requestId: requestId)
        )) ?? Data()
        return LocalSyncHTTPResponse(
            statusCode: error.statusCode,
            headers: ["Content-Type": "application/json", "X-Request-Id": requestId],
            body: body
        )
    }

    private func validation(_ field: String, _ message: String) -> LocalSyncServiceFailure {
        LocalSyncServiceFailure(
            400,
            "VALIDATION_ERROR",
            message,
            details: ["field": .string(field)]
        )
    }

    private func isValidIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let asciiLetterOrDigit = (48...57).contains(scalar.value) ||
                (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            return asciiLetterOrDigit || "._:-".unicodeScalars.contains(scalar)
        }
    }

    private func isValidToken(_ value: String) -> Bool {
        (try? Base64URL.decode(value).count) == 32
    }

    private func isValidKey(_ value: String) -> Bool {
        (try? Base64URL.decode(value).count) == 32
    }

    private func isValidEnvelope(_ envelope: EncryptedEnvelope) -> Bool {
        (try? Base64URL.decode(envelope.nonce).count) == AES256GCM.nonceByteCount &&
            ((try? Base64URL.decode(envelope.ciphertext).count) ?? 0) >= AES256GCM.tagByteCount &&
            ((try? Base64URL.decode(envelope.ciphertext).count) ?? Int.max) <= 32 * 1_024
    }

    private func persist(_ updatedState: LocalSyncPersistedState) throws {
        try Self.persist(updatedState, to: fileURL)
    }

    private static func persist(_ state: LocalSyncPersistedState, to fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func credentialHash(_ value: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(value.utf8))))
    }

    private static func matches(_ value: String, hash expectedHash: String) -> Bool {
        let actual = credentialHash(value)
        let lhs = Array(actual.utf8)
        let rhs = Array(expectedHash.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension SyncPulledOperation {
    func matches(_ operation: SyncPushOperation) -> Bool {
        opId == operation.opId && entityId == operation.entityId &&
            kind == operation.kind && lamport == operation.lamport &&
            ciphertext == operation.ciphertext && nonce == operation.nonce
    }
}

public enum LocalNetworkSyncEndpointResolver {
    public static func preferredEndpoint(
        port: UInt16 = LocalNetworkSyncConstants.defaultPort
    ) throws -> URL {
        let processHost = ProcessInfo.processInfo.hostName.lowercased()
        let localHost: String? = {
            if processHost.hasSuffix(".local") { return processHost }
            if !processHost.contains("."), isValidLocalLabel(processHost) {
                return "\(processHost).local"
            }
            return nil
        }()
        for host in [localHost, privateIPv4Address()].compactMap({ $0 }) {
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            components.port = Int(port)
            if let url = components.url, SyncEndpointPolicy.scope(of: url) == .localNetwork {
                return url
            }
        }
        throw LocalSyncServerError.cannotResolveEndpoint
    }

    private static func isValidLocalLabel(_ value: String) -> Bool {
        guard (1...63).contains(value.count),
              (value.first?.isLetter == true || value.first?.isNumber == true),
              (value.last?.isLetter == true || value.last?.isNumber == true) else {
            return false
        }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    private static func privateIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interfacePointer = current {
            let interface = interfacePointer.pointee
            defer { current = interface.ifa_next }
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  (Int32(interface.ifa_flags) & IFF_UP) != 0,
                  (Int32(interface.ifa_flags) & IFF_LOOPBACK) == 0 else {
                continue
            }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let value = String(cString: buffer)
            if isPrivateIPv4(value) { return value }
        }
        return nil
    }

    private static func isPrivateIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        return octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168)
    }
}

public final class LocalNetworkSyncHTTPServer: @unchecked Sendable {
    private static let maximumHeaderBytes = 32 * 1_024
    private static let maximumRequestBytes = 3 * 1_024 * 1_024 + maximumHeaderBytes

    public let endpoint: URL
    private let store: LocalSyncServerStore
    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "io.github.stophemo.woo-todo.local-sync",
        qos: .utility
    )
    private let lock = NSLock()
    private var started = false

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && listener.state == .ready
    }

    public init(
        store: LocalSyncServerStore,
        endpoint: URL,
        serviceName: String = "Woo Todo"
    ) throws {
        guard SyncEndpointPolicy.scope(of: endpoint) == .localNetwork,
              let rawPort = endpoint.port,
              let portValue = UInt16(exactly: rawPort),
              let port = NWEndpoint.Port(rawValue: portValue) else {
            throw LocalSyncServerError.cannotResolveEndpoint
        }
        self.store = store
        self.endpoint = endpoint
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: port)
        listener.service = NWListener.Service(
            name: serviceName,
            type: LocalNetworkSyncConstants.bonjourServiceType
        )
        self.listener = listener
    }

    public func start() async throws {
        guard markStartedIfNeeded() else { return }

        do {
            try await withCheckedThrowingContinuation { continuation in
                let gate = LocalSyncContinuationGate(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume(.success(()))
                    case .failed(let error):
                        gate.resume(.failure(
                            LocalSyncServerError.listenerFailed(error.localizedDescription)
                        ))
                    case .cancelled:
                        gate.resume(.failure(
                            LocalSyncServerError.listenerFailed("服务已停止")
                        ))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.start(queue: queue)
            }
        } catch {
            resetStarted()
            throw error
        }
    }

    public func stop() {
        let shouldStop = markStoppedIfNeeded()
        if shouldStop { listener.cancel() }
    }

    private func markStartedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
        return true
    }

    private func markStoppedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return false }
        started = false
        return true
    }

    private func resetStarted() {
        lock.lock()
        started = false
        lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.receive(on: connection, accumulated: Data())
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self, weak connection] content, _, isComplete, error in
            guard let self, let connection else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var data = accumulated
            if let content { data.append(content) }
            guard data.count <= Self.maximumRequestBytes else {
                self.send(
                    LocalSyncHTTPResponse(
                        statusCode: 413,
                        headers: ["Content-Type": "application/json"],
                        body: Data("{\"ok\":false,\"error\":{\"code\":\"PAYLOAD_TOO_LARGE\",\"message\":\"请求过大\"}}".utf8)
                    ),
                    on: connection
                )
                return
            }
            do {
                if let request = try Self.parseRequest(data) {
                    Task {
                        let response = await self.store.handle(request)
                        self.send(response, on: connection)
                    }
                } else if isComplete {
                    self.send(Self.badRequest(), on: connection)
                } else {
                    self.receive(on: connection, accumulated: data)
                }
            } catch {
                self.send(Self.badRequest(), on: connection)
            }
        }
    }

    private func send(_ response: LocalSyncHTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        var head = "HTTP/1.1 \(response.statusCode) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(_ data: Data) throws -> LocalSyncHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            guard data.count <= maximumHeaderBytes else { throw LocalSyncServerError.corruptedState }
            return nil
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            throw LocalSyncServerError.corruptedState
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw LocalSyncServerError.corruptedState }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard requestParts.count == 3,
              requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
            throw LocalSyncServerError.corruptedState
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw LocalSyncServerError.corruptedState
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else {
                throw LocalSyncServerError.corruptedState
            }
            headers[name] = value
        }
        let contentLengthText = headers["content-length"] ?? "0"
        guard headers["transfer-encoding"] == nil,
              let contentLength = Int(contentLengthText),
              contentLength >= 0,
              contentLength <= maximumRequestBytes - maximumHeaderBytes else {
            throw LocalSyncServerError.corruptedState
        }
        let bodyStart = headerRange.upperBound
        let expectedCount = bodyStart + contentLength
        guard data.count >= expectedCount else { return nil }
        guard data.count == expectedCount else { throw LocalSyncServerError.corruptedState }
        return LocalSyncHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: data[bodyStart..<expectedCount]
        )
    }

    private static func badRequest() -> LocalSyncHTTPResponse {
        LocalSyncHTTPResponse(
            statusCode: 400,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"ok\":false,\"error\":{\"code\":\"BAD_REQUEST\",\"message\":\"HTTP 请求格式无效\"}}".utf8)
        )
    }
}

private final class LocalSyncContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
