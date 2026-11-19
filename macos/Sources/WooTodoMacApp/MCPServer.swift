import Foundation
import Network
import WooTodoCore

struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct MCPHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

enum MCPHTTPServerError: LocalizedError {
    case invalidPort
    case listenerFailed(String)
    case malformedRequest
    case requestTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidPort: "本机 MCP 服务端口无效"
        case .listenerFailed(let message): "本机 MCP 服务启动失败：\(message)"
        case .malformedRequest: "HTTP 请求格式无效"
        case .requestTooLarge: "请求体过大"
        }
    }
}

/// 只监听 127.0.0.1 的极简 HTTP/1.1 服务，供 MCP 客户端发送 JSON-RPC。
final class MCPHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (MCPHTTPRequest) async -> MCPHTTPResponse

    private static let maximumHeaderBytes = 16 * 1_024
    private static let maximumBodyBytes = 1 * 1_024 * 1_024

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(
        label: "io.github.stophemo.woo-todo.mcp",
        qos: .userInitiated
    )
    private let lock = NSLock()
    private var started = false

    init(port: UInt16, handler: @escaping Handler) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPHTTPServerError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: endpointPort
        )
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start() async throws {
        guard markStartedIfNeeded() else { return }
        do {
            try await withCheckedThrowingContinuation { continuation in
                let gate = MCPContinuationGate(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.resume(.success(()))
                    case .failed(let error):
                        gate.resume(.failure(
                            MCPHTTPServerError.listenerFailed(error.localizedDescription)
                        ))
                    case .cancelled:
                        gate.resume(.failure(
                            MCPHTTPServerError.listenerFailed("服务已停止")
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

    func stop() {
        lock.lock()
        let shouldStop = started
        started = false
        lock.unlock()
        if shouldStop { listener.cancel() }
    }

    private func markStartedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
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
            guard data.count <= Self.maximumBodyBytes + Self.maximumHeaderBytes else {
                self.send(Self.jsonError(
                    statusCode: 413,
                    code: "PAYLOAD_TOO_LARGE",
                    message: "请求过大"
                ), on: connection)
                return
            }
            do {
                if let request = try Self.parseRequest(data) {
                    Task {
                        let response = await self.handler(request)
                        self.send(response, on: connection)
                    }
                } else if isComplete {
                    self.send(Self.jsonError(
                        statusCode: 400,
                        code: "BAD_REQUEST",
                        message: "HTTP 请求格式无效"
                    ), on: connection)
                } else {
                    self.receive(on: connection, accumulated: data)
                }
            } catch {
                self.send(Self.jsonError(
                    statusCode: 400,
                    code: "BAD_REQUEST",
                    message: "HTTP 请求格式无效"
                ), on: connection)
            }
        }
    }

    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
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

    private static func parseRequest(_ data: Data) throws -> MCPHTTPRequest? {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: delimiter) else {
            guard data.count <= maximumHeaderBytes else {
                throw MCPHTTPServerError.requestTooLarge
            }
            return nil
        }
        guard headerRange.lowerBound <= maximumHeaderBytes,
              let headerText = String(
                data: data[..<headerRange.lowerBound],
                encoding: .utf8
              ) else {
            throw MCPHTTPServerError.malformedRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw MCPHTTPServerError.malformedRequest
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            throw MCPHTTPServerError.malformedRequest
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                throw MCPHTTPServerError.malformedRequest
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, headers[name] == nil else {
                throw MCPHTTPServerError.malformedRequest
            }
            headers[name] = value
        }
        let contentLengthText = headers["content-length"] ?? "0"
        guard headers["transfer-encoding"] == nil,
              let contentLength = Int(contentLengthText),
              contentLength >= 0,
              contentLength <= maximumBodyBytes else {
            throw MCPHTTPServerError.malformedRequest
        }
        let bodyStart = headerRange.upperBound
        let expectedCount = bodyStart + contentLength
        guard data.count >= expectedCount else { return nil }
        guard data.count == expectedCount else {
            throw MCPHTTPServerError.malformedRequest
        }
        let rawPath = String(parts[1])
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init)
            ?? rawPath
        return MCPHTTPRequest(
            method: String(parts[0]),
            path: path,
            headers: headers,
            body: Data(data[bodyStart..<expectedCount])
        )
    }

    private static func jsonError(
        statusCode: Int,
        code: String,
        message: String
    ) -> MCPHTTPResponse {
        let body = Data(
            "{\"ok\":false,\"error\":{\"code\":\"\(code)\",\"message\":\"\(message)\"}}".utf8
        )
        return MCPHTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: body
        )
    }
}

private final class MCPContinuationGate: @unchecked Sendable {
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

/// MCP Streamable HTTP 的无状态实现：鉴权、JSON-RPC 分发与工具调用。
@MainActor
final class MCPMessageHandler {
    private static let supportedProtocolVersions = [
        "2025-06-18",
        "2025-03-26",
        "2024-11-05",
    ]

    private let service: MCPTaskService
    private let token: String
    private let serverVersion: String

    init(
        service: MCPTaskService,
        token: String,
        serverVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
    ) {
        self.service = service
        self.token = token
        self.serverVersion = serverVersion
    }

    func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard isAuthorized(request.headers["authorization"]) else {
            return Self.jsonResponse(
                statusCode: 401,
                object: [
                    "jsonrpc": "2.0",
                    "error": [
                        "code": -32001,
                        "message": "缺少或无效的 MCP 令牌",
                    ],
                ],
                extraHeaders: ["WWW-Authenticate": "Bearer"]
            )
        }
        guard isAllowedOrigin(request.headers["origin"]) else {
            return Self.jsonResponse(
                statusCode: 403,
                object: [
                    "jsonrpc": "2.0",
                    "error": [
                        "code": -32002,
                        "message": "已拒绝浏览器来源的请求",
                    ],
                ]
            )
        }
        guard request.path == "/mcp" else {
            return Self.jsonHTTPError(
                statusCode: 404,
                code: "NOT_FOUND",
                message: "仅支持 POST /mcp"
            )
        }
        guard request.method == "POST" else {
            return Self.jsonHTTPError(
                statusCode: 405,
                code: "METHOD_NOT_ALLOWED",
                message: "MCP 服务仅支持 POST",
                extraHeaders: ["Allow": "POST"]
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: request.body)
        } catch {
            return Self.rpcError(id: NSNull(), code: -32700, message: "JSON 解析失败")
        }
        guard let message = object as? [String: Any],
              message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            return Self.rpcError(
                id: (object as? [String: Any])?["id"] ?? NSNull(),
                code: -32600,
                message: "不是有效的 JSON-RPC 2.0 请求"
            )
        }

        let hasID = message.keys.contains("id")
        let id = message["id"] ?? NSNull()
        let params = message["params"] as? [String: Any] ?? [:]

        if !hasID || method.hasPrefix("notifications/") {
            return MCPHTTPResponse(
                statusCode: 202,
                headers: [:],
                body: Data()
            )
        }

        switch method {
        case "initialize":
            return Self.rpcResult(
                id: id,
                result: initializeResult(params: params)
            )
        case "ping":
            return Self.rpcResult(id: id, result: [:])
        case "tools/list":
            return Self.rpcResult(
                id: id,
                result: ["tools": MCPTaskService.tools]
            )
        case "tools/call":
            return toolCall(id: id, params: params)
        case "resources/list":
            return Self.rpcResult(id: id, result: ["resources": []])
        case "resources/templates/list":
            return Self.rpcResult(id: id, result: ["resourceTemplates": []])
        case "prompts/list":
            return Self.rpcResult(id: id, result: ["prompts": []])
        default:
            return Self.rpcError(
                id: id,
                code: -32601,
                message: "不支持的方法：\(method)"
            )
        }
    }

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap {
            Self.supportedProtocolVersions.contains($0) ? $0 : nil
        } ?? "2025-06-18"
        return [
            "protocolVersion": version,
            "capabilities": [
                "tools": ["listChanged": false],
            ],
            "serverInfo": [
                "name": "woo-todo",
                "version": serverVersion,
            ],
            "instructions": "Woo Todo 是本地优先的待办应用。日期使用 YYYY-MM-DD，提醒使用 HH:mm；不设置日期时任务完成即止。新增任务会立即写入本机，并参与用户已配置的同步。",
        ]
    }

    private func toolCall(id: Any, params: [String: Any]) -> MCPHTTPResponse {
        guard let name = params["name"] as? String else {
            return Self.rpcError(id: id, code: -32602, message: "tools/call 缺少工具名称")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let result: MCPToolResult
        do {
            result = try service.call(name: name, arguments: arguments)
        } catch {
            result = .failure(error.localizedDescription)
        }
        var payload: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": result.text,
                ],
            ],
            "isError": result.isError,
        ]
        if let structured = result.structured {
            payload["structuredContent"] = structured
        }
        return Self.rpcResult(id: id, result: payload)
    }

    private func isAuthorized(_ header: String?) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let provided = Array(header.dropFirst("Bearer ".count).utf8)
        let expected = Array(token.utf8)
        guard provided.count == expected.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices {
            difference |= provided[index] ^ expected[index]
        }
        return difference == 0
    }

    private func isAllowedOrigin(_ value: String?) -> Bool {
        guard let value else { return true }
        guard let url = URL(string: value), let host = url.host else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private static func rpcResult(id: Any, result: [String: Any]) -> MCPHTTPResponse {
        jsonResponse(
            statusCode: 200,
            object: [
                "jsonrpc": "2.0",
                "id": id,
                "result": result,
            ]
        )
    }

    private static func rpcError(
        id: Any,
        code: Int,
        message: String
    ) -> MCPHTTPResponse {
        jsonResponse(
            statusCode: 200,
            object: [
                "jsonrpc": "2.0",
                "id": id,
                "error": [
                    "code": code,
                    "message": message,
                ],
            ]
        )
    }

    private static func jsonResponse(
        statusCode: Int,
        object: [String: Any],
        extraHeaders: [String: String] = [:]
    ) -> MCPHTTPResponse {
        let data = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )) ?? Data()
        var headers = extraHeaders
        headers["Content-Type"] = "application/json; charset=utf-8"
        return MCPHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: data
        )
    }

    private static func jsonHTTPError(
        statusCode: Int,
        code: String,
        message: String,
        extraHeaders: [String: String] = [:]
    ) -> MCPHTTPResponse {
        jsonResponse(
            statusCode: statusCode,
            object: [
                "ok": false,
                "error": [
                    "code": code,
                    "message": message,
                ],
            ],
            extraHeaders: extraHeaders
        )
    }
}
