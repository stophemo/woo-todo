import AppKit

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let panelController: FloatingPanelController
    private let openDashboardAction: () -> Void
    private let statusItem: NSStatusItem
    private let clickThroughItem: NSMenuItem
    private let blurItem: NSMenuItem
    private let alwaysOnTopItem: NSMenuItem

    init(
        panelController: FloatingPanelController,
        openDashboard: @escaping () -> Void
    ) {
        self.panelController = panelController
        openDashboardAction = openDashboard
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        clickThroughItem = NSMenuItem(title: "鼠标穿透", action: nil, keyEquivalent: "")
        blurItem = NSMenuItem(title: "毛玻璃", action: nil, keyEquivalent: "")
        alwaysOnTopItem = NSMenuItem(title: "始终置顶", action: nil, keyEquivalent: "")
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "checklist",
            accessibilityDescription: "Woo Todo"
        )
        statusItem.button?.toolTip = "Woo Todo"
        statusItem.menu = buildMenu()
        refreshState()
    }

    func refreshState() {
        clickThroughItem.state = panelController.isClickThrough ? .on : .off
        blurItem.state = panelController.isBlurEnabled ? .on : .off
        alwaysOnTopItem.state = panelController.isAlwaysOnTop ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshState()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Woo Todo")
        menu.delegate = self
        menu.addItem(item("显示任务板", action: #selector(showPanel)))
        menu.addItem(item("任务详情与统计", action: #selector(openDashboard)))
        menu.addItem(item("恢复可交互（⌃⌥Space）", action: #selector(makeInteractive)))
        menu.addItem(.separator())

        clickThroughItem.target = self
        clickThroughItem.action = #selector(toggleClickThrough)
        menu.addItem(clickThroughItem)

        blurItem.target = self
        blurItem.action = #selector(toggleBlur)
        menu.addItem(blurItem)

        alwaysOnTopItem.target = self
        alwaysOnTopItem.action = #selector(toggleAlwaysOnTop)
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())
        menu.addItem(item("退出 Woo Todo", action: #selector(quit)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showPanel() {
        panelController.show()
    }

    @objc private func openDashboard() {
        openDashboardAction()
    }

    @objc private func makeInteractive() {
        panelController.makeInteractive()
    }

    @objc private func toggleClickThrough() {
        panelController.toggleClickThrough()
    }

    @objc private func toggleBlur() {
        panelController.toggleBlur()
    }

    @objc private func toggleAlwaysOnTop() {
        panelController.toggleAlwaysOnTop()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
