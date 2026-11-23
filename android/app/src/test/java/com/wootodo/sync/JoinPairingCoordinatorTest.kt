package com.wootodo.sync

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class JoinPairingCoordinatorTest {
    private val endpoint = "https://sync.example.test"
    private val joinRequestId = "join-request-0001"
    private val deviceId = "device-new-0001"
    private val vaultId = "vault-join-test"
    private val joinSecret = ByteArray(32) { (it + 10).toByte() }
    private val vaultKey = ByteArray(32) { (it + 50).toByte() }
    private val deviceToken = ByteArray(32) { (it + 80).toByte() }
    private val creator = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 2).toByte() })
    private val approver = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 30).toByte() })
    private val approverCredentials = SyncCredentials(
        endpoint = endpoint,
        vaultId = vaultId,
        deviceId = "device-owner",
        deviceToken = Base64Url.encode(ByteArray(32) { (it + 70).toByte() }),
        vaultKey = vaultKey,
    )

    @Test
    fun `新设备显示码等待批准后解封密钥并保存凭据`() = runBlocking {
        val http = QueuedHttpConnectionFactory(creatorResponses())
        val store = MemoryCredentialsStore()
        val progress = mutableListOf<JoinCreationProgress>()
        val coordinator = JoinCreatorCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            credentialsStore = store,
            keyPairFactory = { creator },
            tokenFactory = { deviceToken.copyOf() },
            clockMillis = { 1_000L },
            pause = {},
        )

        val completion = coordinator.awaitApproval(endpoint, " 新 Android ") { progress += it }

        assertEquals(PairingCompletion(vaultId, deviceId), completion)
        assertEquals(
            JoinCreationProgress.Creating,
            progress.first(),
        )
        assertEquals(
            "123456",
            progress.filterIsInstance<JoinCreationProgress.AwaitingApproval>().single().shortCode,
        )
        assertTrue(
            progress.filterIsInstance<JoinCreationProgress.AwaitingConfirmation>().single()
                .verificationCode.matches(Regex("^[0-9]{6}$")),
        )
        assertEquals(JoinCreationProgress.SavingCredentials, progress.last())
        // 成功保存后不撤销新设备。
        assertTrue(http.paths().none { it.endsWith("/revoke") })

        val stored = requireNotNull(store.credentials)
        assertEquals(endpoint, stored.endpoint)
        assertEquals(vaultId, stored.vaultId)
        assertEquals(deviceId, stored.deviceId)
        assertEquals(Base64Url.encode(deviceToken), stored.deviceToken)
        assertTrue(stored.vaultKey.contentEquals(vaultKey))

        assertEquals(
            listOf(
                "/v1/pairings/join",
                "/v1/pairings/join/$joinRequestId/result",
                "/v1/pairings/join/$joinRequestId/result",
                "/v1/pairings/join/$joinRequestId/result",
            ),
            http.paths(),
        )
        val createBody = JSONObject(http.connections.first().sentBody())
        assertEquals(creator.publicKeyBase64Url, createBody.getString("publicKey"))
        assertEquals(Base64Url.encode(deviceToken), createBody.getString("deviceToken"))
        assertEquals("新 Android", createBody.getJSONObject("device").getString("name"))
        assertEquals("android", createBody.getJSONObject("device").getString("platform"))
        assertTrue(
            http.connections[1].sentBody().contains(Base64Url.encode(joinSecret)),
        )
    }

    @Test
    fun `批准结果设备标识不一致时拒绝保存`() = runBlocking {
        val http = QueuedHttpConnectionFactory(creatorResponses(wrongDeviceId = true))
        val store = MemoryCredentialsStore()
        val coordinator = JoinCreatorCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            credentialsStore = store,
            keyPairFactory = { creator },
            tokenFactory = { deviceToken.copyOf() },
            clockMillis = { 1_000L },
            pause = {},
        )

        val error = runCatching {
            coordinator.awaitApproval(endpoint, "新 Android")
        }.exceptionOrNull()

        assertSame(PairingException.InvalidJoinResult, error)
        assertNull(store.credentials)
    }

    @Test
    fun `新设备取消显示码时通知服务端作废请求`() = runBlocking {
        val created = successData(
            """
            {"joinRequestId":"$joinRequestId","joinSecret":"${Base64Url.encode(joinSecret)}",
            "shortCode":"123456","deviceId":"$deviceId","expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val open = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"open","deviceId":"$deviceId",
            "expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val canceled = successData(
            """{"joinRequestId":"$joinRequestId","status":"canceled","serverTime":2000}""",
        )
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(201, created),
                FakeHttpResponse(202, open),
                FakeHttpResponse(200, revokeData()),
                FakeHttpResponse(200, canceled),
            ),
        )
        lateinit var coordinator: JoinCreatorCoordinator
        coordinator = JoinCreatorCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            credentialsStore = MemoryCredentialsStore(),
            keyPairFactory = { creator },
            tokenFactory = { deviceToken.copyOf() },
            clockMillis = { 1_000L },
            pause = {
                coordinator.cancelActive()
                throw kotlinx.coroutines.CancellationException("测试取消")
            },
        )

        val error = runCatching {
            coordinator.awaitApproval(endpoint, "新 Android")
        }.exceptionOrNull()

        assertTrue(error is kotlinx.coroutines.CancellationException)
        // 先尽力撤销未批准的临时设备（服务端返回 401/403 时忽略），再作废请求。
        assertEquals(
            listOf(
                "/v1/pairings/join",
                "/v1/pairings/join/$joinRequestId/result",
                "/v1/devices/current/revoke",
                "/v1/pairings/join/$joinRequestId/cancel",
            ),
            http.paths(),
        )
    }

    @Test
    fun `批准方解析后显示核对码并提交可解封的信封`() = runBlocking {
        val http = QueuedHttpConnectionFactory(approverResponses())
        val coordinator = JoinApproverCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { approver },
            clockMillis = { 1_000L },
        )

        val target = coordinator.resolve(
            endpoint,
            "123456",
            approverCredentials,
        )

        val expectedSessionKey = PairingJoinCrypto.sessionKey(
            keyPair = creator,
            peerPublicKey = approver.publicKey,
            joinRequestId = joinRequestId,
        )
        val expectedCode = PairingJoinCrypto.verificationCode(
            sessionKey = expectedSessionKey,
            joinRequestId = joinRequestId,
            creatorPublicKey = creator.publicKey,
            approverPublicKey = approver.publicKey,
        )
        assertEquals(expectedCode, target.verificationCode)
        assertEquals("新 Android", target.deviceName)
        assertEquals(DevicePlatform.ANDROID, target.platform)

        val completion = coordinator.approve(target, approverCredentials)
        assertEquals(JoinApprovalCompletion(vaultId, deviceId), completion)

        assertEquals(
            listOf(
                "/v1/pairings/join/resolve",
                "/v1/pairings/join/$joinRequestId/approve",
            ),
            http.paths(),
        )
        val approveBody = JSONObject(http.connections.last().sentBody())
        val envelope = approveBody.getJSONObject("vaultKeyEnvelope")
        val plaintext = PairingJoinCrypto.openVaultKey(
            envelope = EncryptedEnvelope(
                ciphertext = envelope.getString("ciphertext"),
                nonce = envelope.getString("nonce"),
            ),
            sessionKey = expectedSessionKey,
            joinRequestId = joinRequestId,
            deviceId = deviceId,
        )
        try {
            assertTrue(plaintext.contentEquals(vaultKey))
        } finally {
            plaintext.fill(0)
            expectedSessionKey.fill(0)
        }
    }

    @Test
    fun `approved先到时先显示核对码等待本机确认后才保存`() = runBlocking {
        val http = QueuedHttpConnectionFactory(approvedFirstResponses())
        val store = MemoryCredentialsStore()
        val coordinator = JoinCreatorCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            credentialsStore = store,
            keyPairFactory = { creator },
            tokenFactory = { deviceToken.copyOf() },
            clockMillis = { 1_000L },
            pause = {},
        )

        val progress = mutableListOf<JoinCreationProgress>()
        var confirmationCode: String? = null
        var savedBeforeConfirmation = true
        val completion = coordinator.awaitApproval(endpoint, "新 Android") { update ->
            progress += update
            if (update is JoinCreationProgress.AwaitingConfirmation &&
                update.requiresConfirmation
            ) {
                confirmationCode = update.verificationCode
                savedBeforeConfirmation = store.credentials != null
                coordinator.confirmApproved()
            }
        }

        assertFalse(savedBeforeConfirmation)
        // 创建方协调器返回后会擦除 creator 私钥，这里用批准方密钥计算期望值。
        val expectedCode = PairingJoinCrypto.verificationCode(
            sessionKey = PairingJoinCrypto.sessionKey(
                keyPair = approver,
                peerPublicKey = creator.publicKey,
                joinRequestId = joinRequestId,
            ),
            joinRequestId = joinRequestId,
            creatorPublicKey = creator.publicKey,
            approverPublicKey = approver.publicKey,
        )
        assertEquals(expectedCode, confirmationCode)
        assertEquals(PairingCompletion(vaultId, deviceId), completion)
        assertTrue(requireNotNull(store.credentials).vaultKey.contentEquals(vaultKey))
        assertEquals(
            listOf(
                "/v1/pairings/join",
                "/v1/pairings/join/$joinRequestId/result",
            ),
            http.paths(),
        )
        assertTrue(progress[1] is JoinCreationProgress.AwaitingApproval)
        assertTrue(
            (progress[2] as JoinCreationProgress.AwaitingConfirmation).requiresConfirmation,
        )
        assertEquals(JoinCreationProgress.SavingCredentials, progress.last())
    }

    @Test
    fun `批准后取消会先撤销设备再作废请求`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                approvedFirstResponses()[0],
                approvedFirstResponses()[1],
                FakeHttpResponse(200, revokeData()),
                FakeHttpResponse(
                    200,
                    successData(
                        """{"joinRequestId":"$joinRequestId","status":"canceled","serverTime":2000}""",
                    ),
                ),
            ),
        )
        val coordinator = JoinCreatorCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            credentialsStore = MemoryCredentialsStore(),
            keyPairFactory = { creator },
            tokenFactory = { deviceToken.copyOf() },
            clockMillis = { 1_000L },
            pause = {},
        )
        val approved = CompletableDeferred<Unit>()
        val job = launch {
            runCatching {
                coordinator.awaitApproval(endpoint, "新 Android") { progress ->
                    if (progress is JoinCreationProgress.AwaitingConfirmation &&
                        progress.requiresConfirmation
                    ) {
                        approved.complete(Unit)
                    }
                }
            }
        }

        approved.await()
        coordinator.cancelActive()
        job.cancelAndJoin()

        assertEquals(
            listOf(
                "/v1/pairings/join",
                "/v1/pairings/join/$joinRequestId/result",
                "/v1/devices/current/revoke",
                "/v1/pairings/join/$joinRequestId/cancel",
            ),
            http.paths(),
        )
        assertEquals(
            "Bearer ${Base64Url.encode(deviceToken)}",
            http.connections[2].getRequestProperty("Authorization"),
        )
        assertTrue(
            http.connections[3].sentBody().contains(Base64Url.encode(joinSecret)),
        )
    }

    @Test
    fun `批准后保存凭据失败会撤销设备`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                approvedFirstResponses()[0],
                approvedFirstResponses()[1],
                FakeHttpResponse(200, revokeData()),
            ),
        )
        val coordinator = JoinCreatorCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            credentialsStore = JoinSaveRejectingStore(),
            keyPairFactory = { creator },
            tokenFactory = { deviceToken.copyOf() },
            clockMillis = { 1_000L },
            pause = {},
        )

        val error = runCatching {
            coordinator.awaitApproval(endpoint, "新 Android") { progress ->
                if (progress is JoinCreationProgress.AwaitingConfirmation &&
                    progress.requiresConfirmation
                ) {
                    coordinator.confirmApproved()
                }
            }
        }.exceptionOrNull()

        assertSame(PairingException.AlreadyPaired, error)
        assertEquals("/v1/devices/current/revoke", http.paths().last())
        assertEquals(
            "Bearer ${Base64Url.encode(deviceToken)}",
            http.connections.last().getRequestProperty("Authorization"),
        )
    }

    @Test
    fun `已显示核对码后批准公钥变化时拒绝保存`() = runBlocking {
        val otherApprover = PairingKeyPair.fromPrivateKey(ByteArray(32) { (it + 40).toByte() })
        val created = successData(
            """
            {"joinRequestId":"$joinRequestId","joinSecret":"${Base64Url.encode(joinSecret)}",
            "shortCode":"123456","deviceId":"$deviceId","expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val resolved = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"resolved","deviceId":"$deviceId",
            "approverPublicKey":"${approver.publicKeyBase64Url}",
            "expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val otherSessionKey = PairingJoinCrypto.sessionKey(
            keyPair = otherApprover,
            peerPublicKey = creator.publicKey,
            joinRequestId = joinRequestId,
        )
        val otherEnvelope = PairingJoinCrypto.sealVaultKey(
            vaultKey = vaultKey,
            sessionKey = otherSessionKey,
            joinRequestId = joinRequestId,
            deviceId = deviceId,
            nonce = ByteArray(12) { 6 },
        )
        otherSessionKey.fill(0)
        val approved = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"approved","vaultId":"$vaultId",
            "deviceId":"$deviceId",
            "approverPublicKey":"${otherApprover.publicKeyBase64Url}",
            "vaultKeyEnvelope":{"ciphertext":"${otherEnvelope.ciphertext}",
            "nonce":"${otherEnvelope.nonce}"},"expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(201, created),
                FakeHttpResponse(202, resolved),
                FakeHttpResponse(200, approved),
            ),
        )
        val store = MemoryCredentialsStore()
        val coordinator = JoinCreatorCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            credentialsStore = store,
            keyPairFactory = { creator },
            tokenFactory = { deviceToken.copyOf() },
            clockMillis = { 1_000L },
            pause = {},
        )

        val error = runCatching {
            coordinator.awaitApproval(endpoint, "新 Android")
        }.exceptionOrNull()

        assertSame(PairingException.InvalidJoinResult, error)
        assertNull(store.credentials)
    }

    @Test
    fun `批准方失败后保留目标并可重试成功`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(200, approverResponses().first().body),
                FakeHttpResponse(500, failureData("INTERNAL", "暂时失败")),
                FakeHttpResponse(200, approverResponses().last().body),
            ),
        )
        val coordinator = JoinApproverCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { approver },
            clockMillis = { 1_000L },
        )
        val target = coordinator.resolve(endpoint, "123456", approverCredentials)

        val firstError = runCatching {
            coordinator.approve(target, approverCredentials)
        }.exceptionOrNull()

        assertTrue(firstError is SyncApiException.Server)
        assertEquals(500, (firstError as SyncApiException.Server).statusCode)
        assertTrue(target.sessionKey.any { it != 0.toByte() })

        val completion = coordinator.approve(target, approverCredentials)
        assertEquals(JoinApprovalCompletion(vaultId, deviceId), completion)
        assertTrue(target.sessionKey.all { it == 0.toByte() })
    }

    @Test
    fun `批准方显式放弃时擦除保留的目标密钥`() = runBlocking {
        val http = QueuedHttpConnectionFactory(listOf(approverResponses().first()))
        val coordinator = JoinApproverCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { approver },
            clockMillis = { 1_000L },
        )
        val target = coordinator.resolve(endpoint, "123456", approverCredentials)

        coordinator.discard(target)

        assertTrue(target.sessionKey.all { it == 0.toByte() })
    }

    @Test
    fun `批准方拒绝服务端返回的其他公钥`() = runBlocking {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(
                    200,
                    successData(
                        """
                        {"joinRequestId":"$joinRequestId",
                        "joinPublicKey":"${creator.publicKeyBase64Url}",
                        "deviceId":"$deviceId",
                        "device":{"name":"新 Android","platform":"android"},
                        "approverPublicKey":"${Base64Url.encode(ByteArray(32) { 9 })}",
                        "expiresAt":301000,"serverTime":1000}
                        """.trimIndent(),
                    ),
                ),
            ),
        )
        val coordinator = JoinApproverCoordinator(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
            keyPairFactory = { approver },
            clockMillis = { 1_000L },
        )

        val error = runCatching {
            coordinator.resolve(endpoint, "123456", approverCredentials)
        }.exceptionOrNull()

        assertSame(PairingException.InvalidJoinResult, error)
    }

    private fun approvedFirstResponses(): List<FakeHttpResponse> {
        val created = successData(
            """
            {"joinRequestId":"$joinRequestId","joinSecret":"${Base64Url.encode(joinSecret)}",
            "shortCode":"123456","deviceId":"$deviceId","expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val sessionKey = PairingJoinCrypto.sessionKey(
            keyPair = approver,
            peerPublicKey = creator.publicKey,
            joinRequestId = joinRequestId,
        )
        val envelope = PairingJoinCrypto.sealVaultKey(
            vaultKey = vaultKey,
            sessionKey = sessionKey,
            joinRequestId = joinRequestId,
            deviceId = deviceId,
            nonce = ByteArray(12) { 5 },
        )
        sessionKey.fill(0)
        val approved = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"approved","vaultId":"$vaultId",
            "deviceId":"$deviceId",
            "approverPublicKey":"${approver.publicKeyBase64Url}",
            "vaultKeyEnvelope":{"ciphertext":"${envelope.ciphertext}",
            "nonce":"${envelope.nonce}"},"expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        return listOf(FakeHttpResponse(201, created), FakeHttpResponse(200, approved))
    }

    private fun failureData(code: String, message: String): String =
        """{"ok":false,"error":{"code":"$code","message":"$message"},"requestId":"req-test"}"""

    private fun revokeData(): String = successData(
        """{"deviceId":"$deviceId","revokedAt":1000}""",
    )

    private fun creatorResponses(wrongDeviceId: Boolean = false): List<FakeHttpResponse> {
        val created = successData(
            """
            {"joinRequestId":"$joinRequestId","joinSecret":"${Base64Url.encode(joinSecret)}",
            "shortCode":"123456","deviceId":"$deviceId","expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val open = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"open","deviceId":"$deviceId",
            "expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val resolved = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"resolved","deviceId":"$deviceId",
            "approverPublicKey":"${approver.publicKeyBase64Url}",
            "expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val resultDeviceId = if (wrongDeviceId) "device-other" else deviceId
        val sessionKey = PairingJoinCrypto.sessionKey(
            keyPair = approver,
            peerPublicKey = creator.publicKey,
            joinRequestId = joinRequestId,
        )
        val envelope = PairingJoinCrypto.sealVaultKey(
            vaultKey = vaultKey,
            sessionKey = sessionKey,
            joinRequestId = joinRequestId,
            deviceId = deviceId,
            nonce = ByteArray(12) { 5 },
        )
        sessionKey.fill(0)
        val approved = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"approved","vaultId":"$vaultId",
            "deviceId":"$resultDeviceId",
            "approverPublicKey":"${approver.publicKeyBase64Url}",
            "vaultKeyEnvelope":{"ciphertext":"${envelope.ciphertext}",
            "nonce":"${envelope.nonce}"},"expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        return listOf(
            FakeHttpResponse(201, created),
            FakeHttpResponse(202, open),
            FakeHttpResponse(202, resolved),
            FakeHttpResponse(200, approved),
        )
    }

    private fun approverResponses(): List<FakeHttpResponse> {
        val resolved = successData(
            """
            {"joinRequestId":"$joinRequestId",
            "joinPublicKey":"${creator.publicKeyBase64Url}",
            "deviceId":"$deviceId",
            "device":{"name":"新 Android","platform":"android"},
            "approverPublicKey":"${approver.publicKeyBase64Url}",
            "expiresAt":301000,"serverTime":1000}
            """.trimIndent(),
        )
        val approved = successData(
            """
            {"joinRequestId":"$joinRequestId","status":"approved","vaultId":"$vaultId",
            "deviceId":"$deviceId","expiresAt":301000}
            """.trimIndent(),
        )
        return listOf(FakeHttpResponse(200, resolved), FakeHttpResponse(200, approved))
    }
}

/** 模拟并发配对已经抢先保存：saveIfAbsent 返回 false。 */
private class JoinSaveRejectingStore : MemoryCredentialsStore() {
    override fun saveIfAbsent(credentials: SyncCredentials): Boolean = false
}
