import Foundation

public enum SyncTrigger: String, CaseIterable, Equatable, Sendable {
    case launch
    case localChange
    case wake
    case networkRestored
    case fallback
    case manual
}

public struct SyncRuntimeSnapshot: Equatable, Sendable {
    public let isConfigured: Bool
    public let isRunning: Bool
    public let hasPendingRun: Bool
    public let activeTrigger: SyncTrigger?
    public let lastSuccessfulAt: Date?
    public let lastErrorMessage: String?

    public init(
        isConfigured: Bool,
        isRunning: Bool,
        hasPendingRun: Bool,
        activeTrigger: SyncTrigger?,
        lastSuccessfulAt: Date?,
        lastErrorMessage: String?
    ) {
        self.isConfigured = isConfigured
        self.isRunning = isRunning
        self.hasPendingRun = hasPendingRun
        self.activeTrigger = activeTrigger
        self.lastSuccessfulAt = lastSuccessfulAt
        self.lastErrorMessage = lastErrorMessage
    }
}

/// 合并生命周期内的同步请求，确保任意时刻只有一次同步在运行。
public struct SyncRuntimeStateMachine: Sendable {
    public private(set) var snapshot: SyncRuntimeSnapshot
    private var pendingTrigger: SyncTrigger?

    public init(isConfigured: Bool, lastSuccessfulAt: Date? = nil) {
        self.snapshot = SyncRuntimeSnapshot(
            isConfigured: isConfigured,
            isRunning: false,
            hasPendingRun: false,
            activeTrigger: nil,
            lastSuccessfulAt: lastSuccessfulAt,
            lastErrorMessage: nil
        )
    }

    public mutating func setConfigured(_ isConfigured: Bool) {
        if !isConfigured {
            pendingTrigger = nil
        }
        snapshot = SyncRuntimeSnapshot(
            isConfigured: isConfigured,
            isRunning: snapshot.isRunning && isConfigured,
            hasPendingRun: isConfigured && pendingTrigger != nil,
            activeTrigger: isConfigured ? snapshot.activeTrigger : nil,
            lastSuccessfulAt: snapshot.lastSuccessfulAt,
            lastErrorMessage: snapshot.lastErrorMessage
        )
    }

    /// 返回 true 表示调用方应立即启动一次同步；运行中的重复请求会被合并为一次后续同步。
    @discardableResult
    public mutating func request(_ trigger: SyncTrigger) -> Bool {
        guard snapshot.isConfigured else { return false }
        if snapshot.isRunning {
            pendingTrigger = mergedPendingTrigger(current: pendingTrigger, incoming: trigger)
            snapshot = SyncRuntimeSnapshot(
                isConfigured: true,
                isRunning: true,
                hasPendingRun: true,
                activeTrigger: snapshot.activeTrigger,
                lastSuccessfulAt: snapshot.lastSuccessfulAt,
                lastErrorMessage: snapshot.lastErrorMessage
            )
            return false
        }
        snapshot = SyncRuntimeSnapshot(
            isConfigured: true,
            isRunning: true,
            hasPendingRun: false,
            activeTrigger: trigger,
            lastSuccessfulAt: snapshot.lastSuccessfulAt,
            lastErrorMessage: nil
        )
        return true
    }

    /// 完成当前同步并返回需要紧接着执行的合并请求。
    public mutating func succeed(at date: Date) -> SyncTrigger? {
        finish(lastSuccessfulAt: date, errorMessage: nil)
    }

    /// 网络或服务端失败只记录状态，不影响后续本地操作与再次触发。
    public mutating func fail(message: String) -> SyncTrigger? {
        finish(lastSuccessfulAt: snapshot.lastSuccessfulAt, errorMessage: message)
    }

    private mutating func finish(
        lastSuccessfulAt: Date?,
        errorMessage: String?
    ) -> SyncTrigger? {
        let next = pendingTrigger
        pendingTrigger = nil
        snapshot = SyncRuntimeSnapshot(
            isConfigured: snapshot.isConfigured,
            isRunning: next != nil,
            hasPendingRun: false,
            activeTrigger: next,
            lastSuccessfulAt: lastSuccessfulAt,
            lastErrorMessage: errorMessage
        )
        return next
    }

    private func mergedPendingTrigger(
        current: SyncTrigger?,
        incoming: SyncTrigger
    ) -> SyncTrigger {
        // 用户主动同步优先保留，其余触发语义等价，保留最新原因便于界面说明。
        if current == .manual || incoming == .manual { return .manual }
        return incoming
    }
}

public struct PairingInvitation: Equatable, Sendable {
    public let pairingId: String
    public let expiresAt: Int64

    public init(pairingId: String, expiresAt: Int64) {
        self.pairingId = pairingId
        self.expiresAt = expiresAt
    }
}

public struct PairingVerification: Equatable, Sendable {
    public let pairingId: String
    public let claimedDeviceId: String
    public let deviceName: String
    public let platform: DevicePlatform
    public let code: String
    public let expiresAt: Int64

    public init(
        pairingId: String,
        claimedDeviceId: String,
        deviceName: String,
        platform: DevicePlatform,
        code: String,
        expiresAt: Int64
    ) {
        self.pairingId = pairingId
        self.claimedDeviceId = claimedDeviceId
        self.deviceName = deviceName
        self.platform = platform
        self.code = code
        self.expiresAt = expiresAt
    }
}

public enum InitiatorPairingPhase: Equatable, Sendable {
    case idle
    case creating
    case awaitingClaim(PairingInvitation)
    case awaitingVerification(PairingVerification)
    case confirming(PairingVerification)
    case confirmed(deviceId: String)
    case expired
    case failed(String)
}

public enum InitiatorPairingStateError: Error, Equatable, LocalizedError {
    case invalidTransition
    case responseMismatch
    case invalidVerificationCode

    public var errorDescription: String? {
        switch self {
        case .invalidTransition: "当前配对状态不允许执行此操作"
        case .responseMismatch: "配对服务返回了不匹配的会话或设备"
        case .invalidVerificationCode: "配对核对码必须是六位数字"
        }
    }
}

/// 发起端配对状态机不保存 secret、私钥或 vault key，避免界面状态意外泄露敏感数据。
public struct InitiatorPairingStateMachine: Sendable {
    public private(set) var phase: InitiatorPairingPhase = .idle

    public init() {}

    public mutating func beginCreation() throws {
        guard phase == .idle || isTerminal else {
            throw InitiatorPairingStateError.invalidTransition
        }
        phase = .creating
    }

    public mutating func didCreate(_ data: CreatePairingData) throws {
        guard phase == .creating else {
            throw InitiatorPairingStateError.invalidTransition
        }
        phase = .awaitingClaim(PairingInvitation(
            pairingId: data.pairingId,
            expiresAt: data.expiresAt
        ))
    }

    public mutating func didPoll(
        _ data: PairingStatusData,
        verificationCode: String? = nil
    ) throws {
        guard case .awaitingClaim(let invitation) = phase else {
            throw InitiatorPairingStateError.invalidTransition
        }
        guard invitation.pairingId == data.pairingId else {
            throw InitiatorPairingStateError.responseMismatch
        }
        switch data.status {
        case .open:
            guard data.claim == nil else {
                throw InitiatorPairingStateError.responseMismatch
            }
        case .claimed:
            guard let claim = data.claim, let verificationCode else {
                throw InitiatorPairingStateError.responseMismatch
            }
            guard verificationCode.range(
                of: #"^[0-9]{6}$"#,
                options: .regularExpression
            ) != nil else {
                throw InitiatorPairingStateError.invalidVerificationCode
            }
            phase = .awaitingVerification(PairingVerification(
                pairingId: data.pairingId,
                claimedDeviceId: claim.deviceId,
                deviceName: claim.name,
                platform: claim.platform,
                code: verificationCode,
                expiresAt: data.expiresAt
            ))
        case .expired, .canceled:
            phase = .expired
        case .confirmed:
            // 发起端必须经过本机用户核对后主动 confirm，轮询阶段不能跳过确认。
            throw InitiatorPairingStateError.responseMismatch
        }
    }

    public mutating func beginConfirmation() throws -> PairingVerification {
        guard case .awaitingVerification(let verification) = phase else {
            throw InitiatorPairingStateError.invalidTransition
        }
        phase = .confirming(verification)
        return verification
    }

    public mutating func didConfirm(_ data: PairingConfirmData) throws {
        guard case .confirming(let verification) = phase,
              data.pairingId == verification.pairingId,
              data.deviceId == verification.claimedDeviceId,
              data.status == .confirmed else {
            throw InitiatorPairingStateError.responseMismatch
        }
        phase = .confirmed(deviceId: data.deviceId)
    }

    public mutating func cancelConfirmation() throws {
        guard case .confirming(let verification) = phase else {
            throw InitiatorPairingStateError.invalidTransition
        }
        phase = .awaitingVerification(verification)
    }

    public mutating func expire() {
        phase = .expired
    }

    public mutating func fail(_ message: String) {
        phase = .failed(message)
    }

    public mutating func reset() {
        phase = .idle
    }

    private var isTerminal: Bool {
        switch phase {
        case .confirmed, .expired, .failed: true
        default: false
        }
    }
}
