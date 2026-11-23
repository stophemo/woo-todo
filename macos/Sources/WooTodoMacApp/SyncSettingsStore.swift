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
    case missingEndpoint
    case missingInviteCode
    case invalidInviteCodeFormat
    case pairingResponseMismatch

    var errorDescription: String? {
        switch self {
        case .credentialsAlreadyStored:
            "本机已有同步身份，请先退出当前同步空间后再操作"
        case .credentialsRollbackFailed(let original, let rollback):
            "同步绑定失败（\(original)），且无法恢复原同步凭据（\(rollback)）"
        case .invalidEndpoint:
            "请输入已部署同步服务的 HTTPS 根地址，例如 https://你的-worker.workers.dev"
        case .missingEndpoint:
            "请先填写已部署同步服务的 HTTPS 地址"
        case .missingInviteCode:
            "请输入部署同步服务时设置的创建邀请码"
        case .invalidInviteCodeFormat:
            "创建邀请码须为 16–256 个字符，且只能包含无空格的可打印 ASCII 字符"
        case .pairingResponseMismatch:
            "配对服务返回的配对结果与当前会话不一致，已停止保存。请重新生成配对码。"
        }
    }
}

private enum SyncUserAction: Equatable {
    case createVault
    case pairDevice
    case loadDevices
    case removeDevice
    case synchronize
    case exitSpace

    var label: String {
        switch self {
        case .createVault: "建立同步空间"
        case .pairDevice: "设备配对"
        case .loadDevices: "获取设备列表"
        case .removeDevice: "移除设备"
        case .synchronize: "同步"
        case .exitSpace: "退出同步空间"
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
        case .credentialsAlreadyStored: "本机已有同步身份，不能覆盖导入"
        case .syncRecoveryFailed(let message):
            "任务已恢复到本地，但同步身份恢复失败：\(message)"
        }
    }
}

enum ShortCodeClaimPhase: Equatable {
    case idle
    case claiming
    case awaitingConfirmation(code: String, deviceName: String, deadline: Date)
    case confirmed
    case failed(String)
}

@MainActor
final class SyncSettingsStore: ObservableObject {
    typealias APIClientFactory = (URL) throws -> SyncAPIClient

    @Published var endpointText: String
    @Published private(set) var connection: SyncConnectionSummary?
    @Published private(set) var runtimeSnapshot: SyncRuntimeSnapshot
    @Published private(set) var lastRunSummary: SyncRunSummary?
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var cleaningDeviceIDs = Set<String>()
    @Published private(set) var isCreatingVault = false
    @Published private(set) var isLoadingDevices = false
    @Published private(set) var pairingPhase: InitiatorPairingPhase = .idle
    @Published private(set) var pairingShortCode: String?
    @Published private(set) var shortCodeClaimPhase: ShortCodeClaimPhase = .idle
    @Published private(set) var joinCreatorPhase: JoinCreatorPhase = .idle
    @Published private(set) var joinCreatorApprovalPending = false
    @Published private(set) var joinApproverPhase: JoinApproverPhase = .idle
    @Published private(set) var actionErrorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isBackupBusy = false
    @Published private(set) var backupStatusMessage: String?
    @Published private(set) var isExitingSpace = false
    @Published private(set) var legacyNotice: String?

    var onRemoteChanges: (() -> Void)?
    var onLifecycleRefresh: (() -> Void)?

    var hasBundledEndpoint: Bool { bundledSyncEndpoint != nil }

    /// 仅供界面与测试观察创建方配对码的本地截止时间。
    var joinCreatorDeadline: Date? { joinCreatorContext?.deadline }

    var endpointFieldIsEditable: Bool {
        connection == nil && bundledSyncEndpoint == nil
    }

    var endpointSetupAssessment: SyncEndpointSetupAssessment {
        if let connection { return .ready(connection.endpoint) }
        if let bundledSyncEndpoint { return .ready(bundledSyncEndpoint) }
        return SyncEndpointSetupPolicy.assess(endpointText)
    }

    var canCreateVault: Bool {
        connection == nil && resolvedEndpoint() != nil
    }

    private let logger = Logger(
        subsystem: "io.github.stophemo.woo-todo",
        category: "跨设备"
    )
    private let repository: SQLiteTaskRepository
    private let credentialsStore: any SyncCredentialsStoring
    private let defaults: UserDefaults
    private let bundledSyncEndpoint: URL?
    private let hadLegacySync: Bool
    private let apiClientFactory: APIClientFactory
    private var credentials: SyncCredentials?
    private var apiClient: SyncAPIClient?
    private var coordinator: SyncCoordinator?
    private var runtimeMachine: SyncRuntimeStateMachine
    private var pairingMachine = InitiatorPairingStateMachine()
    private var joinCreatorMachine = JoinCreatorStateMachine()
    private var joinApproverMachine = JoinApproverStateMachine()
    private var pairingContext: PairingContext?
    private var joinCreatorContext: JoinCreatorContext?
    private var joinApprovalContext: JoinApprovalContext?
    private var syncTask: Task<Void, Never>?
    private var pairingPollTask: Task<Void, Never>?
    private var pairingPollGeneration: UUID?
    private var joinCreatorPollTask: Task<Void, Never>?
    private var joinCreatorPollGeneration: UUID?
    private var shortCodeClaimTask: Task<Void, Never>?
    private var shortCodeClaimGeneration = UUID()
    /// claim 成功但尚未完成保存时用于撤销临时设备的凭据。
    private var shortCodeClaimRevocation: ClaimDeviceRevocation?
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
    private static let legacyNoticeDefaultsKey = "sync.legacy-notice-shown"
    private static let lastSuccessfulSyncDefaultsKey = "sync.last-successful-at"
    private static let fallbackInterval: TimeInterval = 15 * 60

    init(
        repository: SQLiteTaskRepository,
        credentialsStore: any SyncCredentialsStoring,
        credentials: SyncCredentials?,
        defaultSyncEndpoint: URL?,
        legacyDetection: SyncLegacyDetection = SyncLegacyDetection(
            credentialsInvalidated: false,
            legacyStoragePresent: false
        ),
        hasStoredValidCredentials: Bool = false,
        apiClientFactory: @escaping APIClientFactory = { try SyncAPIClient(endpoint: $0) },
        defaults: UserDefaults = .standard
    ) throws {
        self.repository = repository
        self.credentialsStore = credentialsStore
        self.credentials = credentials
        self.defaults = defaults
        self.bundledSyncEndpoint = defaultSyncEndpoint
        self.hadLegacySync = legacyDetection.isLegacy
        self.apiClientFactory = apiClientFactory
        let savedSuccessTimestamp = defaults.object(
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
        if let credentials {
            endpointText = credentials.endpoint.absoluteString
        } else if let defaultSyncEndpoint {
            endpointText = defaultSyncEndpoint.absoluteString
        } else if let saved = defaults.string(forKey: Self.endpointDefaultsKey),
                  case let .ready(endpoint) = SyncEndpointSetupPolicy.assess(saved) {
            endpointText = endpoint.absoluteString
        } else {
            endpointText = ""
        }
        // 只有在没有有效同步身份时才提示旧方式停用；旧文件不能否决新凭据。
        if credentials == nil,
           !hasStoredValidCredentials,
           legacyDetection.isLegacy,
           !defaults.bool(forKey: Self.legacyNoticeDefaultsKey) {
            legacyNotice = SyncLegacyNotice.text
        }
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
        joinCreatorPollTask?.cancel()
        joinCreatorPollTask = nil
        joinCreatorPollGeneration = nil
        shortCodeClaimTask?.cancel()
        shortCodeClaimTask = nil
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

    @discardableResult
    func saveManualEndpoint() -> Bool {
        guard endpointFieldIsEditable else { return true }
        switch SyncEndpointSetupPolicy.assess(endpointText) {
        case .ready(let endpoint):
            defaults.set(endpoint.absoluteString, forKey: Self.endpointDefaultsKey)
            endpointText = endpoint.absoluteString
            actionErrorMessage = nil
            return true
        case .empty:
            actionErrorMessage = SyncSetupError.missingEndpoint.localizedDescription
        case .includesAPIVersion:
            actionErrorMessage = "请删除末尾的 /v1，只填写 Worker 根地址"
        case .invalid:
            actionErrorMessage = SyncSetupError.invalidEndpoint.localizedDescription
        }
        return false
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
        cancelPairingFlows(except: .createVault)
        actionErrorMessage = nil
        statusMessage = nil
        isCreatingVault = true
        defer { isCreatingVault = false }

        do {
            let inviteCode = try validatedInviteCode(rawInviteCode)
            let previousCredentials = try previousCredentialsForPairing()
            let endpoint = try preparedPairingEndpoint()
            let client = try apiClientFactory(endpoint)
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
            try credentialsStore.save(newCredentials)
            do {
                try bindRepository(newCredentials)
            } catch {
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
            try activate(newCredentials, client: client)
            defaults.set(endpoint.absoluteString, forKey: Self.endpointDefaultsKey)
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            statusMessage = "同步空间已建立，其他设备现在可以用六位配对码加入。"
            requestSync(.localChange)
            await refreshDevices()
        } catch {
            actionErrorMessage = userFacingMessage(for: error, action: .createVault)
            // 邀请码只存在于本次调用参数中，失败日志也不记录请求或服务端原文。
            logger.error("建立同步空间失败，界面已显示可操作提示")
        }
    }

    func exportBackup(
        passphrase: String,
        confirmation: String,
        includeSyncIdentity: Bool
    ) async {
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
            let identitySummary = storedCredentials == nil ? "不含同步身份" : "包含同步身份"
            backupStatusMessage = "已导出 \(backup.tasks.count) 条任务和 \(backup.tombstones.count) 条删除记录（\(identitySummary)）。请单独保管文件与口令。"
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
            var existingCredentials: SyncCredentials?
            do {
                existingCredentials = try credentialsStore.load()
            } catch {
                if SyncLegacyDetector.isLegacyCredentialsError(error), hadLegacySync {
                    existingCredentials = nil
                } else {
                    throw error
                }
            }
            if let existingCredentials, (try? existingCredentials.validate()) != nil {
                throw BackupUIError.credentialsAlreadyStored
            }
            guard existingCredentials == nil || hadLegacySync else {
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
                if !recovery.hasSupportedEndpoint {
                    // 旧同步方式的地址已停用：只恢复任务，不保存凭据、不绑定空间。
                    backupStatusMessage = "已恢复 \(snapshot.tasks.count) 条任务和 \(snapshot.tombstones.count) 条删除记录；备份中的同步身份使用旧服务地址，已停用，请重新配对。"
                    onRemoteChanges?()
                    return
                }
                do {
                    let restoredCredentials = try recovery.credentials()
                    try repository.validateSyncBinding(
                        vaultId: restoredCredentials.vaultId,
                        deviceId: restoredCredentials.deviceId
                    )
                    try credentialsStore.save(restoredCredentials)
                    try repository.configureSync(Self.sqliteConfiguration(for: restoredCredentials))
                    try activate(restoredCredentials)
                    runtimeMachine.setConfigured(true)
                    publishRuntimeState()
                    defaults.set(
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

    // MARK: - 已有设备显示配对码（Path A）

    func createPairing() async {
        guard case .idle = pairingMachine.phase,
              let credentials,
              let apiClient else { return }
        actionErrorMessage = nil
        statusMessage = nil
        pairingPollTask?.cancel()
        pairingPollTask = nil
        pairingPollGeneration = nil
        pairingContext = nil
        pairingShortCode = nil

        do {
            try pairingMachine.beginCreation()
            publishPairingState()

            let keyPair = try PairingKeyPair.generate()
            let created = try await apiClient.createPairingCode(
                CreatePairingRequest(publicKey: keyPair.publicKeyBase64URL),
                deviceToken: credentials.deviceToken
            )
            guard created.initiatorPublicKey == keyPair.publicKeyBase64URL,
                  let shortCode = created.shortCode,
                  shortCode.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil else {
                throw InitiatorPairingStateError.responseMismatch
            }
            pairingContext = PairingContext(
                keyPair: keyPair,
                pairingId: created.pairingId,
                deadline: Date().addingTimeInterval(
                    max(0, Double(created.expiresAt - created.serverTime) / 1_000)
                ),
                pairingSecret: created.pairingSecret
            )
            pairingShortCode = shortCode
            try pairingMachine.didCreate(created)
            publishPairingState()
            startPairingPolling()
        } catch {
            pairingMachine.fail(userFacingMessage(for: error, action: .pairDevice))
            pairingContext = nil
            pairingShortCode = nil
            publishPairingState()
            logger.error("创建配对码失败：\(error.localizedDescription, privacy: .public)")
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
            pairingShortCode = nil
            publishPairingState()
            await refreshDevices()
            requestSync(.manual)
        } catch {
            if Date() >= context.deadline {
                pairingMachine.expire()
                pairingContext = nil
                pairingShortCode = nil
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
        pairingShortCode = nil
        pairingMachine.reset()
        actionErrorMessage = nil
        publishPairingState()
    }

    // MARK: - 输入配对码（Path A 认领方）

    func claimByShortCode(_ rawCode: String) {
        guard connection == nil, !isCreatingVault else { return }
        let code = rawCode.filter(\.isNumber)
        guard code.count == 6 else {
            shortCodeClaimPhase = .failed("请输入另一台设备显示的 6 位数字配对码")
            return
        }
        let endpoint: URL
        do {
            endpoint = try preparedPairingEndpoint()
        } catch {
            shortCodeClaimPhase = .failed(error.localizedDescription)
            return
        }
        cancelPairingFlows(except: .pathAClaim)
        shortCodeClaimTask?.cancel()
        // 重新发起认领前，撤销上一次 claim 成功但未完成保存的临时设备。
        abandonShortCodeClaimRevocation()
        let generation = UUID()
        shortCodeClaimGeneration = generation
        shortCodeClaimPhase = .claiming
        actionErrorMessage = nil
        statusMessage = nil
        shortCodeClaimTask = Task { [weak self] in
            await self?.performShortCodeClaim(
                code: code,
                endpoint: endpoint,
                generation: generation
            )
        }
    }

    func cancelShortCodeClaim() {
        shortCodeClaimTask?.cancel()
        shortCodeClaimTask = nil
        shortCodeClaimGeneration = UUID()
        shortCodeClaimPhase = .idle
        abandonShortCodeClaimRevocation()
    }

    private func performShortCodeClaim(
        code: String,
        endpoint: URL,
        generation: UUID
    ) async {
        do {
            _ = try previousCredentialsForPairing()
            let keyPair = try PairingKeyPair.generate()
            let deviceToken = try SecureRandom.deviceToken()
            let client = try apiClientFactory(endpoint)
            let resolved = try await client.resolveShortCode(
                ResolveShortCodeRequest(code: code)
            )
            try Self.validateResolvedShortCode(resolved)
            let claim = try await client.claimPairing(
                pairingId: resolved.pairingId,
                request: PairingClaimRequest(
                    pairingSecret: resolved.pairingSecret,
                    deviceToken: deviceToken,
                    device: PairingDeviceRegistration(
                        name: Self.localDeviceName,
                        platform: .macos,
                        publicKey: keyPair.publicKeyBase64URL
                    )
                )
            )
            // claim 成功后服务端已消费配对码并可能记录临时设备，之后任何放弃路径都要撤销。
            shortCodeClaimRevocation = ClaimDeviceRevocation(
                generation: generation,
                client: client,
                deviceToken: deviceToken
            )
            try Self.validateClaim(claim, resolved: resolved, claimPublicKey: keyPair.publicKey)
            let sessionKey = try keyPair.sessionKey(
                peerPublicKeyBase64URL: resolved.initiatorPublicKey,
                pairingId: resolved.pairingId,
                pairingSecretBase64URL: resolved.pairingSecret
            )
            let verificationCode = try PairingSessionCrypto.verificationCode(
                sessionKey: sessionKey,
                initiatorPublicKey: Base64URL.decode(resolved.initiatorPublicKey),
                claimPublicKey: keyPair.publicKey
            )
            guard shortCodeClaimGeneration == generation else {
                await revokeShortCodeClaimDeviceIfNeeded(generation: generation)
                return
            }
            // 绝对 expiresAt 与本机时钟无关，必须用 serverTime 换算剩余时间；
            // 旧服务未返回 serverTime 时模型已回退为 expiresAt（剩余按 0 处理，fail-closed）。
            let deadline = Date().addingTimeInterval(
                max(0, Double(resolved.expiresAt - resolved.serverTime) / 1_000)
            )
            shortCodeClaimPhase = .awaitingConfirmation(
                code: verificationCode,
                deviceName: "另一台设备",
                deadline: deadline
            )

            while !Task.isCancelled, Date() < deadline {
                let result = try await client.pairingResult(
                    pairingId: resolved.pairingId,
                    request: PairingResultRequest(
                        pairingSecret: resolved.pairingSecret,
                        deviceToken: deviceToken
                    )
                )
                if result.status == .confirmed {
                    let confirmed = try Self.validateConfirmedPairing(
                        result,
                        resolved: resolved,
                        claim: claim
                    )
                    let vaultKey = try PairingSessionCrypto.openVaultKey(
                        confirmed.envelope,
                        sessionKey: sessionKey,
                        pairingId: resolved.pairingId,
                        claimedDeviceId: claim.deviceId
                    )
                    let newCredentials = SyncCredentials(
                        endpoint: endpoint,
                        vaultId: confirmed.vaultId,
                        deviceId: claim.deviceId,
                        deviceToken: deviceToken,
                        vaultKey: vaultKey
                    )
                    try newCredentials.validate()
                    let saved = try await finishShortCodeClaim(
                        newCredentials,
                        client: client,
                        generation: generation
                    )
                    if !saved {
                        await revokeShortCodeClaimDeviceIfNeeded(generation: generation)
                    }
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            await revokeShortCodeClaimDeviceIfNeeded(generation: generation)
            guard !Task.isCancelled, shortCodeClaimGeneration == generation else {
                return
            }
            shortCodeClaimPhase = .failed("配对码已过期，请重新生成")
        } catch is CancellationError {
            // 用户主动取消或切换到其它配对流程：撤销未完成保存的临时设备。
            await revokeShortCodeClaimDeviceIfNeeded(generation: generation)
        } catch {
            await revokeShortCodeClaimDeviceIfNeeded(generation: generation)
            guard shortCodeClaimGeneration == generation else { return }
            shortCodeClaimPhase = .failed(
                userFacingMessage(for: error, action: .pairDevice)
            )
            logger.error(
                "六位码配对失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 返回值表示是否确实完成了保存；false 时调用方需撤销临时设备。
    private func finishShortCodeClaim(
        _ newCredentials: SyncCredentials,
        client: SyncAPIClient,
        generation: UUID
    ) async throws -> Bool {
        guard shortCodeClaimGeneration == generation else { return false }
        let previousCredentials = try previousCredentialsForPairing()
        do {
            try credentialsStore.save(newCredentials)
            try bindRepository(newCredentials)
            defaults.set(
                newCredentials.endpoint.absoluteString,
                forKey: Self.endpointDefaultsKey
            )
            try activate(newCredentials, client: client)
            runtimeMachine.setConfigured(true)
            publishRuntimeState()
            // 凭据与本地绑定已保存成功，不再需要撤销本次临时设备。
            if shortCodeClaimRevocation?.generation == generation {
                shortCodeClaimRevocation = nil
            }
            if let previousCredentials,
               previousCredentials.vaultId != newCredentials.vaultId
                || previousCredentials.deviceId != newCredentials.deviceId {
                // 旧 Mac 设备令牌已不再保存，顺手撤销，避免同步空间里留下无法清理的设备。
                _ = try? await client.revokeDevice(
                    deviceId: previousCredentials.deviceId,
                    deviceToken: newCredentials.deviceToken
                )
            }
            shortCodeClaimPhase = .confirmed
            actionErrorMessage = nil
            await refreshDevices()
            requestSync(.manual)
            logger.notice("已通过六位码加入同步空间")
            return true
        } catch {
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
    }

    // MARK: - 新设备显示配对码（Path B 创建方）

    func createJoinRequest() async {
        guard connection == nil, !isCreatingVault, joinCreatorPhase.canCreate else { return }
        cancelPairingFlows(except: .pathBCreator)
        actionErrorMessage = nil
        statusMessage = nil
        joinCreatorPollTask?.cancel()
        joinCreatorPollTask = nil
        joinCreatorPollGeneration = nil
        joinCreatorContext = nil

        do {
            _ = try previousCredentialsForPairing()
            let endpoint = try preparedPairingEndpoint()
            try joinCreatorMachine.beginCreation()
            publishJoinCreatorPhase()

            let keyPair = try PairingKeyPair.generate()
            let deviceToken = try SecureRandom.deviceToken()
            let client = try apiClientFactory(endpoint)
            let created = try await client.createJoinRequest(
                CreateJoinRequest(
                    publicKey: keyPair.publicKeyBase64URL,
                    deviceToken: deviceToken,
                    device: JoinDeviceRegistration(
                        name: Self.localDeviceName,
                        platform: .macos
                    )
                )
            )
            try joinCreatorMachine.didCreate(created)
            joinCreatorContext = JoinCreatorContext(
                endpoint: endpoint,
                client: client,
                keyPair: keyPair,
                deviceToken: deviceToken,
                joinRequestId: created.joinRequestId,
                joinSecret: created.joinSecret,
                deviceId: created.deviceId,
                deadline: Self.relativeDeadline(
                    expiresAt: created.expiresAt,
                    serverTime: created.serverTime
                )
            )
            publishJoinCreatorPhase()
            startJoinCreatorPolling()
        } catch {
            joinCreatorMachine.fail(
                userFacingMessage(for: error, action: .pairDevice)
            )
            joinCreatorContext = nil
            publishJoinCreatorPhase()
            logger.error("创建配对请求失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func resetJoinCreation() {
        joinCreatorPollTask?.cancel()
        joinCreatorPollTask = nil
        joinCreatorPollGeneration = nil
        joinCreatorContext = nil
        joinCreatorMachine.reset()
        actionErrorMessage = nil
        publishJoinCreatorPhase()
    }

    func cancelJoinCreation() async {
        joinCreatorPollTask?.cancel()
        joinCreatorPollTask = nil
        joinCreatorPollGeneration = nil
        // 先捕获 context 并清理共享状态，再撤销服务端可能已创建的设备。
        let context = joinCreatorContext
        joinCreatorContext = nil
        joinCreatorMachine.cancel()
        publishJoinCreatorPhase()
        if let context {
            await revokeTemporaryDevice(
                client: context.client,
                deviceToken: context.deviceToken
            )
            _ = try? await context.client.cancelJoinRequest(
                joinRequestId: context.joinRequestId,
                request: JoinResultRequest(joinSecret: context.joinSecret)
            )
        }
        statusMessage = "配对已取消，配对码将在 5 分钟后失效。"
    }

    private func startJoinCreatorPolling() {
        joinCreatorPollTask?.cancel()
        let generation = UUID()
        joinCreatorPollGeneration = generation
        joinCreatorPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.joinCreatorPollGeneration == generation {
                await self.pollJoinCreatorOnce(generation: generation)
                guard !Task.isCancelled,
                      self.joinCreatorPollGeneration == generation,
                      self.joinCreatorPhase.isWaitingForApproval,
                      !self.joinCreatorApprovalPending else {
                    break
                }
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    break
                }
            }
            if self.joinCreatorPollGeneration == generation {
                self.joinCreatorPollTask = nil
                self.joinCreatorPollGeneration = nil
            }
        }
    }

    private func pollJoinCreatorOnce(generation: UUID) async {
        guard joinCreatorPollGeneration == generation,
              var context = joinCreatorContext else { return }
        // 已收到 approved：等待用户核对确认，不再受配对码 TTL 约束，也停止轮询。
        if joinCreatorMachine.pendingApproval != nil {
            return
        }
        let deadlinePassed = Date() >= context.deadline
        do {
            // 截止时间也先做最后一次查询，避免丢掉最后一刻到达的 approved。
            let result = try await context.client.joinResult(
                joinRequestId: context.joinRequestId,
                request: JoinResultRequest(joinSecret: context.joinSecret)
            )
            guard joinCreatorPollGeneration == generation else { return }
            if result.expiresAt > 0, result.serverTime > 0 {
                context.deadline = Self.relativeDeadline(
                    expiresAt: result.expiresAt,
                    serverTime: result.serverTime
                )
                joinCreatorContext = context
            }
            var verificationCode: String?
            if result.status == .resolved || result.status == .approved,
               let approverPublicKey = result.approverPublicKey,
               let approverKey = try? Base64URL.decode(approverPublicKey),
               approverKey.count == 32 {
                let sessionKey = try PairingJoinCrypto.sessionKey(
                    keyPair: context.keyPair,
                    peerPublicKey: approverKey,
                    joinRequestId: context.joinRequestId
                )
                verificationCode = try PairingJoinCrypto.verificationCode(
                    sessionKey: sessionKey,
                    joinRequestId: context.joinRequestId,
                    creatorPublicKey: context.keyPair.publicKey,
                    approverPublicKey: approverKey
                )
            }
            try joinCreatorMachine.didPoll(result, verificationCode: verificationCode)
            actionErrorMessage = nil
            publishJoinCreatorPhase()

            if joinCreatorMachine.pendingApproval != nil {
                // approved 已到手：保留 context 供用户确认，停止按 TTL 丢弃。
                return
            }
            if case .approved = joinCreatorMachine.phase {
                // approved 只能来自 confirmJoinCreation，这里做防御性清理。
                joinCreatorContext = nil
            } else if !joinCreatorPhase.isWaitingForApproval {
                joinCreatorContext = nil
            } else if deadlinePassed {
                // 截止时间的最后一次查询仍未拿到 approved，按过期处理。
                joinCreatorMachine.expire()
                joinCreatorContext = nil
                publishJoinCreatorPhase()
            }
        } catch {
            await handleJoinCreatorPollFailure(error, generation: generation)
        }
    }

    /// 用户在核对码一致后显式确认加入；只有这一步会解封 vault key 并保存凭据。
    func confirmJoinCreation() async {
        guard case .awaitingConfirmation = joinCreatorPhase,
              let context = joinCreatorContext else { return }
        actionErrorMessage = nil
        joinCreatorPollTask?.cancel()
        joinCreatorPollTask = nil
        joinCreatorPollGeneration = nil
        do {
            let approval = try joinCreatorMachine.confirmJoinCreation()
            publishJoinCreatorPhase()
            try await finishJoinCreator(approval, context: context)
            joinCreatorContext = nil
            await refreshDevices()
            requestSync(.manual)
        } catch {
            // approve 可能已在服务端创建设备；保存失败或核对失败都先尝试撤销。
            await revokeTemporaryDevice(
                client: context.client,
                deviceToken: context.deviceToken
            )
            joinCreatorMachine.fail(
                userFacingMessage(for: error, action: .pairDevice)
            )
            joinCreatorContext = nil
            publishJoinCreatorPhase()
            logger.error(
                "完成配对失败：\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func finishJoinCreator(
        _ approval: JoinCreatorApproval,
        context: JoinCreatorContext
    ) async throws {
        guard approval.deviceId == context.deviceId else {
            throw JoinPairingStateError.responseMismatch
        }
        let approverKey = try Base64URL.decode(approval.approverPublicKey)
        guard approverKey.count == 32 else {
            throw JoinPairingStateError.responseMismatch
        }
        let sessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: context.keyPair,
            peerPublicKey: approverKey,
            joinRequestId: context.joinRequestId
        )
        let vaultKey = try PairingJoinCrypto.openVaultKey(
            approval.vaultKeyEnvelope,
            sessionKey: sessionKey,
            joinRequestId: context.joinRequestId,
            deviceId: approval.deviceId
        )
        let newCredentials = SyncCredentials(
            endpoint: context.endpoint,
            vaultId: approval.vaultId,
            deviceId: approval.deviceId,
            deviceToken: context.deviceToken,
            vaultKey: vaultKey
        )
        try newCredentials.validate()
        let previousCredentials = try previousCredentialsForPairing()
        do {
            try credentialsStore.save(newCredentials)
            try bindRepository(newCredentials)
        } catch {
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
        defaults.set(context.endpoint.absoluteString, forKey: Self.endpointDefaultsKey)
        try activate(newCredentials, client: context.client)
        runtimeMachine.setConfigured(true)
        publishRuntimeState()
        statusMessage = "已加入同步空间，正在执行首次同步。"
    }

    private func handleJoinCreatorPollFailure(_ error: Error, generation: UUID) async {
        guard joinCreatorPollGeneration == generation else { return }
        if let apiError = error as? SyncAPIError {
            switch apiError {
            case .transport, .invalidHTTPResponse:
                // 临时网络失败不结束 5 分钟配对窗口，下一轮继续尝试。
                actionErrorMessage = "暂时无法连接配对服务，将在配对码有效期内自动重试。请检查网络与 Worker 状态。"
                return
            case .server(let statusCode, let payload, _):
                switch payload.code {
                case "PAIRING_EXPIRED":
                    joinCreatorMachine.expire()
                    joinCreatorContext = nil
                    actionErrorMessage = nil
                    publishJoinCreatorPhase()
                    return
                case "PAIRING_CANCELED":
                    joinCreatorMachine.cancel()
                    joinCreatorContext = nil
                    actionErrorMessage = nil
                    publishJoinCreatorPhase()
                    return
                case "PAIRING_NOT_FOUND":
                    joinCreatorMachine.fail("配对请求无效或已过期，请重新生成配对码。")
                    joinCreatorContext = nil
                    publishJoinCreatorPhase()
                    return
                default:
                    if statusCode == 429 || statusCode >= 500 {
                        actionErrorMessage = "配对服务暂时不可用，将自动重试"
                        return
                    }
                }
            default:
                break
            }
        }
        // 响应不匹配等失败可能发生在 approve 已创建设备之后，先撤销再清理。
        if let context = joinCreatorContext {
            joinCreatorContext = nil
            await revokeTemporaryDevice(
                client: context.client,
                deviceToken: context.deviceToken
            )
        }
        joinCreatorMachine.fail(userFacingMessage(for: error, action: .pairDevice))
        publishJoinCreatorPhase()
    }

    // MARK: - 输入新设备配对码（Path B 批准方）

    func resolveJoinCode(_ rawCode: String) async {
        let code = rawCode.filter(\.isNumber)
        guard code.count == 6 else {
            joinApproverMachine.fail("请输入新设备显示的 6 位数字配对码")
            publishJoinApproverPhase()
            return
        }
        guard connection != nil,
              let credentials,
              let apiClient,
              !isCreatingVault,
              joinApproverPhase.canResolve else { return }
        cancelPairingFlows(except: .pathBApprover)
        actionErrorMessage = nil
        statusMessage = nil
        joinApprovalContext = nil

        do {
            try joinApproverMachine.beginResolving()
            publishJoinApproverPhase()
            let keyPair = try PairingKeyPair.generate()
            let resolved = try await apiClient.resolveJoinRequest(
                ResolveJoinRequest(
                    code: code,
                    publicKey: keyPair.publicKeyBase64URL
                ),
                deviceToken: credentials.deviceToken
            )
            let joinPublicKey = try Base64URL.decode(resolved.joinPublicKey)
            guard joinPublicKey.count == 32 else {
                throw JoinPairingStateError.responseMismatch
            }
            let sessionKey = try PairingJoinCrypto.sessionKey(
                keyPair: keyPair,
                peerPublicKey: joinPublicKey,
                joinRequestId: resolved.joinRequestId
            )
            let verificationCode = try PairingJoinCrypto.verificationCode(
                sessionKey: sessionKey,
                joinRequestId: resolved.joinRequestId,
                creatorPublicKey: joinPublicKey,
                approverPublicKey: keyPair.publicKey
            )
            try joinApproverMachine.didResolve(
                resolved,
                verificationCode: verificationCode,
                expectedApproverPublicKey: keyPair.publicKeyBase64URL
            )
            joinApprovalContext = JoinApprovalContext(
                sessionKey: sessionKey
            )
            publishJoinApproverPhase()
        } catch {
            joinApproverMachine.fail(
                userFacingMessage(for: error, action: .pairDevice)
            )
            joinApprovalContext = nil
            publishJoinApproverPhase()
            logger.error("解析新设备配对码失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func approveJoin() async {
        guard case .awaitingConfirmation = joinApproverPhase,
              let context = joinApprovalContext,
              let credentials,
              let apiClient else { return }
        actionErrorMessage = nil

        do {
            let verification = try joinApproverMachine.beginApproval()
            publishJoinApproverPhase()
            let envelope = try PairingJoinCrypto.sealVaultKey(
                credentials.vaultKey,
                sessionKey: context.sessionKey,
                joinRequestId: verification.joinRequestId,
                deviceId: verification.deviceId
            )
            let approved = try await apiClient.approveJoinRequest(
                joinRequestId: verification.joinRequestId,
                request: PairingConfirmRequest(vaultKeyEnvelope: envelope),
                deviceToken: credentials.deviceToken
            )
            try joinApproverMachine.didApprove(approved)
            joinApprovalContext = nil
            statusMessage = "已批准「\(verification.deviceName)」加入同步空间。"
            publishJoinApproverPhase()
            await refreshDevices()
            requestSync(.manual)
        } catch {
            if case .approving = joinApproverPhase {
                try? joinApproverMachine.cancelApproval()
            }
            actionErrorMessage = userFacingMessage(for: error, action: .pairDevice)
            publishJoinApproverPhase()
            logger.error("批准新设备失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelJoinApproval() {
        joinApprovalContext = nil
        joinApproverMachine.reset()
        actionErrorMessage = nil
        statusMessage = "已取消批准，配对码将在 5 分钟后失效。"
        publishJoinApproverPhase()
    }

    func resetJoinApprover() {
        joinApprovalContext = nil
        joinApproverMachine.reset()
        actionErrorMessage = nil
        publishJoinApproverPhase()
    }

    // MARK: - 设备管理

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
            ).devices.filter { $0.revokedAt == nil }
        } catch {
            actionErrorMessage = userFacingMessage(for: error, action: .loadDevices)
            logger.error("获取设备列表失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    func removeDevice(_ device: DeviceInfo) async {
        guard !device.isCurrent,
              device.id != credentials?.deviceId,
              !cleaningDeviceIDs.contains(device.id),
              let credentials,
              let apiClient else { return }
        cleaningDeviceIDs.insert(device.id)
        defer { cleaningDeviceIDs.remove(device.id) }
        actionErrorMessage = nil
        do {
            _ = try await apiClient.revokeDevice(
                deviceId: device.id,
                deviceToken: credentials.deviceToken
            )
            devices.removeAll { $0.id == device.id }
            await refreshDevices()
        } catch {
            actionErrorMessage = userFacingMessage(for: error, action: .removeDevice)
            logger.error("移除设备失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 当前设备退出同步空间：服务端撤销设备并旋转中继 epoch，本机清除凭据与绑定但保留任务。
    func exitSpace() async {
        guard let storedCredentials = credentials,
              let activeClient = apiClient,
              !isExitingSpace else { return }
        actionErrorMessage = nil
        statusMessage = nil
        isExitingSpace = true
        defer { isExitingSpace = false }
        do {
            _ = try await activeClient.revokeCurrentDevice(
                deviceToken: storedCredentials.deviceToken
            )
        } catch {
            if Self.isDeviceAlreadyRevoked(error) {
                // 服务端已没有当前设备（本机可能已被其它设备移除），继续本地清理。
                logger.notice("服务端已移除当前设备，继续清理本机同步身份")
            } else {
                actionErrorMessage = userFacingMessage(for: error, action: .exitSpace)
                logger.error("退出同步空间失败：\(error.localizedDescription, privacy: .public)")
                return
            }
        }

        syncTask?.cancel()
        syncTask = nil
        pairingPollTask?.cancel()
        pairingPollTask = nil
        joinCreatorPollTask?.cancel()
        joinCreatorPollTask = nil
        shortCodeClaimTask?.cancel()
        shortCodeClaimTask = nil

        if let deleteError = Result(catching: { try credentialsStore.delete() }).failure {
            actionErrorMessage = "已从同步空间移除设备，但本机同步凭据删除失败：\(deleteError.localizedDescription)"
        }
        try? repository.resetSyncBinding()
        credentials = nil
        apiClient = nil
        coordinator = nil
        connection = nil
        devices = []
        pairingContext = nil
        pairingShortCode = nil
        pairingMachine.reset()
        joinCreatorContext = nil
        joinCreatorMachine.reset()
        joinApprovalContext = nil
        joinApproverMachine.reset()
        publishPairingState()
        publishJoinCreatorPhase()
        publishJoinApproverPhase()
        runtimeMachine.setConfigured(false)
        publishRuntimeState()
        statusMessage = "已退出同步空间，本地任务已保留。"
    }

    // MARK: - 配对流程互斥与凭据检查

    private enum PairingFlow {
        case createVault
        case pathAShow
        case pathAClaim
        case pathBCreator
        case pathBApprover
    }

    /// 未配对入口互斥：启动任一流程时取消其它流程的 task/context/state，避免晚到的结果覆盖新身份。
    private func cancelPairingFlows(except exception: PairingFlow) {
        if exception != .pathAShow {
            pairingPollTask?.cancel()
            pairingPollTask = nil
            pairingPollGeneration = nil
            pairingContext = nil
            pairingShortCode = nil
            pairingMachine.reset()
            publishPairingState()
        }
        if exception != .pathAClaim {
            shortCodeClaimTask?.cancel()
            shortCodeClaimTask = nil
            shortCodeClaimGeneration = UUID()
            shortCodeClaimPhase = .idle
            abandonShortCodeClaimRevocation()
        }
        if exception != .pathBCreator {
            joinCreatorPollTask?.cancel()
            joinCreatorPollTask = nil
            joinCreatorPollGeneration = nil
            let context = joinCreatorContext
            joinCreatorContext = nil
            joinCreatorMachine.reset()
            publishJoinCreatorPhase()
            if let context {
                Task { [weak self] in
                    await self?.revokeTemporaryDevice(
                        client: context.client,
                        deviceToken: context.deviceToken
                    )
                    _ = try? await context.client.cancelJoinRequest(
                        joinRequestId: context.joinRequestId,
                        request: JoinResultRequest(joinSecret: context.joinSecret)
                    )
                }
            }
        }
        if exception != .pathBApprover {
            joinApprovalContext = nil
            joinApproverMachine.reset()
            publishJoinApproverPhase()
        }
    }

    /// 保存新身份前确认不会覆盖已存在的合法身份；legacy 无效凭据在 hadLegacySync 时可覆盖。
    private func previousCredentialsForPairing() throws -> SyncCredentials? {
        let stored: SyncCredentials?
        do {
            stored = try credentialsStore.load()
        } catch {
            if SyncLegacyDetector.isLegacyCredentialsError(error), hadLegacySync {
                return nil
            }
            throw error
        }
        guard connection == nil else {
            throw SyncSetupError.credentialsAlreadyStored
        }
        guard let stored else { return nil }
        if (try? stored.validate()) != nil {
            throw SyncSetupError.credentialsAlreadyStored
        }
        guard hadLegacySync else {
            throw SyncSetupError.credentialsAlreadyStored
        }
        return stored
    }

    private static func isDeviceAlreadyRevoked(_ error: Error) -> Bool {
        guard let apiError = error as? SyncAPIError,
              case let .server(statusCode, payload, _) = apiError else {
            return false
        }
        return (statusCode == 401 && payload.code == "INVALID_DEVICE_TOKEN")
            || (statusCode == 403 && payload.code == "DEVICE_REVOKED")
    }

    /// 清理临时设备时 401/403 一律视为设备尚未创建或已失效。
    private static func isIgnorableRevokeError(_ error: Error) -> Bool {
        guard let apiError = error as? SyncAPIError,
              case let .server(statusCode, _, _) = apiError else {
            return false
        }
        return statusCode == 401 || statusCode == 403
    }

    private func abandonShortCodeClaimRevocation() {
        guard let revocation = shortCodeClaimRevocation else { return }
        shortCodeClaimRevocation = nil
        Task { [weak self] in
            await self?.revokeTemporaryDevice(
                client: revocation.client,
                deviceToken: revocation.deviceToken
            )
        }
    }

    private func revokeShortCodeClaimDeviceIfNeeded(generation: UUID) async {
        guard let revocation = shortCodeClaimRevocation,
              revocation.generation == generation else { return }
        shortCodeClaimRevocation = nil
        await revokeTemporaryDevice(
            client: revocation.client,
            deviceToken: revocation.deviceToken
        )
    }

    /// 尽力撤销本次配对使用的临时设备；设备尚未创建时服务端返回 401/403，忽略。
    private func revokeTemporaryDevice(
        client: SyncAPIClient,
        deviceToken: String
    ) async {
        do {
            _ = try await client.revokeCurrentDevice(deviceToken: deviceToken)
        } catch {
            if !Self.isIgnorableRevokeError(error) {
                logger.notice(
                    "撤销未完成配对的临时设备失败：\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func relativeDeadline(expiresAt: Int64, serverTime: Int64) -> Date {
        Date().addingTimeInterval(max(0, Double(expiresAt - serverTime) / 1_000))
    }

    private static func validateResolvedShortCode(_ resolved: ResolveShortCodeData) throws {
        guard !resolved.pairingId.isEmpty,
              !resolved.vaultId.isEmpty,
              resolved.expiresAt > 0,
              (try? Base64URL.decode(resolved.pairingSecret).count) == 32,
              (try? Base64URL.decode(resolved.initiatorPublicKey).count) == 32 else {
            throw SyncSetupError.pairingResponseMismatch
        }
    }

    private static func validateClaim(
        _ claim: PairingClaimData,
        resolved: ResolveShortCodeData,
        claimPublicKey: Data
    ) throws {
        guard claim.pairingId == resolved.pairingId,
              !claim.deviceId.isEmpty,
              claim.status == .claimed,
              claimPublicKey.count == 32 else {
            throw SyncSetupError.pairingResponseMismatch
        }
    }

    private static func validateConfirmedPairing(
        _ result: PairingResultData,
        resolved: ResolveShortCodeData,
        claim: PairingClaimData
    ) throws -> (vaultId: String, envelope: EncryptedEnvelope) {
        guard result.pairingId == resolved.pairingId,
              let vaultId = result.vaultId,
              vaultId == resolved.vaultId,
              let deviceId = result.deviceId,
              deviceId == claim.deviceId,
              let initiatorPublicKey = result.initiatorPublicKey,
              initiatorPublicKey == resolved.initiatorPublicKey,
              let envelope = result.vaultKeyEnvelope,
              !envelope.ciphertext.isEmpty,
              !envelope.nonce.isEmpty else {
            throw SyncSetupError.pairingResponseMismatch
        }
        return (vaultId, envelope)
    }

    // MARK: - 私有装配

    private func resolvedEndpoint() -> URL? {
        if let credentials { return credentials.endpoint }
        if let bundledSyncEndpoint { return bundledSyncEndpoint }
        guard let saved = defaults.string(forKey: Self.endpointDefaultsKey) else {
            return nil
        }
        if case let .ready(endpoint) = SyncEndpointSetupPolicy.assess(saved) {
            return endpoint
        }
        return nil
    }

    private func preparedPairingEndpoint() throws -> URL {
        if resolvedEndpoint() == nil, endpointFieldIsEditable {
            _ = saveManualEndpoint()
        }
        guard let endpoint = resolvedEndpoint() else {
            throw SyncSetupError.missingEndpoint
        }
        return endpoint
    }

    /// 首次绑定或旧绑定不再可用时重建同步元数据，本地任务始终保留。
    private func bindRepository(_ credentials: SyncCredentials) throws {
        let configuration = Self.sqliteConfiguration(for: credentials)
        do {
            try repository.validateSyncBinding(
                vaultId: credentials.vaultId,
                deviceId: credentials.deviceId
            )
            try repository.configureSync(configuration)
        } catch let error as SQLiteRepositoryError {
            guard case .syncIdentityMismatch = error, connection == nil else {
                throw error
            }
            try repository.replaceSyncBinding(with: configuration)
        }
    }

    private func activate(_ credentials: SyncCredentials) throws {
        let client = try apiClientFactory(credentials.endpoint)
        try activate(credentials, client: client)
    }

    private func activate(_ credentials: SyncCredentials, client: SyncAPIClient) throws {
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
                defaults.set(
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
            pairingShortCode = nil
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
                pairingShortCode = nil
            }
            try pairingMachine.didPoll(status, verificationCode: code)
            actionErrorMessage = nil
            if case .expired = pairingMachine.phase {
                pairingContext = nil
                pairingShortCode = nil
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
            pairingShortCode = nil
            actionErrorMessage = nil
            publishPairingState()
            return
        }

        if let apiError = error as? SyncAPIError {
            switch apiError {
            case .transport, .invalidHTTPResponse:
                actionErrorMessage = "暂时无法连接配对服务，将在配对码有效期内自动重试。请检查网络与 Worker 状态。"
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
        pairingShortCode = nil
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

    private func publishJoinCreatorPhase() {
        joinCreatorPhase = joinCreatorMachine.phase
        joinCreatorApprovalPending = joinCreatorMachine.pendingApproval != nil
    }

    private func publishJoinApproverPhase() {
        joinApproverPhase = joinApproverMachine.phase
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
            return "无法连接同步服务。请确认 Worker 已部署、服务地址可在所有设备访问，并检查网络后重试。"
        case .invalidHTTPResponse:
            return "已连接到该地址，但没有收到有效的 HTTP 响应。请确认它是 Woo Todo Worker 的根地址。"
        case .decoding:
            return "服务已响应，但返回格式与当前版本不兼容。请确认没有把网页或其他服务地址当作同步服务。"
        case .encoding:
            return "无法准备\(action.label)请求，请重新启动应用后重试。"
        case .server(let statusCode, let payload, let requestId):
            let requestSuffix = requestId.map { "（请求 ID：\($0)）" } ?? ""
            switch payload.code {
            case "INVALID_INVITE_CODE":
                return "创建邀请码无效或已失效，请向同步服务部署者确认后重试。\(requestSuffix)"
            case "SERVER_MISCONFIGURED" where action == .createVault:
                return "同步服务尚未配置创建邀请码，无法创建空间。请由部署者配置 VAULT_CREATION_INVITE_CODE 后重新部署。\(requestSuffix)"
            case "VAULT_CAPACITY_REACHED":
                return "同步空间已达到存储上限，本地待发送任务仍会保留。请稍后重试。\(requestSuffix)"
            case "VAULT_DEVICE_LIMIT":
                return "同步空间最多允许 4 台设备，请先移除一台旧设备后再配对。\(requestSuffix)"
            case "PAIRING_CODE_USED":
                return "配对码刚被其他设备使用，请在另一台设备重新生成。\(requestSuffix)"
            case "PAIRING_NOT_FOUND":
                return "配对码无效或已过期，请在另一台设备重新生成。\(requestSuffix)"
            case "PAIRING_EXPIRED":
                return "配对码已过期，请重新生成。\(requestSuffix)"
            case "PAIRING_CANCELED":
                return "配对请求已取消，请重新发起。\(requestSuffix)"
            case "PAIRING_CODE_LIMIT":
                return "当前配对码过多，请等待已有配对码过期后再试。\(requestSuffix)"
            case "DEVICE_TOKEN_IN_USE":
                return "设备身份冲突，请重新生成配对码。\(requestSuffix)"
            case "PAIRING_NOT_READY":
                return "配对尚未准备好，请稍后重试。\(requestSuffix)"
            default:
                break
            }
            switch statusCode {
            case 401, 403:
                return "当前设备的同步凭据已失效，服务拒绝\(action.label)。请重新配对。\(requestSuffix)"
            case 404 where action == .createVault,
                 405 where action == .createVault:
                return "找不到 Woo Todo 创建空间接口。请填写 Worker 根地址，末尾不要添加 /v1。\(requestSuffix)"
            case 410 where action == .pairDevice:
                return "配对码已过期，请重新生成。\(requestSuffix)"
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
    var claim: PairingClaimInfo?
    var sessionKey: Data?
}

private struct JoinCreatorContext {
    let endpoint: URL
    let client: SyncAPIClient
    let keyPair: PairingKeyPair
    let deviceToken: String
    let joinRequestId: String
    let joinSecret: String
    let deviceId: String
    var deadline: Date
}

private struct ClaimDeviceRevocation {
    let generation: UUID
    let client: SyncAPIClient
    let deviceToken: String
}

private struct JoinApprovalContext {
    let sessionKey: Data
}

private extension Result {
    var failure: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}

extension JoinCreatorPhase {
    var canCreate: Bool {
        switch self {
        case .idle, .approved, .expired, .canceled, .failed: true
        default: false
        }
    }

    var isWaitingForApproval: Bool {
        switch self {
        case .waitingApproval, .awaitingConfirmation: true
        default: false
        }
    }
}

extension JoinApproverPhase {
    var canResolve: Bool {
        switch self {
        case .idle, .done, .failed: true
        default: false
        }
    }
}
