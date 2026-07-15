package com.wootodo.sync

import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

class SyncCryptoException(message: String, cause: Throwable? = null) : Exception(message, cause)

object Base64Url {
    private val canonicalPattern = Regex("^[A-Za-z0-9_-]*$")

    fun encode(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

    fun decode(value: String): ByteArray {
        if (!canonicalPattern.matches(value) || '=' in value || value.length % 4 == 1) {
            throw SyncCryptoException("数据不是规范的无填充 Base64URL")
        }
        val decoded = try {
            Base64.getUrlDecoder().decode(value)
        } catch (error: IllegalArgumentException) {
            throw SyncCryptoException("数据不是有效的 Base64URL", error)
        }
        if (encode(decoded) != value) {
            throw SyncCryptoException("Base64URL 不是规范编码")
        }
        return decoded
    }
}

object SecureBytes {
    private val random = SecureRandom()

    fun generate(count: Int): ByteArray = ByteArray(count).also(random::nextBytes)

    fun deviceToken(): String = Base64Url.encode(generate(32))
}

object SyncAad {
    const val NAMESPACE = "woo-todo-sync-v1"

    fun canonical(
        vaultId: String,
        operationId: String,
        entityId: String,
        kind: SyncOperationKind,
        lamport: Long,
        deviceId: String,
    ): String {
        require(lamport >= 1)
        return "$NAMESPACE|$vaultId|$operationId|$entityId|${kind.wireValue}|$lamport|$deviceId"
    }

    fun bytes(
        vaultId: String,
        operationId: String,
        entityId: String,
        kind: SyncOperationKind,
        lamport: Long,
        deviceId: String,
    ): ByteArray = canonical(vaultId, operationId, entityId, kind, lamport, deviceId)
        .toByteArray(StandardCharsets.UTF_8)
}

data class SyncOperationMetadata(
    val opId: String,
    val entityId: String,
    val kind: SyncOperationKind,
    val lamport: Long,
    val deviceId: String,
)

object SyncPayloadCrypto {
    fun seal(
        plaintext: ByteArray,
        vaultKey: ByteArray,
        vaultId: String,
        metadata: SyncOperationMetadata,
        nonce: ByteArray = SecureBytes.generate(Aes256Gcm.NONCE_BYTES),
    ): EncryptedEnvelope = Aes256Gcm.seal(
        plaintext,
        vaultKey,
        nonce,
        SyncAad.bytes(
            vaultId,
            metadata.opId,
            metadata.entityId,
            metadata.kind,
            metadata.lamport,
            metadata.deviceId,
        ),
    )

    fun open(
        envelope: EncryptedEnvelope,
        vaultKey: ByteArray,
        vaultId: String,
        metadata: SyncOperationMetadata,
    ): ByteArray = Aes256Gcm.open(
        envelope,
        vaultKey,
        SyncAad.bytes(
            vaultId,
            metadata.opId,
            metadata.entityId,
            metadata.kind,
            metadata.lamport,
            metadata.deviceId,
        ),
    )
}

object Aes256Gcm {
    const val KEY_BYTES = 32
    const val NONCE_BYTES = 12
    const val TAG_BYTES = 16

    fun seal(
        plaintext: ByteArray,
        key: ByteArray,
        nonce: ByteArray = SecureBytes.generate(NONCE_BYTES),
        aad: ByteArray,
    ): EncryptedEnvelope {
        require(key.size == KEY_BYTES) { "AES-256-GCM 密钥必须为 32 字节" }
        require(nonce.size == NONCE_BYTES) { "AES-GCM nonce 必须为 12 字节" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAG_BYTES * 8, nonce),
        )
        cipher.updateAAD(aad)
        val ciphertextAndTag = cipher.doFinal(plaintext)
        return EncryptedEnvelope(
            ciphertext = Base64Url.encode(ciphertextAndTag),
            nonce = Base64Url.encode(nonce),
        )
    }

    fun open(
        envelope: EncryptedEnvelope,
        key: ByteArray,
        aad: ByteArray,
    ): ByteArray {
        require(key.size == KEY_BYTES) { "AES-256-GCM 密钥必须为 32 字节" }
        val nonce = Base64Url.decode(envelope.nonce)
        require(nonce.size == NONCE_BYTES) { "AES-GCM nonce 必须为 12 字节" }
        val ciphertextAndTag = Base64Url.decode(envelope.ciphertext)
        require(ciphertextAndTag.size >= TAG_BYTES) { "密文必须包含 16 字节认证标签" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(TAG_BYTES * 8, nonce),
        )
        cipher.updateAAD(aad)
        return try {
            cipher.doFinal(ciphertextAndTag)
        } catch (error: AEADBadTagException) {
            throw SyncCryptoException("AES-GCM 认证失败", error)
        }
    }
}
