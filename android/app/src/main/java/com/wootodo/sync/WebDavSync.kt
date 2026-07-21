package com.wootodo.sync

import android.content.Context
import android.net.Uri
import android.util.Xml
import java.io.StringReader
import java.nio.charset.StandardCharsets
import java.util.UUID
import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser

sealed class WebDavException(message: String) : Exception(message) {
    class InvalidCredentials : WebDavException("坚果云同步凭据无效")
    class Transport(message: String) : WebDavException(message)
    class Http(val statusCode: Int) : WebDavException("坚果云 WebDAV 返回 HTTP $statusCode")
    class ObjectConflict(path: String) : WebDavException("坚果云对象发生冲突：$path")
    class MalformedObject(message: String) : WebDavException("坚果云同步对象无效：$message")
}

object WebDavEndpointPolicy {
    const val ENDPOINT = "https://dav.jianguoyun.com/dav/"

    fun isAllowed(value: String): Boolean = runCatching {
        val uri = java.net.URI(value)
        uri.scheme.equals("https", ignoreCase = true) &&
            uri.host.equals("dav.jianguoyun.com", ignoreCase = true) &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
            (uri.path == "/dav" || uri.path == "/dav/")
    }.getOrDefault(false)
}

data class WebDavCredentials(
    val endpoint: String = WebDavEndpointPolicy.ENDPOINT,
    val username: String,
    val appPassword: String,
    val vaultId: String,
    val deviceId: String,
    val vaultKey: ByteArray,
) {
    fun validate() {
        if (!WebDavEndpointPolicy.isAllowed(endpoint) ||
            username.isEmpty() || username.any(Char::isWhitespace) || username.any(Char::isISOControl) ||
            appPassword.isEmpty() || appPassword.any(Char::isISOControl) ||
            !VAULT_ID.matches(vaultId) || !IDENTIFIER.matches(deviceId) ||
            vaultKey.size != Aes256Gcm.KEY_BYTES
        ) {
            throw WebDavException.InvalidCredentials()
        }
    }

    fun syncIdentity(): SyncCredentials = SyncCredentials(
        endpoint = endpoint,
        vaultId = vaultId,
        deviceId = deviceId,
        deviceToken = Base64Url.encode(ByteArray(32)),
        vaultKey = vaultKey,
    )

    override fun equals(other: Any?): Boolean = other is WebDavCredentials &&
        endpoint == other.endpoint && username == other.username &&
        appPassword == other.appPassword && vaultId == other.vaultId &&
        deviceId == other.deviceId && vaultKey.contentEquals(other.vaultKey)

    override fun hashCode(): Int = 31 * listOf(
        endpoint,
        username,
        appPassword,
        vaultId,
        deviceId,
    ).hashCode() + vaultKey.contentHashCode()

    private companion object {
        val VAULT_ID = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
        val IDENTIFIER = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
    }
}

class AndroidWebDavCredentialsStore(context: Context) {
    private val blobStore = SharedPreferencesCredentialBlobStore(
        context = context,
        fileName = "webdav_credentials_encrypted",
    )
    private val cipher = AndroidKeystoreCredentialCipher("woo-todo-webdav-credentials-v1")
    private val aad = "woo-todo-webdav-credentials-v1".toByteArray(StandardCharsets.UTF_8)

    @Synchronized
    fun save(credentials: WebDavCredentials) {
        credentials.validate()
        val plaintext = encode(credentials).toByteArray(StandardCharsets.UTF_8)
        try {
            blobStore.write(cipher.encrypt(plaintext, aad))
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    fun load(): WebDavCredentials? {
        val envelope = blobStore.read() ?: return null
        val plaintext = cipher.decrypt(envelope, aad)
        return try {
            decode(String(plaintext, StandardCharsets.UTF_8)).also(WebDavCredentials::validate)
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    fun delete() = blobStore.delete()

    private fun encode(credentials: WebDavCredentials): String = JSONObject()
        .put("endpoint", credentials.endpoint)
        .put("username", credentials.username)
        .put("appPassword", credentials.appPassword)
        .put("vaultId", credentials.vaultId)
        .put("deviceId", credentials.deviceId)
        .put("vaultKey", Base64Url.encode(credentials.vaultKey))
        .toString()

    private fun decode(source: String): WebDavCredentials {
        val value = JSONObject(source)
        val expected = setOf("endpoint", "username", "appPassword", "vaultId", "deviceId", "vaultKey")
        require(value.keys().asSequence().toSet() == expected) { "坚果云凭据字段不完整" }
        return WebDavCredentials(
            endpoint = value.getString("endpoint"),
            username = value.getString("username"),
            appPassword = value.getString("appPassword"),
            vaultId = value.getString("vaultId"),
            deviceId = value.getString("deviceId"),
            vaultKey = Base64Url.decode(value.getString("vaultKey")),
        )
    }
}

data class WebDavOperation(
    val vaultId: String,
    val deviceId: String,
    val opId: String,
    val entityId: String,
    val kind: SyncOperationKind,
    val lamport: Long,
    val nonce: String,
    val ciphertext: String,
) {
    fun validate() {
        val identifier = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")
        if (!Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$").matches(vaultId) ||
            !identifier.matches(deviceId) || !identifier.matches(opId) ||
            !identifier.matches(entityId) || lamport < 1 ||
            runCatching { Base64Url.decode(nonce).size }.getOrNull() != Aes256Gcm.NONCE_BYTES ||
            (runCatching { Base64Url.decode(ciphertext).size }.getOrNull() ?: 0) < Aes256Gcm.TAG_BYTES
        ) {
            throw WebDavException.MalformedObject("元数据或密文长度无效")
        }
    }

    fun canonicalJson(): String {
        validate()
        return buildString {
            append("{\"ciphertext\":").append(JSONObject.quote(ciphertext))
            append(",\"deviceId\":").append(JSONObject.quote(deviceId))
            append(",\"entityId\":").append(JSONObject.quote(entityId))
            append(",\"format\":\"woo-todo-webdav-operation\"")
            append(",\"kind\":").append(JSONObject.quote(kind.wireValue))
            append(",\"lamport\":").append(lamport)
            append(",\"nonce\":").append(JSONObject.quote(nonce))
            append(",\"opId\":").append(JSONObject.quote(opId))
            append(",\"protocolVersion\":1")
            append(",\"vaultId\":").append(JSONObject.quote(vaultId)).append('}')
        }
    }

    fun metadata(): SyncOperationMetadata = SyncOperationMetadata(
        opId = opId,
        entityId = entityId,
        kind = kind,
        lamport = lamport,
        deviceId = deviceId,
    )

    companion object {
        fun from(push: SyncPushOperation, credentials: WebDavCredentials): WebDavOperation =
            WebDavOperation(
                vaultId = credentials.vaultId,
                deviceId = credentials.deviceId,
                opId = push.opId,
                entityId = push.entityId,
                kind = push.kind,
                lamport = push.lamport,
                nonce = push.nonce,
                ciphertext = push.ciphertext,
            ).also(WebDavOperation::validate)

        fun decode(source: String): WebDavOperation {
            try {
                val value = JSONObject(source)
                val expected = setOf(
                    "format", "protocolVersion", "vaultId", "deviceId", "opId",
                    "entityId", "kind", "lamport", "nonce", "ciphertext",
                )
                fun string(name: String): String = value.opt(name) as? String
                    ?: throw WebDavException.MalformedObject("字段类型不匹配")
                val protocolVersion = value.opt("protocolVersion")
                val lamport = when (val raw = value.opt("lamport")) {
                    is Int -> raw.toLong()
                    is Long -> raw
                    else -> throw WebDavException.MalformedObject("字段类型不匹配")
                }
                if (value.keys().asSequence().toSet() != expected ||
                    string("format") != "woo-todo-webdav-operation" ||
                    !((protocolVersion is Int && protocolVersion == 1) ||
                        (protocolVersion is Long && protocolVersion == 1L))
                ) {
                    throw WebDavException.MalformedObject("字段不匹配")
                }
                return WebDavOperation(
                    vaultId = string("vaultId"),
                    deviceId = string("deviceId"),
                    opId = string("opId"),
                    entityId = string("entityId"),
                    kind = SyncOperationKind.fromWire(string("kind")),
                    lamport = lamport,
                    nonce = string("nonce"),
                    ciphertext = string("ciphertext"),
                ).also(WebDavOperation::validate)
            } catch (error: WebDavException) {
                throw error
            } catch (_: Exception) {
                throw WebDavException.MalformedObject("字段或 JSON 格式无效")
            }
        }

        fun path(vaultId: String, opId: String): List<String> = listOf(
            "v1",
            vaultId,
            "ops",
            opId.take(2),
            "$opId.json",
        )

        internal fun isValidShard(value: String): Boolean =
            Regex("^[A-Za-z0-9][A-Za-z0-9._:-]$").matches(value)
    }
}

interface WebDavLocalApplying {
    fun applyWebDavOperations(operations: List<WebDavOperation>)
}

class WebDavClient(
    val credentials: WebDavCredentials,
    private val httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(java.time.Duration.ofSeconds(10))
        .readTimeout(java.time.Duration.ofSeconds(20))
        .writeTimeout(java.time.Duration.ofSeconds(20))
        .build(),
) {
    private val baseUrl = credentials.endpoint.toHttpUrl()
    private val authorization = Credentials.basic(credentials.username, credentials.appPassword)

    init {
        credentials.validate()
    }

    fun ensureCollections() {
        listOf(
            listOf("v1"),
            listOf("v1", credentials.vaultId),
            listOf("v1", credentials.vaultId, "ops"),
        ).forEach { request("MKCOL", it, null, emptyMap(), setOf(201, 405, 409)) }
    }

    fun put(operation: WebDavOperation) {
        val data = operation.canonicalJson().toByteArray(StandardCharsets.UTF_8)
        val path = WebDavOperation.path(credentials.vaultId, operation.opId)
        request("MKCOL", path.dropLast(1), null, emptyMap(), setOf(201, 405, 409))
        val result = request(
            method = "PUT",
            path = path,
            body = data,
            headers = mapOf("Content-Type" to "application/json", "If-None-Match" to "*"),
            accepted = setOf(200, 201, 204, 405, 409, 412),
        )
        if (result.code in setOf(405, 409, 412)) {
            val existing = get(path)
            if (!existing.contentEquals(data)) {
                throw WebDavException.ObjectConflict(path.joinToString("/"))
            }
        }
    }

    fun listOperationPaths(): List<List<String>> {
        val root = listOf("v1", credentials.vaultId, "ops")
        val shards = propfind(root)
            .filter {
                it.size == root.size + 1 &&
                    WebDavOperation.isValidShard(it.last())
            }
            .map(List<String>::last)
            .distinct()
            .sorted()
        return shards.flatMap { shard ->
            propfind(root + shard).filter { it.size == root.size + 2 && it.last().endsWith(".json") }
        }.sortedBy { it.joinToString("/") }
    }

    fun get(path: List<String>): ByteArray = request(
        "GET",
        path,
        null,
        emptyMap(),
        setOf(200),
    ).body

    private fun propfind(path: List<String>): List<List<String>> {
        val body = "<?xml version=\"1.0\" encoding=\"utf-8\" ?>" +
            "<propfind xmlns=\"DAV:\"><prop><resourcetype/></prop></propfind>"
        val response = request(
            "PROPFIND",
            path,
            body.toByteArray(StandardCharsets.UTF_8),
            mapOf("Depth" to "1", "Content-Type" to "application/xml"),
            setOf(207),
        )
        return WebDavPropfindParser.parse(String(response.body, StandardCharsets.UTF_8))
    }

    private fun request(
        method: String,
        path: List<String>,
        body: ByteArray?,
        headers: Map<String, String>,
        accepted: Set<Int>,
    ): ResponseData {
        val url = baseUrl.newBuilder().apply {
            path.forEach(::addPathSegment)
        }.build()
        val mediaType = headers["Content-Type"]?.toMediaType()
        val requestBody = if (body == null && method in setOf("PUT", "PROPFIND")) {
            ByteArray(0).toRequestBody(mediaType)
        } else {
            body?.toRequestBody(mediaType)
        }
        val request = Request.Builder()
            .url(url)
            .header("Authorization", authorization)
            .apply { headers.forEach(::header) }
            .method(method, requestBody)
            .build()
        try {
            httpClient.newCall(request).execute().use { response ->
                val responseBody = response.body?.bytes() ?: ByteArray(0)
                if (response.code !in accepted) throw WebDavException.Http(response.code)
                return ResponseData(response.code, responseBody)
            }
        } catch (error: WebDavException) {
            throw error
        } catch (error: Exception) {
            throw WebDavException.Transport(error.localizedMessage ?: "网络不可用")
        }
    }

    private data class ResponseData(val code: Int, val body: ByteArray)
}

class WebDavSyncRunner(
    private val client: WebDavClient,
    private val outbox: OutboxStore,
    private val local: WebDavLocalApplying,
) {
    fun synchronize(): SyncRunSummary {
        client.ensureCollections()
        val pending = outbox.pendingOperations(SyncCoordinator.MAXIMUM_PUSH_BATCH)
        pending.forEach { client.put(WebDavOperation.from(it, client.credentials)) }
        val operations = client.listOperationPaths().map { path ->
            WebDavOperation.decode(String(client.get(path), StandardCharsets.UTF_8)).also { operation ->
                if (operation.vaultId != client.credentials.vaultId) {
                    throw WebDavException.MalformedObject("同步空间不匹配")
                }
                if (path != WebDavOperation.path(operation.vaultId, operation.opId)) {
                    throw WebDavException.MalformedObject("对象路径与 opId 不匹配")
                }
            }
        }
        operations.chunked(WEBDAV_APPLY_BATCH_SIZE).forEach { batch ->
            local.applyWebDavOperations(batch)
        }
        outbox.acknowledgeOperations(pending.map(SyncPushOperation::opId))
        return SyncRunSummary(
            pushed = pending.size,
            pulled = operations.size,
            pages = webDavPageCount(operations.size),
            finalCursor = 0,
        )
    }

    companion object {
        internal const val WEBDAV_APPLY_BATCH_SIZE = 500

        internal fun webDavPageCount(operationCount: Int): Int =
            maxOf(1, (operationCount + WEBDAV_APPLY_BATCH_SIZE - 1) / WEBDAV_APPLY_BATCH_SIZE)
    }
}

internal object WebDavPropfindParser {
    fun parse(source: String): List<List<String>> {
        val parser = Xml.newPullParser().apply {
            // 坚果云常见响应使用 d:href；同时开启命名空间处理并保留本地名兜底。
            setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
            setInput(StringReader(source))
        }
        val paths = mutableListOf<List<String>>()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG && isHrefElement(parser.name)) {
                parseHref(parser.nextText())?.let(paths::add)
            }
            event = parser.next()
        }
        return paths
    }

    private fun isHrefElement(name: String?): Boolean =
        name?.substringAfterLast(':')?.equals("href", ignoreCase = true) == true

    private fun parseHref(raw: String): List<String>? {
        val value = raw.trim()
        if (value.isEmpty()) {
            throw WebDavException.MalformedObject("PROPFIND href 无效")
        }
        val rawPath = try {
            java.net.URI(value).rawPath
        } catch (_: Exception) {
            null
        }?.takeIf(String::isNotEmpty)
            ?: throw WebDavException.MalformedObject("PROPFIND href 无效")
        val segments = rawPath
            .split('/')
            .filter(String::isNotEmpty)
            .map(Uri::decode)
        val start = segments.indexOf("v1")
        return start.takeIf { it >= 0 }?.let { segments.drop(it) }
    }
}

fun newWebDavIdentity(): Pair<String, String> =
    "vault-${Base64Url.encode(SecureBytes.generate(9))}" to UUID.randomUUID().toString().lowercase()
