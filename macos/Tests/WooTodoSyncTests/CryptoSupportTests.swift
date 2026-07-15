import Foundation
import Testing
@testable import WooTodoSync

@Suite("同步密码学")
struct CryptoSupportTests {
    @Test("共享 AES golden vector 严格匹配")
    func test共享AESGoldenVector严格匹配() throws {
        let fixture = try loadFixture()
        let vector = try #require(fixture.aes256Gcm.vectors.first)
        let key = try Base64URL.decode(vector.key)
        let nonce = try Base64URL.decode(vector.nonce)
        let aad = try Base64URL.decode(vector.aad)
        let plaintext = try Base64URL.decode(vector.plaintext)
        let rawAADComponents = vector.aadUtf8.split(separator: "|", omittingEmptySubsequences: false)
        let aadComponents = try #require(rawAADComponents.count == 7 ? rawAADComponents : nil)
        let kind = try #require(SyncOperationKind(rawValue: String(aadComponents[4])))
        let lamport = try #require(Int64(aadComponents[5]))
        let metadata = SyncAADMetadata(
            vaultId: String(aadComponents[1]),
            operationId: String(aadComponents[2]),
            entityId: String(aadComponents[3]),
            kind: kind,
            lamport: lamport,
            deviceId: String(aadComponents[6])
        )

        #expect(SyncAAD.canonical(metadata) == vector.aadUtf8)
        #expect(Data(vector.aadUtf8.utf8) == aad)
        #expect(Data(vector.plaintextUtf8.utf8) == plaintext)

        let envelope = try AES256GCM.seal(
            plaintext,
            key: key,
            nonce: nonce,
            authenticating: aad
        )
        #expect(envelope.nonce == vector.nonce)
        #expect(envelope.ciphertext == vector.ciphertext)
        let expectedTag = try Base64URL.decode(vector.authenticationTag)
        let expectedCiphertext = try Base64URL.decode(vector.ciphertext)
        #expect(expectedTag == expectedCiphertext.suffix(AES256GCM.tagByteCount))
        #expect(try AES256GCM.open(envelope, key: key, authenticating: aad) == plaintext)
    }

    @Test("AAD 被篡改时拒绝解密")
    func testAES认证AAD被篡改时拒绝解密() throws {
        let key = Data(repeating: 7, count: AES256GCM.keyByteCount)
        let envelope = try AES256GCM.seal(
            Data("任务正文".utf8),
            key: key,
            nonce: Data(repeating: 3, count: AES256GCM.nonceByteCount),
            authenticating: Data("正确AAD".utf8)
        )
        do {
            _ = try AES256GCM.open(
                envelope,
                key: key,
                authenticating: Data("错误AAD".utf8)
            )
            Issue.record("错误 AAD 不应通过认证")
        } catch {
            // 预期 CryptoKit 拒绝认证。
        }
    }

    @Test("X25519 双方派生相同会话密钥并封装 vault key")
    func testX25519双方派生相同会话密钥并封装VaultKey() throws {
        let initiator = PairingKeyPair.generate()
        let claimant = PairingKeyPair.generate()
        let pairingId = "pairing-test-001"
        let pairingSecret = Data(repeating: 5, count: 32)
        let claimedDeviceId = "device-test-001"
        let initiatorKey = try initiator.sessionKey(
            peerPublicKey: claimant.publicKey,
            pairingId: pairingId,
            pairingSecret: pairingSecret
        )
        let claimantKey = try claimant.sessionKey(
            peerPublicKeyBase64URL: initiator.publicKeyBase64URL,
            pairingId: pairingId,
            pairingSecretBase64URL: Base64URL.encode(pairingSecret)
        )
        #expect(initiatorKey == claimantKey)
        #expect(initiatorKey.count == AES256GCM.keyByteCount)

        let vaultKey = Data((0..<32).map(UInt8.init))
        let envelope = try PairingSessionCrypto.sealVaultKey(
            vaultKey,
            sessionKey: initiatorKey,
            pairingId: pairingId,
            claimedDeviceId: claimedDeviceId,
            nonce: Data(repeating: 9, count: AES256GCM.nonceByteCount)
        )
        #expect(
            try PairingSessionCrypto.openVaultKey(
                envelope,
                sessionKey: claimantKey,
                pairingId: pairingId,
                claimedDeviceId: claimedDeviceId
            ) == vaultKey
        )
    }

    @Test("共享 pairing golden vector 锁定 HKDF、核对码与 vault envelope")
    func test共享PairingGoldenVector() throws {
        let vector = try loadFixture().pairing
        let initiator = try PairingKeyPair(
            privateKey: Base64URL.decode(vector.initiatorPrivateKey)
        )
        let claimant = try PairingKeyPair(
            privateKey: Base64URL.decode(vector.claimPrivateKey)
        )
        let pairingSecret = try Base64URL.decode(vector.pairingSecret)
        let sessionKey = try initiator.sessionKey(
            peerPublicKey: claimant.publicKey,
            pairingId: vector.pairingId,
            pairingSecret: pairingSecret
        )

        #expect(Base64URL.encode(initiator.publicKey) == vector.initiatorPublicKey)
        #expect(Base64URL.encode(claimant.publicKey) == vector.claimPublicKey)
        #expect(
            Base64URL.encode(try initiator.sharedSecret(peerPublicKey: claimant.publicKey))
                == vector.sharedSecret
        )
        #expect(Base64URL.encode(sessionKey) == vector.sessionKey)
        #expect(
            String(decoding: PairingSessionCrypto.hkdfInfo(pairingId: vector.pairingId), as: UTF8.self)
                == vector.hkdfInfoUtf8
        )
        #expect(
            String(
                decoding: PairingSessionCrypto.verificationInput(
                    initiatorPublicKey: initiator.publicKey,
                    claimPublicKey: claimant.publicKey
                ),
                as: UTF8.self
            ) == vector.verificationInputUtf8
        )
        #expect(
            try PairingSessionCrypto.verificationCode(
                sessionKey: sessionKey,
                initiatorPublicKey: initiator.publicKey,
                claimPublicKey: claimant.publicKey
            ) == vector.verificationCode
        )

        let vaultKey = try Base64URL.decode(vector.vaultKey)
        let envelope = try PairingSessionCrypto.sealVaultKey(
            vaultKey,
            sessionKey: sessionKey,
            pairingId: vector.pairingId,
            claimedDeviceId: vector.claimedDeviceId,
            nonce: Base64URL.decode(vector.envelopeNonce)
        )
        #expect(envelope.ciphertext == vector.vaultKeyCiphertext)
        #expect(
            String(
                decoding: PairingSessionCrypto.additionalAuthenticatedData(
                    pairingId: vector.pairingId,
                    claimedDeviceId: vector.claimedDeviceId
                ),
                as: UTF8.self
            ) == vector.envelopeAadUtf8
        )
        #expect(
            try PairingSessionCrypto.openVaultKey(
                envelope,
                sessionKey: sessionKey,
                pairingId: vector.pairingId,
                claimedDeviceId: vector.claimedDeviceId
            ) == vaultKey
        )
    }

    private func loadFixture() throws -> CryptoFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repositoryRoot
            .appendingPathComponent("shared")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("crypto-vectors.json")
        return try JSONDecoder().decode(CryptoFixture.self, from: Data(contentsOf: url))
    }
}

private struct CryptoFixture: Decodable {
    let aes256Gcm: AESFixture
    let pairing: PairingVector
}

private struct PairingVector: Decodable {
    let pairingId: String
    let claimedDeviceId: String
    let initiatorPrivateKey: String
    let initiatorPublicKey: String
    let claimPrivateKey: String
    let claimPublicKey: String
    let sharedSecret: String
    let pairingSecret: String
    let hkdfInfoUtf8: String
    let sessionKey: String
    let verificationInputUtf8: String
    let verificationCode: String
    let vaultKey: String
    let envelopeNonce: String
    let envelopeAadUtf8: String
    let vaultKeyCiphertext: String
}

private struct AESFixture: Decodable {
    let vectors: [AESVector]
}

private struct AESVector: Decodable {
    let key: String
    let nonce: String
    let aad: String
    let aadUtf8: String
    let plaintext: String
    let plaintextUtf8: String
    let ciphertext: String
    let authenticationTag: String
}
