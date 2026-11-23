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
    fun `输入固定服务地址的六位码后认领并保存凭据`() = runBlocking {
        val fixture = PairingFixture()
        val store = MemoryCredentialsStore()
        val progress = mutableListOf<PairingProgress>()
        val pauses = mutableListOf<Long>()
        val http = QueuedHttpConnectionFactory(fixture.responses())
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(http),
            credentialsStore = store,
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = { pauses += it },
        )

        val completion = coordinator.pair(
            endpoint = " https://sync.example.test/ ",
            shortCode = "012345",
            deviceName = "  Android 测试设备  ",
        ) {
            progress += it
        }

        assertEquals(
            PairingCompletion(
                vaultId = fixture.vaultId,
                deviceId = fixture.deviceId,
                replacedExistingCredentials = false,
            ),
            completion,
        )
        assertEquals(listOf(PairingPollPolicy.INTERVAL_MILLIS), pauses)
        assertTrue(progress.first() == PairingProgress.Claiming)
        val waiting = progress.filterIsInstance<PairingProgress.AwaitingConfirmation>().single()
        assertTrue(waiting.verificationCode.matches(Regex("^[0-9]{6}$")))
        assertTrue(progress.last() == PairingProgress.SavingCredentials)
        assertTrue(
            http.connections[1].sentBody()
                .contains("\"name\":\"Android 测试设备\""),
        )

        assertNotNull(store.credentials)
        val credentials = requireNotNull(store.credentials)
        assertEquals("https://sync.example.test", credentials.endpoint)
        assertEquals(fixture.vaultId, credentials.vaultId)
        assertEquals(fixture.deviceId, credentials.deviceId)
        assertTrue(credentials.vaultKey.contentEquals(fixture.vaultKey))

        assertEquals(
            listOf(
                "/v1/pairings/resolve",
                "/v1/pairings/${fixture.pairingId}/claim",
                "/v1/pairings/${fixture.pairingId}/result",
                "/v1/pairings/${fixture.pairingId}/result",
            ),
            http.paths(),
        )
        // 成功保存后不撤销新设备。
        assertTrue(http.paths().none { it.endsWith("/revoke") })
        val resolveBody = http.connections.first().sentBody()
        assertTrue(resolveBody.contains("\"code\":\"012345\""))
        assertNull(http.connections.first().getRequestProperty("Authorization"))
    }

    @Test
    fun `本地时钟快十分钟仍能完成配对`() = runBlocking {
        val fixture = PairingFixture(
            now = 1_600_000L,
            serverNow = 1_000_000L,
            expiresAt = 1_300_000L,
        )
        val store = MemoryCredentialsStore()
        val waiting = mutableListOf<PairingProgress.AwaitingConfirmation>()
        val http = QueuedHttpConnectionFactory(fixture.responses())
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(http),
            credentialsStore = store,
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = {},
        )

        val completion = coordinator.pair(fixture.endpoint, "012345", "Android 设备") {
            if (it is PairingProgress.AwaitingConfirmation) waiting += it
        }

        assertEquals(fixture.deviceId, completion.deviceId)
        // 服务器 expiresAt 早于本机时钟，但本地等待截止时间按剩余有效期计算。
        assertEquals(
            fixture.now + (fixture.expiresAt - fixture.serverNow),
            waiting.single().expiresAt,
        )
        assertNotNull(store.credentials)
    }

    @Test
    fun `确认后保存凭据失败会撤销临时设备`() = runBlocking {
        val fixture = PairingFixture()
        val http = QueuedHttpConnectionFactory(
            fixture.responses() + FakeHttpResponse(200, revokeData(fixture.deviceId)),
        )
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(http),
            credentialsStore = RejectingSaveStore(),
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = {},
        )

        val error = runCatching {
            coordinator.pair(fixture.endpoint, "012345", "Android 设备")
        }.exceptionOrNull()

        assertSame(PairingException.AlreadyPaired, error)
        assertEquals("/v1/devices/current/revoke", http.paths().last())
        assertEquals(
            "Bearer ${Base64Url.encode(fixture.deviceToken)}",
            http.connections.last().getRequestProperty("Authorization"),
        )
    }

    @Test
    fun `认领后取消会撤销临时设备`() = runBlocking {
        val fixture = PairingFixture()
        val http = QueuedHttpConnectionFactory(
            fixture.responses().take(3) + FakeHttpResponse(200, revokeData(fixture.deviceId)),
        )
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(http),
            credentialsStore = MemoryCredentialsStore(),
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = { throw kotlinx.coroutines.CancellationException("测试取消") },
        )

        val error = runCatching {
            coordinator.pair(fixture.endpoint, "012345", "Android 设备")
        }.exceptionOrNull()

        assertTrue(error is kotlinx.coroutines.CancellationException)
        assertEquals("/v1/devices/current/revoke", http.paths().last())
    }

    @Test
    fun `非法服务地址不会发起网络请求`() = runBlocking {
        var clientCreated = false
        val coordinator = PairingCoordinator(
            clientFactory = {
                clientCreated = true
                error("不应创建客户端")
            },
            credentialsStore = MemoryCredentialsStore(),
        )

        val error = runCatching {
            coordinator.pair("http://192.168.1.10:8787", "012345", "Android 设备")
        }.exceptionOrNull()

        assertSame(PairingException.InvalidEndpoint, error)
        assertFalse(clientCreated)
    }

    @Test
    fun `确认结果发起方公钥不一致时拒绝落盘`() = runBlocking {
        val fixture = PairingFixture(wrongInitiatorInResult = true)
        val store = MemoryCredentialsStore()
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(QueuedHttpConnectionFactory(fixture.responses())),
            credentialsStore = store,
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = {},
        )

        val error = runCatching {
            coordinator.pair(fixture.endpoint, "012345", "Android 设备")
        }.exceptionOrNull()

        assertSame(PairingException.InvalidResult, error)
        assertNull(store.credentials)
    }

    @Test
    fun `本机已有有效凭据时不会再次认领`() = runBlocking {
        val fixture = PairingFixture()
        val store = MemoryCredentialsStore().apply {
            credentials = SyncCredentials(
                endpoint = fixture.endpoint,
                vaultId = fixture.vaultId,
                deviceId = fixture.deviceId,
                deviceToken = Base64Url.encode(fixture.deviceToken),
                vaultKey = fixture.vaultKey,
            )
        }
        val http = QueuedHttpConnectionFactory(emptyList())
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(http),
            credentialsStore = store,
        )

        val error = runCatching {
            coordinator.pair(fixture.endpoint, "012345", "Android 设备")
        }.exceptionOrNull()

        assertSame(PairingException.AlreadyPaired, error)
        assertTrue(http.connections.isEmpty())
    }

    @Test
    fun `换掉旧版本遗留的局域网凭据并重新绑定`() = runBlocking {
        val fixture = PairingFixture()
        val legacy = SyncCredentials(
            endpoint = "http://192.168.1.10:48473",
            vaultId = "old-vault",
            deviceId = "old-device",
            deviceToken = Base64Url.encode(ByteArray(32) { 3 }),
            vaultKey = ByteArray(32) { 4 },
        )
        val store = MemoryCredentialsStore().apply { credentials = legacy }
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(QueuedHttpConnectionFactory(fixture.responses())),
            credentialsStore = store,
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            clockMillis = { fixture.now },
            pause = {},
        )

        val completion = coordinator.pair(fixture.endpoint, "012345", "Android 设备")

        assertTrue(completion.replacedExistingCredentials)
        assertEquals(fixture.vaultId, requireNotNull(store.credentials).vaultId)
    }

    @Test
    fun `配对码解析失败不落盘`() = runBlocking {
        val fixture = PairingFixture()
        val store = MemoryCredentialsStore()
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(
                    status = 404,
                    body = """
                        {"ok":false,"error":{"code":"PAIRING_NOT_FOUND","message":"配对码无效或已过期"},
                        "requestId":"req-404"}
                    """.trimIndent(),
                ),
            ),
        )
        val coordinator = PairingCoordinator(
            clientFactory = fixture.clientFactory(http),
            credentialsStore = store,
            keyPairFactory = { fixture.claimant },
            tokenFactory = { fixture.deviceToken.copyOf() },
            pause = {},
        )

        val error = runCatching {
            coordinator.pair(fixture.endpoint, "012345", "Android 设备")
        }.exceptionOrNull()

        assertTrue(error is SyncApiException.Server)
        assertEquals(404, (error as SyncApiException.Server).statusCode)
        assertNull(store.credentials)
    }
}

private class PairingFixture(
    private val wrongInitiatorInResult: Boolean = false,
    val now: Long = 1_000L,
    val serverNow: Long = 1_000L,
    val expiresAt: Long = 601_000L,
) {
    val pairingId = "pairing-test-android"
    val deviceId = "device-android-test"
    val vaultId = "vault-test"
    val pairingSecret = ByteArray(32) { it.toByte() }
    val deviceToken = ByteArray(32) { (it + 32).toByte() }
    val vaultKey = ByteArray(32) { (it + 64).toByte() }
    val endpoint = "https://sync.example.test"
    val initiator = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 1).toByte() })
    val claimant = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 97).toByte() })

    fun clientFactory(
        http: QueuedHttpConnectionFactory,
    ): (String) -> SyncApiClient = { endpoint ->
        SyncApiClient(endpoint) { url -> http.create(url) }
    }

    fun responses(): List<FakeHttpResponse> {
        val resolve = successData(
            """
            {"pairingId":"$pairingId","pairingSecret":"${Base64Url.encode(pairingSecret)}",
            "initiatorPublicKey":"${initiator.publicKeyBase64Url}","vaultId":"$vaultId",
            "expiresAt":$expiresAt,"serverTime":$serverNow}
            """.trimIndent(),
        )
        val claim = successData(
            """
            {"pairingId":"$pairingId","status":"claimed","deviceId":"$deviceId",
            "expiresAt":$expiresAt}
            """.trimIndent(),
        )
        val pending = successData(
            """
            {"pairingId":"$pairingId","status":"claimed","vaultId":null,"deviceId":null,
            "initiatorPublicKey":null,"vaultKeyEnvelope":null,"expiresAt":$expiresAt}
            """.trimIndent(),
        )
        val confirmed = successData(confirmedData())
        return listOf(
            FakeHttpResponse(200, resolve),
            FakeHttpResponse(201, claim),
            FakeHttpResponse(202, pending),
            FakeHttpResponse(200, confirmed),
        )
    }

    private fun confirmedData(): String {
        val sessionKey = initiator.sessionKey(
            claimant.publicKey,
            pairingId,
            pairingSecret,
        )
        val envelope = PairingSessionCrypto.sealVaultKey(
            vaultKey = vaultKey,
            sessionKey = sessionKey,
            pairingId = pairingId,
            claimedDeviceId = deviceId,
            nonce = ByteArray(12) { 7 },
        )
        sessionKey.fill(0)
        val initiatorKey = if (wrongInitiatorInResult) {
            Base64Url.encode(ByteArray(32) { 9 })
        } else {
            initiator.publicKeyBase64Url
        }
        return """
            {"pairingId":"$pairingId","status":"confirmed","vaultId":"$vaultId",
            "deviceId":"$deviceId","initiatorPublicKey":"$initiatorKey",
            "vaultKeyEnvelope":{"ciphertext":"${envelope.ciphertext}",
            "nonce":"${envelope.nonce}"},"expiresAt":$expiresAt}
        """.trimIndent()
    }
}

private fun revokeData(deviceId: String): String = successData(
    """{"deviceId":"$deviceId","revokedAt":1000}""",
)

internal open class MemoryCredentialsStore : SyncCredentialsStore {
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

/** 模拟并发配对已经抢先保存：saveIfAbsent 返回 false。 */
private class RejectingSaveStore : MemoryCredentialsStore() {
    override fun saveIfAbsent(credentials: SyncCredentials): Boolean = false
}
