package com.wootodo.sync

import android.content.Context
import android.util.Xml
import java.io.IOException
import java.io.StringReader
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import okhttp3.Credentials
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser

sealed class WebDavException(message: String) : Exception(message) {
    class InvalidCredentials : WebDavException("WebDAV 账号或应用密码无效")
    class Transport(message: String) : WebDavException(message)
    class Http(val statusCode: Int) : WebDavException("WebDAV 服务返回 HTTP $statusCode")
    class ObjectConflict(path: String) : WebDavException("WebDAV 对象发生冲突：$path")
    class MalformedObject(message: String) : WebDavException("WebDAV 同步对象无效：$message")
}

/** WebDAV 地址只允许 HTTPS，且不能携带 userinfo、查询串或片段；允许子路径。 */
object WebDavEndpointPolicy {
    fun isAllowed(value: String): Boolean = runCatching {
        val uri = java.net.URI(value)
        uri.scheme.equals("https", ignoreCase = true) &&
            !uri.host.isNullOrBlank() && value.length <= 2_048 &&
            uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
            (uri.port == -1 || uri.port in 1..65_535) &&
            uri.rawPath.orEmpty().split('/').none(::isTraversalSegment)
    }.getOrDefault(false)

    fun normalize(value: String?): String? {
        val trimmed = value?.trim().orEmpty()
        if (!isAllowed(trimmed)) return null
        return trimmed.removeSuffix("/")
    }

    private fun isTraversalSegment(value: String): Boolean {
        val decoded = runCatching {
            java.net.URLDecoder.decode(
                value.replace("+", "%2B"),
                StandardCharsets.UTF_8.name(),
            )
        }.getOrNull() ?: return true
        return decoded == "." || decoded == ".." || decoded.contains('/') || decoded.contains('\\')
    }
}

internal object WebDavCredentialPolicy {
    private const val MAX_USERNAME_LENGTH = 320
    private const val MAX_APP_PASSWORD_LENGTH = 256
    private const val MAX_DEVICE_NAME_LENGTH = 64
    private val vaultIdPattern = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
    private val identifierPattern = Regex("^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$")

    fun isValidUsername(value: String): Boolean =
        value.codePointCount(0, value.length) in 1..MAX_USERNAME_LENGTH &&
            value.none(Char::isWhitespace) && value.none(Char::isISOControl)

    fun isValidAppPassword(value: String): Boolean =
        value.codePointCount(0, value.length) in 1..MAX_APP_PASSWORD_LENGTH &&
            value.none(Char::isISOControl)

    fun isValidVaultId(value: String): Boolean = vaultIdPattern.matches(value)

    fun isValidDeviceId(value: String): Boolean = identifierPattern.matches(value)

    fun isValidVaultKey(value: ByteArray): Boolean = value.size == Aes256Gcm.KEY_BYTES

    fun normalizeDeviceName(source: String): String {
        val trimmed = source.trim()
        val normalized = if (trimmed.codePointCount(0, trimmed.length) <= MAX_DEVICE_NAME_LENGTH) {
            trimmed
        } else {
            trimmed.substring(0, trimmed.offsetByCodePoints(0, MAX_DEVICE_NAME_LENGTH))
        }
        require(
            normalized.isNotEmpty() && normalized.none(Char::isISOControl),
        ) { "设备名称无效" }
        return normalized
    }
}

class WebDavAccount(
    val endpoint: String,
    val username: String,
    val appPassword: String,
) {
    fun validate() {
        if (!WebDavEndpointPolicy.isAllowed(endpoint) ||
            !WebDavCredentialPolicy.isValidUsername(username) ||
            !WebDavCredentialPolicy.isValidAppPassword(appPassword)
        ) {
            throw WebDavException.InvalidCredentials()
        }
    }

    override fun equals(other: Any?): Boolean = other is WebDavAccount &&
        endpoint == other.endpoint && username == other.username &&
        appPassword == other.appPassword

    override fun hashCode(): Int = listOf(endpoint, username, appPassword).hashCode()

    override fun toString(): String =
        "WebDavAccount(endpoint=$endpoint, username=$username, appPassword=<redacted>)"
}

class WebDavIdentity(
    val vaultId: String,
    val deviceId: String,
    vaultKey: ByteArray,
) {
    val vaultKey: ByteArray = vaultKey.copyOf()

    fun validate() {
        if (!WebDavCredentialPolicy.isValidVaultId(vaultId) ||
            !WebDavCredentialPolicy.isValidDeviceId(deviceId) ||
            !WebDavCredentialPolicy.isValidVaultKey(vaultKey)
        ) {
            throw WebDavException.InvalidCredentials()
        }
    }

    override fun equals(other: Any?): Boolean = other is WebDavIdentity &&
        vaultId == other.vaultId && deviceId == other.deviceId &&
        vaultKey.contentEquals(other.vaultKey)

    override fun hashCode(): Int =
        31 * listOf(vaultId, deviceId).hashCode() + vaultKey.contentHashCode()

    override fun toString(): String =
        "WebDavIdentity(vaultId=$vaultId, deviceId=$deviceId, vaultKey=<redacted>)"
}

class WebDavCredentials(val account: WebDavAccount, val identity: WebDavIdentity) {
    val endpoint: String get() = account.endpoint
    val username: String get() = account.username
    val appPassword: String get() = account.appPassword
    val vaultId: String get() = identity.vaultId
    val deviceId: String get() = identity.deviceId
    val vaultKey: ByteArray get() = identity.vaultKey

    fun validate() {
        account.validate()
        identity.validate()
    }

    fun syncIdentity(): SyncCredentials = SyncCredentials(
        endpoint = endpoint,
        vaultId = vaultId,
        deviceId = deviceId,
        deviceToken = Base64Url.encode(ByteArray(32)),
        vaultKey = vaultKey,
    )

    override fun equals(other: Any?): Boolean = other is WebDavCredentials &&
        account == other.account && identity == other.identity

    override fun hashCode(): Int = 31 * account.hashCode() + identity.hashCode()

    override fun toString(): String =
        "WebDavCredentials(account=$account, identity=$identity)"
}

internal object WebDavAccountJson {
    fun encode(account: WebDavAccount): String = JSONObject()
        .put("endpoint", account.endpoint)
        .put("username", account.username)
        .put("appPassword", account.appPassword)
        .toString()

    fun decode(source: String): WebDavAccount {
        val value = JSONObject(source)
        require(
            value.keys().asSequence().toSet() ==
                setOf("endpoint", "username", "appPassword"),
        ) { "WebDAV 账号字段不完整" }
        return WebDavAccount(
            endpoint = value.getString("endpoint"),
            username = value.getString("username"),
            appPassword = value.getString("appPassword"),
        ).also(WebDavAccount::validate)
    }
}

internal object WebDavIdentityJson {
    fun encode(identity: WebDavIdentity): String = JSONObject()
        .put("vaultId", identity.vaultId)
        .put("deviceId", identity.deviceId)
        .put("vaultKey", Base64Url.encode(identity.vaultKey))
        .toString()

    fun decode(source: String): WebDavIdentity {
        val value = JSONObject(source)
        require(
            value.keys().asSequence().toSet() ==
                setOf("vaultId", "deviceId", "vaultKey"),
        ) { "WebDAV 身份字段不完整" }
        return WebDavIdentity(
            vaultId = value.getString("vaultId"),
            deviceId = value.getString("deviceId"),
            vaultKey = Base64Url.decode(value.getString("vaultKey")),
        ).also(WebDavIdentity::validate)
    }
}

private object WebDavLegacyJson {
    fun decode(source: String): WebDavCredentials {
        val value = JSONObject(source)
        require(
            value.keys().asSequence().toSet() == setOf(
                "endpoint",
                "username",
                "appPassword",
                "vaultId",
                "deviceId",
                "vaultKey",
            ),
        ) { "旧 WebDAV 凭据字段不完整" }
        return WebDavCredentials(
            account = WebDavAccount(
                endpoint = value.getString("endpoint"),
                username = value.getString("username"),
                appPassword = value.getString("appPassword"),
            ),
            identity = WebDavIdentity(
                vaultId = value.getString("vaultId"),
                deviceId = value.getString("deviceId"),
                vaultKey = Base64Url.decode(value.getString("vaultKey")),
            ),
        )
    }
}

/**
 * WebDAV 账号与同步身份分开加密保存。旧版完整凭据（webdav_credentials_encrypted）
 * 在首次读取时迁移为账号 + 身份，之后直接按新格式使用。
 */
class AndroidWebDavCredentialsStore(context: Context) {
    private val accountBlob = SharedPreferencesCredentialBlobStore(
        context = context,
        fileName = ACCOUNT_PREFERENCES,
    )
    private val identityBlob = SharedPreferencesCredentialBlobStore(
        context = context,
        fileName = IDENTITY_PREFERENCES,
    )
    private val legacyBlob = SharedPreferencesCredentialBlobStore(
        context = context,
        fileName = LEGACY_PREFERENCES,
    )
    private val accountCipher = AndroidKeystoreCredentialCipher(ACCOUNT_KEY_ALIAS)
    private val identityCipher = AndroidKeystoreCredentialCipher(IDENTITY_KEY_ALIAS)
    private val legacyCipher = AndroidKeystoreCredentialCipher(LEGACY_KEY_ALIAS)
    private val accountAad = ACCOUNT_KEY_ALIAS.toByteArray(StandardCharsets.UTF_8)
    private val identityAad = IDENTITY_KEY_ALIAS.toByteArray(StandardCharsets.UTF_8)
    private val legacyAad = LEGACY_KEY_ALIAS.toByteArray(StandardCharsets.UTF_8)

    @Synchronized
    fun loadAccount(): WebDavAccount? {
        migrateLegacyIfNeeded()
        val envelope = accountBlob.read() ?: return null
        val plaintext = accountCipher.decrypt(envelope, accountAad)
        return try {
            WebDavAccountJson.decode(String(plaintext, StandardCharsets.UTF_8)).also {
                it.validate()
            }
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    fun saveAccount(account: WebDavAccount) {
        account.validate()
        val plaintext = WebDavAccountJson.encode(account).toByteArray(StandardCharsets.UTF_8)
        try {
            accountBlob.write(accountCipher.encrypt(plaintext, accountAad))
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    fun deleteAccount() = accountBlob.delete()

    @Synchronized
    fun loadIdentity(): WebDavIdentity? {
        migrateLegacyIfNeeded()
        val envelope = identityBlob.read() ?: return null
        val plaintext = identityCipher.decrypt(envelope, identityAad)
        return try {
            WebDavIdentityJson.decode(String(plaintext, StandardCharsets.UTF_8)).also {
                it.validate()
            }
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    fun saveIdentity(identity: WebDavIdentity) {
        identity.validate()
        val plaintext = WebDavIdentityJson.encode(identity).toByteArray(StandardCharsets.UTF_8)
        try {
            identityBlob.write(identityCipher.encrypt(plaintext, identityAad))
        } finally {
            plaintext.fill(0)
        }
    }

    @Synchronized
    fun saveIdentityIfAbsent(identity: WebDavIdentity): Boolean {
        if (identityBlob.read() != null) return false
        saveIdentity(identity)
        return true
    }

    @Synchronized
    fun deleteIdentity() = identityBlob.delete()

    @Synchronized
    fun load(): WebDavCredentials? {
        val account = loadAccount() ?: return null
        val identity = loadIdentity() ?: return null
        return WebDavCredentials(account, identity).also { it.validate() }
    }

    @Synchronized
    fun save(credentials: WebDavCredentials) {
        credentials.validate()
        saveAccount(credentials.account)
        saveIdentity(credentials.identity)
    }

    @Synchronized
    fun delete() {
        runCatching(accountBlob::delete)
        runCatching(identityBlob::delete)
        runCatching(legacyBlob::delete)
    }

    /** 迁移失败不影响新格式读取；旧凭据保持原样，下次再试。 */
    private fun migrateLegacyIfNeeded() {
        val hasAccount = accountBlob.read() != null
        val hasIdentity = identityBlob.read() != null
        if (hasAccount && hasIdentity) return
        val legacy = readLegacy() ?: return
        runCatching {
            if (!hasAccount) saveAccount(legacy.account)
            if (!hasIdentity) saveIdentity(legacy.identity)
            legacyBlob.delete()
        }
    }

    private fun readLegacy(): WebDavCredentials? = runCatching {
        val envelope = legacyBlob.read() ?: return null
        val plaintext = legacyCipher.decrypt(envelope, legacyAad)
        try {
            WebDavLegacyJson.decode(String(plaintext, StandardCharsets.UTF_8)).also {
                it.validate()
            }
        } finally {
            plaintext.fill(0)
        }
    }.getOrNull()

    private companion object {
        const val ACCOUNT_PREFERENCES = "webdav_account_encrypted"
        const val IDENTITY_PREFERENCES = "webdav_identity_encrypted"
        const val LEGACY_PREFERENCES = "webdav_credentials_encrypted"
        const val ACCOUNT_KEY_ALIAS = "woo-todo-webdav-account-v1"
        const val IDENTITY_KEY_ALIAS = "woo-todo-webdav-identity-v1"
        const val LEGACY_KEY_ALIAS = "woo-todo-webdav-credentials-v1"
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
        fun from(
            push: SyncPushOperation,
            vaultId: String,
            deviceId: String,
        ): WebDavOperation = WebDavOperation(
            vaultId = vaultId,
            deviceId = deviceId,
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
    fun pendingWebDavOperationIds(operationIds: List<String>): Set<String> =
        operationIds.toSet()

    fun applyWebDavOperations(operations: List<WebDavOperation>)

    /** 已成功上传的操作等价于已应用，避免下次同步重复下载自己的对象。 */
    fun markWebDavOperationsApplied(operationIds: List<String>) =
        markWebDavOperationsSkipped(operationIds)

    /** 单条操作解密/校验失败时按 opId 记为已处理，避免整批同步永久失败。 */
    fun markWebDavOperationsSkipped(operationIds: List<String>) = Unit
}

/** WebDAV 拉取并发度；供应商会限流，保持在个位数。 */
internal const val WEBDAV_FETCH_PARALLELISM = 4

/** 顺序无关的并发映射；保持输入顺序并原样抛出第一个失败。 */
internal fun <T, R> parallelMap(items: List<T>, block: (T) -> R): List<R> {
    if (items.size <= 1) return items.map(block)
    val pool = Executors.newFixedThreadPool(minOf(WEBDAV_FETCH_PARALLELISM, items.size))
    return try {
        pool.invokeAll(items.map { item -> Callable { block(item) } }).map { future ->
            try {
                future.get()
            } catch (error: ExecutionException) {
                throw when (val cause = error.cause) {
                    is Exception -> cause
                    is Error -> cause
                    else -> error
                }
            }
        }
    } finally {
        pool.shutdownNow()
    }
}

internal object WebDavRetryPolicy {
    val delaysMillis = listOf(1_000L, 2_000L, 4_000L)
    private val retryableHttpStatuses = setOf(408, 425, 429, 500, 502, 503, 504)

    fun isRetryableHttpStatus(statusCode: Int): Boolean = statusCode in retryableHttpStatuses
}

/** 同步内核只依赖这一层，便于用内存实现测试拉取、推送与幂等。 */
interface WebDavOperationTransport {
    fun ensureCollections(vaultId: String)

    fun putOperation(operation: WebDavOperation)

    fun listOperationPaths(vaultId: String): List<List<String>>

    fun get(path: List<String>): ByteArray
}

/** 新账号自动使用的专属目录，避免和同一 WebDAV 账号下的其他应用混用。 */
internal object WebDavStorageLayout {
    const val APP_FOLDER = "WooTodo"

    fun isAppFolder(endpoint: String): Boolean =
        endpoint.trimEnd('/').substringAfterLast('/').equals(APP_FOLDER, ignoreCase = true)

    /**
     * 新账号落到 `<地址>/WooTodo`；已有空间的旧目录保持不变。
     * 先看专属目录，再看旧目录，避免同一个账号下同时存在两种布局时误判。
     */
    fun resolveEndpoint(
        endpoint: String,
        vaultId: String?,
        hasVaultAt: (String) -> Boolean,
        hasPairingAt: (String) -> Boolean,
    ): String {
        val base = endpoint.trimEnd('/')
        if (isAppFolder(base)) return base
        val namespaced = "$base/$APP_FOLDER"
        if (vaultId != null) {
            return when {
                hasVaultAt(namespaced) -> namespaced
                hasVaultAt(base) -> base
                else -> namespaced
            }
        }
        return when {
            hasPairingAt(namespaced) -> namespaced
            hasPairingAt(base) -> base
            else -> namespaced
        }
    }
}

class WebDavClient(
    val account: WebDavAccount,
    httpClient: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(java.time.Duration.ofSeconds(10))
        .readTimeout(java.time.Duration.ofSeconds(20))
        .writeTimeout(java.time.Duration.ofSeconds(20))
        .build(),
    private val retryDelaysMillis: List<Long> = WebDavRetryPolicy.delaysMillis,
    private val retrySleep: (Long) -> Unit = Thread::sleep,
) : WebDavOperationTransport, WebDavDeviceHeartbeatTransport {
    init {
        account.validate()
    }

    private val baseUrl = account.endpoint.toHttpUrl()
    private val httpClient = httpClient.newBuilder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()
    private val authorization = Credentials.basic(account.username, account.appPassword)

    /** 同一轮同步内只对相同目录发一次 MKCOL。 */
    private val ensuredCollections = java.util.concurrent.ConcurrentHashMap.newKeySet<List<String>>()

    override fun ensureCollections(vaultId: String) {
        listOf(
            listOf("v1"),
            listOf("v1", vaultId),
            listOf("v1", vaultId, "ops"),
        ).forEach(::ensureCollection)
    }

    private fun ensureCollection(path: List<String>) {
        if (!ensuredCollections.add(path)) return
        try {
            request("MKCOL", path, null, emptyMap(), setOf(201, 405, 409))
        } catch (error: Exception) {
            ensuredCollections.remove(path)
            throw error
        }
    }

    /** 账号配置页用一次 MKCOL + PROPFIND 验证地址与凭据。 */
    fun testConnection() {
        ensurePairingCollection()
        listPairingFileNames()
    }

    /** 加入已有空间前先取远端最大 lamport，作为本地基线操作的起点。 */
    fun maximumLamport(vaultId: String): Long {
        ensureCollections(vaultId)
        return WebDavOperationIndex.maximumLamport(this, vaultId)
    }

    /** 只探测不创建，用于判断账号根目录或专属目录是否已经属于某个同步空间。 */
    fun hasPairingDirectory(): Boolean = directoryExists(listOf("v1", PAIRING_DIRECTORY))

    fun hasVaultDirectory(vaultId: String): Boolean = directoryExists(listOf("v1", vaultId))

    private fun directoryExists(path: List<String>): Boolean = try {
        propfind(path)
        true
    } catch (error: WebDavException.Http) {
        if (error.statusCode in setOf(403, 404, 409)) false else throw error
    }

    fun ensurePairingCollection() {
        listOf(
            listOf("v1"),
            listOf("v1", PAIRING_DIRECTORY),
        ).forEach { request("MKCOL", it, null, emptyMap(), setOf(201, 405, 409)) }
    }

    override fun putOperation(operation: WebDavOperation) {
        operation.validate()
        val path = WebDavOperation.path(operation.vaultId, operation.opId)
        ensureCollection(path.dropLast(1))
        if (!putFile(path, operation.canonicalJson().toByteArray(StandardCharsets.UTF_8))) {
            throw WebDavException.ObjectConflict(path.joinToString("/"))
        }
    }

    override fun listOperationPaths(vaultId: String): List<List<String>> {
        val root = listOf("v1", vaultId, "ops")
        val shards = propfind(root)
            .filter {
                it.size == root.size + 1 &&
                    WebDavOperation.isValidShard(it.last())
            }
            .map(List<String>::last)
            .distinct()
            .sorted()
        return parallelMap(shards) { shard ->
            propfind(root + shard).filter {
                it.size == root.size + 2 && it.last().endsWith(".json")
            }
        }.flatten().sortedBy { it.joinToString("/") }
    }

    override fun get(path: List<String>): ByteArray = request(
        "GET",
        path,
        null,
        emptyMap(),
        setOf(200),
    ).body

    fun listPairingFileNames(): List<String> {
        ensurePairingCollection()
        return propfind(listOf("v1", PAIRING_DIRECTORY))
            .filter {
                it.size == 3 && it[0] == "v1" && it[1] == PAIRING_DIRECTORY &&
                    it.last().endsWith(".json")
            }
            .map(List<String>::last)
            .distinct()
            .sorted()
    }

    fun getPairingFileOrNull(name: String): String? = try {
        String(get(listOf("v1", PAIRING_DIRECTORY, name)), StandardCharsets.UTF_8)
    } catch (error: WebDavException.Http) {
        if (error.statusCode == 404) null else throw error
    }

    fun putPairingFileIfAbsent(name: String, content: String): Boolean {
        val path = listOf("v1", PAIRING_DIRECTORY, name)
        return putFile(path, content.toByteArray(StandardCharsets.UTF_8))
    }

    fun deletePairingFile(name: String) {
        request(
            "DELETE",
            listOf("v1", PAIRING_DIRECTORY, name),
            null,
            emptyMap(),
            setOf(200, 204, 404),
        )
    }

    override fun ensureDevicesCollection(vaultId: String) {
        listOf(
            listOf("v1"),
            listOf("v1", vaultId),
            listOf("v1", vaultId, DEVICES_DIRECTORY),
        ).forEach { request("MKCOL", it, null, emptyMap(), setOf(201, 405, 409)) }
    }

    /** 覆盖写入自己的心跳；调用方需先 ensureDevicesCollection。 */
    override fun putDeviceHeartbeat(vaultId: String, deviceId: String, content: String) {
        if (!WebDavCredentialPolicy.isValidVaultId(vaultId) ||
            !WebDavCredentialPolicy.isValidDeviceId(deviceId)
        ) {
            throw WebDavException.MalformedObject("设备心跳路径无效")
        }
        request(
            method = "PUT",
            path = deviceHeartbeatPath(vaultId, deviceId),
            body = content.toByteArray(StandardCharsets.UTF_8),
            headers = mapOf("Content-Type" to "application/json"),
            accepted = setOf(200, 201, 204),
        )
    }

    override fun listDeviceHeartbeatFileNames(vaultId: String): List<String> {
        val root = listOf("v1", vaultId, DEVICES_DIRECTORY)
        return propfind(root)
            .filter {
                it.size == root.size + 1 &&
                    it.subList(0, root.size) == root &&
                    it.last().endsWith(".json")
            }
            .map(List<String>::last)
            .distinct()
            .sorted()
    }

    override fun getDeviceHeartbeatOrNull(vaultId: String, deviceId: String): String? = try {
        String(get(deviceHeartbeatPath(vaultId, deviceId)), StandardCharsets.UTF_8)
    } catch (error: WebDavException.Http) {
        if (error.statusCode == 404) null else throw error
    }

    override fun deleteDeviceHeartbeat(vaultId: String, deviceId: String) {
        request(
            "DELETE",
            deviceHeartbeatPath(vaultId, deviceId),
            null,
            emptyMap(),
            setOf(200, 204, 404),
        )
    }

    private fun deviceHeartbeatPath(vaultId: String, deviceId: String): List<String> =
        listOf("v1", vaultId, DEVICES_DIRECTORY, "$deviceId.json")

    /** 写入成功或已有完全相同内容返回 true；已有不同内容返回 false。 */
    private fun putFile(path: List<String>, data: ByteArray): Boolean {
        val result = request(
            method = "PUT",
            path = path,
            body = data,
            headers = mapOf("Content-Type" to "application/json", "If-None-Match" to "*"),
            accepted = setOf(200, 201, 204, 405, 409, 412),
        )
        if (result.code in setOf(405, 409, 412)) {
            val existing = get(path)
            if (!existing.contentEquals(data)) return false
        }
        return true
    }

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
        return WebDavPropfindParser.parse(
            String(response.body, StandardCharsets.UTF_8),
            baseUrl.pathSegments.filter(String::isNotEmpty),
        )
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
        var retryIndex = 0
        while (true) {
            val result = try {
                httpClient.newCall(request).execute().use { response ->
                    val responseBody = response.body?.bytes() ?: ByteArray(0)
                    ResponseData(response.code, responseBody)
                }
            } catch (error: IOException) {
                if (retryIndex >= retryDelaysMillis.size) {
                    throw WebDavException.Transport(error.localizedMessage ?: "网络不可用")
                }
                retryIndex = waitBeforeRetry(retryIndex)
                continue
            } catch (error: WebDavException) {
                throw error
            } catch (error: Exception) {
                throw WebDavException.Transport(error.localizedMessage ?: "网络不可用")
            }
            if (result.code in accepted) return result
            if (!WebDavRetryPolicy.isRetryableHttpStatus(result.code) ||
                retryIndex >= retryDelaysMillis.size
            ) {
                throw WebDavException.Http(result.code)
            }
            retryIndex = waitBeforeRetry(retryIndex)
        }
    }

    private fun waitBeforeRetry(retryIndex: Int): Int {
        try {
            retrySleep(retryDelaysMillis[retryIndex])
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw WebDavException.Transport("同步已取消")
        }
        return retryIndex + 1
    }

    private data class ResponseData(val code: Int, val body: ByteArray)

    private companion object {
        const val PAIRING_DIRECTORY = "pairing"
        const val DEVICES_DIRECTORY = "devices"
    }
}

class WebDavSyncRunner(
    private val transport: WebDavOperationTransport,
    private val identity: WebDavIdentity,
    private val outbox: OutboxStore,
    private val local: WebDavLocalApplying,
    private val onWarning: (String, Throwable) -> Unit = { message, error ->
        android.util.Log.w("WooTodoWebDav", message, error)
    },
    /** 同步全部成功并确认 outbox 后触发；心跳失败不能影响同步结果。 */
    private val onSynchronized: () -> Unit = {},
) {
    fun synchronize(): SyncRunSummary {
        identity.validate()
        transport.ensureCollections(identity.vaultId)
        val pushed = pushPendingOperations()
        // 首次导入或离线积压：本轮只推送，不下发翻页扫描；下一轮继续推送，
        // 直到 outbox 清空才拉取远端，避免每批 200 条都重复 1+N 次 PROPFIND。
        if (pushed > 0 && outbox.pendingOperations(1).isNotEmpty()) {
            runCatching(onSynchronized)
                .onFailure { onWarning("同步完成后写入设备心跳失败", it) }
            return SyncRunSummary(
                pushed = pushed,
                pulled = 0,
                pages = 0,
                finalCursor = 0,
                moreWork = true,
            )
        }
        val paths = transport.listOperationPaths(identity.vaultId)
        val candidates = mutableListOf<Pair<List<String>, String>>()
        paths.forEach { path ->
            try {
                candidates += path to operationId(path)
            } catch (error: WebDavException) {
                onWarning("跳过无效的 WebDAV 对象路径", error)
            }
        }
        val pendingIds = local.pendingWebDavOperationIds(candidates.map { it.second })
        var pulled = 0
        // 按窗口拉取并立即应用：中途失败时已落地的批次不会重做。
        candidates
            .filter { (_, opId) -> opId in pendingIds }
            .chunked(WEBDAV_APPLY_BATCH_SIZE)
            .forEach { window ->
                val outcomes = parallelMap(window) { (path, opId) ->
                    fetchOperation(path, opId)
                }
                val skipped = mutableListOf<String>()
                val operations = mutableListOf<WebDavOperation>()
                outcomes.forEach { outcome ->
                    val operation = outcome.operation
                    when {
                        operation != null -> operations += operation
                        outcome.skippable -> {
                            onWarning(outcome.warningMessage, checkNotNull(outcome.error))
                            skipped += outcome.opId
                        }

                        else -> throw checkNotNull(outcome.error)
                    }
                }
                if (skipped.isNotEmpty()) local.markWebDavOperationsSkipped(skipped)
                operations.chunked(WEBDAV_APPLY_BATCH_SIZE).forEach(::applyBatch)
                pulled += operations.size
            }
        try {
            onSynchronized()
        } catch (error: Exception) {
            onWarning("同步完成后写入设备心跳失败", error)
        }
        return SyncRunSummary(
            pushed = pushed,
            pulled = pulled,
            pages = webDavPageCount(pulled),
            finalCursor = 0,
        )
    }

    /**
     * 连续推送多批直到本轮上限：只推送 50 条会让首次上传需要十几次同步，
     * 而同一分片的 MKCOL 已由 transport 去重。上传成功即确认，失败重试不会重复上传。
     */
    private fun pushPendingOperations(): Int {
        var pushed = 0
        while (pushed < MAXIMUM_PUSH_OPS_PER_RUN) {
            val limit = minOf(
                SyncCoordinator.MAXIMUM_PUSH_BATCH,
                MAXIMUM_PUSH_OPS_PER_RUN - pushed,
            )
            val pending = outbox.pendingOperations(limit)
            if (pending.isEmpty()) break
            val uploaded = mutableListOf<String>()
            try {
                pending.forEach { push ->
                    transport.putOperation(
                        WebDavOperation.from(push, identity.vaultId, identity.deviceId),
                    )
                    uploaded += push.opId
                }
            } finally {
                if (uploaded.isNotEmpty()) {
                    outbox.acknowledgeOperations(uploaded)
                    // 已上传的操作就是本地状态，拉取阶段不应再下载并应用一遍。
                    local.markWebDavOperationsApplied(uploaded)
                }
            }
            pushed += pending.size
            if (pending.size < limit) break
        }
        return pushed
    }

    private fun fetchOperation(path: List<String>, opId: String): FetchOutcome {
        val operation = try {
            WebDavOperation.decode(String(transport.get(path), StandardCharsets.UTF_8))
        } catch (error: WebDavException.MalformedObject) {
            return FetchOutcome(opId, null, error, skippable = true, warningMessage = "跳过无法解析的 WebDAV 操作：$opId")
        } catch (error: WebDavException.Http) {
            if (error.statusCode != 404) return FetchOutcome(opId, null, error, skippable = false, warningMessage = "")
            return FetchOutcome(opId, null, error, skippable = true, warningMessage = "远端操作已不存在：$opId")
        }
        if (operation.vaultId != identity.vaultId ||
            path != WebDavOperation.path(operation.vaultId, operation.opId)
        ) {
            return FetchOutcome(
                opId = opId,
                operation = null,
                error = WebDavException.MalformedObject("同步对象元数据不匹配"),
                skippable = true,
                warningMessage = "跳过与当前空间或路径不匹配的 WebDAV 操作：$opId",
            )
        }
        return FetchOutcome(opId, operation, null, skippable = false, warningMessage = "")
    }

    private data class FetchOutcome(
        val opId: String,
        val operation: WebDavOperation?,
        val error: Exception?,
        val skippable: Boolean,
        val warningMessage: String,
    )

    /**
     * 批量应用失败时退化为逐条应用：单条解密/校验失败的操作按 opId 跳过并告警，
     * 其他操作继续应用，避免一个坏对象让整批同步永久失败。
     */
    private fun applyBatch(batch: List<WebDavOperation>) {
        try {
            local.applyWebDavOperations(batch)
            return
        } catch (error: Exception) {
            if (!isSkippableOperationFailure(error)) throw error
        }
        val skipped = mutableListOf<String>()
        batch.forEach { operation ->
            try {
                local.applyWebDavOperations(listOf(operation))
            } catch (error: Exception) {
                if (!isSkippableOperationFailure(error)) throw error
                onWarning("跳过无法应用的 WebDAV 操作：${operation.opId}", error)
                skipped += operation.opId
            }
        }
        if (skipped.isNotEmpty()) local.markWebDavOperationsSkipped(skipped)
    }

    companion object {
        internal const val WEBDAV_APPLY_BATCH_SIZE = 500

        /** 每轮同步最多确认的待发送操作；超出部分留给下一轮，避免一次产生过多请求。 */
        internal const val MAXIMUM_PUSH_OPS_PER_RUN = 200

        internal fun webDavPageCount(operationCount: Int): Int =
            maxOf(1, (operationCount + WEBDAV_APPLY_BATCH_SIZE - 1) / WEBDAV_APPLY_BATCH_SIZE)

        internal fun isSkippableOperationFailure(error: Exception): Boolean =
            error is WebDavException || error is SyncCryptoException ||
                error is ProtocolJsonException || error is IllegalArgumentException

        private fun operationId(path: List<String>): String {
            val fileName = path.lastOrNull()
                ?: throw WebDavException.MalformedObject("对象路径缺少 opId")
            if (!fileName.endsWith(".json") || fileName.length <= ".json".length) {
                throw WebDavException.MalformedObject("对象路径缺少有效的 opId")
            }
            return fileName.removeSuffix(".json")
        }
    }
}

/** 只读扫描远端操作，供加入已有空间时确定本地 lamport 起点。 */
internal object WebDavOperationIndex {
    fun maximumLamport(
        transport: WebDavOperationTransport,
        vaultId: String,
        onWarning: (String, Throwable) -> Unit = { message, error ->
            android.util.Log.w("WooTodoWebDav", message, error)
        },
    ): Long {
        var maximum = 0L
        // 加入空间时最多要扫描全部历史；并发读取避免移动端在配对后等十几分钟。
        transport.listOperationPaths(vaultId)
            .chunked(WebDavSyncRunner.WEBDAV_APPLY_BATCH_SIZE)
            .forEach { window ->
                val lamports = parallelMap(window) { path ->
                    try {
                        val operation = WebDavOperation.decode(
                            String(transport.get(path), StandardCharsets.UTF_8),
                        )
                        if (operation.vaultId == vaultId) operation.lamport else 0L
                    } catch (error: WebDavException.MalformedObject) {
                        onWarning("跳过无法解析的 WebDAV 操作：${path.joinToString("/")}", error)
                        0L
                    } catch (error: WebDavException.Http) {
                        if (error.statusCode != 404) throw error
                        onWarning("远端操作已不存在：${path.joinToString("/")}", error)
                        0L
                    }
                }
                lamports.forEach { maximum = maxOf(maximum, it) }
            }
        return maximum
    }
}

internal object WebDavPropfindParser {
    fun parse(source: String, basePathSegments: List<String>): List<List<String>> {
        val parser = Xml.newPullParser().apply {
            // WebDAV 服务常见响应使用 d:href；同时开启命名空间处理并保留本地名兜底。
            setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
            setInput(StringReader(source))
        }
        val paths = mutableListOf<List<String>>()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG && isHrefElement(parser.name)) {
                parseHref(parser.nextText(), basePathSegments)?.let(paths::add)
            }
            event = parser.next()
        }
        return paths
    }

    private fun isHrefElement(name: String?): Boolean =
        name?.substringAfterLast(':')?.equals("href", ignoreCase = true) == true

    private fun parseHref(raw: String, basePathSegments: List<String>): List<String>? {
        val value = raw.trim()
        if (value.isEmpty()) {
            throw WebDavException.MalformedObject("PROPFIND href 无效")
        }
        val uri = try {
            java.net.URI(value)
        } catch (_: Exception) {
            null
        } ?: throw WebDavException.MalformedObject("PROPFIND href 无效")
        val rawPath = uri.rawPath?.takeIf(String::isNotEmpty)
            ?: throw WebDavException.MalformedObject("PROPFIND href 无效")
        val segments = rawPath
            .split('/')
            .filter(String::isNotEmpty)
            .map(::decodePathSegment)
        val isRelativePath = !uri.isAbsolute && uri.rawAuthority == null && !rawPath.startsWith('/')
        if (isRelativePath) {
            return segments.takeIf { it.firstOrNull() == "v1" }
        }
        if (segments.size < basePathSegments.size ||
            segments.take(basePathSegments.size) != basePathSegments
        ) {
            return null
        }
        return segments.drop(basePathSegments.size).takeIf { it.firstOrNull() == "v1" }
    }

    private fun decodePathSegment(value: String): String {
        val decoded = try {
            java.net.URLDecoder.decode(
                value.replace("+", "%2B"),
                StandardCharsets.UTF_8.name(),
            )
        } catch (_: Exception) {
            throw WebDavException.MalformedObject("PROPFIND href 无效")
        }
        if (decoded == "." || decoded == ".." || decoded.contains('/') || decoded.contains('\\')) {
            throw WebDavException.MalformedObject("PROPFIND href 无效")
        }
        return decoded
    }
}

fun newWebDavIdentity(): WebDavIdentity = WebDavIdentity(
    vaultId = "vault-${Base64Url.encode(SecureBytes.generate(9))}",
    deviceId = UUID.randomUUID().toString().lowercase(),
    vaultKey = SecureBytes.generate(Aes256Gcm.KEY_BYTES),
)
