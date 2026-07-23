package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Test

class CredentialsStoreTest {
    @Test
    fun `重建仓储实例后仍保留配对身份`() {
        val blobStore = MemoryCredentialBlobStore()
        val cipher = PassthroughCredentialCipher()
        val expected = SyncCredentials(
            endpoint = "https://sync.example.test",
            vaultId = "vault-upgrade-test",
            deviceId = "device-upgrade-test",
            deviceToken = Base64Url.encode(ByteArray(32) { 3 }),
            vaultKey = ByteArray(32) { (it + 1).toByte() },
        )

        WrappedSyncCredentialsStore(blobStore, cipher).save(expected)

        // 覆盖升级会重建 Application/仓储对象，但同签名安装不会清除应用数据。
        val restored = requireNotNull(WrappedSyncCredentialsStore(blobStore, cipher).load())

        assertNotSame(expected, restored)
        assertEquals(expected, restored)
    }
}

private class MemoryCredentialBlobStore : CredentialBlobStore {
    private var envelope: EncryptedEnvelope? = null

    override fun write(envelope: EncryptedEnvelope) {
        this.envelope = envelope.copy()
    }

    override fun read(): EncryptedEnvelope? = envelope?.copy()

    override fun delete() {
        envelope = null
    }
}

private class PassthroughCredentialCipher : CredentialCipher {
    override fun encrypt(plaintext: ByteArray, aad: ByteArray): EncryptedEnvelope =
        EncryptedEnvelope(
            ciphertext = Base64Url.encode(plaintext),
            nonce = Base64Url.encode(aad),
        )

    override fun decrypt(envelope: EncryptedEnvelope, aad: ByteArray): ByteArray {
        check(envelope.nonce == Base64Url.encode(aad))
        return Base64Url.decode(envelope.ciphertext)
    }
}
