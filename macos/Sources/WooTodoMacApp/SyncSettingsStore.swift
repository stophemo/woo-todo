import AppKit
import Combine
import Foundation
import Network
import OSLog
import WooTodoStorage
import WooTodoSync

struct SyncConnectionSummary: Equatable {
    let endpoint: URL
    let vaultId: String
    let deviceId: String
    let deviceName: String
}

struct SyncDeviceSummary: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let platform: DevicePlatform
    let lastSeenAt: Date
    let appVersion: String
    let isCurrent: Bool
}

enum AccountEndpointAssessment: Equatable {
    case empty
    case invalid
    case ready(URL)
}

enum PathAShowPhase: Equatable {
    case idle
    case creating
    case awaitingClaim(code: String, deadline: Date)
    case awaitingVerification(
        deviceName: String,
        platform: DevicePlatform,
        code: String,
        deadline: Date
    )
    case confirmed
    case expired
    case failed(String)
}

enum PathAClaimPhase: Equatable {
    case idle
    case claiming
    case awaitingDecision
    case awaitingApproval(code: String, deadline: Date)
    case confirmed
    case failed(String)
}

enum PathBCreatePhase: Equatable {
    case idle
    case creating
    case awaitingDecision
    case waiting(code: String, deadline: Date)
    case awaitingApproval(
        verificationCode: String,
        deviceName: String,
        deadline: Date
    )
    case approved
    case expired
    case canceled
    case failed(String)
}

/// 加入其他空间前需要用户选择的数据基准。
enum JoinPolicyPrompt: Equatable {
    case clearLocalData(JoinLocalDataSummary)
    case chooseSpace(
        localVaultId: String,
        lastSyncedAt: Date?,
        peerDeviceName: String,
        peerPlatform: DevicePlatform
    )
}

private enum JoinLocalDataClearError: LocalizedError {
    case identityDeletionFailed(String)
    case identityStillPresent
    case localDataClearFailed(String)

    var errorDescription: String? {
        switch self {
        case let .identityDeletionFailed(message):
            return "本机同步身份删除失败，已中止加入并保留本机数据：\(message)"
        case .identityStillPresent:
            return "本机同步身份删除后仍然存在，已中止加入并保留本机数据。"
        case let .localDataClearFailed(message):
            return "本机任务清空失败，已停止同步并进入未配对状态：\(message)"
        }
    }
}

enum PathBApprovePhase: Equatable {
    case idle
    case resolving
    case awaitingConfirmation(
        deviceName: String,
        platform: DevicePlatform,
        code: String,
        deadline: Date
    )
    case approving
    case done
    case failed(String)
}

@MainActor
final class SyncSettingsStore: ObservableObject {
    typealias ClientFactory = (WebDavAccount, WebDavIdentity?) throws -> WebDavClient

    @Published var endpointText = ""
    @Published var username = ""
    @Published var appPassword = ""
    @Published private(set) var account: WebDavAccount?
    @Published private(set) var identity: WebDavIdentity?
    @Published private(set) var connection: SyncConnectionSummary?
    @Published private(set) var devices: [SyncDeviceSummary] = []
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var devicesErrorMessage: String?
    @Published private(set) var runtimeSnapshot: SyncRuntimeSnapshot
    @Published private(set) var lastRunSummary: SyncRunSummary?
    @Published private(set) var isSavingAccount = false
    @Published private(set) var isCreatingVault = false
    @Published private(set) var isExitingSpace = false
    @Published private(set) var pathAShowPhase: PathAShowPhase = .idle
    @Published private(set) var pathAShowCode: String?
    @Published private(set) var pathAClaimPhase: PathAClaimPhase = .idle
    @Published private(set) var pathBCreatePhase: PathBCreatePhase = .idle
    @Published private(set) var pathBCreateCode: String?
    @Published private(set) var pathBApprovePhase: PathBApprovePhase = .idle
    @Published private(set) var joinPolicyPrompt: JoinPolicyPrompt?
    @Published private(set) var actionErrorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var legacyNotice: String?

    var onRemoteChanges: (() -> Void)?
    var onLifecycleRefresh: (() -> Void)?

    var endpointAssessment: AccountEndpointAssessment {
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let url = URL(string: trimmed),
              WebDavEndpointPolicy.isAllowed(url) else {
            return .invalid
        }
        return .ready(url)
    }

    var canSaveAccount: Bool {
        if case .ready = endpointAssessment {
            return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !appPassword.isEmpty
        }
        return false
    }

    private let logger = Logger(
        subsystem: "io.github.stophemo.woo-todo",
        category: "跨设备"
    )
    private let repository: SQLiteTaskRepository
    private let credentialsStore: any WebDavCredentialsStoring
    private let defaults: UserDefaults
    private let clientFactory: ClientFactory
    private let pollInterval: TimeInterval
    private let now: () -> Date
    private var runner: WebDavSyncRunner?
    private var runtimeMachine: SyncRuntimeStateMachine
    private var pathAShowSession: WebDavPathAShowSession?
    private var pathAClaimSession: WebDavPathAClaimSession?
    private var pathBCreateSession: WebDavPathBCreateSession?
    private var pathBApproveSession: WebDavPathBApproveSession?
    private var pendingJoinStart: PendingJoinStart?
    /// 用户已选择“以对方为准”：等 approval 到达、准备保存新身份前再清空本机数据。
    private var pendingJoinClearsLocalData = false
    private var pendingStartupBinding: (account: WebDavAccount, identity: WebDavIdentity)?
    private var bootstrapTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var pathAShowPollTask: Task<Void, Never>?
    private var pathAClaimPollTask: Task<Void, Never>?
    private var pathBCreatePollTask: Task<Void, Never>?
    private var fallbackTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(
        label: "io.github.stophemo.woo-todo.network-monitor",
        qos: .utility
    )
    private var lastPathWasSatisfied: Bool?
    private var hasStarted = false

    private static let lastSuccessfulDefaultsKey = "webdav.last-successful-at"
    private static let legacyNoticeDefaultsKey = "webdav.legacy-notice-shown"
    private static let fallbackInterval: TimeInterval = 15 * 60

    init(
        repository: SQLiteTaskRepository,
        credentialsStore: any WebDavCredentialsStoring,
        defaults: UserDefaults = .standard,
        legacyNotice: String? = nil,
        pollInterval: TimeInterval = WebDavPairingProtocol.pollIntervalSeconds,
        clientFactory: @escaping ClientFactory = { account, identity in
            try WebDavClient(account: account, identity: identity)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.credentialsStore = credentialsStore
        self.defaults = defaults
        self.clientFactory = clientFactory
        self.pollInterval = pollInterval
        self.now = now
        let savedSuccess = defaults.object(
            forKey: Self.lastSuccessfulDefaultsKey
        ) as? Double
        let machine = SyncRuntimeStateMachine(
            isConfigured: false,
            lastSuccessfulAt: savedSuccess.map(Date.init(timeIntervalSince1970:))
        )
        self.runtimeMachine = machine
        self.runtimeSnapshot = machine.snapshot
        if let legacyNotice, !defaults.bool(forKey: Self.legacyNoticeDefaultsKey) {
            self.legacyNotice = legacyNotice
        }

        do {
            let loadedAccount = try credentialsStore.loadAccount()
            let loadedIdentity = try credentialsStore.loadIdentity()
            if let loadedAccount {
                account = loadedAccount
                endpointText = loadedAccount.endpoint.absoluteString
                username = loadedAccount.username
                appPassword = loadedAccount.appPassword
            }
            if let loadedIdentity {
                try activate(account: loadedAccount, identity: loadedIdentity)
                // 数据库绑定推迟到 start() 的异步任务：先取远端 Lamport 水位，
                // 避免升级或切回旧空间时本地快照被远端历史操作覆盖。
                if let loadedAccount {
                    pendingStartupBinding = (loadedAccount, loadedIdentity)
                }
                runtimeSnapshot = runtimeMachine.snapshot
            }
        } catch {
            actionErrorMessage = "WebDAV 配置暂时不可用：\(error.localizedDescription)"
            logger.error(
                "读取 WebDAV 配置失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let pathMonitor = NWPathMonitor()
        self.pathMonitor = pathMonitor
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkPathChanged(isSatisfied: isSatisfied)
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLocalPeriodsAndSync(.wake)
            }
        }

        fallbackTimer = Timer.scheduledTimer(
            withTimeInterval: Self.fallbackInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLocalPeriodsAndSync(.fallback)
            }
        }
        fallbackTimer?.tolerance = 60
        requestSync(.launch)
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        cancelAllPairingTasks()
        pendingJoinStart = nil
        joinPolicyPrompt = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathWasSatisfied = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        hasStarted = false
    }

    func acknowledgeLegacyNotice() {
        defaults.set(true, forKey: Self.legacyNoticeDefaultsKey)
        legacyNotice = nil
    }

    // MARK: - WebDAV 账号

    func testAndSaveAccount() async {
        guard !isSavingAccount else { return }
        actionErrorMessage = nil
        statusMessage = nil
        isSavingAccount = true
        defer { isSavingAccount = false }

        do {
            let account = try makeAccountFromFields()
            let newAccount = try await resolveStorageAccount(account)
            let client = try clientFactory(newAccount, nil)
            try await client.ensurePairingDirectory()
            _ = try await client.listPairingFileNames()
            try credentialsStore.saveAccount(newAccount)
            self.account = newAccount
            endpointText = newAccount.endpoint.absoluteString
            username = newAccount.username
            statusMessage = identity == nil
                ? "WebDAV 账号已保存。接下来可以建立同步空间，或输入另一台设备的配对码。"
                : "WebDAV 账号已更新。"
            if identity == nil,
               let recoveredIdentity = try? credentialsStore.loadIdentity() {
                // 账号文件曾损坏但身份仍完好时，重新保存账号后恢复同步。
                // 若本地数据库绑定的是旧空间，先取远端 Lamport 水位再替换绑定。
                let floor = try await remoteLamportFloor(
                    account: newAccount,
                    identity: recoveredIdentity
                )
                try applyBinding(recoveredIdentity, remoteLamportFloor: floor)
                try activate(account: newAccount, identity: recoveredIdentity)
                runtimeMachine.setConfigured(true)
                publishRuntimeState()
                statusMessage = "WebDAV 账号已保存，已恢复本机同步身份。"
            }
            if let storedIdentity = identity {
                try activate(account: newAccount, identity: storedIdentity)
                requestSync(.manual)
            }
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            logger.error(
                "保存 WebDAV 账号失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /**
     新账号自动落在 WooTodo 专属文件夹；已有空间沿用原目录，避免升级后断链。
     */
    private func resolveStorageAccount(_ account: WebDavAccount) async throws -> WebDavAccount {
        func accountAt(_ endpoint: URL) -> WebDavAccount {
            WebDavAccount(
                endpoint: endpoint,
                username: account.username,
                appPassword: account.appPassword
            )
        }
        let vaultId = identity?.vaultId
        let endpoint = try await WebDavStorageLayout.resolveEndpoint(
            account.endpoint,
            vaultId: vaultId,
            hasVaultAt: { candidate in
                guard let vaultId else { return false }
                return try await clientFactory(accountAt(candidate), nil)
                    .hasVaultDirectory(vaultId: vaultId)
            },
            hasPairingAt: { candidate in
                try await clientFactory(accountAt(candidate), nil).hasPairingDirectory()
            }
        )
        return accountAt(endpoint)
    }

    private func makeAccountFromFields() throws -> WebDavAccount {
        let trimmedEndpoint = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: trimmedEndpoint),
              WebDavEndpointPolicy.isAllowed(endpoint) else {
            throw WebDavError.invalidEndpoint
        }
        let account = WebDavAccount(
            endpoint: endpoint,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            appPassword: appPassword
        )
        try account.validate()
        return account
    }

    // MARK: - 建立/退出同步空间

    func createVault() async {
        guard !isCreatingVault, identity == nil, let account else { return }
        cancelPairingFlows(except: nil)
        actionErrorMessage = nil
        statusMessage = nil
        isCreatingVault = true
        defer { isCreatingVault = false }

        do {
            let newIdentity = WebDavIdentity(
                vaultId: "vault-" + Base64URL.encode(
                    try SecureRandom.bytes(count: 9)
                ),
                deviceId: UUID().uuidString.lowercased(),
                vaultKey: try SecureRandom.bytes(count: AES256GCM.keyByteCount)
            )
            try newIdentity.validate()
            let client = try clientFactory(account, newIdentity)
            try await client.ensureCollections()
            try credentialsStore.saveIdentity(newIdentity)
            do {
                try applyBinding(newIdentity)
            } catch {
                try? credentialsStore.deleteIdentity()
                throw error
            }
            try activate(account: account, identity: newIdentity)
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            statusMessage = "同步空间已建立，本地任务会保留并开始同步。现在可以用六位配对码添加新设备。"
            requestSync(.localChange)
        } catch {
            actionErrorMessage = friendlyMessage(for: error)
            logger.error(
                "建立 WebDAV 同步空间失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func exitSpace() async {
        guard let exitingIdentity = identity, !isExitingSpace else { return }
        actionErrorMessage = nil
        statusMessage = nil
        isExitingSpace = true
        defer { isExitingSpace = false }

        syncTask?.cancel()
        syncTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        pendingStartupBinding = nil
        runner = nil
        cancelAllPairingTasks()
        pendingJoinStart = nil
        joinPolicyPrompt = nil

        // 尽力删除自己的设备心跳；WebDAV 没有服务端设备表，失败不影响本地退出。
        if let account {
            await deleteDeviceHeartbeatBestEffort(
                account: account,
                identity: exitingIdentity
            )
        }

        var deleteError: Error?
        do {
            try credentialsStore.deleteIdentity()
        } catch {
            deleteError = error
        }
        try? repository.resetSyncBinding()
        identity = nil
        connection = nil
        devices = []
        devicesErrorMessage = nil
        pathAShowPhase = .idle
        pathAShowCode = nil
        pathAClaimPhase = .idle
        pathBCreatePhase = .idle
        pathBCreateCode = nil
        pathBApprovePhase = .idle
        runtimeMachine.setConfigured(false)
        publishRuntimeState()
        statusMessage = deleteError == nil
            ? "已退出同步空间。WebDAV 账号与本地任务已保留。"
            : "已停止同步并保留本地任务，但本机同步身份删除失败：\(deleteError!.localizedDescription)"
    }

    // MARK: - 加入其他空间的数据基准

    /// 加入方在 claim/join 前检查本机数据；需要用户确认时只设置提示，不写配对文件。
    private func makeJoinPolicyPrompt(
        peerDeviceName: String?,
        peerPlatform: DevicePlatform?
    ) throws -> JoinPolicyPrompt? {
        if let identity {
            guard let peerDeviceName, let peerPlatform else {
                throw WebDavPairingError.responseMismatch
            }
            return .chooseSpace(
                localVaultId: identity.vaultId,
                lastSyncedAt: runtimeSnapshot.lastSuccessfulAt,
                peerDeviceName: peerDeviceName,
                peerPlatform: peerPlatform
            )
        }
        let summary = try repository.joinLocalDataSummary()
        return summary.hasAnyData ? .clearLocalData(summary) : nil
    }

    /// 用户确认清空本机数据后继续加入；真正清空推迟到对方批准之后。
    func continueJoinClearingLocalTasks() async {
        guard case .clearLocalData = joinPolicyPrompt else { return }
        joinPolicyPrompt = nil
        pendingJoinClearsLocalData = true
        await startPendingJoin()
    }

    /// 用户选择以对方设备的数据为准：登记批准后清空本机数据，然后继续加入。
    func joinUsingPeerData() async {
        guard case .chooseSpace = joinPolicyPrompt else { return }
        joinPolicyPrompt = nil
        pendingJoinClearsLocalData = true
        await startPendingJoin()
    }

    /// 用户选择以本机设备为准：取消本次加入，不清空任何数据。
    func joinUsingLocalData() {
        guard case .chooseSpace = joinPolicyPrompt else { return }
        cancelPendingJoin(
            message: "已取消本次加入。请在本机点击「显示配对码」，再到对方设备输入本机配对码。"
        )
    }

    func cancelJoinPolicyPrompt() {
        cancelPendingJoin(message: "已取消加入，本机任务与同步身份均未改变。")
    }

    /// 清空本地任务、回收站、分类与同步状态；保留数据库文件、WebDAV 账号与显示偏好。
    /// 先删除并确认同步身份，成功后才停止同步并清空任务；任一步失败都不会保存新身份。
    /// 不触碰正在进行的配对会话，调用方在收到 approval、保存新身份前调用。
    func clearLocalDataForJoin() async throws {
        actionErrorMessage = nil
        statusMessage = nil

        // 身份删除失败时立即中止，任务、runner 与连接保持原样。
        do {
            try credentialsStore.deleteIdentity()
        } catch {
            throw JoinLocalDataClearError.identityDeletionFailed(
                error.localizedDescription
            )
        }
        let remainingIdentity: WebDavIdentity?
        do {
            remainingIdentity = try credentialsStore.loadIdentity()
        } catch {
            throw JoinLocalDataClearError.identityDeletionFailed(
                error.localizedDescription
            )
        }
        guard remainingIdentity == nil else {
            throw JoinLocalDataClearError.identityStillPresent
        }

        syncTask?.cancel()
        syncTask = nil
        bootstrapTask?.cancel()
        bootstrapTask = nil
        pendingStartupBinding = nil
        runner = nil

        if let account, let previousIdentity = identity {
            await deleteDeviceHeartbeatBestEffort(
                account: account,
                identity: previousIdentity
            )
        }

        do {
            try repository.clearAllLocalTasksAndSyncState()
        } catch {
            // 任务清空在事务中回滚，本地任务保留；身份已删除，必须进入未配对状态。
            enterUnpairedState()
            onRemoteChanges?()
            throw JoinLocalDataClearError.localDataClearFailed(
                error.localizedDescription
            )
        }

        enterUnpairedState()
        onRemoteChanges?()
    }

    /// 身份已删除或清空失败后，确保 UI 不再显示已配对，也不保留可用的 runner。
    private func enterUnpairedState() {
        runner = nil
        identity = nil
        connection = nil
        devices = []
        devicesErrorMessage = nil
        runtimeMachine.setConfigured(false)
        publishRuntimeState()
    }

    private func startPendingJoin() async {
        guard let action = pendingJoinStart else { return }
        pendingJoinStart = nil
        switch action {
        case .shortCodeClaim(let code):
            pathAClaimPhase = .claiming
            pathAClaimPollTask?.cancel()
            pathAClaimPollTask = Task { [weak self] in
                await self?.performShortCodeClaim(code: code)
            }
        case .createJoinRequest:
            await performCreateJoinRequest()
        }
    }

    private func cancelPendingJoin(message: String) {
        pendingJoinStart = nil
        pendingJoinClearsLocalData = false
        joinPolicyPrompt = nil
        if case .awaitingDecision = pathAClaimPhase {
            pathAClaimPhase = .idle
        }
        if case .awaitingDecision = pathBCreatePhase {
            pathBCreatePhase = .idle
        }
        actionErrorMessage = nil
        statusMessage = message
    }

    private func shortVaultId(_ vaultId: String) -> String {
        guard vaultId.count > 18 else { return vaultId }
        return "\(vaultId.prefix(8))…\(vaultId.suffix(8))"
    }

    // MARK: - 同步

    func requestSync(_ trigger: SyncTrigger = .manual) {
        if pendingStartupBinding != nil {
            // 启动时身份已加载但尚未取远端水位；重试时继续完成绑定。
            beginStartupBinding()
            return
        }
        guard runtimeMachine.request(trigger) else {
            publishRuntimeState()
            return
        }
        publishRuntimeState()
        syncTask = Task { [weak self] in
            await self?.runSyncLoop(startingWith: trigger)
        }
    }

    /// 启动时加载已有身份：先读取远端最大 Lamport 作为水位，再绑定数据库并开始同步。
    private func beginStartupBinding() {
        guard bootstrapTask == nil, let pending = pendingStartupBinding else { return }
        bootstrapTask = Task { [weak self] in
            guard let self else { return }
            do {
                let floor = try await self.remoteLamportFloor(
                    account: pending.account,
                    identity: pending.identity
                )
                // 等待期间用户可能已退出空间或停止同步。
                guard self.pendingStartupBinding != nil else {
                    self.bootstrapTask = nil
                    return
                }
                try self.applyBinding(
                    pending.identity,
                    remoteLamportFloor: floor
                )
                self.pendingStartupBinding = nil
                self.runtimeMachine.setConfigured(true)
                self.publishRuntimeState()
                self.actionErrorMessage = nil
                await self.writeOwnDeviceHeartbeat()
                self.requestSync(.launch)
            } catch {
                guard self.pendingStartupBinding != nil, !Task.isCancelled else {
                    self.bootstrapTask = nil
                    return
                }
                self.actionErrorMessage = "同步暂时不可用，将在网络恢复后重试：\(self.friendlyMessage(for: error))"
                self.publishRuntimeState()
                self.logger.error(
                    "启动时读取远端 Lamport 水位失败：\(error.localizedDescription, privacy: .public)"
                )
            }
            self.bootstrapTask = nil
        }
    }

    private func runSyncLoop(startingWith initialTrigger: SyncTrigger) async {
        var trigger: SyncTrigger? = initialTrigger
        while let activeTrigger = trigger, !Task.isCancelled {
            guard let runner else {
                trigger = runtimeMachine.fail(message: "WebDAV 同步尚未配置")
                publishRuntimeState()
                continue
            }
            logger.debug("开始 WebDAV 同步，触发原因：\(activeTrigger.rawValue, privacy: .public)")
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
                await writeOwnDeviceHeartbeat()
                if summary.pulled > 0 {
                    onRemoteChanges?()
                }
            } catch is CancellationError {
                trigger = runtimeMachine.fail(message: "同步已取消")
                publishRuntimeState()
                break
            } catch {
                trigger = runtimeMachine.fail(message: friendlyMessage(for: error))
                publishRuntimeState()
                logger.notice(
                    "WebDAV 后台同步暂时失败：\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        syncTask = nil
    }

    // MARK: - 设备列表

    func refreshDevices() async {
        guard let account, let identity, !isRefreshingDevices else { return }
        let currentDeviceId = identity.deviceId
        isRefreshingDevices = true
        devicesErrorMessage = nil
        defer { isRefreshingDevices = false }

        do {
            let client = try clientFactory(account, identity)
            let remoteDevices = try await client.listDevices()
            // 等待期间用户可能已切换或退出空间，旧空间的结果不再展示。
            guard self.identity?.deviceId == currentDeviceId else { return }
            devices = remoteDevices.map { device in
                SyncDeviceSummary(
                    id: device.deviceId,
                    name: device.name,
                    platform: device.platform,
                    lastSeenAt: device.lastSeenAt,
                    appVersion: device.appVersion,
                    isCurrent: device.deviceId == currentDeviceId
                )
            }
        } catch is CancellationError {
            // 页面关闭导致的取消不显示错误。
        } catch {
            devicesErrorMessage = friendlyMessage(for: error)
            logger.notice(
                "读取 WebDAV 设备列表失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 退出时最多等待几秒；服务不可达不能阻塞本地退出。
    private func deleteDeviceHeartbeatBestEffort(
        account: WebDavAccount,
        identity: WebDavIdentity
    ) async {
        guard let client = try? clientFactory(account, identity) else { return }
        let logger = self.logger
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await client.deleteOwnDeviceHeartbeat()
                } catch {
                    logger.notice(
                        "删除 WebDAV 设备心跳失败：\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// 心跳是尽力而为的展示信息：失败只记录，不影响同步与本地操作。
    private func writeOwnDeviceHeartbeat() async {
        guard let account, let identity else { return }
        do {
            let client = try clientFactory(account, identity)
            let heartbeat = try WebDavDeviceHeartbeat(
                name: Self.localDeviceName,
                platform: .macos,
                lastSeenAt: Self.timestampMilliseconds(),
                appVersion: Self.appVersion
            )
            try await client.putDeviceHeartbeat(heartbeat)
        } catch is CancellationError {
        } catch {
            logger.notice(
                "写入 WebDAV 设备心跳失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Path A：已有设备显示码

    func createPairing() async {
        guard identity != nil, account != nil, pathAShowPhase.canStart else { return }
        cancelPairingFlows(except: .pathAShow)
        actionErrorMessage = nil
        statusMessage = nil
        pathAShowPhase = .creating

        do {
            guard let account, let identity else {
                throw WebDavError.invalidCredentials
            }
            let client = try clientFactory(account, identity)
            let session = try await WebDavPathAShowSession.start(
                transport: client,
                identity: identity,
                deviceName: Self.localDeviceName
            )
            pathAShowSession = session
            pathAShowCode = session.code
            pathAShowPhase = .awaitingClaim(code: session.code, deadline: session.deadline)
            startPathAShowPolling()
        } catch {
            pathAShowPhase = .failed(friendlyMessage(for: error))
            pathAShowSession = nil
            pathAShowCode = nil
            logger.error(
                "创建 WebDAV 配对码失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func confirmPairing() async {
        guard case let .awaitingVerification(deviceName, _, _, _) = pathAShowPhase,
              let session = pathAShowSession else { return }
        actionErrorMessage = nil
        do {
            try await session.approve()
            pathAShowPhase = .confirmed
            pathAShowCode = nil
            pathAShowSession = nil
            statusMessage = "已批准「\(deviceName)」加入同步空间。"
            requestSync(.manual)
        } catch {
            pathAShowPhase = .failed(friendlyMessage(for: error))
            logger.error(
                "批准 WebDAV 新设备失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func resetPairing() {
        pathAShowPollTask?.cancel()
        pathAShowPollTask = nil
        let session = pathAShowSession
        pathAShowSession = nil
        pathAShowCode = nil
        pathAShowPhase = .idle
        actionErrorMessage = nil
        if let session {
            Task { await session.cancel() }
        }
    }

    private func startPathAShowPolling() {
        pathAShowPollTask?.cancel()
        pathAShowPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let session = self.pathAShowSession else { return }
                do {
                    let state = try await session.poll()
                    switch state {
                    case .waiting:
                        break
                    case let .claimed(deviceId, deviceName, platform, code):
                        _ = deviceId
                        self.pathAShowPhase = .awaitingVerification(
                            deviceName: deviceName,
                            platform: platform,
                            code: code,
                            deadline: session.deadline
                        )
                        self.pathAShowCode = nil
                        self.actionErrorMessage = nil
                        return
                    case .approved:
                        return
                    case .expired:
                        self.pathAShowPhase = .expired
                        self.pathAShowCode = nil
                        self.pathAShowSession = nil
                        return
                    }
                    self.actionErrorMessage = nil
                } catch {
                    if Date() >= session.deadline {
                        self.pathAShowPhase = .expired
                        self.pathAShowCode = nil
                        self.pathAShowSession = nil
                        return
                    }
                    self.actionErrorMessage = "暂时无法读取配对状态，将在配对码有效期内自动重试。"
                }
                do {
                    try await Task.sleep(for: .seconds(self.pollInterval))
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Path A：新设备输入码

    func claimByShortCode(_ rawCode: String) {
        guard account != nil else { return }
        let code = rawCode.filter(\.isNumber)
        guard code.count == 6 else {
            pathAClaimPhase = .failed("请输入另一台设备显示的 6 位数字配对码")
            return
        }
        pendingJoinClearsLocalData = false
        cancelPairingFlows(except: .pathAClaim)
        actionErrorMessage = nil
        statusMessage = nil
        joinPolicyPrompt = nil
        pendingJoinStart = nil
        pathAClaimPhase = .claiming
        pathAClaimPollTask?.cancel()
        pathAClaimPollTask = Task { [weak self] in
            await self?.beginShortCodeClaim(code: code)
        }
    }

    /// 先只读取 offer 判断数据基准，用户确认后才写入 claim。
    private func beginShortCodeClaim(code: String) async {
        do {
            guard let account else {
                throw WebDavError.invalidCredentials
            }
            let client = try clientFactory(account, nil)
            let preview = try await WebDavPathAClaimSession.previewOffer(
                transport: client,
                code: code
            )
            if let prompt = try makeJoinPolicyPrompt(
                peerDeviceName: preview.deviceName,
                peerPlatform: preview.platform
            ) {
                pendingJoinStart = .shortCodeClaim(code: code)
                joinPolicyPrompt = prompt
                pathAClaimPhase = .awaitingDecision
                return
            }
            await performShortCodeClaim(code: code)
        } catch is CancellationError {
            // 用户主动取消。
        } catch {
            guard !Task.isCancelled else { return }
            pathAClaimPhase = .failed(friendlyMessage(for: error))
            pathAClaimSession = nil
            logger.error(
                "六位码加入 WebDAV 空间失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func performShortCodeClaim(code: String) async {
        pathAClaimPhase = .claiming
        do {
            guard let account else {
                throw WebDavError.invalidCredentials
            }
            let client = try clientFactory(account, nil)
            let session = try await WebDavPathAClaimSession.start(
                transport: client,
                code: code,
                deviceName: Self.localDeviceName
            )
            pathAClaimSession = session
            pathAClaimPhase = .awaitingApproval(
                code: session.verificationCode,
                deadline: session.deadline
            )

            while !Task.isCancelled {
                do {
                    let state = try await session.poll()
                    switch state {
                    case .waiting:
                        actionErrorMessage = nil
                    case let .approved(pendingIdentity):
                        // approval 到达后自动保存身份，不再要求本机确认。
                        await completeShortCodeClaim(
                            session: session,
                            identity: pendingIdentity
                        )
                        return
                    case .expired:
                        pendingJoinClearsLocalData = false
                        pathAClaimPhase = .failed("配对码已过期，请在另一台设备重新生成。")
                        pathAClaimSession = nil
                        return
                    }
                } catch WebDavPairingError.responseMismatch {
                    pendingJoinClearsLocalData = false
                    pathAClaimPhase = .failed(
                        "配对文件与当前会话不一致，已停止配对。请重新生成配对码。"
                    )
                    pathAClaimSession = nil
                    return
                } catch {
                    // 429/5xx/网络错误在配对码有效期内继续重试。
                    if Date() >= session.deadline {
                        pendingJoinClearsLocalData = false
                        pathAClaimPhase = .failed("配对码已过期，请在另一台设备重新生成。")
                        pathAClaimSession = nil
                        return
                    }
                    actionErrorMessage = "暂时无法读取配对状态，将在配对码有效期内自动重试。"
                }
                do {
                    try await Task.sleep(for: .seconds(pollInterval))
                } catch {
                    return
                }
            }
        } catch is CancellationError {
            // 用户主动取消。
        } catch {
            guard !Task.isCancelled else { return }
            pendingJoinClearsLocalData = false
            pathAClaimPhase = .failed(friendlyMessage(for: error))
            pathAClaimSession = nil
            logger.error(
                "六位码加入 WebDAV 空间失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// approval 到达后自动完成加入：先取远端 Lamport 水位，再保存身份并绑定。
    /// 用户选择了“以对方为准”时，在本机身份被替换前清空旧内容；清空失败则不保存新身份。
    private func completeShortCodeClaim(
        session: WebDavPathAClaimSession,
        identity pendingIdentity: WebDavIdentity
    ) async {
        guard let account else {
            pendingJoinClearsLocalData = false
            pathAClaimPhase = .failed(friendlyMessage(for: WebDavError.invalidCredentials))
            pathAClaimSession = nil
            return
        }
        actionErrorMessage = nil
        do {
            let floor = try await remoteLamportFloor(
                account: account,
                identity: pendingIdentity
            )
            let newIdentity = try await session.confirm()
            if pendingJoinClearsLocalData {
                pendingJoinClearsLocalData = false
                try await clearLocalDataForJoin()
            }
            try credentialsStore.saveIdentity(newIdentity)
            do {
                try applyBinding(newIdentity, remoteLamportFloor: floor)
            } catch {
                try? credentialsStore.deleteIdentity()
                throw error
            }
            try activate(account: account, identity: newIdentity)
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            pathAClaimPhase = .confirmed
            pathAClaimSession = nil
            statusMessage = "已加入同步空间 \(shortVaultId(newIdentity.vaultId))，正在执行首次同步；如果与对方显示的核对码不一致，请立即退出空间。"
            requestSync(.manual)
        } catch is CancellationError {
            // 用户主动取消。
        } catch {
            pendingJoinClearsLocalData = false
            pathAClaimPhase = .failed(friendlyMessage(for: error))
            pathAClaimSession = nil
            logger.error(
                "自动保存加入身份失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func cancelShortCodeClaim() {
        pathAClaimPollTask?.cancel()
        pathAClaimPollTask = nil
        pendingJoinClearsLocalData = false
        let session = pathAClaimSession
        pathAClaimSession = nil
        pathAClaimPhase = .idle
        actionErrorMessage = nil
        if case .shortCodeClaim? = pendingJoinStart {
            pendingJoinStart = nil
            joinPolicyPrompt = nil
        }
        if let session {
            Task { await session.cancel() }
        }
    }

    // MARK: - Path B：新设备显示码

    func createJoinRequest() async {
        guard identity == nil, account != nil, pathBCreatePhase.canStart else { return }
        pendingJoinClearsLocalData = false
        cancelPairingFlows(except: .pathBCreate)
        actionErrorMessage = nil
        statusMessage = nil
        joinPolicyPrompt = nil
        pendingJoinStart = nil
        do {
            if let prompt = try makeJoinPolicyPrompt(
                peerDeviceName: nil,
                peerPlatform: nil
            ) {
                pendingJoinStart = .createJoinRequest
                joinPolicyPrompt = prompt
                pathBCreatePhase = .awaitingDecision
                return
            }
        } catch {
            pathBCreatePhase = .failed(friendlyMessage(for: error))
            return
        }
        await performCreateJoinRequest()
    }

    private func performCreateJoinRequest() async {
        pathBCreatePhase = .creating
        do {
            guard let account else {
                throw WebDavError.invalidCredentials
            }
            let client = try clientFactory(account, nil)
            let session = try await WebDavPathBCreateSession.start(
                transport: client,
                deviceName: Self.localDeviceName
            )
            pathBCreateSession = session
            pathBCreateCode = session.code
            pathBCreatePhase = .waiting(code: session.code, deadline: session.deadline)
            startPathBCreatePolling()
        } catch {
            pendingJoinClearsLocalData = false
            pathBCreatePhase = .failed(friendlyMessage(for: error))
            pathBCreateSession = nil
            pathBCreateCode = nil
            logger.error(
                "创建 WebDAV 加入码失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func startPathBCreatePolling() {
        pathBCreatePollTask?.cancel()
        pathBCreatePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let session = self.pathBCreateSession else { return }
                do {
                    let state = try await session.poll(now: self.now())
                    switch state {
                    case .waiting:
                        break
                    case let .verification(deviceName, code):
                        self.pathBCreatePhase = .awaitingApproval(
                            verificationCode: code,
                            deviceName: deviceName,
                            deadline: session.deadline
                        )
                        self.actionErrorMessage = nil
                    case let .approved(pendingIdentity):
                        // approval 到达后自动保存身份，不再要求本机确认。
                        await self.completeJoinCreation(
                            session: session,
                            identity: pendingIdentity
                        )
                        return
                    case .expired:
                        self.pendingJoinClearsLocalData = false
                        self.pathBCreatePhase = .expired
                        self.pathBCreateCode = nil
                        self.pathBCreateSession = nil
                        return
                    }
                } catch WebDavPairingError.responseMismatch {
                    self.pendingJoinClearsLocalData = false
                    self.pathBCreatePhase = .failed(
                        "配对文件与当前会话不一致，已停止配对。请重新生成配对码。"
                    )
                    self.pathBCreateCode = nil
                    self.pathBCreateSession = nil
                    return
                } catch {
                    if self.now() >= session.deadline {
                        self.pendingJoinClearsLocalData = false
                        self.pathBCreatePhase = .expired
                        self.pathBCreateCode = nil
                        self.pathBCreateSession = nil
                        return
                    }
                    self.actionErrorMessage = "暂时无法读取配对状态，将在配对码有效期内自动重试。"
                }
                do {
                    try await Task.sleep(for: .seconds(self.pollInterval))
                } catch {
                    return
                }
            }
        }
    }

    /// approval 到达后自动完成加入：先取远端 Lamport 水位，再保存身份并绑定。
    /// 用户选择了“以对方为准”时，在本机身份被替换前清空旧内容；清空失败则不保存新身份。
    private func completeJoinCreation(
        session: WebDavPathBCreateSession,
        identity pendingIdentity: WebDavIdentity
    ) async {
        guard let account else {
            pendingJoinClearsLocalData = false
            pathBCreatePhase = .failed(friendlyMessage(for: WebDavError.invalidCredentials))
            pathBCreateSession = nil
            return
        }
        actionErrorMessage = nil
        do {
            let floor = try await remoteLamportFloor(
                account: account,
                identity: pendingIdentity
            )
            let newIdentity = try await session.confirm(now: now())
            if pendingJoinClearsLocalData {
                pendingJoinClearsLocalData = false
                try await clearLocalDataForJoin()
            }
            try credentialsStore.saveIdentity(newIdentity)
            do {
                try applyBinding(newIdentity, remoteLamportFloor: floor)
            } catch {
                try? credentialsStore.deleteIdentity()
                throw error
            }
            try activate(account: account, identity: newIdentity)
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            pathBCreatePhase = .approved
            pathBCreateCode = nil
            pathBCreateSession = nil
            statusMessage = "已加入同步空间 \(shortVaultId(newIdentity.vaultId))，正在执行首次同步；如果与对方显示的核对码不一致，请立即退出空间。"
            requestSync(.manual)
        } catch is CancellationError {
            // 用户主动取消。
        } catch {
            pendingJoinClearsLocalData = false
            pathBCreatePhase = .failed(friendlyMessage(for: error))
            pathBCreateSession = nil
            logger.error(
                "自动保存加入身份失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func cancelJoinCreation() async {
        pathBCreatePollTask?.cancel()
        pathBCreatePollTask = nil
        pendingJoinClearsLocalData = false
        let session = pathBCreateSession
        pathBCreateSession = nil
        pathBCreateCode = nil
        pathBCreatePhase = .canceled
        if case .createJoinRequest? = pendingJoinStart {
            pendingJoinStart = nil
            joinPolicyPrompt = nil
        }
        if let session {
            await session.cancel()
        }
        statusMessage = "配对已取消。"
    }

    func resetJoinCreation() {
        pathBCreatePollTask?.cancel()
        pathBCreatePollTask = nil
        pendingJoinClearsLocalData = false
        pathBCreateSession = nil
        pathBCreateCode = nil
        pathBCreatePhase = .idle
        actionErrorMessage = nil
        if case .createJoinRequest? = pendingJoinStart {
            pendingJoinStart = nil
            joinPolicyPrompt = nil
        }
    }

    // MARK: - Path B：已有设备批准

    func resolveJoinCode(_ rawCode: String) async {
        guard identity != nil, account != nil, pathBApprovePhase.canResolve else { return }
        let code = rawCode.filter(\.isNumber)
        guard code.count == 6 else {
            pathBApprovePhase = .failed("请输入新设备显示的 6 位数字配对码")
            return
        }
        cancelPairingFlows(except: .pathBApprove)
        actionErrorMessage = nil
        statusMessage = nil
        pathBApprovePhase = .resolving

        do {
            guard let account, let identity else {
                throw WebDavError.invalidCredentials
            }
            let client = try clientFactory(account, identity)
            let session = try await WebDavPathBApproveSession.start(
                transport: client,
                code: code,
                vaultId: identity.vaultId,
                vaultKey: identity.vaultKey,
                approverDeviceId: identity.deviceId,
                approverName: Self.localDeviceName
            )
            pathBApproveSession = session
            pathBApprovePhase = .awaitingConfirmation(
                deviceName: session.deviceName,
                platform: session.platform,
                code: session.verificationCode,
                deadline: session.deadline
            )
        } catch {
            pathBApprovePhase = .failed(friendlyMessage(for: error))
            pathBApproveSession = nil
            logger.error(
                "解析新设备配对码失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func approveJoin() async {
        guard case let .awaitingConfirmation(deviceName, _, _, _) = pathBApprovePhase,
              let session = pathBApproveSession else { return }
        actionErrorMessage = nil
        pathBApprovePhase = .approving
        do {
            try await session.approve()
            pathBApproveSession = nil
            pathBApprovePhase = .done
            statusMessage = "已批准「\(deviceName)」加入同步空间。"
            requestSync(.manual)
        } catch {
            pathBApprovePhase = .failed(friendlyMessage(for: error))
            pathBApproveSession = nil
            logger.error(
                "批准新设备加入 WebDAV 空间失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func cancelJoinApproval() {
        let session = pathBApproveSession
        pathBApproveSession = nil
        pathBApprovePhase = .idle
        actionErrorMessage = nil
        statusMessage = "已取消批准，配对码将在 5 分钟后失效。"
        if let session {
            Task { await session.cancel() }
        }
    }

    func resetJoinApprover() {
        pathBApproveSession = nil
        pathBApprovePhase = .idle
        actionErrorMessage = nil
    }

    // MARK: - 装配

    /// 加入或切回已有空间前，先取远端最大 Lamport 作为本地水位，
    /// 避免本地快照的版本号低于远端历史操作而被静默覆盖。仅新建空空间时水位为 0。
    func remoteLamportFloor(
        account: WebDavAccount,
        identity: WebDavIdentity
    ) async throws -> Int64 {
        let client = try clientFactory(account, identity)
        return try await client.maximumLamport()
    }

    func applyBinding(
        _ identity: WebDavIdentity,
        remoteLamportFloor: Int64 = 0
    ) throws {
        let configuration = SQLiteSyncConfiguration(
            vaultId: identity.vaultId,
            deviceId: identity.deviceId,
            vaultKey: identity.vaultKey
        )
        do {
            try repository.configureSync(configuration)
        } catch let error as SQLiteRepositoryError {
            guard case .syncIdentityMismatch = error else { throw error }
            // 旧 Worker/LAN 或旧 WebDAV 空间留下的 SQLite 绑定允许被新的 WebDAV 身份替换；
            // 本地任务保留并作为新空间的本地快照从远端水位之后重新入队。
            try repository.replaceSyncBinding(
                with: configuration,
                remoteLamportFloor: remoteLamportFloor
            )
        }
    }

    private func activate(account: WebDavAccount?, identity: WebDavIdentity) throws {
        guard let account else {
            throw WebDavError.invalidCredentials
        }
        let client = try clientFactory(account, identity)
        self.account = account
        self.identity = identity
        self.endpointText = account.endpoint.absoluteString
        self.username = account.username
        self.appPassword = account.appPassword
        self.runner = WebDavSyncRunner(
            client: client,
            outbox: repository,
            local: repository
        )
        self.connection = SyncConnectionSummary(
            endpoint: account.endpoint,
            vaultId: identity.vaultId,
            deviceId: identity.deviceId,
            deviceName: Self.localDeviceName
        )
    }

    private func cancelAllPairingTasks() {
        pathAShowPollTask?.cancel()
        pathAShowPollTask = nil
        pathAClaimPollTask?.cancel()
        pathAClaimPollTask = nil
        pathBCreatePollTask?.cancel()
        pathBCreatePollTask = nil
        if let session = pathAShowSession {
            Task { await session.cancel() }
        }
        if let session = pathAClaimSession {
            Task { await session.cancel() }
        }
        if let session = pathBCreateSession {
            Task { await session.cancel() }
        }
        if let session = pathBApproveSession {
            Task { await session.cancel() }
        }
        pathAShowSession = nil
        pathAClaimSession = nil
        pathBCreateSession = nil
        pathBApproveSession = nil
        pendingJoinStart = nil
        pendingJoinClearsLocalData = false
        joinPolicyPrompt = nil
    }

    private enum PendingJoinStart {
        case shortCodeClaim(code: String)
        case createJoinRequest
    }

    private enum PairingFlow {
        case pathAShow
        case pathAClaim
        case pathBCreate
        case pathBApprove
    }

    private func cancelPairingFlows(except exception: PairingFlow?) {
        if exception != .pathAShow {
            pathAShowPollTask?.cancel()
            pathAShowPollTask = nil
            let session = pathAShowSession
            pathAShowSession = nil
            pathAShowCode = nil
            pathAShowPhase = .idle
            if let session {
                Task { await session.cancel() }
            }
        }
        if exception != .pathAClaim {
            pathAClaimPollTask?.cancel()
            pathAClaimPollTask = nil
            pendingJoinClearsLocalData = false
            let session = pathAClaimSession
            pathAClaimSession = nil
            pathAClaimPhase = .idle
            if case .shortCodeClaim? = pendingJoinStart {
                pendingJoinStart = nil
                joinPolicyPrompt = nil
            }
            if let session {
                Task { await session.cancel() }
            }
        }
        if exception != .pathBCreate {
            pathBCreatePollTask?.cancel()
            pathBCreatePollTask = nil
            pendingJoinClearsLocalData = false
            let session = pathBCreateSession
            pathBCreateSession = nil
            pathBCreateCode = nil
            pathBCreatePhase = .idle
            if case .createJoinRequest? = pendingJoinStart {
                pendingJoinStart = nil
                joinPolicyPrompt = nil
            }
            if let session {
                Task { await session.cancel() }
            }
        }
        if exception != .pathBApprove {
            let session = pathBApproveSession
            pathBApproveSession = nil
            pathBApprovePhase = .idle
            if let session {
                Task { await session.cancel() }
            }
        }
    }

    // MARK: - 网络与状态

    private func networkPathChanged(isSatisfied: Bool) {
        guard hasStarted else { return }
        defer { lastPathWasSatisfied = isSatisfied }
        let isRestored = lastPathWasSatisfied == false
            || (lastPathWasSatisfied == nil && runtimeSnapshot.lastErrorMessage != nil)
        if isSatisfied && isRestored {
            requestSync(.networkRestored)
        }
    }

    private func refreshLocalPeriodsAndSync(_ trigger: SyncTrigger) {
        onLifecycleRefresh?()
        requestSync(trigger)
    }

    private func publishRuntimeState() {
        runtimeSnapshot = runtimeMachine.snapshot
    }

    // MARK: - 提示文案

    private func friendlyMessage(for error: Error) -> String {
        if let pairingError = error as? WebDavPairingError {
            return pairingError.localizedDescription
        }
        if let webDavError = error as? WebDavError {
            switch webDavError {
            case .invalidEndpoint:
                return "WebDAV 地址必须是无账号、查询参数或片段的 HTTPS 地址。"
            case .invalidCredentials:
                return "WebDAV 账号或同步身份无效。请检查用户名与应用密码。"
            case .http(401):
                return "WebDAV 用户名或应用密码不正确，也可能是供应商要求使用应用专用密码。"
            case .http(403):
                return "WebDAV 账号无权访问该目录。请检查目录权限或应用密码范围。"
            case .http(404):
                return "WebDAV 地址或目录不存在。请填写供应商提供的 WebDAV 根目录。"
            case .http(405):
                return "该地址没有启用 WebDAV。请确认填写的是 WebDAV 根目录，而不是网页首页。"
            case .http(429):
                return "WebDAV 请求过于频繁，请稍后再试。"
            case .http(let status) where status >= 500:
                return "WebDAV 服务暂时异常（HTTP \(status)），本地任务不受影响，请稍后重试。"
            case .http(let status):
                return "WebDAV 服务返回 HTTP \(status)。"
            case .transport(let message):
                return "无法连接 WebDAV 服务：\(message)"
            case .objectConflict:
                return "配对文件发生冲突，请重新生成配对码。"
            case .encoding(let message):
                return "无法编码 WebDAV 同步数据：\(message)"
            case .invalidResponse:
                return "WebDAV 服务返回了无效响应。"
            case .malformedObject(let message):
                return "WebDAV 同步数据无效：\(message)"
            }
        }
        return error.localizedDescription
    }

    private static var localDeviceName: String {
        let raw = Host.current().localizedName
            ?? ProcessInfo.processInfo.hostName
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty ? "Mac" : cleaned
        return String(value.prefix(64))
    }

    private static var appVersion: String {
        let raw = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned.isEmpty ? "0.0.0" : cleaned
        return String(value.prefix(32))
    }

    private static func timestampMilliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

private extension PathAShowPhase {
    var canStart: Bool {
        switch self {
        case .idle, .confirmed, .expired, .failed: true
        default: false
        }
    }
}

private extension PathBCreatePhase {
    var canStart: Bool {
        switch self {
        case .idle, .approved, .expired, .canceled, .failed: true
        default: false
        }
    }
}

private extension PathBApprovePhase {
    var canResolve: Bool {
        switch self {
        case .idle, .done, .failed: true
        default: false
        }
    }
}
