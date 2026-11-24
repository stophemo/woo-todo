package com.wootodo.sync

import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive

/** WebDAV 上的配对目录；生产实现直接映射到 v1/pairing/ 文件。 */
interface WebDavPairingStore {
    fun ensureDirectory()

    fun listFileNames(): List<String>

    /** 文件不存在返回 null；其他错误以 WebDavException 抛出。 */
    fun readFile(name: String): String?

    /** 写入成功或已有完全相同内容返回 true；已有不同内容返回 false。 */
    fun writeFileIfAbsent(name: String, content: String): Boolean

    fun deleteFile(name: String)
}

class WebDavPairingStoreClient(private val client: WebDavClient) : WebDavPairingStore {
    override fun ensureDirectory() = client.ensurePairingCollection()

    override fun listFileNames(): List<String> = client.listPairingFileNames()

    override fun readFile(name: String): String? = client.getPairingFileOrNull(name)

    override fun writeFileIfAbsent(name: String, content: String): Boolean =
        client.putPairingFileIfAbsent(name, content)

    override fun deleteFile(name: String) = client.deletePairingFile(name)
}

sealed class WebDavPairingException(message: String) : Exception(message) {
    data object InvalidCode :
        WebDavPairingException("请输入另一台设备显示的 6 位数字配对码")

    data object OfferNotFound :
        WebDavPairingException("配对码无效或已过期（5 分钟有效），请重新输入")

    data object JoinNotFound :
        WebDavPairingException("配对码无效或已过期（5 分钟有效），请重新输入")

    data object Expired :
        WebDavPairingException("配对码已过期（5 分钟有效），请重新生成")

    data object Conflict :
        WebDavPairingException("配对文件已被其他设备占用，请重新生成配对码")

    /** 同一六位码匹配到多份配对文件；不按远端 createdAt 自动择一。 */
    data object CodeConflict :
        WebDavPairingException("配对码冲突，请在已有设备重新生成配对码")

    data object InvalidFile :
        WebDavPairingException("配对文件内容无效，请更新应用后重试")

    data object InvalidApproval :
        WebDavPairingException("配对结果校验失败，请重新配对")

    data object AlreadyPaired :
        WebDavPairingException("本机已完成配对，无需再次配对")

    data object DifferentSyncSpace :
        WebDavPairingException("配对请求属于另一个同步空间，本机没有切换同步身份")

    data object CredentialsOverwritten :
        WebDavPairingException("本机同步身份已被另一个配对流程更新，请返回后重新开始配对")

    data object LocalBindingFailed :
        WebDavPairingException("本地任务库无法绑定到新设备，请先备份现有任务再处理本机同步状态")
}

class WebDavOfferSession internal constructor(
    val pairingId: String,
    val code: String,
    /** 本机等待认领的截止时间。 */
    val deadline: Long,
    internal val keyPair: PairingKeyPair,
    internal val pairingSecret: ByteArray,
) {
    fun destroy() {
        pairingSecret.fill(0)
        keyPair.destroy()
    }
}

class WebDavClaimInfo internal constructor(
    val deviceId: String,
    val deviceName: String,
    val platform: DevicePlatform,
    val verificationCode: String,
    val expiresAt: Long,
    internal val sessionKey: ByteArray,
) {
    fun destroy() {
        sessionKey.fill(0)
    }
}

class WebDavClaimSession internal constructor(
    val pairingId: String,
    val deviceId: String,
    val vaultId: String,
    val verificationCode: String,
    val peerDeviceName: String,
    val peerPlatform: DevicePlatform,
    val deadline: Long,
    internal val offerPublicKey: ByteArray,
    internal val sessionKey: ByteArray,
) {
    fun destroy() {
        offerPublicKey.fill(0)
        sessionKey.fill(0)
    }
}

/** 新设备在保存身份前必须人工确认的配对信息。 */
class WebDavPairingConfirmation(
    val verificationCode: String,
    val peerDeviceName: String?,
    val peerPlatform: DevicePlatform?,
    val vaultId: String,
)

class WebDavJoinResolution(
    val verificationCode: String,
    val approverName: String?,
    val deadline: Long,
)

class WebDavJoinSession internal constructor(
    val pairingId: String,
    val code: String,
    val deviceId: String,
    val deadline: Long,
    internal val keyPair: PairingKeyPair,
) {
    fun destroy() {
        keyPair.destroy()
    }
}

class WebDavJoinTarget internal constructor(
    val pairingId: String,
    val deviceId: String,
    val deviceName: String,
    val platform: DevicePlatform,
    val verificationCode: String,
    val expiresAt: Long,
    internal val joinPublicKey: ByteArray,
    internal val keyPair: PairingKeyPair,
    internal val sessionKey: ByteArray,
) {
    fun destroy() {
        joinPublicKey.fill(0)
        sessionKey.fill(0)
        keyPair.destroy()
    }
}

/**
 * 基于 v1/pairing/ JSON 文件的六位码配对。Path A：已有设备显示码；Path B：新设备显示码。
 * 六位码只负责定位，两端另显示由一次性 X25519 会话派生的核对码。
 */
class WebDavPairingCoordinator(
    private val store: WebDavPairingStore,
    private val keyPairFactory: () -> PairingKeyPair = PairingKeyPair::generate,
    private val codeFactory: () -> String = ::randomPairingCode,
    private val pairingIdFactory: () -> String = {
        UUID.randomUUID().toString().lowercase()
    },
    private val deviceIdFactory: () -> String = {
        UUID.randomUUID().toString().lowercase()
    },
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    /** 每个配对文件在本机的首次观察时间，用于相对 TTL；不信任远端 createdAt。 */
    private val observedAt = ConcurrentHashMap<String, Long>()

    // ---------- Path A：已有设备显示码，新设备输入 ----------

    fun createOffer(identity: WebDavIdentity, deviceName: String): WebDavOfferSession {
        identity.validate()
        val name = WebDavCredentialPolicy.normalizeDeviceName(deviceName)
        store.ensureDirectory()
        cleanupExpiredFiles()
        repeat(MAX_WRITE_ATTEMPTS) {
            val now = clockMillis()
            val pairingId = pairingIdFactory()
            val code = codeFactory()
            validatePairingId(pairingId)
            validateCode(code)
            val keyPair = keyPairFactory()
            val secret = SecureBytes.generate(32)
            val offer = PairingOffer(
                pairingId = pairingId,
                createdAt = now,
                expiresAt = now + PairingTimePolicy.TTL_MILLIS,
                code = code,
                publicKey = keyPair.publicKeyBase64Url,
                pairingSecret = Base64Url.encode(secret),
                vaultId = identity.vaultId,
                deviceName = name,
                platform = DevicePlatform.ANDROID,
            )
            if (store.writeFileIfAbsent(offer.fileName, offer.encode())) {
                return WebDavOfferSession(
                    pairingId = pairingId,
                    code = code,
                    deadline = now + PairingTimePolicy.TTL_MILLIS,
                    keyPair = keyPair,
                    pairingSecret = secret,
                )
            }
            keyPair.destroy()
            secret.fill(0)
        }
        throw WebDavPairingException.Conflict
    }

    /**
     * 查找唯一的 offer。同一六位码出现多份时不按远端 createdAt 择一，
     * 而是要求用户在已有设备重新生成配对码。
     */
    fun findOffer(code: String): PairingOffer {
        validateCode(code)
        store.ensureDirectory()
        cleanupExpiredFiles()
        val now = clockMillis()
        val result = mutableListOf<PairingOffer>()
        store.listFileNames().forEach { name ->
            val parsed = PairingFileNames.parse(name) ?: return@forEach
            if (parsed.kind != PairingFileKind.OFFER || parsed.code != code) return@forEach
            val content = store.readFile(name) ?: return@forEach
            // 无法解码或协议版本未知的文件只跳过，不删除其他版本写入的内容。
            val offer = runCatching { PairingOffer.decode(content) }.getOrNull()
                ?: return@forEach
            if (offer.pairingId != parsed.pairingId || offer.code != code) return@forEach
            if (isObservedExpired(name, offer.createdAt, offer.expiresAt, now)) {
                deleteObservedFile(name)
                return@forEach
            }
            result += offer
        }
        return when (result.size) {
            0 -> throw WebDavPairingException.OfferNotFound
            1 -> result.single()
            else -> throw WebDavPairingException.CodeConflict
        }
    }

    fun claimOffer(
        offer: PairingOffer,
        deviceName: String,
        deviceId: String = deviceIdFactory(),
    ): WebDavClaimSession {
        offer.validate()
        WebDavCredentialPolicy.isValidDeviceId(deviceId)
            .let { if (!it) throw WebDavPairingException.InvalidFile }
        val name = WebDavCredentialPolicy.normalizeDeviceName(deviceName)
        val now = clockMillis()
        val deadline = relativeDeadlineOrThrow(offer.fileName, offer.createdAt, offer.expiresAt, now)
        val keyPair = keyPairFactory()
        val claim = PairingClaim(
            pairingId = offer.pairingId,
            createdAt = now,
            expiresAt = now + maxOf(1_000L, deadline - now),
            publicKey = keyPair.publicKeyBase64Url,
            deviceId = deviceId,
            deviceName = name,
            platform = DevicePlatform.ANDROID,
        )
        try {
            if (!store.writeFileIfAbsent(claim.fileName, claim.encode())) {
                // 同一配对流程重试时允许自己留下的 claim。
                val existing = store.readFile(claim.fileName)?.let(PairingClaim::decode)
                if (existing == null ||
                    existing.deviceId != deviceId ||
                    existing.publicKey != keyPair.publicKeyBase64Url
                ) {
                    throw WebDavPairingException.Conflict
                }
            }
            val sessionKey = keyPair.sessionKey(
                peerPublicKeyBase64Url = offer.publicKey,
                pairingId = offer.pairingId,
                pairingSecretBase64Url = offer.pairingSecret,
            )
            try {
                return WebDavClaimSession(
                    pairingId = offer.pairingId,
                    deviceId = deviceId,
                    vaultId = offer.vaultId,
                    verificationCode = PairingSessionCrypto.verificationCode(
                        sessionKey = sessionKey,
                        initiatorPublicKey = Base64Url.decode(offer.publicKey),
                        claimPublicKey = keyPair.publicKey,
                    ),
                    peerDeviceName = offer.deviceName,
                    peerPlatform = offer.platform,
                    deadline = deadline,
                    offerPublicKey = Base64Url.decode(offer.publicKey),
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

    suspend fun awaitOfferClaim(session: WebDavOfferSession): WebDavClaimInfo {
        while (true) {
            currentCoroutineContext().ensureActive()
            if (!PairingTimePolicy.canContinue(clockMillis(), session.deadline)) {
                throw WebDavPairingException.Expired
            }
            val read = readForPolling(PairingFileNames.claim(session.pairingId))
            if (read.temporaryError) {
                pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                continue
            }
            val content = read.content
            if (content == null) {
                pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                continue
            }
            val claimName = PairingFileNames.claim(session.pairingId)
            val claim = runCatching { PairingClaim.decode(content) }.getOrNull()
            if (claim == null || claim.pairingId != session.pairingId) {
                // 无法解码的 claim 不删除，避免破坏其他协议版本写入的文件。
                pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                continue
            }
            val now = clockMillis()
            if (PairingTimePolicy.isExpired(
                    now,
                    observeFile(claimName, now),
                    claim.createdAt,
                    claim.expiresAt,
                )
            ) {
                // 本机已观察该 claim 超过其窗口：移除后继续等待新的 claim。
                deleteObservedFile(claimName)
                pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                continue
            }
            val sessionKey = session.keyPair.sessionKey(
                peerPublicKeyBase64Url = claim.publicKey,
                pairingId = session.pairingId,
                pairingSecretBase64Url = Base64Url.encode(session.pairingSecret),
            )
            try {
                val info = WebDavClaimInfo(
                    deviceId = claim.deviceId,
                    deviceName = claim.deviceName,
                    platform = claim.platform,
                    verificationCode = PairingSessionCrypto.verificationCode(
                        sessionKey = sessionKey,
                        initiatorPublicKey = session.keyPair.publicKey,
                        claimPublicKey = Base64Url.decode(claim.publicKey),
                    ),
                    expiresAt = session.deadline,
                    sessionKey = sessionKey,
                )
                // offer 里含 pairingSecret，认领后立即删除，避免被其他设备再次使用。
                runCatching { store.deleteFile(PairingFileNames.offer(session.code, session.pairingId)) }
                return info
            } catch (error: Exception) {
                sessionKey.fill(0)
                throw error
            }
        }
    }

    fun approveOffer(
        session: WebDavOfferSession,
        claim: WebDavClaimInfo,
        identity: WebDavIdentity,
    ) {
        identity.validate()
        if (!PairingTimePolicy.canContinue(clockMillis(), session.deadline)) {
            throw WebDavPairingException.Expired
        }
        val now = clockMillis()
        val approval = PairingApproval(
            pairingId = session.pairingId,
            createdAt = now,
            expiresAt = now + PairingTimePolicy.TTL_MILLIS,
            deviceId = claim.deviceId,
            vaultId = identity.vaultId,
            vaultKeyEnvelope = PairingSessionCrypto.sealVaultKey(
                vaultKey = identity.vaultKey,
                sessionKey = claim.sessionKey,
                pairingId = session.pairingId,
                claimedDeviceId = claim.deviceId,
            ),
            initiatorPublicKey = session.keyPair.publicKeyBase64Url,
            approverPublicKey = null,
        )
        val name = PairingFileNames.approval(session.pairingId)
        if (!store.writeFileIfAbsent(name, approval.encode())) {
            val existing = store.readFile(name)?.let(PairingApproval::decode)
            if (existing == null ||
                existing.deviceId != claim.deviceId ||
                existing.vaultId != identity.vaultId ||
                existing.initiatorPublicKey != session.keyPair.publicKeyBase64Url ||
                existing.approverPublicKey != null
            ) {
                throw WebDavPairingException.Conflict
            }
        }
        runCatching { store.deleteFile(PairingFileNames.claim(session.pairingId)) }
        runCatching { store.deleteFile(PairingFileNames.offer(session.code, session.pairingId)) }
        claim.destroy()
        session.destroy()
    }

    /**
     * 等待已有设备批准。解封 vaultKey 后先调用 [confirm] 等待本机人工核对，
     * 只有确认通过才删除配对文件并返回身份；轮询本身不会自动采纳身份。
     */
    suspend fun awaitOfferApproval(
        session: WebDavClaimSession,
        confirm: suspend (WebDavPairingConfirmation) -> Unit,
    ): WebDavIdentity {
        while (true) {
            currentCoroutineContext().ensureActive()
            if (!PairingTimePolicy.canContinue(clockMillis(), session.deadline)) {
                throw WebDavPairingException.Expired
            }
            val read = readForPolling(PairingFileNames.approval(session.pairingId))
            if (read.temporaryError) {
                pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                continue
            }
            val content = read.content
            if (content == null) {
                pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                continue
            }
            val approval = runCatching { PairingApproval.decode(content) }.getOrNull()
                ?: throw WebDavPairingException.InvalidApproval
            if (approval.pairingId != session.pairingId ||
                approval.deviceId != session.deviceId ||
                approval.vaultId != session.vaultId ||
                approval.approverPublicKey != null ||
                !Base64Url.decode(approval.initiatorPublicKey)
                    .contentEquals(session.offerPublicKey)
            ) {
                throw WebDavPairingException.InvalidApproval
            }
            val vaultKey = PairingSessionCrypto.openVaultKey(
                envelope = approval.vaultKeyEnvelope,
                sessionKey = session.sessionKey,
                pairingId = session.pairingId,
                claimedDeviceId = session.deviceId,
            )
            val identity = try {
                WebDavIdentity(
                    vaultId = approval.vaultId,
                    deviceId = session.deviceId,
                    vaultKey = vaultKey,
                ).also(WebDavIdentity::validate)
            } finally {
                vaultKey.fill(0)
            }
            try {
                confirm(
                    WebDavPairingConfirmation(
                        verificationCode = session.verificationCode,
                        peerDeviceName = session.peerDeviceName,
                        peerPlatform = session.peerPlatform,
                        vaultId = session.vaultId,
                    ),
                )
            } catch (error: Throwable) {
                identity.vaultKey.fill(0)
                throw error
            }
            deletePairingFiles(session.pairingId)
            session.destroy()
            return identity
        }
    }

    fun cancelOffer(session: WebDavOfferSession) {
        runCatching {
            store.deleteFile(PairingFileNames.offer(session.code, session.pairingId))
        }
        session.destroy()
    }

    fun cancelClaim(session: WebDavClaimSession) {
        runCatching { store.deleteFile(PairingFileNames.claim(session.pairingId)) }
        session.destroy()
    }

    // ---------- Path B：新设备显示码，已有设备输入并批准 ----------

    fun createJoin(
        deviceName: String,
        deviceId: String = deviceIdFactory(),
    ): WebDavJoinSession {
        if (!WebDavCredentialPolicy.isValidDeviceId(deviceId)) {
            throw WebDavPairingException.InvalidFile
        }
        val name = WebDavCredentialPolicy.normalizeDeviceName(deviceName)
        store.ensureDirectory()
        cleanupExpiredFiles()
        repeat(MAX_WRITE_ATTEMPTS) {
            val now = clockMillis()
            val pairingId = pairingIdFactory()
            val code = codeFactory()
            validatePairingId(pairingId)
            validateCode(code)
            val keyPair = keyPairFactory()
            val join = PairingJoin(
                pairingId = pairingId,
                createdAt = now,
                expiresAt = now + PairingTimePolicy.TTL_MILLIS,
                code = code,
                publicKey = keyPair.publicKeyBase64Url,
                deviceId = deviceId,
                deviceName = name,
                platform = DevicePlatform.ANDROID,
            )
            if (store.writeFileIfAbsent(join.fileName, join.encode())) {
                return WebDavJoinSession(
                    pairingId = pairingId,
                    code = code,
                    deviceId = deviceId,
                    deadline = now + PairingTimePolicy.TTL_MILLIS,
                    keyPair = keyPair,
                )
            }
            keyPair.destroy()
        }
        throw WebDavPairingException.Conflict
    }

    /** 查找唯一的 join；同一六位码冲突时要求用户在已有设备重新生成。 */
    fun findJoin(code: String): PairingJoin {
        validateCode(code)
        store.ensureDirectory()
        cleanupExpiredFiles()
        val now = clockMillis()
        val result = mutableListOf<PairingJoin>()
        store.listFileNames().forEach { name ->
            val parsed = PairingFileNames.parse(name) ?: return@forEach
            if (parsed.kind != PairingFileKind.JOIN || parsed.code != code) return@forEach
            val content = store.readFile(name) ?: return@forEach
            val join = runCatching { PairingJoin.decode(content) }.getOrNull()
                ?: return@forEach
            if (join.pairingId != parsed.pairingId || join.code != code) return@forEach
            if (isObservedExpired(name, join.createdAt, join.expiresAt, now)) {
                deleteObservedFile(name)
                return@forEach
            }
            result += join
        }
        return when (result.size) {
            0 -> throw WebDavPairingException.JoinNotFound
            1 -> result.single()
            else -> throw WebDavPairingException.CodeConflict
        }
    }

    /**
     * 等待已有设备 resolve + approval。必须先看到 resolve 的 approverPublicKey
     * 才处理 approval；解封 vaultKey 后仍需 [confirm] 完成本机人工核对，
     * 确认通过才返回身份。
     */
    suspend fun awaitJoinCompletion(
        session: WebDavJoinSession,
        onResolution: (WebDavJoinResolution) -> Unit = {},
        confirm: suspend (WebDavPairingConfirmation) -> Unit,
    ): WebDavIdentity {
        var approverPublicKey: ByteArray? = null
        var approverName: String? = null
        var verificationCode: String? = null
        var sessionKey: ByteArray? = null
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                if (!PairingTimePolicy.canContinue(clockMillis(), session.deadline)) {
                    throw WebDavPairingException.Expired
                }

                val resolveName = PairingFileNames.resolve(session.pairingId)
                val resolveRead = readForPolling(resolveName)
                if (resolveRead.temporaryError) {
                    pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                    continue
                }
                resolveRead.content?.let { content ->
                    val resolve = runCatching { PairingResolve.decode(content) }.getOrNull()
                        ?: throw WebDavPairingException.InvalidFile
                    if (resolve.pairingId != session.pairingId) {
                        throw WebDavPairingException.InvalidFile
                    }
                    val now = clockMillis()
                    if (!PairingTimePolicy.isExpired(
                            now,
                            observeFile(resolveName, now),
                            resolve.createdAt,
                            resolve.expiresAt,
                        )
                    ) {
                        val publicKey = Base64Url.decode(resolve.approverPublicKey)
                        val known = approverPublicKey
                        if (known != null && !known.contentEquals(publicKey)) {
                            throw WebDavPairingException.InvalidApproval
                        }
                        if (known == null) {
                            approverPublicKey = publicKey
                            approverName = resolve.approverName
                            sessionKey?.fill(0)
                            sessionKey = PairingJoinCrypto.sessionKey(
                                keyPair = session.keyPair,
                                peerPublicKey = publicKey,
                                joinRequestId = session.pairingId,
                            )
                            verificationCode = PairingJoinCrypto.verificationCode(
                                sessionKey = checkNotNull(sessionKey),
                                joinRequestId = session.pairingId,
                                creatorPublicKey = session.keyPair.publicKey,
                                approverPublicKey = publicKey,
                            )
                            onResolution(
                                WebDavJoinResolution(
                                    verificationCode = checkNotNull(verificationCode),
                                    approverName = resolve.approverName,
                                    deadline = session.deadline,
                                ),
                            )
                        }
                    }
                }

                val approvalRead = readForPolling(PairingFileNames.approval(session.pairingId))
                if (approvalRead.temporaryError) {
                    pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                    continue
                }
                val approvalContent = approvalRead.content
                if (approvalContent == null) {
                    pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                    continue
                }
                // 尚未看到 resolve 时，approval 一律忽略，不能用来解封 vaultKey。
                val known = approverPublicKey
                if (known == null) {
                    pause(PairingTimePolicy.POLL_INTERVAL_MILLIS)
                    continue
                }
                val approval = runCatching { PairingApproval.decode(approvalContent) }.getOrNull()
                    ?: throw WebDavPairingException.InvalidApproval
                val approver = approval.approverPublicKey
                    ?: throw WebDavPairingException.InvalidApproval
                if (!known.contentEquals(Base64Url.decode(approver))) {
                    throw WebDavPairingException.InvalidApproval
                }
                if (approval.pairingId != session.pairingId ||
                    approval.deviceId != session.deviceId ||
                    !Base64Url.decode(approval.initiatorPublicKey)
                        .contentEquals(session.keyPair.publicKey)
                ) {
                    throw WebDavPairingException.InvalidApproval
                }
                val vaultKey = PairingJoinCrypto.openVaultKey(
                    envelope = approval.vaultKeyEnvelope,
                    sessionKey = checkNotNull(sessionKey),
                    joinRequestId = session.pairingId,
                    deviceId = session.deviceId,
                )
                val identity = try {
                    WebDavIdentity(
                        vaultId = approval.vaultId,
                        deviceId = session.deviceId,
                        vaultKey = vaultKey,
                    ).also(WebDavIdentity::validate)
                } finally {
                    vaultKey.fill(0)
                }
                try {
                    confirm(
                        WebDavPairingConfirmation(
                            verificationCode = checkNotNull(verificationCode),
                            peerDeviceName = approverName,
                            peerPlatform = null,
                            vaultId = approval.vaultId,
                        ),
                    )
                } catch (error: Throwable) {
                    identity.vaultKey.fill(0)
                    throw error
                }
                deletePairingFiles(session.pairingId)
                session.destroy()
                return identity
            }
        } finally {
            sessionKey?.fill(0)
            approverPublicKey?.fill(0)
        }
    }

    fun resolveJoin(
        join: PairingJoin,
        identity: WebDavIdentity,
        deviceName: String,
    ): WebDavJoinTarget {
        identity.validate()
        join.validate()
        val name = WebDavCredentialPolicy.normalizeDeviceName(deviceName)
        val now = clockMillis()
        val deadline = relativeDeadlineOrThrow(join.fileName, join.createdAt, join.expiresAt, now)
        val keyPair = keyPairFactory()
        val resolve = PairingResolve(
            pairingId = join.pairingId,
            createdAt = now,
            expiresAt = now + maxOf(1_000L, deadline - now),
            approverPublicKey = keyPair.publicKeyBase64Url,
            approverDeviceId = identity.deviceId,
            approverName = name,
        )
        try {
            if (!store.writeFileIfAbsent(resolve.fileName, resolve.encode())) {
                val existing = store.readFile(resolve.fileName)?.let(PairingResolve::decode)
                if (existing == null ||
                    existing.approverDeviceId != identity.deviceId ||
                    existing.approverPublicKey != keyPair.publicKeyBase64Url
                ) {
                    throw WebDavPairingException.Conflict
                }
            }
            val sessionKey = PairingJoinCrypto.sessionKey(
                keyPair = keyPair,
                peerPublicKey = Base64Url.decode(join.publicKey),
                joinRequestId = join.pairingId,
            )
            try {
                return WebDavJoinTarget(
                    pairingId = join.pairingId,
                    deviceId = join.deviceId,
                    deviceName = join.deviceName,
                    platform = join.platform,
                    verificationCode = PairingJoinCrypto.verificationCode(
                        sessionKey = sessionKey,
                        joinRequestId = join.pairingId,
                        creatorPublicKey = Base64Url.decode(join.publicKey),
                        approverPublicKey = keyPair.publicKey,
                    ),
                    expiresAt = deadline,
                    joinPublicKey = Base64Url.decode(join.publicKey),
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

    fun approveJoin(target: WebDavJoinTarget, identity: WebDavIdentity) {
        identity.validate()
        if (!PairingTimePolicy.canContinue(clockMillis(), target.expiresAt)) {
            throw WebDavPairingException.Expired
        }
        val now = clockMillis()
        val approval = PairingApproval(
            pairingId = target.pairingId,
            createdAt = now,
            expiresAt = now + PairingTimePolicy.TTL_MILLIS,
            deviceId = target.deviceId,
            vaultId = identity.vaultId,
            vaultKeyEnvelope = PairingJoinCrypto.sealVaultKey(
                vaultKey = identity.vaultKey,
                sessionKey = target.sessionKey,
                joinRequestId = target.pairingId,
                deviceId = target.deviceId,
            ),
            // Path B 的 initiator 是新设备（join 创建方）；批准方公钥单独携带。
            initiatorPublicKey = Base64Url.encode(target.joinPublicKey),
            approverPublicKey = target.keyPair.publicKeyBase64Url,
        )
        val name = PairingFileNames.approval(target.pairingId)
        if (!store.writeFileIfAbsent(name, approval.encode())) {
            val existing = store.readFile(name)?.let(PairingApproval::decode)
            if (existing == null ||
                existing.deviceId != target.deviceId ||
                existing.vaultId != identity.vaultId ||
                existing.approverPublicKey != target.keyPair.publicKeyBase64Url
            ) {
                throw WebDavPairingException.Conflict
            }
        }
        target.destroy()
    }

    fun discardJoinTarget(target: WebDavJoinTarget) {
        target.destroy()
    }

    fun cancelJoinResolution(target: WebDavJoinTarget) {
        runCatching { store.deleteFile(PairingFileNames.resolve(target.pairingId)) }
        target.destroy()
    }

    fun cancelJoin(session: WebDavJoinSession) {
        runCatching { store.deleteFile(PairingFileNames.join(session.code, session.pairingId)) }
        session.destroy()
    }

    fun deletePairingFiles(pairingId: String) {
        runCatching {
            store.listFileNames().forEach { name ->
                val parsed = PairingFileNames.parse(name) ?: return@forEach
                if (parsed.pairingId == pairingId) {
                    runCatching { store.deleteFile(name) }
                    observedAt.remove(name)
                }
            }
        }
    }

    /**
     * 只删除“本机已经观察满一个相对 TTL”的合法配对文件。
     * 无法解码或 protocolVersion 未知的文件只跳过，避免破坏其他版本写入的内容。
     */
    private fun cleanupExpiredFiles(now: Long = clockMillis()) {
        store.listFileNames().forEach { name ->
            val parsed = PairingFileNames.parse(name) ?: return@forEach
            val content = runCatching { store.readFile(name) }.getOrNull() ?: return@forEach
            val file = runCatching { PairingFileCodec.decode(content) }.getOrNull()
                ?: return@forEach
            if (file.pairingId != parsed.pairingId || file.kind != parsed.kind) return@forEach
            if (isObservedExpired(name, file.createdAt, file.expiresAt, now)) {
                deleteObservedFile(name)
            }
        }
    }

    private fun observeFile(name: String, now: Long): Long =
        observedAt[name] ?: observedAt.putIfAbsent(name, now) ?: now

    private fun isObservedExpired(
        name: String,
        createdAt: Long,
        expiresAt: Long,
        now: Long,
    ): Boolean = PairingTimePolicy.isExpired(
        nowMillis = now,
        observedAtMillis = observeFile(name, now),
        createdAt = createdAt,
        expiresAt = expiresAt,
    )

    private fun relativeDeadlineOrThrow(
        name: String,
        createdAt: Long,
        expiresAt: Long,
        now: Long,
    ): Long {
        val observed = observeFile(name, now)
        val deadline = PairingTimePolicy.deadlineFrom(observed, createdAt, expiresAt)
            ?: throw WebDavPairingException.Expired
        if (now > deadline) throw WebDavPairingException.Expired
        return deadline
    }

    private fun deleteObservedFile(name: String) {
        runCatching { store.deleteFile(name) }
        observedAt.remove(name)
    }

    private fun readForPolling(name: String): PollRead = try {
        PollRead(store.readFile(name), temporaryError = false)
    } catch (error: WebDavException.Http) {
        when {
            error.statusCode == 404 -> PollRead(null, temporaryError = false)
            WebDavRetryPolicy.isRetryableHttpStatus(error.statusCode) ->
                PollRead(null, temporaryError = true)
            else -> throw error
        }
    } catch (error: WebDavException.Transport) {
        PollRead(null, temporaryError = true)
    }

    private fun validateCode(code: String) {
        if (!Regex("^[0-9]{6}$").matches(code)) {
            throw WebDavPairingException.InvalidCode
        }
    }

    private fun validatePairingId(pairingId: String) {
        if (!Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$").matches(pairingId)) {
            throw WebDavPairingException.InvalidFile
        }
    }

    private data class PollRead(val content: String?, val temporaryError: Boolean)

    companion object {
        internal const val MAX_WRITE_ATTEMPTS = 3

        internal fun randomPairingCode(): String {
            val value = java.nio.ByteBuffer
                .wrap(SecureBytes.generate(4))
                .int
                .toLong() and 0xffff_ffffL
            return (value % 1_000_000L).toString().padStart(6, '0')
        }
    }
}
