package com.wootodo.sync

import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.currentCoroutineContext

sealed interface PairingProgress {
    data object Claiming : PairingProgress

    data class AwaitingConfirmation(
        val verificationCode: String,
        val expiresAt: Long,
    ) : PairingProgress

    data object SavingCredentials : PairingProgress
}

data class PairingCompletion(
    val vaultId: String,
    val deviceId: String,
)

sealed class PairingException(message: String) : Exception(message) {
    data object AlreadyPaired : PairingException("本机已经完成配对")
    data object InvalidClaim : PairingException("服务端返回了无效的配对认领结果")
    data object InvalidResult : PairingException("服务端返回了不一致的配对结果")
    data object Expired : PairingException("配对二维码已过期，请在 Mac 上重新生成")
    data object Canceled : PairingException("Mac 已取消本次配对，请重新扫码")
    data object LocalBindingFailed : PairingException(
        "本地任务库无法绑定到新设备，请先备份现有任务再处理本机同步状态",
    )
}

object PairingPollPolicy {
    const val INTERVAL_MILLIS = 2_000L
    private const val CLOCK_SKEW_GRACE_MILLIS = 30_000L

    fun canContinue(nowMillis: Long, expiresAt: Long): Boolean =
        nowMillis < expiresAt + CLOCK_SKEW_GRACE_MILLIS

    fun remainingSeconds(nowMillis: Long, expiresAt: Long): Long =
        ((expiresAt - nowMillis).coerceAtLeast(0L) + 999L) / 1_000L
}

/**
 * 新设备配对流程。临时私钥与设备令牌只在本次进程内存在；凭据完整解密并校验后才落盘。
 */
class PairingCoordinator(
    private val transportFactory: (String) -> PairingTransport,
    private val credentialsStore: SyncCredentialsStore,
    private val keyPairFactory: () -> PairingKeyPair = PairingKeyPair::generate,
    private val tokenFactory: () -> ByteArray = { SecureBytes.generate(DEVICE_TOKEN_BYTES) },
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    suspend fun pair(
        link: PairingDeepLink,
        deviceName: String,
        onProgress: (PairingProgress) -> Unit = {},
    ): PairingCompletion {
        if (credentialsStore.load() != null) throw PairingException.AlreadyPaired
        val normalizedDeviceName = normalizeDeviceName(deviceName)
        val keyPair = keyPairFactory()
        val tokenBytes = tokenFactory().also {
            require(it.size == DEVICE_TOKEN_BYTES) { "设备令牌必须为 32 字节" }
        }
        val deviceToken = Base64Url.encode(tokenBytes)
        var sessionKeyToDestroy: ByteArray? = null

        try {
            val transport = transportFactory(link.endpoint)
            onProgress(PairingProgress.Claiming)
            val claim = transport.claimPairing(
                link.pairingId,
                PairingClaimRequest(
                    pairingSecret = link.pairingSecret,
                    deviceToken = deviceToken,
                    device = DeviceRegistration(
                        name = normalizedDeviceName,
                        platform = DevicePlatform.ANDROID,
                        publicKey = keyPair.publicKeyBase64Url,
                    ),
                ),
            )
            currentCoroutineContext().ensureActive()
            validateClaim(link, claim)

            val sessionKey = keyPair.sessionKey(
                peerPublicKeyBase64Url = link.initiatorPublicKey,
                pairingId = link.pairingId,
                pairingSecretBase64Url = link.pairingSecret,
            )
            sessionKeyToDestroy = sessionKey
            val verificationCode = PairingSessionCrypto.verificationCode(
                sessionKey = sessionKey,
                initiatorPublicKey = Base64Url.decode(link.initiatorPublicKey),
                claimPublicKey = keyPair.publicKey,
            )
            onProgress(
                PairingProgress.AwaitingConfirmation(
                    verificationCode = verificationCode,
                    expiresAt = claim.expiresAt,
                ),
            )

            while (true) {
                val result = transport.pairingResult(
                    link.pairingId,
                    PairingResultRequest(
                        pairingSecret = link.pairingSecret,
                        deviceToken = deviceToken,
                    ),
                )
                currentCoroutineContext().ensureActive()
                if (result.pairingId != link.pairingId || result.expiresAt != claim.expiresAt) {
                    throw PairingException.InvalidResult
                }
                when (result.status) {
                    PairingStatus.CLAIMED -> {
                        validatePendingResult(result)
                        if (!PairingPollPolicy.canContinue(clockMillis(), result.expiresAt)) {
                            throw PairingException.Expired
                        }
                        pause(PairingPollPolicy.INTERVAL_MILLIS)
                    }

                    PairingStatus.CONFIRMED -> {
                        val credentials = openCredentials(
                            link = link,
                            claim = claim,
                            result = result,
                            deviceToken = deviceToken,
                            sessionKey = sessionKey,
                        )
                        currentCoroutineContext().ensureActive()
                        onProgress(PairingProgress.SavingCredentials)
                        if (!credentialsStore.saveIfAbsent(credentials)) {
                            throw PairingException.AlreadyPaired
                        }
                        return PairingCompletion(credentials.vaultId, credentials.deviceId)
                    }

                    PairingStatus.EXPIRED -> throw PairingException.Expired
                    PairingStatus.CANCELED -> throw PairingException.Canceled
                    PairingStatus.OPEN -> throw PairingException.InvalidResult
                }
            }
        } finally {
            tokenBytes.fill(0)
            sessionKeyToDestroy?.fill(0)
            keyPair.destroy()
        }
    }

    private fun validateClaim(link: PairingDeepLink, claim: PairingClaimData) {
        if (claim.pairingId != link.pairingId || claim.status != PairingStatus.CLAIMED ||
            claim.deviceId.isBlank() || claim.expiresAt <= 0
        ) {
            throw PairingException.InvalidClaim
        }
    }

    private fun validatePendingResult(result: PairingResultData) {
        if (result.vaultId != null || result.deviceId != null ||
            result.initiatorPublicKey != null || result.vaultKeyEnvelope != null
        ) {
            throw PairingException.InvalidResult
        }
    }

    private fun openCredentials(
        link: PairingDeepLink,
        claim: PairingClaimData,
        result: PairingResultData,
        deviceToken: String,
        sessionKey: ByteArray,
    ): SyncCredentials {
        val vaultId = result.vaultId?.takeIf { it.isNotBlank() }
            ?: throw PairingException.InvalidResult
        val deviceId = result.deviceId?.takeIf { it.isNotBlank() }
            ?: throw PairingException.InvalidResult
        val initiatorPublicKey = result.initiatorPublicKey
            ?: throw PairingException.InvalidResult
        val envelope = result.vaultKeyEnvelope ?: throw PairingException.InvalidResult
        if (deviceId != claim.deviceId ||
            !Base64Url.decode(initiatorPublicKey)
                .contentEquals(Base64Url.decode(link.initiatorPublicKey))
        ) {
            throw PairingException.InvalidResult
        }

        val vaultKey = PairingSessionCrypto.openVaultKey(
            envelope = envelope,
            sessionKey = sessionKey,
            pairingId = link.pairingId,
            claimedDeviceId = deviceId,
        )
        try {
            return SyncCredentials(
                endpoint = link.endpoint,
                vaultId = vaultId,
                deviceId = deviceId,
                deviceToken = deviceToken,
                vaultKey = vaultKey,
            ).also(SyncCredentials::validate)
        } finally {
            vaultKey.fill(0)
        }
    }

    private fun normalizeDeviceName(source: String): String {
        val normalized = source.trim().take(MAXIMUM_DEVICE_NAME_LENGTH)
        require(normalized.isNotEmpty() && normalized.none { it.code < 32 || it.code == 127 }) {
            "设备名称无效"
        }
        return normalized
    }

    private companion object {
        const val DEVICE_TOKEN_BYTES = 32
        const val MAXIMUM_DEVICE_NAME_LENGTH = 80
    }
}
