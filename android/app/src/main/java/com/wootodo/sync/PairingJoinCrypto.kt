package com.wootodo.sync

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** 新设备显示码 / 已有设备批准的单向 join 配对。 */
object PairingJoinCrypto {
    const val HKDF_NAMESPACE = "woo-todo-pairing-join-v1"
    const val VERIFICATION_NAMESPACE = "woo-todo-pairing-code-v1"
    const val ENVELOPE_NAMESPACE = "woo-todo-pair-v1"

    /** HKDF salt 的原文；实际派生时先做 SHA-256。 */
    fun hkdfSalt(joinRequestId: String): ByteArray =
        "$HKDF_NAMESPACE|salt|$joinRequestId".toByteArray(StandardCharsets.UTF_8)

    fun hkdfInfo(joinRequestId: String): ByteArray =
        "$HKDF_NAMESPACE|$joinRequestId".toByteArray(StandardCharsets.UTF_8)

    fun sessionKey(
        keyPair: PairingKeyPair,
        peerPublicKey: ByteArray,
        joinRequestId: String,
    ): ByteArray = HkdfSha256.derive(
        inputKeyMaterial = keyPair.sharedSecret(peerPublicKey),
        salt = MessageDigest.getInstance("SHA-256").digest(hkdfSalt(joinRequestId)),
        info = hkdfInfo(joinRequestId),
        outputBytes = Aes256Gcm.KEY_BYTES,
    )

    fun verificationInput(
        joinRequestId: String,
        creatorPublicKey: ByteArray,
        approverPublicKey: ByteArray,
    ): ByteArray {
        require(creatorPublicKey.size == 32) { "创建方 X25519 公钥必须为 32 字节" }
        require(approverPublicKey.size == 32) { "批准方 X25519 公钥必须为 32 字节" }
        val input = "$VERIFICATION_NAMESPACE|join|$joinRequestId|" +
            "${Base64Url.encode(creatorPublicKey)}|${Base64Url.encode(approverPublicKey)}"
        return input.toByteArray(StandardCharsets.UTF_8)
    }

    fun verificationCode(
        sessionKey: ByteArray,
        joinRequestId: String,
        creatorPublicKey: ByteArray,
        approverPublicKey: ByteArray,
    ): String {
        require(sessionKey.size == Aes256Gcm.KEY_BYTES) { "配对 session key 必须为 32 字节" }
        val hmac = Mac.getInstance("HmacSHA256")
        hmac.init(SecretKeySpec(sessionKey, "HmacSHA256"))
        val digest = hmac.doFinal(
            verificationInput(joinRequestId, creatorPublicKey, approverPublicKey),
        )
        val value = ByteBuffer.wrap(digest, 0, 4).int.toLong() and 0xffff_ffffL
        return (value % 1_000_000L).toString().padStart(6, '0')
    }

    fun sealVaultKey(
        vaultKey: ByteArray,
        sessionKey: ByteArray,
        joinRequestId: String,
        deviceId: String,
        nonce: ByteArray = SecureBytes.generate(Aes256Gcm.NONCE_BYTES),
    ): EncryptedEnvelope = Aes256Gcm.seal(
        vaultKey,
        sessionKey,
        nonce,
        aad(joinRequestId, deviceId),
    )

    fun openVaultKey(
        envelope: EncryptedEnvelope,
        sessionKey: ByteArray,
        joinRequestId: String,
        deviceId: String,
    ): ByteArray = Aes256Gcm.open(
        envelope,
        sessionKey,
        aad(joinRequestId, deviceId),
    )

    fun aad(joinRequestId: String, deviceId: String): ByteArray =
        "$ENVELOPE_NAMESPACE|join|$joinRequestId|$deviceId".toByteArray(StandardCharsets.UTF_8)
}
