package com.wootodo.sync

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavCredentialsTest {
    private val account = WebDavAccount(
        endpoint = "https://dav.example.com/woo-todo/",
        username = "user@example.com",
        appPassword = "application-password",
    )
    private val identity = WebDavIdentity(
        vaultId = "vault-credential-01",
        deviceId = "device-android-0001",
        vaultKey = ByteArray(32) { (it + 5).toByte() },
    )

    @Test
    fun `账号与身份分开编码且可往返`() {
        val accountJson = WebDavAccountJson.encode(account)
        val identityJson = WebDavIdentityJson.encode(identity)

        assertEquals(setOf("endpoint", "username", "appPassword"), JSONObject(accountJson).keySet())
        assertEquals(setOf("vaultId", "deviceId", "vaultKey"), JSONObject(identityJson).keySet())
        assertEquals(account, WebDavAccountJson.decode(accountJson))
        val decodedIdentity = WebDavIdentityJson.decode(identityJson)
        assertEquals(identity.vaultId, decodedIdentity.vaultId)
        assertEquals(identity.deviceId, decodedIdentity.deviceId)
        assertArrayEquals(identity.vaultKey, decodedIdentity.vaultKey)
    }

    @Test
    fun `身份编码拒绝未知字段和错误密钥长度`() {
        val unknown = JSONObject(WebDavIdentityJson.encode(identity))
            .put("unexpected", true)
            .toString()
        assertThrows(IllegalArgumentException::class.java) {
            WebDavIdentityJson.decode(unknown)
        }
        val shortKey = WebDavIdentityJson.encode(identity)
            .replace(Base64Url.encode(identity.vaultKey), "AA")
        assertThrows(Exception::class.java) {
            WebDavIdentityJson.decode(shortKey)
        }
    }

    @Test
    fun `WebDAV账号校验地址用户名与应用密码`() {
        account.validate()
        assertTrue(account.toString().contains("<redacted>"))
        assertFalse(account.toString().contains(account.appPassword))

        listOf(
            WebDavAccount("http://dav.example.com/", "user", "pass"),
            WebDavAccount("https://user:pass@dav.example.com/", "user", "pass"),
            WebDavAccount("https://dav.example.com/", "user name", "pass"),
            WebDavAccount("https://dav.example.com/", "user", "bad\u0000pass"),
        ).forEach { invalid ->
            assertThrows(WebDavException.InvalidCredentials::class.java) {
                invalid.validate()
            }
        }
    }

    @Test
    fun `同步身份使用WebDAV身份且拒绝无效vaultId`() {
        val credentials = WebDavCredentials(account, identity)
        credentials.validate()
        val sync = credentials.syncIdentity()

        assertEquals(identity.vaultId, sync.vaultId)
        assertEquals(identity.deviceId, sync.deviceId)
        assertArrayEquals(identity.vaultKey, sync.vaultKey)

        val invalid = WebDavIdentity(
            vaultId = "..",
            deviceId = "device-android-0001",
            vaultKey = ByteArray(32),
        )
        assertThrows(WebDavException.InvalidCredentials::class.java) {
            invalid.validate()
        }
    }

    @Test
    fun `新同步空间生成的标识符合协议限制`() {
        val generated = newWebDavIdentity()

        assertTrue(WebDavCredentialPolicy.isValidVaultId(generated.vaultId))
        assertTrue(WebDavCredentialPolicy.isValidDeviceId(generated.deviceId))
        assertEquals(32, generated.vaultKey.size)
        generated.validate()
    }
}
