package com.wootodo.sync

import java.util.concurrent.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class JoinIdentityAdoptionTest {
    private val identity = WebDavIdentity(
        vaultId = "vault-peer",
        deviceId = "device-peer",
        vaultKey = ByteArray(32) { 3 },
    )

    @Test
    fun `未批准时不清空本机任务也不采纳身份`() {
        var cleared = false
        var adopted = false
        val adoption = JoinIdentityAdoption(
            clearLocalData = { cleared = true },
            adoptIdentity = { adopted = true },
        )

        assertThrows(WebDavPairingException.Expired::class.java) {
            runBlocking {
                adoption.awaitAndAdopt(clearLocalDataAfterApproval = true) {
                    throw WebDavPairingException.Expired
                }
            }
        }
        assertTrue(!cleared)
        assertTrue(!adopted)
    }

    @Test
    fun `取消时不清空也不采纳身份`() {
        var cleared = false
        var adopted = false
        val adoption = JoinIdentityAdoption(
            clearLocalData = { cleared = true },
            adoptIdentity = { adopted = true },
        )

        assertThrows(CancellationException::class.java) {
            runBlocking {
                adoption.awaitAndAdopt(clearLocalDataAfterApproval = true) {
                    throw CancellationException("取消")
                }
            }
        }
        assertTrue(!cleared)
        assertTrue(!adopted)
    }

    @Test
    fun `批准成功后先清空本机数据再采纳身份`() = runBlocking {
        val calls = mutableListOf<String>()
        val adoption = JoinIdentityAdoption(
            clearLocalData = { calls += "clear" },
            adoptIdentity = { calls += "adopt" },
        )

        val result = adoption.awaitAndAdopt(clearLocalDataAfterApproval = true) { identity }

        assertSame(identity, result)
        assertEquals(listOf("clear", "adopt"), calls)
    }

    @Test
    fun `清空失败时不采纳新身份`() {
        var adopted = false
        val adoption = JoinIdentityAdoption(
            clearLocalData = { throw IllegalStateException("清空失败") },
            adoptIdentity = { adopted = true },
        )

        assertThrows(IllegalStateException::class.java) {
            runBlocking {
                adoption.awaitAndAdopt(clearLocalDataAfterApproval = true) { identity }
            }
        }
        assertTrue(!adopted)
    }

    @Test
    fun `无需清空时直接采纳身份`() = runBlocking {
        var cleared = false
        var adopted: WebDavIdentity? = null
        val adoption = JoinIdentityAdoption(
            clearLocalData = { cleared = true },
            adoptIdentity = { adopted = it },
        )

        val result = adoption.awaitAndAdopt(clearLocalDataAfterApproval = false) { identity }

        assertSame(identity, result)
        assertSame(identity, adopted)
        assertTrue(!cleared)
    }
}
