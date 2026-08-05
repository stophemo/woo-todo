package com.wootodo.sync

import java.util.concurrent.atomic.AtomicInteger
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebDavOperationTest {
    @Test
    fun `共享WebDAV对象可严格解码并规范编码`() {
        val source = requireNotNull(
            javaClass.classLoader?.getResourceAsStream("webdav-operation.json"),
        ).bufferedReader().use { it.readText() }

        val operation = WebDavOperation.decode(source)

        assertEquals("personal-vault", operation.vaultId)
        assertEquals("device-mac-01", operation.deviceId)
        assertEquals(12, operation.lamport)
        assertEquals(
            "{\"ciphertext\":\"VGhpcy1pcy1hLXRlc3QtY2lwaGVydGV4dC1hbmQtdGFnIQ\"," +
                "\"deviceId\":\"device-mac-01\"," +
                "\"entityId\":\"550e8400-e29b-41d4-a716-446655440000\"," +
                "\"format\":\"woo-todo-webdav-operation\",\"kind\":\"upsert\"," +
                "\"lamport\":12,\"nonce\":\"AAECAwQFBgcICQoL\"," +
                "\"opId\":\"op_01JZ7X0B8E6V5P4N3M2K\",\"protocolVersion\":1," +
                "\"vaultId\":\"personal-vault\"}",
            operation.canonicalJson(),
        )
    }

    @Test
    fun `WebDAV对象拒绝未知字段和错误nonce`() {
        val valid = WebDavOperation(
            vaultId = "personal-vault",
            deviceId = "device-android-01",
            opId = "operation-0001",
            entityId = "entity-0001",
            kind = SyncOperationKind.UPSERT,
            lamport = 1,
            nonce = "AAECAwQFBgcICQoL",
            ciphertext = "VGhpcy1pcy1hLXRlc3QtY2lwaGVydGV4dA",
        )
        val unknown = JSONObject(valid.canonicalJson()).put("unexpected", true).toString()
        assertThrows(WebDavException.MalformedObject::class.java) {
            WebDavOperation.decode(unknown)
        }
        listOf(
            JSONObject(valid.canonicalJson()).put("protocolVersion", "1").toString(),
            JSONObject(valid.canonicalJson()).put("lamport", 1.5).toString(),
            JSONObject(valid.canonicalJson()).put("vaultId", 1).toString(),
        ).forEach { malformed ->
            assertThrows(WebDavException.MalformedObject::class.java) {
                WebDavOperation.decode(malformed)
            }
        }
        assertThrows(WebDavException.MalformedObject::class.java) {
            valid.copy(nonce = "AA").validate()
        }
        assertThrows(WebDavException.MalformedObject::class.java) {
            valid.copy(opId = "..unsafe-operation").validate()
        }
        assertThrows(WebDavException.InvalidCredentials::class.java) {
            WebDavCredentials(
                username = "user@example.com",
                appPassword = "application-password",
                vaultId = "..",
                deviceId = "device-android-01",
                vaultKey = ByteArray(Aes256Gcm.KEY_BYTES),
            ).validate()
        }
    }

    @Test
    fun `WebDAV分片接受标识符允许的冒号且拒绝路径分隔符`() {
        assertTrue(WebDavOperation.isValidShard("a:"))
        assertEquals("a:", WebDavOperation.path("personal-vault", "a:bcdefgh")[3])
        assertFalse(WebDavOperation.isValidShard("a/"))
    }

    @Test
    fun `WebDAV拉取批次覆盖五百条边界且空同步仍记一次请求`() {
        assertEquals(1, WebDavSyncRunner.webDavPageCount(0))
        assertEquals(1, WebDavSyncRunner.webDavPageCount(500))
        assertEquals(2, WebDavSyncRunner.webDavPageCount(501))
        assertEquals(3, WebDavSyncRunner.webDavPageCount(1_001))
    }

    @Test
    fun `WebDAV只重试短时服务错误`() {
        listOf(408, 425, 429, 500, 502, 503, 504).forEach { statusCode ->
            assertTrue(WebDavRetryPolicy.isRetryableHttpStatus(statusCode))
        }
        listOf(400, 401, 403, 404, 409).forEach { statusCode ->
            assertFalse(WebDavRetryPolicy.isRetryableHttpStatus(statusCode))
        }
    }

    @Test
    fun `坚果云连续两次503后会重试并继续创建目录`() {
        val requests = AtomicInteger()
        val httpClient = OkHttpClient.Builder()
            .addInterceptor { chain ->
                val requestNumber = requests.incrementAndGet()
                val statusCode = if (requestNumber <= 2) 503 else 201
                Response.Builder()
                    .request(chain.request())
                    .protocol(Protocol.HTTP_1_1)
                    .code(statusCode)
                    .message(if (statusCode == 503) "Service Unavailable" else "Created")
                    .body(ByteArray(0).toResponseBody())
                    .build()
            }
            .build()
        val client = WebDavClient(
            credentials = WebDavCredentials(
                username = "user@example.com",
                appPassword = "application-password",
                vaultId = "personal-vault",
                deviceId = "device-android-01",
                vaultKey = ByteArray(Aes256Gcm.KEY_BYTES),
            ),
            httpClient = httpClient,
            retryDelaysMillis = listOf(0L, 0L),
            retrySleep = {},
        )

        client.ensureCollections()

        assertEquals(5, requests.get())
    }
}
