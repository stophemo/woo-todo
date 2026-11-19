import Foundation
import WooTodoCore

@MainActor
final class MCPSettingsStore: ObservableObject {
    enum Status: Equatable {
        case disabled
        case starting
        case running
        case failed(String)

        var title: String {
            switch self {
            case .disabled: "已关闭"
            case .starting: "正在启动"
            case .running: "运行中"
            case .failed: "启动失败"
            }
        }

        var detail: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    static let defaultPort: UInt16 = 8_765
    private static let enabledDefaultsKey = "mcp.enabled.v1"
    private static let tokenDefaultsKey = "mcp.token.v1"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var token: String
    @Published private(set) var status: Status

    private let defaults: UserDefaults
    private let service: MCPTaskService
    private let allowsExternalServices: Bool
    private let port: UInt16
    private var server: MCPHTTPServer?
    private var generation = 0

    init(
        store: TodayStore,
        repository: TaskRepository,
        defaults: UserDefaults = .standard,
        allowsExternalServices: Bool = true,
        port: UInt16 = MCPSettingsStore.defaultPort
    ) {
        self.defaults = defaults
        self.service = MCPTaskService(store: store, repository: repository)
        self.allowsExternalServices = allowsExternalServices
        self.port = port
        let enabled = defaults.bool(forKey: Self.enabledDefaultsKey)
        isEnabled = enabled
        token = Self.loadOrCreateToken(defaults: defaults)
        status = enabled ? .starting : .disabled
    }

    var endpointURL: URL {
        URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    var configurationSnippet: String {
        """
        {
          "mcpServers": {
            "woo-todo": {
              "type": "http",
              "url": "\(endpointURL.absoluteString)",
              "headers": {
                "Authorization": "Bearer \(token)"
              }
            }
          }
        }
        """
    }

    var claudeCodeSnippet: String {
        "claude mcp add --transport http woo-todo \(endpointURL.absoluteString) "
            + "--header \"Authorization: Bearer \(token)\""
    }

    var codexSnippet: String {
        """
        export WOO_TODO_MCP_TOKEN="\(token)"
        codex mcp add woo-todo --url \(endpointURL.absoluteString) --bearer-token-env-var WOO_TODO_MCP_TOKEN
        """
    }

    var piSnippet: String {
        "pi mcp add woo-todo --url \(endpointURL.absoluteString) "
            + "--header \"Authorization: Bearer \(token)\""
    }

    var hermesSnippet: String {
        "hermes mcp add woo-todo --url \(endpointURL.absoluteString) --auth header"
    }

    func startIfNeeded() {
        guard isEnabled else {
            status = .disabled
            return
        }
        startServer()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            startServer()
        } else {
            stopServer()
            status = .disabled
        }
    }

    func regenerateToken() {
        token = Self.generateToken()
        defaults.set(token, forKey: Self.tokenDefaultsKey)
        guard isEnabled else { return }
        startServer()
    }

    func stop() {
        stopServer()
        if !isEnabled { status = .disabled }
    }

    private func startServer() {
        guard allowsExternalServices else {
            status = .failed("当前运行模式不允许开放本机 MCP 服务")
            return
        }
        generation &+= 1
        let currentGeneration = generation
        server?.stop()
        server = nil
        status = .starting
        do {
            let handler = MCPMessageHandler(service: service, token: token)
            let server = try MCPHTTPServer(port: port) { request in
                await handler.handle(request)
            }
            self.server = server
            Task { @MainActor [weak self] in
                do {
                    try await server.start()
                    guard let self, self.generation == currentGeneration else {
                        server.stop()
                        return
                    }
                    self.status = .running
                } catch {
                    guard let self, self.generation == currentGeneration else { return }
                    self.server = nil
                    self.status = .failed(error.localizedDescription)
                }
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func stopServer() {
        generation &+= 1
        server?.stop()
        server = nil
        if isEnabled { status = .starting }
    }

    private static func loadOrCreateToken(defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: tokenDefaultsKey),
           isValidToken(saved) {
            return saved
        }
        let generated = generateToken()
        defaults.set(generated, forKey: tokenDefaultsKey)
        return generated
    }

    private static func generateToken() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isValidToken(_ value: String) -> Bool {
        value.count == 43 && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}
