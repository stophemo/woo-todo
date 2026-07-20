import AppKit
import Combine
import Foundation
import Network
import OSLog
import UniformTypeIdentifiers
import WooTodoStorage
import WooTodoSync

struct SyncConnectionSummary: Equatable {
    let endpoint: URL
    let vaultId: String
    let deviceId: String
}

private enum SyncSetupError: LocalizedError {
    case credentialsAlreadyStored
    case credentialsRollbackFailed(original: String, rollback: String)
    case invalidEndpoint
    case missingInviteCode
    case invalidInviteCodeFormat
    case currentDeviceOnlyEndpoint
    case includesAPIVersion

    var errorDescription: String? {
        switch self {
        case .credentialsAlreadyStored:
            "Keychain 已存在同步身份，请重新启动应用后再操作"
        case .credentialsRollbackFailed(let original, let rollback):
            "同步绑定失败（\(original)），且无法恢复原 Keychain 凭据（\(rollback)）"
        case .invalidEndpoint:
            "请输入已部署同步服务的 HTTPS 根地址，例如 https://你的-worker.workers.dev"
        case .missingInviteCode:
            "请输入部署同步服务时设置的创建邀请码"
        case .invalidInviteCodeFormat:
            "创建邀请码须为 16–256 个字符，且只能包含无空格的可打印 ASCII 字符"
        case .currentDeviceOnlyEndpoint:
            "127.0.0.1/localhost 只代表当前 Mac，手机会把它理解为手机自己。请改用 Mac 与 Android 都能访问的 HTTPS Worker 地址。"
        case .includesAPIVersion:
            "请填写同步服务根地址，不要在末尾添加 /v1；应用会自动拼接 API 路径。"
        }
    }
}

private enum SyncUserAction: Equatable {
    case createVault
    case pairDevice
    case loadDevices
    case revokeDevice
    case synchronize

    var label: String {
        switch self {
        case .createVault: "创建同步空间"
        case .pairDevice: "设备配对"
        case .loadDevices: "获取设备列表"
        case .revokeDevice: "撤销设备"
        case .synchronize: "同步"
        }
    }
}

private enum BackupUIError: LocalizedError {
    case passphraseMismatch
    case destinationNotEmpty
    case credentialsAlreadyStored
    case syncRecoveryFailed(String)
    case relayContainsSyncIdentity

    var errorDescription: String? {
        switch self {
        case .passphraseMismatch: "两次输入的备份口令不一致"
        case .destinationNotEmpty: "导入只允许在尚无任务、尚未连接同步空间的全新安装中进行"
        case .credentialsAlreadyStored: "Keychain 已有同步身份，不能覆盖导入"
        case .syncRecoveryFailed(let message):
            "任务已恢复到本地，但同步身份恢复失败：\(message)"
        case .relayContainsSyncIdentity:
            "离线接力包不能包含同步身份，请重新导出且不要勾选“包含同步身份”"
        }
    }
}

private enum BackupExportPurpose {
    case offlineRelay
    case recovery(includeSyncIdentity: Bool)
}

@MainActor
final class SyncSettingsStore: ObservableObject {
    @Published var endpointText: String
    @Published private(set) var connection: SyncConnectionSummary?
    @Published private(set) var runtimeSnapshot: SyncRuntimeSnapshot
    @Published private(set) var lastRunSummary: SyncRunSummary?
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var isCreatingVault = false
    @Published private(set) var isLoadingDevices = false
    @Published private(set) var pairingPhase: InitiatorPairingPhase = .idle
    @Published private(set) var pairingQRCodePayload: String?
    @Published private(set) var actionErrorMessage: String?
    @Published private(set) var isBackupBusy = false
    @Published private(set) var backupStatusMessage: String?

    var endpointSetupAssessment: SyncEndpointSetupAssessment {
        SyncEndpointSetupPolicy.assess(endpointText)
    }

    var canCreateVault: Bool {
        if case .ready = endpointSetupAssessment { return true }
        return false
    }

    var onRemoteChanges: (() -> Void)?
    var onLifecycleRefresh: (() -> Void)?

    private let logger = Logger(
        subsystem: "io.github.stophemo.woo-todo",
        category: "同步"
    )
    private let repository: SQLiteTaskRepository
    private let credentialsStore: any SyncCredentialsStoring
    private var credentials: SyncCredentials?
    private var apiClient: SyncAPIClient?
    private var coordinator: SyncCoordinator?
    private var runtimeMachine: SyncRuntimeStateMachine
    private var pairingMachine = InitiatorPairingStateMachine()
    private var pairingContext: PairingContext?
    private var syncTask: Task<Void, Never>?
    private var pairingPollTask: Task<Void, Never>?
    private var pairingPollGeneration: UUID?
    private var fallbackTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(
        label: "io.github.stophemo.woo-todo.network-monitor",
        qos: .utility
    )
    private var lastPathWasSatisfied: Bool?
    private var hasStarted = false

    private static let endpointDefaultsKey = "sync.endpoint"
    private static let lastSuccessfulSyncDefaultsKey = "sync.last-successful-at"
    private static let fallbackInterval: TimeInterval = 15 * 60

    init(
        repository: SQLiteTaskRepository,
        credentialsStore: any SyncCredentialsStoring,
        credentials: SyncCredentials?
    ) throws {
        self.repository = repository
        self.credentialsStore = credentialsStore
        self.credentials = credentials
        let savedSuccessTimestamp = UserDefaults.standard.object(
            forKey: Self.lastSuccessfulSyncDefaultsKey
        ) as? Double
        let initialRuntimeMachine = SyncRuntimeStateMachine(
            isConfigured: credentials != nil,
            lastSuccessfulAt: credentials == nil
                ? nil
                : savedSuccessTimestamp.map { Date(timeIntervalSince1970: $0) }
        )
        self.runtimeMachine = initialRuntimeMachine
        self.runtimeSnapshot = initialRuntimeMachine.snapshot
        self.endpointText = credentials?.endpoint.absoluteString
            ?? UserDefaults.standard.string(forKey: Self.endpointDefaultsKey)
            ?? "https://"
        if let credentials {
            try activate(credentials)
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
        pairingPollTask?.cancel()
        pairingPollTask = nil
        pairingPollGeneration = nil
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

    func createVault(inviteCode rawInviteCode: String) async {
        guard !isCreatingVault, connection == nil else { return }
        actionErrorMessage = nil
        isCreatingVault = true
        defer { isCreatingVault = false }

        do {
            let inviteCode = try validatedInviteCode(rawInviteCode)
            let previousCredentials = try credentialsStore.load()
            guard previousCredentials == nil else {
                throw SyncSetupError.credentialsAlreadyStored
            }
            let endpoint = try validatedEndpoint()
            let client = try SyncAPIClient(endpoint: endpoint)
            let vaultKey = try SecureRandom.bytes(count: AES256GCM.keyByteCount)
            let created = try await client.createVault(
                CreateVaultRequest(device: DeviceRegistration(
                    name: Self.localDeviceName,
                    platform: .macos
                )),
                inviteCode: inviteCode
            )
            let newCredentials = SyncCredentials(
                endpoint: endpoint,
                vaultId: created.vaultId,
                deviceId: created.device.id,
                deviceToken: created.device.token,
                vaultKey: vaultKey
            )
            try newCredentials.validate()
            try repository.validateSyncBinding(
                vaultId: newCredentials.vaultId,
                deviceId: newCredentials.deviceId
            )
            try credentialsStore.save(newCredentials)
            do {
                try repository.configureSync(Self.sqliteConfiguration(for: newCredentials))
            } catch {
                // 数据库绑定失败时精确恢复原 Keychain 状态，避免覆盖已有设备身份。
                do {
                    try restoreCredentials(previousCredentials)
                } catch let rollbackError {
                    throw SyncSetupError.credentialsRollbackFailed(
                        original: error.localizedDescription,
                        rollback: rollbackError.localizedDescription
                    )
                }
                throw error
            }
            try activate(newCredentials)
            UserDefaults.standard.set(endpoint.absoluteString, forKey: Self.endpointDefaultsKey)
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            requestSync(.localChange)
            await refreshDevices()
        } catch {
            actionErrorMessage = userFacingMessage(for: error, action: .createVault)
            // 邀请码只存在于本次调用参数中，失败日志也不记录请求或服务端原文。
            logger.error("创建同步空间失败，界面已显示可操作提示")
        }
    }

    func exportBackup(
        passphrase: String,
        confirmation: String,
        includeSyncIdentity: Bool
    ) async {
        await exportPackage(
            passphrase: passphrase,
            confirmation: confirmation,
            purpose: .recovery(includeSyncIdentity: includeSyncIdentity)
        )
    }

    func exportOfflineRelay(
        passphrase: String,
        confirmation: String
    ) async {
        await exportPackage(
            passphrase: passphrase,
            confirmation: confirmation,
            purpose: .offlineRelay
        )
    }

    private func exportPackage(
        passphrase: String,
        confirmation: String,
        purpose: BackupExportPurpose
    ) async {
        guard !isBackupBusy else { return }
        guard passphrase == confirmation else {
            actionErrorMessage = BackupUIError.passphraseMismatch.localizedDescription
            return
        }
        let includeSyncIdentity: Bool
        let isOfflineRelay: Bool
        switch purpose {
        case .offlineRelay:
            includeSyncIdentity = false
            isOfflineRelay = true
        case .recovery(let shouldIncludeIdentity):
            includeSyncIdentity = shouldIncludeIdentity
            isOfflineRelay = false
        }
        let panel = NSSavePanel()
        panel.title = isOfflineRelay ? "导出 Woo Todo 离线接力包" : "导出 Woo Todo 加密备份"
        panel.nameFieldStringValue = isOfflineRelay
            ? "WooTodo-Relay-\(Self.backupDateKey()).wootodo"
            : "WooTodo-\(Self.backupDateKey()).wootodo"
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: "wootodo") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isBackupBusy = true
        actionErrorMessage = nil
        backupStatusMessage = nil
        defer { isBackupBusy = false }
        do {
            let backup = try repository.makeBackupContents()
            let storedCredentials = includeSyncIdentity
                ? try credentialsStore.load()
                : nil
            let exportedAt = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            let snapshot = try BackupSnapshot(
                exportedAt: exportedAt,
                tasks: backup.tasks,
                tombstones: backup.tombstones,
                syncCredentials: storedCredentials.map(BackupSyncCredentials.init)
            )
            let data = try await Task.detached(priority: .userInitiated) {
                try BackupPackageCodec.seal(snapshot, passphrase: passphrase)
            }.value
            try data.write(to: destination, options: .atomic)
            if isOfflineRelay {
                backupStatusMessage = "离线接力包已导出：\(backup.tasks.count) 条任务、\(backup.tombstones.count) 条删除记录。可通过 U 盘、局域网文件传输或系统分享交给另一台设备。"
            } else {
                let identitySummary = storedCredentials == nil ? "不含同步身份" : "包含同步身份"
                backupStatusMessage = "已导出 \(backup.tasks.count) 条任务和 \(backup.tombstones.count) 条删除记录（\(identitySummary)）。请单独保管文件与口令。"
            }
        } catch {
            actionErrorMessage = error.localizedDescription
            logger.error("导出加密备份失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func mergeOfflineRelay(passphrase: String) async {
        guard !isBackupBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "合并 Woo Todo 离线接力包"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "wootodo") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let source = panel.url else { return }

        isBackupBusy = true
        actionErrorMessage = nil
        backupStatusMessage = nil
        defer { isBackupBusy = false }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                return try BackupPackageCodec.open(data, passphrase: passphrase)
            }.value
            guard snapshot.syncCredentials == nil else {
                throw BackupUIError.relayContainsSyncIdentity
            }
            let result = try repository.mergeOfflineRelayPayloads(
                snapshot.tasks,
                tombstones: snapshot.tombstones
            )
            onRemoteChanges?()
            backupStatusMessage = "离线接力完成：合并 \(result.mergedTaskCount) 条任务、\(result.mergedTombstoneCount) 条删除记录，\(result.unchangedCount) 条无需变更。"
            if connection != nil {
                requestSync(.localChange)
            }
        } catch {
            actionErrorMessage = error.localizedDescription
            logger.error("合并离线接力包失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func importBackup(passphrase: String) async {
        guard !isBackupBusy else { return }
        do {
            guard connection == nil, try repository.fetchAll().isEmpty else {
                throw BackupUIError.destinationNotEmpty
            }
            guard try credentialsStore.load() == nil else {
                throw BackupUIError.credentialsAlreadyStored
            }
        } catch {
            actionErrorMessage = error.localizedDescription
            return
        }

        let panel = NSOpenPanel()
        panel.title = "导入 Woo Todo 加密备份"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "wootodo") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let source = panel.url else { return }

        isBackupBusy = true
        actionErrorMessage = nil
        backupStatusMessage = nil
        defer { isBackupBusy = false }
        do {
            let snapshot = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                return try BackupPackageCodec.open(data, passphrase: passphrase)
            }.value
            try repository.restoreBackupPayloads(
                snapshot.tasks,
                tombstones: snapshot.tombstones
            )

            if let recovery = snapshot.syncCredentials {
                let restoredCredentials = try recovery.credentials()
                do {
                    try repository.validateSyncBinding(
                        vaultId: restoredCredentials.vaultId,
                        deviceId: restoredCredentials.deviceId
                    )
                    try credentialsStore.save(restoredCredentials)
                    try repository.configureSync(Self.sqliteConfiguration(for: restoredCredentials))
                    try activate(restoredCredentials)
                    runtimeMachine.setConfigured(true)
                    publishRuntimeState()
                    UserDefaults.standard.set(
                        restoredCredentials.endpoint.absoluteString,
                        forKey: Self.endpointDefaultsKey
                    )
                } catch {
                    try? credentialsStore.delete()
                    throw BackupUIError.syncRecoveryFailed(error.localizedDescription)
                }
            }

            onRemoteChanges?()
            backupStatusMessage = "已恢复 \(snapshot.tasks.count) 条任务和 \(snapshot.tombstones.count) 条删除记录"
            if snapshot.syncCredentials != nil {
                requestSync(.localChange)
                await refreshDevices()
            }
        } catch {
            actionErrorMessage = error.localizedDescription
            logger.error("导入加密备份失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func createPairing() async {
        guard case .idle = pairingMachine.phase,
              let credentials,
              let apiClient else { return }
        actionErrorMessage = nil
        pairingPollTask?.cancel()
        pairingPollTask = nil
        pairingPollGeneration = nil
        pairingContext = nil
        pairingQRCodePayload = nil

        do {
            try pairingMachine.beginCreation()
            publishPairingState()

            let keyPair = PairingKeyPair.generate()
            let created = try await apiClient.createPairing(
                CreatePairingRequest(publicKey: keyPair.publicKeyBase64URL),
                deviceToken: credentials.deviceToken
            )
            guard created.initiatorPublicKey == keyPair.publicKeyBase64URL else {
                throw InitiatorPairingStateError.responseMismatch
            }
            let deepLink = try PairingDeepLink(
                endpoint: credentials.endpoint,
                pairingId: created.pairingId,
                pairingSecret: created.pairingSecret,
                initiatorPublicKey: created.initiatorPublicKey
            )
            pairingContext = PairingContext(
                keyPair: keyPair,
                pairingId: created.pairingId,
                deadline: Date().addingTimeInterval(
                    max(0, Double(created.expiresAt - created.serverTime) / 1_000)
                ),
                pairingSecret: created.pairingSecret
            )
            pairingQRCodePayload = try deepLink.url().absoluteString
            try pairingMachine.didCreate(created)
            publishPairingState()
            startPairingPolling()
        } catch {
            pairingMachine.fail(userFacingMessage(for: error, action: .pairDevice))
            pairingContext = nil
            pairingQRCodePayload = nil
            publishPairingState()
            logger.error("创建配对会话失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func confirmPairing() async {
        guard case .awaitingVerification = pairingMachine.phase,
              let credentials,
              let apiClient,
              var context = pairingContext,
              let sessionKey = context.sessionKey,
              let claim = context.claim else {
            return
        }
        actionErrorMessage = nil

        do {
            let verification = try pairingMachine.beginConfirmation()
            publishPairingState()
            let envelope = try PairingSessionCrypto.sealVaultKey(
                credentials.vaultKey,
                sessionKey: sessionKey,
                pairingId: verification.pairingId,
                claimedDeviceId: verification.claimedDeviceId
            )
            let confirmed = try await apiClient.confirmPairing(
                pairingId: context.pairingId,
                request: PairingConfirmRequest(vaultKeyEnvelope: envelope),
                deviceToken: credentials.deviceToken
            )
            guard confirmed.deviceId == claim.deviceId else {
                throw InitiatorPairingStateError.responseMismatch
            }
            try pairingMachine.didConfirm(confirmed)
            context.sessionKey = nil
            pairingContext = nil
            pairingQRCodePayload = nil
            publishPairingState()
            await refreshDevices()
            requestSync(.manual)
        } catch {
            if Date() >= context.deadline {
                pairingMachine.expire()
                pairingContext = nil
                pairingQRCodePayload = nil
            } else {
                try? pairingMachine.cancelConfirmation()
            }
            actionErrorMessage = userFacingMessage(for: error, action: .pairDevice)
            publishPairingState()
            logger.error("确认配对失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func resetPairing() {
        pairingPollTask?.cancel()
        pairingPollTask = nil
        pairingPollGeneration = nil
        pairingContext = nil
        pairingQRCodePayload = nil
        pairingMachine.reset()
        actionErrorMessage = nil
        publishPairingState()
    }

    func refreshDevices() async {
        guard !isLoadingDevices,
              let credentials,
              let apiClient else { return }
        isLoadingDevices = true
        defer { isLoadingDevices = false }
        actionErrorMessage = nil
        do {
            devices = try await apiClient.listDevices(
                deviceToken: credentials.deviceToken
            ).devices
        } catch {
            actionErrorMessage = userFacingMessage(for: error, action: .loadDevices)
            logger.error("获取设备列表失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func revokeDevice(_ device: DeviceInfo) async {
        guard !device.isCurrent,
              device.id != credentials?.deviceId,
              let credentials,
              let apiClient else { return }
        actionErrorMessage = nil
        do {
            _ = try await apiClient.revokeDevice(
                deviceId: device.id,
                deviceToken: credentials.deviceToken
            )
            await refreshDevices()
        } catch {
            actionErrorMessage = userFacingMessage(for: error, action: .revokeDevice)
            logger.error("撤销设备失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func activate(_ credentials: SyncCredentials) throws {
        let client = try SyncAPIClient(endpoint: credentials.endpoint)
        self.credentials = credentials
        self.apiClient = client
        self.coordinator = SyncCoordinator(
            transport: client,
            outbox: repository,
            local: repository,
            deviceToken: credentials.deviceToken
        )
        self.connection = SyncConnectionSummary(
            endpoint: credentials.endpoint,
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId
        )
        endpointText = credentials.endpoint.absoluteString
    }

    private func runSyncLoop(startingWith initialTrigger: SyncTrigger) async {
        var trigger: SyncTrigger? = initialTrigger
        while let activeTrigger = trigger, !Task.isCancelled {
            guard let coordinator else {
                trigger = runtimeMachine.fail(message: "同步协调器尚未配置")
                publishRuntimeState()
                continue
            }
            logger.debug("开始同步，触发原因：\(activeTrigger.rawValue, privacy: .public)")
            do {
                let summary = try await coordinator.synchronize()
                lastRunSummary = summary
                let successfulAt = Date()
                UserDefaults.standard.set(
                    successfulAt.timeIntervalSince1970,
                    forKey: Self.lastSuccessfulSyncDefaultsKey
                )
                trigger = runtimeMachine.succeed(at: successfulAt)
                publishRuntimeState()
                if summary.pulled > 0 {
                    onRemoteChanges?()
                }
            } catch is CancellationError {
                trigger = runtimeMachine.fail(message: "同步已取消")
                publishRuntimeState()
                break
            } catch {
                trigger = runtimeMachine.fail(
                    message: userFacingMessage(for: error, action: .synchronize)
                )
                publishRuntimeState()
                logger.notice("后台同步暂时失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        syncTask = nil
    }

    private func startPairingPolling() {
        pairingPollTask?.cancel()
        let generation = UUID()
        pairingPollGeneration = generation
        pairingPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.pairingPollGeneration == generation {
                guard case .awaitingClaim = self.pairingMachine.phase else { break }
                await self.pollPairingOnce()
                guard case .awaitingClaim = self.pairingMachine.phase else { break }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
            if self.pairingPollGeneration == generation {
                self.pairingPollTask = nil
                self.pairingPollGeneration = nil
            }
        }
    }

    private func pollPairingOnce() async {
        guard let credentials,
              let apiClient,
              var context = pairingContext else { return }
        if Date() >= context.deadline {
            pairingMachine.expire()
            pairingContext = nil
            pairingQRCodePayload = nil
            publishPairingState()
            return
        }
        do {
            let status = try await apiClient.pairingStatus(
                pairingId: context.pairingId,
                deviceToken: credentials.deviceToken
            )
            var code: String?
            if status.status == .claimed, let claim = status.claim {
                guard let keyPair = context.keyPair,
                      let pairingSecret = context.pairingSecret else {
                    throw InitiatorPairingStateError.responseMismatch
                }
                let sessionKey = try keyPair.sessionKey(
                    peerPublicKeyBase64URL: claim.publicKey,
                    pairingId: context.pairingId,
                    pairingSecretBase64URL: pairingSecret
                )
                code = try PairingSessionCrypto.verificationCode(
                    sessionKey: sessionKey,
                    initiatorPublicKey: keyPair.publicKey,
                    claimPublicKey: Base64URL.decode(claim.publicKey)
                )
                context.keyPair = nil
                context.pairingSecret = nil
                context.claim = claim
                context.sessionKey = sessionKey
                pairingContext = context
                pairingQRCodePayload = nil
            }
            try pairingMachine.didPoll(status, verificationCode: code)
            actionErrorMessage = nil
            if case .expired = pairingMachine.phase {
                pairingContext = nil
                pairingQRCodePayload = nil
            }
            publishPairingState()
        } catch {
            handlePairingPollFailure(error)
        }
    }

    private func handlePairingPollFailure(_ error: Error) {
        if case let SyncAPIError.server(_, payload, _)? = error as? SyncAPIError,
           payload.code == "PAIRING_EXPIRED" {
            pairingMachine.expire()
            pairingContext = nil
            pairingQRCodePayload = nil
            actionErrorMessage = nil
            publishPairingState()
            return
        }

        if let apiError = error as? SyncAPIError {
            switch apiError {
            case .transport, .invalidHTTPResponse:
                // 临时网络失败不结束 10 分钟配对窗口，下一轮继续尝试。
                actionErrorMessage = "暂时无法连接配对服务，将在二维码有效期内自动重试。请检查 Mac 网络与 Worker 状态。"
                return
            case .server(let statusCode, _, _) where statusCode == 429 || statusCode >= 500:
                actionErrorMessage = "配对服务暂时不可用，将自动重试"
                return
            default:
                break
            }
        }

        pairingMachine.fail(error.localizedDescription)
        pairingContext = nil
        pairingQRCodePayload = nil
        actionErrorMessage = nil
        publishPairingState()
    }

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

    private func publishPairingState() {
        pairingPhase = pairingMachine.phase
    }

    private func validatedEndpoint() throws -> URL {
        switch endpointSetupAssessment {
        case .ready(let endpoint):
            return endpoint
        case .empty, .invalid:
            throw SyncSetupError.invalidEndpoint
        case .currentDeviceOnly:
            throw SyncSetupError.currentDeviceOnlyEndpoint
        case .includesAPIVersion:
            throw SyncSetupError.includesAPIVersion
        }
    }

    private func validatedInviteCode(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SyncSetupError.missingInviteCode
        }
        guard (16...256).contains(value.unicodeScalars.count),
              value.unicodeScalars.allSatisfy({ (0x21...0x7e).contains($0.value) }) else {
            throw SyncSetupError.invalidInviteCodeFormat
        }
        return value
    }

    private func userFacingMessage(for error: Error, action: SyncUserAction) -> String {
        guard let apiError = error as? SyncAPIError else {
            return error.localizedDescription
        }
        switch apiError {
        case .invalidEndpoint:
            return SyncSetupError.invalidEndpoint.localizedDescription
        case .transport:
            return "无法连接同步服务。请确认 Worker 已部署、服务地址能在 Mac 与手机上访问，并检查网络后重试。"
        case .invalidHTTPResponse:
            return "已连接到该地址，但没有收到有效的 HTTP 响应。请确认它是 Woo Todo Worker 的根地址。"
        case .decoding:
            return "服务已响应，但返回格式与当前版本不兼容。请确认没有把 Vercel 主页或其他网页地址当作同步服务。"
        case .encoding:
            return "无法准备\(action.label)请求，请重新启动应用后重试。"
        case .server(let statusCode, let payload, let requestId):
            let requestSuffix = requestId.map { "（请求 ID：\($0)）" } ?? ""
            if payload.code == "INVALID_INVITE_CODE" {
                return "创建邀请码无效或已失效，请向同步服务部署者确认后重试。\(requestSuffix)"
            }
            if payload.code == "SERVER_MISCONFIGURED", action == .createVault {
                return "同步服务尚未配置创建邀请码，无法创建空间。请由部署者配置 VAULT_CREATION_INVITE_CODE 后重新部署。\(requestSuffix)"
            }
            if payload.code == "VAULT_CAPACITY_REACHED" {
                return "同步空间已达到存储上限，本地待发送任务仍会保留。请先导出加密备份，等待后续压缩或迁移工具。\(requestSuffix)"
            }
            switch statusCode {
            case 401, 403:
                return "当前设备的同步凭据已失效，服务拒绝\(action.label)。请检查已绑定设备状态。\(requestSuffix)"
            case 404 where action == .createVault,
                 405 where action == .createVault:
                return "找不到 Woo Todo 创建空间接口。请填写 Worker 根地址，末尾不要添加 /v1。\(requestSuffix)"
            case 410 where action == .pairDevice:
                return "配对二维码已过期，请重新生成。\(requestSuffix)"
            case 429:
                return "请求过于频繁，请稍后再试。\(requestSuffix)"
            case 500...599:
                return "同步服务暂时异常，\(action.label)未完成；本地任务不受影响，请稍后重试。\(requestSuffix)"
            default:
                return "服务拒绝\(action.label)（\(payload.code)）：\(payload.message)\(requestSuffix)"
            }
        }
    }

    private static func sqliteConfiguration(
        for credentials: SyncCredentials
    ) -> SQLiteSyncConfiguration {
        SQLiteSyncConfiguration(
            vaultId: credentials.vaultId,
            deviceId: credentials.deviceId,
            vaultKey: credentials.vaultKey
        )
    }

    private func restoreCredentials(_ credentials: SyncCredentials?) throws {
        if let credentials {
            try credentialsStore.save(credentials)
        } else {
            try credentialsStore.delete()
        }
    }

    private static var localDeviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    private static func backupDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private struct PairingContext {
    var keyPair: PairingKeyPair?
    let pairingId: String
    let deadline: Date
    var pairingSecret: String?
    var claim: PairingClaimInfo? = nil
    var sessionKey: Data? = nil
}
