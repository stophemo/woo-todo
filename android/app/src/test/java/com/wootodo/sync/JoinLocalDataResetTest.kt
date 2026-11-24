package com.wootodo.sync

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class JoinLocalDataResetTest {
    private val oldIdentity = WebDavIdentity(
        vaultId = "vault-old",
        deviceId = "device-old",
        vaultKey = ByteArray(32) { 1 },
    )
    private val newIdentity = WebDavIdentity(
        vaultId = "vault-new",
        deviceId = "device-new",
        vaultKey = ByteArray(32) { 2 },
    )

    @Test
    fun `身份删除失败时不清空任务也不进入未配对`() {
        val calls = mutableListOf<String>()
        val reset = JoinLocalDataReset(
            deleteIdentity = {
                calls += "delete"
                throw IllegalStateException("无法删除同步凭据")
            },
            loadIdentity = {
                calls += "load"
                oldIdentity
            },
            stopSync = { calls += "stop" },
            clearLocalData = { calls += "clear" },
            onUnpaired = { calls += "unpaired" },
        )

        val error = assertThrows(IllegalStateException::class.java) {
            runBlocking { reset.reset() }
        }

        assertEquals("无法删除同步凭据", error.message)
        assertEquals(listOf("delete"), calls)
    }

    @Test
    fun `删除后仍能读到身份时中止且不清空任务`() {
        val calls = mutableListOf<String>()
        val reset = JoinLocalDataReset(
            deleteIdentity = { calls += "delete" },
            loadIdentity = {
                calls += "load"
                oldIdentity
            },
            stopSync = { calls += "stop" },
            clearLocalData = { calls += "clear" },
            onUnpaired = { calls += "unpaired" },
        )

        assertThrows(WebDavPairingException.IdentityNotRemoved::class.java) {
            runBlocking { reset.reset() }
        }

        assertEquals(listOf("delete", "load"), calls)
    }

    @Test
    fun `任务清空失败时保留任务并进入未配对`() {
        val calls = mutableListOf<String>()
        var storedIdentity: WebDavIdentity? = oldIdentity
        val reset = JoinLocalDataReset(
            deleteIdentity = {
                calls += "delete"
                storedIdentity = null
            },
            loadIdentity = {
                calls += "load"
                storedIdentity
            },
            stopSync = { calls += "stop" },
            clearLocalData = {
                calls += "clear"
                throw IllegalStateException("数据库繁忙")
            },
            onUnpaired = { calls += "unpaired" },
        )

        val error = assertThrows(IllegalStateException::class.java) {
            runBlocking { reset.reset() }
        }

        assertEquals("数据库繁忙", error.message)
        assertEquals(listOf("delete", "load", "stop", "clear", "unpaired"), calls)
    }

    @Test
    fun `身份确认删除后按停止同步再清空并刷新未配对的顺序执行`() = runBlocking {
        val calls = mutableListOf<String>()
        var storedIdentity: WebDavIdentity? = oldIdentity
        val reset = JoinLocalDataReset(
            deleteIdentity = {
                calls += "delete"
                storedIdentity = null
            },
            loadIdentity = {
                calls += "load"
                storedIdentity
            },
            stopSync = { calls += "stop" },
            clearLocalData = { calls += "clear" },
            onUnpaired = { calls += "unpaired" },
        )

        reset.reset()

        assertEquals(listOf("delete", "load", "stop", "clear", "unpaired"), calls)
    }

    @Test
    fun `任务清空失败时不会采纳新身份`() {
        var storedIdentity: WebDavIdentity? = oldIdentity
        var adopted = false
        val adoption = JoinIdentityAdoption(
            clearLocalData = {
                JoinLocalDataReset(
                    deleteIdentity = { storedIdentity = null },
                    loadIdentity = { storedIdentity },
                    stopSync = {},
                    clearLocalData = { throw IllegalStateException("清空失败") },
                    onUnpaired = {},
                ).reset()
            },
            adoptIdentity = { adopted = true },
        )

        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                adoption.awaitAndAdopt(clearLocalDataAfterApproval = true) { newIdentity }
            }
        }

        assertTrue(!adopted)
    }
}
