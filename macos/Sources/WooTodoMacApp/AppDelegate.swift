import AppKit
import OSLog
import WooTodoCore
import WooTodoStorage
import WooTodoSync

/// 普通窗口打开时临时显示 Dock 图标，全部收起后回到纯菜单栏应用。
enum WindowActivationPolicy {
    static func resolve(
        mainVisible: Bool,
        settingsVisible: Bool
    ) -> NSApplication.ActivationPolicy {
        mainVisible || settingsVisible ? .regular : .accessory
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "io.github.stophemo.woo-todo", category: "应用")
    private var repository: SQLiteTaskRepository?
    private var todayStore: TodayStore?
    private var syncSettingsStore: SyncSettingsStore?
    private var dayCounterStore: DayCounterStore?
    private var dailyDigestSettingsStore: DailyDigestSettingsStore?
    private var shortcutSettingsStore: ShortcutSettingsStore?
    private var mcpSettingsStore: MCPSettingsStore?
    private var taskNotificationScheduler: TaskNotificationScheduler?
    private var panelController: FloatingPanelController?
    private var quickAddPanelController: QuickAddPanelController?
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var statusMenuController: StatusMenuController?
    private var appUpdateController: AppUpdateController?
    private var localDataManager: LocalDataManager?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        do {
            let runtime = try AppRuntimeConfiguration.current()
            let localDataManager = LocalDataManager(
                bundleIdentifier: Bundle.main.bundleIdentifier
                    ?? "io.github.stophemo.woo-todo",
                bundleURL: Bundle.main.bundleURL,
                appSupportURL: runtime.appDataURL,
                cachesURL: runtime.cachesURL,
                savedStateURL: runtime.savedStateURL,
                defaults: runtime.defaults,
                syncCredentialsStore: runtime.syncCredentialsStore,
                allowsAppRemoval: runtime.allowsLocalDataRemoval
            )
            self.localDataManager = localDataManager
            // 本地任务库是启动的唯一硬依赖；同步身份即使损坏或不匹配也不能阻塞本地使用。
            let repository = try SQLiteTaskRepository(databaseURL: runtime.databaseURL)
            if runtime.shouldSeedUITestFixtures {
                try UITestFixtureSeeder.seedIfNeeded(repository: repository)
            }
            let credentialsStore = runtime.syncCredentialsStore
            var storedCredentials: SyncCredentials?
            var credentialsLoadError: Error?
            do {
                storedCredentials = try credentialsStore.load()
            } catch {
                credentialsLoadError = error
                logger.error(
                    "同步身份无法读取，本地模式继续启动：\(error.localizedDescription, privacy: .public)"
                )
            }
            let startupDecision = SyncStartupActivationPolicy.evaluate(
                storedCredentials: storedCredentials,
                credentialsError: credentialsLoadError,
                applicationSupportURL: runtime.appDataURL
            )
            let legacyDetection = startupDecision.legacyDetection
            let hasStoredValidCredentials = startupDecision.hasStoredValidCredentials
            // 旧文件只影响提示，不能否决已读取且合法的新凭据。
            var activeCredentials = startupDecision.activeCredentials
            var syncActivationError = startupDecision.activationError
            if let credentials = activeCredentials {
                do {
                    try repository.configureSync(SQLiteSyncConfiguration(
                        vaultId: credentials.vaultId,
                        deviceId: credentials.deviceId,
                        vaultKey: credentials.vaultKey
                    ))
                } catch {
                    activeCredentials = nil
                    syncActivationError = error
                    logger.error(
                        "同步身份无法激活，本地模式继续启动：\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            let syncSettingsStore = try SyncSettingsStore(
                repository: repository,
                credentialsStore: credentialsStore,
                credentials: activeCredentials,
                defaultSyncEndpoint: runtime.defaultSyncEndpoint,
                legacyDetection: legacyDetection,
                hasStoredValidCredentials: hasStoredValidCredentials,
                defaults: runtime.defaults
            )
            let store = TodayStore(repository: repository)
            let mcpSettingsStore = MCPSettingsStore(
                store: store,
                repository: repository,
                defaults: runtime.defaults,
                allowsExternalServices: runtime.allowsExternalServices
            )
            let dayCounterStore = DayCounterStore(
                defaults: runtime.defaults,
                repository: repository
            )
            let dailyDigestSettingsStore = DailyDigestSettingsStore(defaults: runtime.defaults)
            let taskNotificationScheduler: TaskNotificationScheduler? = runtime.allowsExternalServices
                ? TaskNotificationScheduler()
                : nil
            do {
                let migrated = try LegacyTaskDateMigration.run(
                    repository: repository,
                    defaults: runtime.defaults
                )
                if migrated > 0 {
                    logger.notice("已将 \(migrated) 条旧任务的一天区间折算为任务日期")
                }
            } catch {
                logger.error(
                    "旧任务日期折算失败：\(error.localizedDescription, privacy: .public)"
                )
            }
            store.reload()
            store.onTasksChanged = { [weak self] in
                // 先让本地列表完成渲染，再启动同步和通知调度；网络不可成为勾选反馈的前置条件。
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self else { return }
                    self.mainWindowController?.reloadIfVisible()
                    self.syncSettingsStore?.requestSync(.localChange)
                    self.refreshTaskNotifications()
                }
            }

            let panelController = FloatingPanelController(
                store: store,
                dayCounterStore: dayCounterStore,
                defaults: runtime.defaults
            )
            let quickAddPanelController = QuickAddPanelController(
                store: store,
                dismissesOnResignKey: runtime.initialScreen != .quickAdd
            )
            let appUpdateController: AppUpdateController? = runtime.allowsExternalServices
                ? AppUpdateController(defaults: runtime.defaults)
                : nil
            let shortcutSettingsStore = ShortcutSettingsStore(
                defaults: runtime.defaults,
                actions: [
                    .quickAdd: { [weak quickAddPanelController] in
                        quickAddPanelController?.show()
                    },
                    .toggleTaskPanel: { [weak panelController] in
                        panelController?.toggleVisibility()
                    },
                    .toggleAlwaysOnTop: { [weak panelController] in
                        panelController?.toggleAlwaysOnTop()
                    },
                    .toggleClickThrough: { [weak panelController] in
                        panelController?.toggleClickThrough()
                    },
                    .toggleDesktopWidget: { [weak panelController] in
                        panelController?.toggleDesktopWidget()
                    },
                    .increasePanelOpacity: { [weak panelController] in
                        panelController?.increasePanelOpacity()
                    },
                    .decreasePanelOpacity: { [weak panelController] in
                        panelController?.decreasePanelOpacity()
                    },
                ]
            )
            let statusMenuController: StatusMenuController?
            if runtime.allowsExternalServices {
                statusMenuController = StatusMenuController(
                    panelController: panelController,
                    shortcutSettingsStore: shortcutSettingsStore,
                    quickAdd: { [weak quickAddPanelController] in
                        quickAddPanelController?.show()
                    },
                    mainWindowVisible: { [weak self] in
                        guard let self else { return false }
                        return self.mainWindowController?.isVisible == true && !NSApp.isHidden
                    },
                    toggleMainWindow: { [weak self] in
                        self?.toggleMainWindow()
                    },
                    openSettings: { [weak self] in
                        self?.showSettings(section: .display)
                    },
                    checkForUpdates: { [weak appUpdateController] in
                        appUpdateController?.performMenuAction()
                    }
                )
            } else {
                statusMenuController = nil
            }

            self.repository = repository
            todayStore = store
            self.syncSettingsStore = syncSettingsStore
            self.dayCounterStore = dayCounterStore
            self.dailyDigestSettingsStore = dailyDigestSettingsStore
            self.shortcutSettingsStore = shortcutSettingsStore
            self.mcpSettingsStore = mcpSettingsStore
            self.taskNotificationScheduler = taskNotificationScheduler
            self.panelController = panelController
            self.quickAddPanelController = quickAddPanelController
            self.statusMenuController = statusMenuController
            self.appUpdateController = appUpdateController
            appUpdateController?.onStateChange = { [weak statusMenuController] state in
                statusMenuController?.setUpdateState(state)
            }
            appUpdateController?.onMessage = { [weak statusMenuController] title, message in
                statusMenuController?.showTransientMessage(title: title, message: message)
            }
            appUpdateController?.onUpdateAvailable = { [weak statusMenuController] version in
                statusMenuController?.showUpdateAvailable(version: version)
            }
            appUpdateController?.checkOnLaunch()
            if runtime.allowsExternalServices {
                wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.dayCounterStore?.refreshDate()
                        self?.appUpdateController?.checkAutomatically()
                    }
                }
            }
            panelController.onStateChange = { [weak statusMenuController] in
                statusMenuController?.refreshState()
            }
            shortcutSettingsStore.onBindingsChanged = { [weak statusMenuController] in
                statusMenuController?.refreshState()
            }
            dayCounterStore.onLocalConfigurationChanged = { [weak self] in
                self?.syncSettingsStore?.requestSync(.localChange)
            }
            dayCounterStore.onDateChanged = { [weak self] in
                self?.todayStore?.settleRecurringTasks()
                self?.mainWindowController?.reloadIfVisible()
                self?.refreshTaskNotifications()
            }
            dailyDigestSettingsStore.onChange = { [weak self] in
                self?.refreshTaskNotifications()
            }
            if runtime.allowsExternalServices {
                shortcutSettingsStore.start()
            }
            syncSettingsStore.onRemoteChanges = { [weak self] in
                self?.todayStore?.settleRecurringTasks()
                self?.todayStore?.reload()
                self?.dayCounterStore?.reloadFromRepository()
                self?.mainWindowController?.reloadIfVisible()
                self?.refreshTaskNotifications()
            }
            syncSettingsStore.onLifecycleRefresh = { [weak self] in
                self?.todayStore?.settleRecurringTasks()
                self?.todayStore?.reload()
                self?.mainWindowController?.reloadIfVisible()
                self?.refreshTaskNotifications()
            }
            mcpSettingsStore.startIfNeeded()
            store.settleRecurringTasks()
            if runtime.allowsExternalServices {
                syncSettingsStore.start()
                refreshTaskNotifications()
            }
            switch runtime.initialScreen {
            case let .main(section):
                showMainWindow(section: section)
                scheduleUITestSnapshot(
                    window: mainWindowController?.window,
                    runtime: runtime
                )
            case let .settings(section):
                showSettings(section: section)
                scheduleUITestSnapshot(
                    window: settingsWindowController?.window,
                    runtime: runtime
                )
            case .quickAdd:
                quickAddPanelController.show()
                scheduleUITestSnapshot(window: quickAddPanelController.window, runtime: runtime)
            case .panel:
                panelController.show()
                scheduleUITestSnapshot(window: panelController.window, runtime: runtime)
            }
            if let syncActivationError {
                showSyncCredentialsWarning(syncActivationError)
            }
            if let legacyNotice = syncSettingsStore.legacyNotice {
                showLegacySyncNotice(legacyNotice)
                syncSettingsStore.acknowledgeLegacyNotice()
            }
            logger.info("Woo Todo 已启动，本地任务面板准备完成")
        } catch {
            logger.error("启动失败：\(error.localizedDescription, privacy: .public)")
            showStartupError(error)
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        appUpdateController?.checkAutomatically()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if mainWindowController?.isVisible == true, !NSApp.isHidden {
            return false
        }
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        appUpdateController?.stop()
        syncSettingsStore?.stop()
        mcpSettingsStore?.stop()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu(title: "Woo Todo")

        let applicationMenuItem = NSMenuItem(
            title: "Woo Todo",
            action: nil,
            keyEquivalent: ""
        )
        let applicationMenu = NSMenu(title: "Woo Todo")
        let aboutItem = NSMenuItem(
            title: "关于 Woo Todo",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        applicationMenu.addItem(aboutItem)
        applicationMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出 Woo Todo",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let editMenuItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(editCommand("撤销", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(editCommand(
            "重做",
            action: Selector(("redo:")),
            key: "z",
            modifiers: [.command, .shift]
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(editCommand("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(editCommand("复制", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(editCommand("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(editCommand("全选", action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        let mainWindowItem = NSMenuItem(
            title: "显示 Woo Todo 主窗口",
            action: #selector(showMainWindowFromMenu),
            keyEquivalent: "0"
        )
        mainWindowItem.keyEquivalentModifierMask = .command
        mainWindowItem.target = self
        windowMenu.addItem(mainWindowItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(editCommand(
            "关闭",
            action: #selector(NSWindow.performClose(_:)),
            key: "w"
        ))
        windowMenu.addItem(editCommand(
            "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            key: "m"
        ))
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        showSettings(section: .display)
    }

    @objc private func showMainWindowFromMenu() {
        showMainWindow()
    }

    private func editCommand(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }

    private func showMainWindow(section: MainWindowSection? = nil) {
        let targetSection = section ?? mainWindowController?.currentSection ?? .today
        if let mainWindowController {
            mainWindowController.show(section: targetSection)
            return
        }
        guard let repository, let dayCounterStore else { return }

        let store = DashboardStore(repository: repository)
        store.onTasksChanged = { [weak self] in
            self?.todayStore?.reload()
            self?.syncSettingsStore?.requestSync(.localChange)
            self?.refreshTaskNotifications()
        }
        let controller = MainWindowController(
            store: store,
            dayCounterStore: dayCounterStore,
            initialSection: targetSection
        ) { [weak self] in
            self?.showSettings(section: .display)
        }
        controller.onClose = { [weak self] in
            self?.mainWindowController = nil
        }
        controller.onVisibilityChange = { [weak self] in
            self?.updateActivationPolicy()
        }
        mainWindowController = controller
        controller.show(section: targetSection)
    }

    private func showSettings(section: SettingsSection = .display) {
        if let settingsWindowController {
            settingsWindowController.show(section: section)
            return
        }
        guard let syncSettingsStore,
              let dayCounterStore,
              let dailyDigestSettingsStore,
              let shortcutSettingsStore,
              let mcpSettingsStore,
              let localDataManager else { return }

        let controller = SettingsWindowController(
            syncSettingsStore: syncSettingsStore,
            dayCounterStore: dayCounterStore,
            dailyDigestSettingsStore: dailyDigestSettingsStore,
            shortcutSettingsStore: shortcutSettingsStore,
            mcpSettingsStore: mcpSettingsStore,
            localDataManager: localDataManager,
            initialSection: section
        )
        controller.onClose = { [weak self] in
            self?.settingsWindowController = nil
        }
        controller.onVisibilityChange = { [weak self] in
            self?.updateActivationPolicy()
        }
        settingsWindowController = controller
        controller.show(section: section)
    }

    /// 打开普通窗口时临时显示 Dock 图标，主窗口和设置窗口都收起后回到纯菜单栏应用。
    private func updateActivationPolicy() {
        let policy = WindowActivationPolicy.resolve(
            mainVisible: mainWindowController?.isVisibleOrMiniaturized == true,
            settingsVisible: settingsWindowController?.isVisibleOrMiniaturized == true
        )
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
        statusMenuController?.refreshState()
    }

    private func toggleMainWindow() {
        if let mainWindowController, mainWindowController.isVisible, !NSApp.isHidden {
            mainWindowController.hide()
        } else {
            showMainWindow()
        }
    }

    private func refreshTaskNotifications() {
        guard let repository,
              let taskNotificationScheduler,
              let dailyDigestSettingsStore else { return }
        do {
            taskNotificationScheduler.synchronize(
                try repository.fetchAll(),
                digest: dailyDigestSettingsStore.configuration
            )
        } catch {
            logger.error(
                "刷新任务提醒失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func scheduleUITestSnapshot(
        window: NSWindow?,
        runtime: AppRuntimeConfiguration
    ) {
        guard let window,
              let directory = runtime.uiTestArtifactDirectory,
              let screenName = runtime.uiTestScreenName else { return }
        let destination = directory.appendingPathComponent("\(screenName).png")
        Task { @MainActor [weak window] in
            try? await Task.sleep(for: .seconds(2))
            guard let view = window?.contentView else { return }
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return
            }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                logger.error(
                    "UI 测试截图写入失败：\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func showStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Woo Todo 无法启动"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "退出")
        alert.runModal()
    }

    private func showLegacySyncNotice(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "旧同步方式已停用"
        alert.informativeText = message
        alert.addButton(withTitle: "继续使用本地任务")
        alert.runModal()
    }

    private func showSyncCredentialsWarning(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let repositoryError = error as? SQLiteRepositoryError,
           case .syncIdentityMismatch = repositoryError {
            alert.messageText = "同步身份与本地数据库不匹配"
            alert.informativeText = "Keychain 中的同步空间或设备身份与当前本地任务库不一致，因此本次启动已停用同步。\n\n本地任务仍可查看和编辑，变更会安全保存在本地待恢复队列中；应用没有覆盖 Keychain 或数据库身份。请先保留当前安装与数据，恢复匹配的同步身份后再重新启动。"
        } else {
            alert.messageText = "同步身份暂时不可用"
            alert.informativeText = "\(error.localizedDescription)\n\n本地任务仍可查看和编辑；如果数据库已有同步身份，变更会安全保存在本地待恢复队列中。Keychain 恢复并重新启动后，应用会补入待同步队列。请暂时不要卸载应用或创建新的同步空间。"
        }
        alert.addButton(withTitle: "继续使用本地任务")
        alert.runModal()
    }
}
