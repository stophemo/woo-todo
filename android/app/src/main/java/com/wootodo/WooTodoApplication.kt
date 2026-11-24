package com.wootodo

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import com.wootodo.data.LegacyTaskDateMigration
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskRepository
import com.wootodo.display.DayCounterPreferences
import com.wootodo.reminder.NotificationHelper
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.TaskReminderScheduler
import com.wootodo.sync.AndroidWebDavCredentialsStore
import com.wootodo.sync.AutomaticSyncRequestGate
import com.wootodo.sync.JoinLocalDataReset
import com.wootodo.sync.LegacySyncNotice
import com.wootodo.sync.SQLiteSyncStore
import com.wootodo.sync.SyncBindingConflictException
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncJobScheduler
import com.wootodo.sync.SyncRunner
import com.wootodo.sync.SyncRuntime
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.sync.SyncStatusPreferences
import com.wootodo.sync.WebDavAccount
import com.wootodo.sync.WebDavClient
import com.wootodo.sync.WebDavCredentials
import com.wootodo.sync.WebDavDeviceDirectory
import com.wootodo.sync.WebDavDeviceInfo
import com.wootodo.sync.WebDavIdentity
import com.wootodo.sync.WebDavPairingException
import com.wootodo.sync.WebDavSyncRunner
import com.wootodo.sync.bindPairedSyncStore
import com.wootodo.sync.newWebDavIdentity
import com.wootodo.sync.readDisplayConfiguration
import com.wootodo.sync.withIdentityRollback
import com.wootodo.sync.writeDisplayConfiguration
import com.wootodo.ui.DeviceName
import com.wootodo.widget.TodayWidgetUpdater
import java.util.concurrent.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class WooTodoApplication : Application() {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val automaticSyncGate = AutomaticSyncRequestGate()
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            requestNetworkRestoredSync()
        }
    }
    val database: TaskDatabase by lazy { TaskDatabase(this) }
    val taskStore: SQLiteTaskStore by lazy { SQLiteTaskStore(database) }
    val taskRepository: TaskRepository by lazy { TaskRepository(taskStore) }
    val webDavCredentialsStore by lazy { AndroidWebDavCredentialsStore(this) }
    val syncStatusPreferences by lazy { SyncStatusPreferences(this) }
    val legacySyncNotice by lazy { LegacySyncNotice(this) }
    val syncRuntime: SyncRuntime by lazy {
        SyncRuntime(
            runnerFactory = { createSyncRunner() },
        )
    }

    /** 账号与身份分开保存；任一部分缺失或无效都视为未配置。 */
    fun webDavAccount(): WebDavAccount? = runCatching {
        webDavCredentialsStore.loadAccount()
    }.getOrNull()

    fun activeSyncCredentials(): WebDavCredentials? = runCatching {
        webDavCredentialsStore.load()
    }.getOrNull()

    fun activeSyncConfigured(): Boolean = activeSyncCredentials() != null

    /** 读取 WebDAV 加密心跳设备列表；坏文件已在存储层跳过。 */
    suspend fun listWebDavDevices(): List<WebDavDeviceInfo> = withContext(Dispatchers.IO) {
        val credentials = activeSyncCredentials() ?: return@withContext emptyList()
        webDavDeviceDirectory(credentials.account, credentials.identity).listDevices()
    }

    /** 旧版 Worker / LAN 凭据保留但不启用；旧 WebDAV 凭据会自动迁移。 */
    fun legacySyncDetected(): Boolean = runCatching {
        if (activeSyncConfigured()) return false
        legacySyncNotice.hasWorkerOrLanCredentials()
    }.getOrDefault(false)

    private fun webDavDeviceDirectory(
        account: WebDavAccount,
        identity: WebDavIdentity,
    ): WebDavDeviceDirectory = WebDavDeviceDirectory(
        transport = WebDavClient(account),
        identity = identity,
    )

    /** 心跳是尽力而为的附加信息：失败只记录，不影响空间创建、同步或退出。 */
    private fun writeWebDavHeartbeat(
        account: WebDavAccount,
        identity: WebDavIdentity,
        name: String = DeviceName.current(this),
    ) {
        runCatching {
            webDavDeviceDirectory(account, identity).writeHeartbeat(
                name = name,
                appVersion = BuildConfig.VERSION_NAME,
            )
        }.onFailure { Log.w("WooTodoWebDav", "写入 WebDAV 设备心跳失败", it) }
    }

    private fun deleteWebDavHeartbeat(account: WebDavAccount, identity: WebDavIdentity) {
        runCatching {
            webDavDeviceDirectory(account, identity).deleteOwnHeartbeat()
        }.onFailure { Log.w("WooTodoWebDav", "删除 WebDAV 设备心跳失败", it) }
    }

    private fun createSyncRunner(): SyncRunner? {
        val credentials = activeSyncCredentials() ?: return null
        ensureDisplayConfigurationStored()
        // 首次绑定前先取远端最大 lamport，避免本地基线操作覆盖已有空间的历史数据。
        val remoteLamportFloor = if (SQLiteSyncStore.needsBinding(database)) {
            WebDavClient(credentials.account).maximumLamport(credentials.vaultId)
        } else {
            0L
        }
        val syncStore = try {
            SQLiteSyncStore(
                database = database,
                credentials = credentials.syncIdentity(),
                onTasksChanged = { onRemoteTasksChanged() },
                onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
                remoteLamportFloor = remoteLamportFloor,
            )
        } catch (_: SyncBindingConflictException) {
            // 本机刚从 Worker/LAN 升级或数据库仍绑定旧身份：保留任务并重新绑定 WebDAV。
            SQLiteSyncStore.replaceSyncBinding(
                database = database,
                credentials = credentials.syncIdentity(),
                onTasksChanged = { onRemoteTasksChanged() },
                onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
                remoteLamportFloor = WebDavClient(credentials.account)
                    .maximumLamport(credentials.vaultId),
            )
        }
        return SyncRunner(
            WebDavSyncRunner(
                transport = WebDavClient(credentials.account),
                identity = credentials.identity,
                outbox = syncStore,
                local = syncStore,
                onSynchronized = {
                    writeWebDavHeartbeat(credentials.account, credentials.identity)
                },
            )::synchronize,
        )
    }

    private fun onRemoteTasksChanged() {
        taskStore.invalidateFromSync()
        applicationScope.launch {
            val settled = runCatching {
                taskRepository.settleRecurringTasks()
            }.getOrDefault(0)
            TodayWidgetUpdater.updateAll(this@WooTodoApplication)
            TaskReminderScheduler.scheduleAll(this@WooTodoApplication)
            if (settled > 0) notifyLocalMutation()
        }
    }

    /** 日期变化或应用回到前台时结算每天重复任务。 */
    fun settleRecurringTasksAsync() {
        applicationScope.launch {
            val settled = runCatching {
                taskRepository.settleRecurringTasks()
            }.getOrDefault(0)
            if (settled > 0) {
                TodayWidgetUpdater.updateAll(this@WooTodoApplication)
                TaskReminderScheduler.scheduleAll(this@WooTodoApplication)
                notifyLocalMutation()
            }
        }
    }

    private fun onRemoteDisplayConfigurationChanged(
        payload: com.wootodo.sync.DisplayConfigurationPayload,
    ) {
        // 远端显示配置只同步分类；标题、副标题与计时日期仍只留本机。
        taskStore.invalidateCategoriesFromSync()
        TodayWidgetUpdater.updateAllAsync(this)
    }

    private fun ensureDisplayConfigurationStored() {
        val preferencePayload = DayCounterPreferences.toPayload(DayCounterPreferences.load(this))
        val sqlite = database.writableDatabase
        var storedPayload = preferencePayload
        sqlite.beginTransaction()
        try {
            val existing = readDisplayConfiguration(sqlite)
            if (existing == null) {
                writeDisplayConfiguration(
                    sqlite,
                    preferencePayload,
                    isLocalOverride = false,
                )
            } else {
                storedPayload = existing
            }
            sqlite.setTransactionSuccessful()
        } finally {
            sqlite.endTransaction()
        }
        if (storedPayload != preferencePayload) {
            DayCounterPreferences.applyRemote(this, storedPayload)
        }
    }

    suspend fun saveWebDavAccount(account: WebDavAccount) = withContext(Dispatchers.IO) {
        account.validate()
        webDavCredentialsStore.saveAccount(account)
        syncRuntime.refreshConfiguration(activeSyncConfigured())
    }

    /** 建立首个同步空间：生成 vaultId/vaultKey/deviceId 并确保 v1/<vaultId>/ops 存在。 */
    suspend fun createWebDavSpace(deviceName: String): WebDavIdentity {
        var createdIdentity: WebDavIdentity? = null
        syncRuntime.withExclusiveConfiguration {
            withContext(Dispatchers.IO) {
                val account = webDavCredentialsStore.loadAccount()
                    ?: throw WebDavPairingException.LocalBindingFailed
                val identity = newWebDavIdentity()
                // 先确认 WebDAV 目录可写，再保存身份，避免留下无法同步的空间。
                WebDavClient(account).ensureCollections(identity.vaultId)
                val previous = webDavCredentialsStore.loadIdentity()
                if (previous != null) {
                    throw WebDavPairingException.AlreadyPaired
                }
                webDavCredentialsStore.saveIdentity(identity)
                try {
                    bindStoredIdentity(identity, replaced = false)
                } catch (error: Exception) {
                    webDavCredentialsStore.deleteIdentity()
                    throw error
                }
                syncStatusPreferences.clear()
                writeWebDavHeartbeat(account, identity, deviceName)
                createdIdentity = identity
            }
            syncRuntime.refreshConfiguration(true)
            SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
            SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
        }
        applicationScope.launch { syncRuntime.synchronize() }
        return checkNotNull(createdIdentity)
    }

    /**
     * 配对成功后写入新身份并绑定任务库。本机已有旧身份时整体替换；
     * 数据库仍绑定旧空间但本机没有 WebDAV 身份时也允许 replace。
     */
    suspend fun adoptWebDavIdentity(identity: WebDavIdentity) {
        identity.validate()
        syncRuntime.withExclusiveConfiguration {
            withContext(Dispatchers.IO) {
                val account = webDavCredentialsStore.loadAccount()
                    ?: throw WebDavPairingException.LocalBindingFailed
                val previous = webDavCredentialsStore.loadIdentity()
                if (previous != null && previous != identity) {
                    throw WebDavPairingException.CredentialsOverwritten
                }
                // 加入已有空间：先取远端最大 lamport 作为本地基线水位，再绑定并开始同步。
                val remoteLamportFloor = WebDavClient(account).maximumLamport(identity.vaultId)
                if (previous == null && !webDavCredentialsStore.saveIdentityIfAbsent(identity)) {
                    val stored = webDavCredentialsStore.loadIdentity()
                    if (stored != identity) {
                        throw WebDavPairingException.CredentialsOverwritten
                    }
                }
                try {
                    withIdentityRollback(
                        previous = previous,
                        saveIdentity = webDavCredentialsStore::saveIdentity,
                        deleteIdentity = webDavCredentialsStore::deleteIdentity,
                    ) {
                        bindStoredIdentity(
                            identity,
                            replaced = previous != null,
                            remoteLamportFloor = remoteLamportFloor,
                        )
                    }
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Exception) {
                    val fallbackConfigured = activeSyncConfigured()
                    syncRuntime.refreshConfiguration(fallbackConfigured)
                    if (fallbackConfigured) {
                        SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
                        SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
                    } else {
                        SyncJobScheduler.cancel(this@WooTodoApplication)
                    }
                    throw WebDavPairingException.LocalBindingFailed
                }
                syncStatusPreferences.clear()
                writeWebDavHeartbeat(account, identity)
            }
            syncRuntime.refreshConfiguration(true)
            SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
            SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
        }
        applicationScope.launch { syncRuntime.synchronize() }
    }

    /** 只在网络互斥锁内调用；调用方负责保存身份与失败回滚。 */
    private fun bindStoredIdentity(
        identity: WebDavIdentity,
        replaced: Boolean,
        remoteLamportFloor: Long = 0,
    ) {
        val account = checkNotNull(webDavCredentialsStore.loadAccount()) {
            "WebDAV 账号未完成保存"
        }
        val credentials = WebDavCredentials(account, identity).also {
            it.validate()
        }
        ensureDisplayConfigurationStored()
        bindPairedSyncStore(
            database = database,
            credentials = credentials.syncIdentity(),
            replacedExistingCredentials = replaced,
            onTasksChanged = { onRemoteTasksChanged() },
            onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
            remoteLamportFloor = remoteLamportFloor,
        )
    }

    /** 退出同步空间：只清本机身份，保留账号与本地任务；远端需改应用密码才会失效。 */
    suspend fun leaveSyncSpace() = syncRuntime.withExclusiveConfiguration {
        withContext(Dispatchers.IO) {
            SyncJobScheduler.cancel(this@WooTodoApplication)
            SQLiteSyncStore.resetSyncBinding(database)
            // 心跳删除是尽力而为：即使读取旧凭据失败，也必须继续退出空间。
            runCatching { webDavCredentialsStore.load() }.getOrNull()?.let { credentials ->
                deleteWebDavHeartbeat(credentials.account, credentials.identity)
            }
            webDavCredentialsStore.deleteIdentity()
            syncStatusPreferences.clear()
        }
        syncRuntime.refreshConfiguration(false)
    }

    /**
     * 加入其他空间前清空本机任务、回收站、分类与同步状态，保留 WebDAV 账号与显示偏好。
     * 必须先删除并确认旧身份，确认后才停止同步并原子清空任务；任一步失败都不会采纳新身份。
     */
    suspend fun clearLocalTasksForJoin() {
        val previousCredentials = withContext(Dispatchers.IO) {
            runCatching { webDavCredentialsStore.load() }.getOrNull()
        }
        syncRuntime.withExclusiveConfiguration {
            withContext(Dispatchers.IO) {
                JoinLocalDataReset(
                    deleteIdentity = { webDavCredentialsStore.deleteIdentity() },
                    loadIdentity = { webDavCredentialsStore.loadIdentity() },
                    stopSync = { SyncJobScheduler.cancel(this@WooTodoApplication) },
                    clearLocalData = { SQLiteSyncStore.clearAllLocalTasks(database) },
                    onUnpaired = {
                        // 身份已确认删除：无论任务清空成败都回到未配对并刷新本地展示。
                        syncStatusPreferences.clear()
                        syncRuntime.refreshConfiguration(false)
                        taskStore.invalidateFromSync()
                        taskStore.invalidateCategoriesFromSync()
                        runCatching {
                            TodayWidgetUpdater.updateAll(this@WooTodoApplication)
                        }
                        runCatching {
                            TaskReminderScheduler.scheduleAll(this@WooTodoApplication)
                        }
                        // 心跳删除是尽力而为：失败不能阻止本地清空或加入流程。
                        previousCredentials?.let { credentials ->
                            deleteWebDavHeartbeat(credentials.account, credentials.identity)
                        }
                    },
                ).reset()
            }
        }
    }

    suspend fun synchronizeManually(): SyncExecutionResult {
        val result = syncRuntime.synchronize()
        if (result is SyncExecutionResult.Failed && result.retryable) {
            withContext(Dispatchers.IO) {
                SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
            }
        } else {
            SyncJobScheduler.cancelImmediate(this)
        }
        return result
    }

    /** 本地写入已经落入 SQLite outbox，联网后由持久化 Job 发送。 */
    fun notifyLocalMutation() {
        TaskReminderScheduler.scheduleAllAsync(this)
        requestAutomaticSync()
    }

    fun notifyAppForegrounded() {
        requestAutomaticSync()
    }

    private fun requestNetworkRestoredSync() {
        requestAutomaticSync(replacePendingJob = true)
    }

    private fun requestAutomaticSync(replacePendingJob: Boolean = false) {
        if (!automaticSyncGate.request(replacePendingJob)) return
        applicationScope.launch {
            while (true) {
                val request = automaticSyncGate.takeNext() ?: break
                try {
                    synchronizeAutomatically(request.replacePendingJob)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    // 状态与持久化 Job 已在同步入口内更新，保留下一次自动触发。
                }
            }
        }
    }

    private suspend fun synchronizeAutomatically(replacePendingJob: Boolean = false) {
        val configured = runCatching { activeSyncConfigured() }.getOrDefault(false)
        syncRuntime.refreshConfiguration(configured)
        if (!configured) {
            SyncJobScheduler.cancel(this)
            return
        }
        SyncJobScheduler.ensurePeriodic(this)
        SyncJobScheduler.enqueueImmediate(this, replaceExisting = replacePendingJob)
        when (val result = syncRuntime.synchronize()) {
            is SyncExecutionResult.Failed -> {
                if (!result.retryable) SyncJobScheduler.cancelImmediate(this)
            }
            SyncExecutionResult.NotConfigured,
            is SyncExecutionResult.Succeeded,
            -> SyncJobScheduler.cancelImmediate(this)
        }
    }

    private fun migrateLegacyTaskDatesIfNeeded() {
        val preferences = getSharedPreferences(
            LegacyTaskDateMigration.PREFERENCES,
            Context.MODE_PRIVATE,
        )
        if (preferences.getBoolean(LegacyTaskDateMigration.KEY, false)) return
        applicationScope.launch {
            runCatching {
                val planned = LegacyTaskDateMigration.plan(taskRepository.allTasks())
                planned.forEach { task ->
                    taskRepository.update(
                        task.id,
                        LegacyTaskDateMigration.draft(task),
                    )
                }
                preferences.edit()
                    .putBoolean(LegacyTaskDateMigration.KEY, true)
                    .apply()
                if (planned.isNotEmpty()) {
                    TodayWidgetUpdater.updateAll(this@WooTodoApplication)
                    TaskReminderScheduler.scheduleAll(this@WooTodoApplication)
                    notifyLocalMutation()
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createChannel(this)
        ReminderScheduler.schedule(this)
        migrateLegacyTaskDatesIfNeeded()
        getSystemService(ConnectivityManager::class.java)
            ?.registerDefaultNetworkCallback(networkCallback)
        applicationScope.launch {
            syncRuntime.state.collect { state ->
                if (state is SyncRuntimeState.Succeeded) {
                    syncStatusPreferences.recordSuccessfulSync(state.finishedAt)
                }
            }
        }
        applicationScope.launch {
            // 首次读取时会自动迁移 0.2.x 的完整 WebDAV 凭据。
            val configured = runCatching {
                activeSyncConfigured()
            }.getOrDefault(false)
            try {
                taskRepository.settleRecurringTasks()
                TodayWidgetUpdater.updateAll(this@WooTodoApplication)
                TaskReminderScheduler.scheduleAll(this@WooTodoApplication)
            } finally {
                // 无论本地启动维护是否失败，都要让界面离开 Loading，显示真实配对状态。
                syncRuntime.refreshConfiguration(configured)
                if (configured) {
                    SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
                    SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
                } else {
                    SyncJobScheduler.cancel(this@WooTodoApplication)
                }
            }
        }
    }
}
