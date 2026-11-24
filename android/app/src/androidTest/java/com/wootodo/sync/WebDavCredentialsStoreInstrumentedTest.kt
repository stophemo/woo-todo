package com.wootodo.sync

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.charset.StandardCharsets
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class WebDavCredentialsStoreInstrumentedTest {
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Before
    fun setUp() {
        clearPreferences()
    }

    @After
    fun tearDown() {
        clearPreferences()
    }

    @Test
    fun `旧WebDAV完整凭据自动迁移为账号与身份`() {
        val vaultKey = ByteArray(32) { (it + 9).toByte() }
        val legacyJson = JSONObject()
            .put("endpoint", "https://dav.example.com/woo-todo/")
            .put("username", "user@example.com")
            .put("appPassword", "application-password")
            .put("vaultId", "vault-legacy-migrate")
            .put("deviceId", "device-legacy-migrate")
            .put("vaultKey", Base64Url.encode(vaultKey))
            .toString()
        val legacyBlob = SharedPreferencesCredentialBlobStore(
            context,
            "webdav_credentials_encrypted",
        )
        val legacyCipher = AndroidKeystoreCredentialCipher("woo-todo-webdav-credentials-v1")
        legacyBlob.write(
            legacyCipher.encrypt(
                legacyJson.toByteArray(StandardCharsets.UTF_8),
                "woo-todo-webdav-credentials-v1".toByteArray(StandardCharsets.UTF_8),
            ),
        )

        val store = AndroidWebDavCredentialsStore(context)
        val credentials = requireNotNull(store.load())

        assertEquals("https://dav.example.com/woo-todo/", credentials.endpoint)
        assertEquals("user@example.com", credentials.username)
        assertEquals("vault-legacy-migrate", credentials.vaultId)
        assertEquals("device-legacy-migrate", credentials.deviceId)
        assertArrayEquals(vaultKey, credentials.vaultKey)
        assertNull(legacyBlob.read())

        val reopened = AndroidWebDavCredentialsStore(context)
        assertEquals(credentials.account, reopened.loadAccount())
        assertEquals(credentials.vaultId, reopened.loadIdentity()?.vaultId)
    }

    @Test
    fun `退出空间删除身份但保留账号`() {
        val store = AndroidWebDavCredentialsStore(context)
        val account = WebDavAccount(
            endpoint = "https://dav.example.com/woo-todo/",
            username = "user@example.com",
            appPassword = "application-password",
        )
        val identity = WebDavIdentity(
            vaultId = "vault-keep-account",
            deviceId = "device-keep-account",
            vaultKey = ByteArray(32) { 4 },
        )
        store.save(WebDavCredentials(account, identity))

        store.deleteIdentity()

        assertNull(store.load())
        assertNotNull(store.loadAccount())
        assertNull(store.loadIdentity())
        assertEquals(account, store.loadAccount())
    }

    private fun clearPreferences() {
        listOf(
            "webdav_account_encrypted",
            "webdav_identity_encrypted",
            "webdav_credentials_encrypted",
        ).forEach { name -> context.deleteSharedPreferences(name) }
    }
}
