package com.wootodo.sync

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingCodeCoordinatorTest {
    private val endpoint = "https://sync.example.test"
    private val pairingId = "pairing-code-test"
    private val secret = Base64Url.encode(ByteArray(32) { it.toByte() })
    private val credentials = SyncCredentials(
        endpoint = endpoint,
        vaultId = "vault-code-test",
        deviceId = "device-owner",
        deviceToken = Base64Url.encode(ByteArray(32) { (it + 40).toByte() }),
        vaultKey = ByteArray(32) { (it + 60).toByte() },
    )
    private val keyPair = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 3).toByte() })
    private val claimant = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 90).toByte() })

    @Test
    fun `显示码改走五分钟createPairingCode并等待认领后确认`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(
                    201,
                    successData(
                        """
                        {"pairingId":"$pairingId","pairingSecret":"$secret",
                        "initiatorPublicKey":"${keyPair.publicKeyBase64Url}",
                        "expiresAt":301000,"serverTime":1000,"shortCode":"654321"}
                        """.trimIndent(),
                    ),
                ),
                FakeHttpResponse(
                    200,
                    successData(
                        """
                        {"pairingId":"$pairingId","status":"claimed","expiresAt":301000,
                        "claim":{"deviceId":"device-new","name":"新手机","platform":"android",
                        "publicKey":"${claimant.publicKeyBase64Url}","claimedAt":2000}}
                        """.trimIndent(),
                    ),
                ),
                FakeHttpResponse(
                    200,
                    successData(
                        """
                        {"pairingId":"$pairingId","status":"confirmed","deviceId":"device-new"}
                        """.trimIndent(),
                    ),
                ),
            ),
        )
        val coordinator = PairingCodeCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { keyPair },
            clockMillis = { 1_000L },
        )

        val offer = coordinator.create(endpoint, credentials)
        assertEquals("654321", offer.shortCode)
        val claim = (coordinator.awaitClaim(offer, credentials) as PairingCodeClaimResult.Claimed)
            .claim
        assertEquals("device-new", claim.deviceId)
        assertEquals("新手机", claim.deviceName)
        assertTrue(claim.verificationCode.matches(Regex("^[0-9]{6}$")))

        coordinator.confirm(offer, claim, credentials)

        assertEquals(
            listOf(
                "/v1/pairings/code",
                "/v1/pairings/$pairingId",
                "/v1/pairings/$pairingId/confirm",
            ),
            http.paths(),
        )
        assertTrue(http.connections.first().sentBody().contains(keyPair.publicKeyBase64Url))
        assertEquals(
            "Bearer ${credentials.deviceToken}",
            http.connections.first().getRequestProperty("Authorization"),
        )
        assertTrue(http.connections.last().sentBody().contains("vaultKeyEnvelope"))
    }

    @Test
    fun `确认失败保留认领会话并可重试成功`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(201, createResponse()),
                FakeHttpResponse(200, claimedResponse()),
                FakeHttpResponse(
                    500,
                    """{"ok":false,"error":{"code":"INTERNAL","message":"暂时失败"},"requestId":"req-test"}""",
                ),
                FakeHttpResponse(200, confirmedResponse()),
            ),
        )
        val coordinator = PairingCodeCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { keyPair },
            clockMillis = { 1_000L },
        )
        val offer = coordinator.create(endpoint, credentials)
        val claim = (coordinator.awaitClaim(offer, credentials) as PairingCodeClaimResult.Claimed)
            .claim

        val error = runCatching {
            coordinator.confirm(offer, claim, credentials)
        }.exceptionOrNull()

        assertTrue(error is SyncApiException.Server)
        assertTrue(claim.sessionKey.any { it != 0.toByte() })

        coordinator.confirm(offer, claim, credentials)
        assertTrue(claim.sessionKey.all { it == 0.toByte() })
        coordinator.discard(claim, offer)
        assertEquals(4, http.paths().size)
    }

    @Test
    fun `显式放弃时擦除认领会话密钥`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(201, createResponse()),
                FakeHttpResponse(200, claimedResponse()),
            ),
        )
        val coordinator = PairingCodeCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { keyPair },
            clockMillis = { 1_000L },
        )
        val offer = coordinator.create(endpoint, credentials)
        val claim = (coordinator.awaitClaim(offer, credentials) as PairingCodeClaimResult.Claimed)
            .claim

        coordinator.discard(claim, offer)

        assertTrue(claim.sessionKey.all { it == 0.toByte() })
    }

    @Test
    fun `服务端未返回六位码时提示服务端不支持`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(
                    201,
                    successData(
                        """
                        {"pairingId":"$pairingId","pairingSecret":"$secret",
                        "initiatorPublicKey":"${keyPair.publicKeyBase64Url}",
                        "expiresAt":301000,"serverTime":1000}
                        """.trimIndent(),
                    ),
                ),
            ),
        )
        val coordinator = PairingCodeCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { keyPair },
            clockMillis = { 1_000L },
        )

        val error = runCatching { coordinator.create(endpoint, credentials) }.exceptionOrNull()

        assertSame(PairingException.UnsupportedPairingCode, error)
    }

    private fun createResponse(): String = successData(
        """
        {"pairingId":"$pairingId","pairingSecret":"$secret",
        "initiatorPublicKey":"${keyPair.publicKeyBase64Url}",
        "expiresAt":301000,"serverTime":1000,"shortCode":"654321"}
        """.trimIndent(),
    )

    private fun claimedResponse(): String = successData(
        """
        {"pairingId":"$pairingId","status":"claimed","expiresAt":301000,
        "claim":{"deviceId":"device-new","name":"新手机","platform":"android",
        "publicKey":"${claimant.publicKeyBase64Url}","claimedAt":2000}}
        """.trimIndent(),
    )

    private fun confirmedResponse(): String = successData(
        """{"pairingId":"$pairingId","status":"confirmed","deviceId":"device-new"}""",
    )
}
