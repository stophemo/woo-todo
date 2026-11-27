package com.wootodo.sync

import java.nio.charset.StandardCharsets
import org.json.JSONObject

class WebDavInviteException(message: String) : IllegalArgumentException(message)

/**
 * 邀请二维码/链接里的内容：完整的目标目录、账号、应用密码、空间 ID 与同步密钥。
 * 这只是本机之间传递的一次性秘密，不写入 WebDAV；请只给自己的设备扫描。
 */
data class WebDavInvite(
    val account: WebDavAccount,
    val vaultId: String,
    val vaultKey: ByteArray,
    val issuedAt: Long,
    val expiresAt: Long,
) {
    init {
        account.validate()
        require(WebDavCredentialPolicy.isValidVaultId(vaultId)) { "邀请缺少有效的同步空间" }
        require(WebDavCredentialPolicy.isValidVaultKey(vaultKey)) { "邀请缺少有效的同步密钥" }
        require(issuedAt in 0..expiresAt) { "邀请时间无效" }
    }

    /** 第二台设备必须生成自己的 deviceId，避免两台设备共用同步身份。 */
    fun identity(deviceId: String): WebDavIdentity =
        WebDavIdentity(vaultId, deviceId, vaultKey).also(WebDavIdentity::validate)

    /** 不把应用密码写进日志或崩溃报告。 */
    override fun toString(): String =
        "WebDavInvite(vaultId=$vaultId, endpoint=${account.endpoint}, issuedAt=$issuedAt, expiresAt=$expiresAt)"

    fun encode(): String {
        val json = JSONObject()
            .put("v", PROTOCOL_VERSION)
            .put("endpoint", account.endpoint)
            .put("username", account.username)
            .put("appPassword", account.appPassword)
            .put("vaultId", vaultId)
            .put("vaultKey", Base64Url.encode(vaultKey))
            .put("issuedAt", issuedAt)
            .put("expiresAt", expiresAt)
            .toString()
        return PREFIX + Base64Url.encode(json.toByteArray(StandardCharsets.UTF_8))
    }

    companion object {
        const val PREFIX = "woo-todo-invite:1:"
        const val TTL_MILLIS = 10L * 60L * 1_000L
        private const val PROTOCOL_VERSION = 1
        private const val MAXIMUM_LENGTH = 4_096
        private const val CLOCK_SKEW_MILLIS = 5L * 60L * 1_000L
        private val KEYS = setOf(
            "v", "endpoint", "username", "appPassword",
            "vaultId", "vaultKey", "issuedAt", "expiresAt",
        )

        fun create(credentials: WebDavCredentials, now: Long): WebDavInvite = WebDavInvite(
            account = credentials.account,
            vaultId = credentials.vaultId,
            vaultKey = credentials.vaultKey,
            issuedAt = now,
            expiresAt = now + TTL_MILLIS,
        )

        fun decode(source: String, now: Long): WebDavInvite {
            val value = source.trim()
            if (value.length > MAXIMUM_LENGTH || !value.startsWith(PREFIX)) throw invalid()
            val json = try {
                JSONObject(
                    String(
                        Base64Url.decode(value.removePrefix(PREFIX)),
                        StandardCharsets.UTF_8,
                    ),
                )
            } catch (_: Exception) {
                throw invalid()
            }
            if (json.keys().asSequence().toSet() != KEYS || json.optInt("v") != PROTOCOL_VERSION) {
                throw invalid()
            }
            val invite = try {
                WebDavInvite(
                    account = WebDavAccount(
                        endpoint = json.getString("endpoint"),
                        username = json.getString("username"),
                        appPassword = json.getString("appPassword"),
                    ),
                    vaultId = json.getString("vaultId"),
                    vaultKey = Base64Url.decode(json.getString("vaultKey")),
                    issuedAt = json.getLong("issuedAt"),
                    expiresAt = json.getLong("expiresAt"),
                )
            } catch (_: Exception) {
                throw invalid()
            }
            if (invite.expiresAt <= now) {
                throw WebDavInviteException("邀请已过期，请在已配对的设备上重新生成")
            }
            if (invite.issuedAt > now + CLOCK_SKEW_MILLIS ||
                invite.expiresAt - invite.issuedAt > TTL_MILLIS + CLOCK_SKEW_MILLIS
            ) {
                throw invalid()
            }
            return invite
        }

        private fun invalid() = WebDavInviteException("邀请无效或格式不正确")
    }
}
