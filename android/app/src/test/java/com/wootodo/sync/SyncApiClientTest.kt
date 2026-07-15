package com.wootodo.sync

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class SyncApiClientTest {
    @Test
    fun `同步客户端拒绝远程明文HTTP`() {
        assertThrows(SyncApiException.InvalidEndpoint::class.java) {
            SyncApiClient("http://sync.example.test")
        }
    }

    @Test
    fun `配对202按成功解析且匿名请求不带Bearer`() {
        val connection = FakeConnection(
            status = 202,
            response = """
                {"ok":true,"data":{"pairingId":"pair-1","status":"claimed","expiresAt":123},
                "requestId":"req-pair"}
            """.trimIndent(),
        )
        val client = SyncApiClient("https://sync.example.test/root") { url ->
            connection.attach(url)
        }
        val result = client.pairingResult(
            "pair-1",
            PairingResultRequest(
                pairingSecret = Base64Url.encode(ByteArray(32) { 4 }),
                deviceToken = Base64Url.encode(ByteArray(32) { 5 }),
            ),
        )

        assertEquals(PairingStatus.CLAIMED, result.status)
        assertNull(connection.getRequestProperty("Authorization"))
        assertEquals("/root/v1/pairings/pair-1/result", connection.requestUrl.path)
    }

    @Test
    fun `同步Bearer只在header且错误详情完整保留`() {
        val connection = FakeConnection(
            status = 400,
            response = """
                {"ok":false,"error":{"code":"VALIDATION_ERROR","message":"参数无效",
                "details":{"field":"push[0].nonce"}},"requestId":"req-error"}
            """.trimIndent(),
        )
        val token = Base64Url.encode(ByteArray(32) { 1 })
        val client = SyncApiClient("https://sync.example.test") { url ->
            connection.attach(url)
        }

        val error = try {
            client.sync(SyncRequest(0, 0, 100, emptyList()), BearerCredential(token))
            throw AssertionError("预期服务端错误")
        } catch (error: SyncApiException.Server) {
            error
        }

        assertEquals("Bearer $token", connection.getRequestProperty("Authorization"))
        val sent = JSONObject(connection.sentBody())
        assertEquals(setOf("cursor", "ack", "pullLimit", "push"), sent.keys().asSequence().toSet())
        assertEquals("VALIDATION_ERROR", error.payload.code)
        assertEquals(JsonValue.Text("push[0].nonce"), error.payload.details?.get("field"))
        assertEquals("req-error", error.requestId)
    }
}

private class FakeConnection(
    private val status: Int,
    private val response: String,
) : HttpURLConnection(URL("https://placeholder.test")) {
    private var actualUrl: URL = url
    val requestUrl: URL get() = actualUrl
    private val body = ByteArrayOutputStream()

    override fun connect() = Unit
    override fun disconnect() = Unit
    override fun usingProxy(): Boolean = false
    override fun getResponseCode(): Int = status
    override fun getResponseMessage(): String = "测试响应"
    override fun getOutputStream(): ByteArrayOutputStream = body
    override fun getInputStream(): InputStream = ByteArrayInputStream(response.toByteArray())
    override fun getErrorStream(): InputStream = ByteArrayInputStream(response.toByteArray())

    fun attach(value: URL): FakeConnection = apply { actualUrl = value }

    fun sentBody(): String = body.toString(Charsets.UTF_8.name())
}
