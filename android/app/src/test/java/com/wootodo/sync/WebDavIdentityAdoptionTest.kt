package com.wootodo.sync

import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavIdentityAdoptionTest {
    private val previous = WebDavIdentity(
        vaultId = "vault-test-old",
        deviceId = "device-test-old",
        vaultKey = ByteArray(32) { 1 },
    )
    private val adopted = WebDavIdentity(
        vaultId = "vault-test-new",
        deviceId = "device-test-new",
        vaultKey = ByteArray(32) { 2 },
    )

    @Test
    fun `绑定失败时删除新保存的身份`() {
        var deleted = false
        var saved: WebDavIdentity? = null
        val error = assertThrows(WebDavPairingException.LocalBindingFailed::class.java) {
            withIdentityRollback(
                previous = null,
                saveIdentity = { saved = it },
                deleteIdentity = { deleted = true },
            ) {
                throw IllegalStateException("绑定失败")
            }
        }
        assertEquals(WebDavPairingException.LocalBindingFailed, error)
        assertTrue(deleted)
        assertNull(saved)
    }

    @Test
    fun `绑定失败时恢复旧身份`() {
        var deleted = false
        var saved: WebDavIdentity? = null
        assertThrows(WebDavPairingException.LocalBindingFailed::class.java) {
            withIdentityRollback(
                previous = previous,
                saveIdentity = { saved = it },
                deleteIdentity = { deleted = true },
            ) {
                throw IllegalStateException("绑定失败")
            }
        }
        assertEquals(previous, saved)
        assertTrue(!deleted)
    }

    @Test
    fun `绑定成功不回滚`() {
        var rolledBack = false
        val value = withIdentityRollback(
            previous = null,
            saveIdentity = { rolledBack = true },
            deleteIdentity = { rolledBack = true },
        ) {
            "ok"
        }
        assertEquals("ok", value)
        assertTrue(!rolledBack)
    }

    @Test
    fun `取消不会被包装成绑定失败也不回滚`() {
        var rolledBack = false
        assertThrows(CancellationException::class.java) {
            withIdentityRollback(
                previous = previous,
                saveIdentity = { rolledBack = true },
                deleteIdentity = { rolledBack = true },
            ) {
                throw CancellationException("取消")
            }
        }
        assertTrue(!rolledBack)
    }
}
