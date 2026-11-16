import Foundation
import WooTodoCore

/// 一次 MCP 工具调用的结果；text 面向模型展示，structured 便于客户端读取字段。
struct MCPToolResult {
    let text: String
    let structured: [String: Any]?
    let isError: Bool

    static func success(_ payload: [String: Any]) -> MCPToolResult {
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )) ?? Data()
        return MCPToolResult(
            text: String(decoding: data, as: UTF8.self),
            structured: payload,
            isError: false
        )
    }

    static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, structured: nil, isError: true)
    }
}

struct MCPToolError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// 把 MCP 工具参数映射到本地 TodayStore。所有写入仍走本地仓储和现有同步回调。
@MainActor
final class MCPTaskService {
    private let store: TodayStore
    private let repository: TaskRepository

    init(store: TodayStore, repository: TaskRepository) {
        self.store = store
        self.repository = repository
    }

    static var tools: [[String: Any]] {
        [
            [
                "name": "add_task",
                "description": "在 Woo Todo 中新增一条任务。日期使用 YYYY-MM-DD；不设置日期时任务完成即止；tag 留空表示无标签，新标签会自动创建。",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "任务标题，1–120 个字符",
                        ],
                        "tag": [
                            "type": "string",
                            "description": "标签名称；留空表示无标签。不存在时会自动创建，最多 8 个标签",
                        ],
                        "startDate": [
                            "type": "string",
                            "description": "开始日期，格式 YYYY-MM-DD；必须与 endDate 同时提供",
                        ],
                        "endDate": [
                            "type": "string",
                            "description": "结束日期，格式 YYYY-MM-DD；必须与 startDate 同时提供",
                        ],
                        "reminderTime": [
                            "type": "string",
                            "description": "提醒时间，格式 HH:mm；仅在有起止日期时有效",
                        ],
                    ],
                    "required": ["title"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "list_tasks",
                "description": "查看 Woo Todo 中的任务，便于避免重复添加或了解已有计划。",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "includeCompleted": [
                            "type": "boolean",
                            "description": "是否包含已完成和已放弃任务，默认 false",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "最多返回多少条，默认 50，范围 1–200",
                        ],
                    ],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "list_tags",
                "description": "查看已有标签及其优先级。数字越小，任务列表中的优先级越高。",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    func call(name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "add_task":
            return try addTask(arguments)
        case "list_tasks":
            return try listTasks(arguments)
        case "list_tags":
            return listTags()
        default:
            throw MCPToolError(message: "未知工具：\(name)")
        }
    }

    private func addTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let title = try requiredString(arguments, "title")
        let startDate = try optionalDate(arguments, "startDate")
        let endDate = try optionalDate(arguments, "endDate")
        guard (startDate == nil) == (endDate == nil) else {
            throw MCPToolError(message: "startDate 与 endDate 需要同时提供或同时省略")
        }
        if let startDate, let endDate, startDate > endDate {
            throw MCPToolError(message: "startDate 不能晚于 endDate")
        }

        let reminderValue = try optionalString(arguments, "reminderTime")
        let reminderTime: TaskReminderTime?
        if let reminderValue {
            guard startDate != nil else {
                throw MCPToolError(message: "设置 reminderTime 时需要同时设置起止日期")
            }
            guard let parsed = TaskReminderTime(wireValue: reminderValue) else {
                throw MCPToolError(message: "reminderTime 格式应为 HH:mm")
            }
            reminderTime = parsed
        } else {
            reminderTime = nil
        }

        // 先完成任务本身校验，避免校验失败时留下新建标签。
        _ = try TodoTask(
            title: title,
            categoryID: TaskCategory.inboxID,
            startDate: startDate,
            endDate: endDate,
            reminderTime: reminderTime
        )

        var categoryID = TaskCategory.inboxID
        var tagCreated = false
        if let tag = try optionalString(arguments, "tag") {
            let alreadyExists = store.categories.contains {
                $0.name.compare(
                    tag,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }
            guard let category = store.addCategory(named: tag) else {
                throw MCPToolError(
                    message: store.errorMessage ?? "无法创建标签 \(tag)"
                )
            }
            categoryID = category.id
            tagCreated = !alreadyExists
        }

        guard let task = store.addTask(
            title: title,
            categoryID: categoryID,
            startDate: startDate,
            endDate: endDate,
            reminderTime: reminderTime
        ) else {
            throw MCPToolError(message: store.errorMessage ?? "无法新增任务")
        }

        var payload = taskPayload(task)
        if tagCreated {
            payload["tagCreated"] = true
        }
        return .success([
            "ok": true,
            "task": payload,
        ])
    }

    private func listTasks(_ arguments: [String: Any]) throws -> MCPToolResult {
        let includeCompleted = arguments["includeCompleted"] as? Bool ?? false
        let rawLimit: Int
        if let value = arguments["limit"] as? Int {
            rawLimit = value
        } else if let value = arguments["limit"] as? NSNumber {
            rawLimit = value.intValue
        } else {
            rawLimit = 50
        }
        let limit = min(max(rawLimit, 1), 200)
        let allTasks = try repository.fetchAll()
        let filtered = allTasks
            .filter { includeCompleted || $0.status == .pending }
            .sorted(by: TodoTask.displayOrder)
        let tasks = filtered.prefix(limit).map(taskPayload)
        return .success([
            "tasks": Array(tasks),
            "total": allTasks.count,
            "note": includeCompleted ? "包含已完成和已放弃任务" : "仅包含待办任务",
        ])
    }

    private func listTags() -> MCPToolResult {
        let tags = store.categories
            .filter { $0.id != TaskCategory.inboxID }
            .map { category -> [String: Any] in
                [
                    "name": category.name,
                    "priority": category.order,
                ]
            }
        return .success([
            "tags": tags,
            "maximumTags": TaskCategory.maximumCount,
            "note": "priority 越小优先级越高；新增任务不传 tag 表示无标签",
        ])
    }

    private func taskPayload(_ task: TodoTask) -> [String: Any] {
        var payload: [String: Any] = [
            "id": task.id.uuidString,
            "title": task.title,
            "status": task.status.rawValue,
        ]
        if task.categoryID != TaskCategory.inboxID {
            payload["tag"] = TaskCategory.resolveName(
                id: task.categoryID,
                categories: store.categories
            )
        }
        if let startDate = task.startDate {
            payload["startDate"] = dateString(startDate)
        }
        if let endDate = task.endDate {
            payload["endDate"] = dateString(endDate)
        }
        if let reminderTime = task.reminderTime {
            payload["reminderTime"] = reminderTime.wireValue
        }
        return payload
    }

    private func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = try optionalString(arguments, key) else {
            throw MCPToolError(message: "缺少必填参数 \(key)")
        }
        return value
    }

    private func optionalString(
        _ arguments: [String: Any],
        _ key: String
    ) throws -> String? {
        guard let raw = arguments[key], !(raw is NSNull) else { return nil }
        guard let value = raw as? String else {
            throw MCPToolError(message: "\(key) 必须是字符串")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalDate(_ arguments: [String: Any], _ key: String) throws -> Date? {
        guard let value = try optionalString(arguments, key) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = TodoTask.protocolCalendar
        formatter.timeZone = TodoTask.protocolCalendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value else {
            throw MCPToolError(message: "\(key) 格式应为 YYYY-MM-DD")
        }
        return date
    }

    private func dateString(_ date: Date) -> String {
        let components = TodoTask.protocolCalendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
