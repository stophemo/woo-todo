import CryptoKit
import Foundation

public enum PairingKeyError: Error, Equatable, LocalizedError {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidPairingSecret
    case invalidSessionKey

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey: "X25519 私钥必须为 32 字节"
        case .invalidPublicKey: "X25519 公钥必须为 32 字节"
        case .invalidPairingSecret: "配对 secret 必须为 32 字节"
        case .invalidSessionKey: "配对 session key 必须为 32 字节"
        }
    }
}

public struct PairingKeyPair: Equatable, Sendable {
    public let privateKey: Data
    public let publicKey: Data

    public init(privateKey: Data) throws {
        guard privateKey.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey) else {
            throw PairingKeyError.invalidPrivateKey
        }
        self.privateKey = privateKey
        self.publicKey = key.publicKey.rawRepresentation
    }

    public static func generate() -> PairingKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        // CryptoKit 生成的 key 始终满足构造条件。
        return try! PairingKeyPair(privateKey: key.rawRepresentation)
    }

    public var publicKeyBase64URL: String {
        Base64URL.encode(publicKey)
    }

    public func sharedSecret(peerPublicKey: Data) throws -> Data {
        guard peerPublicKey.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else {
            throw PairingKeyError.invalidPublicKey
        }
        let own = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let secret = try own.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    public func sessionKey(
        peerPublicKey: Data,
        pairingId: String,
        pairingSecret: Data
    ) throws -> Data {
        guard pairingSecret.count == 32 else {
            throw PairingKeyError.invalidPairingSecret
        }
        guard peerPublicKey.count == 32,
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey) else {
            throw PairingKeyError.invalidPublicKey
        }
        let own = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let secret = try own.sharedSecretFromKeyAgreement(with: peer)
        let key = secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: pairingSecret,
            sharedInfo: PairingSessionCrypto.hkdfInfo(pairingId: pairingId),
            outputByteCount: AES256GCM.keyByteCount
        )
        return key.withUnsafeBytes { Data($0) }
    }

    public func sessionKey(
        peerPublicKeyBase64URL: String,
        pairingId: String,
        pairingSecretBase64URL: String
    ) throws -> Data {
        try sessionKey(
            peerPublicKey: Base64URL.decode(peerPublicKeyBase64URL),
            pairingId: pairingId,
            pairingSecret: Base64URL.decode(pairingSecretBase64URL)
        )
    }
}

public enum PairingSessionCrypto {
    public static let hkdfNamespace = "woo-todo-pairing-v1"
    public static let verificationNamespace = "woo-todo-pairing-code-v1"
    public static let envelopeNamespace = "woo-todo-pair-v1"

    public static func hkdfInfo(pairingId: String) -> Data {
        Data("\(hkdfNamespace)|\(pairingId)".utf8)
    }

    public static func verificationInput(
        initiatorPublicKey: Data,
        claimPublicKey: Data
    ) -> Data {
        Data(
            "\(verificationNamespace)|\(Base64URL.encode(initiatorPublicKey))|\(Base64URL.encode(claimPublicKey))".utf8
        )
    }

    public static func verificationCode(
        sessionKey: Data,
        initiatorPublicKey: Data,
        claimPublicKey: Data
    ) throws -> String {
        guard sessionKey.count == AES256GCM.keyByteCount else {
            throw PairingKeyError.invalidSessionKey
        }
        let code = HMAC<SHA256>.authenticationCode(
            for: verificationInput(
                initiatorPublicKey: initiatorPublicKey,
                claimPublicKey: claimPublicKey
            ),
            using: SymmetricKey(data: sessionKey)
        )
        let bytes = Array(code.prefix(4))
        let value = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return String(
            format: "%06u",
            locale: Locale(identifier: "en_US_POSIX"),
            value % 1_000_000
        )
    }

    public static func additionalAuthenticatedData(
        pairingId: String,
        claimedDeviceId: String
    ) -> Data {
        Data("\(envelopeNamespace)|\(pairingId)|\(claimedDeviceId)".utf8)
    }

    public static func sealVaultKey(
        _ vaultKey: Data,
        sessionKey: Data,
        pairingId: String,
        claimedDeviceId: String,
        nonce: Data? = nil
    ) throws -> EncryptedEnvelope {
        try AES256GCM.seal(
            vaultKey,
            key: sessionKey,
            nonce: nonce,
            authenticating: additionalAuthenticatedData(
                pairingId: pairingId,
                claimedDeviceId: claimedDeviceId
            )
        )
    }

    public static func openVaultKey(
        _ envelope: EncryptedEnvelope,
        sessionKey: Data,
        pairingId: String,
        claimedDeviceId: String
    ) throws -> Data {
        try AES256GCM.open(
            envelope,
            key: sessionKey,
            authenticating: additionalAuthenticatedData(
                pairingId: pairingId,
                claimedDeviceId: claimedDeviceId
            )
        )
    }
}
