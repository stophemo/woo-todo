package com.wootodo.sync

import java.nio.charset.StandardCharsets
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavInviteTest {
    private val now = 1_765_000_000_000L
    private val macosInvite =
        "woo-todo-invite:1:eyJhcHBQYXNzd29yZCI6InRoaXJkLXBhcnR5LXBhc3N3b3JkIiwiZW5kcG9pbnQiOiJodHRwczovL2Rhdi5leGFtcGxlLmNvbS9kYXYvV29vVG9kbyIsImV4cGlyZXNBdCI6MTc2NTAwMDYwMDAwMCwiaXNzdWVkQXQiOjE3NjUwMDAwMDAwMDAsInVzZXJuYW1lIjoidXNlckBleGFtcGxlLmNvbSIsInYiOjEsInZhdWx0SWQiOiJ2YXVsdC1pbnZpdGUtdGVzdCIsInZhdWx0S2V5IjoiQ1FrSkNRa0pDUWtKQ1FrSkNRa0pDUWtKQ1FrSkNRa0pDUWtKQ1FrSkNRayJ9"

    private val credentials = WebDavCredentials(
        account = WebDavAccount(
            endpoint = "https://dav.example.com/dav/WooTodo",
            username = "user@example.com",
            appPassword = "third-party-password",
        ),
        identity = WebDavIdentity(
            vaultId = "vault-invite-test",
            deviceId = "device-owner-01",
            vaultKey = ByteArray(Aes256Gcm.KEY_BYTES) { 9 },
        ),
    )

    @Test
    fun `邀请可往返并生成独立设备身份`() {
        val invite = WebDavInvite.create(credentials, now)
        val decoded = WebDavInvite.decode(invite.encode(), now + 1_000L)

        assertEquals(credentials.account, decoded.account)
        assertEquals(credentials.vaultId, decoded.vaultId)
        assertArrayEquals(credentials.vaultKey, decoded.vaultKey)
        assertEquals(now, decoded.issuedAt)
        assertEquals(now + WebDavInvite.TTL_MILLIS, decoded.expiresAt)

        val identity = decoded.identity("device-new-01")
        assertEquals(credentials.vaultId, identity.vaultId)
        assertEquals("device-new-01", identity.deviceId)
        assertArrayEquals(credentials.vaultKey, identity.vaultKey)
    }

    @Test
    fun `过期的邀请被拒绝`() {
        val encoded = WebDavInvite.create(credentials, now).encode()

        val error = assertThrows(WebDavInviteException::class.java) {
            WebDavInvite.decode(encoded, now + WebDavInvite.TTL_MILLIS + 1)
        }

        assertTrue(error.message!!.contains("过期"))
    }

    @Test
    fun `前缀或内容被篡改时拒绝`() {
        val encoded = WebDavInvite.create(credentials, now).encode()

        assertThrows(WebDavInviteException::class.java) {
            WebDavInvite.decode(encoded.replace("woo-todo-invite:1:", "other:"), now)
        }
        assertThrows(WebDavInviteException::class.java) {
            WebDavInvite.decode(encoded.dropLast(1) + "A", now)
        }
    }

    @Test
    fun `解码另一平台生成的邀请`() {
        val decoded = WebDavInvite.decode(macosInvite, now)

        assertEquals("vault-invite-test", decoded.vaultId)
        assertEquals(credentials.account, decoded.account)
        assertArrayEquals(credentials.vaultKey, decoded.vaultKey)
        assertEquals(now, decoded.issuedAt)
        assertEquals(now + WebDavInvite.TTL_MILLIS, decoded.expiresAt)
    }

    @Test
    fun `时间跨度异常时拒绝`() {
        val json = JSONObject()
            .put("v", 1)
            .put("endpoint", credentials.account.endpoint)
            .put("username", credentials.account.username)
            .put("appPassword", credentials.account.appPassword)
            .put("vaultId", credentials.vaultId)
            .put("vaultKey", Base64Url.encode(credentials.vaultKey))
            .put("issuedAt", now)
            .put("expiresAt", now + WebDavInvite.TTL_MILLIS * 2)
        val encoded = WebDavInvite.PREFIX + Base64Url.encode(
            json.toString().toByteArray(StandardCharsets.UTF_8),
        )

        assertThrows(WebDavInviteException::class.java) {
            WebDavInvite.decode(encoded, now)
        }
        assertThrows(WebDavInviteException::class.java) {
            WebDavInvite.decode(encoded, now - 10L * 60L * 1_000L)
        }
    }
}
