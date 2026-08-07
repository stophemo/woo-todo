import AppKit
import Testing
@testable import WooTodoMacApp

struct UpdatePromptViewControllerTests {
    @MainActor @Test func updatePromptFitsContentAndKeepsActionsVisible() throws {
        let controller = UpdatePromptViewController(
            version: "0.1.26",
            onInstall: {},
            onLater: {}
        )
        let contentSize = controller.contentSize

        #expect(contentSize.width == 292)
        #expect((88...120).contains(contentSize.height))

        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        controller.view.layoutSubtreeIfNeeded()

        let buttons = descendants(of: NSButton.self, in: controller.view)
        #expect(buttons.map(\.title).sorted() == ["立即更新", "稍后"].sorted())
        for button in buttons {
            let frame = controller.view.convert(button.bounds, from: button)
            #expect(controller.view.bounds.contains(frame))
            #expect(!button.isHidden)
            #expect(button.isEnabled)
        }

        try writeSnapshotIfRequested(controller.view)
    }

    @MainActor
    private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { child in
            let current = child as? View
            return (current.map { [$0] } ?? []) + descendants(of: type, in: child)
        }
    }

    @MainActor
    private func writeSnapshotIfRequested(_ view: NSView) throws {
        guard let path = ProcessInfo.processInfo.environment["WOO_TODO_UPDATE_PROMPT_SNAPSHOT"],
              !path.isEmpty else { return }
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("无法为更新提示创建离屏位图")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("无法编码更新提示快照")
            return
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
