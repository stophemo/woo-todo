import Foundation
import Testing
@testable import WooTodoSync

@Suite("Path B Join 加密向量")
struct PairingJoinCryptoTests {
    @Test("共享 pairingJoin 向量锁定 HKDF、核对码与 envelope")
    func matchesSharedFixture() throws {
        let vector = try loadFixture().pairingJoin
        let creator = try PairingKeyPair(
            privateKey: Base64URL.decode(vector.creatorPrivateKey)
        )
        let approver = try PairingKeyPair(
            privateKey: Base64URL.decode(vector.approverPrivateKey)
        )
        #expect(creator.publicKeyBase64URL == vector.creatorPublicKey)
        #expect(approver.publicKeyBase64URL == vector.approverPublicKey)

        let creatorSessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: creator,
            peerPublicKey: approver.publicKey,
            joinRequestId: vector.joinRequestId
        )
        let approverSessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: approver,
            peerPublicKey: creator.publicKey,
            joinRequestId: vector.joinRequestId
        )
        let expectedSessionKey = try Base64URL.decode(vector.sessionKey)
        #expect(creatorSessionKey == expectedSessionKey)
        #expect(approverSessionKey == expectedSessionKey)

        let verification = try PairingJoinCrypto.verificationCode(
            sessionKey: creatorSessionKey,
            joinRequestId: vector.joinRequestId,
            creatorPublicKey: creator.publicKey,
            approverPublicKey: approver.publicKey
        )
        #expect(verification == vector.verificationCode)

        let vaultKey = try Base64URL.decode(vector.vaultKey)
        let sealed = try PairingJoinCrypto.sealVaultKey(
            vaultKey,
            sessionKey: approverSessionKey,
            joinRequestId: vector.joinRequestId,
            deviceId: vector.deviceId,
            nonce: try Base64URL.decode(vector.vaultKeyEnvelope.nonce)
        )
        #expect(sealed.ciphertext == vector.vaultKeyEnvelope.ciphertext)
        #expect(sealed.nonce == vector.vaultKeyEnvelope.nonce)

        let opened = try PairingJoinCrypto.openVaultKey(
            EncryptedEnvelope(
                ciphertext: vector.vaultKeyEnvelope.ciphertext,
                nonce: vector.vaultKeyEnvelope.nonce
            ),
            sessionKey: creatorSessionKey,
            joinRequestId: vector.joinRequestId,
            deviceId: vector.deviceId
        )
        #expect(opened == vaultKey)
    }

    @Test("Path A 与 Path B 的 envelope AAD 不可混用")
    func rejectsCrossPathEnvelope() throws {
        let vector = try loadFixture().pairingJoin
        let creator = try PairingKeyPair(
            privateKey: Base64URL.decode(vector.creatorPrivateKey)
        )
        let approver = try PairingKeyPair(
            privateKey: Base64URL.decode(vector.approverPrivateKey)
        )
        let sessionKey = try PairingJoinCrypto.sessionKey(
            keyPair: creator,
            peerPublicKey: approver.publicKey,
            joinRequestId: vector.joinRequestId
        )
        #expect(throws: (any Error).self) {
            _ = try PairingJoinCrypto.openVaultKey(
                EncryptedEnvelope(
                    ciphertext: vector.vaultKeyEnvelope.ciphertext,
                    nonce: vector.vaultKeyEnvelope.nonce
                ),
                sessionKey: sessionKey,
                joinRequestId: vector.joinRequestId,
                deviceId: "device-other"
            )
        }
        #expect(throws: (any Error).self) {
            _ = try PairingSessionCrypto.openVaultKey(
                EncryptedEnvelope(
                    ciphertext: vector.vaultKeyEnvelope.ciphertext,
                    nonce: vector.vaultKeyEnvelope.nonce
                ),
                sessionKey: sessionKey,
                pairingId: vector.joinRequestId,
                claimedDeviceId: vector.deviceId
            )
        }
    }

    private func loadFixture() throws -> CryptoFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try JSONDecoder().decode(
            CryptoFixture.self,
            from: Data(
                contentsOf: repositoryRoot
                    .appendingPathComponent("shared")
                    .appendingPathComponent("fixtures")
                    .appendingPathComponent("crypto-vectors.json")
            )
        )
    }
}

private struct CryptoFixture: Decodable {
    let pairingJoin: PairingJoin

    struct PairingJoin: Decodable {
        let joinRequestId: String
        let deviceId: String
        let creatorPrivateKey: String
        let creatorPublicKey: String
        let approverPrivateKey: String
        let approverPublicKey: String
        let sessionKey: String
        let verificationCode: String
        let vaultKey: String
        let vaultKeyEnvelope: Envelope

        struct Envelope: Decodable {
            let ciphertext: String
            let nonce: String
        }
    }
}
