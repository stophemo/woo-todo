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

    private static let enabledDefaultsKey = "mcp.enabled.v1"
    private static let tokenDefaultsKey = "mcp.token.v1"
    private static let portDefaultsKey = "mcp.port.v1"
    private static let runningEndpointDefaultsKey = "mcp.running-endpoint.v1"
    private static let portRange: ClosedRange<UInt16> = 20_000...60_000
    /** 应用更新或快速重启时旧实例可能还占着端口，先短延迟重试同一端口再换。 */
    private static let samePortStartRetries = 2
    private static let restartDelay = Duration.milliseconds(400)
    private static let maximumRuntimeRestarts = 2

    @Published private(set) var isEnabled: Bool
    @Published private(set) var token: String
    @Published private(set) var port: UInt16
    @Published private(set) var status: Status
    /** 端口或令牌相对上次确认的配置发生变化时提示用户重新复制 Agent 命令。 */
    @Published private(set) var endpointChangeNotice: String?

    private let defaults: UserDefaults
    private let service: MCPTaskService
    private let allowsExternalServices: Bool
    private let allowsPortRotation: Bool
    private var server: MCPHTTPServer?
    private var generation = 0
    private var startCycle = 0
    private var runtimeRestartCount = 0
    private var hasStarted = false

    init(
        store: TodayStore,
        repository: TaskRepository,
        defaults: UserDefaults = .standard,
        allowsExternalServices: Bool = true,
        port: UInt16? = nil
    ) {
        self.defaults = defaults
        self.service = MCPTaskService(store: store, repository: repository)
        self.allowsExternalServices = allowsExternalServices
        self.allowsPortRotation = port == nil
        self.port = port ?? Self.loadOrCreatePort(defaults: defaults)
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
        guard !hasStarted else { return }
        hasStarted = true
        beginStartCycle()
    }

    /** 监听意外中断且无法自愈后，在应用回到前台时再试一次。 */
    func restartIfNeeded() {
        guard isEnabled, case .failed = status else { return }
        beginStartCycle()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            hasStarted = true
            beginStartCycle()
        } else {
            stopServer()
            status = .disabled
        }
    }

    func regenerateToken() {
        token = Self.generateToken()
        defaults.set(token, forKey: Self.tokenDefaultsKey)
        guard isEnabled else { return }
        beginStartCycle()
    }

    /** 用户已按当前地址更新 Agent 后清除提示，并把当前端点记为已确认。 */
    func acknowledgeEndpointChange() {
        defaults.set(runningEndpointValue, forKey: Self.runningEndpointDefaultsKey)
        endpointChangeNotice = nil
    }

    func stop() {
        startCycle &+= 1
        stopServer()
        if !isEnabled { status = .disabled }
    }

    private var runningEndpointValue: String { "\(port)|\(token)" }

    private func beginStartCycle() {
        startCycle &+= 1
        runtimeRestartCount = 0
        startServer(cycle: startCycle, attempt: 0, rotationsLeft: allowsPortRotation ? 1 : 0)
    }

    private func startServer(cycle: Int, attempt: Int, rotationsLeft: Int) {
        guard allowsExternalServices else {
            status = .failed("当前运行模式不允许开放本机 MCP 服务")
            return
        }
        guard cycle == startCycle else { return }
        generation &+= 1
        let currentGeneration = generation
        server?.stop()
        server = nil
        status = .starting
        do {
            let handler = MCPMessageHandler(service: service, token: token)
            let server = try MCPHTTPServer(
                port: port,
                handler: { request in
                    await handler.handle(request)
                },
                onUnexpectedFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.handleUnexpectedListenerFailure(message)
                    }
                }
            )
            self.server = server
            Task { @MainActor [weak self] in
                do {
                    try await server.start()
                    guard let self, self.generation == currentGeneration else {
                        server.stop()
                        return
                    }
                    self.status = .running
                    self.runtimeRestartCount = 0
                    self.recordRunningEndpoint()
                } catch {
                    guard let self, self.generation == currentGeneration else { return }
                    self.server = nil
                    self.handleStartFailure(
                        error,
                        cycle: cycle,
                        attempt: attempt,
                        rotationsLeft: rotationsLeft
                    )
                }
            }
        } catch {
            handleStartFailure(error, cycle: cycle, attempt: attempt, rotationsLeft: rotationsLeft)
        }
    }

    private func handleStartFailure(
        _ error: Error,
        cycle: Int,
        attempt: Int,
        rotationsLeft: Int
    ) {
        guard cycle == startCycle else { return }
        if attempt < Self.samePortStartRetries {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.restartDelay)
                guard let self, self.startCycle == cycle else { return }
                self.startServer(
                    cycle: cycle,
                    attempt: attempt + 1,
                    rotationsLeft: rotationsLeft
                )
            }
            return
        }
        if rotationsLeft > 0 {
            let previous = port
            rotatePort()
            endpointChangeNotice =
                "端口 \(previous) 已被占用，已自动改用 \(port)。请重新复制下方 Agent 命令。"
            startServer(cycle: cycle, attempt: 0, rotationsLeft: rotationsLeft - 1)
            return
        }
        status = .failed(error.localizedDescription)
    }

    /** ready 之后监听中断：先在同一端口自愈，避免悄悄换端口让所有客户端掉线。 */
    private func handleUnexpectedListenerFailure(_ message: String) {
        guard isEnabled else { return }
        server = nil
        generation &+= 1
        runtimeRestartCount += 1
        guard runtimeRestartCount <= Self.maximumRuntimeRestarts else {
            status = .failed(message)
            return
        }
        status = .starting
        startCycle &+= 1
        let cycle = startCycle
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.restartDelay)
            guard let self, self.startCycle == cycle else { return }
            // 运行期故障可能是端口被抢，但不主动换端口：换了同样会让客户端掉线。
            self.startServer(cycle: cycle, attempt: 0, rotationsLeft: 0)
        }
    }

    /** 首次成功启动时静默记录端点；之后端点变化会持续提示，直到用户确认。 */
    private func recordRunningEndpoint() {
        let current = runningEndpointValue
        guard let previous = defaults.string(forKey: Self.runningEndpointDefaultsKey) else {
            defaults.set(current, forKey: Self.runningEndpointDefaultsKey)
            return
        }
        guard previous != current else { return }
        endpointChangeNotice =
            "本机地址或访问令牌已变化（当前端口 \(port)），已有 Agent 会连不上；请重新复制下方命令。"
    }

    private func rotatePort() {
        var next = port
        while next == port {
            next = UInt16.random(in: Self.portRange)
        }
        port = next
        defaults.set(Int(next), forKey: Self.portDefaultsKey)
    }

    private func stopServer() {
        generation &+= 1
        startCycle &+= 1
        server?.stop()
        server = nil
        if isEnabled { status = .starting }
    }

    private static func loadOrCreatePort(defaults: UserDefaults) -> UInt16 {
        if let saved = defaults.object(forKey: portDefaultsKey) as? NSNumber {
            let value = saved.uint16Value
            if portRange.contains(value) {
                return value
            }
        }
        let value = UInt16.random(in: portRange)
        defaults.set(Int(value), forKey: portDefaultsKey)
        return value
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
