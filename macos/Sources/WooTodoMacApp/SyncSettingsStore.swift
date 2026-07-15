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

    var errorDescription: String? {
        switch self {
        case .credentialsAlreadyStored:
            "Keychain 已存在同步身份，请重新启动应用后再操作"
        case .credentialsRollbackFailed(let original, let rollback):
            "同步绑定失败（\(original)），且无法恢复原 Keychain 凭据（\(rollback)）"
        }
    }
}

private enum BackupUIError: LocalizedError {
    case passphraseMismatch
    case destinationNotEmpty
    case credentialsAlreadyStored
    case syncRecoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .passphraseMismatch: "两次输入的备份口令不一致"
        case .destinationNotEmpty: "导入只允许在尚无任务、尚未连接同步空间的全新安装中进行"
        case .credentialsAlreadyStored: "Keychain 已有同步身份，不能覆盖导入"
        case .syncRecoveryFailed(let message):
            "任务已恢复到本地，但同步身份恢复失败：\(message)"
        }
    }
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

    func createVault() async {
        guard !isCreatingVault, connection == nil else { return }
        actionErrorMessage = nil
        isCreatingVault = true
        defer { isCreatingVault = false }

        do {
            let previousCredentials = try credentialsStore.load()
            guard previousCredentials == nil else {
                throw SyncSetupError.credentialsAlreadyStored
            }
            let endpoint = try validatedEndpoint()
            let client = try SyncAPIClient(endpoint: endpoint)
            let vaultKey = try SecureRandom.bytes(count: AES256GCM.keyByteCount)
            let created = try await client.createVault(CreateVaultRequest(
                device: DeviceRegistration(
                    name: Self.localDeviceName,
                    platform: .macos
                )
            ))
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
            actionErrorMessage = error.localizedDescription
            logger.error("创建同步空间失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func exportBackup(passphrase: String, confirmation: String) async {
        guard !isBackupBusy else { return }
        guard passphrase == confirmation else {
            actionErrorMessage = BackupUIError.passphraseMismatch.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出 Woo Todo 加密备份"
        panel.nameFieldStringValue = "WooTodo-\(Self.backupDateKey()).wootodo"
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
            let payloads = try repository.makeBackupPayloads()
            let storedCredentials = try credentialsStore.load()
            let exportedAt = Int64((Date().timeIntervalSince1970 * 1_000).rounded())
            let snapshot = try BackupSnapshot(
                exportedAt: exportedAt,
                tasks: payloads,
                syncCredentials: storedCredentials.map(BackupSyncCredentials.init)
            )
            let data = try await Task.detached(priority: .userInitiated) {
                try BackupPackageCodec.seal(snapshot, passphrase: passphrase)
            }.value
            try data.write(to: destination, options: .atomic)
            backupStatusMessage = "已导出 \(payloads.count) 条任务。请把文件保存到夸克网盘，并单独保管口令。"
        } catch {
            actionErrorMessage = error.localizedDescription
            logger.error("导出加密备份失败：\(error.localizedDescription, privacy: .public)")
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
            try repository.restoreBackupPayloads(snapshot.tasks)

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
            backupStatusMessage = "已恢复 \(snapshot.tasks.count) 条任务"
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
            pairingMachine.fail(error.localizedDescription)
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
            actionErrorMessage = error.localizedDescription
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
            actionErrorMessage = error.localizedDescription
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
            actionErrorMessage = error.localizedDescription
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
                trigger = runtimeMachine.fail(message: error.localizedDescription)
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
                actionErrorMessage = "暂时无法查询配对状态：\(apiError.localizedDescription)"
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
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: trimmed), SyncEndpointPolicy.isAllowed(endpoint) else {
            throw SyncAPIError.invalidEndpoint
        }
        return endpoint
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
