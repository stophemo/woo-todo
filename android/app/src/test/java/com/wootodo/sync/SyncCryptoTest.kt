package com.wootodo.sync

import java.nio.charset.StandardCharsets
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncCryptoTest {
    @Test
    fun `共享AES golden向量严格匹配`() {
        val vector = fixture()
            .getJSONObject("aes256Gcm")
            .getJSONArray("vectors")
            .getJSONObject(0)
        val key = Base64Url.decode(vector.getString("key"))
        val nonce = Base64Url.decode(vector.getString("nonce"))
        val aad = Base64Url.decode(vector.getString("aad"))
        val plaintext = Base64Url.decode(vector.getString("plaintext"))

        val envelope = Aes256Gcm.seal(plaintext, key, nonce, aad)
        assertEquals(vector.getString("ciphertext"), envelope.ciphertext)
        assertEquals(vector.getString("nonce"), envelope.nonce)
        assertEquals(vector.getString("aadUtf8"), String(aad, StandardCharsets.UTF_8))
        assertEquals(
            vector.getString("plaintextUtf8"),
            String(plaintext, StandardCharsets.UTF_8),
        )
        assertArrayEquals(plaintext, Aes256Gcm.open(envelope, key, aad))
    }

    @Test
    fun `同步AAD绑定全部操作元数据`() {
        assertEquals(
            "woo-todo-sync-v1|vault-demo|op-demo-001|task-demo-001|upsert|42|device-demo-001",
            SyncAad.canonical(
                vaultId = "vault-demo",
                operationId = "op-demo-001",
                entityId = "task-demo-001",
                kind = SyncOperationKind.UPSERT,
                lamport = 42,
                deviceId = "device-demo-001",
            ),
        )
    }

    @Test
    fun `AES拒绝被篡改的AAD`() {
        val key = ByteArray(32) { 7 }
        val envelope = Aes256Gcm.seal(
            "任务正文".toByteArray(StandardCharsets.UTF_8),
            key,
            ByteArray(12) { 3 },
            "正确AAD".toByteArray(StandardCharsets.UTF_8),
        )

        assertThrows(SyncCryptoException::class.java) {
            Aes256Gcm.open(envelope, key, "错误AAD".toByteArray(StandardCharsets.UTF_8))
        }
    }

    @Test
    fun `X25519双方派生相同HKDF密钥和六位核对码`() {
        val initiator = PairingKeyPair.generate()
        val claimant = PairingKeyPair.generate()
        val pairingId = "pairing-test-001"
        val pairingSecret = ByteArray(32) { (it + 1).toByte() }
        val first = initiator.sessionKey(claimant.publicKey, pairingId, pairingSecret)
        val second = claimant.sessionKey(
            initiator.publicKeyBase64Url,
            pairingId,
            Base64Url.encode(pairingSecret),
        )

        assertArrayEquals(first, second)
        assertEquals(32, first.size)
        val firstCode = PairingSessionCrypto.verificationCode(
            first,
            initiator.publicKey,
            claimant.publicKey,
        )
        assertEquals(
            firstCode,
            PairingSessionCrypto.verificationCode(
                second,
                initiator.publicKey,
                claimant.publicKey,
            ),
        )
        assertTrue(firstCode.matches(Regex("^[0-9]{6}$")))

        val vaultKey = ByteArray(32) { it.toByte() }
        val claimedDeviceId = "device-android-test"
        val envelope = PairingSessionCrypto.sealVaultKey(
            vaultKey,
            first,
            pairingId,
            claimedDeviceId,
            ByteArray(12) { 9 },
        )
        assertArrayEquals(
            vaultKey,
            PairingSessionCrypto.openVaultKey(envelope, second, pairingId, claimedDeviceId),
        )
        assertThrows(SyncCryptoException::class.java) {
            PairingSessionCrypto.openVaultKey(envelope, second, pairingId, "other-device")
        }
    }

    @Test
    fun `共享Pairing golden向量严格匹配`() {
        val vector = fixture().getJSONObject("pairing")
        val pairingId = vector.getString("pairingId")
        val claimedDeviceId = vector.getString("claimedDeviceId")
        val initiator = PairingKeyPair.fromPrivateKey(
            Base64Url.decode(vector.getString("initiatorPrivateKey")),
        )
        val claimant = PairingKeyPair.fromPrivateKey(
            Base64Url.decode(vector.getString("claimPrivateKey")),
        )
        val pairingSecret = Base64Url.decode(vector.getString("pairingSecret"))

        assertEquals(vector.getString("initiatorPublicKey"), initiator.publicKeyBase64Url)
        assertEquals(vector.getString("claimPublicKey"), claimant.publicKeyBase64Url)
        assertEquals(
            vector.getString("sharedSecret"),
            Base64Url.encode(initiator.sharedSecret(claimant.publicKey)),
        )

        val sessionKey = initiator.sessionKey(claimant.publicKey, pairingId, pairingSecret)
        assertEquals(vector.getString("sessionKey"), Base64Url.encode(sessionKey))
        assertEquals(
            vector.getString("hkdfInfoUtf8"),
            String(PairingSessionCrypto.hkdfInfo(pairingId), StandardCharsets.UTF_8),
        )
        assertEquals(
            vector.getString("verificationInputUtf8"),
            String(
                PairingSessionCrypto.verificationInput(
                    initiator.publicKey,
                    claimant.publicKey,
                ),
                StandardCharsets.UTF_8,
            ),
        )
        assertEquals(
            vector.getString("verificationCode"),
            PairingSessionCrypto.verificationCode(
                sessionKey,
                initiator.publicKey,
                claimant.publicKey,
            ),
        )

        val envelope = PairingSessionCrypto.sealVaultKey(
            vaultKey = Base64Url.decode(vector.getString("vaultKey")),
            sessionKey = sessionKey,
            pairingId = pairingId,
            claimedDeviceId = claimedDeviceId,
            nonce = Base64Url.decode(vector.getString("envelopeNonce")),
        )
        assertEquals(
            vector.getString("envelopeAadUtf8"),
            String(PairingSessionCrypto.aad(pairingId, claimedDeviceId), StandardCharsets.UTF_8),
        )
        assertEquals(vector.getString("vaultKeyCiphertext"), envelope.ciphertext)
    }

    @Test
    fun `Base64URL拒绝padding和非规范输入`() {
        assertThrows(SyncCryptoException::class.java) { Base64Url.decode("AA==") }
        assertThrows(SyncCryptoException::class.java) { Base64Url.decode("包含中文") }
    }

    private fun fixture(): JSONObject {
        val stream = requireNotNull(javaClass.classLoader?.getResourceAsStream("crypto-vectors.json")) {
            "缺少共享加密向量 crypto-vectors.json"
        }
        return stream.bufferedReader(StandardCharsets.UTF_8).use { JSONObject(it.readText()) }
    }
}
