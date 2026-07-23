import AppKit
import OSLog
import WooTodoCore
import WooTodoStorage
import WooTodoSync

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "io.github.stophemo.woo-todo", category: "应用")
    private var repository: SQLiteTaskRepository?
    private var todayStore: TodayStore?
    private var syncSettingsStore: SyncSettingsStore?
    private var webDavSettingsStore: WebDavSettingsStore?
    private var dayCounterStore: DayCounterStore?
    private var shortcutSettingsStore: ShortcutSettingsStore?
    private var taskNotificationScheduler: TaskNotificationScheduler?
    private var panelController: FloatingPanelController?
    private var quickAddPanelController: QuickAddPanelController?
    private var dashboardWindowController: DashboardWindowController?
    private var statusMenuController: StatusMenuController?
    private var appUpdateController: AppUpdateController?
    private var wakeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        do {
            // 本地任务库是启动的唯一硬依赖；同步身份即使损坏或不匹配也不能阻塞本地使用。
            let repository = try SQLiteTaskRepository(databaseURL: databaseURL())
            let credentialsStore = KeychainCredentialsStore()
            let activeCredentials: SyncCredentials?
            let syncActivationError: Error?
            do {
                let credentials = try credentialsStore.load()
                if let credentials {
                    try repository.configureSync(SQLiteSyncConfiguration(
                        vaultId: credentials.vaultId,
                        deviceId: credentials.deviceId,
                        vaultKey: credentials.vaultKey
                    ))
                }
                activeCredentials = credentials
                syncActivationError = nil
            } catch let activationError {
                activeCredentials = nil
                syncActivationError = activationError
                logger.error(
                    "同步身份无法激活，本地模式继续启动：\(activationError.localizedDescription, privacy: .public)"
                )
            }
            let syncSettingsStore = try SyncSettingsStore(
                repository: repository,
                credentialsStore: credentialsStore,
                credentials: activeCredentials
            )
            let webDavSettingsStore = WebDavSettingsStore(
                repository: repository,
                workerSyncConfigured: activeCredentials != nil
            )
            let store = TodayStore(repository: repository)
            let dayCounterStore = DayCounterStore()
            let taskNotificationScheduler = TaskNotificationScheduler()
            store.reload()
            store.onTasksChanged = { [weak self] in
                self?.dashboardWindowController?.reload()
                self?.syncSettingsStore?.requestSync(.localChange)
                self?.webDavSettingsStore?.requestSync(.localChange)
                self?.refreshTaskNotifications()
            }

            let panelController = FloatingPanelController(
                store: store,
                dayCounterStore: dayCounterStore
            )
            let quickAddPanelController = QuickAddPanelController(store: store)
            let appUpdateController = AppUpdateController()
            let shortcutSettingsStore = ShortcutSettingsStore(actions: [
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
            ])
            let statusMenuController = StatusMenuController(
                panelController: panelController,
                shortcutSettingsStore: shortcutSettingsStore,
                quickAdd: { [weak quickAddPanelController] in
                    quickAddPanelController?.show()
                },
                openDashboard: { [weak self] in
                    self?.showDashboard()
                },
                openSettings: { [weak self] in
                    self?.showDashboard(section: .display)
                },
                checkForUpdates: { [weak appUpdateController] in
                    appUpdateController?.checkManually()
                },
                openAvailableUpdate: { [weak appUpdateController] in
                    appUpdateController?.openAvailableUpdate()
                }
            )

            appUpdateController.onAvailableUpdateChanged = { [weak statusMenuController] update in
                statusMenuController?.setAvailableUpdate(update)
            }

            self.repository = repository
            todayStore = store
            self.syncSettingsStore = syncSettingsStore
            self.webDavSettingsStore = webDavSettingsStore
            self.dayCounterStore = dayCounterStore
            self.shortcutSettingsStore = shortcutSettingsStore
            self.taskNotificationScheduler = taskNotificationScheduler
            self.panelController = panelController
            self.quickAddPanelController = quickAddPanelController
            self.statusMenuController = statusMenuController
            self.appUpdateController = appUpdateController
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
            panelController.onStateChange = { [weak statusMenuController] in
                statusMenuController?.refreshState()
            }
            shortcutSettingsStore.onBindingsChanged = { [weak statusMenuController] in
                statusMenuController?.refreshState()
            }
            shortcutSettingsStore.start()
            syncSettingsStore.onRemoteChanges = { [weak self] in
                self?.todayStore?.reload()
                self?.dashboardWindowController?.reload()
                self?.refreshTaskNotifications()
            }
            syncSettingsStore.onLifecycleRefresh = { [weak self] in
                self?.todayStore?.reload()
                self?.dashboardWindowController?.reload()
                self?.refreshTaskNotifications()
            }
            webDavSettingsStore.onRemoteChanges = { [weak self] in
                self?.todayStore?.reload()
                self?.dashboardWindowController?.reload()
                self?.refreshTaskNotifications()
            }
            syncSettingsStore.start()
            webDavSettingsStore.start()
            panelController.show()
            refreshTaskNotifications()
            if let syncActivationError {
                showSyncCredentialsWarning(syncActivationError)
            }
            appUpdateController.checkAutomatically()
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

    func applicationWillTerminate(_ notification: Notification) {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        syncSettingsStore?.stop()
        webDavSettingsStore?.stop()
        appUpdateController?.stop()
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

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        showDashboard(section: .display)
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

    private func databaseURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root
            .appendingPathComponent("WooTodo", isDirectory: true)
            .appendingPathComponent("tasks.sqlite")
    }

    private func showDashboard(section: DashboardSection = .today) {
        if let dashboardWindowController {
            dashboardWindowController.show(section: section)
            return
        }
        guard let repository,
              let todayStore,
              let syncSettingsStore,
              let webDavSettingsStore,
              let dayCounterStore,
              let shortcutSettingsStore else { return }

        let dashboardStore = DashboardStore(repository: repository)
        dashboardStore.onTasksChanged = { [weak self, weak todayStore, weak syncSettingsStore] in
            todayStore?.reload()
            syncSettingsStore?.requestSync(.localChange)
            self?.webDavSettingsStore?.requestSync(.localChange)
            self?.refreshTaskNotifications()
        }
        let controller = DashboardWindowController(
            store: dashboardStore,
            syncSettingsStore: syncSettingsStore,
            webDavSettingsStore: webDavSettingsStore,
            dayCounterStore: dayCounterStore,
            shortcutSettingsStore: shortcutSettingsStore,
            initialSection: section
        )
        controller.onClose = { [weak self] in
            self?.dashboardWindowController = nil
        }
        dashboardWindowController = controller
        controller.show(section: section)
    }

    private func refreshTaskNotifications() {
        guard let repository, let taskNotificationScheduler else { return }
        do {
            taskNotificationScheduler.synchronize(try repository.fetchAll())
        } catch {
            logger.error(
                "刷新任务提醒失败：\(error.localizedDescription, privacy: .public)"
            )
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
