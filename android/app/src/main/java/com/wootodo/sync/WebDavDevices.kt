package com.wootodo.sync

import java.nio.charset.StandardCharsets
import org.json.JSONObject

internal object WebDavDeviceProtocol {
    const val FORMAT = "woo-todo-webdav-device"
    const val PROTOCOL_VERSION = 1
    const val DIRECTORY = "devices"
    const val AAD_PREFIX = "woo-todo-webdav-device-v1"
    const val MAX_NAME_CODE_POINTS = 80
    const val MAX_APP_VERSION_LENGTH = 32

    fun aad(vaultId: String, deviceId: String): ByteArray =
        "$AAD_PREFIX|$vaultId|$deviceId".toByteArray(StandardCharsets.UTF_8)
}

/** 设备心跳明文；信封只暴露格式、版本、deviceId、nonce 与密文。 */
data class WebDavDeviceHeartbeat(
    val deviceId: String,
    val name: String,
    val platform: DevicePlatform,
    val lastSeenAt: Long,
    val appVersion: String,
) {
    fun validate() {
        if (!WebDavCredentialPolicy.isValidDeviceId(deviceId) ||
            name.isEmpty() ||
            name.codePointCount(0, name.length) > WebDavDeviceProtocol.MAX_NAME_CODE_POINTS ||
            name.any(Char::isISOControl) ||
            lastSeenAt <= 0L ||
            appVersion.isEmpty() ||
            appVersion.codePointCount(0, appVersion.length) >
            WebDavDeviceProtocol.MAX_APP_VERSION_LENGTH ||
            appVersion.any(Char::isISOControl)
        ) {
            throw WebDavException.MalformedObject("设备心跳字段无效")
        }
    }

    fun seal(
        vaultId: String,
        vaultKey: ByteArray,
        nonce: ByteArray = SecureBytes.generate(Aes256Gcm.NONCE_BYTES),
    ): String {
        validate()
        if (!WebDavCredentialPolicy.isValidVaultId(vaultId)) {
            throw WebDavException.MalformedObject("同步空间 ID 无效")
        }
        val plaintext = JSONObject()
            .put("name", name)
            .put("platform", platform.wireValue)
            .put("lastSeenAt", lastSeenAt)
            .put("appVersion", appVersion)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        val envelope = try {
            Aes256Gcm.seal(
                plaintext = plaintext,
                key = vaultKey,
                nonce = nonce,
                aad = WebDavDeviceProtocol.aad(vaultId, deviceId),
            )
        } finally {
            plaintext.fill(0)
        }
        return JSONObject()
            .put("format", WebDavDeviceProtocol.FORMAT)
            .put("protocolVersion", WebDavDeviceProtocol.PROTOCOL_VERSION)
            .put("deviceId", deviceId)
            .put("nonce", envelope.nonce)
            .put("ciphertext", envelope.ciphertext)
            .toString()
    }

    companion object {
        private val envelopeFields =
            setOf("format", "protocolVersion", "deviceId", "nonce", "ciphertext")
        private val plaintextFields = setOf("name", "platform", "lastSeenAt", "appVersion")

        fun decode(source: String, vaultId: String, vaultKey: ByteArray): WebDavDeviceHeartbeat {
            try {
                val value = JSONObject(source)
                if (value.keys().asSequence().toSet() != envelopeFields) {
                    throw WebDavException.MalformedObject("设备心跳字段不匹配")
                }
                val format = value.opt("format") as? String
                    ?: throw WebDavException.MalformedObject("设备心跳字段类型不匹配")
                val protocolVersion = value.opt("protocolVersion")
                val deviceId = value.opt("deviceId") as? String
                    ?: throw WebDavException.MalformedObject("设备心跳字段类型不匹配")
                val nonce = value.opt("nonce") as? String
                    ?: throw WebDavException.MalformedObject("设备心跳字段类型不匹配")
                val ciphertext = value.opt("ciphertext") as? String
                    ?: throw WebDavException.MalformedObject("设备心跳字段类型不匹配")
                val supportedVersion =
                    (protocolVersion is Int && protocolVersion == WebDavDeviceProtocol.PROTOCOL_VERSION) ||
                        (protocolVersion is Long &&
                            protocolVersion == WebDavDeviceProtocol.PROTOCOL_VERSION.toLong())
                if (format != WebDavDeviceProtocol.FORMAT || !supportedVersion) {
                    throw WebDavException.MalformedObject("不支持的设备心跳协议版本")
                }
                if (!WebDavCredentialPolicy.isValidVaultId(vaultId) ||
                    !WebDavCredentialPolicy.isValidDeviceId(deviceId)
                ) {
                    throw WebDavException.MalformedObject("设备心跳路径无效")
                }
                val plaintext = Aes256Gcm.open(
                    envelope = EncryptedEnvelope(nonce = nonce, ciphertext = ciphertext),
                    key = vaultKey,
                    aad = WebDavDeviceProtocol.aad(vaultId, deviceId),
                )
                return try {
                    decodePlaintext(plaintext, deviceId)
                } finally {
                    plaintext.fill(0)
                }
            } catch (error: WebDavException) {
                throw error
            } catch (_: Exception) {
                throw WebDavException.MalformedObject("设备心跳格式无效")
            }
        }

        private fun decodePlaintext(
            plaintext: ByteArray,
            deviceId: String,
        ): WebDavDeviceHeartbeat {
            val value = JSONObject(String(plaintext, StandardCharsets.UTF_8))
            if (value.keys().asSequence().toSet() != plaintextFields) {
                throw WebDavException.MalformedObject("设备心跳明文字段不匹配")
            }
            val name = value.opt("name") as? String
                ?: throw WebDavException.MalformedObject("设备心跳字段类型不匹配")
            val platform = DevicePlatform.fromWire(
                value.opt("platform") as? String
                    ?: throw WebDavException.MalformedObject("设备心跳字段类型不匹配"),
            )
            val lastSeenAt = when (val raw = value.opt("lastSeenAt")) {
                is Int -> raw.toLong()
                is Long -> raw
                else -> throw WebDavException.MalformedObject("设备心跳字段类型不匹配")
            }
            val appVersion = value.opt("appVersion") as? String
                ?: throw WebDavException.MalformedObject("设备心跳字段类型不匹配")
            return WebDavDeviceHeartbeat(
                deviceId = deviceId,
                name = name,
                platform = platform,
                lastSeenAt = lastSeenAt,
                appVersion = appVersion,
            ).also(WebDavDeviceHeartbeat::validate)
        }
    }
}

/** 设备列表条目；isCurrent 由本机 identity 判定。 */
data class WebDavDeviceInfo(
    val deviceId: String,
    val name: String,
    val platform: DevicePlatform,
    val lastSeenAt: Long,
    val appVersion: String,
    val isCurrent: Boolean,
)

/**
 * 设备心跳存储接口。调用方先 [ensureDevicesCollection]，实现负责
 * v1/<vaultId>/devices/<deviceId>.json 的覆盖写入、枚举与读取。
 */
interface WebDavDeviceHeartbeatTransport {
    fun ensureDevicesCollection(vaultId: String)

    fun putDeviceHeartbeat(vaultId: String, deviceId: String, content: String)

    fun listDeviceHeartbeatFileNames(vaultId: String): List<String>

    /** 文件不存在返回 null；其他错误以 WebDavException 抛出。 */
    fun getDeviceHeartbeatOrNull(vaultId: String, deviceId: String): String?

    fun deleteDeviceHeartbeat(vaultId: String, deviceId: String)
}

class WebDavDeviceDirectory(
    private val transport: WebDavDeviceHeartbeatTransport,
    private val identity: WebDavIdentity,
    private val clockMillis: () -> Long = System::currentTimeMillis,
    private val onWarning: (String, Throwable) -> Unit = { message, error ->
        android.util.Log.w("WooTodoWebDav", message, error)
    },
) {
    /** 用 PUT 覆盖自己的心跳；不写其他设备。 */
    fun writeHeartbeat(name: String, appVersion: String) {
        identity.validate()
        val heartbeat = WebDavDeviceHeartbeat(
            deviceId = identity.deviceId,
            name = WebDavCredentialPolicy.normalizeDeviceName(name),
            platform = DevicePlatform.ANDROID,
            lastSeenAt = clockMillis(),
            appVersion = appVersion,
        )
        heartbeat.validate()
        val content = heartbeat.seal(identity.vaultId, identity.vaultKey)
        transport.ensureDevicesCollection(identity.vaultId)
        transport.putDeviceHeartbeat(identity.vaultId, identity.deviceId, content)
    }

    /**
     * 尽力枚举设备：坏文件、未知版本、deviceId 与文件名不匹配的心跳只跳过并记录，
     * 不删除其他设备写入的文件。结果按 lastSeenAt 降序。
     */
    fun listDevices(): List<WebDavDeviceInfo> {
        identity.validate()
        transport.ensureDevicesCollection(identity.vaultId)
        return transport.listDeviceHeartbeatFileNames(identity.vaultId)
            .mapNotNull { fileName ->
                val deviceId = deviceIdFromFileName(fileName) ?: run {
                    onWarning(
                        "跳过无效的设备心跳文件名：$fileName",
                        WebDavException.MalformedObject("设备心跳文件名无效"),
                    )
                    return@mapNotNull null
                }
                val content = try {
                    transport.getDeviceHeartbeatOrNull(identity.vaultId, deviceId)
                } catch (error: WebDavException) {
                    onWarning("跳过无法读取的设备心跳：$fileName", error)
                    return@mapNotNull null
                } ?: return@mapNotNull null
                val heartbeat = try {
                    WebDavDeviceHeartbeat.decode(content, identity.vaultId, identity.vaultKey)
                } catch (error: Exception) {
                    onWarning("跳过无法解析的设备心跳：$fileName", error)
                    return@mapNotNull null
                }
                if (heartbeat.deviceId != deviceId) {
                    onWarning(
                        "跳过设备 ID 与文件名不匹配的心跳：$fileName",
                        WebDavException.MalformedObject("设备心跳 deviceId 与文件名不匹配"),
                    )
                    return@mapNotNull null
                }
                WebDavDeviceInfo(
                    deviceId = heartbeat.deviceId,
                    name = heartbeat.name,
                    platform = heartbeat.platform,
                    lastSeenAt = heartbeat.lastSeenAt,
                    appVersion = heartbeat.appVersion,
                    isCurrent = heartbeat.deviceId == identity.deviceId,
                )
            }
            .distinctBy(WebDavDeviceInfo::deviceId)
            .sortedWith(
                compareByDescending<WebDavDeviceInfo> { it.lastSeenAt }
                    .thenBy { it.deviceId },
            )
    }

    /** 退出空间时尽力删除自己的心跳；删除失败不会阻止退出。 */
    fun deleteOwnHeartbeat() {
        identity.validate()
        transport.deleteDeviceHeartbeat(identity.vaultId, identity.deviceId)
    }

    companion object {
        fun deviceIdFromFileName(fileName: String): String? {
            if (!fileName.endsWith(".json") || fileName.length <= ".json".length) return null
            val deviceId = fileName.removeSuffix(".json")
            return deviceId.takeIf(WebDavCredentialPolicy::isValidDeviceId)
        }
    }
}
