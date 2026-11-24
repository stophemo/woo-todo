package com.wootodo.sync

import com.wootodo.data.LocalJoinDataSummary
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class JoinPolicyTest {
    @Test
    fun `无身份且无本地数据时直接加入`() {
        val policy = JoinPolicyDecider.decide(
            hasIdentity = false,
            localVaultId = null,
            lastSyncedAt = null,
            peerDeviceName = "MacBook",
            peerPlatform = DevicePlatform.MACOS,
            localData = LocalJoinDataSummary(),
        )
        assertEquals(JoinPolicy.JoinDirectly, policy)
    }

    @Test
    fun `无身份但有活动任务时提示清空本机数据`() {
        val policy = JoinPolicyDecider.decide(
            hasIdentity = false,
            localVaultId = null,
            lastSyncedAt = null,
            peerDeviceName = "MacBook",
            peerPlatform = DevicePlatform.MACOS,
            localData = LocalJoinDataSummary(activeTaskCount = 3),
        )
        assertEquals(JoinPolicy.ClearLocalTasks(3), policy)
    }

    @Test
    fun `无身份只有回收站数据时也提示清空`() {
        val policy = JoinPolicyDecider.decide(
            hasIdentity = false,
            localVaultId = null,
            lastSyncedAt = null,
            peerDeviceName = "MacBook",
            peerPlatform = DevicePlatform.MACOS,
            localData = LocalJoinDataSummary(trashedTaskCount = 2),
        )
        assertEquals(JoinPolicy.ClearLocalTasks(2), policy)
    }

    @Test
    fun `无身份只有自定义标签时也提示清空`() {
        val policy = JoinPolicyDecider.decide(
            hasIdentity = false,
            localVaultId = null,
            lastSyncedAt = null,
            peerDeviceName = "MacBook",
            peerPlatform = DevicePlatform.MACOS,
            localData = LocalJoinDataSummary(customCategoryCount = 2),
        )
        assertEquals(JoinPolicy.ClearLocalTasks(2), policy)
    }

    @Test
    fun `无身份只有待同步记录时也提示清空`() {
        val policy = JoinPolicyDecider.decide(
            hasIdentity = false,
            localVaultId = null,
            lastSyncedAt = null,
            peerDeviceName = "MacBook",
            peerPlatform = DevicePlatform.MACOS,
            localData = LocalJoinDataSummary(
                pendingOutboxCount = 1,
                deferredDeletionCount = 2,
            ),
        )
        assertEquals(JoinPolicy.ClearLocalTasks(3), policy)
    }

    @Test
    fun `有身份时显示本机空间最近同步与对方设备`() {
        val policy = JoinPolicyDecider.decide(
            hasIdentity = true,
            localVaultId = "vault-local",
            lastSyncedAt = 1_700_000_000_000L,
            peerDeviceName = "MacBook",
            peerPlatform = DevicePlatform.MACOS,
            localData = LocalJoinDataSummary(),
        )
        assertEquals(
            JoinPolicy.ChooseSpace(
                localVaultId = "vault-local",
                lastSyncedAt = 1_700_000_000_000L,
                peerDeviceName = "MacBook",
                peerPlatform = DevicePlatform.MACOS,
            ),
            policy,
        )
    }

    @Test
    fun `直接加入不会弹出选择也不标记清空`() = runBlocking {
        var prompted = false
        val preparation = JoinPreparation(
            policyFor = { _, _ -> JoinPolicy.JoinDirectly },
            choose = {
                prompted = true
                JoinPolicyChoice.Continue
            },
        )

        assertEquals(
            JoinPreparationResult.Ready(clearLocalDataAfterApproval = false),
            preparation.prepare(null, null),
        )
        assertTrue(!prompted)
    }

    @Test
    fun `有任务选择继续加入时只标记批准后清空`() = runBlocking {
        var prompted: JoinPolicy? = null
        val preparation = JoinPreparation(
            policyFor = { _, _ -> JoinPolicy.ClearLocalTasks(3) },
            choose = {
                prompted = it
                JoinPolicyChoice.Continue
            },
        )

        assertEquals(
            JoinPreparationResult.Ready(clearLocalDataAfterApproval = true),
            preparation.prepare("MacBook", DevicePlatform.MACOS),
        )
        assertEquals(JoinPolicy.ClearLocalTasks(3), prompted)
    }

    @Test
    fun `有任务选择取消时不清空也不加入`() = runBlocking {
        val preparation = JoinPreparation(
            policyFor = { _, _ -> JoinPolicy.ClearLocalTasks(3) },
            choose = { JoinPolicyChoice.Cancel },
        )

        assertEquals(
            JoinPreparationResult.Cancelled,
            preparation.prepare("MacBook", DevicePlatform.MACOS),
        )
    }

    @Test
    fun `有任务选择以本机为准时取消且不清空`() = runBlocking {
        val preparation = JoinPreparation(
            policyFor = { _, _ -> JoinPolicy.ClearLocalTasks(3) },
            choose = { JoinPolicyChoice.UseLocalData },
        )

        assertEquals(
            JoinPreparationResult.UseLocalData,
            preparation.prepare("MacBook", DevicePlatform.MACOS),
        )
    }

    @Test
    fun `有身份选择以对方为准时只标记批准后清空`() = runBlocking {
        val preparation = JoinPreparation(
            policyFor = { name, platform ->
                JoinPolicy.ChooseSpace("vault-local", 1_000L, name, platform)
            },
            choose = { JoinPolicyChoice.Continue },
        )

        assertEquals(
            JoinPreparationResult.Ready(clearLocalDataAfterApproval = true),
            preparation.prepare("Pixel", DevicePlatform.ANDROID),
        )
    }

    @Test
    fun `有身份选择以本机为准时取消且不清空`() = runBlocking {
        val preparation = JoinPreparation(
            policyFor = { name, platform ->
                JoinPolicy.ChooseSpace("vault-local", 1_000L, name, platform)
            },
            choose = { JoinPolicyChoice.UseLocalData },
        )

        assertEquals(
            JoinPreparationResult.UseLocalData,
            preparation.prepare("Pixel", DevicePlatform.ANDROID),
        )
    }

    @Test
    fun `有身份取消时不清空`() = runBlocking {
        val preparation = JoinPreparation(
            policyFor = { name, platform ->
                JoinPolicy.ChooseSpace("vault-local", null, name, platform)
            },
            choose = { JoinPolicyChoice.Cancel },
        )

        assertEquals(
            JoinPreparationResult.Cancelled,
            preparation.prepare("Pixel", DevicePlatform.ANDROID),
        )
    }
}
