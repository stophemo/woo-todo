import AppKit
import SwiftUI
import Testing
import WooTodoCore
@testable import WooTodoMacApp

@Suite("快速新增面板")
@MainActor
struct QuickAddPanelControllerTests {
    @Test("面板失去焦点时自动关闭")
    func dismissesWhenResigningKey() throws {
        let store = TodayStore(repository: QuickAddTestRepository())
        let controller = QuickAddPanelController(store: store)
        let panel = try #require(controller.window)

        panel.orderFront(nil)
        #expect(panel.isVisible)

        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: panel)
        )

        #expect(!panel.isVisible)
    }

    @Test("快速新增默认不设置时间")
    func defaultsToNoSchedule() throws {
        let repository = QuickAddTestRepository()
        let model = QuickAddModel(store: TodayStore(repository: repository))
        model.prepareForPresentation()

        model.title = "写周报"
        model.submit()

        let task = try #require(repository.saved.first)
        #expect(task.categoryID == TaskCategory.inboxID)
        #expect(task.startDate == nil)
        #expect(task.endDate == nil)
        #expect(task.reminderTime == nil)
    }

    @Test("快速新增可设置起止日期和提醒")
    func savesScheduleAndReminder() throws {
        let repository = QuickAddTestRepository()
        let model = QuickAddModel(store: TodayStore(repository: repository))
        model.prepareForPresentation()
        let start = date(2026, 11, 16)
        let end = date(2026, 11, 18)

        model.title = "准备发布"
        model.dateRangeEnabled = true
        model.startDate = start
        model.endDate = end
        model.reminderEnabled = true
        model.reminderDate = Calendar.current.date(
            bySettingHour: 9,
            minute: 30,
            second: 0,
            of: start
        ) ?? start
        model.submit()

        let task = try #require(repository.saved.first)
        let expectedReminder = try TaskReminderTime(hour: 9, minute: 30)
        #expect(task.startDate == TodoTask.protocolCalendar.startOfDay(for: start))
        #expect(task.endDate == TodoTask.protocolCalendar.startOfDay(for: end))
        #expect(task.reminderTime == expectedReminder)
    }

    @Test("展开时间与提醒会调整面板高度")
    func schedulingSectionResizesPanel() async throws {
        let controller = QuickAddPanelController(
            store: TodayStore(repository: QuickAddTestRepository())
        )
        let panel = try #require(controller.window)
        controller.model.prepareForPresentation()
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        let collapsedHeight = panel.frame.height

        controller.model.isSchedulingExpanded = true
        controller.model.dateRangeEnabled = true
        try await Task.sleep(for: .milliseconds(200))
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let expandedHeight = panel.frame.height

        #expect(collapsedHeight > 100)
        #expect(expandedHeight > collapsedHeight)
    }

    @Test("展开时间与提醒会增加内容高度")
    func schedulingSectionGrowsContent() throws {
        let repository = QuickAddTestRepository()
        let model = QuickAddModel(store: TodayStore(repository: repository))
        model.prepareForPresentation()
        let view = NSHostingView(rootView: QuickAddView(model: model))
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 400)
        view.layoutSubtreeIfNeeded()
        let collapsedHeight = view.fittingSize.height

        model.isSchedulingExpanded = true
        model.dateRangeEnabled = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
        let expandedHeight = view.fittingSize.height

        #expect(expandedHeight > collapsedHeight)
    }

    @Test("开始日期晚于结束日期时拒绝提交")
    func rejectsReversedSchedule() throws {
        let repository = QuickAddTestRepository()
        let model = QuickAddModel(store: TodayStore(repository: repository))
        model.prepareForPresentation()
        let start = date(2026, 11, 18)

        model.title = "准备发布"
        model.dateRangeEnabled = true
        model.startDate = start
        model.endDate = start.addingTimeInterval(-86_400)
        model.submit()

        #expect(repository.saved.isEmpty)
        #expect(model.errorMessage == "开始日期不能晚于结束日期")
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        TodoTask.protocolCalendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: 12
        ))!
    }
}

private final class QuickAddTestRepository: TaskRepository {
    private(set) var saved: [TodoTask] = []

    func fetchAll() throws -> [TodoTask] { [] }

    func save(_ tasks: [TodoTask]) throws {
        saved.append(contentsOf: tasks)
    }

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool { false }

    func delete(id: UUID) throws {}

    func clearHistory(ids: Set<UUID>?) throws -> Int { 0 }
}
