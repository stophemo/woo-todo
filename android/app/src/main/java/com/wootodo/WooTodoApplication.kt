package com.wootodo

import android.app.Application
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskRepository
import com.wootodo.reminder.NotificationHelper
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.TaskReminderScheduler
import com.wootodo.sync.AndroidSyncCredentialsStore
import com.wootodo.sync.AndroidWebDavCredentialsStore
import com.wootodo.sync.BearerCredential
import com.wootodo.sync.PairingCompletion
import com.wootodo.sync.PairingException
import com.wootodo.sync.BackupRestoreResult
import com.wootodo.sync.BackupTransferService
import com.wootodo.sync.SQLiteBackupDatabase
import com.wootodo.sync.SQLiteSyncStore
import com.wootodo.sync.SyncApiClient
import com.wootodo.sync.SyncCoordinator
import com.wootodo.sync.SyncJobScheduler
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRunner
import com.wootodo.sync.SyncRuntime
import com.wootodo.sync.WebDavClient
import com.wootodo.sync.WebDavCredentials
import com.wootodo.sync.WebDavSyncRunner
import com.wootodo.widget.TodayWidgetUpdater
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import java.util.concurrent.CancellationException

class WooTodoApplication : Application() {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    val database: TaskDatabase by lazy { TaskDatabase(this) }
    val taskStore: SQLiteTaskStore by lazy { SQLiteTaskStore(database) }
    val taskRepository: TaskRepository by lazy { TaskRepository(taskStore) }
    val syncCredentialsStore by lazy { AndroidSyncCredentialsStore(this) }
    val webDavCredentialsStore by lazy { AndroidWebDavCredentialsStore(this) }
    private val backupDatabase by lazy { SQLiteBackupDatabase(database) }
    private val backupTransferService by lazy {
        BackupTransferService(backupDatabase, syncCredentialsStore)
    }
    val syncRuntime: SyncRuntime by lazy {
        SyncRuntime(
            runnerFactory = { createSyncRunner() },
        )
    }

    private fun createSyncRunner(): SyncRunner? {
        val webDav = webDavCredentialsStore.load()
        if (webDav != null) {
            val syncStore = SQLiteSyncStore(
                database = database,
                credentials = webDav.syncIdentity(),
                onTasksChanged = { onRemoteTasksChanged() },
            )
            return SyncRunner(WebDavSyncRunner(
                client = WebDavClient(webDav),
                outbox = syncStore,
                local = syncStore,
            )::synchronize)
        }
        return createSyncCoordinator()?.let { coordinator ->
            SyncRunner(coordinator::synchronize)
        }
    }

    /** 调用方应在 IO 线程运行同步；尚未配对时返回 null。 */
    fun createSyncCoordinator(): SyncCoordinator? {
        if (webDavCredentialsStore.load() != null) return null
        val credentials = syncCredentialsStore.load() ?: return null
        val syncStore = SQLiteSyncStore(
            database = database,
            credentials = credentials,
            onTasksChanged = { onRemoteTasksChanged() },
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
        TodayWidgetUpdater.updateAllAsync(this)
        TaskReminderScheduler.scheduleAllAsync(this)
    }

    suspend fun configureWebDav(credentials: WebDavCredentials) = withContext(Dispatchers.IO) {
        if (syncCredentialsStore.load() != null) {
            throw IllegalStateException("当前已配置 Worker 同步，请先使用现有同步方式")
        }
        val previous = webDavCredentialsStore.load()
        webDavCredentialsStore.save(credentials)
        try {
            SQLiteSyncStore(database, credentials.syncIdentity())
        } catch (error: Exception) {
            if (previous == null) webDavCredentialsStore.delete() else webDavCredentialsStore.save(previous)
            throw error
        }
        syncRuntime.refreshConfiguration(configured = true)
        SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
        SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
    }

    suspend fun finalizePairing(completion: PairingCompletion) {
        check(completion.deviceId.isNotBlank() && completion.vaultId.isNotBlank())
        try {
            withContext(Dispatchers.IO) {
                checkNotNull(createSyncCoordinator()) { "同步凭据未完成保存" }
            }
        } catch (error: CancellationException) {
            // 凭据已完整落盘时保留它；下次启动会继续完成数据库绑定。
            throw error
        } catch (error: Exception) {
            runCatching { syncCredentialsStore.delete() }
            syncRuntime.refreshConfiguration(configured = false)
            SyncJobScheduler.cancel(this)
            throw PairingException.LocalBindingFailed
        }
        syncRuntime.refreshConfiguration(configured = true)
        SyncJobScheduler.ensurePeriodic(this)
        SyncJobScheduler.enqueueImmediate(this)
        applicationScope.launch { syncRuntime.synchronize() }
    }

    suspend fun synchronizeManually(): SyncExecutionResult {
        val result = syncRuntime.synchronize()
        if (result is SyncExecutionResult.Failed && result.retryable) {
            SyncJobScheduler.enqueueImmediate(this)
        }
        return result
    }

    suspend fun hasBackupSyncCredentials(): Boolean = withContext(Dispatchers.IO) {
        backupTransferService.hasSyncCredentials()
    }

    suspend fun requireBackupRestoreReady() = withContext(Dispatchers.IO) {
        backupTransferService.requireRestoreReady()
    }

    suspend fun createEncryptedBackup(
        passphrase: String,
        confirmation: String,
        includeSyncCredentials: Boolean,
    ): ByteArray = withContext(Dispatchers.IO) {
        backupTransferService.createEncryptedBackup(
            passphrase = passphrase,
            confirmation = confirmation,
            includeSyncCredentials = includeSyncCredentials,
        )
    }

    suspend fun restoreEncryptedBackup(
        data: ByteArray,
        passphrase: String,
    ): BackupRestoreResult {
        val result = withContext(Dispatchers.IO) {
            backupTransferService.restoreEncryptedBackup(data, passphrase)
        }
        taskStore.invalidateFromSync()
        TodayWidgetUpdater.updateAllAsync(this)
        TaskReminderScheduler.scheduleAllAsync(this)
        val webDavConfigured = withContext(Dispatchers.IO) {
            webDavCredentialsStore.load() != null
        }
        syncRuntime.refreshConfiguration(result.syncCredentialsRestored || webDavConfigured)
        if (result.syncCredentialsRestored || webDavConfigured) {
            SyncJobScheduler.ensurePeriodic(this)
            SyncJobScheduler.enqueueImmediate(this)
            applicationScope.launch { syncRuntime.synchronize() }
        } else {
            SyncJobScheduler.cancel(this)
        }
        return result
    }

    /** 本地写入已经落入 SQLite outbox，联网后由持久化 Job 发送。 */
    fun notifyLocalMutation() {
        TaskReminderScheduler.scheduleAllAsync(this)
        applicationScope.launch {
            val configured = runCatching {
                syncCredentialsStore.load() != null || webDavCredentialsStore.load() != null
            }.getOrDefault(false)
            if (configured) {
                syncRuntime.refreshConfiguration(configured = true)
                SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
                SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createChannel(this)
        ReminderScheduler.schedule(this)
        applicationScope.launch {
            taskRepository.autoPassExpired()
            TodayWidgetUpdater.updateAll(this@WooTodoApplication)
            TaskReminderScheduler.scheduleAll(this@WooTodoApplication)
            val configured = runCatching {
                syncCredentialsStore.load() != null || webDavCredentialsStore.load() != null
            }.getOrDefault(false)
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
