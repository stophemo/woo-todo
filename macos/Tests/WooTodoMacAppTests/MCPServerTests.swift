import Foundation
import Testing
import WooTodoCore
@testable import WooTodoMacApp

@Suite("MCP 本机接入")
@MainActor
struct MCPServerTests {
    private let token = "test-token"

    @Test("initialize 返回协议版本与工具能力")
    func initializeReturnsToolsCapability() async throws {
        let handler = makeHandler()
        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-06-18"],
        ]))

        #expect(response.statusCode == 200)
        let object = try decode(response)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "woo-todo")
    }

    @Test("缺少或错误的令牌无法访问")
    func rejectsInvalidToken() async throws {
        let handler = makeHandler()
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "ping",
        ]

        let missing = await handler.handle(request(body, token: nil))
        let wrong = await handler.handle(request(body, token: "wrong"))

        #expect(missing.statusCode == 401)
        #expect(wrong.statusCode == 401)
    }

    @Test("拒绝非回环来源的浏览器请求")
    func rejectsForeignOrigin() async throws {
        let handler = makeHandler()
        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "ping",
        ], origin: "https://example.com"))

        #expect(response.statusCode == 403)
    }

    @Test("tools/list 暴露新增、查询任务与标签工具")
    func listsTools() async throws {
        let handler = makeHandler()
        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
        ]))

        let object = try decode(response)
        let result = try #require(object["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        #expect(Set(tools.compactMap { $0["name"] as? String }) == [
            "add_task", "list_tasks", "list_tags",
        ])
    }

    @Test("add_task 写入标签、起止日期与提醒")
    func addTaskPersistsScheduleAndTag() async throws {
        let repository = MCPTestRepository()
        let store = TodayStore(repository: repository)
        let handler = makeHandler(store: store, repository: repository)
        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "add_task",
                "arguments": [
                    "title": "  准备发布计划  ",
                    "tag": "工作",
                    "startDate": "2026-11-16",
                    "endDate": "2026-11-18",
                    "reminderTime": "09:30",
                ],
            ],
        ]))

        #expect(response.statusCode == 200)
        let object = try decode(response)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let task = try #require(structured["task"] as? [String: Any])
        #expect(task["title"] as? String == "准备发布计划")
        #expect(task["tag"] as? String == "工作")
        #expect(task["startDate"] as? String == "2026-11-16")
        #expect(task["endDate"] as? String == "2026-11-18")
        #expect(task["reminderTime"] as? String == "09:30")
        #expect(task["tagCreated"] as? Bool == true)

        let saved = try #require(repository.tasks.first)
        let expectedReminder = try TaskReminderTime(hour: 9, minute: 30)
        #expect(saved.title == "准备发布计划")
        #expect(saved.reminderTime == expectedReminder)
        #expect(repository.categories.contains { $0.name == "工作" })
    }

    @Test("非法日期返回工具错误且不写入任务")
    func rejectsInvalidDate() async throws {
        let repository = MCPTestRepository()
        let store = TodayStore(repository: repository)
        let handler = makeHandler(store: store, repository: repository)
        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": [
                "name": "add_task",
                "arguments": [
                    "title": "日期错误",
                    "startDate": "2026-13-01",
                    "endDate": "2026-13-02",
                ],
            ],
        ]))

        let object = try decode(response)
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(repository.tasks.isEmpty)
    }

    @Test("MCP 接入开关可启动并停止本机服务")
    func settingsLifecycleStartsAndStopsServer() async throws {
        let suite = "io.github.stophemo.woo-todo.mcp-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = MCPTestRepository()
        let store = TodayStore(repository: repository)

        var runningSettings: MCPSettingsStore?
        var runningPort: UInt16?
        for _ in 0..<8 {
            let port = UInt16.random(in: 20_000...50_000)
            let settings = MCPSettingsStore(
                store: store,
                repository: repository,
                defaults: defaults,
                allowsExternalServices: true,
                port: port
            )
            settings.setEnabled(true)
            if await waitUntilRunning(settings) {
                runningSettings = settings
                runningPort = port
                break
            }
            settings.setEnabled(false)
        }

        let settings = try #require(runningSettings)
        let port = try #require(runningPort)
        #expect(settings.isEnabled)
        #expect(settings.token.count == 43)

        let response = try await send(
            body: ["jsonrpc": "2.0", "id": 10, "method": "ping"],
            port: port,
            token: settings.token
        )
        #expect(response.statusCode == 200)

        settings.setEnabled(false)
        #expect(!settings.isEnabled)
        #expect(settings.status == .disabled)
    }

    @Test("HTTP 服务完成鉴权并返回工具结果")
    func httpServerRoundTrip() async throws {
        let repository = MCPTestRepository()
        let store = TodayStore(repository: repository)
        let handler = MCPMessageHandler(
            service: MCPTaskService(store: store, repository: repository),
            token: token,
            serverVersion: "test"
        )
        let (server, port) = try await startServer(handler: handler)
        defer { server.stop() }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": [
                "name": "add_task",
                "arguments": ["title": "来自本机 MCP 的任务"],
            ],
        ]
        let unauthorized = try await send(
            body: body,
            port: port,
            token: nil
        )
        #expect(unauthorized.statusCode == 401)

        let authorized = try await send(
            body: body,
            port: port,
            token: token
        )
        #expect(authorized.statusCode == 200)
        let object = try #require(
            JSONSerialization.jsonObject(with: authorized.data) as? [String: Any]
        )
        let result = try #require(object["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(repository.tasks.first?.title == "来自本机 MCP 的任务")
    }

    @Test("list_tasks 从仓储读取包含未来日期的待办")
    func listsTasksFromRepository() async throws {
        let repository = MCPTestRepository()
        let future = TodoTask.protocolCalendar.date(from: DateComponents(
            year: 2027,
            month: 1,
            day: 1,
            hour: 12
        ))!
        repository.tasks = [
            try TodoTask(
                title: "未来任务",
                categoryID: TaskCategory.inboxID,
                startDate: future,
                endDate: future
            ),
        ]
        let store = TodayStore(repository: repository)
        store.reload()
        #expect(store.tasks.isEmpty)
        let handler = makeHandler(store: store, repository: repository)

        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": ["name": "list_tasks", "arguments": [:]],
        ]))

        let object = try decode(response)
        let result = try #require(object["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let tasks = try #require(structured["tasks"] as? [[String: Any]])
        #expect(tasks.compactMap { $0["title"] as? String } == ["未来任务"])
    }

    @Test("list_tags 返回自定义标签与优先级")
    func listsTags() async throws {
        let repository = MCPTestRepository()
        repository.categories = TaskCategory.normalizeList([
            try TaskCategory(id: "work", name: "工作", order: 0),
            try TaskCategory(id: "life", name: "生活", order: 1),
        ])
        let store = TodayStore(repository: repository)
        store.reload()
        let handler = makeHandler(store: store, repository: repository)
        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": ["name": "list_tags", "arguments": [:]],
        ]))

        let object = try decode(response)
        let result = try #require(object["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let tags = try #require(structured["tags"] as? [[String: Any]])
        #expect(tags.compactMap { $0["name"] as? String } == ["工作", "生活"])
        #expect(tags.compactMap { $0["priority"] as? Int } == [1, 2])
    }

    private func makeHandler(
        store: TodayStore? = nil,
        repository: MCPTestRepository? = nil
    ) -> MCPMessageHandler {
        let resolvedRepository = repository ?? MCPTestRepository()
        let resolvedStore = store ?? TodayStore(repository: resolvedRepository)
        return MCPMessageHandler(
            service: MCPTaskService(
                store: resolvedStore,
                repository: resolvedRepository
            ),
            token: token,
            serverVersion: "test"
        )
    }

    private func waitUntilRunning(_ settings: MCPSettingsStore) async -> Bool {
        for _ in 0..<40 {
            switch settings.status {
            case .running:
                return true
            case .failed:
                return false
            case .starting, .disabled:
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        return false
    }

    private func startServer(
        handler: MCPMessageHandler
    ) async throws -> (MCPHTTPServer, UInt16) {
        for _ in 0..<8 {
            let port = UInt16.random(in: 20_000...50_000)
            do {
                let server = try MCPHTTPServer(port: port) { request in
                    await handler.handle(request)
                }
                try await server.start()
                return (server, port)
            } catch {
                continue
            }
        }
        throw MCPToolError(message: "无法启动测试 HTTP 服务")
    }

    private func send(
        body: [String: Any],
        port: UInt16,
        token: String?
    ) async throws -> (statusCode: Int, data: Data) {
        var request = URLRequest(
            url: URL(string: "http://127.0.0.1:\(port)/mcp")!
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func request(
        _ body: [String: Any],
        token: String? = "test-token",
        origin: String? = nil
    ) -> MCPHTTPRequest {
        var headers = ["content-type": "application/json"]
        if let token {
            headers["authorization"] = "Bearer \(token)"
        }
        if let origin {
            headers["origin"] = origin
        }
        return MCPHTTPRequest(
            method: "POST",
            path: "/mcp",
            headers: headers,
            body: try! JSONSerialization.data(withJSONObject: body)
        )
    }

    private func decode(_ response: MCPHTTPResponse) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        )
    }
}

private final class MCPTestRepository: TaskRepository {
    var tasks: [TodoTask] = []
    var categories: [TaskCategory] = TaskCategory.defaults

    func fetchAll() throws -> [TodoTask] { tasks }

    func save(_ tasks: [TodoTask]) throws {
        for task in tasks {
            if let index = self.tasks.firstIndex(where: { $0.id == task.id }) {
                self.tasks[index] = task
            } else {
                self.tasks.append(task)
            }
        }
    }

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool { false }

    func delete(id: UUID) throws {}

    func clearHistory(ids: Set<UUID>?) throws -> Int { 0 }

    func fetchCategories() throws -> [TaskCategory] { categories }

    func saveCategories(_ categories: [TaskCategory]) throws {
        self.categories = categories
    }
}
