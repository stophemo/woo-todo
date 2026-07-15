package com.wootodo.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.wootodo.WooTodoApplication
import com.wootodo.sync.PairingCompletion
import com.wootodo.sync.PairingCoordinator
import com.wootodo.sync.PairingDeepLink
import com.wootodo.sync.PairingException
import com.wootodo.sync.PairingProgress
import com.wootodo.sync.SyncApiClient
import com.wootodo.sync.SyncApiException
import com.wootodo.sync.SyncCredentialsStore
import com.wootodo.sync.SyncCryptoException
import java.util.concurrent.CancellationException
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

class PairingViewModel(
    private val coordinator: PairingCoordinator,
    private val credentialsStore: SyncCredentialsStore,
    private val finalizePairing: suspend (PairingCompletion) -> Unit,
) : ViewModel() {
    private val mutableState = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val state: StateFlow<PairingUiState> = mutableState.asStateFlow()
    private var pairingJob: Job? = null

    fun begin(link: PairingDeepLink, deviceName: String) {
        pairingJob?.cancel()
        pairingJob = viewModelScope.launch {
            mutableState.value = PairingUiState.Claiming
            try {
                val completion = withContext(Dispatchers.IO) {
                    coordinator.pair(link, deviceName) { progress ->
                        mutableState.value = progress.toUiState()
                    }
                }
                finalizePairing(completion)
                mutableState.value = PairingUiState.Succeeded(completion.deviceId)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                mutableState.value = PairingUiState.Failed(PairingErrorMessage.from(error))
            }
        }
    }

    fun cancel() {
        pairingJob?.cancel()
        pairingJob = null
        mutableState.value = PairingUiState.Idle
    }

    fun recoverInterruptedPairing() {
        if (isPairingActive()) return
        viewModelScope.launch {
            val credentials = withContext(Dispatchers.IO) {
                runCatching { credentialsStore.load() }.getOrNull()
            }
            if (credentials == null) {
                mutableState.value = PairingUiState.Interrupted
            } else {
                val completion = PairingCompletion(credentials.vaultId, credentials.deviceId)
                try {
                    finalizePairing(completion)
                    mutableState.value = PairingUiState.Succeeded(completion.deviceId)
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    mutableState.value = PairingUiState.Failed(PairingErrorMessage.from(error))
                }
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
                transportFactory = { endpoint -> SyncApiClient(endpoint) },
                credentialsStore = application.syncCredentialsStore,
            )
            return PairingViewModel(
                coordinator,
                application.syncCredentialsStore,
                application::finalizePairing,
            ) as T
        }
    }
}

private object PairingErrorMessage {
    fun from(error: Exception): String = when (error) {
        PairingException.AlreadyPaired -> "本机已完成配对，无需再次扫码"
        is PairingException -> requireNotNull(error.message)
        is SyncApiException.Transport -> "网络连接失败，请保持联网后重新扫码"
        is SyncApiException.Decoding -> "同步服务响应无法识别，请更新应用后重试"
        is SyncApiException.InvalidEndpoint -> "配对链接中的同步服务地址无效"
        is SyncApiException.Server -> when {
            error.statusCode == 410 || error.payload.code == "PAIRING_EXPIRED" ->
                "配对二维码已过期，请在 Mac 上重新生成"

            error.statusCode == 409 -> "本次配对已被认领或状态已改变，请重新生成二维码"
            error.statusCode == 404 -> "找不到本次配对，请在 Mac 上重新生成二维码"
            else -> "同步服务暂时无法完成配对（${error.payload.code}）"
        }

        is SyncCryptoException -> "配对密钥校验失败，请确认六位码并重新扫码"
        else -> "配对未完成，请在 Mac 上重新生成二维码后再试"
    }
}
