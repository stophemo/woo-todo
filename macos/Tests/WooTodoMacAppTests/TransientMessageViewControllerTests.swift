import AppKit
import Testing
@testable import WooTodoMacApp

struct TransientMessageViewControllerTests {
    @MainActor @Test func shortMessageUsesCompactContentSize() {
        let controller = TransientMessageViewController(
            title: "已是最新版本",
            message: "当前版本为 v0.1.26。"
        )

        #expect((136...150).contains(controller.contentSize.width))
        #expect((46...58).contains(controller.contentSize.height))
    }

    @MainActor @Test func longMessageExpandsWithinMaximumWidth() {
        let shortController = TransientMessageViewController(
            title: "已是最新版本",
            message: "当前版本为 v0.1.26。"
        )
        let longController = TransientMessageViewController(
            title: "正在检查更新",
            message: "检查在后台进行，完成后会在菜单中显示结果。"
        )

        #expect(longController.contentSize.width > shortController.contentSize.width)
        #expect(longController.contentSize.width <= 260)
        #expect(longController.contentSize.height > shortController.contentSize.height)
    }
}
