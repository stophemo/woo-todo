import AppKit
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
}

private final class QuickAddTestRepository: TaskRepository {
    func fetchAll() throws -> [TodoTask] { [] }

    func save(_ tasks: [TodoTask]) throws {}

    func reopenCompleted(id: UUID, at date: Date) throws -> Bool { false }

    func delete(id: UUID) throws {}

    func clearHistory(ids: Set<UUID>?) throws -> Int { 0 }
}
