package com.wootodo.sync

import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.interfaces.XECPrivateKey
import java.security.interfaces.XECPublicKey
import java.security.spec.NamedParameterSpec
import java.security.spec.XECPrivateKeySpec
import java.security.spec.XECPublicKeySpec
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class PairingKeyPair private constructor(
    privateScalarBytes: ByteArray,
    publicKeyBytes: ByteArray,
) {
    private val privateScalar: ByteArray = privateScalarBytes.copyOf()
    val publicKey: ByteArray = publicKeyBytes.copyOf()
    val publicKeyBase64Url: String get() = Base64Url.encode(publicKey)

    fun sharedSecret(peerPublicKey: ByteArray): ByteArray {
        require(peerPublicKey.size == 32) { "X25519 公钥必须为 32 字节" }
        val keyFactory = xdhKeyFactory()
        val privateKey = keyFactory.generatePrivate(
            XECPrivateKeySpec(NamedParameterSpec.X25519, privateScalar.copyOf()),
        )
        val peerValue = BigInteger(1, peerPublicKey.reversedArray())
        val peerKey = keyFactory.generatePublic(
            XECPublicKeySpec(NamedParameterSpec.X25519, peerValue),
        )
        val agreement = xdhKeyAgreement()
        agreement.init(privateKey)
        agreement.doPhase(peerKey, true)
        return agreement.generateSecret()
    }

    fun sessionKey(
        peerPublicKey: ByteArray,
        pairingId: String,
        pairingSecret: ByteArray,
    ): ByteArray {
        require(pairingSecret.size == 32) { "配对 secret 必须为 32 字节" }
        return HkdfSha256.derive(
            inputKeyMaterial = sharedSecret(peerPublicKey),
            salt = pairingSecret,
            info = PairingSessionCrypto.hkdfInfo(pairingId),
            outputBytes = Aes256Gcm.KEY_BYTES,
        )
    }

    fun sessionKey(
        peerPublicKeyBase64Url: String,
        pairingId: String,
        pairingSecretBase64Url: String,
    ): ByteArray = sessionKey(
        Base64Url.decode(peerPublicKeyBase64Url),
        pairingId,
        Base64Url.decode(pairingSecretBase64Url),
    )

    /** 配对结束后立即擦除可由应用控制的临时私钥副本。 */
    fun destroy() {
        privateScalar.fill(0)
    }

    companion object {
        fun generate(): PairingKeyPair {
            val generator = runCatching { KeyPairGenerator.getInstance("XDH") }
                .getOrElse { KeyPairGenerator.getInstance("X25519") }
            generator.initialize(NamedParameterSpec.X25519)
            val pair = generator.generateKeyPair()
            val privateScalar = (pair.private as? XECPrivateKey)?.scalar?.orElse(null)
                ?: throw SyncCryptoException("无法导出 X25519 私钥")
            val publicValue = (pair.public as? XECPublicKey)?.u
                ?: throw SyncCryptoException("无法导出 X25519 公钥")
            return PairingKeyPair(privateScalar, publicValue.toLittleEndian(32))
        }

        fun fromPrivateKey(privateScalar: ByteArray): PairingKeyPair {
            require(privateScalar.size == 32) { "X25519 私钥必须为 32 字节" }
            val keyFactory = xdhKeyFactory()
            val privateKey = keyFactory.generatePrivate(
                XECPrivateKeySpec(NamedParameterSpec.X25519, privateScalar.copyOf()),
            )
            val basePoint = keyFactory.generatePublic(
                XECPublicKeySpec(NamedParameterSpec.X25519, BigInteger.valueOf(9)),
            )
            val agreement = xdhKeyAgreement()
            agreement.init(privateKey)
            agreement.doPhase(basePoint, true)
            return PairingKeyPair(privateScalar, agreement.generateSecret())
        }
    }
}

object HkdfSha256 {
    fun derive(
        inputKeyMaterial: ByteArray,
        salt: ByteArray,
        info: ByteArray,
        outputBytes: Int,
    ): ByteArray {
        require(outputBytes in 1..(255 * 32))
        val extract = Mac.getInstance("HmacSHA256")
        extract.init(SecretKeySpec(salt, "HmacSHA256"))
        val pseudoRandomKey = extract.doFinal(inputKeyMaterial)
        val output = ByteArray(outputBytes)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < outputBytes) {
            val expand = Mac.getInstance("HmacSHA256")
            expand.init(SecretKeySpec(pseudoRandomKey, "HmacSHA256"))
            expand.update(previous)
            expand.update(info)
            expand.update(counter.toByte())
            previous = expand.doFinal()
            val count = minOf(previous.size, outputBytes - offset)
            previous.copyInto(output, offset, 0, count)
            offset += count
            counter += 1
        }
        return output
    }
}

object PairingSessionCrypto {
    const val HKDF_NAMESPACE = "woo-todo-pairing-v1"
    const val VERIFICATION_NAMESPACE = "woo-todo-pairing-code-v1"
    const val ENVELOPE_NAMESPACE = "woo-todo-pair-v1"

    fun hkdfInfo(pairingId: String): ByteArray =
        "$HKDF_NAMESPACE|$pairingId".toByteArray(StandardCharsets.UTF_8)

    fun verificationInput(
        initiatorPublicKey: ByteArray,
        claimPublicKey: ByteArray,
    ): ByteArray {
        require(initiatorPublicKey.size == 32) { "发起方 X25519 公钥必须为 32 字节" }
        require(claimPublicKey.size == 32) { "认领方 X25519 公钥必须为 32 字节" }
        val input = "$VERIFICATION_NAMESPACE|${Base64Url.encode(initiatorPublicKey)}|" +
            Base64Url.encode(claimPublicKey)
        return input.toByteArray(StandardCharsets.UTF_8)
    }

    fun aad(pairingId: String, claimedDeviceId: String): ByteArray =
        "$ENVELOPE_NAMESPACE|$pairingId|$claimedDeviceId".toByteArray(StandardCharsets.UTF_8)

    fun sealVaultKey(
        vaultKey: ByteArray,
        sessionKey: ByteArray,
        pairingId: String,
        claimedDeviceId: String,
        nonce: ByteArray = SecureBytes.generate(Aes256Gcm.NONCE_BYTES),
    ): EncryptedEnvelope {
        require(vaultKey.size == Aes256Gcm.KEY_BYTES)
        return Aes256Gcm.seal(vaultKey, sessionKey, nonce, aad(pairingId, claimedDeviceId))
    }

    fun openVaultKey(
        envelope: EncryptedEnvelope,
        sessionKey: ByteArray,
        pairingId: String,
        claimedDeviceId: String,
    ): ByteArray = Aes256Gcm.open(envelope, sessionKey, aad(pairingId, claimedDeviceId))

    fun verificationCode(
        sessionKey: ByteArray,
        initiatorPublicKey: ByteArray,
        claimPublicKey: ByteArray,
    ): String {
        require(sessionKey.size == Aes256Gcm.KEY_BYTES)
        val hmac = Mac.getInstance("HmacSHA256")
        hmac.init(SecretKeySpec(sessionKey, "HmacSHA256"))
        val digest = hmac.doFinal(verificationInput(initiatorPublicKey, claimPublicKey))
        val value = ByteBuffer.wrap(digest, 0, 4).int.toLong() and 0xffff_ffffL
        return (value % 1_000_000L).toString().padStart(6, '0')
    }
}

private fun BigInteger.toLittleEndian(size: Int): ByteArray {
    val bigEndian = toByteArray().let { bytes ->
        if (bytes.size > 1 && bytes[0] == 0.toByte()) bytes.copyOfRange(1, bytes.size) else bytes
    }
    require(bigEndian.size <= size) { "X25519 公钥超出 32 字节" }
    return ByteArray(size).also { output ->
        bigEndian.reversedArray().copyInto(output)
    }
}

private fun xdhKeyFactory(): KeyFactory = runCatching { KeyFactory.getInstance("XDH") }
    .getOrElse { KeyFactory.getInstance("X25519") }

private fun xdhKeyAgreement(): KeyAgreement = runCatching { KeyAgreement.getInstance("XDH") }
    .getOrElse { KeyAgreement.getInstance("X25519") }
