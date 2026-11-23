package com.wootodo.sync

import android.content.Context

/** 旧同步方式只用于检测，不读取、不删除其中的凭据。 */
object LegacySyncDetector {
    fun detects(hasWebDavCredentials: Boolean, syncCredentialsEndpoint: String?): Boolean =
        hasWebDavCredentials ||
            (syncCredentialsEndpoint != null &&
                !SyncEndpointPolicy.isValid(syncCredentialsEndpoint))
}

class LegacySyncNotice(context: Context) {
    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun hasWebDavCredentials(): Boolean {
        val legacy = applicationContext.getSharedPreferences(
            WEBDAV_PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        return legacy.contains(WEBDAV_CIPHERTEXT_KEY) || legacy.contains(WEBDAV_NONCE_KEY)
    }

    fun shouldShowOnce(): Boolean = !preferences.getBoolean(KEY_SHOWN, false)

    fun markShown() {
        preferences.edit().putBoolean(KEY_SHOWN, true).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "sync_legacy_notice"
        const val KEY_SHOWN = "legacy_notice_shown"
        const val WEBDAV_PREFERENCES_NAME = "webdav_credentials_encrypted"
        const val WEBDAV_CIPHERTEXT_KEY = "ciphertext"
        const val WEBDAV_NONCE_KEY = "nonce"
    }
}

/** 最近一次成功同步时间，供跨设备页在重启后继续显示。 */
class SyncStatusPreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun lastSuccessfulSyncAt(): Long? = preferences
        .getLong(KEY_LAST_SUCCESS, 0L)
        .takeIf { it > 0L }

    fun recordSuccessfulSync(finishedAt: Long) {
        preferences.edit().putLong(KEY_LAST_SUCCESS, finishedAt).apply()
    }

    fun clear() {
        preferences.edit().remove(KEY_LAST_SUCCESS).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "sync_status"
        const val KEY_LAST_SUCCESS = "last_success_at"
    }
}

/** 没有构建期地址时，首台设备填写并持久化的自托管 Worker 地址。 */
class SelfHostedEndpointPreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun load(): String? = SyncEndpointPolicy.normalize(
        preferences.getString(KEY_ENDPOINT, null),
    )

    fun save(endpoint: String) {
        val normalized = SyncEndpointPolicy.normalize(endpoint)
            ?: throw IllegalArgumentException("同步服务地址无效")
        check(preferences.edit().putString(KEY_ENDPOINT, normalized).commit()) {
            "无法保存同步服务地址"
        }
    }

    private companion object {
        const val PREFERENCES_NAME = "sync_endpoint"
        const val KEY_ENDPOINT = "endpoint"
    }
}
