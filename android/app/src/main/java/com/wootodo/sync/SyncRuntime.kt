package com.wootodo.sync

import java.util.concurrent.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

fun interface SyncRunner {
    fun synchronize(): SyncRunSummary
}

sealed interface SyncRuntimeState {
    /** 凭据仍在从 Android 安全存储读取，界面暂不应把设备当作未配对。 */
    data object Loading : SyncRuntimeState
    data object Unpaired : SyncRuntimeState
    data object Idle : SyncRuntimeState
    data object Running : SyncRuntimeState

    data class Succeeded(
        val summary: SyncRunSummary,
        val finishedAt: Long,
    ) : SyncRuntimeState

    data class Failed(
        val message: String,
        val retryable: Boolean,
        val finishedAt: Long,
    ) : SyncRuntimeState
}

sealed interface SyncExecutionResult {
    data object NotConfigured : SyncExecutionResult
    data class Succeeded(val summary: SyncRunSummary) : SyncExecutionResult
    data class Failed(val retryable: Boolean) : SyncExecutionResult
}

data class SyncFailureDescription(
    val message: String,
    val retryable: Boolean,
)

object SyncFailurePolicy {
    fun describe(error: Exception): SyncFailureDescription = when (error) {
        is WebDavException.Transport -> SyncFailureDescription("坚果云暂时不可达，联网后会自动重试", true)
        is WebDavException.Http -> {
            val retryable = error.statusCode in setOf(408, 425, 429) || error.statusCode in 500..599
            val message = if (error.statusCode == 401 || error.statusCode == 403) {
                "坚果云账号或应用密码无效"
            } else if (retryable) {
                "坚果云暂时不可用，稍后会自动重试"
            } else {
                "坚果云拒绝了同步请求（HTTP ${error.statusCode}）"
            }
            SyncFailureDescription(message, retryable)
        }
        is WebDavException -> SyncFailureDescription(error.message ?: "坚果云同步数据校验失败", false)
        is SyncApiException.Transport -> SyncFailureDescription("网络不可用，联网后会自动重试", true)
        is SyncApiException.Server -> {
            val capacityReached = error.payload.code == "VAULT_CAPACITY_REACHED"
            val retryable = !capacityReached && (
                error.statusCode in setOf(408, 425, 429) || error.statusCode in 500..599
                )
            val message = when {
                error.statusCode == 401 || error.statusCode == 403 ->
                    "设备授权已失效，请检查设备是否被撤销"

                capacityReached ->
                    "同步空间已达到存储上限，本地待发送任务仍会保留；请先导出加密备份"

                retryable -> "同步服务暂时不可用，稍后会自动重试"
                else -> "同步服务拒绝了本次请求（${error.payload.code}）"
            }
            SyncFailureDescription(message, retryable)
        }

        is SyncApiException.InvalidEndpoint -> SyncFailureDescription("同步服务地址无效", false)
        is SyncApiException.Decoding -> SyncFailureDescription("同步协议响应无法识别", false)
        is SyncCoordinatorException -> SyncFailureDescription("同步数据校验失败，已保留本地待发送任务", false)
        is SyncCryptoException -> SyncFailureDescription("同步密文校验失败，未应用远端数据", false)
        else -> SyncFailureDescription("同步未完成，已保留本地待发送任务", false)
    }
}

/** 应用进程内的单飞同步入口，前台、Widget 与 JobScheduler 共用同一个互斥锁。 */
class SyncRuntime(
    private val runnerFactory: () -> SyncRunner?,
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutex = Mutex()
    private val mutableState = MutableStateFlow<SyncRuntimeState>(SyncRuntimeState.Loading)
    val state: StateFlow<SyncRuntimeState> = mutableState.asStateFlow()

    fun refreshConfiguration(configured: Boolean) {
        if (mutableState.value == SyncRuntimeState.Running) return
        mutableState.value = if (configured) SyncRuntimeState.Idle else SyncRuntimeState.Unpaired
    }

    suspend fun synchronize(): SyncExecutionResult = mutex.withLock {
        val runner = try {
            withContext(ioDispatcher) { runnerFactory() }
        } catch (error: Exception) {
            return@withLock recordFailure(error)
        }
        if (runner == null) {
            mutableState.value = SyncRuntimeState.Unpaired
            return@withLock SyncExecutionResult.NotConfigured
        }

        mutableState.value = SyncRuntimeState.Running
        try {
            val summary = withContext(ioDispatcher) { runner.synchronize() }
            mutableState.value = SyncRuntimeState.Succeeded(summary, clockMillis())
            SyncExecutionResult.Succeeded(summary)
        } catch (error: CancellationException) {
            mutableState.value = SyncRuntimeState.Idle
            throw error
        } catch (error: Exception) {
            recordFailure(error)
        }
    }

    private fun recordFailure(error: Exception): SyncExecutionResult.Failed {
        val failure = SyncFailurePolicy.describe(error)
        mutableState.value = SyncRuntimeState.Failed(
            message = failure.message,
            retryable = failure.retryable,
            finishedAt = clockMillis(),
        )
        return SyncExecutionResult.Failed(failure.retryable)
    }
}
