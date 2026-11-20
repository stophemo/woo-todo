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

/// 把 MCP 工具参数映射到本地仓储。所有写入仍走现有仓储、同步回调与 UI 刷新路径。
@MainActor
final class MCPTaskService {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let statusValues = ["pending", "completed", "pass", "history", "all"]
    private static let dueValues = ["overdue", "today", "upcoming", "unscheduled"]
    private static let sortValues = ["priority", "created", "updated", "completed", "due"]

    private let store: TodayStore
    private let repository: TaskRepository
    private let now: () -> Date

    init(
        store: TodayStore,
        repository: TaskRepository,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.repository = repository
        self.now = now
    }

    static var tools: [[String: Any]] {
        let taskId = [
            "type": "string",
            "description": "任务 UUID，来自 list_tasks 的 id；不要编造",
        ] as [String: Any]
        let trashId = [
            "type": "string",
            "description": "最近删除任务的 trashId，来自 list_trash；不要编造",
        ] as [String: Any]
        let scheduleProperties: [String: Any] = [
            "startDate": [
                "type": "string",
                "description": "开始日期，格式 YYYY-MM-DD（Asia/Shanghai）；必须与 endDate 同时提供",
            ],
            "endDate": [
                "type": "string",
                "description": "结束日期，格式 YYYY-MM-DD（Asia/Shanghai）；必须与 startDate 同时提供",
            ],
            "reminderTime": [
                "type": "string",
                "description": "提醒时间，格式 HH:mm；只有设置起止日期时才能使用",
            ],
        ]

        return [
            toolDefinition(
                name: "list_tasks",
                description: """
                查询任务并取得后续写入操作需要的 id。默认只返回待办任务，按标签优先级、结束日期和创建顺序排列。
                每条任务包含 id、status、tag、起止日期、提醒、dateState、创建/更新/完成时间和是否逾期。
                建议先用 query、tag、due 缩小范围，再对具体 id 调用其他工具。
                """,
                readOnly: true,
                idempotent: true,
                properties: [
                    "status": [
                        "type": "string",
                        "enum": statusValues,
                        "description": "pending 待办（默认）；completed 已完成；pass 已放弃；history 已完成或已放弃；all 全部",
                    ],
                    "includeCompleted": [
                        "type": "boolean",
                        "description": "兼容旧参数；为 true 时等价于 status=all，已被 status 取代",
                    ],
                    "tag": [
                        "type": "string",
                        "description": "按标签名称精确筛选（忽略大小写）；未分类使用“未分类”",
                    ],
                    "query": [
                        "type": "string",
                        "description": "按标题子串筛选，忽略大小写",
                    ],
                    "due": [
                        "type": "string",
                        "enum": dueValues,
                        "description": "按待办日期状态筛选：overdue 已逾期；today 今天进行中；upcoming 未来开始；unscheduled 无日期。仅对待办有意义",
                    ],
                    "sort": [
                        "type": "string",
                        "enum": sortValues,
                        "description": "排序方式；默认 priority。查询历史时建议使用 completed",
                    ],
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 200,
                        "default": 50,
                        "description": "最多返回多少条，默认 50",
                    ],
                    "offset": [
                        "type": "integer",
                        "minimum": 0,
                        "default": 0,
                        "description": "跳过多少条，用于分页",
                    ],
                ],
            ),
            toolDefinition(
                name: "get_task",
                description: "按 id 读取一条任务的完整状态。写入前可用它确认标题、标签、日期和状态；最近删除中的任务请用 list_trash。",
                readOnly: true,
                idempotent: true,
                properties: ["taskId": taskId],
                required: ["taskId"],
            ),
            toolDefinition(
                name: "add_task",
                description: """
                新增一条待办。日期必须成对提供；不设置日期表示完成即止。
                tag 留空表示无标签；不存在的标签会自动创建。返回完整任务，包含新 id 和 tagCreated。
                """,
                properties: [
                    "title": [
                        "type": "string",
                        "description": "任务标题，去除首尾空白后 1–120 个字符",
                    ],
                    "tag": [
                        "type": "string",
                        "description": "标签名称；留空表示无标签。不区分大小写，不存在时自动创建",
                    ],
                    "startDate": scheduleProperties["startDate"]!,
                    "endDate": scheduleProperties["endDate"]!,
                    "reminderTime": scheduleProperties["reminderTime"]!,
                    "recurrence": [
                        "type": "string",
                        "enum": ["once", "daily"],
                        "default": "once",
                        "description": "重复方式；daily 表示每天生成一条新任务，必须设置起止日期。过期未完成的上一条会自动记为放弃",
                    ],
                ],
                required: ["title"],
            ),
            toolDefinition(
                name: "update_task",
                description: """
                修改一条待办的部分字段。只传需要修改的字段，未传字段保持原值。
                tag 传空字符串或 null 清除标签；startDate/endDate 必须成对传，传 null 清除日期并同时清除提醒；reminderTime 传 null 或空字符串清除提醒。
                仅待办可编辑。已完成任务请先 reopen_task；已放弃任务是最终状态。
                """,
                idempotent: true,
                properties: [
                    "taskId": taskId,
                    "title": [
                        "type": "string",
                        "description": "新标题；省略则保持原值",
                    ],
                    "tag": [
                        "type": ["string", "null"],
                        "description": "新标签名称；空字符串或 null 表示移到未分类；省略则保持原值。不存在的标签会自动创建",
                    ],
                    "startDate": [
                        "type": ["string", "null"],
                        "description": "新开始日期 YYYY-MM-DD；与 endDate 一起传 null 可清除日期。省略则保持原日期",
                    ],
                    "endDate": [
                        "type": ["string", "null"],
                        "description": "新结束日期 YYYY-MM-DD；与 startDate 一起传 null 可清除日期。省略则保持原日期",
                    ],
                    "reminderTime": [
                        "type": ["string", "null"],
                        "description": "新提醒 HH:mm；空字符串或 null 清除提醒；省略则保持原提醒",
                    ],
                    "recurrence": [
                        "type": "string",
                        "enum": ["once", "daily"],
                        "description": "重复方式；daily 每天生成一条新任务，必须保留起止日期；省略则保持原值",
                    ],
                ],
                required: ["taskId"],
            ),
            toolDefinition(
                name: "complete_task",
                description: "把一条待办标记为已完成。已完成任务再次调用会返回 changed=false；已放弃任务不能完成。",
                idempotent: true,
                properties: ["taskId": taskId],
                required: ["taskId"],
            ),
            toolDefinition(
                name: "reopen_task",
                description: "撤销一条已完成任务，把它恢复为待办。已放弃任务不能恢复。",
                idempotent: true,
                properties: ["taskId": taskId],
                required: ["taskId"],
            ),
            toolDefinition(
                name: "abandon_task",
                description: "放弃一条待办，任务进入历史，状态变为 pass。放弃是最终状态，不能撤销；已完成任务如需放弃请先 reopen_task。",
                idempotent: true,
                properties: ["taskId": taskId],
                required: ["taskId"],
            ),
            toolDefinition(
                name: "delete_task",
                description: "删除一条待办。任务会移入本机“最近删除”，可通过 list_trash 和 restore_task 恢复；删除会同步到其他设备。只能删除待办。",
                destructive: true,
                properties: ["taskId": taskId],
                required: ["taskId"],
            ),
            toolDefinition(
                name: "list_trash",
                description: "列出本机“最近删除”中的任务。每条包含 trashId（恢复时使用）、删除时间和原任务完整字段。",
                readOnly: true,
                idempotent: true,
                properties: [
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 200,
                        "default": 50,
                        "description": "最多返回多少条，默认 50",
                    ],
                    "offset": [
                        "type": "integer",
                        "minimum": 0,
                        "default": 0,
                        "description": "跳过多少条，用于分页",
                    ],
                ],
            ),
            toolDefinition(
                name: "restore_task",
                description: "从最近删除恢复一条任务。恢复会创建新的任务 id（原 id 已删除），并像新增任务一样同步到其他设备；返回新任务。",
                properties: [
                    "trashId": [
                        "type": "string",
                        "description": "最近删除任务的 trashId，来自 list_trash；恢复后会生成新的任务 id",
                    ],
                ],
                required: ["trashId"],
            ),
            toolDefinition(
                name: "purge_trash",
                description: "永久移除本机最近删除中的恢复副本，不可再恢复。不会删除其他设备上的数据，也不会产生新的同步删除记录。必须传 confirm=true。",
                destructive: true,
                idempotent: true,
                properties: [
                    "trashIds": [
                        "type": "array",
                        "items": trashId,
                        "description": "要永久移除的 trashId 列表；all=true 时可省略",
                    ],
                    "all": [
                        "type": "boolean",
                        "default": false,
                        "description": "为 true 时清空全部最近删除",
                    ],
                    "confirm": [
                        "type": "boolean",
                        "description": "永久操作确认，必须为 true",
                    ],
                ],
                required: ["confirm"],
            ),
            toolDefinition(
                name: "list_tags",
                description: "列出全部标签，包括未分类兜底标签。返回 id、名称、优先级、是否为兜底标签，以及待办数和总任务数。",
                readOnly: true,
                idempotent: true,
                properties: [:],
            ),
            toolDefinition(
                name: "create_tag",
                description: "创建标签；已存在同名标签时直接返回现有标签（created=false）。标签名称最长 12 个字符，最多 8 个标签（含未分类）。",
                idempotent: true,
                properties: [
                    "name": [
                        "type": "string",
                        "description": "标签名称，1–12 个字符；忽略大小写去重",
                    ],
                ],
                required: ["name"],
            ),
            toolDefinition(
                name: "rename_tag",
                description: "重命名自定义标签。未分类兜底标签不能改名；新名称不能与其他标签重名。",
                idempotent: true,
                properties: [
                    "oldName": [
                        "type": "string",
                        "description": "当前标签名称",
                    ],
                    "newName": [
                        "type": "string",
                        "description": "新标签名称，1–12 个字符",
                    ],
                ],
                required: ["oldName", "newName"],
            ),
            toolDefinition(
                name: "delete_tag",
                description: "删除自定义标签。该标签下的待办会移到未分类；返回受影响的待办数量。未分类不能删除。",
                destructive: true,
                idempotent: true,
                properties: [
                    "name": [
                        "type": "string",
                        "description": "要删除的标签名称",
                    ],
                ],
                required: ["name"],
            ),
            toolDefinition(
                name: "reorder_tags",
                description: "按给定顺序重排全部标签优先级。names 必须包含当前所有标签名称（包括“未分类”），不能重复或遗漏；第 0 个优先级最高。",
                idempotent: true,
                properties: [
                    "names": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "按优先级从高到低排列的完整标签名称列表",
                    ],
                ],
                required: ["names"],
            ),
            toolDefinition(
                name: "get_statistics",
                description: "读取完成统计：本周完成、连续天数、按时率、进行中数量、最近 14 天完成趋势、近 30 天标签分布和最近历史。只统计明确完成的任务。",
                readOnly: true,
                idempotent: true,
                properties: [
                    "historyLimit": [
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 200,
                        "default": 20,
                        "description": "最近历史返回多少条，默认 20",
                    ],
                ],
            ),
            toolDefinition(
                name: "clear_history",
                description: "从本机历史中永久清除已完成或已放弃任务，并同步删除记录。必须传 confirm=true；不传 all=true 时必须提供 taskIds。",
                destructive: true,
                idempotent: true,
                properties: [
                    "taskIds": [
                        "type": "array",
                        "items": taskId,
                        "description": "要清除历史的任务 id 列表；all=true 时可省略",
                    ],
                    "all": [
                        "type": "boolean",
                        "default": false,
                        "description": "为 true 时清除全部历史",
                    ],
                    "confirm": [
                        "type": "boolean",
                        "description": "永久操作确认，必须为 true",
                    ],
                ],
                required: ["confirm"],
            ),
        ]
    }

    func call(name: String, arguments: [String: Any]) throws -> MCPToolResult {
        switch name {
        case "list_tasks": return try listTasks(arguments)
        case "get_task": return try getTask(arguments)
        case "add_task": return try addTask(arguments)
        case "update_task": return try updateTask(arguments)
        case "complete_task": return try completeTask(arguments)
        case "reopen_task": return try reopenTask(arguments)
        case "abandon_task": return try abandonTask(arguments)
        case "delete_task": return try deleteTask(arguments)
        case "list_trash": return try listTrash(arguments)
        case "restore_task": return try restoreTask(arguments)
        case "purge_trash": return try purgeTrash(arguments)
        case "list_tags": return try listTags()
        case "create_tag": return try createTag(arguments)
        case "rename_tag": return try renameTag(arguments)
        case "delete_tag": return try deleteTag(arguments)
        case "reorder_tags": return try reorderTags(arguments)
        case "get_statistics": return try getStatistics(arguments)
        case "clear_history": return try clearHistory(arguments)
        default:
            throw MCPToolError(message: "未知工具：\(name)")
        }
    }

    // MARK: - 读取

    private func listTasks(_ arguments: [String: Any]) throws -> MCPToolResult {
        store.settleRecurringTasks()
        let today = calendar.startOfDay(for: now())
        let categories = try normalizedCategories()
        let status = try listStatus(arguments)
        let limit = try integerArgument(arguments, "limit", default: 50, range: 1...200)
        let offset = try integerArgument(arguments, "offset", default: 0, range: 0...100_000)

        var tasks = try repository.fetchAll()
        switch status {
        case .pending:
            tasks = tasks.filter { $0.status == .pending }
        case .completed:
            tasks = tasks.filter { $0.status == .completed }
        case .pass:
            tasks = tasks.filter { $0.status == .pass }
        case .history:
            tasks = tasks.filter { $0.status != .pending }
        case .all:
            break
        }
        if let tagName = try optionalString(arguments, "tag") {
            guard let category = matchCategory(tagName, in: categories) else {
                throw MCPToolError(message: "标签不存在：\(tagName)；请先调用 list_tags")
            }
            tasks = tasks.filter { $0.categoryID == category.id }
        }
        if let query = try optionalString(arguments, "query") {
            tasks = tasks.filter {
                $0.title.range(
                    of: query,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
        if let due = try optionalString(arguments, "due") {
            guard Self.dueValues.contains(due) else {
                throw MCPToolError(
                    message: "due 只能是 \(Self.dueValues.joined(separator: "/"))"
                )
            }
            tasks = tasks.filter { dateState($0, today: today) == due }
        }

        let sort = try optionalString(arguments, "sort") ?? "priority"
        guard Self.sortValues.contains(sort) else {
            throw MCPToolError(
                message: "sort 只能是 \(Self.sortValues.joined(separator: "/"))"
            )
        }
        tasks = sortedTasks(tasks, by: sort, categories: categories)
        let total = tasks.count
        let page = tasks.dropFirst(offset).prefix(limit)
        return .success([
            "tasks": page.map {
                taskPayload($0, categories: categories, today: today)
            },
            "total": total,
            "returned": page.count,
            "offset": offset,
            "hasMore": offset + page.count < total,
            "today": dateString(today),
            "timeZone": "Asia/Shanghai",
        ])
    }

    private func getTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        store.settleRecurringTasks()
        let id = try requiredUUID(arguments, "taskId")
        let today = calendar.startOfDay(for: now())
        let categories = try normalizedCategories()
        if let task = try repository.fetchAll().first(where: { $0.id == id }) {
            return .success([
                "task": taskPayload(task, categories: categories, today: today),
                "today": dateString(today),
            ])
        }
        if try repository.fetchTrash().contains(where: { $0.id == id }) {
            throw MCPToolError(
                message: "任务 \(id.uuidString) 在最近删除中；请用 list_trash 查看并用 restore_task 恢复"
            )
        }
        throw MCPToolError(
            message: "未找到任务 \(id.uuidString)；请先调用 list_tasks 获取有效 id"
        )
    }

    private func listTrash(_ arguments: [String: Any]) throws -> MCPToolResult {
        let limit = try integerArgument(arguments, "limit", default: 50, range: 1...200)
        let offset = try integerArgument(arguments, "offset", default: 0, range: 0...100_000)
        let today = calendar.startOfDay(for: now())
        let categories = try normalizedCategories()
        let trash = try repository.fetchTrash().sorted {
            if $0.deletedAt != $1.deletedAt { return $0.deletedAt > $1.deletedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let total = trash.count
        let page = trash.dropFirst(offset).prefix(limit)
        return .success([
            "items": page.map { item in
                [
                    "trashId": item.id.uuidString,
                    "deletedAt": timestampValue(item.deletedAt),
                    "task": taskPayload(item.task, categories: categories, today: today),
                ] as [String: Any]
            },
            "total": total,
            "returned": page.count,
            "offset": offset,
            "hasMore": offset + page.count < total,
            "note": "恢复会生成新的任务 id，并同步到其他设备",
        ])
    }

    private func listTags() throws -> MCPToolResult {
        let categories = try normalizedCategories()
        let tasks = try repository.fetchAll()
        let payload = categories.map { category -> [String: Any] in
            let matching = tasks.filter { $0.categoryID == category.id }
            return [
                "id": category.id,
                "name": category.name,
                "priority": category.order,
                "isFallback": category.id == TaskCategory.inboxID,
                "pendingTaskCount": matching.filter { $0.status == .pending }.count,
                "totalTaskCount": matching.count,
            ]
        }
        return .success([
            "tags": payload,
            "maximumTags": TaskCategory.maximumCount,
            "maximumNameLength": TaskCategory.maximumNameLength,
            "fallbackTagId": TaskCategory.inboxID,
            "note": "priority 越小优先级越高；未分类是兜底标签，不能删除或改名",
        ])
    }

    private func getStatistics(_ arguments: [String: Any]) throws -> MCPToolResult {
        store.settleRecurringTasks()
        let historyLimit = try integerArgument(
            arguments,
            "historyLimit",
            default: 20,
            range: 0...200
        )
        let today = calendar.startOfDay(for: now())
        let categories = try normalizedCategories()
        let snapshot = StatisticsEngine().calculate(
            tasks: try repository.fetchAll(),
            at: now(),
            historyLimit: historyLimit
        )
        return .success([
            "today": dateString(today),
            "timeZone": "Asia/Shanghai",
            "completedThisWeek": snapshot.completedThisWeek,
            "currentStreakDays": snapshot.currentStreakDays,
            "onTimeRate": snapshot.onTimeRate.map { $0 as Any } ?? NSNull(),
            "pendingCount": snapshot.pendingCount,
            "dailyActivity": snapshot.dailyActivity.map {
                ["date": dateString($0.date), "completed": $0.completed]
            },
            "tagActivity": snapshot.categoryActivity.map {
                [
                    "tag": TaskCategory.resolveName(
                        id: $0.categoryID,
                        categories: categories
                    ),
                    "completed": $0.completed,
                    "ratio": $0.ratio,
                ] as [String: Any]
            },
            "recentHistory": snapshot.recentHistory.map {
                taskPayload($0, categories: categories, today: today)
            },
            "note": "onTimeRate 为 0–1 的小数，没有带截止日期的完成任务时为 null；标签分布统计近 30 天",
        ])
    }

    // MARK: - 任务写入

    private func addTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let title = try requiredString(arguments, "title")
        let schedule = try scheduleArguments(arguments)
        let recurrence = try recurrenceArgument(arguments, default: .once)
        guard recurrence != .daily || schedule.startDate != nil else {
            throw MCPToolError(message: "每天重复的任务必须设置起止日期")
        }
        let categories = try normalizedCategories()

        // 先校验任务本身，避免校验失败时留下新建标签。
        _ = try TodoTask(
            title: title,
            categoryID: TaskCategory.inboxID,
            startDate: schedule.startDate,
            endDate: schedule.endDate,
            reminderTime: schedule.reminderTime,
            recurrence: recurrence
        )

        let originalTag = try optionalString(arguments, "tag")
        var categoryID = TaskCategory.inboxID
        var tagCreated = false
        if let originalTag {
            if let matched = matchCategory(originalTag, in: categories) {
                categoryID = matched.id
            } else {
                categoryID = try createTagID(named: originalTag, in: categories)
                tagCreated = true
            }
        }
        let date = now()
        let task = try TodoTask(
            title: title,
            categoryID: categoryID,
            startDate: schedule.startDate,
            endDate: schedule.endDate,
            sortIndex: nextSortIndex(),
            createdAt: date,
            reminderTime: schedule.reminderTime,
            recurrence: recurrence
        )
        try repository.save(task)
        notifyChange()
        let refreshed = try normalizedCategories()
        var payload = taskPayload(
            task,
            categories: refreshed,
            today: calendar.startOfDay(for: date)
        )
        payload["tagCreated"] = tagCreated
        return .success(["ok": true, "task": payload])
    }

    private func updateTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let id = try requiredUUID(arguments, "taskId")
        let categories = try normalizedCategories()
        guard var existing = try repository.fetchAll().first(where: { $0.id == id }) else {
            throw MCPToolError(
                message: "未找到任务 \(id.uuidString)；请先调用 list_tasks 获取有效 id"
            )
        }
        guard existing.status == .pending else {
            throw MCPToolError(
                message: "任务 \(id.uuidString) 当前为 \(existing.status.displayName)，不能编辑；已完成任务可先 reopen_task"
            )
        }

        let keys = Set(arguments.keys)
        guard keys.contains(where: {
            ["title", "tag", "startDate", "endDate", "reminderTime", "recurrence"].contains($0)
        }) else {
            throw MCPToolError(message: "没有需要更新的字段")
        }

        let title = keys.contains("title")
            ? try requiredString(arguments, "title")
            : existing.title
        let datesProvided = keys.contains("startDate") || keys.contains("endDate")
        guard !datesProvided || (keys.contains("startDate") && keys.contains("endDate")) else {
            throw MCPToolError(message: "startDate 与 endDate 需要同时提供或同时省略")
        }
        let schedule: (startDate: Date?, endDate: Date?)
        if datesProvided {
            schedule = (
                try optionalDate(arguments, "startDate"),
                try optionalDate(arguments, "endDate")
            )
        } else {
            schedule = (existing.startDate, existing.endDate)
        }
        guard (schedule.startDate == nil) == (schedule.endDate == nil) else {
            throw MCPToolError(message: "startDate 与 endDate 需要同时提供或同时省略")
        }
        if let start = schedule.startDate, let end = schedule.endDate, start > end {
            throw MCPToolError(message: "startDate 不能晚于 endDate")
        }

        let recurrence = keys.contains("recurrence")
            ? try recurrenceArgument(arguments, default: existing.recurrence)
            : existing.recurrence
        guard recurrence != .daily || schedule.startDate != nil else {
            throw MCPToolError(message: "每天重复的任务必须设置起止日期")
        }
        var reminder = existing.reminderTime
        if keys.contains("reminderTime") {
            if let value = try optionalString(arguments, "reminderTime") {
                guard let parsed = TaskReminderTime(wireValue: value) else {
                    throw MCPToolError(message: "reminderTime 格式应为 HH:mm")
                }
                reminder = parsed
            } else {
                reminder = nil
            }
        }
        if schedule.startDate == nil {
            reminder = nil
        }

        // 先用未分类占位校验标题、日期和提醒，再解析可能新建的标签。
        _ = try TodoTask(
            id: existing.id,
            seriesID: existing.seriesID,
            title: title,
            categoryID: TaskCategory.inboxID,
            status: .pending,
            startDate: schedule.startDate,
            endDate: schedule.endDate,
            sortIndex: existing.sortIndex,
            createdAt: existing.createdAt,
            updatedAt: now(),
            reminderTime: reminder,
            completedAt: nil,
            recurrence: recurrence
        )

        var categoryID = existing.categoryID
        if keys.contains("tag") {
            if let tagName = try optionalString(arguments, "tag") {
                if let matched = matchCategory(tagName, in: categories) {
                    categoryID = matched.id
                } else {
                    categoryID = try createTagID(named: tagName, in: categories)
                }
            } else {
                categoryID = TaskCategory.inboxID
            }
        } else if !categories.contains(where: { $0.id == categoryID }) {
            categoryID = TaskCategory.inboxID
        }

        let changed = existing.title != title
            || existing.categoryID != categoryID
            || existing.startDate != schedule.startDate
            || existing.endDate != schedule.endDate
            || existing.reminderTime != reminder
            || existing.recurrence != recurrence
        let date = now()
        existing.title = title
        existing.categoryID = categoryID
        existing.startDate = schedule.startDate.map { calendar.startOfDay(for: $0) }
        existing.endDate = schedule.endDate.map { calendar.startOfDay(for: $0) }
        existing.reminderTime = existing.startDate == nil ? nil : reminder
        existing.recurrence = recurrence
        if changed {
            existing.updatedAt = date
            try repository.save(existing)
            notifyChange()
        }
        let refreshed = try normalizedCategories()
        return .success([
            "ok": true,
            "changed": changed,
            "task": taskPayload(
                existing,
                categories: refreshed,
                today: calendar.startOfDay(for: date)
            ),
        ])
    }

    private func completeTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let id = try requiredUUID(arguments, "taskId")
        let date = now()
        guard var task = try repository.fetchAll().first(where: { $0.id == id }) else {
            throw MCPToolError(message: "未找到任务 \(id.uuidString)；请先调用 list_tasks")
        }
        switch task.status {
        case .completed:
            return try taskResult(task, changed: false, date: date)
        case .pass:
            throw MCPToolError(message: "任务 \(id.uuidString) 已放弃，不能标记为完成")
        case .pending:
            break
        }
        task.status = .completed
        task.completedAt = date
        task.updatedAt = date
        try repository.save(task)
        notifyChange()
        return try taskResult(task, changed: true, date: date)
    }

    private func reopenTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let id = try requiredUUID(arguments, "taskId")
        let date = now()
        guard let task = try repository.fetchAll().first(where: { $0.id == id }) else {
            throw MCPToolError(message: "未找到任务 \(id.uuidString)；请先调用 list_tasks")
        }
        if task.status == .pending {
            return try taskResult(task, changed: false, date: date)
        }
        guard task.status == .completed else {
            throw MCPToolError(message: "任务 \(id.uuidString) 已放弃，放弃是最终状态，不能撤销")
        }
        guard try repository.reopenCompleted(id: id, at: date) else {
            throw MCPToolError(message: "无法撤销任务 \(id.uuidString) 的完成状态")
        }
        notifyChange()
        guard let updated = try repository.fetchAll().first(where: { $0.id == id }) else {
            throw MCPToolError(message: "任务已撤销完成，但读取最新状态失败")
        }
        return try taskResult(updated, changed: true, date: date)
    }

    private func abandonTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let id = try requiredUUID(arguments, "taskId")
        let date = now()
        guard var task = try repository.fetchAll().first(where: { $0.id == id }) else {
            throw MCPToolError(message: "未找到任务 \(id.uuidString)；请先调用 list_tasks")
        }
        switch task.status {
        case .pass:
            return try taskResult(task, changed: false, date: date)
        case .completed:
            throw MCPToolError(
                message: "任务 \(id.uuidString) 已完成，不能直接放弃；如需放弃请先 reopen_task"
            )
        case .pending:
            break
        }
        task.status = .pass
        task.completedAt = date
        task.updatedAt = date
        try repository.save(task)
        notifyChange()
        return try taskResult(task, changed: true, date: date)
    }

    private func deleteTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let id = try requiredUUID(arguments, "taskId")
        guard let task = try repository.fetchAll().first(where: { $0.id == id }) else {
            throw MCPToolError(message: "未找到任务 \(id.uuidString)；请先调用 list_tasks")
        }
        guard task.status == .pending else {
            throw MCPToolError(
                message: "任务 \(id.uuidString) 当前为 \(task.status.displayName)，不能删除；只有待办可以删除"
            )
        }
        try repository.delete(id: id)
        notifyChange()
        return .success([
            "ok": true,
            "deleted": [
                "id": task.id.uuidString,
                "trashId": task.id.uuidString,
                "title": task.title,
            ],
            "recoverable": true,
            "note": "任务已移到最近删除；可用 list_trash 查看并 restore_task 恢复",
        ])
    }

    private func restoreTask(_ arguments: [String: Any]) throws -> MCPToolResult {
        let id = try requiredUUID(arguments, "trashId")
        let date = now()
        guard let restoredID = try repository.restoreTrash(id: id, at: date) else {
            throw MCPToolError(
                message: "最近删除中没有任务 \(id.uuidString)；请先调用 list_trash"
            )
        }
        notifyChange()
        guard let restored = try repository.fetchAll().first(where: { $0.id == restoredID }) else {
            throw MCPToolError(message: "任务已恢复，但读取新任务失败；请调用 list_tasks")
        }
        return .success([
            "ok": true,
            "restoredFrom": id.uuidString,
            "task": taskPayload(
                restored,
                categories: try normalizedCategories(),
                today: calendar.startOfDay(for: date)
            ),
        ])
    }

    private func purgeTrash(_ arguments: [String: Any]) throws -> MCPToolResult {
        try requireConfirmation(arguments, operation: "永久移除最近删除")
        let all = try booleanArgument(arguments, "all", default: false)
        let ids = all ? nil : try requiredUUIDArray(arguments, "trashIds")
        if !all, ids?.isEmpty != false {
            throw MCPToolError(message: "all=false 时需要提供非空的 trashIds")
        }
        let removed = try repository.removeTrash(ids: ids.map(Set.init))
        return .success([
            "ok": true,
            "removed": removed,
            "note": "只移除了本机恢复副本，不会影响其他设备",
        ])
    }

    private func clearHistory(_ arguments: [String: Any]) throws -> MCPToolResult {
        try requireConfirmation(arguments, operation: "清除历史")
        let all = try booleanArgument(arguments, "all", default: false)
        let ids = all ? nil : try requiredUUIDArray(arguments, "taskIds")
        if !all, ids?.isEmpty != false {
            throw MCPToolError(message: "all=false 时需要提供非空的 taskIds")
        }
        let removed = try repository.clearHistory(ids: ids.map(Set.init))
        if removed > 0 { notifyChange() }
        return .success([
            "ok": true,
            "removed": removed,
            "note": "只清除了本机历史记录",
        ])
    }

    // MARK: - 标签写入

    private func createTag(_ arguments: [String: Any]) throws -> MCPToolResult {
        let name = try requiredString(arguments, "name")
        let categories = try normalizedCategories()
        if let existing = matchCategory(name, in: categories) {
            return .success([
                "ok": true,
                "created": false,
                "tag": tagPayload(existing),
            ])
        }
        _ = try createTagID(named: name, in: categories)
        notifyChange()
        let refreshed = try normalizedCategories()
        guard let tag = matchCategory(name, in: refreshed) else {
            throw MCPToolError(message: "标签已创建，但读取失败")
        }
        return .success([
            "ok": true,
            "created": true,
            "tag": tagPayload(tag),
        ])
    }

    private func renameTag(_ arguments: [String: Any]) throws -> MCPToolResult {
        let oldName = try requiredString(arguments, "oldName")
        let newName = try requiredString(arguments, "newName")
        let categories = try normalizedCategories()
        guard let target = matchCategory(oldName, in: categories) else {
            throw MCPToolError(message: "标签不存在：\(oldName)；请先调用 list_tags")
        }
        guard target.id != TaskCategory.inboxID else {
            throw MCPToolError(message: "未分类是兜底标签，不能改名")
        }
        let normalizedNewName: String
        do {
            normalizedNewName = try TaskCategory.normalizeName(newName)
        } catch {
            throw MCPToolError(message: "标签名称需要 1–12 个字符")
        }
        if target.name == normalizedNewName {
            return .success([
                "ok": true,
                "changed": false,
                "tag": tagPayload(target),
            ])
        }
        if categories.contains(where: {
            $0.id != target.id
                && $0.name.compare(
                    normalizedNewName,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
        }) {
            throw MCPToolError(message: "已经有同名标签：\(normalizedNewName)")
        }
        let updated = try categories.map { category -> TaskCategory in
            guard category.id == target.id else { return category }
            return try TaskCategory(
                id: category.id,
                name: normalizedNewName,
                order: category.order
            )
        }
        try saveCategories(updated)
        return .success([
            "ok": true,
            "changed": true,
            "tag": tagPayload(
                try normalizedCategories().first(where: { $0.id == target.id })
                    ?? target
            ),
        ])
    }

    private func deleteTag(_ arguments: [String: Any]) throws -> MCPToolResult {
        let name = try requiredString(arguments, "name")
        let categories = try normalizedCategories()
        guard let target = matchCategory(name, in: categories) else {
            throw MCPToolError(message: "标签不存在：\(name)；请先调用 list_tags")
        }
        guard target.id != TaskCategory.inboxID else {
            throw MCPToolError(message: "未分类是兜底标签，不能删除")
        }
        let affected = try repository.fetchAll().filter {
            $0.status == .pending && $0.categoryID == target.id
        }.count
        try saveCategories(categories.filter { $0.id != target.id })
        return .success([
            "ok": true,
            "removed": tagPayload(target),
            "reassignedPendingTasks": affected,
            "note": "该标签下的待办已移到未分类",
        ])
    }

    private func reorderTags(_ arguments: [String: Any]) throws -> MCPToolResult {
        let names = try requiredStringArray(arguments, "names")
        let categories = try normalizedCategories()
        guard names.count == categories.count else {
            throw MCPToolError(
                message: "names 必须包含全部 \(categories.count) 个标签（包括“未分类”）"
            )
        }
        var ordered: [TaskCategory] = []
        var seen = Set<String>()
        for name in names {
            guard let category = matchCategory(name, in: categories) else {
                throw MCPToolError(message: "标签不存在：\(name)；请先调用 list_tags")
            }
            guard seen.insert(category.id).inserted else {
                throw MCPToolError(message: "标签重复：\(name)")
            }
            ordered.append(category)
        }
        guard seen.count == categories.count else {
            throw MCPToolError(message: "names 必须包含全部 \(categories.count) 个标签")
        }
        try saveCategories(ordered)
        let refreshed = try normalizedCategories()
        return .success([
            "ok": true,
            "tags": refreshed.map(tagPayload),
        ])
    }

    // MARK: - 参数与数据格式

    private enum ListStatus {
        case pending
        case completed
        case pass
        case history
        case all
    }

    private func listStatus(_ arguments: [String: Any]) throws -> ListStatus {
        let raw = try optionalString(arguments, "status")
        if let raw {
            switch raw {
            case "pending": return .pending
            case "completed": return .completed
            case "pass": return .pass
            case "history": return .history
            case "all": return .all
            default:
                throw MCPToolError(
                    message: "status 只能是 \(Self.statusValues.joined(separator: "/"))"
                )
            }
        }
        if try booleanArgument(arguments, "includeCompleted", default: false) {
            return .all
        }
        return .pending
    }

    private func recurrenceArgument(
        _ arguments: [String: Any],
        default defaultValue: TaskRecurrence
    ) throws -> TaskRecurrence {
        guard let raw = try optionalString(arguments, "recurrence") else {
            return defaultValue
        }
        switch raw {
        case "once": return .once
        case "daily": return .daily
        default:
            throw MCPToolError(message: "recurrence 只能是 once/daily")
        }
    }

    private func scheduleArguments(
        _ arguments: [String: Any]
    ) throws -> (startDate: Date?, endDate: Date?, reminderTime: TaskReminderTime?) {
        let hasStart = arguments.keys.contains("startDate")
        let hasEnd = arguments.keys.contains("endDate")
        guard hasStart == hasEnd else {
            throw MCPToolError(message: "startDate 与 endDate 需要同时提供或同时省略")
        }
        let startDate = hasStart ? try optionalDate(arguments, "startDate") : nil
        let endDate = hasEnd ? try optionalDate(arguments, "endDate") : nil
        guard (startDate == nil) == (endDate == nil) else {
            throw MCPToolError(message: "startDate 与 endDate 需要同时提供或同时省略")
        }
        if let start = startDate, let end = endDate, start > end {
            throw MCPToolError(message: "startDate 不能晚于 endDate")
        }
        var reminder: TaskReminderTime?
        if let rawReminder = try optionalString(arguments, "reminderTime") {
            guard startDate != nil else {
                throw MCPToolError(message: "设置 reminderTime 时需要同时设置起止日期")
            }
            guard let parsed = TaskReminderTime(wireValue: rawReminder) else {
                throw MCPToolError(message: "reminderTime 格式应为 HH:mm")
            }
            reminder = parsed
        }
        return (startDate, endDate, reminder)
    }

    private func taskResult(
        _ task: TodoTask,
        changed: Bool,
        date: Date
    ) throws -> MCPToolResult {
        .success([
            "ok": true,
            "changed": changed,
            "task": taskPayload(
                task,
                categories: try normalizedCategories(),
                today: calendar.startOfDay(for: date)
            ),
        ])
    }

    private func taskPayload(
        _ task: TodoTask,
        categories: [TaskCategory],
        today: Date
    ) -> [String: Any] {
        [
            "id": task.id.uuidString,
            "seriesId": task.seriesID.uuidString,
            "title": task.title,
            "status": task.status.rawValue,
            "statusLabel": task.status.displayName,
            "recurrence": task.recurrence.rawValue,
            "tag": TaskCategory.resolveName(id: task.categoryID, categories: categories),
            "tagId": task.categoryID,
            "startDate": task.startDate.map(dateString) ?? NSNull(),
            "endDate": task.endDate.map(dateString) ?? NSNull(),
            "reminderTime": task.reminderTime?.wireValue ?? NSNull(),
            "dateState": dateState(task, today: today),
            "isOverdue": TaskDateState.isOverdue(task, on: today),
            "isActiveToday": task.status == .pending
                && TaskDateState.isActive(task, on: today),
            "createdAt": timestampValue(task.createdAt),
            "updatedAt": timestampValue(task.updatedAt),
            "completedAt": timestampValue(task.completedAt),
        ]
    }

    private func tagPayload(_ tag: TaskCategory) -> [String: Any] {
        [
            "id": tag.id,
            "name": tag.name,
            "priority": tag.order,
            "isFallback": tag.id == TaskCategory.inboxID,
        ]
    }

    private func dateState(_ task: TodoTask, today: Date) -> String {
        switch task.status {
        case .completed: return "completed"
        case .pass: return "pass"
        case .pending:
            if TaskDateState.isOverdue(task, on: today) { return "overdue" }
            if TaskDateState.isActive(task, on: today) { return "today" }
            if let start = task.startDate, calendar.startOfDay(for: start) > today {
                return "upcoming"
            }
            if task.startDate == nil { return "unscheduled" }
            return "today"
        }
    }

    private func sortedTasks(
        _ tasks: [TodoTask],
        by sort: String,
        categories: [TaskCategory]
    ) -> [TodoTask] {
        let order = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.order) })
        return tasks.sorted { lhs, rhs in
            switch sort {
            case "created":
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case "updated":
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            case "completed":
                let left = lhs.completedAt ?? .distantPast
                let right = rhs.completedAt ?? .distantPast
                if left != right { return left > right }
            case "due":
                let left = lhs.endDate ?? .distantFuture
                let right = rhs.endDate ?? .distantFuture
                if left != right { return left < right }
            default:
                let left = order[lhs.categoryID] ?? Int.max
                let right = order[rhs.categoryID] ?? Int.max
                if left != right { return left < right }
                let leftEnd = lhs.endDate ?? .distantFuture
                let rightEnd = rhs.endDate ?? .distantFuture
                if leftEnd != rightEnd { return leftEnd < rightEnd }
            }
            if TodoTask.displayOrder(lhs, rhs) { return true }
            if TodoTask.displayOrder(rhs, lhs) { return false }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func normalizedCategories() throws -> [TaskCategory] {
        TaskCategory.normalizeList(try repository.fetchCategories())
    }

    private func matchCategory(
        _ name: String,
        in categories: [TaskCategory]
    ) -> TaskCategory? {
        categories.first {
            $0.name.compare(
                name,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
    }

    private func createTagID(
        named name: String,
        in categories: [TaskCategory]
    ) throws -> String {
        let normalized: String
        do {
            normalized = try TaskCategory.normalizeName(name)
        } catch {
            throw MCPToolError(message: "标签名称需要 1–12 个字符")
        }
        guard categories.count < TaskCategory.maximumCount else {
            throw MCPToolError(message: "最多只能有 \(TaskCategory.maximumCount) 个标签，请先删除一个")
        }
        let tag = try TaskCategory(
            id: TaskCategory.newID(existing: Set(categories.map(\.id))),
            name: normalized,
            order: categories.count
        )
        try repository.saveCategories(TaskCategory.normalizeList(categories + [tag]))
        return tag.id
    }

    private func saveCategories(_ categories: [TaskCategory]) throws {
        let normalized = TaskCategory.normalizeList(categories)
        let current = try normalizedCategories()
        let known = Set(normalized.map(\.id))
        let date = now()
        for category in current where !known.contains(category.id) {
            _ = try repository.reassignPendingCategory(
                from: category.id,
                to: TaskCategory.inboxID,
                at: date
            )
        }
        try repository.saveCategories(normalized)
        notifyChange()
    }

    private func nextSortIndex() throws -> Int {
        (try repository.fetchAll().map(\.sortIndex).max() ?? -1) + 1
    }

    private func notifyChange() {
        store.reload()
        store.onTasksChanged?()
    }

    private var calendar: Calendar { TodoTask.protocolCalendar }

    private func dateString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func timestampValue(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return Self.timestampFormatter.string(from: date)
    }

    private func optionalDate(_ arguments: [String: Any], _ key: String) throws -> Date? {
        guard let value = try optionalString(arguments, key) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value else {
            throw MCPToolError(message: "\(key) 格式应为 YYYY-MM-DD")
        }
        return calendar.startOfDay(for: date)
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

    private func requiredUUID(_ arguments: [String: Any], _ key: String) throws -> UUID {
        let value = try requiredString(arguments, key)
        guard let id = UUID(uuidString: value) else {
            throw MCPToolError(message: "\(key) 必须是有效 UUID")
        }
        return id
    }

    private func requiredUUIDArray(
        _ arguments: [String: Any],
        _ key: String
    ) throws -> [UUID] {
        let values = try requiredStringArray(arguments, key)
        return try values.map { value in
            guard let id = UUID(uuidString: value) else {
                throw MCPToolError(message: "\(key) 包含无效 UUID：\(value)")
            }
            return id
        }
    }

    private func requiredStringArray(
        _ arguments: [String: Any],
        _ key: String
    ) throws -> [String] {
        guard let raw = arguments[key] else {
            throw MCPToolError(message: "缺少必填参数 \(key)")
        }
        guard let values = raw as? [String] else {
            throw MCPToolError(message: "\(key) 必须是字符串数组")
        }
        return values.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func integerArgument(
        _ arguments: [String: Any],
        _ key: String,
        default defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw = arguments[key], !(raw is NSNull) else { return defaultValue }
        let value: Int
        if let int = raw as? Int {
            value = int
        } else if let number = raw as? NSNumber {
            value = number.intValue
        } else {
            throw MCPToolError(message: "\(key) 必须是整数")
        }
        guard range.contains(value) else {
            throw MCPToolError(message: "\(key) 需要在 \(range.lowerBound)–\(range.upperBound) 之间")
        }
        return value
    }

    private func booleanArgument(
        _ arguments: [String: Any],
        _ key: String,
        default defaultValue: Bool
    ) throws -> Bool {
        guard let raw = arguments[key], !(raw is NSNull) else { return defaultValue }
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        throw MCPToolError(message: "\(key) 必须是布尔值")
    }

    private func requireConfirmation(
        _ arguments: [String: Any],
        operation: String
    ) throws {
        guard try booleanArgument(arguments, "confirm", default: false) else {
            throw MCPToolError(message: "\(operation)需要 confirm=true")
        }
    }

    private static func toolDefinition(
        name: String,
        description: String,
        readOnly: Bool = false,
        destructive: Bool = false,
        idempotent: Bool = false,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "idempotentHint": idempotent,
                "openWorldHint": false,
            ],
        ]
    }
}
