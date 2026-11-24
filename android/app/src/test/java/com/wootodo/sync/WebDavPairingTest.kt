package com.wootodo.sync

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavPairingTest {
    private val identity = WebDavIdentity(
        vaultId = "vault-test-0001",
        deviceId = "device-mac-0001",
        vaultKey = ByteArray(32) { (it + 1).toByte() },
    )

    @Test
    fun `PathA完整流程核对码一致并解封vaultKey`() = runBlocking {
        val clock = TestClock()
        val store = MemoryPairingStore()
        val creator = coordinator(store, clock = clock)
        val offer = creator.createOffer(identity, "MacBook")
        assertEquals("123456", offer.code)

        val joiner = coordinator(
            store,
            code = "654321",
            pairingId = "pairing-claim-0001",
            clock = clock,
        )
        val offerFile = joiner.findOffer("123456")
        assertEquals("MacBook", offerFile.deviceName)

        val claim = joiner.claimOffer(offerFile, "Pixel", deviceId = "device-android-0001")
        val claimInfo = creator.awaitOfferClaim(offer)

        assertEquals(claim.verificationCode, claimInfo.verificationCode)
        // 持有空间方显示加入方设备名/平台与核对码，用于唯一一次“批准加入”。
        assertEquals("Pixel", claimInfo.deviceName)
        assertEquals(DevicePlatform.ANDROID, claimInfo.platform)
        creator.approveOffer(offer, claimInfo, identity)
        val result = joiner.awaitOfferApproval(claim)

        assertEquals(identity.vaultId, result.vaultId)
        assertEquals("device-android-0001", result.deviceId)
        assertArrayEquals(identity.vaultKey, result.vaultKey)
        assertTrue(store.files.isEmpty())
    }

    @Test
    fun `PathA批准文件只包含密文与公钥不含vaultKey明文`() {
        val store = MemoryPairingStore()
        val coordinator = coordinator(store, code = "123456", pairingId = "pairing-a-0001")
        val offer = coordinator.createOffer(identity, "MacBook")
        val claim = runBlocking {
            val joiner = coordinator(store, code = "654321", pairingId = "pairing-claim-0001")
            joiner.claimOffer(
                joiner.findOffer("123456"),
                "Pixel",
                deviceId = "device-android-0001",
            )
        }
        val info = runBlocking { coordinator.awaitOfferClaim(offer) }
        coordinator.approveOffer(offer, info, identity)

        val approval = store.files[PairingFileNames.approval(offer.pairingId)]
        assertNotNull(approval)
        assertFalse(approval!!.contains(Base64Url.encode(identity.vaultKey)))
        assertTrue(approval.contains("initiatorPublicKey"))
        assertTrue(approval.contains("vaultKeyEnvelope"))
        // Path A approval 不带批准方公钥，避免两端格式混淆。
        assertFalse(JSONObject(approval).has("approverPublicKey"))
        claim.destroy()
    }

    @Test
    fun `PathB完整流程核对码一致并解封vaultKey`() = runBlocking {
        val store = MemoryPairingStore()
        val creator = coordinator(store, code = "654321", pairingId = "pairing-b-0001")
        val join = creator.createJoin("Pixel", deviceId = "device-android-0001")
        assertEquals("654321", join.code)

        val approver = coordinator(store, code = "111111", pairingId = "pairing-resolve-0001")
        val target = approver.resolveJoin(approver.findJoin("654321"), identity, "MacBook")
        approver.approveJoin(target, identity)

        var resolution: WebDavJoinResolution? = null
        val result = creator.awaitJoinCompletion(
            join,
            onResolution = { resolution = it },
        )

        assertNotNull(resolution)
        assertEquals(target.verificationCode, resolution!!.verificationCode)
        assertEquals("MacBook", resolution!!.approverName)
        assertEquals(identity.vaultId, result.vaultId)
        assertEquals("device-android-0001", result.deviceId)
        assertArrayEquals(identity.vaultKey, result.vaultKey)
        assertTrue(store.files.isEmpty())
    }

    @Test
    fun `PathB只有approval时不会解封身份`() = runBlocking {
        val store = MemoryPairingStore()
        val creator = coordinator(store, code = "654321", pairingId = "pairing-b-approval-only")
        val join = creator.createJoin("Pixel", deviceId = "device-android-only")
        val approver = coordinator(store, code = "111111", pairingId = "pairing-b-only-approve")
        val target = approver.resolveJoin(approver.findJoin("654321"), identity, "MacBook")
        approver.approveJoin(target, identity)
        // 模拟 approval 先到，resolve 尚未可见。
        store.deleteFile(PairingFileNames.resolve(join.pairingId))

        var polls = 0
        val gated = WebDavPairingCoordinator(
            store = store,
            clockMillis = { 1_700_000_000_000L },
            pause = {
                polls += 1
                if (polls > 2) throw StopPolling()
            },
        )
        assertThrows(StopPolling::class.java) {
            runBlocking {
                gated.awaitJoinCompletion(join, onResolution = {})
            }
        }
        assertNotNull(store.files[PairingFileNames.approval(join.pairingId)])
    }

    @Test
    fun `PathB先收到approval时等resolve到达后才处理并自动采纳身份`() = runBlocking {
        val store = MemoryPairingStore()
        val creator = coordinator(store, code = "654321", pairingId = "pairing-b-late-resolve")
        val join = creator.createJoin("Pixel", deviceId = "device-android-late")
        val approver = coordinator(store, code = "111111", pairingId = "pairing-b-late-approve")
        val target = approver.resolveJoin(approver.findJoin("654321"), identity, "MacBook")
        approver.approveJoin(target, identity)
        // 把 resolve 暂时移走，第一次轮询只能看到 approval。
        val resolveName = PairingFileNames.resolve(join.pairingId)
        val resolveContent = checkNotNull(store.files.remove(resolveName))

        var pauses = 0
        val gated = WebDavPairingCoordinator(
            store = store,
            clockMillis = { 1_700_000_000_000L },
            pause = {
                pauses += 1
                if (pauses == 1) store.files[resolveName] = resolveContent
            },
        )
        var resolution: WebDavJoinResolution? = null
        val result = gated.awaitJoinCompletion(
            join,
            onResolution = { resolution = it },
        )

        assertEquals(target.verificationCode, resolution!!.verificationCode)
        assertArrayEquals(identity.vaultKey, result.vaultKey)
        assertTrue(store.files.isEmpty())
    }

    @Test
    fun `PathBapproval的批准公钥必须与resolve一致`() {
        runBlocking {
            val store = MemoryPairingStore()
        val creator = coordinator(store, code = "654321", pairingId = "pairing-b-mismatch")
        val join = creator.createJoin("Pixel", deviceId = "device-android-mismatch")
        val approver = coordinator(store, code = "111111", pairingId = "pairing-b-mismatch-app")
        val target = approver.resolveJoin(approver.findJoin("654321"), identity, "MacBook")
        approver.approveJoin(target, identity)

        val approvalName = PairingFileNames.approval(join.pairingId)
        val approval = PairingApproval.decode(checkNotNull(store.files[approvalName]))
        val otherKey = PairingKeyPair.generate()
        store.files[approvalName] = approval.copy(
            approverPublicKey = otherKey.publicKeyBase64Url,
        ).encode()
        otherKey.destroy()

        assertThrows(WebDavPairingException.InvalidApproval::class.java) {
            runBlocking {
                creator.awaitJoinCompletion(join)
            }
        }
        // 校验失败不会自动删除 approval，也不会返回身份。
        assertNotNull(store.files[approvalName])
        }
    }

    @Test
    fun `同一六位码匹配多份offer时返回配对码冲突`() {
        val store = MemoryPairingStore()
        coordinator(store, code = "123456", pairingId = "pairing-collide-offer-a")
            .createOffer(identity, "Mac One")
        coordinator(store, code = "123456", pairingId = "pairing-collide-offer-b")
            .createOffer(identity, "Mac Two")

        val finder = coordinator(store)
        val error = assertThrows(WebDavPairingException.CodeConflict::class.java) {
            finder.findOffer("123456")
        }
        assertTrue(checkNotNull(error.message).contains("配对码冲突"))
        assertTrue(checkNotNull(error.message).contains("重新生成"))
    }

    @Test
    fun `同一六位码匹配多份join时返回配对码冲突`() {
        val store = MemoryPairingStore()
        coordinator(store, code = "654321", pairingId = "pairing-collide-join-a")
            .createJoin("Pixel One", deviceId = "device-android-a1")
        coordinator(store, code = "654321", pairingId = "pairing-collide-join-b")
            .createJoin("Pixel Two", deviceId = "device-android-b1")

        val finder = coordinator(store)
        assertThrows(WebDavPairingException.CodeConflict::class.java) {
            finder.findJoin("654321")
        }
    }

    @Test
    fun `配对文件按本机首次观察时间清理而不是远端createdAt`() {
        val clock = TestClock()
        val store = MemoryPairingStore()
        val offer = coordinator(
            store,
            code = "123456",
            pairingId = "pairing-observed-01",
            clock = clock,
        ).createOffer(identity, "MacBook")

        val finder = coordinator(store, clock = clock)
        assertEquals(offer.pairingId, finder.findOffer("123456").pairingId)

        clock.now += PairingTimePolicy.TTL_MILLIS + 1
        assertThrows(WebDavPairingException.OfferNotFound::class.java) {
            finder.findOffer("123456")
        }
        assertFalse(store.files.containsKey(PairingFileNames.offer("123456", offer.pairingId)))
    }

    @Test
    fun `对端时钟落后二十分钟仍可完成PathA配对`() = runBlocking {
        val behindClock = TestClock()
        val localClock = TestClock(behindClock.now + 20L * 60L * 1_000L)
        val store = MemoryPairingStore()
        val creator = coordinator(
            store,
            code = "123456",
            pairingId = "pairing-skew-0001",
            clock = behindClock,
        )
        val offerSession = creator.createOffer(identity, "MacBook")

        val joiner = coordinator(
            store,
            code = "654321",
            pairingId = "pairing-skew-claim",
            clock = localClock,
        )
        val offer = joiner.findOffer("123456")
        assertEquals(offerSession.pairingId, offer.pairingId)
        val claim = joiner.claimOffer(offer, "Pixel", deviceId = "device-android-skew")

        val info = creator.awaitOfferClaim(offerSession)
        assertEquals(claim.verificationCode, info.verificationCode)
        creator.approveOffer(offerSession, info, identity)

        val result = joiner.awaitOfferApproval(claim)
        assertArrayEquals(identity.vaultKey, result.vaultKey)
        assertFalse(store.files.containsKey(offer.fileName))
    }

    @Test
    fun `无法解码或未知协议版本的配对文件不会被删除`() {
        val store = MemoryPairingStore()
        val unknownName = PairingFileNames.offer("123456", "pairing-unknown-01")
        store.files[unknownName] = JSONObject()
            .put("format", "woo-todo-webdav-pairing")
            .put("protocolVersion", 2)
            .put("kind", "offer")
            .put("pairingId", "pairing-unknown-01")
            .put("createdAt", 1)
            .put("expiresAt", 2)
            .toString()
        val garbageName = PairingFileNames.offer("123456", "pairing-garbage-01")
        store.files[garbageName] = "not-json"

        val finder = coordinator(store)
        assertThrows(WebDavPairingException.OfferNotFound::class.java) {
            finder.findOffer("123456")
        }

        assertTrue(store.files.containsKey(unknownName))
        assertTrue(store.files.containsKey(garbageName))
    }

    @Test
    fun `轮询遇到临时WebDAV错误会在TTL内继续`() = runBlocking {
        val clock = TestClock()
        val store = MemoryPairingStore()
        val creator = coordinator(store, code = "123456", pairingId = "pairing-retry-0001", clock = clock)
        val offer = creator.createOffer(identity, "MacBook")
        val joiner = coordinator(
            store,
            code = "654321",
            pairingId = "pairing-retry-claim",
            clock = clock,
        )
        val claim = joiner.claimOffer(
            joiner.findOffer("123456"),
            "Pixel",
            deviceId = "device-android-0001",
        )
        val info = creator.awaitOfferClaim(offer)
        creator.approveOffer(offer, info, identity)

        val flaky = FlakyPairingStore(store, failures = 2, error = WebDavException.Http(503))
        val flakyCoordinator = WebDavPairingCoordinator(
            store = flaky,
            clockMillis = { clock.now },
            pause = {},
        )
        val result = flakyCoordinator.awaitOfferApproval(claim)

        assertArrayEquals(identity.vaultKey, result.vaultKey)
        assertEquals(0, flaky.failures)
    }

    @Test
    fun `过期配对码不会被认领`() {
        val clock = TestClock()
        val store = MemoryPairingStore()
        val creator = coordinator(
            store,
            code = "123456",
            pairingId = "pairing-expired-01",
            clock = clock,
        )
        val offer = creator.createOffer(identity, "MacBook")
        clock.now += PairingTimePolicy.TTL_MILLIS + PairingTimePolicy.POLL_GRACE_MILLIS + 1

        assertThrows(WebDavPairingException.Expired::class.java) {
            runBlocking { creator.awaitOfferClaim(offer) }
        }
        offer.destroy()
    }

    @Test
    fun `同名配对文件内容不同时重新生成`() {
        val store = MemoryPairingStore()
        val creator = coordinator(store, code = "123456", pairingId = "pairing-conflict-01")
        creator.createOffer(identity, "MacBook")

        val second = coordinator(store, code = "123456", pairingId = "pairing-conflict-01")
        val retried = second.createOffer(identity, "Another Mac")

        assertTrue(retried.pairingId != "pairing-conflict-01")
        assertEquals(2, store.files.size)
    }

    @Test
    fun `第二个设备认领同一offer时冲突`() {
        val store = MemoryPairingStore()
        val creator = coordinator(store, code = "123456", pairingId = "pairing-claim-race")
        creator.createOffer(identity, "MacBook")
        val first = coordinator(store, code = "111111", pairingId = "pairing-claim-one")
        first.claimOffer(first.findOffer("123456"), "Pixel One", deviceId = "device-android-0001")

        val second = coordinator(store, code = "222222", pairingId = "pairing-claim-two")
        assertThrows(WebDavPairingException.Conflict::class.java) {
            second.claimOffer(
                second.findOffer("123456"),
                "Pixel Two",
                deviceId = "device-android-0002",
            )
        }
    }

    @Test
    fun `PathA批准设备不一致时拒绝解封`() {
        runBlocking {
            val store = MemoryPairingStore()
            val creator = coordinator(store, code = "123456", pairingId = "pairing-tamper-01")
            val offer = creator.createOffer(identity, "MacBook")
            val joiner = coordinator(store, code = "654321", pairingId = "pairing-tamper-claim")
            val claim = joiner.claimOffer(
                joiner.findOffer("123456"),
                "Pixel",
                deviceId = "device-android-0001",
            )
            val info = creator.awaitOfferClaim(offer)
            creator.approveOffer(offer, info, identity)

            val approvalName = PairingFileNames.approval(offer.pairingId)
            val approval = PairingApproval.decode(checkNotNull(store.files[approvalName]))
            store.files[approvalName] = approval.copy(deviceId = "device-android-0009").encode()

            assertThrows(WebDavPairingException.InvalidApproval::class.java) {
                runBlocking { joiner.awaitOfferApproval(claim) }
            }
            // 自动保存失败时保留批准文件，便于重试或排查。
            assertNotNull(store.files[approvalName])
        }
    }

    @Test
    fun `共享配对fixture可被严格解码`() {
        val offer = PairingFileCodec.decode(fixture("webdav-pairing-offer.json")) as PairingOffer
        val claim = PairingFileCodec.decode(fixture("webdav-pairing-claim.json")) as PairingClaim
        val join = PairingFileCodec.decode(fixture("webdav-pairing-join.json")) as PairingJoin
        val resolve = PairingFileCodec.decode(fixture("webdav-pairing-resolve.json")) as PairingResolve
        val approval = PairingFileCodec.decode(fixture("webdav-pairing-approval.json")) as PairingApproval

        assertEquals("482913", offer.code)
        assertEquals("device-android-a1", claim.deviceId)
        assertEquals("731205", join.code)
        assertEquals("device-macos-b1", resolve.approverDeviceId)
        assertEquals(join.publicKey, approval.initiatorPublicKey)
        assertEquals(resolve.approverPublicKey, approval.approverPublicKey)
        assertEquals("device-android-b2", approval.deviceId)
    }

    @Test
    fun `配对文件严格拒绝未知字段与错误版本`() {
        val offer = PairingOffer(
            pairingId = "pairing-strict-01",
            createdAt = 1_700_000_000_000L,
            expiresAt = 1_700_000_300_000L,
            code = "123456",
            publicKey = Base64Url.encode(ByteArray(32) { 4 }),
            pairingSecret = Base64Url.encode(ByteArray(32) { 5 }),
            vaultId = identity.vaultId,
            deviceName = "MacBook",
            platform = DevicePlatform.MACOS,
        )
        val unknown = JSONObject(offer.encode()).put("unexpected", true).toString()
        assertThrows(WebDavException.MalformedObject::class.java) {
            PairingOffer.decode(unknown)
        }
        val wrongVersion = JSONObject(offer.encode()).put("protocolVersion", 2).toString()
        assertThrows(WebDavException.MalformedObject::class.java) {
            PairingOffer.decode(wrongVersion)
        }
        assertEquals(
            PairingFileKind.OFFER,
            PairingFileNames.parse(offer.fileName)?.kind,
        )
        assertEquals("123456", PairingFileNames.parse(offer.fileName)?.code)
        assertNull(PairingFileNames.parse("offer-12345-missing-code.json"))
        assertNull(PairingFileNames.parse("../offer-123456-ab.json"))
    }

    @Test
    fun `清理只删除对应pairingId的文件`() {
        val store = MemoryPairingStore()
        val first = coordinator(store, code = "123456", pairingId = "pairing-clean-0001")
        val second = coordinator(store, code = "234567", pairingId = "pairing-clean-0002")
        first.createOffer(identity, "Mac One")
        second.createOffer(identity, "Mac Two")
        val finder = coordinator(store)
        val offer = finder.findOffer("123456")

        finder.deletePairingFiles(offer.pairingId)

        assertEquals(1, store.files.size)
        assertTrue(store.files.keys.single().contains("pairing-clean-0002"))
    }

    private fun fixture(name: String): String = requireNotNull(
        javaClass.classLoader?.getResourceAsStream(name),
    ).bufferedReader().use { it.readText() }

    private class StopPolling : Exception("stop polling")

    private class TestClock(var now: Long = 1_700_000_000_000L)

    private fun coordinator(
        store: WebDavPairingStore,
        code: String = "123456",
        pairingId: String = "pairing-default-0001",
        clock: TestClock = TestClock(),
    ): WebDavPairingCoordinator {
        val counter = AtomicInteger()
        return WebDavPairingCoordinator(
            store = store,
            keyPairFactory = PairingKeyPair::generate,
            codeFactory = { code },
            pairingIdFactory = {
                if (counter.getAndIncrement() == 0) pairingId
                else "$pairingId-retry-${counter.get()}"
            },
            deviceIdFactory = { "device-generated-0001" },
            clockMillis = { clock.now },
            pause = {},
        )
    }

    private class FlakyPairingStore(
        private val delegate: WebDavPairingStore,
        var failures: Int,
        private val error: Exception,
    ) : WebDavPairingStore {
        override fun ensureDirectory() = delegate.ensureDirectory()

        override fun listFileNames(): List<String> = delegate.listFileNames()

        override fun readFile(name: String): String? {
            if (failures > 0) {
                failures -= 1
                throw error
            }
            return delegate.readFile(name)
        }

        override fun writeFileIfAbsent(name: String, content: String): Boolean =
            delegate.writeFileIfAbsent(name, content)

        override fun deleteFile(name: String) = delegate.deleteFile(name)
    }

    private class MemoryPairingStore : WebDavPairingStore {
        val files = linkedMapOf<String, String>()

        override fun ensureDirectory() = Unit

        override fun listFileNames(): List<String> = files.keys.toList()

        override fun readFile(name: String): String? = files[name]

        override fun writeFileIfAbsent(name: String, content: String): Boolean {
            val existing = files[name]
            return when {
                existing == null -> {
                    files[name] = content
                    true
                }
                existing == content -> true
                else -> false
            }
        }

        override fun deleteFile(name: String) {
            files.remove(name)
        }
    }
}
