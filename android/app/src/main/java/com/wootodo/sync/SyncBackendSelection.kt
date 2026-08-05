package com.wootodo.sync

import android.content.Context

enum class SyncBackend(val persistedValue: String) {
    WORKER_OR_LOCAL("workerOrLocal"),
    WEB_DAV("webDav"),
    ;

    companion object {
        fun fromPersistedValue(value: String?): SyncBackend? =
            entries.firstOrNull { it.persistedValue == value }
    }
}

internal object SyncBackendSelectionPolicy {
    fun resolve(
        persistedValue: String?,
        hasWorkerOrLocalCredentials: Boolean,
        hasWebDavCredentials: Boolean,
    ): SyncBackend? {
        val persisted = SyncBackend.fromPersistedValue(persistedValue)
        if (persisted == SyncBackend.WORKER_OR_LOCAL && hasWorkerOrLocalCredentials) {
            return persisted
        }
        if (persisted == SyncBackend.WEB_DAV && hasWebDavCredentials) {
            return persisted
        }
        // 旧版本同时出现两套凭据时 WebDAV 一直具有优先级，迁移时保持原行为。
        return when {
            hasWebDavCredentials -> SyncBackend.WEB_DAV
            hasWorkerOrLocalCredentials -> SyncBackend.WORKER_OR_LOCAL
            else -> null
        }
    }
}

class AndroidSyncBackendSelection(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    @Synchronized
    fun resolve(
        hasWorkerOrLocalCredentials: Boolean,
        hasWebDavCredentials: Boolean,
    ): SyncBackend? = SyncBackendSelectionPolicy.resolve(
        persistedValue = preferences.getString(ACTIVE_BACKEND_KEY, null),
        hasWorkerOrLocalCredentials = hasWorkerOrLocalCredentials,
        hasWebDavCredentials = hasWebDavCredentials,
    )

    @Synchronized
    fun persist(backend: SyncBackend) {
        check(
            preferences.edit()
                .putString(ACTIVE_BACKEND_KEY, backend.persistedValue)
                .commit(),
        ) { "无法保存活动同步方式" }
    }

    private companion object {
        const val PREFERENCES_NAME = "sync_backend_selection"
        const val ACTIVE_BACKEND_KEY = "active_backend"
    }
}
