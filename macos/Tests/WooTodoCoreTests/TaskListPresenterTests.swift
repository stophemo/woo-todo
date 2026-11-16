import Foundation
import Testing
@testable import WooTodoCore

@Suite("任务列表排序")
struct TaskListPresenterTests {
    @Test("组内先按标签优先级再按结束日期")
    func categoryPriorityComesFirst() throws {
        let today = date("2026-07-15")
        let categories = TaskCategory.normalizeList([
            try TaskCategory(id: "life", name: "生活", order: 0),
            try TaskCategory(id: "work", name: "工作", order: 1),
            try TaskCategory(id: TaskCategory.inboxID, name: "未分类", order: 2),
        ])
        let highPriority = try TodoTask(
            title: "高优先级稍晚",
            categoryID: "life",
            startDate: today,
            endDate: date("2026-07-17")
        )
        let lowPriority = try TodoTask(
            title: "低优先级更早",
            categoryID: "work",
            startDate: today,
            endDate: today
        )

        let sections = TaskListPresenter.sections(
            tasks: [lowPriority, highPriority],
            categories: categories,
            on: today
        )

        let todaySection = try #require(sections.first { $0.kind == .today })
        #expect(todaySection.tasks.map(\.title) == ["高优先级稍晚", "低优先级更早"])
    }

    private func date(_ value: String) -> Date {
        TodoTask.protocolCalendar.date(from: DateComponents(
            year: Int(value.prefix(4)),
            month: Int(value.dropFirst(5).prefix(2)),
            day: Int(value.suffix(2))
        ))!
    }
}
