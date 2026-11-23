package com.wootodo.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

sealed interface JoinCreationProgress {
    data object Creating : JoinCreationProgress

    data class AwaitingApproval(
        val shortCode: String,
        val expiresAt: Long,
    ) : JoinCreationProgress

    /**
     * 核对码已可显示。服务端先回 approved、本机尚未核对过批准方公钥时
     * [requiresConfirmation] 为 true，必须由用户核对后调用 [JoinCreatorCoordinator.confirmApproved]。
     */
    data class AwaitingConfirmation(
        val verificationCode: String,
        val expiresAt: Long,
        val requiresConfirmation: Boolean = false,
    ) : JoinCreationProgress

    data object SavingCredentials : JoinCreationProgress
}

/**
 * 未配对设备显示六位码，由已配对设备输入并批准后取回同步密钥的 Path B 创建方。
 */
class JoinCreatorCoordinator(
    private val clientFactory: (String) -> SyncApiClient = { endpoint -> SyncApiClient(endpoint) },
    private val credentialsStore: SyncCredentialsStore,
    private val keyPairFactory: () -> PairingKeyPair = PairingKeyPair::generate,
    private val tokenFactory: () -> ByteArray = { SecureBytes.generate(DEVICE_TOKEN_BYTES) },
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    @Volatile
    private var activeRequest: ActiveJoinRequest? = null

    @Volatile
    private var pendingApprovedConfirmation: CompletableDeferred<Unit>? = null

    /** 用户核对 approved 先行到达时的核对码一致后调用；其它时机调用无效果。 */
    fun confirmApproved() {
        pendingApprovedConfirmation?.complete(Unit)
    }

    suspend fun awaitApproval(
        endpoint: String,
        deviceName: String,
        onProgress: (JoinCreationProgress) -> Unit = {},
    ): PairingCompletion {
        val normalizedEndpoint = SyncEndpointPolicy.normalize(endpoint)
            ?: throw PairingException.InvalidEndpoint
        val previousCredentials = credentialsStore.load()
        // 旧版本留下的 LAN/WebDAV 凭据视为未配对，可以重新加入新的同步空间。
        if (previousCredentials != null &&
            SyncEndpointPolicy.isValid(previousCredentials.endpoint)
        ) {
            throw PairingException.AlreadyPaired
        }
        val normalizedDeviceName = normalizeDeviceName(deviceName)
        val keyPair = keyPairFactory()
        val tokenBytes = tokenFactory().also {
            require(it.size == DEVICE_TOKEN_BYTES) { "设备令牌必须为 32 字节" }
        }
        val deviceToken = Base64Url.encode(tokenBytes)
        var sessionKeyToDestroy: ByteArray? = null

        try {
            onProgress(JoinCreationProgress.Creating)
            val client = clientFactory(normalizedEndpoint)
            val created = client.createJoinRequest(
                CreateJoinRequest(
                    publicKey = keyPair.publicKeyBase64Url,
                    deviceToken = deviceToken,
                    device = JoinDeviceRegistration(
                        name = normalizedDeviceName,
                        platform = DevicePlatform.ANDROID,
                    ),
                ),
            )
            validateCreated(created)
            activeRequest = ActiveJoinRequest(
                endpoint = normalizedEndpoint,
                joinRequestId = created.joinRequestId,
                joinSecret = created.joinSecret,
                deviceToken = deviceToken,
            )
            val deadline = clockMillis() +
                maxOf(0L, created.expiresAt - created.serverTime)
            onProgress(
                JoinCreationProgress.AwaitingApproval(
                    shortCode = created.shortCode,
                    expiresAt = deadline,
                ),
            )
            // 已显示核对码时保存当时的批准方公钥；approved 必须与它一致。
            var verifiedApproverPublicKey: ByteArray? = null

            while (true) {
                currentCoroutineContext().ensureActive()
                if (!PairingPollPolicy.canContinue(clockMillis(), deadline)) {
                    throw PairingException.Expired
                }
                val result = client.joinResult(
                    created.joinRequestId,
                    JoinResultRequest(created.joinSecret),
                )
                if (result.joinRequestId != created.joinRequestId ||
                    result.deviceId != created.deviceId
                ) {
                    throw PairingException.InvalidJoinResult
                }
                when (result.status) {
                    JoinRequestStatus.OPEN,
                    JoinRequestStatus.RESOLVED,
                    -> {
                        val approverPublicKey = result.approverPublicKey
                        if (approverPublicKey != null) {
                            val publicKey = Base64Url.decode(approverPublicKey)
                            val verified = verifiedApproverPublicKey
                            if (verified == null) {
                                val sessionKey = PairingJoinCrypto.sessionKey(
                                    keyPair = keyPair,
                                    peerPublicKey = publicKey,
                                    joinRequestId = created.joinRequestId,
                                )
                                sessionKeyToDestroy = sessionKey
                                verifiedApproverPublicKey = publicKey
                                onProgress(
                                    JoinCreationProgress.AwaitingConfirmation(
                                        verificationCode = PairingJoinCrypto.verificationCode(
                                            sessionKey = sessionKey,
                                            joinRequestId = created.joinRequestId,
                                            creatorPublicKey = keyPair.publicKey,
                                            approverPublicKey = publicKey,
                                        ),
                                        expiresAt = deadline,
                                    ),
                                )
                            } else if (!verified.contentEquals(publicKey)) {
                                throw PairingException.InvalidJoinResult
                            }
                        }
                        pause(PairingPollPolicy.INTERVAL_MILLIS)
                    }

                    JoinRequestStatus.APPROVED -> {
                        val vaultId = result.vaultId?.takeIf { it.isNotBlank() }
                            ?: throw PairingException.InvalidJoinResult
                        val approverPublicKey = result.approverPublicKey
                            ?: throw PairingException.InvalidJoinResult
                        val envelope = result.vaultKeyEnvelope
                            ?: throw PairingException.InvalidJoinResult
                        val approvedPublicKey = Base64Url.decode(approverPublicKey)
                        val verified = verifiedApproverPublicKey
                        if (verified == null) {
                            // approved 先于任何 resolved 到达：先展示核对码，禁止直接落盘。
                            val sessionKey = PairingJoinCrypto.sessionKey(
                                keyPair = keyPair,
                                peerPublicKey = approvedPublicKey,
                                joinRequestId = created.joinRequestId,
                            )
                            sessionKeyToDestroy = sessionKey
                            verifiedApproverPublicKey = approvedPublicKey
                            val confirmation = CompletableDeferred<Unit>()
                            pendingApprovedConfirmation = confirmation
                            try {
                                onProgress(
                                    JoinCreationProgress.AwaitingConfirmation(
                                        verificationCode = PairingJoinCrypto.verificationCode(
                                            sessionKey = sessionKey,
                                            joinRequestId = created.joinRequestId,
                                            creatorPublicKey = keyPair.publicKey,
                                            approverPublicKey = approvedPublicKey,
                                        ),
                                        expiresAt = deadline,
                                        requiresConfirmation = true,
                                    ),
                                )
                                confirmation.await()
                            } finally {
                                pendingApprovedConfirmation = null
                            }
                            currentCoroutineContext().ensureActive()
                        } else if (!verified.contentEquals(approvedPublicKey)) {
                            throw PairingException.InvalidJoinResult
                        }
                        val sessionKey = checkNotNull(sessionKeyToDestroy)
                        val vaultKey = PairingJoinCrypto.openVaultKey(
                            envelope = envelope,
                            sessionKey = sessionKey,
                            joinRequestId = created.joinRequestId,
                            deviceId = created.deviceId,
                        )
                        val credentials = try {
                            SyncCredentials(
                                endpoint = normalizedEndpoint,
                                vaultId = vaultId,
                                deviceId = created.deviceId,
                                deviceToken = deviceToken,
                                vaultKey = vaultKey,
                            ).also(SyncCredentials::validate)
                        } finally {
                            vaultKey.fill(0)
                        }
                        currentCoroutineContext().ensureActive()
                        onProgress(JoinCreationProgress.SavingCredentials)
                        try {
                            if (previousCredentials != null) {
                                credentialsStore.save(credentials)
                            } else if (!credentialsStore.saveIfAbsent(credentials)) {
                                throw PairingException.AlreadyPaired
                            }
                        } catch (error: Exception) {
                            // 批准后设备已在服务端创建，保存失败必须撤销，避免占用设备上限。
                            revokeTemporaryDevice(client, deviceToken)
                            throw error
                        }
                        activeRequest = null
                        return PairingCompletion(
                            vaultId = credentials.vaultId,
                            deviceId = credentials.deviceId,
                            replacedExistingCredentials = previousCredentials != null,
                        )
                    }

                    JoinRequestStatus.EXPIRED -> throw PairingException.Expired
                    JoinRequestStatus.CANCELED -> throw PairingException.Canceled
                }
            }
        } finally {
            pendingApprovedConfirmation = null
            tokenBytes.fill(0)
            sessionKeyToDestroy?.fill(0)
            keyPair.destroy()
        }
    }

    /** 用户取消时尽力撤销设备并通知服务端；失败不影响本地放弃本次配对。 */
    suspend fun cancelActive() {
        val request = activeRequest ?: return
        activeRequest = null
        withContext(Dispatchers.IO) {
            val client = runCatching { clientFactory(request.endpoint) }.getOrNull()
                ?: return@withContext
            // approved 后设备已创建；未批准时服务端返回 401/403，忽略即可。
            revokeTemporaryDevice(client, request.deviceToken)
            runCatching {
                client.cancelJoinRequest(
                    request.joinRequestId,
                    JoinResultRequest(request.joinSecret),
                )
            }
        }
    }

    private fun validateCreated(created: CreateJoinRequestData) {
        if (!IDENTIFIER.matches(created.joinRequestId) ||
            !IDENTIFIER.matches(created.deviceId) ||
            created.expiresAt <= 0 ||
            !SHORT_CODE.matches(created.shortCode) ||
            Base64Url.decode(created.joinSecret).size != 32
        ) {
            throw PairingException.InvalidJoinResult
        }
    }

    private fun normalizeDeviceName(source: String): String {
        val normalized = source.trim().take(MAXIMUM_DEVICE_NAME_LENGTH)
        require(normalized.isNotEmpty() && normalized.none { it.code < 32 || it.code == 127 }) {
            "设备名称无效"
        }
        return normalized
    }

    private data class ActiveJoinRequest(
        val endpoint: String,
        val joinRequestId: String,
        val joinSecret: String,
        val deviceToken: String,
    )

    private companion object {
        const val DEVICE_TOKEN_BYTES = 32
        const val MAXIMUM_DEVICE_NAME_LENGTH = 80
        val SHORT_CODE = Regex("^[0-9]{6}$")
        val IDENTIFIER = Regex("^[A-Za-z0-9._:-]{1,128}$")
    }
}

/** 已配对设备输入新设备六位码后解析、核对并批准。 */
class JoinApprovalTarget internal constructor(
    val endpoint: String,
    val joinRequestId: String,
    val deviceId: String,
    val deviceName: String,
    val platform: DevicePlatform,
    val verificationCode: String,
    val expiresAt: Long,
    internal val keyPair: PairingKeyPair,
    internal val sessionKey: ByteArray,
) {
    fun destroy() {
        sessionKey.fill(0)
        keyPair.destroy()
    }
}

data class JoinApprovalCompletion(
    val vaultId: String,
    val deviceId: String,
)

class JoinApproverCoordinator(
    private val clientFactory: (String) -> SyncApiClient = { endpoint -> SyncApiClient(endpoint) },
    private val keyPairFactory: () -> PairingKeyPair = PairingKeyPair::generate,
    private val clockMillis: () -> Long = System::currentTimeMillis,
) {
    suspend fun resolve(
        endpoint: String,
        shortCode: String,
        credentials: SyncCredentials,
    ): JoinApprovalTarget {
        val normalizedEndpoint = SyncEndpointPolicy.normalize(endpoint)
            ?: throw PairingException.InvalidEndpoint
        if (!SHORT_CODE.matches(shortCode)) throw PairingException.InvalidCode
        val keyPair = keyPairFactory()
        try {
            val resolved = clientFactory(normalizedEndpoint).resolveJoinRequest(
                ResolveJoinRequest(
                    code = shortCode,
                    publicKey = keyPair.publicKeyBase64Url,
                ),
                BearerCredential(credentials.deviceToken),
            )
            if (!IDENTIFIER.matches(resolved.joinRequestId) ||
                !IDENTIFIER.matches(resolved.deviceId) ||
                resolved.expiresAt <= 0 ||
                Base64Url.decode(resolved.joinPublicKey).size != 32 ||
                !Base64Url.decode(resolved.approverPublicKey)
                    .contentEquals(keyPair.publicKey)
            ) {
                throw PairingException.InvalidJoinResult
            }
            val joinPublicKey = Base64Url.decode(resolved.joinPublicKey)
            val sessionKey = PairingJoinCrypto.sessionKey(
                keyPair = keyPair,
                peerPublicKey = joinPublicKey,
                joinRequestId = resolved.joinRequestId,
            )
            try {
                return JoinApprovalTarget(
                    endpoint = normalizedEndpoint,
                    joinRequestId = resolved.joinRequestId,
                    deviceId = resolved.deviceId,
                    deviceName = resolved.device.name,
                    platform = resolved.device.platform,
                    verificationCode = PairingJoinCrypto.verificationCode(
                        sessionKey = sessionKey,
                        joinRequestId = resolved.joinRequestId,
                        creatorPublicKey = joinPublicKey,
                        approverPublicKey = keyPair.publicKey,
                    ),
                    expiresAt = clockMillis() +
                        maxOf(0L, resolved.expiresAt - resolved.serverTime),
                    keyPair = keyPair,
                    sessionKey = sessionKey,
                )
            } catch (error: Exception) {
                sessionKey.fill(0)
                throw error
            }
        } catch (error: Exception) {
            keyPair.destroy()
            throw error
        }
    }

    /**
     * 批准新设备。只在服务端确认成功后擦除临时密钥；网络或服务端失败时保留
     * [target] 供用户重试，用户放弃时调用 [discard]。
     */
    suspend fun approve(
        target: JoinApprovalTarget,
        credentials: SyncCredentials,
    ): JoinApprovalCompletion {
        val envelope = PairingJoinCrypto.sealVaultKey(
            vaultKey = credentials.vaultKey,
            sessionKey = target.sessionKey,
            joinRequestId = target.joinRequestId,
            deviceId = target.deviceId,
        )
        val result = clientFactory(target.endpoint).approveJoinRequest(
            target.joinRequestId,
            PairingConfirmRequest(envelope),
            BearerCredential(credentials.deviceToken),
        )
        if (result.joinRequestId != target.joinRequestId ||
            result.deviceId != target.deviceId ||
            result.vaultId != credentials.vaultId ||
            !result.status.equals("approved", ignoreCase = true)
        ) {
            throw PairingException.InvalidJoinResult
        }
        target.destroy()
        return JoinApprovalCompletion(
            vaultId = credentials.vaultId,
            deviceId = target.deviceId,
        )
    }

    /** 用户显式取消时擦除保留的临时密钥。 */
    fun discard(target: JoinApprovalTarget) {
        target.destroy()
    }

    private companion object {
        val SHORT_CODE = Regex("^[0-9]{6}$")
        val IDENTIFIER = Regex("^[A-Za-z0-9._:-]{1,128}$")
    }
}
