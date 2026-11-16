import Foundation
import Testing
@testable import WooTodoCore

@Suite("任务领域模型")
struct TaskModelTests {
    @Test("任务内容会去除首尾空白")
    func titleIsTrimmed() throws {
        let task = try TodoTask(title: "  写周报  \n", categoryID: "side")
        #expect(task.title == "写周报")
    }

    @Test("空任务不能创建")
    func emptyTitleIsRejected() {
        #expect(throws: TaskValidationError.emptyTitle) {
            try TodoTask(title: "  \n", categoryID: "extra")
        }
    }

    @Test("标题上限按 Unicode scalar 而不是字形簇计算")
    func titleLimitUsesUnicodeScalars() throws {
        let valid = String(repeating: "😀", count: 120)
        #expect(try TodoTask(title: valid, categoryID: "main").title == valid)
        #expect(throws: TaskValidationError.titleTooLong) {
            try TodoTask(
                title: String(repeating: "👨‍👩‍👧‍👦", count: 18),
                categoryID: "main"
            )
        }
    }

    @Test("日期范围必须同时为空或同时有值且开始不晚于结束")
    func dateRangeValidation() throws {
        #expect(throws: TaskValidationError.invalidDates) {
            try TodoTask(title: "半开区间", categoryID: "main", startDate: Date())
        }
        let start = date("2026-07-20")
        #expect(throws: TaskValidationError.invalidDates) {
            try TodoTask(
                title: "倒置范围",
                categoryID: "main",
                startDate: start,
                endDate: date("2026-07-19")
            )
        }
        let task = try TodoTask(
            title: "合法范围",
            categoryID: "main",
            startDate: date("2026-07-20T18:00:00+08:00"),
            endDate: date("2026-07-25T03:00:00+08:00")
        )
        #expect(task.startDate == date("2026-07-20"))
        #expect(task.endDate == date("2026-07-25"))
    }

    @Test("提醒只允许有日期的任务")
    func reminderRequiresDates() throws {
        let reminder = try TaskReminderTime(hour: 9, minute: 0)
        #expect(throws: TaskValidationError.invalidReminderTime) {
            try TodoTask(title: "无日期提醒", categoryID: "main", reminderTime: reminder)
        }
        let task = try TodoTask(
            title: "有日期提醒",
            categoryID: "main",
            startDate: date("2026-07-20"),
            endDate: date("2026-07-20"),
            reminderTime: reminder
        )
        #expect(task.reminderTime == reminder)
    }

    @Test("分类定义校验并补齐未分类")
    func categoryValidationAndNormalization() throws {
        #expect(TaskCategory.defaults.map(\.id) == ["inbox"])
        #expect(throws: TaskValidationError.invalidCategory) {
            try TaskCategory(id: "Work", name: "工作", order: 0)
        }
        #expect(throws: TaskValidationError.invalidCategory) {
            try TaskCategory(id: "work", name: " ", order: 0)
        }
        let normalized = TaskCategory.normalizeList([
            try TaskCategory(id: "work", name: "工作", order: 8),
            try TaskCategory(id: "life", name: "生活", order: 9),
        ])
        #expect(normalized.map(\.id) == ["inbox", "work", "life"])
        #expect(normalized.map(\.order) == [0, 1, 2])
        #expect(TaskCategory.newID(existing: ["cabcdefg"]) != "cabcdefg")
    }

    @Test("标签输入留空表示不设置标签")
    func categoryInputEmptyMeansNone() throws {
        #expect(
            try TaskCategory.resolveInput(
                "  \n",
                categories: TaskCategory.defaults
            ) == .none
        )
    }

    @Test("标签输入优先匹配已有标签并忽略大小写")
    func categoryInputMatchesExisting() throws {
        let work = try TaskCategory(id: "work", name: "Work", order: 1)
        let categories = TaskCategory.normalizeList([work])

        #expect(
            try TaskCategory.resolveInput("  work ", categories: categories)
                == .existing(try #require(categories.first { $0.id == "work" }))
        )
        #expect(
            try TaskCategory.resolveInput("未分类", categories: categories)
                == .existing(try #require(categories.first { $0.id == "inbox" }))
        )
    }

    @Test("标签输入不匹配时生成新标签")
    func categoryInputCreatesNewCategory() throws {
        let result = try TaskCategory.resolveInput(
            "  学习 ",
            categories: TaskCategory.defaults
        )

        guard case let .create(category) = result else {
            Issue.record("应生成新标签")
            return
        }
        #expect(category.name == "学习")
        #expect(category.order == 1)
        #expect(TaskCategory.isValidID(category.id))
    }

    @Test("标签输入校验名称与数量上限")
    func categoryInputValidation() throws {
        #expect(throws: TaskValidationError.invalidCategory) {
            try TaskCategory.resolveInput(
                String(repeating: "字", count: 13),
                categories: TaskCategory.defaults
            )
        }

        let full = TaskCategory.normalizeList(
            (1...7).map { index in
                try! TaskCategory(id: "c\(index)", name: "标签\(index)", order: index)
            }
        )
        #expect(full.count == 8)
        #expect(throws: TaskValidationError.categoryLimitReached) {
            try TaskCategory.resolveInput("新标签", categories: full)
        }
    }

    @Test("待办任务排在已结算任务前")
    func displayOrderPutsPendingFirst() throws {
        let pending = try TodoTask(title: "待办", categoryID: "main")
        let completed = try TodoTask(
            title: "完成",
            categoryID: "main",
            status: .completed,
            completedAt: Date()
        )
        #expect([completed, pending].sorted(by: TodoTask.displayOrder).map(\.title) == [
            "待办", "完成"
        ])
    }

    private func date(_ value: String) -> Date {
        if value.count == 10 {
            var calendar = TodoTask.protocolCalendar
            calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
            return calendar.date(from: DateComponents(
                year: Int(value.prefix(4)),
                month: Int(value.dropFirst(5).prefix(2)),
                day: Int(value.suffix(2))
            ))!
        }
        return ISO8601DateFormatter().date(from: value)!
    }
}
