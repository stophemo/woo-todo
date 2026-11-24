package com.wootodo.sync

import com.wootodo.data.LocalJoinDataSummary
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext

/** 加入其他空间前，本机数据应如何处理。 */
sealed interface JoinPolicy {
    /** 无身份且没有任何本地数据，直接 claim/join。 */
    data object JoinDirectly : JoinPolicy

    /** 无身份但本机有任务、回收站、自定义标签或待同步记录：提示清空后再加入。 */
    data class ClearLocalTasks(val dataCount: Int) : JoinPolicy

    /** 已有身份：由用户选择以对方还是本机设备的数据为准。 */
    data class ChooseSpace(
        val localVaultId: String,
        val lastSyncedAt: Long?,
        val peerDeviceName: String?,
        val peerPlatform: DevicePlatform?,
    ) : JoinPolicy
}

/** 用户在加入提示中的选择。 */
sealed interface JoinPolicyChoice {
    /** 清空本机数据（如需要）后继续 claim/join。 */
    data object Continue : JoinPolicyChoice

    /** 取消本次输入，改为让对方设备输入本机配对码。 */
    data object UseLocalData : JoinPolicyChoice

    data object Cancel : JoinPolicyChoice
}

/** [JoinPreparation.prepare] 的结果。 */
sealed interface JoinPreparationResult {
    /**
     * 可以继续 claim/join。[clearLocalDataAfterApproval] 为真时，必须等对方批准、
     * 拿到新身份后，在采纳新身份前清空本机数据；批准前不得清空。
     */
    data class Ready(val clearLocalDataAfterApproval: Boolean) : JoinPreparationResult

    /** 用户选择以本机为准，调用方不应 claim/join，也不应清空数据。 */
    data object UseLocalData : JoinPreparationResult

    data object Cancelled : JoinPreparationResult
}

object JoinPolicyDecider {
    fun decide(
        hasIdentity: Boolean,
        localVaultId: String?,
        lastSyncedAt: Long?,
        peerDeviceName: String?,
        peerPlatform: DevicePlatform?,
        localData: LocalJoinDataSummary,
    ): JoinPolicy {
        if (hasIdentity) {
            require(!localVaultId.isNullOrBlank()) { "已有同步身份但缺少空间 ID" }
            return JoinPolicy.ChooseSpace(
                localVaultId = localVaultId,
                lastSyncedAt = lastSyncedAt,
                peerDeviceName = peerDeviceName,
                peerPlatform = peerPlatform,
            )
        }
        return if (localData.hasLocalData) {
            JoinPolicy.ClearLocalTasks(localData.totalCount)
        } else {
            JoinPolicy.JoinDirectly
        }
    }
}

/**
 * 在写入 claim/join 前执行加入方的数据基准策略：需要时先询问用户，
 * 选择以对方为准时只标记“批准成功后需要清空本机数据”，不在配对前清空。
 */
class JoinPreparation(
    private val policyFor: suspend (peerDeviceName: String?, peerPlatform: DevicePlatform?) -> JoinPolicy,
    private val choose: suspend (JoinPolicy) -> JoinPolicyChoice,
) {
    suspend fun prepare(
        peerDeviceName: String?,
        peerPlatform: DevicePlatform?,
    ): JoinPreparationResult {
        val policy = policyFor(peerDeviceName, peerPlatform)
        if (policy is JoinPolicy.JoinDirectly) {
            return JoinPreparationResult.Ready(clearLocalDataAfterApproval = false)
        }
        return when (choose(policy)) {
            JoinPolicyChoice.Continue ->
                JoinPreparationResult.Ready(clearLocalDataAfterApproval = true)
            JoinPolicyChoice.UseLocalData -> JoinPreparationResult.UseLocalData
            JoinPolicyChoice.Cancel -> JoinPreparationResult.Cancelled
        }
    }
}

/**
 * 等对方批准后接管身份：只有批准成功拿到新身份后才按需删除旧身份并清空本机数据。
 * 配对失败、过期或取消时 [awaitIdentity] 抛出，本机任务与身份保持不变；
 * 删除旧身份或清空数据失败同样抛出，且不会采纳新身份。
 */
class JoinIdentityAdoption(
    private val clearLocalData: suspend () -> Unit,
    private val adoptIdentity: suspend (WebDavIdentity) -> Unit,
) {
    suspend fun awaitAndAdopt(
        clearLocalDataAfterApproval: Boolean,
        awaitIdentity: suspend () -> WebDavIdentity,
    ): WebDavIdentity {
        val identity = awaitIdentity()
        if (clearLocalDataAfterApproval) {
            clearLocalData()
        }
        adoptIdentity(identity)
        return identity
    }
}

/**
 * 加入其他空间前的本机数据重置顺序：
 * 1. 先删除并确认旧同步身份；删除失败或删除后仍能读到身份时立即抛出，
 *    任务与旧同步身份保持可用。
 * 2. 身份确认删除后才停止同步 Job，再原子清空任务与同步表。
 * 3. 清空失败时事务回滚、任务保留，并回调未配对刷新后继续抛出。
 *
 * 只有 [reset] 正常返回，调用方才允许采纳新身份。
 */
class JoinLocalDataReset(
    private val deleteIdentity: suspend () -> Unit,
    private val loadIdentity: suspend () -> WebDavIdentity?,
    private val stopSync: suspend () -> Unit,
    private val clearLocalData: suspend () -> Unit,
    private val onUnpaired: suspend () -> Unit,
) {
    suspend fun reset() {
        deleteIdentity()
        if (loadIdentity() != null) {
            throw WebDavPairingException.IdentityNotRemoved
        }
        // 身份已删除，后续任何失败都必须让界面离开旧同步状态。
        try {
            stopSync()
            clearLocalData()
        } catch (error: Exception) {
            withContext(NonCancellable) { onUnpaired() }
            throw error
        }
        onUnpaired()
    }
}
