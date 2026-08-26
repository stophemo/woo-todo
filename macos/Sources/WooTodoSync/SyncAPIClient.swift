import Foundation

public enum SyncAPIError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case encoding(String)
    case transport(String)
    case invalidHTTPResponse
    case decoding(String)
    case server(statusCode: Int, payload: ServerErrorPayload, requestId: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "同步服务地址无效"
        case .encoding(let message):
            "请求编码失败：\(message)"
        case .transport(let message):
            "网络请求失败：\(message)"
        case .invalidHTTPResponse:
            "同步服务没有返回有效的 HTTP 响应"
        case .decoding(let message):
            "响应解析失败：\(message)"
        case .server(_, let payload, _):
            "同步服务错误（\(payload.code)）：\(payload.message)"
        }
    }
}

public protocol SyncTransport: Sendable {
    func sync(_ request: SyncRequest, deviceToken: String) async throws -> SyncData
}

public extension SyncAPIError {
    /// 服务端游标落后于客户端（通常因服务端状态丢失重建后从序号 1 重新计数）。
    /// 客户端应重置本地 cursor 后从头重新同步。
    var isCursorAhead: Bool {
        if case .server(let statusCode, let payload, _) = self {
            return statusCode == 409 && payload.code == "CURSOR_AHEAD"
        }
        return false
    }
}

private struct SuccessEnvelope<Value: Decodable>: Decodable {
    let ok: Bool
    let data: Value
    let requestId: String
}

private struct FailureEnvelope: Decodable {
    let ok: Bool
    let error: ServerErrorPayload
    let requestId: String?
}

public final class SyncAPIClient: SyncTransport, @unchecked Sendable {
    public let endpoint: URL
    private let session: URLSession

    public convenience init(endpoint: URL) throws {
        try self.init(endpoint: endpoint, session: Self.defaultSession(for: endpoint))
    }

    public init(endpoint: URL, session: URLSession) throws {
        guard SyncEndpointPolicy.isAllowed(endpoint) else {
            throw SyncAPIError.invalidEndpoint
        }
        self.endpoint = endpoint
        self.session = session
    }

    static func directSessionConfiguration(for endpoint: URL) -> URLSessionConfiguration? {
        guard [.localNetwork, .currentDeviceOnly].contains(
            SyncEndpointPolicy.scope(of: endpoint)
        ) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return configuration
    }

    private static func defaultSession(for endpoint: URL) -> URLSession {
        guard let configuration = directSessionConfiguration(for: endpoint) else {
            return .shared
        }
        return URLSession(configuration: configuration)
    }

    public func createVault(
        _ request: CreateVaultRequest,
        inviteCode: String
    ) async throws -> CreateVaultData {
        try await send(
            method: "POST",
            path: ["v1", "vaults"],
            body: encode(request),
            deviceToken: nil,
            vaultCreationInviteCode: inviteCode
        )
    }

    public func createPairing(
        _ request: CreatePairingRequest,
        deviceToken: String
    ) async throws -> CreatePairingData {
        try await send(
            method: "POST",
            path: ["v1", "pairings"],
            body: encode(request),
            deviceToken: deviceToken
        )
    }

    public func pairingStatus(
        pairingId: String,
        deviceToken: String
    ) async throws -> PairingStatusData {
        try await send(
            method: "GET",
            path: ["v1", "pairings", pairingId],
            body: nil,
            deviceToken: deviceToken
        )
    }

    public func claimPairing(
        pairingId: String,
        request: PairingClaimRequest
    ) async throws -> PairingClaimData {
        try await send(
            method: "POST",
            path: ["v1", "pairings", pairingId, "claim"],
            body: encode(request),
            deviceToken: nil
        )
    }

    public func confirmPairing(
        pairingId: String,
        request: PairingConfirmRequest,
        deviceToken: String
    ) async throws -> PairingConfirmData {
        try await send(
            method: "POST",
            path: ["v1", "pairings", pairingId, "confirm"],
            body: encode(request),
            deviceToken: deviceToken
        )
    }

    public func pairingResult(
        pairingId: String,
        request: PairingResultRequest
    ) async throws -> PairingResultData {
        try await send(
            method: "POST",
            path: ["v1", "pairings", pairingId, "result"],
            body: encode(request),
            deviceToken: nil
        )
    }

    public func sync(_ request: SyncRequest, deviceToken: String) async throws -> SyncData {
        try await send(
            method: "POST",
            path: ["v1", "sync"],
            body: encode(request),
            deviceToken: deviceToken
        )
    }

    public func listDevices(deviceToken: String) async throws -> DeviceListData {
        try await send(
            method: "GET",
            path: ["v1", "devices"],
            body: nil,
            deviceToken: deviceToken
        )
    }

    public func revokeDevice(
        deviceId: String,
        deviceToken: String
    ) async throws -> RevokeDeviceData {
        try await send(
            method: "POST",
            path: ["v1", "devices", deviceId, "revoke"],
            body: nil,
            deviceToken: deviceToken
        )
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw SyncAPIError.encoding(error.localizedDescription)
        }
    }

    private func send<Value: Decodable>(
        method: String,
        path: [String],
        body: Data?,
        deviceToken: String?,
        vaultCreationInviteCode: String? = nil
    ) async throws -> Value {
        var url = endpoint
        for component in path {
            url.appendPathComponent(component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let deviceToken {
            request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
        }
        if let vaultCreationInviteCode {
            request.setValue(
                vaultCreationInviteCode,
                forHTTPHeaderField: "X-Woo-Todo-Invite-Code"
            )
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SyncAPIError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SyncAPIError.invalidHTTPResponse
        }

        if (200..<300).contains(httpResponse.statusCode) {
            do {
                let envelope = try JSONDecoder().decode(SuccessEnvelope<Value>.self, from: data)
                guard envelope.ok else {
                    throw SyncAPIError.decoding("成功响应中的 ok 不是 true")
                }
                return envelope.data
            } catch let error as SyncAPIError {
                throw error
            } catch {
                throw SyncAPIError.decoding(error.localizedDescription)
            }
        }

        if let envelope = try? JSONDecoder().decode(FailureEnvelope.self, from: data) {
            throw SyncAPIError.server(
                statusCode: httpResponse.statusCode,
                payload: envelope.error,
                requestId: envelope.requestId
            )
        }
        let fallback = ServerErrorPayload(
            code: "HTTP_\(httpResponse.statusCode)",
            message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            details: nil
        )
        throw SyncAPIError.server(
            statusCode: httpResponse.statusCode,
            payload: fallback,
            requestId: httpResponse.value(forHTTPHeaderField: "x-request-id")
        )
    }
}
