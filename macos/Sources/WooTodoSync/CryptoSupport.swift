import CryptoKit
import Foundation
import Security

public enum SyncCryptoError: Error, Equatable, LocalizedError {
    case invalidBase64URL
    case invalidKeyLength(Int)
    case invalidNonceLength(Int)
    case ciphertextTooShort
    case randomGenerationFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidBase64URL:
            "数据不是规范的无填充 Base64URL"
        case .invalidKeyLength(let length):
            "AES-256-GCM 密钥必须为 32 字节，当前为 \(length) 字节"
        case .invalidNonceLength(let length):
            "AES-256-GCM nonce 必须为 12 字节，当前为 \(length) 字节"
        case .ciphertextTooShort:
            "密文必须至少包含 16 字节认证标签"
        case .randomGenerationFailed(let status):
            "安全随机数生成失败，状态码：\(status)"
        }
    }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ source: String) throws -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard source.rangeOfCharacter(from: allowed.inverted) == nil,
              !source.contains("="),
              source.count % 4 != 1 else {
            throw SyncCryptoError.invalidBase64URL
        }
        let padding = String(repeating: "=", count: (4 - source.count % 4) % 4)
        let standard = source
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: standard), encode(data) == source else {
            throw SyncCryptoError.invalidBase64URL
        }
        return data
    }
}

public enum SecureRandom {
    public static func bytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard status == errSecSuccess else {
            throw SyncCryptoError.randomGenerationFailed(status)
        }
        return data
    }

    public static func deviceToken() throws -> String {
        Base64URL.encode(try bytes(count: 32))
    }
}

public struct SyncAADMetadata: Equatable, Sendable {
    public let vaultId: String
    public let operationId: String
    public let entityId: String
    public let kind: SyncOperationKind
    public let lamport: Int64
    public let deviceId: String

    public init(
        vaultId: String,
        operationId: String,
        entityId: String,
        kind: SyncOperationKind,
        lamport: Int64,
        deviceId: String
    ) {
        self.vaultId = vaultId
        self.operationId = operationId
        self.entityId = entityId
        self.kind = kind
        self.lamport = lamport
        self.deviceId = deviceId
    }

    public init(vaultId: String, operation: SyncPushOperation, deviceId: String) {
        self.init(
            vaultId: vaultId,
            operationId: operation.opId,
            entityId: operation.entityId,
            kind: operation.kind,
            lamport: operation.lamport,
            deviceId: deviceId
        )
    }

    public init(vaultId: String, operation: SyncPulledOperation) {
        self.init(
            vaultId: vaultId,
            operationId: operation.opId,
            entityId: operation.entityId,
            kind: operation.kind,
            lamport: operation.lamport,
            deviceId: operation.deviceId
        )
    }
}

public enum SyncAAD {
    public static let namespace = "woo-todo-sync-v1"

    public static func canonical(_ metadata: SyncAADMetadata) -> String {
        [
            namespace,
            metadata.vaultId,
            metadata.operationId,
            metadata.entityId,
            metadata.kind.rawValue,
            String(metadata.lamport),
            metadata.deviceId,
        ].joined(separator: "|")
    }

    public static func data(_ metadata: SyncAADMetadata) -> Data {
        Data(canonical(metadata).utf8)
    }
}

public enum AES256GCM {
    public static let keyByteCount = 32
    public static let nonceByteCount = 12
    public static let tagByteCount = 16

    /// wire 格式为独立 nonce，以及“加密正文 || 16 字节 tag”的 ciphertext。
    public static func seal(
        _ plaintext: Data,
        key keyData: Data,
        nonce nonceData: Data? = nil,
        authenticating aad: Data
    ) throws -> EncryptedEnvelope {
        guard keyData.count == keyByteCount else {
            throw SyncCryptoError.invalidKeyLength(keyData.count)
        }
        let actualNonce: Data
        if let nonceData {
            guard nonceData.count == nonceByteCount else {
                throw SyncCryptoError.invalidNonceLength(nonceData.count)
            }
            actualNonce = nonceData
        } else {
            actualNonce = try SecureRandom.bytes(count: nonceByteCount)
        }

        let nonce = try AES.GCM.Nonce(data: actualNonce)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            nonce: nonce,
            authenticating: aad
        )
        var combined = Data(sealed.ciphertext)
        combined.append(contentsOf: sealed.tag)
        return EncryptedEnvelope(
            ciphertext: Base64URL.encode(combined),
            nonce: Base64URL.encode(actualNonce)
        )
    }

    public static func open(
        _ envelope: EncryptedEnvelope,
        key keyData: Data,
        authenticating aad: Data
    ) throws -> Data {
        guard keyData.count == keyByteCount else {
            throw SyncCryptoError.invalidKeyLength(keyData.count)
        }
        let nonceData = try Base64URL.decode(envelope.nonce)
        guard nonceData.count == nonceByteCount else {
            throw SyncCryptoError.invalidNonceLength(nonceData.count)
        }
        let combined = try Base64URL.decode(envelope.ciphertext)
        guard combined.count >= tagByteCount else {
            throw SyncCryptoError.ciphertextTooShort
        }
        let ciphertext = combined.dropLast(tagByteCount)
        let tag = combined.suffix(tagByteCount)
        let sealed = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(
            sealed,
            using: SymmetricKey(data: keyData),
            authenticating: aad
        )
    }
}
