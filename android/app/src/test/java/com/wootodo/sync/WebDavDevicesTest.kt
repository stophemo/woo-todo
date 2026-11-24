package com.wootodo.sync

import java.nio.charset.StandardCharsets
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavDevicesTest {
    private val identity = WebDavIdentity(
        vaultId = "vault-android-test",
        deviceId = "device-android-01",
        vaultKey = ByteArray(Aes256Gcm.KEY_BYTES) { 7 },
    )

    @Test
    fun `心跳加密后仅暴露信封字段并可解密`() {
        val original = heartbeat()
        val sealed = original.seal(identity.vaultId, identity.vaultKey)
        val envelope = JSONObject(sealed)

        assertEquals(
            setOf("format", "protocolVersion", "deviceId", "nonce", "ciphertext"),
            envelope.keys().asSequence().toSet(),
        )
        assertEquals(WebDavDeviceProtocol.FORMAT, envelope.getString("format"))
        assertEquals(WebDavDeviceProtocol.PROTOCOL_VERSION, envelope.getInt("protocolVersion"))
        assertEquals(identity.deviceId, envelope.getString("deviceId"))
        assertFalse(sealed.contains("\"name\""))
        assertFalse(sealed.contains("\"lastSeenAt\""))

        assertEquals(
            original,
            WebDavDeviceHeartbeat.decode(sealed, identity.vaultId, identity.vaultKey),
        )
    }

    @Test
    fun `AAD 绑定 vaultId 与 deviceId 且拒绝篡改`() {
        val sealed = heartbeat().seal(identity.vaultId, identity.vaultKey)

        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavDeviceHeartbeat.decode(sealed, "vault-other-test", identity.vaultKey)
        }
        val tamperedDeviceId = JSONObject(sealed)
            .put("deviceId", "device-android-99")
            .toString()
        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavDeviceHeartbeat.decode(tamperedDeviceId, identity.vaultId, identity.vaultKey)
        }
        val tamperedCiphertext = JSONObject(sealed)
            .put("ciphertext", Base64Url.encode(ByteArray(Aes256Gcm.TAG_BYTES)))
            .toString()
        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavDeviceHeartbeat.decode(tamperedCiphertext, identity.vaultId, identity.vaultKey)
        }
        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavDeviceHeartbeat.decode(
                sealed,
                identity.vaultId,
                ByteArray(Aes256Gcm.KEY_BYTES) { 9 },
            )
        }
    }

    @Test
    fun `明文与信封严格校验字段`() {
        val valid = validPlaintext()
        assertEquals(
            "Pixel 8",
            WebDavDeviceHeartbeat
                .decode(sealRaw(valid), identity.vaultId, identity.vaultKey)
                .name,
        )

        val invalidPlaintexts = listOf(
            validPlaintext { put("extra", "x") },
            JSONObject()
                .put("name", "Pixel 8")
                .put("platform", "android")
                .put("lastSeenAt", 1_700_000_000_000L)
                .toString(),
            validPlaintext { put("lastSeenAt", "1700000000000") },
            validPlaintext { put("lastSeenAt", 0) },
            validPlaintext { put("platform", "linux") },
            validPlaintext { put("name", "x".repeat(81)) },
            validPlaintext { put("name", "bad\nname") },
            validPlaintext { put("appVersion", "v".repeat(33)) },
        )
        invalidPlaintexts.forEach { plaintext ->
            assertThrows(WebDavException.MalformedObject::class.java) {
                WebDavDeviceHeartbeat.decode(
                    sealRaw(plaintext),
                    identity.vaultId,
                    identity.vaultKey,
                )
            }
        }

        val sealed = heartbeat().seal(identity.vaultId, identity.vaultKey)
        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavDeviceHeartbeat.decode(
                JSONObject(sealed).put("extra", true).toString(),
                identity.vaultId,
                identity.vaultKey,
            )
        }
        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavDeviceHeartbeat.decode(
                JSONObject(sealed).put("protocolVersion", 2).toString(),
                identity.vaultId,
                identity.vaultKey,
            )
        }
        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavDeviceHeartbeat.decode(
                JSONObject(sealed).put("format", "other-format").toString(),
                identity.vaultId,
                identity.vaultKey,
            )
        }
    }

    @Test
    fun `目录列出时跳过坏文件未知版本和文件名不匹配的心跳`() {
        val transport = InMemoryDeviceTransport()
        transport.files["device-mac-0001.json"] =
            heartbeat(deviceId = "device-mac-0001", platform = DevicePlatform.MACOS)
                .seal(identity.vaultId, identity.vaultKey)
        transport.files["device-win-0001.json"] =
            heartbeat(deviceId = "device-win-0001", platform = DevicePlatform.WINDOWS)
                .seal(identity.vaultId, identity.vaultKey)
        transport.files["device-bad-0001.json"] =
            heartbeat(deviceId = "device-other-01")
                .seal(identity.vaultId, identity.vaultKey)
        transport.files["device-v2-0001.json"] = JSONObject(
            heartbeat(deviceId = "device-v2-0001").seal(identity.vaultId, identity.vaultKey),
        ).put("protocolVersion", 2).toString()
        transport.files["device-broken-01.json"] = "{broken"
        transport.files["short.json"] = "invalid file name"
        transport.files["README.md"] = "not a heartbeat"

        val devices = directory(transport).listDevices()

        assertEquals(
            listOf("device-mac-0001", "device-win-0001"),
            devices.map(WebDavDeviceInfo::deviceId),
        )
        assertTrue(transport.deleted.isEmpty())
    }

    @Test
    fun `设备列表按最近同步时间降序并标记当前设备`() {
        val transport = InMemoryDeviceTransport()
        listOf(
            heartbeat(identity.deviceId, name = "Pixel", lastSeenAt = 100),
            heartbeat(
                deviceId = "device-mac-0001",
                name = "Mac",
                platform = DevicePlatform.MACOS,
                lastSeenAt = 300,
            ),
            heartbeat(
                deviceId = "device-win-0001",
                name = "PC",
                platform = DevicePlatform.WINDOWS,
                lastSeenAt = 200,
            ),
        ).forEach { beat ->
            transport.files["${beat.deviceId}.json"] =
                beat.seal(identity.vaultId, identity.vaultKey)
        }

        val devices = directory(transport).listDevices()

        assertEquals(
            listOf("device-mac-0001", "device-win-0001", identity.deviceId),
            devices.map(WebDavDeviceInfo::deviceId),
        )
        assertTrue(devices.single { it.deviceId == identity.deviceId }.isCurrent)
        assertFalse(devices.single { it.deviceId == "device-mac-0001" }.isCurrent)
        assertEquals(DevicePlatform.WINDOWS, devices[1].platform)
        assertEquals("PC", devices[1].name)
        assertEquals("0.2.23", devices[1].appVersion)
    }

    @Test
    fun `写入心跳覆盖同一 deviceId 而不写其他设备`() {
        val transport = InMemoryDeviceTransport()
        var now = 1_000L
        val directory = WebDavDeviceDirectory(
            transport = transport,
            identity = identity,
            clockMillis = { now },
            onWarning = { _, _ -> },
        )

        now = 1_000L
        directory.writeHeartbeat("Pixel 8", "0.2.22")
        now = 2_000L
        directory.writeHeartbeat("Pixel 8 Pro", "0.2.23")

        assertEquals(setOf("device-android-01.json"), transport.files.keys)
        assertEquals(2, transport.putCount)
        assertTrue(identity.vaultId in transport.ensured)
        val stored = WebDavDeviceHeartbeat.decode(
            transport.files.getValue("device-android-01.json"),
            identity.vaultId,
            identity.vaultKey,
        )
        assertEquals("Pixel 8 Pro", stored.name)
        assertEquals(2_000L, stored.lastSeenAt)
        assertEquals("0.2.23", stored.appVersion)
        assertEquals(DevicePlatform.ANDROID, stored.platform)
        assertEquals(identity.deviceId, stored.deviceId)
    }

    @Test
    fun `空列表返回空结果`() {
        val transport = InMemoryDeviceTransport()

        assertTrue(directory(transport).listDevices().isEmpty())
        assertTrue(identity.vaultId in transport.ensured)
    }

    @Test
    fun `退出空间只删除自己的心跳`() {
        val transport = InMemoryDeviceTransport()
        transport.files["device-android-01.json"] =
            heartbeat().seal(identity.vaultId, identity.vaultKey)
        transport.files["device-mac-0001.json"] =
            heartbeat(deviceId = "device-mac-0001", platform = DevicePlatform.MACOS)
                .seal(identity.vaultId, identity.vaultKey)

        directory(transport).deleteOwnHeartbeat()

        assertEquals(setOf("device-mac-0001.json"), transport.files.keys)
        assertEquals(listOf(identity.deviceId), transport.deleted)
    }

    @Test
    fun `同步成功后写入本机心跳`() {
        val transport = InMemoryDeviceTransport()
        val directory = WebDavDeviceDirectory(
            transport = transport,
            identity = identity,
            clockMillis = { 42L },
            onWarning = { _, _ -> },
        )
        val runner = WebDavSyncRunner(
            transport = EmptyOperationTransport,
            identity = identity,
            outbox = EmptyOutbox,
            local = NoopLocal,
            onWarning = { _, _ -> },
            onSynchronized = {
                directory.writeHeartbeat("Pixel 8", "0.2.23")
            },
        )

        runner.synchronize()

        val stored = WebDavDeviceHeartbeat.decode(
            transport.files.getValue("device-android-01.json"),
            identity.vaultId,
            identity.vaultKey,
        )
        assertEquals(identity.deviceId, stored.deviceId)
        assertEquals(42L, stored.lastSeenAt)
        assertEquals("0.2.23", stored.appVersion)
    }

    @Test
    fun `心跳写入失败不影响同步成功`() {
        var warned = false
        val runner = WebDavSyncRunner(
            transport = EmptyOperationTransport,
            identity = identity,
            outbox = EmptyOutbox,
            local = NoopLocal,
            onWarning = { _, _ -> warned = true },
            onSynchronized = { throw WebDavException.Transport("离线") },
        )

        val summary = runner.synchronize()

        assertEquals(0, summary.pushed)
        assertEquals(0, summary.pulled)
        assertTrue(warned)
    }

    private fun heartbeat(
        deviceId: String = identity.deviceId,
        name: String = "Pixel 8",
        platform: DevicePlatform = DevicePlatform.ANDROID,
        lastSeenAt: Long = 1_700_000_000_000L,
        appVersion: String = "0.2.23",
    ): WebDavDeviceHeartbeat = WebDavDeviceHeartbeat(
        deviceId = deviceId,
        name = name,
        platform = platform,
        lastSeenAt = lastSeenAt,
        appVersion = appVersion,
    )

    private fun directory(transport: WebDavDeviceHeartbeatTransport): WebDavDeviceDirectory =
        WebDavDeviceDirectory(
            transport = transport,
            identity = identity,
            clockMillis = { 1_700_000_000_000L },
            onWarning = { _, _ -> },
        )

    private fun validPlaintext(change: JSONObject.() -> Unit = {}): String = JSONObject()
        .put("name", "Pixel 8")
        .put("platform", "android")
        .put("lastSeenAt", 1_700_000_000_000L)
        .put("appVersion", "0.2.23")
        .apply(change)
        .toString()

    private fun sealRaw(plaintext: String): String {
        val envelope = Aes256Gcm.seal(
            plaintext = plaintext.toByteArray(StandardCharsets.UTF_8),
            key = identity.vaultKey,
            aad = WebDavDeviceProtocol.aad(identity.vaultId, identity.deviceId),
        )
        return JSONObject()
            .put("format", WebDavDeviceProtocol.FORMAT)
            .put("protocolVersion", WebDavDeviceProtocol.PROTOCOL_VERSION)
            .put("deviceId", identity.deviceId)
            .put("nonce", envelope.nonce)
            .put("ciphertext", envelope.ciphertext)
            .toString()
    }

    private class InMemoryDeviceTransport : WebDavDeviceHeartbeatTransport {
        val files = linkedMapOf<String, String>()
        val deleted = mutableListOf<String>()
        val ensured = mutableSetOf<String>()
        var putCount = 0

        override fun ensureDevicesCollection(vaultId: String) {
            ensured += vaultId
        }

        override fun putDeviceHeartbeat(vaultId: String, deviceId: String, content: String) {
            putCount += 1
            files["$deviceId.json"] = content
        }

        override fun listDeviceHeartbeatFileNames(vaultId: String): List<String> =
            files.keys.sorted()

        override fun getDeviceHeartbeatOrNull(vaultId: String, deviceId: String): String? =
            files["$deviceId.json"]

        override fun deleteDeviceHeartbeat(vaultId: String, deviceId: String) {
            deleted += deviceId
            files.remove("$deviceId.json")
        }
    }

    private object EmptyOperationTransport : WebDavOperationTransport {
        override fun ensureCollections(vaultId: String) = Unit

        override fun putOperation(operation: WebDavOperation) = Unit

        override fun listOperationPaths(vaultId: String): List<List<String>> = emptyList()

        override fun get(path: List<String>): ByteArray = error("不应读取操作")
    }

    private object EmptyOutbox : OutboxStore {
        override fun pendingOperations(limit: Int): List<SyncPushOperation> = emptyList()

        override fun acknowledgeOperations(opIds: List<String>) = Unit
    }

    private object NoopLocal : WebDavLocalApplying {
        override fun applyWebDavOperations(operations: List<WebDavOperation>) = Unit
    }
}
