package com.wootodo.sync

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive

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
    val replacedExistingCredentials: Boolean = false,
)

sealed class PairingException(message: String) : Exception(message) {
    data object AlreadyPaired : PairingException("本机已经完成配对")
    data object InvalidEndpoint : PairingException(
        "同步服务地址无效，请填写部署好的 HTTPS Worker 地址",
    )
    data object InvalidCode : PairingException("请输入另一台设备显示的 6 位数字配对码")
    data object InvalidResolve : PairingException("配对码无法解析，请确认输入的是另一台设备显示的 6 位码")
    data object InvalidClaim : PairingException("服务端返回了无效的配对认领结果")
    data object InvalidResult : PairingException("服务端返回了不一致的配对结果")
    data object DifferentSyncSpace : PairingException(
        "配对请求属于另一个同步空间，本机没有切换同步身份",
    )
    data object UnsupportedPairingCode : PairingException("当前同步服务不支持六位配对码，请更新服务端")
    data object Expired : PairingException("配对码已过期（5 分钟有效），请重新生成")
    data object Canceled : PairingException("对方已取消本次配对，请重新生成配对码")
    data object JoinNotFound : PairingException("配对码无效或已过期（5 分钟有效），请重新输入")
    data object JoinCodeUsed : PairingException("配对码已被其他设备使用，请让对方重新显示")
    data object JoinNotReady : PairingException("配对请求尚未准备好确认，请稍后重试")
    data object DeviceLimit : PairingException("同步空间最多 4 台设备，请先移除一台旧设备")
    data object InvalidJoinResult : PairingException("服务端返回了无效的加入配对结果")
    data object CredentialsOverwritten : PairingException(
        "本机同步身份已被另一个配对流程更新，请返回后重新开始配对",
    )
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

/** 已有设备显示六位码时，新设备用固定 Worker 地址解析并认领配对。 */
class PairingCoordinator(
    private val clientFactory: (String) -> SyncApiClient = { endpoint -> SyncApiClient(endpoint) },
    private val credentialsStore: SyncCredentialsStore,
    private val keyPairFactory: () -> PairingKeyPair = PairingKeyPair::generate,
    private val tokenFactory: () -> ByteArray = { SecureBytes.generate(DEVICE_TOKEN_BYTES) },
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    suspend fun pair(
        endpoint: String,
        shortCode: String,
        deviceName: String,
        replaceExistingCredentials: Boolean = false,
        onProgress: (PairingProgress) -> Unit = {},
    ): PairingCompletion {
        val normalizedEndpoint = SyncEndpointPolicy.normalize(endpoint)
            ?: throw PairingException.InvalidEndpoint
        if (!SHORT_CODE.matches(shortCode)) throw PairingException.InvalidCode
        val storedCredentials = credentialsStore.load()
        val previousCredentials = storedCredentials
            ?.takeIf { SyncEndpointPolicy.isValid(it.endpoint) }
        // 旧版本保存的 LAN/WebDAV 地址视为未配对；重新配对会覆盖它们。
        if (previousCredentials != null && !replaceExistingCredentials) {
            throw PairingException.AlreadyPaired
        }
        val normalizedDeviceName = normalizeDeviceName(deviceName)
        val keyPair = keyPairFactory()
        val tokenBytes = tokenFactory().also {
            require(it.size == DEVICE_TOKEN_BYTES) { "设备令牌必须为 32 字节" }
        }
        val deviceToken = Base64Url.encode(tokenBytes)
        var sessionKeyToDestroy: ByteArray? = null
        var deviceClaimed = false
        var credentialsSaved = false
        var clientForRevoke: SyncApiClient? = null

        try {
            onProgress(PairingProgress.Claiming)
            val client = clientFactory(normalizedEndpoint)
            clientForRevoke = client
            val resolved = client.resolveShortCode(ResolveShortCodeRequest(shortCode))
            validateResolved(resolved)
            if (previousCredentials != null && replaceExistingCredentials &&
                previousCredentials.vaultId != resolved.vaultId
            ) {
                throw PairingException.DifferentSyncSpace
            }
            // 服务端绝对时间不能直接和本机时钟比较；换算成本机等待截止时间。
            val deadline = clockMillis() +
                maxOf(0L, resolved.expiresAt - resolved.serverTime)
            val claim = client.claimPairing(
                resolved.pairingId,
                PairingClaimRequest(
                    pairingSecret = resolved.pairingSecret,
                    deviceToken = deviceToken,
                    device = DeviceRegistration(
                        name = normalizedDeviceName,
                        platform = DevicePlatform.ANDROID,
                        publicKey = keyPair.publicKeyBase64Url,
                    ),
                ),
            )
            deviceClaimed = true
            currentCoroutineContext().ensureActive()
            validateClaim(resolved, claim)

            val sessionKey = keyPair.sessionKey(
                peerPublicKeyBase64Url = resolved.initiatorPublicKey,
                pairingId = resolved.pairingId,
                pairingSecretBase64Url = resolved.pairingSecret,
            )
            sessionKeyToDestroy = sessionKey
            val verificationCode = PairingSessionCrypto.verificationCode(
                sessionKey = sessionKey,
                initiatorPublicKey = Base64Url.decode(resolved.initiatorPublicKey),
                claimPublicKey = keyPair.publicKey,
            )
            onProgress(
                PairingProgress.AwaitingConfirmation(
                    verificationCode = verificationCode,
                    expiresAt = deadline,
                ),
            )

            while (true) {
                val result = client.pairingResult(
                    resolved.pairingId,
                    PairingResultRequest(
                        pairingSecret = resolved.pairingSecret,
                        deviceToken = deviceToken,
                    ),
                )
                currentCoroutineContext().ensureActive()
                if (result.pairingId != resolved.pairingId ||
                    result.expiresAt != claim.expiresAt
                ) {
                    throw PairingException.InvalidResult
                }
                when (result.status) {
                    PairingStatus.CLAIMED -> {
                        validatePendingResult(result)
                        if (!PairingPollPolicy.canContinue(clockMillis(), deadline)) {
                            throw PairingException.Expired
                        }
                        pause(PairingPollPolicy.INTERVAL_MILLIS)
                    }

                    PairingStatus.CONFIRMED -> {
                        if (previousCredentials != null && replaceExistingCredentials &&
                            result.vaultId != previousCredentials.vaultId
                        ) {
                            throw PairingException.DifferentSyncSpace
                        }
                        val credentials = openCredentials(
                            resolved = resolved,
                            endpoint = normalizedEndpoint,
                            claim = claim,
                            result = result,
                            deviceToken = deviceToken,
                            sessionKey = sessionKey,
                        )
                        currentCoroutineContext().ensureActive()
                        onProgress(PairingProgress.SavingCredentials)
                        if (storedCredentials != null) {
                            credentialsStore.save(credentials)
                        } else if (!credentialsStore.saveIfAbsent(credentials)) {
                            throw PairingException.AlreadyPaired
                        }
                        credentialsSaved = true
                        return PairingCompletion(
                            vaultId = credentials.vaultId,
                            deviceId = credentials.deviceId,
                            replacedExistingCredentials = storedCredentials != null,
                        )
                    }

                    PairingStatus.EXPIRED -> throw PairingException.Expired
                    PairingStatus.CANCELED -> throw PairingException.Canceled
                    PairingStatus.OPEN -> throw PairingException.InvalidResult
                }
            }
        } finally {
            // 认领成功后若流程失败、取消或保存凭据失败，撤销服务端已创建的设备，
            // 避免留下占用设备上限的幽灵设备；成功保存时保留新设备。
            if (deviceClaimed && !credentialsSaved) {
                clientForRevoke?.let { revokeTemporaryDevice(it, deviceToken) }
            }
            tokenBytes.fill(0)
            sessionKeyToDestroy?.fill(0)
            keyPair.destroy()
        }
    }

    private fun validateResolved(resolved: ResolveShortCodeData) {
        if (!IDENTIFIER.matches(resolved.pairingId) ||
            resolved.vaultId.isBlank() ||
            resolved.expiresAt <= 0 ||
            Base64Url.decode(resolved.pairingSecret).size != 32 ||
            Base64Url.decode(resolved.initiatorPublicKey).size != 32
        ) {
            throw PairingException.InvalidResolve
        }
    }

    private fun validateClaim(resolved: ResolveShortCodeData, claim: PairingClaimData) {
        if (claim.pairingId != resolved.pairingId ||
            claim.status != PairingStatus.CLAIMED ||
            !IDENTIFIER.matches(claim.deviceId) ||
            claim.expiresAt <= 0
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
        resolved: ResolveShortCodeData,
        endpoint: String,
        claim: PairingClaimData,
        result: PairingResultData,
        deviceToken: String,
        sessionKey: ByteArray,
    ): SyncCredentials {
        val vaultId = result.vaultId?.takeIf { it.isNotBlank() }
            ?: throw PairingException.InvalidResult
        if (vaultId != resolved.vaultId) {
            throw PairingException.DifferentSyncSpace
        }
        val deviceId = result.deviceId?.takeIf { it.isNotBlank() }
            ?: throw PairingException.InvalidResult
        val initiatorPublicKey = result.initiatorPublicKey
            ?: throw PairingException.InvalidResult
        val envelope = result.vaultKeyEnvelope ?: throw PairingException.InvalidResult
        if (deviceId != claim.deviceId ||
            !Base64Url.decode(initiatorPublicKey)
                .contentEquals(Base64Url.decode(resolved.initiatorPublicKey))
        ) {
            throw PairingException.InvalidResult
        }

        val vaultKey = PairingSessionCrypto.openVaultKey(
            envelope = envelope,
            sessionKey = sessionKey,
            pairingId = resolved.pairingId,
            claimedDeviceId = deviceId,
        )
        try {
            return SyncCredentials(
                endpoint = endpoint,
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
        val SHORT_CODE = Regex("^[0-9]{6}$")
        val IDENTIFIER = Regex("^[A-Za-z0-9._:-]{1,128}$")
    }
}
