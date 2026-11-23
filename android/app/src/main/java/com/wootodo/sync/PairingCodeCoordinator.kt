package com.wootodo.sync

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive

/** 已配对设备显示六位码的 Path A 发起方。 */
class PairingCodeOffer internal constructor(
    val endpoint: String,
    val pairingId: String,
    val pairingSecret: String,
    val shortCode: String,
    val expiresAt: Long,
    internal val keyPair: PairingKeyPair,
) {
    fun destroy() {
        keyPair.destroy()
    }
}

class PairingCodeClaim internal constructor(
    val deviceId: String,
    val deviceName: String,
    val platform: DevicePlatform,
    val verificationCode: String,
    internal val sessionKey: ByteArray,
    val expiresAt: Long,
) {
    fun destroy() {
        sessionKey.fill(0)
    }
}

sealed interface PairingCodeClaimResult {
    data class Claimed(val claim: PairingCodeClaim) : PairingCodeClaimResult
    data object Confirmed : PairingCodeClaimResult
}

class PairingCodeCoordinator(
    private val clientFactory: (String) -> SyncApiClient = { endpoint -> SyncApiClient(endpoint) },
    private val keyPairFactory: () -> PairingKeyPair = PairingKeyPair::generate,
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val pause: suspend (Long) -> Unit = { delay(it) },
) {
    suspend fun create(endpoint: String, credentials: SyncCredentials): PairingCodeOffer {
        val normalizedEndpoint = SyncEndpointPolicy.normalize(endpoint)
            ?: throw PairingException.InvalidEndpoint
        val keyPair = keyPairFactory()
        try {
            val created = clientFactory(normalizedEndpoint).createPairingCode(
                CreatePairingRequest(keyPair.publicKeyBase64Url),
                BearerCredential(credentials.deviceToken),
            )
            val shortCode = created.shortCode ?: throw PairingException.UnsupportedPairingCode
            if (!SHORT_CODE.matches(shortCode) ||
                created.pairingId.isBlank() ||
                created.expiresAt <= 0 ||
                Base64Url.decode(created.pairingSecret).size != 32 ||
                Base64Url.decode(created.initiatorPublicKey).size != 32 ||
                !Base64Url.decode(created.initiatorPublicKey).contentEquals(keyPair.publicKey)
            ) {
                throw PairingException.InvalidResult
            }
            return PairingCodeOffer(
                endpoint = normalizedEndpoint,
                pairingId = created.pairingId,
                pairingSecret = created.pairingSecret,
                shortCode = shortCode,
                expiresAt = clockMillis() + maxOf(0L, created.expiresAt - created.serverTime),
                keyPair = keyPair,
            )
        } catch (error: Exception) {
            keyPair.destroy()
            throw error
        }
    }

    suspend fun awaitClaim(
        offer: PairingCodeOffer,
        credentials: SyncCredentials,
    ): PairingCodeClaimResult {
        val client = clientFactory(offer.endpoint)
        val bearer = BearerCredential(credentials.deviceToken)
        while (true) {
            currentCoroutineContext().ensureActive()
            if (!PairingPollPolicy.canContinue(clockMillis(), offer.expiresAt)) {
                throw PairingException.Expired
            }
            val status = client.pairingStatus(offer.pairingId, bearer)
            if (status.pairingId != offer.pairingId) throw PairingException.InvalidResult
            when (status.status) {
                PairingStatus.CLAIMED -> {
                    val claim = status.claim ?: throw PairingException.InvalidResult
                    if (!IDENTIFIER.matches(claim.deviceId) || status.expiresAt <= 0) {
                        throw PairingException.InvalidResult
                    }
                    val sessionKey = offer.keyPair.sessionKey(
                        peerPublicKeyBase64Url = claim.publicKey,
                        pairingId = offer.pairingId,
                        pairingSecretBase64Url = offer.pairingSecret,
                    )
                    try {
                        return PairingCodeClaimResult.Claimed(
                            PairingCodeClaim(
                                deviceId = claim.deviceId,
                                deviceName = claim.name,
                                platform = claim.platform,
                                verificationCode = PairingSessionCrypto.verificationCode(
                                    sessionKey = sessionKey,
                                    initiatorPublicKey = offer.keyPair.publicKey,
                                    claimPublicKey = Base64Url.decode(claim.publicKey),
                                ),
                                sessionKey = sessionKey,
                                expiresAt = status.expiresAt,
                            ),
                        )
                    } catch (error: Exception) {
                        sessionKey.fill(0)
                        throw error
                    }
                }

                PairingStatus.CONFIRMED -> return PairingCodeClaimResult.Confirmed
                PairingStatus.OPEN -> pause(PairingPollPolicy.INTERVAL_MILLIS)
                PairingStatus.EXPIRED -> throw PairingException.Expired
                PairingStatus.CANCELED -> throw PairingException.Canceled
            }
        }
    }

    /**
     * 确认认领。只在服务端确认成功后擦除临时密钥；网络或服务端失败时保留
     * [offer]/[claim] 供重试，用户放弃时调用 [discard]。
     */
    suspend fun confirm(
        offer: PairingCodeOffer,
        claim: PairingCodeClaim,
        credentials: SyncCredentials,
    ) {
        val envelope = PairingSessionCrypto.sealVaultKey(
            vaultKey = credentials.vaultKey,
            sessionKey = claim.sessionKey,
            pairingId = offer.pairingId,
            claimedDeviceId = claim.deviceId,
        )
        val result = clientFactory(offer.endpoint).confirmPairing(
            offer.pairingId,
            PairingConfirmRequest(envelope),
            BearerCredential(credentials.deviceToken),
        )
        if (result.pairingId != offer.pairingId ||
            result.status != PairingStatus.CONFIRMED ||
            result.deviceId != claim.deviceId
        ) {
            throw PairingException.InvalidResult
        }
        claim.destroy()
        offer.destroy()
    }

    /** 用户显式取消时擦除保留的临时密钥。 */
    fun discard(claim: PairingCodeClaim, offer: PairingCodeOffer) {
        claim.destroy()
        offer.destroy()
    }

    private companion object {
        val SHORT_CODE = Regex("^[0-9]{6}$")
        val IDENTIFIER = Regex("^[A-Za-z0-9._:-]{1,128}$")
    }
}
