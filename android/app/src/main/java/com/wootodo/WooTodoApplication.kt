package com.wootodo

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import com.wootodo.data.LegacyTaskDateMigration
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskRepository
import com.wootodo.display.DayCounterPreferences
import com.wootodo.reminder.NotificationHelper
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.TaskReminderScheduler
import com.wootodo.sync.AndroidSyncCredentialsStore
import com.wootodo.sync.AutomaticSyncRequestGate
import com.wootodo.sync.BearerCredential
import com.wootodo.sync.LegacySyncDetector
import com.wootodo.sync.LegacySyncNotice
import com.wootodo.sync.PairingCompletion
import com.wootodo.sync.PairingException
import com.wootodo.sync.SQLiteSyncStore
import com.wootodo.sync.SyncApiClient
import com.wootodo.sync.SyncCoordinator
import com.wootodo.sync.SyncCredentials
import com.wootodo.sync.SyncDeviceManager
import com.wootodo.sync.SyncEndpointPolicy
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncJobScheduler
import com.wootodo.sync.SyncLeavePolicy
import com.wootodo.sync.SyncRunner
import com.wootodo.sync.SyncRuntime
import com.wootodo.sync.SyncRuntimeState
import com.wootodo.sync.SyncStatusPreferences
import com.wootodo.sync.bindPairedSyncStore
import com.wootodo.sync.readDisplayConfiguration
import com.wootodo.sync.writeDisplayConfiguration
import com.wootodo.widget.TodayWidgetUpdater
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.CancellationException

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
    val syncCredentialsStore by lazy { AndroidSyncCredentialsStore(this) }
    val syncStatusPreferences by lazy { SyncStatusPreferences(this) }
    val legacySyncNotice by lazy { LegacySyncNotice(this) }
    val syncRuntime: SyncRuntime by lazy {
        SyncRuntime(
            runnerFactory = { createSyncRunner() },
        )
    }

    /** 只返回端点符合 HTTPS Worker 规则的凭据；旧 LAN/WebDAV 凭据视为未配对。 */
    fun activeSyncCredentials(): SyncCredentials? = runCatching {
        syncCredentialsStore.load()?.takeIf { SyncEndpointPolicy.isValid(it.endpoint) }
    }.getOrNull()

    fun activeSyncConfigured(): Boolean = activeSyncCredentials() != null

    /** 旧凭据不删除、不启用；升级后只提示一次重新配对。 */
    fun legacySyncDetected(): Boolean = runCatching {
        if (activeSyncConfigured()) return false
        LegacySyncDetector.detects(
            hasWebDavCredentials = legacySyncNotice.hasWebDavCredentials(),
            syncCredentialsEndpoint = syncCredentialsStore.load()?.endpoint,
        )
    }.getOrDefault(false)

    private fun createSyncRunner(): SyncRunner? = activeSyncCredentials()?.let { credentials ->
        SyncRunner(createSyncCoordinator(credentials)::synchronize)
    }

    /** 调用方应在 IO 线程运行同步；尚未配对时返回 null。 */
    fun createSyncCoordinator(): SyncCoordinator? =
        activeSyncCredentials()?.let(::createSyncCoordinator)

    private fun createSyncCoordinator(credentials: SyncCredentials): SyncCoordinator {
        ensureDisplayConfigurationStored()
        val syncStore = SQLiteSyncStore(
            database = database,
            credentials = credentials,
            onTasksChanged = { onRemoteTasksChanged() },
            onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
        )
        return SyncCoordinator(
            transport = SyncApiClient(credentials.endpoint),
            outbox = syncStore,
            remoteApplyStore = syncStore,
            credential = BearerCredential(credentials.deviceToken),
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

    suspend fun finalizePairing(
        completion: PairingCompletion,
        previousCredentials: SyncCredentials?,
    ) {
        check(completion.deviceId.isNotBlank() && completion.vaultId.isNotBlank())
        syncRuntime.withExclusiveConfiguration {
            try {
                withContext(Dispatchers.IO) {
                    val credentials = checkNotNull(syncCredentialsStore.load()) {
                        "同步凭据未完成保存"
                    }
                    check(
                        credentials.deviceId == completion.deviceId &&
                            credentials.vaultId == completion.vaultId
                    ) { "配对结果与本地同步凭据不一致" }
                    // 先验证新端点，确保重绑后不会因客户端构造失败回滚。
                    SyncApiClient(credentials.endpoint)
                    ensureDisplayConfigurationStored()
                    if (completion.replacedExistingCredentials) {
                        SyncJobScheduler.cancel(this@WooTodoApplication)
                    }
                    bindPairedSyncStore(
                        database = database,
                        credentials = credentials,
                        replacedExistingCredentials = completion.replacedExistingCredentials,
                        onTasksChanged = { onRemoteTasksChanged() },
                        onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
                    )
                }
            } catch (error: CancellationException) {
                // 凭据已完整落盘时保留它；下次启动会继续完成数据库绑定。
                throw error
            } catch (error: Exception) {
                runCatching {
                    if (previousCredentials == null) {
                        syncCredentialsStore.delete()
                    } else {
                        syncCredentialsStore.save(previousCredentials)
                    }
                }
                val fallbackConfigured = withContext(Dispatchers.IO) {
                    runCatching { activeSyncConfigured() }.getOrDefault(false)
                }
                syncRuntime.refreshConfiguration(fallbackConfigured)
                if (fallbackConfigured) {
                    SyncJobScheduler.ensurePeriodic(this)
                    SyncJobScheduler.enqueueImmediate(this)
                } else {
                    SyncJobScheduler.cancel(this)
                }
                throw PairingException.LocalBindingFailed
            }
            syncStatusPreferences.clear()
            syncRuntime.refreshConfiguration(true)
            SyncJobScheduler.ensurePeriodic(this)
            SyncJobScheduler.enqueueImmediate(this)
        }
        applicationScope.launch { syncRuntime.synchronize() }
    }

    /** 退出同步空间：先撤销服务端设备，再清除本机凭据并重置同步绑定，任务保留。 */
    suspend fun leaveSyncSpace(credentials: SyncCredentials) {
        syncRuntime.withExclusiveConfiguration {
            withContext(Dispatchers.IO) {
                SyncJobScheduler.cancel(this@WooTodoApplication)
                try {
                    SyncDeviceManager().leaveSpace(credentials)
                } catch (error: Exception) {
                    // 设备已被其他设备移除时服务端会拒绝撤销，但本地仍须完成退出。
                    if (!SyncLeavePolicy.serverAlreadyRemoved(error)) throw error
                }
                // 先成功解绑数据库，再删除凭据；解绑失败时保留凭据并抛出，
                // 避免留下「无凭据但数据库仍绑定」的无法恢复状态。
                SQLiteSyncStore.resetSyncBinding(database)
                syncCredentialsStore.delete()
                syncStatusPreferences.clear()
            }
            syncRuntime.refreshConfiguration(false)
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
