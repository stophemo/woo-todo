import AppKit
import WooTodoCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private enum OpacityPreset: Int, CaseIterable {
        case twenty = 20
        case forty = 40
        case sixty = 60
        case eighty = 80
        case oneHundred = 100

        var title: String {
            switch self {
            case .twenty: "20%（最透明）"
            case .forty: "40%"
            case .sixty: "60%"
            case .eighty: "80%"
            case .oneHundred: "100%（最清晰）"
            }
        }

        var opacity: CGFloat { CGFloat(rawValue) / 100 }
    }

    private let panelController: FloatingPanelController
    private let shortcutSettingsStore: ShortcutSettingsStore
    private let quickAddAction: () -> Void
    private let openDashboardAction: () -> Void
    private let openSettingsAction: () -> Void
    private let checkForUpdatesAction: () -> Void
    private let openAvailableUpdateAction: () -> Void
    private let statusItem: NSStatusItem
    private let quickAddItem: NSMenuItem
    private let taskPanelItem: NSMenuItem
    private let makeInteractiveItem: NSMenuItem
    private let clickThroughItem: NSMenuItem
    private let blurItem: NSMenuItem
    private let alwaysOnTopItem: NSMenuItem
    private let opacityItem: NSMenuItem
    private let availableUpdateItem: NSMenuItem
    private var opacityPresetItems: [NSMenuItem] = []

    init(
        panelController: FloatingPanelController,
        shortcutSettingsStore: ShortcutSettingsStore,
        quickAdd: @escaping () -> Void,
        openDashboard: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void,
        openAvailableUpdate: @escaping () -> Void
    ) {
        self.panelController = panelController
        self.shortcutSettingsStore = shortcutSettingsStore
        quickAddAction = quickAdd
        openDashboardAction = openDashboard
        openSettingsAction = openSettings
        checkForUpdatesAction = checkForUpdates
        openAvailableUpdateAction = openAvailableUpdate
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        quickAddItem = NSMenuItem(title: "快速新增任务", action: nil, keyEquivalent: "")
        taskPanelItem = NSMenuItem(title: "显示任务板", action: nil, keyEquivalent: "")
        makeInteractiveItem = NSMenuItem(title: "恢复可交互", action: nil, keyEquivalent: "")
        clickThroughItem = NSMenuItem(title: "鼠标穿透", action: nil, keyEquivalent: "")
        blurItem = NSMenuItem(title: "毛玻璃", action: nil, keyEquivalent: "")
        alwaysOnTopItem = NSMenuItem(title: "始终置顶", action: nil, keyEquivalent: "")
        opacityItem = NSMenuItem(title: "日常不透明度", action: nil, keyEquivalent: "")
        availableUpdateItem = NSMenuItem(title: "有新版本可用", action: nil, keyEquivalent: "")
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
        let percentage = Int((panelController.panelOpacity * 100).rounded())
        opacityItem.title = panelController.isClickThrough
            ? "日常不透明度（恢复后 \(percentage)%）"
            : "日常不透明度（\(percentage)%）"
        quickAddItem.title = "快速新增任务"
        taskPanelItem.title = panelController.isVisible
            ? "隐藏任务板"
            : "显示任务板"
        makeInteractiveItem.isHidden = !panelController.isClickThrough
        clickThroughItem.title = panelController.isClickThrough
            ? "鼠标穿透：已开启"
            : "鼠标穿透"
        alwaysOnTopItem.title = "始终置顶"
        applyShortcut(.quickAdd, to: quickAddItem)
        applyShortcut(.toggleTaskPanel, to: taskPanelItem)
        applyShortcut(.toggleClickThrough, to: clickThroughItem)
        applyShortcut(.toggleAlwaysOnTop, to: alwaysOnTopItem)
        opacityPresetItems.forEach { item in
            guard let rawValue = item.representedObject as? Int else { return }
            item.state = rawValue == percentage ? .on : .off
        }
    }

    func setAvailableUpdate(_ update: AvailableAppUpdate?) {
        if let update {
            availableUpdateItem.title = "有新版本可用：v\(update.version)"
            availableUpdateItem.toolTip = "点击打开下载页"
            availableUpdateItem.isHidden = false
        } else {
            availableUpdateItem.title = "有新版本可用"
            availableUpdateItem.toolTip = nil
            availableUpdateItem.isHidden = true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshState()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "Woo Todo")
        menu.delegate = self
        quickAddItem.target = self
        quickAddItem.action = #selector(quickAdd)
        menu.addItem(quickAddItem)
        taskPanelItem.target = self
        taskPanelItem.action = #selector(toggleTaskPanel)
        menu.addItem(taskPanelItem)
        menu.addItem(item("任务详情与统计…", action: #selector(openDashboard)))
        menu.addItem(item("设置…", action: #selector(openSettings)))
        makeInteractiveItem.target = self
        makeInteractiveItem.action = #selector(makeInteractive)
        menu.addItem(makeInteractiveItem)
        menu.addItem(.separator())

        clickThroughItem.target = self
        clickThroughItem.action = #selector(toggleClickThrough)
        menu.addItem(clickThroughItem)

        blurItem.target = self
        blurItem.action = #selector(toggleBlur)
        menu.addItem(blurItem)

        let opacityMenu = NSMenu(title: "日常不透明度")
        OpacityPreset.allCases.forEach { preset in
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(setOpacity(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.rawValue
            opacityPresetItems.append(item)
            opacityMenu.addItem(item)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        alwaysOnTopItem.target = self
        alwaysOnTopItem.action = #selector(toggleAlwaysOnTop)
        menu.addItem(alwaysOnTopItem)
        menu.addItem(.separator())
        availableUpdateItem.target = self
        availableUpdateItem.action = #selector(openAvailableUpdate)
        availableUpdateItem.isHidden = true
        menu.addItem(availableUpdateItem)
        menu.addItem(item("检查更新…", action: #selector(checkForUpdates)))
        menu.addItem(item("退出 Woo Todo", action: #selector(quit)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func applyShortcut(_ command: GlobalShortcutCommand, to item: NSMenuItem) {
        let binding = shortcutSettingsStore.binding(for: command)
        item.keyEquivalent = Self.menuKeyEquivalent(for: binding.keyLabel)
        item.keyEquivalentModifierMask = Self.menuModifierMask(for: binding.modifiers)
    }

    private static func menuModifierMask(
        for modifiers: GlobalShortcutModifiers
    ) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.command) { mask.insert(.command) }
        return mask
    }

    private static func menuKeyEquivalent(for keyLabel: String) -> String {
        switch keyLabel {
        case "Space": return " "
        case "Return": return "\r"
        case "Tab": return "\t"
        case "Delete": return "\u{8}"
        case "Forward Delete": return "\u{F728}"
        case "Home": return "\u{F729}"
        case "End": return "\u{F72B}"
        case "Page Up": return "\u{F72C}"
        case "Page Down": return "\u{F72D}"
        case "↑": return "\u{F700}"
        case "↓": return "\u{F701}"
        case "←": return "\u{F702}"
        case "→": return "\u{F703}"
        default:
            if keyLabel.hasPrefix("F"),
               let number = Int(keyLabel.dropFirst()),
               Self.functionKeyEquivalents.indices.contains(number - 1) {
                return Self.functionKeyEquivalents[number - 1]
            }
            return keyLabel.lowercased()
        }
    }

    private static let functionKeyEquivalents = [
        "\u{F704}", "\u{F705}", "\u{F706}", "\u{F707}", "\u{F708}",
        "\u{F709}", "\u{F70A}", "\u{F70B}", "\u{F70C}", "\u{F70D}",
        "\u{F70E}", "\u{F70F}", "\u{F710}", "\u{F711}", "\u{F712}",
        "\u{F713}", "\u{F714}", "\u{F715}", "\u{F716}", "\u{F717}"
    ]

    @objc private func toggleTaskPanel() {
        panelController.toggleVisibility()
    }

    @objc private func quickAdd() {
        quickAddAction()
    }

    @objc private func openDashboard() {
        openDashboardAction()
    }

    @objc private func openSettings() {
        openSettingsAction()
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

    @objc private func checkForUpdates() {
        checkForUpdatesAction()
    }

    @objc private func openAvailableUpdate() {
        openAvailableUpdateAction()
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let preset = OpacityPreset(rawValue: rawValue) else { return }
        panelController.setPanelOpacity(preset.opacity)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
