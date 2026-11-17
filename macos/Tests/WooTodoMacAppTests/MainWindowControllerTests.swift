import AppKit
import Foundation
import Testing
import WooTodoCore
import WooTodoStorage
@testable import WooTodoMacApp

@Suite("主窗口生命周期")
@MainActor
struct MainWindowControllerTests {
    @Test("隐藏时不刷新，show 只刷新一次并保留分区")
    func hiddenWindowDoesNotReload() throws {
        let repository = CountingTaskRepository()
        let store = DashboardStore(repository: repository)
        let suite = "woo-todo-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dayCounterStore = DayCounterStore(
            defaults: defaults,
            repository: try SQLiteTaskRepository(path: ":memory:")
        )
        let controller = MainWindowController(
            store: store,
            dayCounterStore: dayCounterStore,
            openSettings: {}
        )

        controller.reloadIfVisible()
        #expect(repository.fetchCount == 0)
        #expect(!controller.isVisible)
        #expect(!controller.isVisibleOrMiniaturized)

        controller.show(section: .statistics)
        #expect(controller.currentSection == .statistics)
        #expect(repository.fetchCount == 1)
        // show 已经刷新过，紧接着的 becomeKey 不应重复 fetch。
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: controller.window
        ))
        #expect(repository.fetchCount == 1)

        controller.hide()
        controller.reloadIfVisible()
        #expect(repository.fetchCount == 1)
        controller.show(section: controller.currentSection)
        #expect(repository.fetchCount == 2)
        #expect(controller.currentSection == .statistics)

        let window = try #require(controller.window)
        #expect(controller.windowShouldClose(window) == false)
        #expect(!controller.isVisible)
    }
}

private final class CountingTaskRepository: TaskRepository {
    private(set) var fetchCount = 0
    private var tasks: [TodoTask] = []

    func fetchAll() throws -> [TodoTask] {
        fetchCount += 1
        return tasks
    }

    func save(_ tasks: [TodoTask]) throws {
        self.tasks = tasks
    }

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool { false }

    func delete(id: UUID) throws {
        tasks.removeAll { $0.id == id }
    }

    func clearHistory(ids: Set<UUID>?) throws -> Int { 0 }
}
