package com.wootodo.sync

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/**
 * macOS 近旁配置 Android 的坚果云深链。该链接等同于应用密码和同步密钥，不能写入日志或持久化。
 */
data class WebDavSetupLink(
    val username: String,
    val appPassword: String,
    val vaultId: String,
    val vaultKey: ByteArray,
) {
    init {
        require(WebDavCredentialPolicy.isValidUsername(username)) { "坚果云账号无效" }
        require(WebDavCredentialPolicy.isValidAppPassword(appPassword)) { "坚果云应用密码无效" }
        require(WebDavCredentialPolicy.isValidVaultId(vaultId)) { "同步空间名无效" }
        require(WebDavCredentialPolicy.isValidVaultKey(vaultKey)) { "同步密钥长度无效" }
    }

    fun toUri(): String = buildString {
        append("wootodo://webdav?")
        append("v=1")
        append('&').append(query("username", username))
        append('&').append(query("appPassword", appPassword))
        append('&').append(query("vaultId", vaultId))
        append('&').append(query("vaultKey", Base64Url.encode(vaultKey)))
    }

    override fun equals(other: Any?): Boolean = other is WebDavSetupLink &&
        username == other.username && appPassword == other.appPassword &&
        vaultId == other.vaultId && vaultKey.contentEquals(other.vaultKey)

    override fun hashCode(): Int = 31 * listOf(username, appPassword, vaultId).hashCode() +
        vaultKey.contentHashCode()

    override fun toString(): String =
        "WebDavSetupLink(username=<已隐藏>, appPassword=<已隐藏>, vaultId=<已隐藏>, vaultKey=<已隐藏>)"

    private fun query(key: String, value: String): String =
        "$key=${URLEncoder.encode(value, StandardCharsets.UTF_8.name()).replace("+", "%20")}"

    companion object {
        private val requiredKeys = setOf("v", "username", "appPassword", "vaultId", "vaultKey")

        fun parse(source: String): WebDavSetupLink {
            val uri = try {
                URI(source)
            } catch (error: Exception) {
                throw IllegalArgumentException("坚果云配置链接不是有效 URI", error)
            }
            require(
                uri.scheme?.equals("wootodo", ignoreCase = true) == true &&
                    uri.host?.equals("webdav", ignoreCase = true) == true &&
                    uri.rawPath.isNullOrEmpty() && uri.rawFragment == null &&
                    uri.rawUserInfo == null && uri.port == -1 && uri.rawQuery != null,
            ) { "坚果云配置链接地址无效" }

            val values = linkedMapOf<String, String>()
            uri.rawQuery!!.split('&').forEach { part ->
                require(part.isNotEmpty()) { "坚果云配置链接包含空字段" }
                val separator = part.indexOf('=')
                require(separator > 0) { "坚果云配置链接字段格式无效" }
                val key = decode(part.substring(0, separator))
                require(key in requiredKeys && key !in values) {
                    "坚果云配置链接字段不匹配"
                }
                values[key] = decode(part.substring(separator + 1))
            }
            require(values.keys == requiredKeys) { "坚果云配置链接字段不完整" }
            require(values.getValue("v") == "1") { "坚果云配置链接版本不支持" }
            return WebDavSetupLink(
                username = values.getValue("username"),
                appPassword = values.getValue("appPassword"),
                vaultId = values.getValue("vaultId"),
                vaultKey = try {
                    Base64Url.decode(values.getValue("vaultKey"))
                } catch (error: Exception) {
                    throw IllegalArgumentException("坚果云配置链接同步密钥无效", error)
                },
            )
        }

        private fun decode(value: String): String = try {
            // Query 参数是 URI 组件而不是 application/x-www-form-urlencoded；原始 '+' 必须保留。
            URLDecoder.decode(value.replace("+", "%2B"), StandardCharsets.UTF_8.name())
        } catch (error: Exception) {
            throw IllegalArgumentException("坚果云配置链接编码无效", error)
        }
    }
}
