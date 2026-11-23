package com.wootodo.ui

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wootodo.WooTodoApplication
import com.wootodo.sync.PairingCompletion
import com.wootodo.sync.PairingCoordinator
import com.wootodo.sync.PairingException
import com.wootodo.sync.PairingProgress
import com.wootodo.sync.SyncApiClient
import com.wootodo.sync.SyncApiException
import com.wootodo.sync.SyncCredentialsStore
import com.wootodo.sync.SyncCredentials
import com.wootodo.sync.SyncCryptoException
import com.wootodo.sync.SyncEndpointPolicy
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

sealed interface PairingUiState {
    data object Idle : PairingUiState
    data object Claiming : PairingUiState

    data class AwaitingConfirmation(
        val verificationCode: String,
        val expiresAt: Long,
    ) : PairingUiState

    data object SavingCredentials : PairingUiState
    data class Succeeded(val deviceId: String) : PairingUiState
    data class Failed(val message: String) : PairingUiState
    data object Interrupted : PairingUiState
}

object PairingRecoveryPolicy {
    fun requiresRescan(wasPairingInSavedState: Boolean, runtimeStillActive: Boolean): Boolean =
        wasPairingInSavedState && !runtimeStillActive
}

internal class PairingSessionGeneration {
    private val value = AtomicLong()

    fun advance(): Long = value.incrementAndGet()
    fun current(): Long = value.get()
    fun isCurrent(candidate: Long): Boolean = value.get() == candidate
}

class PairingViewModel(
    private val coordinator: PairingCoordinator,
    private val credentialsStore: SyncCredentialsStore,
    private val finalizePairing: suspend (PairingCompletion, SyncCredentials?) -> Unit,
) : ViewModel() {
    private val mutableState = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val state: StateFlow<PairingUiState> = mutableState.asStateFlow()
    private var pairingJob: Job? = null
    private var recoveryJob: Job? = null
    private val sessionGeneration = PairingSessionGeneration()

    fun prepareForNewPairing() {
        pairingJob?.cancel()
        recoveryJob?.cancel()
        pairingJob = null
        recoveryJob = null
        sessionGeneration.advance()
        mutableState.value = PairingUiState.Idle
    }

    fun begin(
        endpoint: String,
        shortCode: String,
        deviceName: String,
        replaceExistingCredentials: Boolean = false,
    ) {
        prepareForNewPairing()
        val generation = sessionGeneration.current()
        pairingJob = viewModelScope.launch {
            mutableState.value = PairingUiState.Claiming
            try {
                val attempt = withContext(Dispatchers.IO) {
                    val previousCredentials = credentialsStore.load()
                    val completion = coordinator.pair(
                        endpoint = endpoint,
                        shortCode = shortCode,
                        deviceName = deviceName,
                        replaceExistingCredentials = replaceExistingCredentials,
                    ) { progress ->
                        if (sessionGeneration.isCurrent(generation)) {
                            mutableState.value = progress.toUiState()
                        }
                    }
                    PairingAttempt(completion, previousCredentials)
                }
                if (!sessionGeneration.isCurrent(generation)) return@launch
                finalizePairing(attempt.completion, attempt.previousCredentials)
                if (sessionGeneration.isCurrent(generation)) {
                    mutableState.value = PairingUiState.Succeeded(attempt.completion.deviceId)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                Log.e(TAG, "配对流程失败", error)
                if (sessionGeneration.isCurrent(generation)) {
                    mutableState.value = PairingUiState.Failed(PairingErrorMessage.from(error))
                }
            }
        }
    }

    fun cancel() {
        pairingJob?.cancel()
        recoveryJob?.cancel()
        pairingJob = null
        recoveryJob = null
        sessionGeneration.advance()
        mutableState.value = PairingUiState.Idle
    }

    fun recoverInterruptedPairing() {
        if (isPairingActive()) return
        recoveryJob?.cancel()
        val generation = sessionGeneration.advance()
        recoveryJob = viewModelScope.launch {
            val credentials = withContext(Dispatchers.IO) {
                runCatching { credentialsStore.load() }.getOrNull()
            }
            if (credentials == null || !SyncEndpointPolicy.isValid(credentials.endpoint)) {
                if (sessionGeneration.isCurrent(generation)) {
                    mutableState.value = PairingUiState.Interrupted
                }
            } else {
                if (!sessionGeneration.isCurrent(generation)) return@launch
                val completion = PairingCompletion(
                    vaultId = credentials.vaultId,
                    deviceId = credentials.deviceId,
                    replacedExistingCredentials = true,
                )
                try {
                    finalizePairing(completion, null)
                    if (sessionGeneration.isCurrent(generation)) {
                        mutableState.value = PairingUiState.Succeeded(completion.deviceId)
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    Log.e(TAG, "恢复配对流程失败", error)
                    if (sessionGeneration.isCurrent(generation)) {
                        mutableState.value = PairingUiState.Failed(PairingErrorMessage.from(error))
                    }
                }
            }
            if (sessionGeneration.isCurrent(generation)) {
                recoveryJob = null
            }
        }
    }

    fun acknowledgeTerminalState() {
        if (mutableState.value is PairingUiState.Succeeded ||
            mutableState.value is PairingUiState.Failed ||
            mutableState.value == PairingUiState.Interrupted
        ) {
            mutableState.value = PairingUiState.Idle
        }
    }

    fun isPairingActive(): Boolean = when (mutableState.value) {
        PairingUiState.Claiming,
        is PairingUiState.AwaitingConfirmation,
        PairingUiState.SavingCredentials,
        -> true

        else -> false
    }

    private fun PairingProgress.toUiState(): PairingUiState = when (this) {
        PairingProgress.Claiming -> PairingUiState.Claiming
        is PairingProgress.AwaitingConfirmation -> PairingUiState.AwaitingConfirmation(
            verificationCode,
            expiresAt,
        )
        PairingProgress.SavingCredentials -> PairingUiState.SavingCredentials
    }

    class Factory(private val application: WooTodoApplication) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            val coordinator = PairingCoordinator(
                clientFactory = { endpoint -> SyncApiClient(endpoint) },
                credentialsStore = application.syncCredentialsStore,
            )
            return PairingViewModel(
                coordinator,
                application.syncCredentialsStore,
            ) { completion, previousCredentials ->
                // 保存后可能已被另一配对流程覆盖；此时不能再进入回滚覆盖胜出方。
                val stored = application.syncCredentialsStore.load()
                if (stored == null ||
                    stored.deviceId != completion.deviceId ||
                    stored.vaultId != completion.vaultId
                ) {
                    throw PairingException.CredentialsOverwritten
                }
                application.finalizePairing(completion, previousCredentials)
            } as T
        }
    }

    private companion object {
        const val TAG = "WooTodoPairing"
    }
}

private data class PairingAttempt(
    val completion: PairingCompletion,
    val previousCredentials: SyncCredentials?,
)

internal object PairingErrorMessage {
    fun from(error: Throwable): String = when (error) {
        PairingException.AlreadyPaired -> "本机已完成配对，无需再次配对"
        is PairingException -> requireNotNull(error.message)
        is SyncApiException.Transport -> when (error.cause) {
            is UnknownHostException -> "找不到同步服务，请检查网络和服务器地址"
            is ConnectException -> "无法连接同步服务，请检查网络和服务器地址"
            is SocketTimeoutException -> "连接同步服务超时，请检查网络后重试"
            is SSLException -> "同步服务的 HTTPS 证书校验失败，请检查服务器地址"
            else -> "无法连接同步服务，请检查网络和服务器地址"
        }
        is SyncApiException.Decoding -> "同步服务响应无法识别，请更新应用后重试"
        is SyncApiException.InvalidEndpoint -> "同步服务地址无效，请填写部署好的 HTTPS Worker 地址"
        is SyncApiException.Server -> when (error.payload.code) {
            "VAULT_DEVICE_LIMIT" -> "同步空间最多 4 台设备，请先移除一台旧设备"
            "PAIRING_EXPIRED" -> "配对码已过期（5 分钟有效），请重新生成"
            "PAIRING_NOT_FOUND" -> "配对码无效或已过期（5 分钟有效），请重新输入"
            "PAIRING_CODE_USED" -> "配对码已被其他设备使用，请让对方重新显示"
            "PAIRING_CANCELED" -> "对方已取消本次配对，请重新配对"
            "PAIRING_NOT_READY", "PAIRING_APPROVE_FAILED" ->
                "配对请求尚未准备好确认，请重新显示配对码"
            else -> when {
                error.statusCode == 401 || error.statusCode == 403 ->
                    "设备授权已失效，请先退出同步空间后重新配对"
                error.statusCode == 404 || error.statusCode == 410 ->
                    "配对码无效或已过期（5 分钟有效），请重新输入"
                error.statusCode == 409 -> "配对码已被使用或状态已改变，请重新配对"
                else -> "同步服务暂时无法完成配对（${error.payload.code}）"
            }
        }
        is SyncCryptoException -> "配对密钥协商或校验失败，请更新 Woo Todo 后重试"
        else -> error.localizedMessage
            ?.takeIf(String::isNotBlank)
            ?.let { "配对未完成：$it" }
            ?: "配对未完成，请确认两台设备显示同一组配对码后重试"
    }
}
