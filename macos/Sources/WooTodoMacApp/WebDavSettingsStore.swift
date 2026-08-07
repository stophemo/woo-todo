import Foundation
import OSLog
import WooTodoStorage
import WooTodoSync

struct WebDavConnectionSummary: Equatable {
    let endpoint: URL
    let username: String
    let vaultId: String
    let deviceId: String
}

@MainActor
final class WebDavSettingsStore: ObservableObject {
    @Published var endpointText = ""
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
    var onWillReplaceWorkerSync: (() async -> Void)?
    var onDidReplaceWorkerSync: (() -> Void)?
    var onReplaceWorkerSyncFailed: (() -> Void)?
    @Published private(set) var workerSyncConfigured: Bool

    var setupLinkURL: URL? {
        guard let credentials else { return nil }
        return try? WebDavSetupLink(
            endpoint: credentials.endpoint,
            username: credentials.username,
            appPassword: credentials.appPassword,
            vaultId: credentials.vaultId,
            vaultKey: Base64URL.encode(credentials.vaultKey)
        ).url()
    }

    private let logger = Logger(
        subsystem: "io.github.stophemo.woo-todo",
        category: "WebDAV 同步"
    )
    private let repository: SQLiteTaskRepository
    private let credentialsStore: any WebDavCredentialsStoring
    private let workerCredentialsStore: any SyncCredentialsStoring
    private let defaults: UserDefaults
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
        credentialsStore: any WebDavCredentialsStoring = WebDavCredentialsStore(),
        workerCredentialsStore: any SyncCredentialsStoring,
        workerSyncConfigured: Bool,
        defaults: UserDefaults = .standard,
        initialCredentials: Result<WebDavCredentials?, Error>? = nil
    ) {
        self.repository = repository
        self.credentialsStore = credentialsStore
        self.workerCredentialsStore = workerCredentialsStore
        self.workerSyncConfigured = workerSyncConfigured
        self.defaults = defaults
        self.draftDeviceId = UUID().uuidString.lowercased()
        let savedSuccess = defaults.object(
            forKey: Self.lastSuccessfulDefaultsKey
        ) as? Double
        let machine = SyncRuntimeStateMachine(
            isConfigured: false,
            lastSuccessfulAt: savedSuccess.map(Date.init(timeIntervalSince1970:))
        )
        self.runtimeMachine = machine
        self.runtimeSnapshot = machine.snapshot

        do {
            let storedCredentials: WebDavCredentials?
            if let initialCredentials {
                storedCredentials = try initialCredentials.get()
            } else {
                storedCredentials = try credentialsStore.load()
            }
            if workerSyncConfigured {
                if let storedCredentials {
                    applyDraft(storedCredentials)
                } else {
                    makeFreshDraft()
                }
            } else if let storedCredentials {
                try repository.configureSync(Self.sqliteConfiguration(for: storedCredentials))
                try activate(storedCredentials)
                runtimeMachine.setConfigured(true)
                runtimeSnapshot = runtimeMachine.snapshot
            } else {
                makeFreshDraft()
            }
        } catch {
            makeFreshDraft()
            actionErrorMessage = "WebDAV 同步身份暂时不可用：\(error.localizedDescription)"
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

    func configure(replacingWorkerSync: Bool = false) async {
        guard (!workerSyncConfigured || replacingWorkerSync), !isSaving else { return }
        isSaving = true
        actionErrorMessage = nil
        defer { isSaving = false }

        var previous: WebDavCredentials?
        var previousWorkerCredentials: SyncCredentials?
        var replacementPrepared = false
        do {
            previous = try credentialsStore.load()
            let key = try Base64URL.decode(
                vaultKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard let endpoint = URL(
                string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
            ) else {
                throw WebDavError.invalidEndpoint
            }
            let newCredentials = WebDavCredentials(
                endpoint: endpoint,
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                appPassword: appPassword,
                vaultId: vaultId.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceId: credentials?.deviceId ?? previous?.deviceId ?? draftDeviceId,
                vaultKey: key
            )
            try newCredentials.validate()
            let preparedClient = try WebDavClient(credentials: newCredentials)
            let remoteLamportFloor: Int64
            if replacingWorkerSync {
                try await preparedClient.ensureCollections()
                remoteLamportFloor = try await preparedClient.maximumLamport()
            } else {
                remoteLamportFloor = 0
            }
            previousWorkerCredentials = try workerCredentialsStore.load()
            if replacingWorkerSync {
                guard previousWorkerCredentials != nil else {
                    throw WebDavError.invalidCredentials
                }
                await onWillReplaceWorkerSync?()
                replacementPrepared = true
            }
            try credentialsStore.save(newCredentials)
            do {
                if replacingWorkerSync {
                    try repository.replaceSyncBinding(
                        with: Self.sqliteConfiguration(for: newCredentials),
                        remoteLamportFloor: remoteLamportFloor
                    )
                } else {
                    try repository.configureSync(Self.sqliteConfiguration(for: newCredentials))
                }
                activate(newCredentials, client: preparedClient)
            } catch {
                throw error
            }
            workerSyncConfigured = false
            SyncBackendSelection.webDav.persist(in: defaults)
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            if replacingWorkerSync {
                onDidReplaceWorkerSync?()
            }
            requestSync(.localChange)
        } catch {
            if let previous {
                try? credentialsStore.save(previous)
            } else {
                try? credentialsStore.delete()
            }
            if replacementPrepared {
                if let previousWorkerCredentials {
                    try? workerCredentialsStore.save(previousWorkerCredentials)
                }
                onReplaceWorkerSyncFailed?()
            }
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
        activate(credentials, client: client)
    }

    private func activate(_ credentials: WebDavCredentials, client: WebDavClient) {
        self.credentials = credentials
        self.runner = WebDavSyncRunner(client: client, outbox: repository, local: repository)
        self.connection = WebDavConnectionSummary(
            endpoint: credentials.endpoint,
            username: credentials.username,
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId
        )
        endpointText = credentials.endpoint.absoluteString
        username = credentials.username
        appPassword = credentials.appPassword
        vaultId = credentials.vaultId
        vaultKeyText = Base64URL.encode(credentials.vaultKey)
    }

    func prepareForReplacement() async {
        let runningSync = syncTask
        stop()
        await runningSync?.value
    }

    func finishReplacement() {
        credentials = nil
        runner = nil
        connection = nil
        workerSyncConfigured = true
        runtimeMachine = SyncRuntimeStateMachine(isConfigured: false)
        publishRuntimeState()
        do {
            if let stored = try credentialsStore.load() {
                applyDraft(stored)
            } else {
                appPassword = ""
                makeFreshDraft()
            }
        } catch {
            appPassword = ""
            makeFreshDraft()
            actionErrorMessage = "无法读取已保存的 WebDAV 配置：\(error.localizedDescription)"
        }
    }

    func resumeAfterFailedReplacement() {
        do {
            if let stored = try credentialsStore.load() {
                try activate(stored)
                runtimeMachine.setConfigured(true)
                publishRuntimeState()
            }
            start()
        } catch {
            actionErrorMessage = "WebDAV 同步身份暂时不可用：\(error.localizedDescription)"
        }
    }

    private func runSyncLoop(startingWith initialTrigger: SyncTrigger) async {
        var trigger: SyncTrigger? = initialTrigger
        while trigger != nil, !Task.isCancelled {
            guard let runner else {
                trigger = runtimeMachine.fail(message: "WebDAV 同步尚未配置")
                publishRuntimeState()
                continue
            }
            do {
                let summary = try await runner.synchronize()
                lastRunSummary = summary
                let successfulAt = Date()
                defaults.set(
                    successfulAt.timeIntervalSince1970,
                    forKey: Self.lastSuccessfulDefaultsKey
                )
                trigger = runtimeMachine.succeed(at: successfulAt)
                publishRuntimeState()
                if summary.pulled > 0 { onRemoteChanges?() }
            } catch is CancellationError {
                trigger = runtimeMachine.fail(message: "WebDAV 同步已取消")
                publishRuntimeState()
                break
            } catch {
                trigger = runtimeMachine.fail(message: error.localizedDescription)
                publishRuntimeState()
                logger.notice("WebDAV 后台同步暂时失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        syncTask = nil
    }

    private func makeFreshDraft() {
        let randomVault = (try? SecureRandom.bytes(count: 9)).map(Base64URL.encode) ?? UUID().uuidString
        let randomKey = (try? SecureRandom.bytes(count: AES256GCM.keyByteCount)).map(Base64URL.encode) ?? ""
        endpointText = ""
        vaultId = "vault-\(randomVault)"
        vaultKeyText = randomKey
    }

    private func applyDraft(_ credentials: WebDavCredentials) {
        endpointText = credentials.endpoint.absoluteString
        username = credentials.username
        appPassword = credentials.appPassword
        vaultId = credentials.vaultId
        vaultKeyText = Base64URL.encode(credentials.vaultKey)
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
