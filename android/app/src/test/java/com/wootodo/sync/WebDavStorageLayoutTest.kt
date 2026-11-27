package com.wootodo.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavStorageLayoutTest {
    @Test
    fun `识别已经指向专属目录的地址`() {
        assertTrue(WebDavStorageLayout.isAppFolder("https://dav.example.com/dav/WooTodo"))
        assertTrue(WebDavStorageLayout.isAppFolder("https://dav.example.com/dav/wootodo/"))
        assertFalse(WebDavStorageLayout.isAppFolder("https://dav.example.com/dav"))
    }

    @Test
    fun `新账号落在专属目录`() {
        val resolved = WebDavStorageLayout.resolveEndpoint(
            endpoint = "https://dav.example.com/dav/",
            vaultId = null,
            hasVaultAt = { false },
            hasPairingAt = { false },
        )

        assertEquals("https://dav.example.com/dav/WooTodo", resolved)
    }

    @Test
    fun `旧账号已有配对目录时保持原目录`() {
        val resolved = WebDavStorageLayout.resolveEndpoint(
            endpoint = "https://dav.example.com/dav/",
            vaultId = null,
            hasVaultAt = { false },
            hasPairingAt = { it == "https://dav.example.com/dav" },
        )

        assertEquals("https://dav.example.com/dav", resolved)
    }

    @Test
    fun `已加入专属目录的空间优先使用专属目录`() {
        val resolved = WebDavStorageLayout.resolveEndpoint(
            endpoint = "https://dav.example.com/dav/",
            vaultId = null,
            hasVaultAt = { false },
            hasPairingAt = { true },
        )

        assertEquals("https://dav.example.com/dav/WooTodo", resolved)
    }

    @Test
    fun `已配对设备按自己的空间所在目录解析`() {
        val resolved = WebDavStorageLayout.resolveEndpoint(
            endpoint = "https://dav.example.com/dav/",
            vaultId = "vault-legacy",
            hasVaultAt = { it == "https://dav.example.com/dav" },
            hasPairingAt = { error("已配对时不应探测配对目录") },
        )

        assertEquals("https://dav.example.com/dav", resolved)
    }

    @Test
    fun `用户已填写专属目录时不重复追加`() {
        val resolved = WebDavStorageLayout.resolveEndpoint(
            endpoint = "https://dav.example.com/dav/WooTodo/",
            vaultId = null,
            hasVaultAt = { error("不应探测") },
            hasPairingAt = { error("不应探测") },
        )

        assertEquals("https://dav.example.com/dav/WooTodo", resolved)
    }
}
