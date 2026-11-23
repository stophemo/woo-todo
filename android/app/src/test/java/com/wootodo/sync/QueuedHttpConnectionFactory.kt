package com.wootodo.sync

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

data class FakeHttpResponse(val status: Int, val body: String)

/** 用 connectionFactory 注入同步响应，避免测试依赖真实网络。 */
class QueuedHttpConnectionFactory(responses: List<FakeHttpResponse>) {
    private val queue = ArrayDeque(responses)
    val connections = mutableListOf<FakeHttpConnection>()

    fun create(url: URL): HttpURLConnection {
        check(queue.isNotEmpty()) { "没有更多假 HTTP 响应" }
        return FakeHttpConnection(queue.removeFirst(), url).also(connections::add)
    }

    fun paths(): List<String> = connections.map { it.requestUrl.path }
}

class FakeHttpConnection(
    private val response: FakeHttpResponse,
    url: URL,
) : HttpURLConnection(url) {
    private var actualUrl: URL = url
    val requestUrl: URL get() = actualUrl
    private val requestBody = ByteArrayOutputStream()

    override fun connect() = Unit
    override fun disconnect() = Unit
    override fun usingProxy(): Boolean = false
    override fun getResponseCode(): Int = response.status
    override fun getResponseMessage(): String = "测试响应"
    override fun getOutputStream(): ByteArrayOutputStream = requestBody
    override fun getInputStream(): InputStream = ByteArrayInputStream(response.body.toByteArray())

    override fun getErrorStream(): InputStream = ByteArrayInputStream(response.body.toByteArray())

    fun sentBody(): String = requestBody.toString(Charsets.UTF_8.name())

    fun attach(value: URL): FakeHttpConnection = apply { actualUrl = value }
}

fun successData(data: String): String =
    """{"ok":true,"data":$data,"requestId":"req-test"}"""
