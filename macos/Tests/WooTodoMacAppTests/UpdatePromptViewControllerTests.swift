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

        #expect(contentSize.width == 356)
        #expect((130...190).contains(contentSize.height))

        controller.view.frame = NSRect(origin: .zero, size: contentSize)
        controller.view.layoutSubtreeIfNeeded()

        let buttons = descendants(of: NSButton.self, in: controller.view)
        #expect(buttons.map(\.title).sorted() == ["立即更新", "稍后"].sorted())
        #expect(buttons.first(where: { $0.title == "立即更新" })?.keyEquivalent == "\r")
        for button in buttons {
            let frame = controller.view.convert(button.bounds, from: button)
            #expect(controller.view.bounds.contains(frame))
            #expect(!button.isHidden)
            #expect(button.isEnabled)
        }

        let labels = descendants(of: NSTextField.self, in: controller.view)
        #expect(labels.contains { $0.stringValue == "新版本可用" })
        #expect(labels.contains { $0.stringValue == "Woo Todo v0.1.26" })
        #expect(labels.contains { $0.stringValue == "本地任务和设置会保留" })
        let titleLabel = try #require(labels.first { $0.identifier?.rawValue == "update.title" })
        #expect(titleLabel.frame.width >= titleLabel.intrinsicContentSize.width)

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
        let snapshotSurface = NSView(frame: view.bounds)
        snapshotSurface.wantsLayer = true
        snapshotSurface.layer?.backgroundColor = NSColor(
            calibratedWhite: 0.14,
            alpha: 1
        ).cgColor
        view.frame = snapshotSurface.bounds
        snapshotSurface.addSubview(view)
        snapshotSurface.displayIfNeeded()
        guard let bitmap = snapshotSurface.bitmapImageRepForCachingDisplay(
            in: snapshotSurface.bounds
        ) else {
            Issue.record("无法为更新提示创建离屏位图")
            return
        }
        snapshotSurface.cacheDisplay(in: snapshotSurface.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("无法编码更新提示快照")
            return
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
