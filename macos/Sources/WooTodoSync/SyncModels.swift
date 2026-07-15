import Foundation

public enum DevicePlatform: String, Codable, Sendable {
    case macos
    case android
}

public enum PairingStatus: String, Codable, Sendable {
    case open
    case claimed
    case confirmed
    case expired
    case canceled
}

public enum SyncOperationKind: String, Codable, CaseIterable, Sendable {
    case upsert
    case delete
    case complete
    case pass
    case reorder
}

public struct EncryptedEnvelope: Codable, Equatable, Sendable {
    public let ciphertext: String
    public let nonce: String

    public init(ciphertext: String, nonce: String) {
        self.ciphertext = ciphertext
        self.nonce = nonce
    }
}

public struct DeviceRegistration: Codable, Equatable, Sendable {
    public let name: String
    public let platform: DevicePlatform
    public let publicKey: String?

    public init(name: String, platform: DevicePlatform, publicKey: String? = nil) {
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
    }
}

public struct CreateVaultRequest: Codable, Equatable, Sendable {
    public let device: DeviceRegistration
    public let recoveryEnvelope: EncryptedEnvelope?

    public init(device: DeviceRegistration, recoveryEnvelope: EncryptedEnvelope? = nil) {
        self.device = device
        self.recoveryEnvelope = recoveryEnvelope
    }
}

public struct CreatedDevice: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: DevicePlatform
    public let token: String
}

public struct CreateVaultData: Codable, Equatable, Sendable {
    public let vaultId: String
    public let device: CreatedDevice
    public let serverTime: Int64
}

public struct CreatePairingRequest: Codable, Equatable, Sendable {
    public let publicKey: String

    public init(publicKey: String) {
        self.publicKey = publicKey
    }
}

public struct CreatePairingData: Codable, Equatable, Sendable {
    public let pairingId: String
    public let pairingSecret: String
    public let initiatorPublicKey: String
    public let expiresAt: Int64
    public let serverTime: Int64
}

public struct PairingClaimRequest: Codable, Equatable, Sendable {
    public let pairingSecret: String
    public let deviceToken: String
    public let device: PairingDeviceRegistration

    public init(pairingSecret: String, deviceToken: String, device: PairingDeviceRegistration) {
        self.pairingSecret = pairingSecret
        self.deviceToken = deviceToken
        self.device = device
    }
}

public struct PairingDeviceRegistration: Codable, Equatable, Sendable {
    public let name: String
    public let platform: DevicePlatform
    public let publicKey: String

    public init(name: String, platform: DevicePlatform, publicKey: String) {
        self.name = name
        self.platform = platform
        self.publicKey = publicKey
    }
}

public struct PairingClaimData: Codable, Equatable, Sendable {
    public let pairingId: String
    public let status: PairingStatus
    public let deviceId: String
    public let expiresAt: Int64
}

public struct PairingClaimInfo: Codable, Equatable, Sendable {
    public let deviceId: String
    public let name: String
    public let platform: DevicePlatform
    public let publicKey: String
    public let claimedAt: Int64
}

public struct PairingStatusData: Codable, Equatable, Sendable {
    public let pairingId: String
    public let status: PairingStatus
    public let expiresAt: Int64
    public let claim: PairingClaimInfo?
}

public struct PairingConfirmRequest: Codable, Equatable, Sendable {
    public let vaultKeyEnvelope: EncryptedEnvelope

    public init(vaultKeyEnvelope: EncryptedEnvelope) {
        self.vaultKeyEnvelope = vaultKeyEnvelope
    }
}

public struct PairingConfirmData: Codable, Equatable, Sendable {
    public let pairingId: String
    public let status: PairingStatus
    public let deviceId: String
}

public struct PairingResultRequest: Codable, Equatable, Sendable {
    public let pairingSecret: String
    public let deviceToken: String

    public init(pairingSecret: String, deviceToken: String) {
        self.pairingSecret = pairingSecret
        self.deviceToken = deviceToken
    }
}

public struct PairingResultData: Codable, Equatable, Sendable {
    public let pairingId: String
    public let status: PairingStatus
    public let vaultId: String?
    public let deviceId: String?
    public let initiatorPublicKey: String?
    public let vaultKeyEnvelope: EncryptedEnvelope?
    public let expiresAt: Int64

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pairingId = try container.decode(String.self, forKey: .pairingId)
        self.status = try container.decode(PairingStatus.self, forKey: .status)
        self.vaultId = try container.decodeIfPresent(String.self, forKey: .vaultId)
        self.deviceId = try container.decodeIfPresent(String.self, forKey: .deviceId)
        self.initiatorPublicKey = try container.decodeIfPresent(String.self, forKey: .initiatorPublicKey)
        self.vaultKeyEnvelope = try container.decodeIfPresent(
            EncryptedEnvelope.self,
            forKey: .vaultKeyEnvelope
        )
        self.expiresAt = try container.decode(Int64.self, forKey: .expiresAt)

        switch status {
        case .claimed:
            guard vaultId == nil, deviceId == nil, initiatorPublicKey == nil,
                  vaultKeyEnvelope == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "claimed 配对结果不得携带确认字段"
                )
            }
        case .confirmed:
            guard vaultId != nil, deviceId != nil, initiatorPublicKey != nil,
                  vaultKeyEnvelope != nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .status,
                    in: container,
                    debugDescription: "confirmed 配对结果缺少确认字段"
                )
            }
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .status,
                in: container,
                debugDescription: "配对 result 只允许 claimed 或 confirmed"
            )
        }
    }
}

public struct SyncPushOperation: Codable, Equatable, Sendable {
    public let opId: String
    public let entityId: String
    public let kind: SyncOperationKind
    public let lamport: Int64
    public let ciphertext: String
    public let nonce: String

    public init(
        opId: String,
        entityId: String,
        kind: SyncOperationKind,
        lamport: Int64,
        ciphertext: String,
        nonce: String
    ) {
        self.opId = opId
        self.entityId = entityId
        self.kind = kind
        self.lamport = lamport
        self.ciphertext = ciphertext
        self.nonce = nonce
    }
}

public struct SyncRequest: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let ack: Int64?
    public let pullLimit: Int?
    public let push: [SyncPushOperation]

    public init(
        cursor: Int64,
        ack: Int64? = nil,
        pullLimit: Int? = nil,
        push: [SyncPushOperation]
    ) {
        self.cursor = cursor
        self.ack = ack
        self.pullLimit = pullLimit
        self.push = push
    }
}

public struct SyncPushSummary: Codable, Equatable, Sendable {
    public let received: Int
    public let inserted: Int
    public let duplicates: Int

    public init(received: Int, inserted: Int, duplicates: Int) {
        self.received = received
        self.inserted = inserted
        self.duplicates = duplicates
    }
}

public struct SyncPulledOperation: Codable, Equatable, Sendable {
    public let serverSeq: Int64
    public let opId: String
    public let deviceId: String
    public let entityId: String
    public let kind: SyncOperationKind
    public let lamport: Int64
    public let ciphertext: String
    public let nonce: String
    public let createdAt: Int64

    public init(
        serverSeq: Int64,
        opId: String,
        deviceId: String,
        entityId: String,
        kind: SyncOperationKind,
        lamport: Int64,
        ciphertext: String,
        nonce: String,
        createdAt: Int64
    ) {
        self.serverSeq = serverSeq
        self.opId = opId
        self.deviceId = deviceId
        self.entityId = entityId
        self.kind = kind
        self.lamport = lamport
        self.ciphertext = ciphertext
        self.nonce = nonce
        self.createdAt = createdAt
    }
}

public struct SyncData: Codable, Equatable, Sendable {
    public let push: SyncPushSummary
    public let pull: [SyncPulledOperation]
    public let cursor: Int64
    public let hasMore: Bool
    public let serverTime: Int64

    public init(
        push: SyncPushSummary,
        pull: [SyncPulledOperation],
        cursor: Int64,
        hasMore: Bool,
        serverTime: Int64
    ) {
        self.push = push
        self.pull = pull
        self.cursor = cursor
        self.hasMore = hasMore
        self.serverTime = serverTime
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: DevicePlatform
    public let publicKey: String?
    public let createdAt: Int64
    public let lastSeenAt: Int64?
    public let revokedAt: Int64?
    public let isCurrent: Bool
}

public struct DeviceListData: Codable, Equatable, Sendable {
    public let devices: [DeviceInfo]
}

public struct RevokeDeviceData: Codable, Equatable, Sendable {
    public let deviceId: String
    public let revokedAt: Int64
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析服务端错误详情"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public struct ServerErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]?

    public init(code: String, message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}
