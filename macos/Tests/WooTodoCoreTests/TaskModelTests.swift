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
