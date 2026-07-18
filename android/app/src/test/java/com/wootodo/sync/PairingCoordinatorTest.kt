package com.wootodo.sync

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCoordinatorTest {
    @Test
    fun `认领后轮询确认并仅保存完整解密凭据`() = runBlocking {
        val fixture = PairingFixture()
        val store = MemoryCredentialsStore()
        val progress = mutableListOf<PairingProgress>()
        val pauses = mutableListOf<Long>()
        val coordinator = PairingCoordinator(
            transportFactory = { fixture.transport },
            credentialsStore = store,
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = { pauses += it },
        )

        val completion = coordinator.pair(fixture.link, "  Samsung Galaxy S23 Ultra  ") {
            progress += it
        }

        assertEquals(PairingCompletion(fixture.vaultId, fixture.deviceId), completion)
        assertEquals(listOf(PairingPollPolicy.INTERVAL_MILLIS), pauses)
        assertTrue(progress.first() == PairingProgress.Claiming)
        val waiting = progress.filterIsInstance<PairingProgress.AwaitingConfirmation>().single()
        assertTrue(waiting.verificationCode.matches(Regex("^[0-9]{6}$")))
        assertTrue(progress.last() == PairingProgress.SavingCredentials)
        assertEquals("Samsung Galaxy S23 Ultra", fixture.transport.claimRequest?.device?.name)

        assertNotNull(store.credentials)
        val credentials = requireNotNull(store.credentials)
        assertEquals(fixture.link.endpoint, credentials.endpoint)
        assertEquals(fixture.vaultId, credentials.vaultId)
        assertEquals(fixture.deviceId, credentials.deviceId)
        assertTrue(credentials.vaultKey.contentEquals(fixture.vaultKey))
    }

    @Test
    fun `确认结果发起方公钥不一致时拒绝落盘`() = runBlocking {
        val fixture = PairingFixture(wrongInitiatorInResult = true)
        val store = MemoryCredentialsStore()
        val coordinator = PairingCoordinator(
            transportFactory = { fixture.transport },
            credentialsStore = store,
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = {},
        )

        val error = runCatching { coordinator.pair(fixture.link, "Galaxy") }.exceptionOrNull()

        assertSame(PairingException.InvalidResult, error)
        assertNull(store.credentials)
    }

    @Test
    fun `本机已有凭据时不会认领新二维码`() = runBlocking {
        val fixture = PairingFixture()
        val store = MemoryCredentialsStore().apply {
            credentials = SyncCredentials(
                endpoint = fixture.link.endpoint,
                vaultId = fixture.vaultId,
                deviceId = fixture.deviceId,
                deviceToken = Base64Url.encode(fixture.deviceToken),
                vaultKey = fixture.vaultKey,
            )
        }
        val coordinator = PairingCoordinator(
            transportFactory = { fixture.transport },
            credentialsStore = store,
        )

        val error = runCatching { coordinator.pair(fixture.link, "Galaxy") }.exceptionOrNull()

        assertSame(PairingException.AlreadyPaired, error)
        assertNull(fixture.transport.claimRequest)
    }

    @Test
    fun `手机拒绝连接只属于当前设备的回环地址`() = runBlocking {
        var transportCreated = false
        val localLink = PairingDeepLink(
            endpoint = "http://127.0.0.1:8787",
            pairingId = "pair-local",
            pairingSecret = Base64Url.encode(ByteArray(32) { 1 }),
            initiatorPublicKey = Base64Url.encode(ByteArray(32) { 2 }),
        )
        val coordinator = PairingCoordinator(
            transportFactory = {
                transportCreated = true
                error("不应创建网络客户端")
            },
            credentialsStore = MemoryCredentialsStore(),
        )

        val error = runCatching { coordinator.pair(localLink, "Galaxy") }.exceptionOrNull()

        assertSame(PairingException.CurrentDeviceOnlyEndpoint, error)
        assertFalse(transportCreated)
    }
}

private class PairingFixture(
    wrongInitiatorInResult: Boolean = false,
) {
    val now = 1_000L
    val expiresAt = 601_000L
    val pairingId = "pairing-test-android"
    val deviceId = "device-android-test"
    val vaultId = "vault-test"
    val pairingSecret = ByteArray(32) { it.toByte() }
    val deviceToken = ByteArray(32) { (it + 32).toByte() }
    val vaultKey = ByteArray(32) { (it + 64).toByte() }
    val initiator = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 1).toByte() })
    val claimant = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 97).toByte() })
    val link = PairingDeepLink(
        endpoint = "https://sync.example.test",
        pairingId = pairingId,
        pairingSecret = Base64Url.encode(pairingSecret),
        initiatorPublicKey = initiator.publicKeyBase64Url,
    )
    val transport = ConfirmingPairingTransport(this, wrongInitiatorInResult)
}

private class ConfirmingPairingTransport(
    private val fixture: PairingFixture,
    private val wrongInitiatorInResult: Boolean,
) : PairingTransport {
    var claimRequest: PairingClaimRequest? = null
    private var resultCalls = 0

    override fun claimPairing(
        pairingId: String,
        request: PairingClaimRequest,
    ): PairingClaimData {
        assertEquals(fixture.pairingId, pairingId)
        claimRequest = request
        return PairingClaimData(
            pairingId = pairingId,
            status = PairingStatus.CLAIMED,
            deviceId = fixture.deviceId,
            expiresAt = fixture.expiresAt,
        )
    }

    override fun pairingResult(
        pairingId: String,
        request: PairingResultRequest,
    ): PairingResultData {
        resultCalls += 1
        if (resultCalls == 1) {
            return PairingResultData(
                pairingId = pairingId,
                status = PairingStatus.CLAIMED,
                vaultId = null,
                deviceId = null,
                initiatorPublicKey = null,
                vaultKeyEnvelope = null,
                expiresAt = fixture.expiresAt,
            )
        }
        val claimantPublicKey = requireNotNull(claimRequest?.device?.publicKey)
        val sessionKey = fixture.initiator.sessionKey(
            claimantPublicKey,
            fixture.pairingId,
            fixture.link.pairingSecret,
        )
        val envelope = PairingSessionCrypto.sealVaultKey(
            vaultKey = fixture.vaultKey,
            sessionKey = sessionKey,
            pairingId = fixture.pairingId,
            claimedDeviceId = fixture.deviceId,
            nonce = ByteArray(12) { 7 },
        )
        sessionKey.fill(0)
        return PairingResultData(
            pairingId = pairingId,
            status = PairingStatus.CONFIRMED,
            vaultId = fixture.vaultId,
            deviceId = fixture.deviceId,
            initiatorPublicKey = if (wrongInitiatorInResult) {
                Base64Url.encode(ByteArray(32) { 9 })
            } else {
                fixture.initiator.publicKeyBase64Url
            },
            vaultKeyEnvelope = envelope,
            expiresAt = fixture.expiresAt,
        )
    }
}

private class MemoryCredentialsStore : SyncCredentialsStore {
    var credentials: SyncCredentials? = null

    override fun save(credentials: SyncCredentials) {
        this.credentials = credentials
    }

    override fun saveIfAbsent(credentials: SyncCredentials): Boolean {
        if (this.credentials != null) return false
        save(credentials)
        return true
    }

    override fun load(): SyncCredentials? = credentials

    override fun delete() {
        credentials = null
    }
}
