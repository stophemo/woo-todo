import Foundation

public enum JoinPairingStateError: Error, Equatable, LocalizedError {
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

public struct JoinCreatorInvitation: Equatable, Sendable {
    public let joinRequestId: String
    public let shortCode: String
    public let deviceId: String
    public let expiresAt: Int64

    public init(joinRequestId: String, shortCode: String, deviceId: String, expiresAt: Int64) {
        self.joinRequestId = joinRequestId
        self.shortCode = shortCode
        self.deviceId = deviceId
        self.expiresAt = expiresAt
    }
}

public struct JoinCreatorVerification: Equatable, Sendable {
    public let joinRequestId: String
    public let deviceId: String
    public let code: String
    public let approverPublicKey: String
    public let expiresAt: Int64

    public init(
        joinRequestId: String,
        deviceId: String,
        code: String,
        approverPublicKey: String,
        expiresAt: Int64
    ) {
        self.joinRequestId = joinRequestId
        self.deviceId = deviceId
        self.code = code
        self.approverPublicKey = approverPublicKey
        self.expiresAt = expiresAt
    }
}

/// 服务端已批准、但尚未经过本机用户核对确认的结果。
public struct JoinCreatorApproval: Equatable, Sendable {
    public let vaultId: String
    public let deviceId: String
    public let approverPublicKey: String
    public let vaultKeyEnvelope: EncryptedEnvelope

    public init(
        vaultId: String,
        deviceId: String,
        approverPublicKey: String,
        vaultKeyEnvelope: EncryptedEnvelope
    ) {
        self.vaultId = vaultId
        self.deviceId = deviceId
        self.approverPublicKey = approverPublicKey
        self.vaultKeyEnvelope = vaultKeyEnvelope
    }
}

/// 新设备显示码的创建方状态：idle → creating → waitingApproval → awaitingConfirmation → approved。
public enum JoinCreatorPhase: Equatable, Sendable {
    case idle
    case creating
    case waitingApproval(JoinCreatorInvitation)
    case awaitingConfirmation(JoinCreatorVerification)
    case approved(vaultId: String, deviceId: String)
    case expired
    case canceled
    case failed(String)
}

/// 创建方只保存服务端预分配的设备身份与短码，不保存私钥或 vault key。
/// approved 结果必须先经用户核对确认，不能直接从 waitingApproval 落盘。
public struct JoinCreatorStateMachine: Sendable {
    public private(set) var phase: JoinCreatorPhase = .idle
    public private(set) var pendingApproval: JoinCreatorApproval?
    private var joinRequestId: String?
    private var deviceId: String?

    public init() {}

    public mutating func beginCreation() throws {
        guard phase == .idle || isTerminal else {
            throw JoinPairingStateError.invalidTransition
        }
        phase = .creating
        joinRequestId = nil
        deviceId = nil
        pendingApproval = nil
    }

    public mutating func didCreate(_ data: CreateJoinRequestData) throws {
        guard phase == .creating else {
            throw JoinPairingStateError.invalidTransition
        }
        guard !data.joinRequestId.isEmpty,
              !data.deviceId.isEmpty,
              !data.joinSecret.isEmpty,
              Self.isSixDigitCode(data.shortCode) else {
            throw JoinPairingStateError.responseMismatch
        }
        joinRequestId = data.joinRequestId
        deviceId = data.deviceId
        phase = .waitingApproval(JoinCreatorInvitation(
            joinRequestId: data.joinRequestId,
            shortCode: data.shortCode,
            deviceId: data.deviceId,
            expiresAt: data.expiresAt
        ))
    }

    public mutating func didPoll(
        _ data: JoinResultData,
        verificationCode: String? = nil
    ) throws {
        guard phase.isPolling, let joinRequestId, let deviceId else {
            throw JoinPairingStateError.invalidTransition
        }
        guard data.joinRequestId == joinRequestId, data.deviceId == deviceId else {
            throw JoinPairingStateError.responseMismatch
        }

        switch data.status {
        case .open:
            guard data.vaultId == nil, data.vaultKeyEnvelope == nil else {
                throw JoinPairingStateError.responseMismatch
            }
        case .resolved:
            guard let approverPublicKey = data.approverPublicKey,
                  (try? Base64URL.decode(approverPublicKey).count) == 32,
                  let verificationCode,
                  Self.isSixDigitCode(verificationCode) else {
                throw JoinPairingStateError.responseMismatch
            }
            if case let .awaitingConfirmation(existing) = phase {
                guard existing.approverPublicKey == approverPublicKey else {
                    throw JoinPairingStateError.responseMismatch
                }
            } else {
                phase = .awaitingConfirmation(JoinCreatorVerification(
                    joinRequestId: joinRequestId,
                    deviceId: deviceId,
                    code: verificationCode,
                    approverPublicKey: approverPublicKey,
                    expiresAt: data.expiresAt
                ))
            }
        case .approved:
            guard let vaultId = data.vaultId, !vaultId.isEmpty,
                  let envelope = data.vaultKeyEnvelope,
                  !envelope.ciphertext.isEmpty,
                  !envelope.nonce.isEmpty,
                  let approverPublicKey = data.approverPublicKey,
                  (try? Base64URL.decode(approverPublicKey).count) == 32 else {
                throw JoinPairingStateError.responseMismatch
            }
            let verifiedKey: String
            if case let .awaitingConfirmation(existing) = phase {
                guard existing.approverPublicKey == approverPublicKey else {
                    throw JoinPairingStateError.responseMismatch
                }
                verifiedKey = existing.approverPublicKey
            } else if case .waitingApproval = phase {
                // approved 先到：先用其公钥展示核对码，等待用户显式确认。
                guard let verificationCode, Self.isSixDigitCode(verificationCode) else {
                    throw JoinPairingStateError.responseMismatch
                }
                phase = .awaitingConfirmation(JoinCreatorVerification(
                    joinRequestId: joinRequestId,
                    deviceId: deviceId,
                    code: verificationCode,
                    approverPublicKey: approverPublicKey,
                    expiresAt: data.expiresAt
                ))
                verifiedKey = approverPublicKey
            } else {
                throw JoinPairingStateError.invalidTransition
            }
            pendingApproval = JoinCreatorApproval(
                vaultId: vaultId,
                deviceId: deviceId,
                approverPublicKey: verifiedKey,
                vaultKeyEnvelope: envelope
            )
        case .expired:
            phase = .expired
            pendingApproval = nil
        case .canceled:
            phase = .canceled
            pendingApproval = nil
        }
    }

    /// 用户核对核对码一致后调用；只有这一步会进入 approved。
    public mutating func confirmJoinCreation() throws -> JoinCreatorApproval {
        guard case .awaitingConfirmation = phase,
              let pendingApproval else {
            throw JoinPairingStateError.invalidTransition
        }
        self.pendingApproval = nil
        phase = .approved(
            vaultId: pendingApproval.vaultId,
            deviceId: pendingApproval.deviceId
        )
        return pendingApproval
    }

    public mutating func expire() {
        phase = .expired
        pendingApproval = nil
    }

    public mutating func cancel() {
        guard phase.isPolling || phase == .creating else { return }
        phase = .canceled
        pendingApproval = nil
    }

    public mutating func fail(_ message: String) {
        phase = .failed(message)
        pendingApproval = nil
    }

    public mutating func reset() {
        phase = .idle
        joinRequestId = nil
        deviceId = nil
        pendingApproval = nil
    }

    private var isTerminal: Bool {
        switch phase {
        case .approved, .expired, .canceled, .failed: true
        default: false
        }
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil
    }
}

private extension JoinCreatorPhase {
    var isPolling: Bool {
        switch self {
        case .waitingApproval, .awaitingConfirmation: true
        default: false
        }
    }
}

public struct JoinApproverVerification: Equatable, Sendable {
    public let joinRequestId: String
    public let deviceId: String
    public let deviceName: String
    public let platform: DevicePlatform
    public let joinPublicKey: String
    public let code: String
    public let expiresAt: Int64

    public init(
        joinRequestId: String,
        deviceId: String,
        deviceName: String,
        platform: DevicePlatform,
        joinPublicKey: String,
        code: String,
        expiresAt: Int64
    ) {
        self.joinRequestId = joinRequestId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.joinPublicKey = joinPublicKey
        self.code = code
        self.expiresAt = expiresAt
    }
}

/// 已有设备的批准方状态：idle → resolving → awaitingConfirmation → approving → done。
public enum JoinApproverPhase: Equatable, Sendable {
    case idle
    case resolving
    case awaitingConfirmation(JoinApproverVerification)
    case approving(JoinApproverVerification)
    case done(deviceId: String)
    case failed(String)
}

public struct JoinApproverStateMachine: Sendable {
    public private(set) var phase: JoinApproverPhase = .idle

    public init() {}

    public mutating func beginResolving() throws {
        guard phase == .idle || isTerminal else {
            throw JoinPairingStateError.invalidTransition
        }
        phase = .resolving
    }

    public mutating func didResolve(
        _ data: ResolveJoinRequestData,
        verificationCode: String,
        expectedApproverPublicKey: String
    ) throws {
        guard phase == .resolving else {
            throw JoinPairingStateError.invalidTransition
        }
        guard !data.joinRequestId.isEmpty,
              !data.deviceId.isEmpty,
              data.approverPublicKey == expectedApproverPublicKey,
              (try? Base64URL.decode(data.joinPublicKey).count) == 32,
              Self.isSixDigitCode(verificationCode) else {
            throw JoinPairingStateError.responseMismatch
        }
        phase = .awaitingConfirmation(JoinApproverVerification(
            joinRequestId: data.joinRequestId,
            deviceId: data.deviceId,
            deviceName: data.device.name,
            platform: data.device.platform,
            joinPublicKey: data.joinPublicKey,
            code: verificationCode,
            expiresAt: data.expiresAt
        ))
    }

    public mutating func beginApproval() throws -> JoinApproverVerification {
        guard case let .awaitingConfirmation(verification) = phase else {
            throw JoinPairingStateError.invalidTransition
        }
        phase = .approving(verification)
        return verification
    }

    public mutating func cancelApproval() throws {
        guard case let .approving(verification) = phase else {
            throw JoinPairingStateError.invalidTransition
        }
        phase = .awaitingConfirmation(verification)
    }

    public mutating func didApprove(_ data: ApproveJoinData) throws {
        guard case let .approving(verification) = phase,
              data.joinRequestId == verification.joinRequestId,
              data.deviceId == verification.deviceId,
              data.status.lowercased() == "approved" else {
            throw JoinPairingStateError.responseMismatch
        }
        phase = .done(deviceId: data.deviceId)
    }

    public mutating func fail(_ message: String) {
        phase = .failed(message)
    }

    public mutating func reset() {
        phase = .idle
    }

    private var isTerminal: Bool {
        switch phase {
        case .done, .failed: true
        default: false
        }
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil
    }
}
