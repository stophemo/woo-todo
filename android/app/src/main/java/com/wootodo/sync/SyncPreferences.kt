package com.wootodo.sync

import android.content.Context

/**
 * 旧版 Worker / 旧 LAN 凭据只用于提示，不读取、不删除、不启用。
 * 旧 WebDAV 完整凭据由 AndroidWebDavCredentialsStore 自动迁移，不再是 legacy。
 */
object LegacySyncDetector {
    fun detects(hasWorkerOrLanCredentials: Boolean): Boolean = hasWorkerOrLanCredentials
}

class LegacySyncNotice(context: Context) {
    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    fun hasWorkerOrLanCredentials(): Boolean {
        val legacy = applicationContext.getSharedPreferences(
            WORKER_PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        return legacy.contains(WORKER_CIPHERTEXT_KEY) || legacy.contains(WORKER_NONCE_KEY)
    }

    fun shouldShowOnce(): Boolean = !preferences.getBoolean(KEY_SHOWN, false)

    fun markShown() {
        preferences.edit().putBoolean(KEY_SHOWN, true).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "sync_legacy_notice"
        const val KEY_SHOWN = "legacy_notice_shown"
        const val WORKER_PREFERENCES_NAME = "sync_credentials_encrypted"
        const val WORKER_CIPHERTEXT_KEY = "ciphertext"
        const val WORKER_NONCE_KEY = "nonce"
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

    /** 设备心跳只是展示信息，不需要每轮同步都写一次。 */
    fun lastHeartbeatAt(): Long = preferences.getLong(KEY_LAST_HEARTBEAT, 0L)

    fun recordHeartbeat(at: Long) {
        preferences.edit().putLong(KEY_LAST_HEARTBEAT, at).apply()
    }

    fun clear() {
        preferences.edit()
            .remove(KEY_LAST_SUCCESS)
            .remove(KEY_LAST_HEARTBEAT)
            .apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "sync_status"
        const val KEY_LAST_SUCCESS = "last_success_at"
        const val KEY_LAST_HEARTBEAT = "last_heartbeat_at"
    }
}
