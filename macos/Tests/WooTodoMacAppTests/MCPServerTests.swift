import Foundation
import Testing
import WooTodoCore
import WooTodoStorage
@testable import WooTodoMacApp

@Suite("MCP 本机服务")
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
            "add_task", "list_tasks", "list_tags", "get_task", "update_task",
            "complete_task", "reopen_task", "abandon_task", "delete_task",
            "list_trash", "restore_task", "purge_trash", "create_tag",
            "rename_tag", "delete_tag", "reorder_tags", "get_statistics",
            "clear_history",
        ])
        for tool in tools {
            #expect((tool["description"] as? String)?.isEmpty == false)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
            let annotations = try #require(tool["annotations"] as? [String: Any])
            #expect(annotations["openWorldHint"] as? Bool == false)
        }
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

    @Test("add_task 可只设置任务日期")
    func addTaskWithSingleDate() async throws {
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
                    "title": "单日任务",
                    "startDate": "2026-11-16",
                ],
            ],
        ]))

        let result = try #require(try decode(response)["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let addedTask = try #require(structured["task"] as? [String: Any])
        #expect(addedTask["startDate"] as? String == "2026-11-16")
        #expect(addedTask["endDate"] is NSNull)

        let saved = try #require(repository.tasks.first)
        let day = TodoTask.protocolCalendar.startOfDay(
            for: TodoTask.protocolCalendar.date(from: DateComponents(
                year: 2026, month: 11, day: 16
            ))!
        )
        #expect(saved.startDate == day)
        #expect(saved.endDate == day)

        let id = try #require(addedTask["id"] as? String)
        let updated = try await callTool(
            "update_task",
            arguments: ["taskId": id, "startDate": "2026-11-18"],
            handler: handler
        )
        let updatedPayload = try task(in: updated)
        #expect(updatedPayload["startDate"] as? String == "2026-11-18")
        #expect(updatedPayload["endDate"] is NSNull)
        let moved = try #require(repository.tasks.first)
        #expect(moved.endDate == moved.startDate)
    }

    @Test("add_task 和 update_task 支持每天重复")
    func addAndUpdateDailyRecurrence() async throws {
        let repository = MCPTestRepository()
        let handler = makeHandler(repository: repository, now: { testNow })
        let added = try await callTool(
            "add_task",
            arguments: [
                "title": "铲屎",
                "startDate": "2026-11-20",
                "endDate": "2026-11-20",
                "recurrence": "daily",
            ],
            handler: handler
        )
        let addedTask = try task(in: added)
        #expect(addedTask["recurrence"] as? String == "daily")
        let id = try #require(addedTask["id"] as? String)

        let invalid = try await callTool(
            "update_task",
            arguments: [
                "taskId": id,
                "startDate": NSNull(),
                "endDate": NSNull(),
            ],
            handler: handler
        )
        #expect(invalid.isError)

        let updated = try await callTool(
            "update_task",
            arguments: ["taskId": id, "recurrence": "once"],
            handler: handler
        )
        #expect(try task(in: updated)["recurrence"] as? String == "once")
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

    @Test("MCP 服务开关可启动并停止本机服务")
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

    @Test("MCP 默认使用持久化的五位随机端口")
    func portIsPersisted() throws {
        let suite = "io.github.stophemo.woo-todo.mcp-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = MCPTestRepository()
        let first = MCPSettingsStore(
            store: TodayStore(repository: repository),
            repository: repository,
            defaults: defaults,
            allowsExternalServices: false
        )
        let second = MCPSettingsStore(
            store: TodayStore(repository: repository),
            repository: repository,
            defaults: defaults,
            allowsExternalServices: false
        )

        #expect((10_000...65_535).contains(Int(first.port)))
        #expect(first.port == second.port)
        #expect(first.endpointURL.absoluteString.contains(":\(first.port)/mcp"))
    }

    @Test("常用 Agent 命令包含本机地址与令牌")
    func agentSnippetsUseEndpointAndToken() throws {
        let suite = "io.github.stophemo.woo-todo.mcp-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = MCPTestRepository()
        let settings = MCPSettingsStore(
            store: TodayStore(repository: repository),
            repository: repository,
            defaults: defaults,
            allowsExternalServices: false
        )
        let endpoint = settings.endpointURL.absoluteString

        #expect(settings.claudeCodeSnippet.contains(endpoint))
        #expect(settings.claudeCodeSnippet.contains(settings.token))
        #expect(settings.codexSnippet.contains(endpoint))
        #expect(settings.codexSnippet.contains(settings.token))
        #expect(settings.codexSnippet.contains("WOO_TODO_MCP_TOKEN"))
        #expect(settings.piSnippet.contains(endpoint))
        #expect(settings.piSnippet.contains(settings.token))
        #expect(settings.hermesSnippet.contains(endpoint))
        #expect(settings.configurationSnippet.contains(settings.token))
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
        #expect(tags.compactMap { $0["name"] as? String } == ["未分类", "工作", "生活"])
        #expect(tags.compactMap { $0["priority"] as? Int } == [0, 1, 2])
        #expect(tags.compactMap { $0["isFallback"] as? Bool } == [true, false, false])
    }

    @Test("list_tasks 支持状态、标签、日期筛选与分页")
    func listTasksFiltersAndPagination() async throws {
        let repository = MCPTestRepository()
        repository.categories = TaskCategory.normalizeList([
            try TaskCategory(id: "work", name: "工作", order: 0),
            try TaskCategory(id: "life", name: "生活", order: 1),
        ])
        let now = testNow
        repository.tasks = [
            try TodoTask(
                title: "逾期",
                categoryID: "work",
                startDate: day("2026-11-18"),
                endDate: day("2026-11-18"),
                sortIndex: 0,
                createdAt: now
            ),
            try TodoTask(
                title: "今天",
                categoryID: "work",
                startDate: day("2026-11-18"),
                endDate: day("2026-11-19"),
                sortIndex: 1,
                createdAt: now
            ),
            try TodoTask(
                title: "未来",
                categoryID: "life",
                startDate: day("2026-11-20"),
                endDate: day("2026-11-20"),
                sortIndex: 2,
                createdAt: now
            ),
            try TodoTask(
                title: "无日期",
                categoryID: TaskCategory.inboxID,
                sortIndex: 3,
                createdAt: now
            ),
            try TodoTask(
                title: "已完成",
                categoryID: "work",
                status: .completed,
                startDate: day("2026-11-18"),
                endDate: day("2026-11-19"),
                sortIndex: 4,
                createdAt: now,
                completedAt: day("2026-11-19")
            ),
            try TodoTask(
                title: "已放弃",
                categoryID: "life",
                status: .pass,
                startDate: day("2026-11-18"),
                endDate: day("2026-11-18"),
                sortIndex: 5,
                createdAt: now,
                completedAt: day("2026-11-18")
            ),
        ]
        let handler = makeHandler(repository: repository, now: { now })

        let all = try await callTool(
            "list_tasks",
            arguments: ["status": "all"],
            handler: handler
        )
        let allStructured = try structured(of: all)
        let allTasks = try #require(allStructured["tasks"] as? [[String: Any]])
        #expect(allTasks.count == 6)
        #expect(allStructured["total"] as? Int == 6)
        let overdue = try #require(allTasks.first { $0["title"] as? String == "逾期" })
        #expect(overdue["dateState"] as? String == "overdue")
        #expect(overdue["tag"] as? String == "工作")
        #expect(overdue["startDate"] as? String == "2026-11-18")
        #expect(overdue["completedAt"] is NSNull)

        let today = try await callTool(
            "list_tasks",
            arguments: ["due": "today"],
            handler: handler
        )
        let todayTasks = try tasks(in: today)
        #expect(todayTasks.compactMap { $0["title"] as? String } == ["今天"])

        let filtered = try await callTool(
            "list_tasks",
            arguments: ["status": "all", "tag": "工作", "query": "完成"],
            handler: handler
        )
        let filteredTasks = try tasks(in: filtered)
        #expect(filteredTasks.compactMap { $0["title"] as? String } == ["已完成"])

        let page = try await callTool(
            "list_tasks",
            arguments: ["status": "all", "limit": 2, "offset": 1],
            handler: handler
        )
        let pageStructured = try structured(of: page)
        #expect(pageStructured["total"] as? Int == 6)
        #expect(pageStructured["returned"] as? Int == 2)
        #expect(pageStructured["hasMore"] as? Bool == true)

        let history = try await callTool(
            "list_tasks",
            arguments: ["status": "history", "sort": "completed"],
            handler: handler
        )
        let historyTasks = try tasks(in: history)
        #expect(historyTasks.compactMap { $0["title"] as? String } == ["已完成", "已放弃"])
    }

    @Test("update_task 支持部分更新、清空标签与日期")
    func updateTaskSupportsPartialAndClearing() async throws {
        let repository = MCPTestRepository()
        let now = testNow
        let handler = makeHandler(repository: repository, now: { now })
        let added = try await callTool(
            "add_task",
            arguments: [
                "title": "原任务",
                "tag": "工作",
                "startDate": "2026-11-18",
                "endDate": "2026-11-20",
                "reminderTime": "09:30",
            ],
            handler: handler
        )
        let addedTask = try task(in: added)
        let id = try #require(addedTask["id"] as? String)

        let renamed = try await callTool(
            "update_task",
            arguments: ["taskId": id, "title": "只改标题"],
            handler: handler
        )
        let renamedTask = try task(in: renamed)
        #expect(renamedTask["title"] as? String == "只改标题")
        #expect(renamedTask["tag"] as? String == "工作")
        #expect(renamedTask["startDate"] as? String == "2026-11-18")
        #expect(renamedTask["reminderTime"] as? String == "09:30")

        let untagged = try await callTool(
            "update_task",
            arguments: ["taskId": id, "tag": ""],
            handler: handler
        )
        #expect(try task(in: untagged)["tag"] as? String == "未分类")

        let cleared = try await callTool(
            "update_task",
            arguments: [
                "taskId": id,
                "startDate": NSNull(),
                "endDate": NSNull(),
            ],
            handler: handler
        )
        let clearedTask = try task(in: cleared)
        #expect(clearedTask["startDate"] is NSNull)
        #expect(clearedTask["endDate"] is NSNull)
        #expect(clearedTask["reminderTime"] is NSNull)
        let stored = try #require(repository.tasks.first)
        #expect(stored.startDate == nil)
        #expect(stored.endDate == nil)
        #expect(stored.reminderTime == nil)

        _ = try await callTool(
            "complete_task",
            arguments: ["taskId": id],
            handler: handler
        )
        let rejected = try await callTool(
            "update_task",
            arguments: ["taskId": id, "title": "不应写入"],
            handler: handler
        )
        #expect(rejected.isError)
        #expect(rejected.text.contains("不能编辑"))
    }

    @Test("完成、撤销完成与放弃状态流转")
    func taskStatusTransitions() async throws {
        let repository = MCPTestRepository()
        let handler = makeHandler(repository: repository, now: { testNow })
        let added = try await callTool(
            "add_task",
            arguments: ["title": "状态流转"],
            handler: handler
        )
        let id = try #require(try task(in: added)["id"] as? String)

        let completed = try await callTool(
            "complete_task",
            arguments: ["taskId": id],
            handler: handler
        )
        let completedTask = try task(in: completed)
        #expect(completedTask["status"] as? String == "completed")
        #expect(completedTask["completedAt"] is String)

        let completedAgain = try await callTool(
            "complete_task",
            arguments: ["taskId": id],
            handler: handler
        )
        #expect(completedAgain.structured?["changed"] as? Bool == false)

        let reopened = try await callTool(
            "reopen_task",
            arguments: ["taskId": id],
            handler: handler
        )
        #expect(try task(in: reopened)["status"] as? String == "pending")

        let abandoned = try await callTool(
            "abandon_task",
            arguments: ["taskId": id],
            handler: handler
        )
        #expect(try task(in: abandoned)["status"] as? String == "pass")

        let cannotReopen = try await callTool(
            "reopen_task",
            arguments: ["taskId": id],
            handler: handler
        )
        #expect(cannotReopen.isError)
        #expect(cannotReopen.text.contains("最终状态"))

        let cannotComplete = try await callTool(
            "complete_task",
            arguments: ["taskId": id],
            handler: handler
        )
        #expect(cannotComplete.isError)
    }

    @Test("删除进入最近删除并可恢复或永久移除")
    func deleteRestoreAndPurge() async throws {
        let repository = MCPTestRepository()
        let handler = makeHandler(repository: repository, now: { testNow })
        let added = try await callTool(
            "add_task",
            arguments: ["title": "误删任务", "tag": "工作"],
            handler: handler
        )
        let originalID = try #require(try task(in: added)["id"] as? String)

        let deleted = try await callTool(
            "delete_task",
            arguments: ["taskId": originalID],
            handler: handler
        )
        #expect(deleted.structured?["recoverable"] as? Bool == true)
        #expect(repository.tasks.isEmpty)
        #expect(try repository.fetchTrash().count == 1)

        let trash = try await callTool("list_trash", handler: handler)
        let items = try items(in: trash)
        #expect(items.count == 1)
        #expect(items.first?["trashId"] as? String == originalID)

        let restored = try await callTool(
            "restore_task",
            arguments: ["trashId": originalID],
            handler: handler
        )
        let restoredTask = try task(in: restored)
        let newID = try #require(restoredTask["id"] as? String)
        #expect(newID != originalID)
        #expect(restoredTask["title"] as? String == "误删任务")
        #expect(try repository.fetchTrash().isEmpty)

        let fetched = try await callTool(
            "get_task",
            arguments: ["taskId": newID],
            handler: handler
        )
        #expect(fetched.structured?["task"] != nil)

        let second = try await callTool(
            "add_task",
            arguments: ["title": "待永久移除"],
            handler: handler
        )
        let secondID = try #require(try task(in: second)["id"] as? String)
        _ = try await callTool(
            "delete_task",
            arguments: ["taskId": secondID],
            handler: handler
        )
        let missingConfirm = try await callTool(
            "purge_trash",
            arguments: ["all": true],
            handler: handler
        )
        #expect(missingConfirm.isError)
        let purged = try await callTool(
            "purge_trash",
            arguments: ["all": true, "confirm": true],
            handler: handler
        )
        #expect(purged.structured?["removed"] as? Int == 1)
        #expect(try repository.fetchTrash().isEmpty)
    }

    @Test("标签创建、重命名、重排与删除维护任务归属")
    func tagManagement() async throws {
        let repository = MCPTestRepository()
        let handler = makeHandler(repository: repository, now: { testNow })
        let added = try await callTool(
            "add_task",
            arguments: ["title": "带标签任务", "tag": "工作"],
            handler: handler
        )
        let taskID = try #require(try task(in: added)["id"] as? String)
        let existing = try await callTool(
            "create_tag",
            arguments: ["name": "工作"],
            handler: handler
        )
        #expect(existing.structured?["created"] as? Bool == false)
        _ = try await callTool(
            "create_tag",
            arguments: ["name": "生活"],
            handler: handler
        )

        let renamed = try await callTool(
            "rename_tag",
            arguments: ["oldName": "工作", "newName": "项目"],
            handler: handler
        )
        #expect(renamed.structured?["changed"] as? Bool == true)
        let taskAfterRename = try await callTool(
            "get_task",
            arguments: ["taskId": taskID],
            handler: handler
        )
        #expect(try task(in: taskAfterRename)["tag"] as? String == "项目")

        let reordered = try await callTool(
            "reorder_tags",
            arguments: ["names": ["生活", "未分类", "项目"]],
            handler: handler
        )
        let reorderedTags = try tags(in: reordered)
        #expect(reorderedTags.compactMap { $0["name"] as? String } == ["生活", "未分类", "项目"])

        let removed = try await callTool(
            "delete_tag",
            arguments: ["name": "项目"],
            handler: handler
        )
        #expect(removed.structured?["reassignedPendingTasks"] as? Int == 1)
        let taskAfterDelete = try await callTool(
            "get_task",
            arguments: ["taskId": taskID],
            handler: handler
        )
        #expect(try task(in: taskAfterDelete)["tag"] as? String == "未分类")
        let cannotRenameFallback = try await callTool(
            "rename_tag",
            arguments: ["oldName": "未分类", "newName": "其他"],
            handler: handler
        )
        #expect(cannotRenameFallback.isError)
    }

    @Test("get_statistics 返回完成概览与标签分布")
    func statisticsSummary() async throws {
        let repository = MCPTestRepository()
        repository.categories = TaskCategory.normalizeList([
            try TaskCategory(id: "work", name: "工作", order: 0),
        ])
        repository.tasks = [
            try TodoTask(
                title: "本周完成",
                categoryID: "work",
                status: .completed,
                startDate: day("2026-11-17"),
                endDate: day("2026-11-18"),
                createdAt: day("2026-11-17"),
                completedAt: day("2026-11-18")
            ),
            try TodoTask(
                title: "进行中",
                categoryID: "work",
                createdAt: day("2026-11-19")
            ),
        ]
        let handler = makeHandler(repository: repository, now: { testNow })
        let response = try await callTool(
            "get_statistics",
            arguments: ["historyLimit": 1],
            handler: handler
        )
        let structured = try structured(of: response)
        #expect(structured["completedThisWeek"] as? Int == 1)
        #expect(structured["pendingCount"] as? Int == 1)
        #expect((structured["onTimeRate"] as? Double) == 1.0)
        #expect((structured["dailyActivity"] as? [[String: Any]])?.count == 14)
        let tagActivity = try #require(structured["tagActivity"] as? [[String: Any]])
        #expect(tagActivity.first?["tag"] as? String == "工作")
        #expect((structured["recentHistory"] as? [[String: Any]])?.count == 1)
    }

    @Test("clear_history 需要确认并清除指定历史")
    func clearHistoryRequiresConfirmation() async throws {
        let repository = MCPTestRepository()
        let completed = try TodoTask(
            title: "历史任务",
            categoryID: TaskCategory.inboxID,
            status: .completed,
            createdAt: day("2026-11-18"),
            completedAt: day("2026-11-18")
        )
        repository.tasks = [completed]
        let handler = makeHandler(repository: repository, now: { testNow })

        let rejected = try await callTool(
            "clear_history",
            arguments: ["taskIds": [completed.id.uuidString]],
            handler: handler
        )
        #expect(rejected.isError)
        #expect(try repository.fetchAll().count == 1)

        let cleared = try await callTool(
            "clear_history",
            arguments: ["taskIds": [completed.id.uuidString], "confirm": true],
            handler: handler
        )
        #expect(cleared.structured?["removed"] as? Int == 1)
        #expect(try repository.fetchAll().isEmpty)
    }

    @Test("真实 SQLite 仓储支持 MCP 任务生命周期")
    func realSQLiteTaskLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woo-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try SQLiteTaskRepository(
            databaseURL: directory.appendingPathComponent("tasks.sqlite")
        )
        let store = TodayStore(repository: repository)
        store.reload()
        let handler = makeHandler(store: store, repository: repository, now: { testNow })

        let added = try await callTool(
            "add_task",
            arguments: ["title": "真实仓储任务", "tag": "工作"],
            handler: handler
        )
        let id = try #require(try task(in: added)["id"] as? String)

        let updated = try await callTool(
            "update_task",
            arguments: ["taskId": id, "title": "已修改", "tag": "生活"],
            handler: handler
        )
        #expect(try task(in: updated)["title"] as? String == "已修改")
        #expect(try task(in: updated)["tag"] as? String == "生活")

        _ = try await callTool(
            "complete_task",
            arguments: ["taskId": id],
            handler: handler
        )
        _ = try await callTool(
            "reopen_task",
            arguments: ["taskId": id],
            handler: handler
        )
        let reopened = try await callTool(
            "get_task",
            arguments: ["taskId": id],
            handler: handler
        )
        #expect(try task(in: reopened)["status"] as? String == "pending")

        _ = try await callTool(
            "delete_task",
            arguments: ["taskId": id],
            handler: handler
        )
        #expect(try repository.fetchAll().isEmpty)
        let trash = try await callTool("list_trash", handler: handler)
        #expect(try items(in: trash).count == 1)

        let restored = try await callTool(
            "restore_task",
            arguments: ["trashId": id],
            handler: handler
        )
        let restoredTask = try task(in: restored)
        let restoredID = try #require(restoredTask["id"] as? String)
        #expect(restoredID != id)
        #expect(try repository.fetchAll().count == 1)
        #expect(try repository.fetchTrash().isEmpty)
    }

    private var testNow: Date {
        TodoTask.protocolCalendar.date(from: DateComponents(
            year: 2026,
            month: 11,
            day: 19,
            hour: 12
        ))!
    }

    private func day(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = TodoTask.protocolCalendar
        formatter.timeZone = TodoTask.protocolCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value)!
    }

    private func makeHandler(
        store: TodayStore? = nil,
        repository: TaskRepository? = nil,
        now: @escaping () -> Date = Date.init
    ) -> MCPMessageHandler {
        let resolvedRepository = repository ?? MCPTestRepository()
        let resolvedStore = store ?? TodayStore(repository: resolvedRepository)
        return MCPMessageHandler(
            service: MCPTaskService(
                store: resolvedStore,
                repository: resolvedRepository,
                now: now
            ),
            token: token,
            serverVersion: "test"
        )
    }

    private typealias ToolCallResult = (
        isError: Bool,
        structured: [String: Any]?,
        text: String
    )

    private func callTool(
        _ name: String,
        arguments: [String: Any] = [:],
        handler: MCPMessageHandler
    ) async throws -> ToolCallResult {
        let response = await handler.handle(request([
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ]))
        let object = try decode(response)
        let result = try #require(object["result"] as? [String: Any])
        let content = result["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        return (
            result["isError"] as? Bool ?? false,
            result["structuredContent"] as? [String: Any],
            text
        )
    }

    private func structured(of result: ToolCallResult) throws -> [String: Any] {
        try #require(result.structured)
    }

    private func task(in result: ToolCallResult) throws -> [String: Any] {
        try #require(try structured(of: result)["task"] as? [String: Any])
    }

    private func tasks(in result: ToolCallResult) throws -> [[String: Any]] {
        try #require(try structured(of: result)["tasks"] as? [[String: Any]])
    }

    private func items(in result: ToolCallResult) throws -> [[String: Any]] {
        try #require(try structured(of: result)["items"] as? [[String: Any]])
    }

    private func tags(in result: ToolCallResult) throws -> [[String: Any]] {
        try #require(try structured(of: result)["tags"] as? [[String: Any]])
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
    var trash: [TrashedTask] = []

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

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].status == .completed else { return false }
        tasks[index].status = .pending
        tasks[index].completedAt = nil
        tasks[index].updatedAt = date
        return true
    }

    func delete(id: UUID) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: index)
        trash.append(TrashedTask(task: task, deletedAt: Date()))
    }

    func clearHistory(ids: Set<UUID>?) throws -> Int {
        let targets = tasks.filter {
            $0.status != .pending && (ids == nil || ids?.contains($0.id) == true)
        }
        tasks.removeAll {
            $0.status != .pending && (ids == nil || ids?.contains($0.id) == true)
        }
        return targets.count
    }

    func fetchTrash() throws -> [TrashedTask] { trash }

    func trashCount() throws -> Int { trash.count }

    func restoreTrash(id: UUID, at date: Date) throws -> UUID? {
        guard let index = trash.firstIndex(where: { $0.id == id }) else { return nil }
        let item = trash.remove(at: index)
        let categoryID = categories.contains(where: { $0.id == item.task.categoryID })
            ? item.task.categoryID
            : TaskCategory.inboxID
        let restored = try TodoTask(
            id: UUID(),
            seriesID: item.task.seriesID,
            title: item.task.title,
            categoryID: categoryID,
            status: .pending,
            startDate: item.task.startDate,
            endDate: item.task.endDate,
            sortIndex: item.task.sortIndex,
            createdAt: item.task.createdAt,
            updatedAt: date,
            reminderTime: item.task.reminderTime,
            completedAt: nil
        )
        tasks.append(restored)
        return restored.id
    }

    func removeTrash(ids: Set<UUID>?) throws -> Int {
        let count = trash.count
        trash.removeAll { ids == nil || ids?.contains($0.id) == true }
        return count - trash.count
    }

    func fetchCategories() throws -> [TaskCategory] { categories }

    func saveCategories(_ categories: [TaskCategory]) throws {
        self.categories = categories
    }

    func reassignPendingCategory(from: String, to: String, at date: Date) throws -> Int {
        var count = 0
        for index in tasks.indices where tasks[index].status == .pending
            && tasks[index].categoryID == from {
            tasks[index].categoryID = to
            tasks[index].updatedAt = date
            count += 1
        }
        return count
    }
}
