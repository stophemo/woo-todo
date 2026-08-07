import AppKit
import WooTodoCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private enum OpacityPreset: Int, CaseIterable {
        case twenty = 20
        case thirty = 30
        case forty = 40
        case fifty = 50
        case sixty = 60
        case seventy = 70
        case eighty = 80
        case ninety = 90
        case oneHundred = 100

        var title: String {
            switch self {
            case .twenty: "20%（最透明）"
            case .thirty: "30%"
            case .forty: "40%"
            case .fifty: "50%"
            case .sixty: "60%"
            case .seventy: "70%"
            case .eighty: "80%"
            case .ninety: "90%"
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
    private let statusItem: NSStatusItem
    private let quickAddItem: NSMenuItem
    private let taskPanelItem: NSMenuItem
    private let desktopWidgetItem: NSMenuItem
    private let clickThroughItem: NSMenuItem
    private let blurItem: NSMenuItem
    private let alwaysOnTopItem: NSMenuItem
    private let opacityItem: NSMenuItem
    private let updateItem: NSMenuItem
    private var opacityPresetItems: [NSMenuItem] = []
    private var updateState = AppUpdateState.idle
    private var messagePopover: NSPopover?
    private var messageDismissTask: Task<Void, Never>?

    init(
        panelController: FloatingPanelController,
        shortcutSettingsStore: ShortcutSettingsStore,
        quickAdd: @escaping () -> Void,
        openDashboard: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void
    ) {
        self.panelController = panelController
        self.shortcutSettingsStore = shortcutSettingsStore
        quickAddAction = quickAdd
        openDashboardAction = openDashboard
        openSettingsAction = openSettings
        checkForUpdatesAction = checkForUpdates
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        quickAddItem = NSMenuItem(title: "快速新增任务", action: nil, keyEquivalent: "")
        taskPanelItem = NSMenuItem(title: "显示任务板", action: nil, keyEquivalent: "")
        desktopWidgetItem = NSMenuItem(title: "桌面小组件模式", action: nil, keyEquivalent: "")
        clickThroughItem = NSMenuItem(title: "鼠标穿透", action: nil, keyEquivalent: "")
        blurItem = NSMenuItem(title: "毛玻璃", action: nil, keyEquivalent: "")
        alwaysOnTopItem = NSMenuItem(title: "始终置顶", action: nil, keyEquivalent: "")
        opacityItem = NSMenuItem(title: "日常不透明度", action: nil, keyEquivalent: "")
        updateItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")
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
        opacityItem.title = "不透明度（\(percentage)%）"
        quickAddItem.title = "快速新增任务"
        taskPanelItem.title = panelController.isVisible
            ? "隐藏任务板"
            : "显示任务板"
        desktopWidgetItem.state = panelController.isDesktopWidget ? .on : .off
        desktopWidgetItem.title = panelController.isDesktopWidget
            ? "桌面小组件模式：已开启"
            : "桌面小组件模式"
        clickThroughItem.title = panelController.isClickThrough
            ? "鼠标穿透：已开启"
            : "鼠标穿透"
        alwaysOnTopItem.title = "始终置顶"
        applyShortcut(.quickAdd, to: quickAddItem)
        applyShortcut(.toggleTaskPanel, to: taskPanelItem)
        applyShortcut(.toggleClickThrough, to: clickThroughItem)
        applyShortcut(.toggleAlwaysOnTop, to: alwaysOnTopItem)
        applyShortcut(.toggleDesktopWidget, to: desktopWidgetItem)
        opacityPresetItems.forEach { item in
            guard let rawValue = item.representedObject as? Int else { return }
            item.state = rawValue == percentage ? .on : .off
        }
        switch updateState {
        case .idle:
            updateItem.title = "检查更新…"
            updateItem.isEnabled = true
        case .checking:
            updateItem.title = "正在检查更新…"
            updateItem.isEnabled = false
        case let .available(version):
            updateItem.title = "更新到 v\(version)"
            updateItem.isEnabled = true
        case let .downloading(version):
            updateItem.title = "正在更新到 v\(version)…"
            updateItem.isEnabled = false
        }
    }

    func setUpdateState(_ state: AppUpdateState) {
        updateState = state
        refreshState()
    }

    func showUpdateAvailable(version: String) {
        messageDismissTask?.cancel()
        messagePopover?.close()
        let controller = UpdatePromptViewController(
            version: version,
            onInstall: { [weak self] in
                self?.messagePopover?.close()
                self?.messagePopover = nil
                self?.checkForUpdatesAction()
            },
            onLater: { [weak self] in
                self?.messagePopover?.close()
                self?.messagePopover = nil
            }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = controller.contentSize
        popover.contentViewController = controller
        messagePopover = popover

        DispatchQueue.main.async { [weak self, weak popover] in
            guard let self, let popover, let button = self.statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func showTransientMessage(title: String, message: String) {
        messageDismissTask?.cancel()
        messagePopover?.close()

        let controller = TransientMessageViewController(title: title, message: message)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = controller.contentSize
        popover.contentViewController = controller
        messagePopover = popover

        DispatchQueue.main.async { [weak self, weak popover] in
            guard let self, let popover, let button = self.statusItem.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        messageDismissTask = Task { @MainActor [weak self, weak popover] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, self?.messagePopover === popover else { return }
            popover?.close()
            self?.messagePopover = nil
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
        menu.addItem(item("设置…", action: #selector(openSettingsFromStatusMenu)))
        menu.addItem(.separator())

        clickThroughItem.target = self
        clickThroughItem.action = #selector(toggleClickThrough)
        menu.addItem(clickThroughItem)

        blurItem.target = self
        blurItem.action = #selector(toggleBlur)
        menu.addItem(blurItem)

        let opacityMenu = NSMenu(title: "不透明度")
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
        desktopWidgetItem.target = self
        desktopWidgetItem.action = #selector(toggleDesktopWidget)
        menu.addItem(desktopWidgetItem)
        menu.addItem(.separator())
        updateItem.target = self
        updateItem.action = #selector(checkForUpdates)
        menu.addItem(updateItem)
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

    @objc private func toggleDesktopWidget() {
        panelController.toggleDesktopWidget()
    }

    @objc private func quickAdd() {
        quickAddAction()
    }

    @objc private func openDashboard() {
        openDashboardAction()
    }

    @objc private func openSettingsFromStatusMenu() {
        openSettingsAction()
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

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? Int,
              let preset = OpacityPreset(rawValue: rawValue) else { return }
        panelController.setPanelOpacity(preset.opacity)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

@MainActor
final class TransientMessageViewController: NSViewController {
    private static let horizontalInset: CGFloat = 12
    private static let minimumContentWidth: CGFloat = 136
    private static let maximumContentWidth: CGFloat = 260
    private static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let messageFont = NSFont.systemFont(ofSize: 12)

    private let messageTitle: String
    private let message: String
    private let contentWidth: CGFloat

    init(title: String, message: String) {
        messageTitle = title
        self.message = message
        let titleWidth = ceil((title as NSString).size(
            withAttributes: [.font: Self.titleFont]
        ).width)
        let messageWidth = ceil((message as NSString).size(
            withAttributes: [.font: Self.messageFont]
        ).width)
        contentWidth = min(
            max(
                max(titleWidth, messageWidth) + Self.horizontalInset * 2,
                Self.minimumContentWidth
            ),
            Self.maximumContentWidth
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var contentSize: NSSize {
        _ = view
        view.layoutSubtreeIfNeeded()
        return NSSize(
            width: contentWidth,
            height: ceil(view.fittingSize.height)
        )
    }

    override func loadView() {
        let titleLabel = NSTextField(labelWithString: messageTitle)
        titleLabel.font = Self.titleFont
        titleLabel.identifier = NSUserInterfaceItemIdentifier("transient.title")

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = Self.messageFont
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 3
        messageLabel.preferredMaxLayoutWidth = contentWidth - Self.horizontalInset * 2
        messageLabel.identifier = NSUserInterfaceItemIdentifier("transient.message")

        let contentView = NSStackView(views: [titleLabel, messageLabel])
        contentView.orientation = .vertical
        contentView.alignment = .leading
        contentView.spacing = 2
        contentView.edgeInsets = NSEdgeInsets(
            top: 9,
            left: Self.horizontalInset,
            bottom: 9,
            right: Self.horizontalInset
        )

        view = NSView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 1))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
    }
}

@MainActor
final class UpdatePromptViewController: NSViewController {
    private static let contentWidth: CGFloat = 356
    private static let accentColor = NSColor(
        calibratedRed: 107 / 255,
        green: 86 / 255,
        blue: 200 / 255,
        alpha: 1
    )

    private let version: String
    private let onInstall: () -> Void
    private let onLater: () -> Void

    init(
        version: String,
        onInstall: @escaping () -> Void,
        onLater: @escaping () -> Void
    ) {
        self.version = version
        self.onInstall = onInstall
        self.onLater = onLater
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var contentSize: NSSize {
        _ = view
        view.layoutSubtreeIfNeeded()
        return NSSize(
            width: Self.contentWidth,
            height: ceil(view.fittingSize.height)
        )
    }

    override func loadView() {
        let iconBackground = NSView()
        iconBackground.wantsLayer = true
        iconBackground.layer?.backgroundColor = Self.accentColor.withAlphaComponent(0.14).cgColor
        iconBackground.layer?.borderColor = Self.accentColor.withAlphaComponent(0.32).cgColor
        iconBackground.layer?.borderWidth = 1
        iconBackground.layer?.cornerRadius = 12
        iconBackground.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: NSImage(
            systemSymbolName: "arrow.down.to.line.compact",
            accessibilityDescription: "有可用更新"
        ) ?? NSImage())
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 20,
            weight: .semibold
        )
        iconView.contentTintColor = Self.accentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(iconView)

        let statusLabel = NSTextField(labelWithString: "新版本可用")
        statusLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        statusLabel.textColor = Self.accentColor
        statusLabel.identifier = NSUserInterfaceItemIdentifier("update.status")

        let titleLabel = NSTextField(labelWithString: "Woo Todo v\(version)")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("update.title")

        let detailLabel = NSTextField(
            wrappingLabelWithString: "下载完成后会自动安装，完成后重新打开 Woo Todo。"
        )
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.preferredMaxLayoutWidth = 246
        detailLabel.identifier = NSUserInterfaceItemIdentifier("update.detail")

        let textStack = NSStackView(views: [statusLabel, titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerStack = NSStackView(views: [iconBackground, textStack])
        headerStack.orientation = .horizontal
        headerStack.alignment = .top
        headerStack.spacing = 14

        let reassuranceIcon = NSImageView(image: NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: nil
        ) ?? NSImage())
        reassuranceIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 11,
            weight: .medium
        )
        reassuranceIcon.contentTintColor = .systemGreen
        reassuranceIcon.setContentHuggingPriority(.required, for: .horizontal)

        let reassuranceLabel = NSTextField(labelWithString: "本地任务和设置会保留")
        reassuranceLabel.font = .systemFont(ofSize: 11)
        reassuranceLabel.textColor = .secondaryLabelColor
        reassuranceLabel.identifier = NSUserInterfaceItemIdentifier("update.reassurance")

        let reassuranceStack = NSStackView(views: [reassuranceIcon, reassuranceLabel])
        reassuranceStack.orientation = .horizontal
        reassuranceStack.alignment = .centerY
        reassuranceStack.spacing = 5

        let installButton = NSButton(title: "立即更新", target: self, action: #selector(install))
        installButton.bezelStyle = .rounded
        installButton.controlSize = .regular
        installButton.font = .systemFont(ofSize: 13, weight: .semibold)
        installButton.bezelColor = Self.accentColor
        installButton.keyEquivalent = "\r"
        installButton.identifier = NSUserInterfaceItemIdentifier("update.install")

        let laterButton = NSButton(title: "稍后", target: self, action: #selector(later))
        laterButton.isBordered = false
        laterButton.controlSize = .regular
        laterButton.wantsLayer = true
        laterButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        laterButton.layer?.cornerRadius = 7
        laterButton.attributedTitle = NSAttributedString(
            string: "稍后",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        laterButton.identifier = NSUserInterfaceItemIdentifier("update.later")

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonStack = NSStackView(
            views: [reassuranceStack, buttonSpacer, laterButton, installButton]
        )
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.distribution = .fill

        let separator = NSBox()
        separator.boxType = .separator

        let contentView = NSStackView(views: [headerStack, separator, buttonStack])
        contentView.orientation = .vertical
        contentView.alignment = .width
        contentView.spacing = 14
        contentView.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)

        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 1))
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            iconBackground.widthAnchor.constraint(equalToConstant: 50),
            iconBackground.heightAnchor.constraint(equalToConstant: 50),
            iconView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            laterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            installButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
    }

    @objc private func install() {
        onInstall()
    }

    @objc private func later() {
        onLater()
    }
}
