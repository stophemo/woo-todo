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
                account = WebDavAccount(
                    endpoint = "https://dav.example.com/woo-todo/",
                    username = "user@example.com",
                    appPassword = "application-password",
                ),
                identity = WebDavIdentity(
                    vaultId = "..",
                    deviceId = "device-android-01",
                    vaultKey = ByteArray(Aes256Gcm.KEY_BYTES),
                ),
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
    fun `WebDAV服务连续三次503后会重试并继续创建目录`() {
        val requests = AtomicInteger()
        val client = clientWith { chain ->
            val requestNumber = requests.incrementAndGet()
            val statusCode = if (requestNumber <= 3) 503 else 201
            response(chain.request(), statusCode)
        }

        client.ensureCollections("personal-vault")

        assertEquals(6, requests.get())
    }

    @Test
    fun `WebDAV禁止明文地址并拒绝重定向`() {
        assertFalse(
            WebDavEndpointPolicy.isAllowed("http://dav.example.com/woo-todo/"),
        )
        assertFalse(
            WebDavEndpointPolicy.isAllowed("https://user:pass@dav.example.com/woo-todo/"),
        )
        assertFalse(
            WebDavEndpointPolicy.isAllowed("https://dav.example.com/woo-todo/?a=1"),
        )
        assertTrue(
            WebDavEndpointPolicy.isAllowed("https://dav.example.com/woo-todo/"),
        )

        val client = clientWith { chain -> response(chain.request(), 302) }
        assertThrows(WebDavException.Http::class.java) {
            client.ensureCollections("personal-vault")
        }
    }

    @Test
    fun `WebDAV同名对象内容不同时报告冲突相同内容幂等`() {
        var existing = "different"
        val client = clientWith { chain ->
            when (chain.request().method) {
                "MKCOL" -> response(chain.request(), 201)
                "PUT" -> response(chain.request(), 412)
                "GET" -> response(chain.request(), 200, existing)
                else -> response(chain.request(), 500)
            }
        }
        val operation = operation()

        assertThrows(WebDavException.ObjectConflict::class.java) {
            client.putOperation(operation)
        }

        existing = operation.canonicalJson()
        client.putOperation(operation)
    }

    private fun clientWith(
        handler: (okhttp3.Interceptor.Chain) -> Response,
    ): WebDavClient = WebDavClient(
        account = WebDavAccount(
            endpoint = "https://dav.example.com/woo-todo/",
            username = "user@example.com",
            appPassword = "application-password",
        ),
        httpClient = OkHttpClient.Builder().addInterceptor(handler).build(),
        retryDelaysMillis = listOf(0L, 0L, 0L),
        retrySleep = {},
    )

    private fun response(
        request: okhttp3.Request,
        statusCode: Int,
        body: String = "",
    ): Response = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(statusCode)
        .message("test")
        .body(body.toResponseBody())
        .build()

    private fun operation(): WebDavOperation = WebDavOperation(
        vaultId = "personal-vault",
        deviceId = "device-android-01",
        opId = "operation-0001",
        entityId = "entity-0001",
        kind = SyncOperationKind.UPSERT,
        lamport = 1,
        nonce = Base64Url.encode(ByteArray(Aes256Gcm.NONCE_BYTES)),
        ciphertext = Base64Url.encode(ByteArray(Aes256Gcm.TAG_BYTES)),
    )
}
