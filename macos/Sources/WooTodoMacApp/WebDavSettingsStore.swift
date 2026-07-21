import Foundation
import OSLog
import WooTodoStorage
import WooTodoSync

struct WebDavConnectionSummary: Equatable {
    let username: String
    let vaultId: String
    let deviceId: String
}

@MainActor
final class WebDavSettingsStore: ObservableObject {
    @Published var username = ""
    @Published var appPassword = ""
    @Published var vaultId = ""
    @Published var vaultKeyText = ""
    @Published private(set) var connection: WebDavConnectionSummary?
    @Published private(set) var runtimeSnapshot: SyncRuntimeSnapshot
    @Published private(set) var lastRunSummary: SyncRunSummary?
    @Published private(set) var actionErrorMessage: String?
    @Published private(set) var isSaving = false

    var onRemoteChanges: (() -> Void)?
    let workerSyncConfigured: Bool

    private let logger = Logger(
        subsystem: "io.github.stophemo.woo-todo",
        category: "坚果云同步"
    )
    private let repository: SQLiteTaskRepository
    private let credentialsStore: WebDavCredentialsStore
    private var credentials: WebDavCredentials?
    private var runner: WebDavSyncRunner?
    private var runtimeMachine: SyncRuntimeStateMachine
    private var syncTask: Task<Void, Never>?
    private var fallbackTimer: Timer?
    private var hasStarted = false
    private let draftDeviceId: String

    private static let lastSuccessfulDefaultsKey = "webdav.last-successful-at"
    private static let fallbackInterval: TimeInterval = 15 * 60

    init(
        repository: SQLiteTaskRepository,
        credentialsStore: WebDavCredentialsStore = WebDavCredentialsStore(),
        workerSyncConfigured: Bool
    ) {
        self.repository = repository
        self.credentialsStore = credentialsStore
        self.workerSyncConfigured = workerSyncConfigured
        self.draftDeviceId = UUID().uuidString.lowercased()
        let savedSuccess = UserDefaults.standard.object(
            forKey: Self.lastSuccessfulDefaultsKey
        ) as? Double
        let machine = SyncRuntimeStateMachine(
            isConfigured: false,
            lastSuccessfulAt: savedSuccess.map(Date.init(timeIntervalSince1970:))
        )
        self.runtimeMachine = machine
        self.runtimeSnapshot = machine.snapshot

        do {
            if workerSyncConfigured {
                makeFreshDraft()
                if try credentialsStore.load() != nil {
                    actionErrorMessage = "当前已连接 Worker，同一个任务库不能同时启用坚果云同步"
                }
            } else if let stored = try credentialsStore.load() {
                try repository.configureSync(Self.sqliteConfiguration(for: stored))
                try activate(stored)
                runtimeMachine.setConfigured(true)
                runtimeSnapshot = runtimeMachine.snapshot
            } else {
                makeFreshDraft()
            }
        } catch {
            makeFreshDraft()
            actionErrorMessage = "坚果云同步身份暂时不可用：\(error.localizedDescription)"
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        fallbackTimer = Timer.scheduledTimer(
            withTimeInterval: Self.fallbackInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestSync(.fallback) }
        }
        fallbackTimer?.tolerance = 60
        requestSync(.launch)
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        hasStarted = false
    }

    func configure() async {
        guard !workerSyncConfigured, !isSaving else { return }
        isSaving = true
        actionErrorMessage = nil
        defer { isSaving = false }

        do {
            let key = try Base64URL.decode(
                vaultKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let newCredentials = WebDavCredentials(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                appPassword: appPassword,
                vaultId: vaultId.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceId: credentials?.deviceId ?? draftDeviceId,
                vaultKey: key
            )
            try newCredentials.validate()
            let previous = try credentialsStore.load()
            try credentialsStore.save(newCredentials)
            do {
                try repository.configureSync(Self.sqliteConfiguration(for: newCredentials))
                try activate(newCredentials)
            } catch {
                if let previous {
                    try? credentialsStore.save(previous)
                } else {
                    try? credentialsStore.delete()
                }
                throw error
            }
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            requestSync(.localChange)
        } catch {
            actionErrorMessage = error.localizedDescription
        }
    }

    func requestSync(_ trigger: SyncTrigger = .manual) {
        guard runtimeMachine.request(trigger) else {
            publishRuntimeState()
            return
        }
        publishRuntimeState()
        syncTask = Task { [weak self] in
            await self?.runSyncLoop(startingWith: trigger)
        }
    }

    private func activate(_ credentials: WebDavCredentials) throws {
        let client = try WebDavClient(credentials: credentials)
        self.credentials = credentials
        self.runner = WebDavSyncRunner(client: client, outbox: repository, local: repository)
        self.connection = WebDavConnectionSummary(
            username: credentials.username,
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId
        )
        username = credentials.username
        appPassword = credentials.appPassword
        vaultId = credentials.vaultId
        vaultKeyText = Base64URL.encode(credentials.vaultKey)
    }

    private func runSyncLoop(startingWith initialTrigger: SyncTrigger) async {
        var trigger: SyncTrigger? = initialTrigger
        while trigger != nil, !Task.isCancelled {
            guard let runner else {
                trigger = runtimeMachine.fail(message: "坚果云同步尚未配置")
                publishRuntimeState()
                continue
            }
            do {
                let summary = try await runner.synchronize()
                lastRunSummary = summary
                let successfulAt = Date()
                UserDefaults.standard.set(
                    successfulAt.timeIntervalSince1970,
                    forKey: Self.lastSuccessfulDefaultsKey
                )
                trigger = runtimeMachine.succeed(at: successfulAt)
                publishRuntimeState()
                if summary.pulled > 0 { onRemoteChanges?() }
            } catch is CancellationError {
                trigger = runtimeMachine.fail(message: "坚果云同步已取消")
                publishRuntimeState()
                break
            } catch {
                trigger = runtimeMachine.fail(message: error.localizedDescription)
                publishRuntimeState()
                logger.notice("坚果云后台同步暂时失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        syncTask = nil
    }

    private func makeFreshDraft() {
        let randomVault = (try? SecureRandom.bytes(count: 9)).map(Base64URL.encode) ?? UUID().uuidString
        let randomKey = (try? SecureRandom.bytes(count: AES256GCM.keyByteCount)).map(Base64URL.encode) ?? ""
        vaultId = "vault-\(randomVault)"
        vaultKeyText = randomKey
    }

    private func publishRuntimeState() {
        runtimeSnapshot = runtimeMachine.snapshot
    }

    private static func sqliteConfiguration(
        for credentials: WebDavCredentials
    ) -> SQLiteSyncConfiguration {
        SQLiteSyncConfiguration(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId,
            vaultKey: credentials.vaultKey
        )
    }
}
