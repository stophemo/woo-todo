import AppKit
import Carbon.HIToolbox
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
    private var panelController: FloatingPanelController?
    private var dashboardWindowController: DashboardWindowController?
    private var statusMenuController: StatusMenuController?
    private var globalShortcut: GlobalShortcut?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let credentialsStore = KeychainCredentialsStore()
            let credentials = try credentialsStore.load()
            let syncConfiguration = credentials.map {
                SQLiteSyncConfiguration(
                    vaultId: $0.vaultId,
                    deviceId: $0.deviceId,
                    vaultKey: $0.vaultKey
                )
            }
            let repository = try SQLiteTaskRepository(
                databaseURL: databaseURL(),
                syncConfiguration: syncConfiguration
            )
            let syncSettingsStore = try SyncSettingsStore(
                repository: repository,
                credentialsStore: credentialsStore,
                credentials: credentials
            )
            let store = TodayStore(repository: repository)
            store.reload()
            store.onTasksChanged = { [weak self] in
                self?.dashboardWindowController?.reload()
                self?.syncSettingsStore?.requestSync(.localChange)
            }

            let panelController = FloatingPanelController(store: store)
            let statusMenuController = StatusMenuController(
                panelController: panelController
            ) { [weak self] in
                self?.showDashboard()
            }
            let globalShortcut = try GlobalShortcut(
                keyCode: UInt32(kVK_Space),
                modifiers: UInt32(controlKey | optionKey)
            ) { [weak panelController] in
                panelController?.toggleInteraction()
            }

            self.repository = repository
            todayStore = store
            self.syncSettingsStore = syncSettingsStore
            self.panelController = panelController
            self.statusMenuController = statusMenuController
            self.globalShortcut = globalShortcut
            panelController.onStateChange = { [weak statusMenuController] in
                statusMenuController?.refreshState()
            }
            syncSettingsStore.onRemoteChanges = { [weak self] in
                self?.todayStore?.reload()
                self?.dashboardWindowController?.reload()
            }
            syncSettingsStore.onLifecycleRefresh = { [weak self] in
                self?.todayStore?.reload()
                self?.dashboardWindowController?.reload()
            }
            syncSettingsStore.start()
            panelController.show()
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
        guard let repository, let todayStore, let syncSettingsStore else { return }

        let dashboardStore = DashboardStore(repository: repository)
        dashboardStore.onTasksChanged = { [weak todayStore, weak syncSettingsStore] in
            todayStore?.reload()
            syncSettingsStore?.requestSync(.localChange)
        }
        let controller = DashboardWindowController(
            store: dashboardStore,
            syncSettingsStore: syncSettingsStore
        )
        controller.onClose = { [weak self] in
            self?.dashboardWindowController = nil
        }
        dashboardWindowController = controller
        controller.show()
    }

    private func showStartupError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Woo Todo 无法启动"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "退出")
        alert.runModal()
    }
}
