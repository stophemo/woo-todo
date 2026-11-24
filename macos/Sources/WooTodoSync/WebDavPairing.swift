import Foundation

public enum WebDavPairingError: Error, Equatable, LocalizedError, Sendable {
    case invalidCode
    case notFound
    case expired
    case conflict
    case pairingCodeConflict
    case malformedFile(String)
    case responseMismatch
    case confirmationRequired

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "配对码必须是六位数字"
        case .notFound: "没有找到匹配的配对码，请在另一台设备重新生成"
        case .expired: "配对码已过期，请重新生成"
        case .conflict: "配对码已被其他设备使用，请重新生成"
        case .pairingCodeConflict: "配对码冲突：同一配对码匹配到多份请求，请在已有设备重新生成配对码"
        case .malformedFile(let message): "配对文件无效：\(message)"
        case .responseMismatch: "配对文件与当前会话不一致，已停止配对"
        case .confirmationRequired: "请先在本机核对六位核对码并确认加入"
        }
    }
}

public enum WebDavPairingProtocol {
    public static let format = "woo-todo-webdav-pairing"
    public static let protocolVersion = 1
    public static let directory = ["v1", "pairing"]
    public static let ttlMilliseconds: Int64 = 5 * 60 * 1_000
    public static let pollIntervalSeconds: Double = 2
}

public enum WebDavPairingTTL {
    /// 配对文件只接受 5 分钟内的有效期，避免恶意文件长期占用配对码。
    public static func isValid(createdAt: Int64, expiresAt: Int64) -> Bool {
        createdAt > 0
            && expiresAt > createdAt
            && expiresAt - createdAt <= WebDavPairingProtocol.ttlMilliseconds
    }

    /// 使用相对 TTL，而不是把远端绝对时间与本机时钟直接比较，以容忍设备时钟偏移。
    public static func relativeDeadline(
        observedAt: Date,
        createdAt: Int64,
        expiresAt: Int64
    ) -> Date {
        observedAt.addingTimeInterval(TimeInterval(expiresAt - createdAt) / 1_000)
    }
}

public enum WebDavPairingFileKind: String, Codable, Equatable, Sendable {
    case offer
    case claim
    case join
    case resolve
    case approval
}

public struct WebDavPairingFileName: Equatable, Sendable {
    public let kind: WebDavPairingFileKind
    public let code: String?
    public let pairingId: String

    public init(kind: WebDavPairingFileKind, code: String?, pairingId: String) {
        self.kind = kind
        self.code = code
        self.pairingId = pairingId
    }

    public var string: String {
        switch kind {
        case .offer, .join:
            return "\(kind.rawValue)-\(code ?? "")-\(pairingId).json"
        case .claim, .resolve, .approval:
            return "\(kind.rawValue)-\(pairingId).json"
        }
    }

    public static func parse(_ name: String) -> WebDavPairingFileName? {
        guard name.hasSuffix(".json"), name.count > ".json".count else { return nil }
        let base = String(name.dropLast(".json".count))
        for kind in [WebDavPairingFileKind.offer, .join, .claim, .resolve, .approval] {
            let prefix = "\(kind.rawValue)-"
            guard base.hasPrefix(prefix) else { continue }
            let remainder = String(base.dropFirst(prefix.count))
            switch kind {
            case .offer, .join:
                guard remainder.count > 7, remainder[remainder.index(remainder.startIndex, offsetBy: 6)] == "-",
                      isSixDigitCode(String(remainder.prefix(6))) else { return nil }
                let code = String(remainder.prefix(6))
                let pairingId = String(remainder.dropFirst(7))
                guard isPairingId(pairingId) else { return nil }
                return WebDavPairingFileName(kind: kind, code: code, pairingId: pairingId)
            case .claim, .resolve, .approval:
                guard isPairingId(remainder) else { return nil }
                return WebDavPairingFileName(kind: kind, code: nil, pairingId: remainder)
            }
        }
        return nil
    }

    public static func isSixDigitCode(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil
    }

    public static func isPairingId(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$",
            options: .regularExpression
        ) != nil
    }
}

// MARK: - 配对文件内容

public struct WebDavPairingEnvelope: Codable, Equatable, Sendable {
    public let ciphertext: String
    public let nonce: String

    public init(ciphertext: String, nonce: String) {
        self.ciphertext = ciphertext
        self.nonce = nonce
    }

    public init(_ envelope: EncryptedEnvelope) {
        self.init(ciphertext: envelope.ciphertext, nonce: envelope.nonce)
    }

    public var encryptedEnvelope: EncryptedEnvelope {
        EncryptedEnvelope(ciphertext: ciphertext, nonce: nonce)
    }

    public init(from decoder: Decoder) throws {
        let container = try PairingJSON.container(
            decoder,
            expected: ["ciphertext", "nonce"]
        )
        self.ciphertext = try container.decode(String.self, forKey: PairingKey("ciphertext"))
        self.nonce = try container.decode(String.self, forKey: PairingKey("nonce"))
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PairingKey.self)
        try container.encode(ciphertext, forKey: PairingKey("ciphertext"))
        try container.encode(nonce, forKey: PairingKey("nonce"))
    }

    public func validate() throws {
        guard (try? Base64URL.decode(nonce).count) == AES256GCM.nonceByteCount,
              (try? Base64URL.decode(ciphertext).count)
                == AES256GCM.keyByteCount + AES256GCM.tagByteCount else {
            throw WebDavPairingError.malformedFile("vaultKeyEnvelope 密文长度无效")
        }
    }
}

public struct WebDavPairingOffer: Equatable, Sendable {
    public let pairingId: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let code: String
    public let publicKey: String
    public let pairingSecret: String
    public let vaultId: String
    public let deviceName: String
    public let platform: DevicePlatform

    public init(
        pairingId: String,
        createdAt: Int64,
        expiresAt: Int64,
        code: String,
        publicKey: String,
        pairingSecret: String,
        vaultId: String,
        deviceName: String,
        platform: DevicePlatform
    ) {
        self.pairingId = pairingId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.code = code
        self.publicKey = publicKey
        self.pairingSecret = pairingSecret
        self.vaultId = vaultId
        self.deviceName = deviceName
        self.platform = platform
    }

    func validate() throws {
        try PairingJSON.validateHeader(
            kind: .offer,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        guard WebDavPairingFileName.isPairingId(pairingId),
              WebDavPairingFileName.isSixDigitCode(code),
              PairingJSON.isPublicKey(publicKey),
              PairingJSON.isSecret(pairingSecret),
              PairingJSON.isVaultId(vaultId),
              PairingJSON.isDeviceName(deviceName) else {
            throw WebDavPairingError.malformedFile("offer 字段无效")
        }
    }
}

public struct WebDavPairingClaim: Equatable, Sendable {
    public let pairingId: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let publicKey: String
    public let deviceId: String
    public let deviceName: String
    public let platform: DevicePlatform

    public init(
        pairingId: String,
        createdAt: Int64,
        expiresAt: Int64,
        publicKey: String,
        deviceId: String,
        deviceName: String,
        platform: DevicePlatform
    ) {
        self.pairingId = pairingId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.publicKey = publicKey
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
    }

    func validate() throws {
        try PairingJSON.validateHeader(
            kind: .claim,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        guard WebDavPairingFileName.isPairingId(pairingId),
              PairingJSON.isPublicKey(publicKey),
              PairingJSON.isDeviceId(deviceId),
              PairingJSON.isDeviceName(deviceName) else {
            throw WebDavPairingError.malformedFile("claim 字段无效")
        }
    }
}

public struct WebDavPairingJoin: Equatable, Sendable {
    public let pairingId: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let code: String
    public let publicKey: String
    public let deviceId: String
    public let deviceName: String
    public let platform: DevicePlatform

    public init(
        pairingId: String,
        createdAt: Int64,
        expiresAt: Int64,
        code: String,
        publicKey: String,
        deviceId: String,
        deviceName: String,
        platform: DevicePlatform
    ) {
        self.pairingId = pairingId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.code = code
        self.publicKey = publicKey
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
    }

    func validate() throws {
        try PairingJSON.validateHeader(
            kind: .join,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        guard WebDavPairingFileName.isPairingId(pairingId),
              WebDavPairingFileName.isSixDigitCode(code),
              PairingJSON.isPublicKey(publicKey),
              PairingJSON.isDeviceId(deviceId),
              PairingJSON.isDeviceName(deviceName) else {
            throw WebDavPairingError.malformedFile("join 字段无效")
        }
    }
}

public struct WebDavPairingResolve: Equatable, Sendable {
    public let pairingId: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let approverPublicKey: String
    public let approverDeviceId: String
    public let approverName: String

    public init(
        pairingId: String,
        createdAt: Int64,
        expiresAt: Int64,
        approverPublicKey: String,
        approverDeviceId: String,
        approverName: String
    ) {
        self.pairingId = pairingId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.approverPublicKey = approverPublicKey
        self.approverDeviceId = approverDeviceId
        self.approverName = approverName
    }

    func validate() throws {
        try PairingJSON.validateHeader(
            kind: .resolve,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        guard WebDavPairingFileName.isPairingId(pairingId),
              PairingJSON.isPublicKey(approverPublicKey),
              PairingJSON.isDeviceId(approverDeviceId),
              PairingJSON.isDeviceName(approverName) else {
            throw WebDavPairingError.malformedFile("resolve 字段无效")
        }
    }
}

public struct WebDavPairingApproval: Equatable, Sendable {
    public let pairingId: String
    public let createdAt: Int64
    public let expiresAt: Int64
    public let deviceId: String
    public let vaultId: String
    public let vaultKeyEnvelope: WebDavPairingEnvelope
    /// Path A 由已有设备写入；与 offer 公钥一致。
    public let initiatorPublicKey: String?
    /// Path B 由已有设备写入；与 resolve 公钥一致。
    public let approverPublicKey: String?

    public init(
        pairingId: String,
        createdAt: Int64,
        expiresAt: Int64,
        deviceId: String,
        vaultId: String,
        vaultKeyEnvelope: WebDavPairingEnvelope,
        initiatorPublicKey: String? = nil,
        approverPublicKey: String? = nil
    ) {
        self.pairingId = pairingId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.deviceId = deviceId
        self.vaultId = vaultId
        self.vaultKeyEnvelope = vaultKeyEnvelope
        self.initiatorPublicKey = initiatorPublicKey
        self.approverPublicKey = approverPublicKey
    }

    func validate() throws {
        try PairingJSON.validateHeader(
            kind: .approval,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
        try vaultKeyEnvelope.validate()
        // Path A 写 offer 公钥；Path B 同时写 join 公钥（initiator）与 resolve 公钥。
        guard WebDavPairingFileName.isPairingId(pairingId),
              PairingJSON.isDeviceId(deviceId),
              PairingJSON.isVaultId(vaultId),
              initiatorPublicKey.map(PairingJSON.isPublicKey) == true,
              approverPublicKey.map(PairingJSON.isPublicKey) ?? true else {
            throw WebDavPairingError.malformedFile("approval 字段无效")
        }
    }
}

public enum WebDavPairingFile: Equatable, Sendable {
    case offer(WebDavPairingOffer)
    case claim(WebDavPairingClaim)
    case join(WebDavPairingJoin)
    case resolve(WebDavPairingResolve)
    case approval(WebDavPairingApproval)

    public var kind: WebDavPairingFileKind {
        switch self {
        case .offer: .offer
        case .claim: .claim
        case .join: .join
        case .resolve: .resolve
        case .approval: .approval
        }
    }

    public var pairingId: String {
        switch self {
        case .offer(let value): value.pairingId
        case .claim(let value): value.pairingId
        case .join(let value): value.pairingId
        case .resolve(let value): value.pairingId
        case .approval(let value): value.pairingId
        }
    }

    public var createdAt: Int64 {
        switch self {
        case .offer(let value): value.createdAt
        case .claim(let value): value.createdAt
        case .join(let value): value.createdAt
        case .resolve(let value): value.createdAt
        case .approval(let value): value.createdAt
        }
    }

    public var expiresAt: Int64 {
        switch self {
        case .offer(let value): value.expiresAt
        case .claim(let value): value.expiresAt
        case .join(let value): value.expiresAt
        case .resolve(let value): value.expiresAt
        case .approval(let value): value.expiresAt
        }
    }

    func validate() throws {
        switch self {
        case .offer(let value): try value.validate()
        case .claim(let value): try value.validate()
        case .join(let value): try value.validate()
        case .resolve(let value): try value.validate()
        case .approval(let value): try value.validate()
        }
    }
}

public enum WebDavPairingFileCodec {
    public static func encode(_ file: WebDavPairingFile) throws -> Data {
        try file.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            switch file {
            case .offer(let value):
                return try encoder.encode(OfferPayload(value))
            case .claim(let value):
                return try encoder.encode(ClaimPayload(value))
            case .join(let value):
                return try encoder.encode(JoinPayload(value))
            case .resolve(let value):
                return try encoder.encode(ResolvePayload(value))
            case .approval(let value):
                return try encoder.encode(ApprovalPayload(value))
            }
        } catch let error as WebDavPairingError {
            throw error
        } catch {
            throw WebDavPairingError.malformedFile(error.localizedDescription)
        }
    }

    public static func decode(_ data: Data) throws -> WebDavPairingFile {
        struct Probe: Decodable {
            let format: String
            let protocolVersion: Int
            let kind: String
        }
        let probe: Probe
        do {
            probe = try JSONDecoder().decode(Probe.self, from: data)
        } catch {
            throw WebDavPairingError.malformedFile("JSON 无法解析")
        }
        guard probe.format == WebDavPairingProtocol.format,
              probe.protocolVersion == WebDavPairingProtocol.protocolVersion,
              let kind = WebDavPairingFileKind(rawValue: probe.kind) else {
            throw WebDavPairingError.malformedFile("格式或协议版本不匹配")
        }
        do {
            switch kind {
            case .offer:
                let payload = try JSONDecoder().decode(OfferPayload.self, from: data)
                let value = payload.value
                try value.validate()
                return .offer(value)
            case .claim:
                let payload = try JSONDecoder().decode(ClaimPayload.self, from: data)
                let value = payload.value
                try value.validate()
                return .claim(value)
            case .join:
                let payload = try JSONDecoder().decode(JoinPayload.self, from: data)
                let value = payload.value
                try value.validate()
                return .join(value)
            case .resolve:
                let payload = try JSONDecoder().decode(ResolvePayload.self, from: data)
                let value = payload.value
                try value.validate()
                return .resolve(value)
            case .approval:
                let payload = try JSONDecoder().decode(ApprovalPayload.self, from: data)
                let value = payload.value
                try value.validate()
                return .approval(value)
            }
        } catch let error as WebDavPairingError {
            throw error
        } catch {
            throw WebDavPairingError.malformedFile(error.localizedDescription)
        }
    }
}

// MARK: - Codable 载荷（严格字段）

private struct OfferPayload: Codable {
    let format: String
    let protocolVersion: Int
    let kind: String
    let pairingId: String
    let createdAt: Int64
    let expiresAt: Int64
    let code: String
    let publicKey: String
    let pairingSecret: String
    let vaultId: String
    let deviceName: String
    let platform: DevicePlatform

    init(_ value: WebDavPairingOffer) {
        format = WebDavPairingProtocol.format
        protocolVersion = WebDavPairingProtocol.protocolVersion
        kind = WebDavPairingFileKind.offer.rawValue
        pairingId = value.pairingId
        createdAt = value.createdAt
        expiresAt = value.expiresAt
        code = value.code
        publicKey = value.publicKey
        pairingSecret = value.pairingSecret
        vaultId = value.vaultId
        deviceName = value.deviceName
        platform = value.platform
    }

    init(from decoder: Decoder) throws {
        let container = try PairingJSON.container(decoder, expected: [
            "format", "protocolVersion", "kind", "pairingId", "createdAt",
            "expiresAt", "code", "publicKey", "pairingSecret", "vaultId",
            "deviceName", "platform",
        ])
        format = try container.decode(String.self, forKey: PairingKey("format"))
        protocolVersion = try container.decode(Int.self, forKey: PairingKey("protocolVersion"))
        kind = try container.decode(String.self, forKey: PairingKey("kind"))
        pairingId = try container.decode(String.self, forKey: PairingKey("pairingId"))
        createdAt = try container.decode(Int64.self, forKey: PairingKey("createdAt"))
        expiresAt = try container.decode(Int64.self, forKey: PairingKey("expiresAt"))
        code = try container.decode(String.self, forKey: PairingKey("code"))
        publicKey = try container.decode(String.self, forKey: PairingKey("publicKey"))
        pairingSecret = try container.decode(String.self, forKey: PairingKey("pairingSecret"))
        vaultId = try container.decode(String.self, forKey: PairingKey("vaultId"))
        deviceName = try container.decode(String.self, forKey: PairingKey("deviceName"))
        platform = try container.decode(DevicePlatform.self, forKey: PairingKey("platform"))
        try PairingJSON.requireHeader(
            format: format,
            protocolVersion: protocolVersion,
            kind: kind,
            expectedKind: .offer
        )
    }

    var value: WebDavPairingOffer {
        WebDavPairingOffer(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            code: code,
            publicKey: publicKey,
            pairingSecret: pairingSecret,
            vaultId: vaultId,
            deviceName: deviceName,
            platform: platform
        )
    }
}

private struct ClaimPayload: Codable {
    let format: String
    let protocolVersion: Int
    let kind: String
    let pairingId: String
    let createdAt: Int64
    let expiresAt: Int64
    let publicKey: String
    let deviceId: String
    let deviceName: String
    let platform: DevicePlatform

    init(_ value: WebDavPairingClaim) {
        format = WebDavPairingProtocol.format
        protocolVersion = WebDavPairingProtocol.protocolVersion
        kind = WebDavPairingFileKind.claim.rawValue
        pairingId = value.pairingId
        createdAt = value.createdAt
        expiresAt = value.expiresAt
        publicKey = value.publicKey
        deviceId = value.deviceId
        deviceName = value.deviceName
        platform = value.platform
    }

    init(from decoder: Decoder) throws {
        let container = try PairingJSON.container(decoder, expected: [
            "format", "protocolVersion", "kind", "pairingId", "createdAt",
            "expiresAt", "publicKey", "deviceId", "deviceName", "platform",
        ])
        format = try container.decode(String.self, forKey: PairingKey("format"))
        protocolVersion = try container.decode(Int.self, forKey: PairingKey("protocolVersion"))
        kind = try container.decode(String.self, forKey: PairingKey("kind"))
        pairingId = try container.decode(String.self, forKey: PairingKey("pairingId"))
        createdAt = try container.decode(Int64.self, forKey: PairingKey("createdAt"))
        expiresAt = try container.decode(Int64.self, forKey: PairingKey("expiresAt"))
        publicKey = try container.decode(String.self, forKey: PairingKey("publicKey"))
        deviceId = try container.decode(String.self, forKey: PairingKey("deviceId"))
        deviceName = try container.decode(String.self, forKey: PairingKey("deviceName"))
        platform = try container.decode(DevicePlatform.self, forKey: PairingKey("platform"))
        try PairingJSON.requireHeader(
            format: format,
            protocolVersion: protocolVersion,
            kind: kind,
            expectedKind: .claim
        )
    }

    var value: WebDavPairingClaim {
        WebDavPairingClaim(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            publicKey: publicKey,
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform
        )
    }
}

private struct JoinPayload: Codable {
    let format: String
    let protocolVersion: Int
    let kind: String
    let pairingId: String
    let createdAt: Int64
    let expiresAt: Int64
    let code: String
    let publicKey: String
    let deviceId: String
    let deviceName: String
    let platform: DevicePlatform

    init(_ value: WebDavPairingJoin) {
        format = WebDavPairingProtocol.format
        protocolVersion = WebDavPairingProtocol.protocolVersion
        kind = WebDavPairingFileKind.join.rawValue
        pairingId = value.pairingId
        createdAt = value.createdAt
        expiresAt = value.expiresAt
        code = value.code
        publicKey = value.publicKey
        deviceId = value.deviceId
        deviceName = value.deviceName
        platform = value.platform
    }

    init(from decoder: Decoder) throws {
        let container = try PairingJSON.container(decoder, expected: [
            "format", "protocolVersion", "kind", "pairingId", "createdAt",
            "expiresAt", "code", "publicKey", "deviceId", "deviceName", "platform",
        ])
        format = try container.decode(String.self, forKey: PairingKey("format"))
        protocolVersion = try container.decode(Int.self, forKey: PairingKey("protocolVersion"))
        kind = try container.decode(String.self, forKey: PairingKey("kind"))
        pairingId = try container.decode(String.self, forKey: PairingKey("pairingId"))
        createdAt = try container.decode(Int64.self, forKey: PairingKey("createdAt"))
        expiresAt = try container.decode(Int64.self, forKey: PairingKey("expiresAt"))
        code = try container.decode(String.self, forKey: PairingKey("code"))
        publicKey = try container.decode(String.self, forKey: PairingKey("publicKey"))
        deviceId = try container.decode(String.self, forKey: PairingKey("deviceId"))
        deviceName = try container.decode(String.self, forKey: PairingKey("deviceName"))
        platform = try container.decode(DevicePlatform.self, forKey: PairingKey("platform"))
        try PairingJSON.requireHeader(
            format: format,
            protocolVersion: protocolVersion,
            kind: kind,
            expectedKind: .join
        )
    }

    var value: WebDavPairingJoin {
        WebDavPairingJoin(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            code: code,
            publicKey: publicKey,
            deviceId: deviceId,
            deviceName: deviceName,
            platform: platform
        )
    }
}

private struct ResolvePayload: Codable {
    let format: String
    let protocolVersion: Int
    let kind: String
    let pairingId: String
    let createdAt: Int64
    let expiresAt: Int64
    let approverPublicKey: String
    let approverDeviceId: String
    let approverName: String

    init(_ value: WebDavPairingResolve) {
        format = WebDavPairingProtocol.format
        protocolVersion = WebDavPairingProtocol.protocolVersion
        kind = WebDavPairingFileKind.resolve.rawValue
        pairingId = value.pairingId
        createdAt = value.createdAt
        expiresAt = value.expiresAt
        approverPublicKey = value.approverPublicKey
        approverDeviceId = value.approverDeviceId
        approverName = value.approverName
    }

    init(from decoder: Decoder) throws {
        let container = try PairingJSON.container(decoder, expected: [
            "format", "protocolVersion", "kind", "pairingId", "createdAt",
            "expiresAt", "approverPublicKey", "approverDeviceId", "approverName",
        ])
        format = try container.decode(String.self, forKey: PairingKey("format"))
        protocolVersion = try container.decode(Int.self, forKey: PairingKey("protocolVersion"))
        kind = try container.decode(String.self, forKey: PairingKey("kind"))
        pairingId = try container.decode(String.self, forKey: PairingKey("pairingId"))
        createdAt = try container.decode(Int64.self, forKey: PairingKey("createdAt"))
        expiresAt = try container.decode(Int64.self, forKey: PairingKey("expiresAt"))
        approverPublicKey = try container.decode(String.self, forKey: PairingKey("approverPublicKey"))
        approverDeviceId = try container.decode(String.self, forKey: PairingKey("approverDeviceId"))
        approverName = try container.decode(String.self, forKey: PairingKey("approverName"))
        try PairingJSON.requireHeader(
            format: format,
            protocolVersion: protocolVersion,
            kind: kind,
            expectedKind: .resolve
        )
    }

    var value: WebDavPairingResolve {
        WebDavPairingResolve(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            approverPublicKey: approverPublicKey,
            approverDeviceId: approverDeviceId,
            approverName: approverName
        )
    }
}

private struct ApprovalPayload: Codable {
    let format: String
    let protocolVersion: Int
    let kind: String
    let pairingId: String
    let createdAt: Int64
    let expiresAt: Int64
    let deviceId: String
    let vaultId: String
    let vaultKeyEnvelope: WebDavPairingEnvelope
    let initiatorPublicKey: String?
    let approverPublicKey: String?

    private enum CodingKeys: String, CodingKey {
        case format, protocolVersion, kind, pairingId, createdAt, expiresAt
        case deviceId, vaultId, vaultKeyEnvelope
        case initiatorPublicKey, approverPublicKey
    }

    init(_ value: WebDavPairingApproval) {
        format = WebDavPairingProtocol.format
        protocolVersion = WebDavPairingProtocol.protocolVersion
        kind = WebDavPairingFileKind.approval.rawValue
        pairingId = value.pairingId
        createdAt = value.createdAt
        expiresAt = value.expiresAt
        deviceId = value.deviceId
        vaultId = value.vaultId
        vaultKeyEnvelope = value.vaultKeyEnvelope
        initiatorPublicKey = value.initiatorPublicKey
        approverPublicKey = value.approverPublicKey
    }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: PairingKey.self)
        var expected = Set([
            "format", "protocolVersion", "kind", "pairingId", "createdAt",
            "expiresAt", "deviceId", "vaultId", "vaultKeyEnvelope",
            "initiatorPublicKey",
        ])
        let hasApprover = keyed.contains(PairingKey("approverPublicKey"))
        guard keyed.contains(PairingKey("initiatorPublicKey")) else {
            throw WebDavPairingError.malformedFile("approval 缺少 initiatorPublicKey")
        }
        if hasApprover {
            expected.insert("approverPublicKey")
        }
        guard Set(keyed.allKeys.map(\.stringValue)) == expected else {
            throw WebDavPairingError.malformedFile("字段不匹配")
        }
        format = try keyed.decode(String.self, forKey: PairingKey("format"))
        protocolVersion = try keyed.decode(Int.self, forKey: PairingKey("protocolVersion"))
        kind = try keyed.decode(String.self, forKey: PairingKey("kind"))
        pairingId = try keyed.decode(String.self, forKey: PairingKey("pairingId"))
        createdAt = try keyed.decode(Int64.self, forKey: PairingKey("createdAt"))
        expiresAt = try keyed.decode(Int64.self, forKey: PairingKey("expiresAt"))
        deviceId = try keyed.decode(String.self, forKey: PairingKey("deviceId"))
        vaultId = try keyed.decode(String.self, forKey: PairingKey("vaultId"))
        vaultKeyEnvelope = try keyed.decode(
            WebDavPairingEnvelope.self,
            forKey: PairingKey("vaultKeyEnvelope")
        )
        initiatorPublicKey = try keyed.decodeIfPresent(
            String.self,
            forKey: PairingKey("initiatorPublicKey")
        )
        approverPublicKey = try keyed.decodeIfPresent(
            String.self,
            forKey: PairingKey("approverPublicKey")
        )
        try PairingJSON.requireHeader(
            format: format,
            protocolVersion: protocolVersion,
            kind: kind,
            expectedKind: .approval
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(kind, forKey: .kind)
        try container.encode(pairingId, forKey: .pairingId)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(deviceId, forKey: .deviceId)
        try container.encode(vaultId, forKey: .vaultId)
        try container.encode(vaultKeyEnvelope, forKey: .vaultKeyEnvelope)
        try container.encodeIfPresent(initiatorPublicKey, forKey: .initiatorPublicKey)
        try container.encodeIfPresent(approverPublicKey, forKey: .approverPublicKey)
    }

    var value: WebDavPairingApproval {
        WebDavPairingApproval(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: expiresAt,
            deviceId: deviceId,
            vaultId: vaultId,
            vaultKeyEnvelope: vaultKeyEnvelope,
            initiatorPublicKey: initiatorPublicKey,
            approverPublicKey: approverPublicKey
        )
    }
}

private struct PairingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { stringValue = String(intValue) }
}

private enum PairingJSON {
    static func container(
        _ decoder: Decoder,
        expected: Set<String>
    ) throws -> KeyedDecodingContainer<PairingKey> {
        let container = try decoder.container(keyedBy: PairingKey.self)
        guard Set(container.allKeys.map(\.stringValue)) == expected else {
            throw WebDavPairingError.malformedFile("字段不匹配")
        }
        return container
    }

    static func requireHeader(
        format: String,
        protocolVersion: Int,
        kind: String,
        expectedKind: WebDavPairingFileKind
    ) throws {
        guard format == WebDavPairingProtocol.format,
              protocolVersion == WebDavPairingProtocol.protocolVersion,
              kind == expectedKind.rawValue else {
            throw WebDavPairingError.malformedFile("格式、版本或 kind 不匹配")
        }
    }

    static func validateHeader(
        kind: WebDavPairingFileKind,
        createdAt: Int64,
        expiresAt: Int64
    ) throws {
        guard WebDavPairingTTL.isValid(createdAt: createdAt, expiresAt: expiresAt) else {
            throw WebDavPairingError.malformedFile("\(kind.rawValue) 有效期无效")
        }
    }

    static func isPublicKey(_ value: String) -> Bool {
        (try? Base64URL.decode(value).count) == 32
    }

    static func isSecret(_ value: String) -> Bool {
        (try? Base64URL.decode(value).count) == 32
    }

    static func isVaultId(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
            options: .regularExpression
        ) != nil
    }

    static func isDeviceId(_ value: String) -> Bool {
        value.range(
            of: "^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$",
            options: .regularExpression
        ) != nil
    }

    static func isDeviceName(_ value: String) -> Bool {
        (1...64).contains(value.unicodeScalars.count)
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

// MARK: - 传输与相对过期跟踪

public protocol WebDavPairingFileTransport: Sendable {
    func ensurePairingDirectory() async throws
    func listPairingFileNames() async throws -> [String]
    func readPairingFile(name: String) async throws -> Data
    func writePairingFile(name: String, data: Data) async throws
    func deletePairingFile(name: String) async throws
}

public extension WebDavPairingFileTransport {
    /// 尽力删除同一 pairingId 的全部配对文件；失败不影响配对结果。
    func deletePairingFiles(matching pairingId: String) async {
        guard let names = try? await listPairingFileNames() else { return }
        for name in names {
            guard let parsed = WebDavPairingFileName.parse(name),
                  parsed.pairingId == pairingId else { continue }
            try? await deletePairingFile(name: name)
            WebDavPairingObservationRegistry.shared.forget(name: name)
        }
    }

    /// 清理本机已经观察过、且超过相对 TTL 的配对文件。
    /// 使用本机首次观察时间加文件自身窗口计算截止时间，避免设备时钟偏移误删。
    /// 无法解码、未知协议版本或字段无效的文件只跳过，不删除。
    func cleanupExpiredPairingFiles(now: Date = Date()) async {
        guard let names = try? await listPairingFileNames() else { return }
        for name in names {
            guard WebDavPairingFileName.parse(name) != nil,
                  let data = try? await readPairingFile(name: name),
                  let file = try? WebDavPairingFileCodec.decode(data),
                  let deadline = WebDavPairingObservationRegistry.shared.deadline(
                      name: name,
                      createdAt: file.createdAt,
                      expiresAt: file.expiresAt,
                      now: now
                  ),
                  now >= deadline else {
                continue
            }
            try? await deletePairingFile(name: name)
            WebDavPairingObservationRegistry.shared.forget(name: name)
        }
    }
}

/// 进程内共享的首次观察时间：同一文件在多个配对会话之间保持相对 TTL 的起点。
final class WebDavPairingObservationRegistry: @unchecked Sendable {
    static let shared = WebDavPairingObservationRegistry()

    private let lock = NSLock()
    private var observedAt: [String: Date] = [:]

    func deadline(
        name: String,
        createdAt: Int64,
        expiresAt: Int64,
        now: Date
    ) -> Date? {
        guard WebDavPairingTTL.isValid(createdAt: createdAt, expiresAt: expiresAt) else {
            return nil
        }
        return lock.withLock {
            let start = observedAt[name] ?? now
            observedAt[name] = start
            return WebDavPairingTTL.relativeDeadline(
                observedAt: start,
                createdAt: createdAt,
                expiresAt: expiresAt
            )
        }
    }

    func forget(name: String) {
        lock.withLock {
            _ = observedAt.removeValue(forKey: name)
        }
    }
}

struct WebDavPairingObservation: Sendable {
    private var observedAt: [String: Date] = [:]

    mutating func deadline(
        name: String,
        createdAt: Int64,
        expiresAt: Int64,
        now: Date
    ) -> Date? {
        guard WebDavPairingTTL.isValid(createdAt: createdAt, expiresAt: expiresAt) else {
            return nil
        }
        let start = observedAt[name] ?? now
        observedAt[name] = start
        return WebDavPairingTTL.relativeDeadline(
            observedAt: start,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
}

enum WebDavPairingRandom {
    static func sixDigitCode() throws -> String {
        let bytes = try SecureRandom.bytes(count: 4)
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        return String(format: "%06u", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func pairingId() throws -> String {
        UUID().uuidString.lowercased()
    }

    static func deviceId() throws -> String {
        UUID().uuidString.lowercased()
    }

    static func vaultId() throws -> String {
        "vault-" + Base64URL.encode(try SecureRandom.bytes(count: 9))
    }
}

func webDavNowMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
}

func webDavDate(milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
}

// MARK: - Path A：已有设备显示码

public enum WebDavPathAShowState: Equatable, Sendable {
    case waiting
    case claimed(
        deviceId: String,
        deviceName: String,
        platform: DevicePlatform,
        verificationCode: String
    )
    case approved
    case expired
}

public final class WebDavPathAShowSession: @unchecked Sendable {
    public let pairingId: String
    public let code: String
    public let deadline: Date

    private let transport: any WebDavPairingFileTransport
    private let identity: WebDavIdentity
    private var keyPair: PairingKeyPair?
    private var pairingSecret: Data?
    private var claim: WebDavPairingClaim?
    private var sessionKey: Data?
    private var observation = WebDavPairingObservation()

    public static func start(
        transport: any WebDavPairingFileTransport,
        identity: WebDavIdentity,
        deviceName: String,
        now: Date = Date()
    ) async throws -> WebDavPathAShowSession {
        try await transport.ensurePairingDirectory()
        await transport.cleanupExpiredPairingFiles(now: now)
        var lastError: Error = WebDavPairingError.conflict
        for _ in 0..<5 {
            let pairingId = try WebDavPairingRandom.pairingId()
            let code = try WebDavPairingRandom.sixDigitCode()
            let keyPair = try PairingKeyPair.generate()
            let pairingSecret = try SecureRandom.bytes(count: 32)
            let createdAt = webDavNowMilliseconds(now)
            let offer = WebDavPairingOffer(
                pairingId: pairingId,
                createdAt: createdAt,
                expiresAt: createdAt + WebDavPairingProtocol.ttlMilliseconds,
                code: code,
                publicKey: keyPair.publicKeyBase64URL,
                pairingSecret: Base64URL.encode(pairingSecret),
                vaultId: identity.vaultId,
                deviceName: deviceName,
                platform: .macos
            )
            let name = WebDavPairingFileName(
                kind: .offer,
                code: code,
                pairingId: pairingId
            ).string
            do {
                try await transport.writePairingFile(
                    name: name,
                    data: WebDavPairingFileCodec.encode(.offer(offer))
                )
                return WebDavPathAShowSession(
                    transport: transport,
                    identity: identity,
                    pairingId: pairingId,
                    code: code,
                    deadline: now.addingTimeInterval(
                        TimeInterval(WebDavPairingProtocol.ttlMilliseconds) / 1_000
                    ),
                    keyPair: keyPair,
                    pairingSecret: pairingSecret
                )
            } catch WebDavError.objectConflict {
                lastError = WebDavPairingError.conflict
                continue
            }
        }
        throw lastError
    }

    private init(
        transport: any WebDavPairingFileTransport,
        identity: WebDavIdentity,
        pairingId: String,
        code: String,
        deadline: Date,
        keyPair: PairingKeyPair,
        pairingSecret: Data
    ) {
        self.transport = transport
        self.identity = identity
        self.pairingId = pairingId
        self.code = code
        self.deadline = deadline
        self.keyPair = keyPair
        self.pairingSecret = pairingSecret
    }

    public func poll(now: Date = Date()) async throws -> WebDavPathAShowState {
        if sessionKey != nil, claim != nil {
            return .claimed(
                deviceId: claim!.deviceId,
                deviceName: claim!.deviceName,
                platform: claim!.platform,
                verificationCode: try verificationCode()
            )
        }
        if now >= deadline {
            await cancel()
            return .expired
        }
        let claimName = WebDavPairingFileName(
            kind: .claim,
            code: nil,
            pairingId: pairingId
        ).string
        let names = try await transport.listPairingFileNames()
        guard names.contains(claimName) else { return .waiting }

        let data: Data
        do {
            data = try await transport.readPairingFile(name: claimName)
        } catch WebDavError.http(404) {
            return .waiting
        }
        guard case let .claim(claim) = try WebDavPairingFileCodec.decode(data) else {
            throw WebDavPairingError.responseMismatch
        }
        guard claim.pairingId == pairingId,
              let deadline = observation.deadline(
                name: claimName,
                createdAt: claim.createdAt,
                expiresAt: claim.expiresAt,
                now: now
              ) else {
            throw WebDavPairingError.responseMismatch
        }
        guard now < deadline else {
            try? await transport.deletePairingFile(name: claimName)
            return .waiting
        }
        guard let keyPair, let pairingSecret else {
            throw WebDavPairingError.responseMismatch
        }
        let sessionKey = try keyPair.sessionKey(
            peerPublicKeyBase64URL: claim.publicKey,
            pairingId: pairingId,
            pairingSecretBase64URL: Base64URL.encode(pairingSecret)
        )
        self.sessionKey = sessionKey
        self.claim = claim
        return .claimed(
            deviceId: claim.deviceId,
            deviceName: claim.deviceName,
            platform: claim.platform,
            verificationCode: try verificationCode()
        )
    }

    /// 用户核对六位核对码一致后，加密传递 vaultKey。
    @discardableResult
    public func approve(now: Date = Date()) async throws -> WebDavPairingApproval {
        guard now < deadline else {
            throw WebDavPairingError.expired
        }
        guard let claim, let sessionKey else {
            throw WebDavPairingError.responseMismatch
        }
        let envelope = try PairingSessionCrypto.sealVaultKey(
            identity.vaultKey,
            sessionKey: sessionKey,
            pairingId: pairingId,
            claimedDeviceId: claim.deviceId
        )
        let createdAt = webDavNowMilliseconds(now)
        let approval = WebDavPairingApproval(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: createdAt + WebDavPairingProtocol.ttlMilliseconds,
            deviceId: claim.deviceId,
            vaultId: identity.vaultId,
            vaultKeyEnvelope: WebDavPairingEnvelope(envelope),
            initiatorPublicKey: keyPair?.publicKeyBase64URL
        )
        let name = WebDavPairingFileName(
            kind: .approval,
            code: nil,
            pairingId: pairingId
        ).string
        try await transport.writePairingFile(
            name: name,
            data: WebDavPairingFileCodec.encode(.approval(approval))
        )
        // 保留 approval 给新设备读取，删除 offer/claim 防止被再次认领。
        try? await transport.deletePairingFile(
            name: WebDavPairingFileName(kind: .offer, code: code, pairingId: pairingId).string
        )
        try? await transport.deletePairingFile(
            name: WebDavPairingFileName(kind: .claim, code: nil, pairingId: pairingId).string
        )
        await transport.cleanupExpiredPairingFiles(now: now)
        return approval
    }

    public func cancel() async {
        try? await transport.deletePairingFile(
            name: WebDavPairingFileName(kind: .offer, code: code, pairingId: pairingId).string
        )
        try? await transport.deletePairingFile(
            name: WebDavPairingFileName(kind: .claim, code: nil, pairingId: pairingId).string
        )
        await transport.cleanupExpiredPairingFiles()
    }

    private func verificationCode() throws -> String {
        guard let sessionKey, let keyPair, let claim else {
            throw WebDavPairingError.responseMismatch
        }
        return try PairingSessionCrypto.verificationCode(
            sessionKey: sessionKey,
            initiatorPublicKey: keyPair.publicKey,
            claimPublicKey: Base64URL.decode(claim.publicKey)
        )
    }
}

// MARK: - Path A：新设备输入码

public enum WebDavPathAClaimState: Equatable, Sendable {
    case waiting
    /// 已读到 approval 并解封身份，等待调用方自动保存身份并清理配对文件。
    case approved(identity: WebDavIdentity)
    case expired
}

/// 加入方在写入 claim 前查看 offer 的公开信息，用于展示对方设备并选择数据基准。
public struct WebDavPathAOfferPreview: Equatable, Sendable {
    public let deviceName: String
    public let platform: DevicePlatform
    public let vaultId: String
    public let deadline: Date

    public init(
        deviceName: String,
        platform: DevicePlatform,
        vaultId: String,
        deadline: Date
    ) {
        self.deviceName = deviceName
        self.platform = platform
        self.vaultId = vaultId
        self.deadline = deadline
    }
}

public final class WebDavPathAClaimSession: @unchecked Sendable {
    public let pairingId: String
    public let code: String
    public let deviceId: String
    public let verificationCode: String
    public let deadline: Date

    private let transport: any WebDavPairingFileTransport
    private let keyPair: PairingKeyPair
    private let vaultId: String
    private let offerPublicKey: Data
    private let sessionKey: Data
    private let claimName: String
    private var observation = WebDavPairingObservation()
    private var pendingIdentity: WebDavIdentity?

    /// 已解封但尚未经本机确认的同步身份。
    public var awaitingIdentity: WebDavIdentity? {
        pendingIdentity
    }

    /// 只读取 offer 的公开字段，不写入 claim；用于加入前的数据基准提示。
    public static func previewOffer(
        transport: any WebDavPairingFileTransport,
        code: String,
        now: Date = Date()
    ) async throws -> WebDavPathAOfferPreview {
        let selected = try await discoverOffer(
            transport: transport,
            code: code,
            now: now
        )
        return WebDavPathAOfferPreview(
            deviceName: selected.offer.deviceName,
            platform: selected.offer.platform,
            vaultId: selected.offer.vaultId,
            deadline: selected.deadline
        )
    }

    public static func start(
        transport: any WebDavPairingFileTransport,
        code: String,
        deviceName: String,
        now: Date = Date()
    ) async throws -> WebDavPathAClaimSession {
        let selected = try await discoverOffer(
            transport: transport,
            code: code,
            now: now
        )

        let keyPair = try PairingKeyPair.generate()
        let deviceId = try WebDavPairingRandom.deviceId()
        let createdAt = webDavNowMilliseconds(now)
        let claim = WebDavPairingClaim(
            pairingId: selected.offer.pairingId,
            createdAt: createdAt,
            expiresAt: createdAt + max(
                1_000,
                webDavNowMilliseconds(selected.deadline) - createdAt
            ),
            publicKey: keyPair.publicKeyBase64URL,
            deviceId: deviceId,
            deviceName: deviceName,
            platform: .macos
        )
        let claimName = WebDavPairingFileName(
            kind: .claim,
            code: nil,
            pairingId: selected.offer.pairingId
        ).string
        do {
            try await transport.writePairingFile(
                name: claimName,
                data: WebDavPairingFileCodec.encode(.claim(claim))
            )
        } catch WebDavError.objectConflict {
            throw WebDavPairingError.conflict
        }

        let offerPublicKey = try Base64URL.decode(selected.offer.publicKey)
        let pairingSecret = try Base64URL.decode(selected.offer.pairingSecret)
        let sessionKey = try keyPair.sessionKey(
            peerPublicKey: offerPublicKey,
            pairingId: selected.offer.pairingId,
            pairingSecret: pairingSecret
        )
        let verificationCode = try PairingSessionCrypto.verificationCode(
            sessionKey: sessionKey,
            initiatorPublicKey: offerPublicKey,
            claimPublicKey: keyPair.publicKey
        )
        return WebDavPathAClaimSession(
            transport: transport,
            pairingId: selected.offer.pairingId,
            code: code,
            deviceId: deviceId,
            verificationCode: verificationCode,
            deadline: selected.deadline,
            keyPair: keyPair,
            vaultId: selected.offer.vaultId,
            offerPublicKey: offerPublicKey,
            sessionKey: sessionKey,
            claimName: claimName
        )
    }

    private struct OfferSelection {
        let offer: WebDavPairingOffer
        let deadline: Date
    }

    private static func discoverOffer(
        transport: any WebDavPairingFileTransport,
        code: String,
        now: Date
    ) async throws -> OfferSelection {
        guard WebDavPairingFileName.isSixDigitCode(code) else {
            throw WebDavPairingError.invalidCode
        }
        try await transport.ensurePairingDirectory()
        await transport.cleanupExpiredPairingFiles(now: now)
        let names = try await transport.listPairingFileNames()
        let offerNames = names.filter {
            guard let parsed = WebDavPairingFileName.parse($0) else { return false }
            return parsed.kind == .offer && parsed.code == code
        }
        guard !offerNames.isEmpty else {
            throw WebDavPairingError.notFound
        }

        var observation = WebDavPairingObservation()
        var candidates: [OfferSelection] = []
        var sawExpired = false
        for name in offerNames {
            let data: Data
            do {
                data = try await transport.readPairingFile(name: name)
            } catch WebDavError.http(404) {
                continue
            }
            guard case let .offer(offer) = try? WebDavPairingFileCodec.decode(data),
                  offer.code == code,
                  WebDavPairingFileName.parse(name)?.pairingId == offer.pairingId,
                  let deadline = observation.deadline(
                    name: name,
                    createdAt: offer.createdAt,
                    expiresAt: offer.expiresAt,
                    now: now
                  ) else {
                continue
            }
            if now >= deadline {
                sawExpired = true
                try? await transport.deletePairingFile(name: name)
                continue
            }
            candidates.append(OfferSelection(offer: offer, deadline: deadline))
        }
        // 同一六位码出现多份有效 offer 时不按远端可控的 createdAt 自动择一，
        // 否则攻击者可以用更新时间戳的假 offer 抢占配对。让用户回到已有设备重新生成。
        guard candidates.count <= 1 else {
            throw WebDavPairingError.pairingCodeConflict
        }
        guard let selected = candidates.first else {
            throw sawExpired ? WebDavPairingError.expired : WebDavPairingError.notFound
        }
        return selected
    }

    private init(
        transport: any WebDavPairingFileTransport,
        pairingId: String,
        code: String,
        deviceId: String,
        verificationCode: String,
        deadline: Date,
        keyPair: PairingKeyPair,
        vaultId: String,
        offerPublicKey: Data,
        sessionKey: Data,
        claimName: String
    ) {
        self.transport = transport
        self.pairingId = pairingId
        self.code = code
        self.deviceId = deviceId
        self.verificationCode = verificationCode
        self.deadline = deadline
        self.keyPair = keyPair
        self.vaultId = vaultId
        self.offerPublicKey = offerPublicKey
        self.sessionKey = sessionKey
        self.claimName = claimName
    }

    public func poll(now: Date = Date()) async throws -> WebDavPathAClaimState {
        if let pendingIdentity {
            return .approved(identity: pendingIdentity)
        }
        let approvalName = WebDavPairingFileName(
            kind: .approval,
            code: nil,
            pairingId: pairingId
        ).string
        let names = try await transport.listPairingFileNames()
        if names.contains(approvalName) {
            let data: Data
            do {
                data = try await transport.readPairingFile(name: approvalName)
            } catch WebDavError.http(404) {
                return try await expirationState(now: now)
            }
            guard case let .approval(approval) = try WebDavPairingFileCodec.decode(data),
                  approval.pairingId == pairingId,
                  approval.deviceId == deviceId,
                  approval.vaultId == vaultId,
                  approval.initiatorPublicKey == Base64URL.encode(offerPublicKey),
                  approval.approverPublicKey == nil,
                  let approvalDeadline = observation.deadline(
                    name: approvalName,
                    createdAt: approval.createdAt,
                    expiresAt: approval.expiresAt,
                    now: now
                  ),
                  now < approvalDeadline else {
                throw WebDavPairingError.responseMismatch
            }
            let vaultKey = try PairingSessionCrypto.openVaultKey(
                approval.vaultKeyEnvelope.encryptedEnvelope,
                sessionKey: sessionKey,
                pairingId: pairingId,
                claimedDeviceId: deviceId
            )
            let identity = WebDavIdentity(
                vaultId: approval.vaultId,
                deviceId: deviceId,
                vaultKey: vaultKey
            )
            try identity.validate()
            // approval 到达并解封后由调用方自动保存身份，不再要求本机再次确认。
            pendingIdentity = identity
            return .approved(identity: identity)
        }
        return try await expirationState(now: now)
    }

    /// 调用方自动保存身份前调用：删除配对文件并返回已解封的身份。
    public func confirm(now: Date = Date()) async throws -> WebDavIdentity {
        guard now < deadline else {
            throw WebDavPairingError.expired
        }
        guard let pendingIdentity else {
            throw WebDavPairingError.confirmationRequired
        }
        await transport.deletePairingFiles(matching: pairingId)
        await transport.cleanupExpiredPairingFiles(now: now)
        self.pendingIdentity = nil
        return pendingIdentity
    }

    public func cancel() async {
        try? await transport.deletePairingFile(name: claimName)
        await transport.deletePairingFiles(matching: pairingId)
        await transport.cleanupExpiredPairingFiles()
    }

    private func expirationState(now: Date) async throws -> WebDavPathAClaimState {
        if now >= deadline {
            await transport.deletePairingFiles(matching: pairingId)
            await transport.cleanupExpiredPairingFiles(now: now)
            return .expired
        }
        return .waiting
    }
}

// MARK: - Path B：新设备显示码

public enum WebDavPathBCreateState: Equatable, Sendable {
    case waiting
    /// 已收到已有设备的 resolve，六位核对码可显示。
    case verification(deviceName: String, code: String)
    /// 已收到并解封 approval，等待调用方自动保存身份并清理配对文件。
    case approved(identity: WebDavIdentity)
    case expired
}

public final class WebDavPathBCreateSession: @unchecked Sendable {
    public let pairingId: String
    public let code: String
    public let deviceId: String
    public let deadline: Date

    /// 新设备临时公钥；用于测试或外部展示，不含私钥。
    public var publicKeyBase64URL: String { keyPair.publicKeyBase64URL }

    private let transport: any WebDavPairingFileTransport
    private let keyPair: PairingKeyPair
    private var approverPublicKey: Data?
    private var approverName: String?
    private var verificationCode: String?
    private var pendingIdentity: WebDavIdentity?
    private var observation = WebDavPairingObservation()

    /// 已解封但尚未经本机确认的同步身份。
    public var awaitingIdentity: WebDavIdentity? {
        pendingIdentity
    }

    public static func start(
        transport: any WebDavPairingFileTransport,
        deviceName: String,
        now: Date = Date()
    ) async throws -> WebDavPathBCreateSession {
        try await transport.ensurePairingDirectory()
        await transport.cleanupExpiredPairingFiles(now: now)
        var lastError: Error = WebDavPairingError.conflict
        for _ in 0..<5 {
            let pairingId = try WebDavPairingRandom.pairingId()
            let code = try WebDavPairingRandom.sixDigitCode()
            let deviceId = try WebDavPairingRandom.deviceId()
            let keyPair = try PairingKeyPair.generate()
            let createdAt = webDavNowMilliseconds(now)
            let join = WebDavPairingJoin(
                pairingId: pairingId,
                createdAt: createdAt,
                expiresAt: createdAt + WebDavPairingProtocol.ttlMilliseconds,
                code: code,
                publicKey: keyPair.publicKeyBase64URL,
                deviceId: deviceId,
                deviceName: deviceName,
                platform: .macos
            )
            let name = WebDavPairingFileName(
                kind: .join,
                code: code,
                pairingId: pairingId
            ).string
            do {
                try await transport.writePairingFile(
                    name: name,
                    data: WebDavPairingFileCodec.encode(.join(join))
                )
                return WebDavPathBCreateSession(
                    transport: transport,
                    pairingId: pairingId,
                    code: code,
                    deviceId: deviceId,
                    deadline: now.addingTimeInterval(
                        TimeInterval(WebDavPairingProtocol.ttlMilliseconds) / 1_000
                    ),
                    keyPair: keyPair
                )
            } catch WebDavError.objectConflict {
                lastError = WebDavPairingError.conflict
                continue
            }
        }
        throw lastError
    }

    private init(
        transport: any WebDavPairingFileTransport,
        pairingId: String,
        code: String,
        deviceId: String,
        deadline: Date,
        keyPair: PairingKeyPair
    ) {
        self.transport = transport
        self.pairingId = pairingId
        self.code = code
        self.deviceId = deviceId
        self.deadline = deadline
        self.keyPair = keyPair
    }

    public func poll(now: Date = Date()) async throws -> WebDavPathBCreateState {
        if let pendingIdentity {
            return .approved(identity: pendingIdentity)
        }
        let resolveName = WebDavPairingFileName(
            kind: .resolve,
            code: nil,
            pairingId: pairingId
        ).string
        let approvalName = WebDavPairingFileName(
            kind: .approval,
            code: nil,
            pairingId: pairingId
        ).string
        let names = try await transport.listPairingFileNames()

        // 到点后仍给最后一次读取 approval 的机会；没有 approval 就按过期处理。
        if now >= deadline, !names.contains(approvalName) {
            await cancel()
            return .expired
        }

        var resolveApproverKey: Data?
        if names.contains(resolveName) {
            let data: Data
            do {
                data = try await transport.readPairingFile(name: resolveName)
            } catch WebDavError.http(404) {
                data = Data()
            }
            if !data.isEmpty,
               case let .resolve(resolve) = try WebDavPairingFileCodec.decode(data) {
                guard resolve.pairingId == pairingId else {
                    throw WebDavPairingError.responseMismatch
                }
                let approverKey = try Base64URL.decode(resolve.approverPublicKey)
                guard approverKey.count == 32 else {
                    throw WebDavPairingError.responseMismatch
                }
                if let existing = approverPublicKey,
                   existing != approverKey {
                    throw WebDavPairingError.responseMismatch
                }
                approverPublicKey = approverKey
                approverName = resolve.approverName
                let sessionKey = try PairingJoinCrypto.sessionKey(
                    keyPair: keyPair,
                    peerPublicKey: approverKey,
                    joinRequestId: pairingId
                )
                verificationCode = try PairingJoinCrypto.verificationCode(
                    sessionKey: sessionKey,
                    joinRequestId: pairingId,
                    creatorPublicKey: keyPair.publicKey,
                    approverPublicKey: approverKey
                )
                resolveApproverKey = approverKey
            }
        }

        if names.contains(approvalName) {
            // 必须先看到 resolve 且 approval 的 approverPublicKey 与之一致；
            // 只有 approval 时不解封、不保存，避免同账号方零交互接管新设备。
            guard let resolveApproverKey, let verificationCode else {
                return await expirationState(now: now)
            }
            let data: Data
            do {
                data = try await transport.readPairingFile(name: approvalName)
            } catch WebDavError.http(404) {
                return await expirationState(now: now)
            }
            guard case let .approval(approval) = try WebDavPairingFileCodec.decode(data),
                  approval.pairingId == pairingId,
                  approval.deviceId == deviceId,
                  approval.initiatorPublicKey == keyPair.publicKeyBase64URL,
                  let approverKey = approval.approverPublicKey.map({ try? Base64URL.decode($0) }),
                  let approverKey,
                  approverKey.count == 32,
                  approverKey == resolveApproverKey,
                  let deadline = observation.deadline(
                    name: approvalName,
                    createdAt: approval.createdAt,
                    expiresAt: approval.expiresAt,
                    now: now
                  ),
                  now < deadline else {
                throw WebDavPairingError.responseMismatch
            }
            let sessionKey = try PairingJoinCrypto.sessionKey(
                keyPair: keyPair,
                peerPublicKey: approverKey,
                joinRequestId: pairingId
            )
            let vaultKey = try PairingJoinCrypto.openVaultKey(
                approval.vaultKeyEnvelope.encryptedEnvelope,
                sessionKey: sessionKey,
                joinRequestId: pairingId,
                deviceId: deviceId
            )
            let identity = WebDavIdentity(
                vaultId: approval.vaultId,
                deviceId: deviceId,
                vaultKey: vaultKey
            )
            try identity.validate()
            // approval 到达并解封后由调用方自动保存身份，不再要求本机再次确认。
            pendingIdentity = identity
            return .approved(identity: identity)
        }

        if let verificationCode, approverPublicKey != nil {
            return .verification(
                deviceName: approverName ?? "已配对设备",
                code: verificationCode
            )
        }
        return await expirationState(now: now)
    }

    /// 调用方自动保存身份前调用：删除配对文件并返回已解封的身份。
    public func confirm(now: Date = Date()) async throws -> WebDavIdentity {
        guard now < deadline else {
            throw WebDavPairingError.expired
        }
        guard let pendingIdentity else {
            throw WebDavPairingError.confirmationRequired
        }
        await transport.deletePairingFiles(matching: pairingId)
        await transport.cleanupExpiredPairingFiles(now: now)
        self.pendingIdentity = nil
        return pendingIdentity
    }

    public func cancel() async {
        try? await transport.deletePairingFile(
            name: WebDavPairingFileName(kind: .join, code: code, pairingId: pairingId).string
        )
        await transport.deletePairingFiles(matching: pairingId)
        await transport.cleanupExpiredPairingFiles()
    }

    private func expirationState(now: Date) async -> WebDavPathBCreateState {
        if now >= deadline {
            await cancel()
            return .expired
        }
        return .waiting
    }
}

// MARK: - Path B：已有设备批准

public final class WebDavPathBApproveSession: @unchecked Sendable {
    public let pairingId: String
    public let deviceId: String
    public let deviceName: String
    public let platform: DevicePlatform
    public let verificationCode: String
    public let deadline: Date

    private let transport: any WebDavPairingFileTransport
    private let vaultId: String
    private let vaultKey: Data
    private let keyPair: PairingKeyPair
    private let initiatorPublicKey: String
    private let joinFileName: String
    private let sessionKey: Data

    public static func start(
        transport: any WebDavPairingFileTransport,
        code: String,
        vaultId: String,
        vaultKey: Data,
        approverDeviceId: String,
        approverName: String,
        now: Date = Date()
    ) async throws -> WebDavPathBApproveSession {
        guard WebDavPairingFileName.isSixDigitCode(code) else {
            throw WebDavPairingError.invalidCode
        }
        try await transport.ensurePairingDirectory()
        await transport.cleanupExpiredPairingFiles(now: now)
        let names = try await transport.listPairingFileNames()
        let joinNames = names.filter {
            guard let parsed = WebDavPairingFileName.parse($0) else { return false }
            return parsed.kind == .join && parsed.code == code
        }
        guard !joinNames.isEmpty else {
            throw WebDavPairingError.notFound
        }

        var observation = WebDavPairingObservation()
        var candidates: [(join: WebDavPairingJoin, deadline: Date, fileName: String)] = []
        var sawExpired = false
        for name in joinNames {
            let data: Data
            do {
                data = try await transport.readPairingFile(name: name)
            } catch WebDavError.http(404) {
                continue
            }
            guard case let .join(join) = try? WebDavPairingFileCodec.decode(data),
                  join.code == code,
                  WebDavPairingFileName.parse(name)?.pairingId == join.pairingId,
                  let deadline = observation.deadline(
                    name: name,
                    createdAt: join.createdAt,
                    expiresAt: join.expiresAt,
                    now: now
                  ) else {
                continue
            }
            if now >= deadline {
                sawExpired = true
                try? await transport.deletePairingFile(name: name)
                continue
            }
            candidates.append((join, deadline, name))
        }
        // 同一六位码出现多份有效 join 时拒绝自动择一，避免攻击者用更新时间戳
        // 的假 join 抢占真实新设备，导致 vaultKey 被封给攻击者。
        guard candidates.count <= 1 else {
            throw WebDavPairingError.pairingCodeConflict
        }
        guard let selected = candidates.first else {
            throw sawExpired ? WebDavPairingError.expired : WebDavPairingError.notFound
        }

        let keyPair = try PairingKeyPair.generate()
        let createdAt = webDavNowMilliseconds(now)
        let resolve = WebDavPairingResolve(
            pairingId: selected.join.pairingId,
            createdAt: createdAt,
            expiresAt: createdAt + max(
                1_000,
                webDavNowMilliseconds(selected.deadline) - createdAt
            ),
            approverPublicKey: keyPair.publicKeyBase64URL,
            approverDeviceId: approverDeviceId,
            approverName: approverName
        )
        let resolveName = WebDavPairingFileName(
            kind: .resolve,
            code: nil,
            pairingId: selected.join.pairingId
        ).string
        do {
            try await transport.writePairingFile(
                name: resolveName,
                data: WebDavPairingFileCodec.encode(.resolve(resolve))
            )
        } catch WebDavError.objectConflict {
            throw WebDavPairingError.conflict
        }

        let joinPublicKey = try Base64URL.decode(selected.join.publicKey)
        let sessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: keyPair,
            peerPublicKey: joinPublicKey,
            joinRequestId: selected.join.pairingId
        )
        let verificationCode = try PairingJoinCrypto.verificationCode(
            sessionKey: sessionKey,
            joinRequestId: selected.join.pairingId,
            creatorPublicKey: joinPublicKey,
            approverPublicKey: keyPair.publicKey
        )
        return WebDavPathBApproveSession(
            transport: transport,
            pairingId: selected.join.pairingId,
            deviceId: selected.join.deviceId,
            deviceName: selected.join.deviceName,
            platform: selected.join.platform,
            verificationCode: verificationCode,
            deadline: selected.deadline,
            vaultId: vaultId,
            vaultKey: vaultKey,
            keyPair: keyPair,
            initiatorPublicKey: Base64URL.encode(joinPublicKey),
            joinFileName: selected.fileName,
            sessionKey: sessionKey
        )
    }

    private init(
        transport: any WebDavPairingFileTransport,
        pairingId: String,
        deviceId: String,
        deviceName: String,
        platform: DevicePlatform,
        verificationCode: String,
        deadline: Date,
        vaultId: String,
        vaultKey: Data,
        keyPair: PairingKeyPair,
        initiatorPublicKey: String,
        joinFileName: String,
        sessionKey: Data
    ) {
        self.transport = transport
        self.pairingId = pairingId
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.platform = platform
        self.verificationCode = verificationCode
        self.deadline = deadline
        self.vaultId = vaultId
        self.vaultKey = vaultKey
        self.keyPair = keyPair
        self.initiatorPublicKey = initiatorPublicKey
        self.joinFileName = joinFileName
        self.sessionKey = sessionKey
    }

    /// 用户核对六位核对码一致后批准新设备。
    @discardableResult
    public func approve(now: Date = Date()) async throws -> WebDavPairingApproval {
        guard now < deadline else {
            throw WebDavPairingError.expired
        }
        let envelope = try PairingJoinCrypto.sealVaultKey(
            vaultKey,
            sessionKey: sessionKey,
            joinRequestId: pairingId,
            deviceId: deviceId
        )
        let createdAt = webDavNowMilliseconds(now)
        let approval = WebDavPairingApproval(
            pairingId: pairingId,
            createdAt: createdAt,
            expiresAt: createdAt + WebDavPairingProtocol.ttlMilliseconds,
            deviceId: deviceId,
            vaultId: vaultId,
            vaultKeyEnvelope: WebDavPairingEnvelope(envelope),
            initiatorPublicKey: initiatorPublicKey,
            approverPublicKey: keyPair.publicKeyBase64URL
        )
        try await transport.writePairingFile(
            name: WebDavPairingFileName(
                kind: .approval,
                code: nil,
                pairingId: pairingId
            ).string,
            data: WebDavPairingFileCodec.encode(.approval(approval))
        )
        try? await transport.deletePairingFile(name: joinFileName)
        await transport.cleanupExpiredPairingFiles(now: now)
        return approval
    }

    public func cancel() async {
        try? await transport.deletePairingFile(
            name: WebDavPairingFileName(kind: .resolve, code: nil, pairingId: pairingId).string
        )
        await transport.cleanupExpiredPairingFiles()
    }
}
