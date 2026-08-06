package com.wootodo.sync

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test
import org.json.JSONObject

class WebDavSetupLinkTest {
    private val key = ByteArray(Aes256Gcm.KEY_BYTES) { it.toByte() }
    private val endpoint = "https://dav.example.com/remote.php/dav/files/person/woo-todo/"
    private val link = WebDavSetupLink(
        endpoint = endpoint,
        username = "person@example.com",
        appPassword = "app password/+",
        vaultId = "personal-vault",
        vaultKey = key,
    )

    @Test
    fun `共享fixture可由Android严格解析并往返`() {
        val fixture = JSONObject(
            requireNotNull(
                javaClass.classLoader?.getResourceAsStream("webdav-setup-link.json"),
            ).bufferedReader().use { it.readText() },
        )
        val value = WebDavSetupLink(
            endpoint = fixture.getString("endpoint"),
            username = fixture.getString("username"),
            appPassword = fixture.getString("appPassword"),
            vaultId = fixture.getString("vaultId"),
            vaultKey = Base64Url.decode(fixture.getString("vaultKey")),
        )

        assertEquals("2", fixture.getString("v"))
        assertEquals(value, WebDavSetupLink.parse(value.toUri()))
    }

    @Test
    fun `解析Mac URLComponents生成的跨端配置URI`() {
        val source = requireNotNull(
            javaClass.classLoader?.getResourceAsStream("webdav-setup-link-uri.txt"),
        ).bufferedReader().use { it.readText().trim() }

        val parsed = WebDavSetupLink.parse(source)

        assertEquals(endpoint, parsed.endpoint)
        assertEquals("person+tag@example.com", parsed.username)
        assertEquals("space and & equals= + slash/", parsed.appPassword)
        assertEquals("personal-vault", parsed.vaultId)
        assertArrayEquals(ByteArray(Aes256Gcm.KEY_BYTES) { 7 }, parsed.vaultKey)
    }

    @Test
    fun `严格解析五字段并支持规范往返`() {
        val parsed = WebDavSetupLink.parse(link.toUri())

        assertEquals(link.endpoint, parsed.endpoint)
        assertEquals(link.username, parsed.username)
        assertEquals(link.appPassword, parsed.appPassword)
        assertEquals(link.vaultId, parsed.vaultId)
        assertArrayEquals(link.vaultKey, parsed.vaultKey)
        assertEquals(link, parsed)
        assertFalse(parsed.toString().contains(link.username))
        assertFalse(parsed.toString().contains(link.appPassword))
        assertFalse(parsed.toString().contains(link.vaultId))
        assertFalse(parsed.toString().contains(Base64Url.encode(link.vaultKey)))
    }

    @Test
    fun `保留 Mac 风格查询参数中的原始加号`() {
        val source = baseUri(
            "wootodo://webdav",
            appPassword = "app+password",
        )

        assertEquals("app+password", WebDavSetupLink.parse(source).appPassword)
    }

    @Test
    fun `严格解析六字段并拒绝缺失重复未知字段以及设备身份`() {
        val base = link.toUri()
        listOf(
            base.replace("&appPassword=app%20password%2F%2B", ""),
            "$base&username=other@example.com",
            "$base&deviceId=device-123456",
            "$base&endpoint=https%3A%2F%2Fother.example.com%2Fdav%2F",
            "$base&",
            base.replace("v=2", "v=3"),
        ).forEach { source ->
            assertThrows(IllegalArgumentException::class.java) {
                WebDavSetupLink.parse(source)
            }
        }
    }

    @Test
    fun `拒绝错误地址字段约束和密钥长度`() {
        val invalidSources = listOf(
            baseUri("wootodo://pair"),
            baseUri("wootodo://webdav/path"),
            baseUri("wootodo://webdav:443"),
            baseUri("wootodo://user@webdav"),
            baseUri("wootodo://webdav#fragment"),
            baseUri("wootodo://webdav", username = "bad%20user"),
            baseUri("wootodo://webdav", endpoint = "http%3A%2F%2Fdav.example.com%2F"),
            baseUri("wootodo://webdav", endpoint = "https%3A%2F%2Fuser%40dav.example.com%2F"),
            baseUri("wootodo://webdav", endpoint = "https%3A%2F%2Fdav.example.com%2F%3Ftoken%3Dsecret"),
            baseUri("wootodo://webdav", vaultId = "bad%2Fvault"),
            baseUri("wootodo://webdav", appPassword = ""),
            baseUri("wootodo://webdav", appPassword = "bad%0Apassword"),
            baseUri("wootodo://webdav", username = "a".repeat(321)),
            baseUri("wootodo://webdav", appPassword = "a".repeat(257)),
            baseUri("wootodo://webdav", vaultKey = Base64Url.encode(ByteArray(31))),
            baseUri("wootodo://webdav", vaultKey = "not-base64*"),
        )
        invalidSources.forEach { source ->
            assertThrows(IllegalArgumentException::class.java) {
                WebDavSetupLink.parse(source)
            }
        }
    }

    private fun baseUri(
        authority: String,
        endpoint: String = "https%3A%2F%2Fdav.example.com%2Fwoo-todo%2F",
        username: String = "person%40example.com",
        appPassword: String = "app-password",
        vaultId: String = "personal-vault",
        vaultKey: String = Base64Url.encode(key),
    ): String = "$authority?v=2&endpoint=$endpoint&username=$username&appPassword=$appPassword&" +
        "vaultId=$vaultId&vaultKey=$vaultKey"
}
