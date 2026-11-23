package com.wootodo.sync

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncDeviceManagerTest {
    private val credentials = SyncCredentials(
        endpoint = "https://sync.example.test",
        vaultId = "vault-device-test",
        deviceId = "device-current",
        deviceToken = Base64Url.encode(ByteArray(32) { 1 }),
        vaultKey = ByteArray(32) { 2 },
    )

    @Test
    fun `退出空间调用当前设备撤销接口`() {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(
                    200,
                    successData("""{"deviceId":"device-current","revokedAt":2000}"""),
                ),
            ),
        )
        val manager = SyncDeviceManager(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
        )

        val result = manager.leaveSpace(credentials)

        assertEquals("device-current", result.deviceId)
        assertEquals(2000L, result.revokedAt)
        assertEquals(
            listOf("/v1/devices/current/revoke"),
            http.paths(),
        )
        assertEquals(
            "Bearer ${credentials.deviceToken}",
            http.connections.single().getRequestProperty("Authorization"),
        )
    }

    @Test
    fun `列出设备并移除其他设备`() {
        val http = QueuedHttpConnectionFactory(
            listOf(
                FakeHttpResponse(
                    200,
                    successData(
                        """
                        {"devices":[{"id":"device-current","name":"手机","platform":"android",
                        "publicKey":null,"createdAt":100,"lastSeenAt":200,"revokedAt":null,
                        "isCurrent":true},{"id":"device-mac","name":"Mac","platform":"macos",
                        "publicKey":null,"createdAt":50,"lastSeenAt":150,"revokedAt":null,
                        "isCurrent":false}]}
                        """.trimIndent(),
                    ),
                ),
                FakeHttpResponse(
                    200,
                    successData("""{"deviceId":"device-mac","revokedAt":3000}"""),
                ),
            ),
        )
        val manager = SyncDeviceManager(
            clientFactory = { SyncApiClient(it) { url -> http.create(url) } },
        )

        val devices = manager.listDevices(credentials).devices
        assertEquals(2, devices.size)
        assertTrue(devices.first().isCurrent)
        assertEquals(DevicePlatform.MACOS, devices.last().platform)

        manager.removeDevice(credentials, "device-mac")
        assertEquals(
            listOf("/v1/devices", "/v1/devices/device-mac/revoke"),
            http.paths(),
        )
        assertEquals(
            "Bearer ${credentials.deviceToken}",
            http.connections.last().getRequestProperty("Authorization"),
        )
    }

    @Test
    fun `退出空间时服务端已移除设备仍继续本地清理`() {
        assertTrue(
            SyncLeavePolicy.serverAlreadyRemoved(
                serverError(401, "INVALID_DEVICE_TOKEN"),
            ),
        )
        assertTrue(
            SyncLeavePolicy.serverAlreadyRemoved(
                serverError(403, "DEVICE_REVOKED"),
            ),
        )
        assertFalse(SyncLeavePolicy.serverAlreadyRemoved(serverError(403, "FORBIDDEN")))
        assertFalse(SyncLeavePolicy.serverAlreadyRemoved(serverError(401, "AUTH_REQUIRED")))
        assertFalse(SyncLeavePolicy.serverAlreadyRemoved(serverError(500, "INTERNAL")))
        assertFalse(
            SyncLeavePolicy.serverAlreadyRemoved(
                SyncApiException.Transport(IOException("断网")),
            ),
        )
    }

    private fun serverError(statusCode: Int, code: String): SyncApiException.Server =
        SyncApiException.Server(
            statusCode = statusCode,
            payload = ServerErrorPayload(code = code, message = "测试错误"),
            requestId = null,
        )
}
