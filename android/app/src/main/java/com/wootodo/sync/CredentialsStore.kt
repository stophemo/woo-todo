package com.wootodo.sync

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONObject
import java.net.URI
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SyncCredentials(
    val endpoint: String,
    val vaultId: String,
    val deviceId: String,
    val deviceToken: String,
    vaultKey: ByteArray,
) {
    val vaultKey: ByteArray = vaultKey.copyOf()

    fun validate() {
        val uri = runCatching { URI(endpoint) }.getOrNull()
        require(uri != null && SyncEndpointPolicy.isAllowed(uri))
        require(vaultId.isNotBlank() && deviceId.isNotBlank())
        require(Base64Url.decode(deviceToken).size == 32)
        require(vaultKey.size == Aes256Gcm.KEY_BYTES)
    }

    override fun equals(other: Any?): Boolean = other is SyncCredentials &&
        endpoint == other.endpoint &&
        vaultId == other.vaultId &&
        deviceId == other.deviceId &&
        deviceToken == other.deviceToken &&
        vaultKey.contentEquals(other.vaultKey)

    override fun hashCode(): Int = 31 * listOf(endpoint, vaultId, deviceId, deviceToken).hashCode() +
        vaultKey.contentHashCode()
}

interface SyncCredentialsStore {
    fun save(credentials: SyncCredentials)

    /** 同一应用进程内原子地拒绝覆盖已有身份。 */
    fun saveIfAbsent(credentials: SyncCredentials): Boolean

    fun load(): SyncCredentials?
    fun delete()
}

interface CredentialCipher {
    fun encrypt(plaintext: ByteArray, aad: ByteArray): EncryptedEnvelope
    fun decrypt(envelope: EncryptedEnvelope, aad: ByteArray): ByteArray
}

interface CredentialBlobStore {
    fun write(envelope: EncryptedEnvelope)
    fun read(): EncryptedEnvelope?
    fun delete()
}

class WrappedSyncCredentialsStore(
    private val blobStore: CredentialBlobStore,
    private val cipher: CredentialCipher,
) : SyncCredentialsStore {
    @Synchronized
    override fun save(credentials: SyncCredentials) {
        write(credentials)
    }

    @Synchronized
    override fun saveIfAbsent(credentials: SyncCredentials): Boolean {
        if (blobStore.read() != null) return false
        write(credentials)
        return true
    }

    private fun write(credentials: SyncCredentials) {
        credentials.validate()
        val plaintext = SyncCredentialsJson.encode(credentials).toByteArray(StandardCharsets.UTF_8)
        try {
            blobStore.write(cipher.encrypt(plaintext, CREDENTIAL_AAD))
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    override fun load(): SyncCredentials? {
        val envelope = blobStore.read() ?: return null
        val plaintext = cipher.decrypt(envelope, CREDENTIAL_AAD)
        return try {
            SyncCredentialsJson.decode(String(plaintext, StandardCharsets.UTF_8)).also {
                it.validate()
            }
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    override fun delete() = blobStore.delete()

    private companion object {
        val CREDENTIAL_AAD = "woo-todo-credentials-v1".toByteArray(StandardCharsets.UTF_8)
    }
}

class SharedPreferencesCredentialBlobStore(context: Context) : CredentialBlobStore {
    private val preferences = context.applicationContext.getSharedPreferences(
        "sync_credentials_encrypted",
        Context.MODE_PRIVATE,
    )

    override fun write(envelope: EncryptedEnvelope) {
        check(
            preferences.edit()
            .putString("ciphertext", envelope.ciphertext)
            .putString("nonce", envelope.nonce)
            .commit(),
        ) { "无法持久化同步凭据" }
    }

    override fun read(): EncryptedEnvelope? {
        val ciphertext = preferences.getString("ciphertext", null)
        val nonce = preferences.getString("nonce", null)
        if (ciphertext == null && nonce == null) return null
        check(ciphertext != null && nonce != null) { "加密同步凭据不完整" }
        return EncryptedEnvelope(ciphertext, nonce)
    }

    override fun delete() {
        check(preferences.edit().clear().commit()) { "无法删除同步凭据" }
    }
}

class AndroidKeystoreCredentialCipher(
    private val alias: String = "woo-todo-sync-credentials-v1",
) : CredentialCipher {
    override fun encrypt(plaintext: ByteArray, aad: ByteArray): EncryptedEnvelope {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, loadOrCreateKey())
        cipher.updateAAD(aad)
        return EncryptedEnvelope(
            ciphertext = Base64Url.encode(cipher.doFinal(plaintext)),
            nonce = Base64Url.encode(cipher.iv),
        )
    }

    override fun decrypt(envelope: EncryptedEnvelope, aad: ByteArray): ByteArray {
        val nonce = Base64Url.decode(envelope.nonce)
        require(nonce.size == Aes256Gcm.NONCE_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            loadOrCreateKey(),
            GCMParameterSpec(Aes256Gcm.TAG_BYTES * 8, nonce),
        )
        cipher.updateAAD(aad)
        return cipher.doFinal(Base64Url.decode(envelope.ciphertext))
    }

    private fun loadOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(alias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}

class AndroidSyncCredentialsStore(context: Context) : SyncCredentialsStore by
    WrappedSyncCredentialsStore(
        blobStore = SharedPreferencesCredentialBlobStore(context),
        cipher = AndroidKeystoreCredentialCipher(),
    )

private object SyncCredentialsJson {
    fun encode(credentials: SyncCredentials): String = JSONObject()
        .put("endpoint", credentials.endpoint)
        .put("vaultId", credentials.vaultId)
        .put("deviceId", credentials.deviceId)
        .put("deviceToken", credentials.deviceToken)
        .put("vaultKey", Base64Url.encode(credentials.vaultKey))
        .toString()

    fun decode(source: String): SyncCredentials {
        val objectValue = JSONObject(source)
        val expected = setOf("endpoint", "vaultId", "deviceId", "deviceToken", "vaultKey")
        val actual = objectValue.keys().asSequence().toSet()
        require(actual == expected) { "加密凭据字段不完整" }
        return SyncCredentials(
            endpoint = objectValue.getString("endpoint"),
            vaultId = objectValue.getString("vaultId"),
            deviceId = objectValue.getString("deviceId"),
            deviceToken = objectValue.getString("deviceToken"),
            vaultKey = Base64Url.decode(objectValue.getString("vaultKey")),
        )
    }
}
