import CryptoKit
import Foundation

/// 新设备显示码 / 已有设备批准的单向 join 配对。
/// 与短码配对使用相同的 X25519 + HKDF + AES-GCM 原语，但使用独立命名空间。
public enum PairingJoinCrypto {
    public static let hkdfNamespace = "woo-todo-pairing-join-v1"
    public static let verificationNamespace = "woo-todo-pairing-code-v1"
    public static let envelopeNamespace = "woo-todo-pair-v1"

    public static func sessionKey(
        keyPair: PairingKeyPair,
        peerPublicKey: Data,
        joinRequestId: String
    ) throws -> Data {
        let shared = try keyPair.sharedSecret(peerPublicKey: peerPublicKey)
        let salt = SHA256.hash(data: Data(
            "\(hkdfNamespace)|salt|\(joinRequestId)".utf8
        ))
        let key = shared.withUnsafeBytes { bytes -> SymmetricKey in
            let input = SymmetricKey(data: Data(bytes))
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input,
                salt: Data(salt),
                info: Data("\(hkdfNamespace)|\(joinRequestId)".utf8),
                outputByteCount: AES256GCM.keyByteCount
            )
        }
        return key.withUnsafeBytes { Data($0) }
    }

    public static func verificationCode(
        sessionKey: Data,
        joinRequestId: String,
        creatorPublicKey: Data,
        approverPublicKey: Data
    ) throws -> String {
        guard sessionKey.count == AES256GCM.keyByteCount else {
            throw PairingKeyError.invalidSessionKey
        }
        let input = Data(
            "\(verificationNamespace)|join|\(joinRequestId)|\(Base64URL.encode(creatorPublicKey))|\(Base64URL.encode(approverPublicKey))".utf8
        )
        let code = HMAC<SHA256>.authenticationCode(
            for: input,
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

    public static func sealVaultKey(
        _ vaultKey: Data,
        sessionKey: Data,
        joinRequestId: String,
        deviceId: String,
        nonce: Data? = nil
    ) throws -> EncryptedEnvelope {
        try AES256GCM.seal(
            vaultKey,
            key: sessionKey,
            nonce: nonce,
            authenticating: aad(joinRequestId: joinRequestId, deviceId: deviceId)
        )
    }

    public static func openVaultKey(
        _ envelope: EncryptedEnvelope,
        sessionKey: Data,
        joinRequestId: String,
        deviceId: String
    ) throws -> Data {
        try AES256GCM.open(
            envelope,
            key: sessionKey,
            authenticating: aad(joinRequestId: joinRequestId, deviceId: deviceId)
        )
    }

    private static func aad(joinRequestId: String, deviceId: String) -> Data {
        Data("\(envelopeNamespace)|join|\(joinRequestId)|\(deviceId)".utf8)
    }
}
