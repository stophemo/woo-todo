import AppKit
import Foundation
import Testing
import WooTodoCore
import WooTodoStorage
@testable import WooTodoMacApp

@Suite("任务板展示模式")
@MainActor
struct FloatingPanelPresentationTests {
    @Test("关闭始终置顶后自动回到桌面小组件")
    func disablingAlwaysOnTopRestoresDesktopWidget() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "panel.desktopWidget")
        defaults.set(false, forKey: "panel.alwaysOnTop")

        let controller = try makeController(defaults: defaults)
        let window = controller.window

        #expect(controller.isDesktopWidget)
        #expect(!controller.isAlwaysOnTop)
        #expect(window?.level == PanelDesktopLevelPolicy.level(pointerInside: false))
        #expect(window?.collectionBehavior.contains(.stationary) == true)

        controller.toggleAlwaysOnTop()

        #expect(controller.isDesktopWidget)
        #expect(controller.isAlwaysOnTop)
        #expect(window?.level == .floating)
        #expect(window?.collectionBehavior.contains(.stationary) == true)

        controller.toggleAlwaysOnTop()

        #expect(controller.isDesktopWidget)
        #expect(!controller.isAlwaysOnTop)
        #expect(window?.level == PanelDesktopLevelPolicy.level(pointerInside: false))
        #expect(window?.collectionBehavior.contains(.stationary) == true)
    }

    @Test("鼠标穿透不会退出桌面小组件模式")
    func clickThroughKeepsDesktopWidgetMode() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "panel.desktopWidget")
        defaults.set(false, forKey: "panel.clickThrough")

        let controller = try makeController(defaults: defaults)
        let window = controller.window

        controller.toggleClickThrough()

        #expect(controller.isDesktopWidget)
        #expect(controller.isClickThrough)
        #expect(window?.ignoresMouseEvents == true)
        #expect(window?.level == PanelDesktopLevelPolicy.level(pointerInside: false))
        #expect(window?.collectionBehavior.contains(.stationary) == true)

        controller.toggleClickThrough()

        #expect(controller.isDesktopWidget)
        #expect(!controller.isClickThrough)
        #expect(window?.ignoresMouseEvents == false)
    }

    @Test("启动时置顶只覆盖展示层，不丢失小组件偏好")
    func pinnedLaunchKeepsDesktopWidgetPreference() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "panel.desktopWidget")
        defaults.set(true, forKey: "panel.alwaysOnTop")

        let controller = try makeController(defaults: defaults)
        let window = controller.window

        #expect(controller.isDesktopWidget)
        #expect(controller.isAlwaysOnTop)
        #expect(window?.level == .floating)
        #expect(window?.collectionBehavior.contains(.stationary) == true)
    }

    @Test("普通窗口模式仍然随显示桌面一起收起")
    func normalModeKeepsDefaultShowDesktopBehavior() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "panel.desktopWidget")
        defaults.set(false, forKey: "panel.alwaysOnTop")

        let controller = try makeController(defaults: defaults)
        let window = controller.window

        #expect(!controller.isDesktopWidget)
        #expect(!controller.isAlwaysOnTop)
        #expect(window?.level == .normal)
        #expect(window?.collectionBehavior.contains(.stationary) == false)
    }

    @Test("重新开启桌面小组件会清除置顶但保留穿透")
    func reenablingDesktopWidgetKeepsClickThrough() throws {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "panel.desktopWidget")
        defaults.set(true, forKey: "panel.alwaysOnTop")
        defaults.set(true, forKey: "panel.clickThrough")

        let controller = try makeController(defaults: defaults)
        controller.toggleDesktopWidget()
        controller.toggleDesktopWidget()

        #expect(controller.isDesktopWidget)
        #expect(!controller.isAlwaysOnTop)
        #expect(controller.isClickThrough)
        #expect(controller.window?.level == PanelDesktopLevelPolicy.level(pointerInside: false))
        #expect(controller.window?.ignoresMouseEvents == true)
    }

    @Test("旧版置顶回归留下的普通窗口状态会一次性恢复小组件")
    func legacyNormalStateMigratesToDesktopWidget() throws {
        let (defaults, suite) = makeDefaults(marksCurrentStateModel: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "panel.desktopWidget")
        defaults.set(false, forKey: "panel.alwaysOnTop")
        defaults.set(true, forKey: "panel.clickThrough")

        let controller = try makeController(defaults: defaults)

        #expect(controller.isDesktopWidget)
        #expect(!controller.isAlwaysOnTop)
        #expect(!controller.isClickThrough)
        #expect(defaults.bool(forKey: "panel.desktopWidget"))
        #expect(defaults.integer(forKey: "panel.stateModelVersion") == 2)
        #expect(controller.window?.collectionBehavior.contains(.stationary) == true)
    }

    @Test("迁移只执行一次，之后用户可主动选择普通窗口")
    func migrationRunsOnceAndKeepsLaterNormalChoice() throws {
        let (defaults, suite) = makeDefaults(marksCurrentStateModel: false)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "panel.desktopWidget")

        let first = try makeController(defaults: defaults)
        #expect(first.isDesktopWidget)

        first.toggleDesktopWidget()
        #expect(!first.isDesktopWidget)

        let second = try makeController(defaults: defaults)
        #expect(!second.isDesktopWidget)
        #expect(second.window?.level == .normal)
    }

    private func makeDefaults(
        marksCurrentStateModel: Bool = true
    ) -> (defaults: UserDefaults, suite: String) {
        let suite = "woo-todo-panel-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if marksCurrentStateModel {
            // 当前状态模型版本为 2；测试默认跳过一次性迁移。
            defaults.set(2, forKey: "panel.stateModelVersion")
        }
        return (defaults, suite)
    }

    private func makeController(defaults: UserDefaults) throws -> FloatingPanelController {
        let store = TodayStore(repository: EmptyTaskRepository())
        let dayCounterStore = DayCounterStore(
            defaults: defaults,
            repository: try SQLiteTaskRepository(path: ":memory:")
        )
        return FloatingPanelController(
            store: store,
            dayCounterStore: dayCounterStore,
            defaults: defaults
        )
    }
}

private final class EmptyTaskRepository: TaskRepository {
    func fetchAll() throws -> [TodoTask] { [] }

    func save(_ tasks: [TodoTask]) throws {}

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool { false }

    func delete(id: UUID) throws {}

    func clearHistory(ids: Set<UUID>?) throws -> Int { 0 }
}
