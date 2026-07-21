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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
                }
            )

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

    func applicationWillTerminate(_ notification: Notification) {
        syncSettingsStore?.stop()
        webDavSettingsStore?.stop()
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

    private func showDashboard() {
        if let dashboardWindowController {
            dashboardWindowController.show()
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
            shortcutSettingsStore: shortcutSettingsStore
        )
        controller.onClose = { [weak self] in
            self?.dashboardWindowController = nil
        }
        dashboardWindowController = controller
        controller.show()
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
