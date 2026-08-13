package com.wootodo

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.wootodo.data.SQLiteTaskStore
import com.wootodo.data.TaskDatabase
import com.wootodo.data.TaskRepository
import com.wootodo.display.DayCounterPreferences
import com.wootodo.reminder.NotificationHelper
import com.wootodo.reminder.ReminderScheduler
import com.wootodo.reminder.TaskReminderScheduler
import com.wootodo.sync.AndroidLocalNetworkServiceResolver
import com.wootodo.sync.AndroidSyncBackendSelection
import com.wootodo.sync.AndroidSyncCredentialsStore
import com.wootodo.sync.AndroidWebDavCredentialsStore
import com.wootodo.sync.AutomaticSyncRequestGate
import com.wootodo.sync.BearerCredential
import com.wootodo.sync.PairingCompletion
import com.wootodo.sync.PairingException
import com.wootodo.sync.RecoveringLocalNetworkSyncTransport
import com.wootodo.sync.SQLiteSyncStore
import com.wootodo.sync.SyncApiClient
import com.wootodo.sync.SyncBackend
import com.wootodo.sync.SyncCoordinator
import com.wootodo.sync.SyncCredentials
import com.wootodo.sync.SyncEndpointPolicy
import com.wootodo.sync.SyncEndpointScope
import com.wootodo.sync.SyncJobScheduler
import com.wootodo.sync.SyncExecutionResult
import com.wootodo.sync.SyncRunner
import com.wootodo.sync.SyncRuntime
import com.wootodo.sync.SyncTransportMode
import com.wootodo.sync.SyncTransportModePolicy
import com.wootodo.sync.WebDavClient
import com.wootodo.sync.WebDavCredentials
import com.wootodo.sync.WebDavSyncRunner
import com.wootodo.sync.readDisplayConfiguration
import com.wootodo.sync.writeDisplayConfiguration
import com.wootodo.widget.TodayWidgetUpdater
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.withContext
import kotlinx.coroutines.launch
import java.net.URI
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
    val webDavCredentialsStore by lazy { AndroidWebDavCredentialsStore(this) }
    val syncBackendSelection by lazy { AndroidSyncBackendSelection(this) }
    val syncRuntime: SyncRuntime by lazy {
        SyncRuntime(
            runnerFactory = { createSyncRunner() },
        )
    }

    private fun createSyncRunner(): SyncRunner? {
        val webDav = webDavCredentialsStore.load()
        val workerOrLocal = syncCredentialsStore.load()
        return when (resolveSyncBackend(workerOrLocal, webDav)) {
            SyncBackend.WEB_DAV -> {
                val credentials = webDav ?: return null
                ensureDisplayConfigurationStored()
                val syncStore = SQLiteSyncStore(
                    database = database,
                    credentials = credentials.syncIdentity(),
                    onTasksChanged = { onRemoteTasksChanged() },
                    onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
                )
                SyncRunner(WebDavSyncRunner(
                    client = WebDavClient(credentials),
                    outbox = syncStore,
                    local = syncStore,
                )::synchronize)
            }

            SyncBackend.WORKER_OR_LOCAL -> workerOrLocal?.let(::createSyncCoordinator)
                ?.let { coordinator -> SyncRunner(coordinator::synchronize) }

            null -> null
        }
    }

    /** 调用方应在 IO 线程运行同步；尚未配对时返回 null。 */
    fun createSyncCoordinator(): SyncCoordinator? {
        val credentials = syncCredentialsStore.load() ?: return null
        val webDav = webDavCredentialsStore.load()
        if (resolveSyncBackend(credentials, webDav) != SyncBackend.WORKER_OR_LOCAL) return null
        return createSyncCoordinator(credentials)
    }

    private fun createSyncCoordinator(credentials: SyncCredentials): SyncCoordinator {
        ensureDisplayConfigurationStored()
        val syncStore = SQLiteSyncStore(
            database = database,
            credentials = credentials,
            onTasksChanged = { onRemoteTasksChanged() },
            onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
        )
        return SyncCoordinator(
            transport = createSyncTransport(credentials),
            outbox = syncStore,
            remoteApplyStore = syncStore,
            credential = BearerCredential(credentials.deviceToken),
        )
    }

    private fun createSyncTransport(credentials: SyncCredentials) =
        if (SyncEndpointPolicy.scope(URI(credentials.endpoint)) == SyncEndpointScope.LOCAL_NETWORK) {
            RecoveringLocalNetworkSyncTransport(
                initialEndpoint = credentials.endpoint,
                vaultId = credentials.vaultId,
                resolver = AndroidLocalNetworkServiceResolver(this),
                onEndpointRecovered = { endpoint ->
                    persistRecoveredLocalNetworkEndpoint(credentials, endpoint)
                },
            )
        } else {
            SyncApiClient(credentials.endpoint)
        }

    private fun persistRecoveredLocalNetworkEndpoint(
        expected: SyncCredentials,
        endpoint: String,
    ) {
        val current = syncCredentialsStore.load() ?: return
        if (current.vaultId != expected.vaultId ||
            current.deviceId != expected.deviceId ||
            current.deviceToken != expected.deviceToken
        ) {
            return
        }
        syncCredentialsStore.save(
            SyncCredentials(
                endpoint = endpoint,
                vaultId = current.vaultId,
                deviceId = current.deviceId,
                deviceToken = current.deviceToken,
                vaultKey = current.vaultKey,
            ),
        )
    }

    fun activeSyncBackend(): SyncBackend? = resolveSyncBackend(
        workerOrLocal = syncCredentialsStore.load(),
        webDav = webDavCredentialsStore.load(),
    )

    fun activeSyncTransportMode(): SyncTransportMode? {
        val workerOrLocal = syncCredentialsStore.load()
        val webDav = webDavCredentialsStore.load()
        return SyncTransportModePolicy.resolve(
            backend = resolveSyncBackend(workerOrLocal, webDav),
            workerEndpoint = workerOrLocal?.endpoint,
        )
    }

    fun canSwitchToSavedWorkerOrLocalSync(): Boolean =
        activeSyncBackend() == SyncBackend.WEB_DAV && syncCredentialsStore.load() != null

    private fun resolveSyncBackend(
        workerOrLocal: SyncCredentials?,
        webDav: WebDavCredentials?,
    ): SyncBackend? = syncBackendSelection.resolve(
        hasWorkerOrLocalCredentials = workerOrLocal != null,
        hasWebDavCredentials = webDav != null,
    )

    private fun onRemoteTasksChanged() {
        taskStore.invalidateFromSync()
        TodayWidgetUpdater.updateAllAsync(this)
        TaskReminderScheduler.scheduleAllAsync(this)
    }

    private fun onRemoteDisplayConfigurationChanged(
        payload: com.wootodo.sync.DisplayConfigurationPayload,
    ) {
        DayCounterPreferences.applyRemote(this, payload)
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

    suspend fun configureWebDav(
        credentials: WebDavCredentials,
        replacingWorkerSync: Boolean = false,
    ) = syncRuntime.withExclusiveConfiguration {
        withContext(Dispatchers.IO) {
            val previousWorker = syncCredentialsStore.load()
            val previous = webDavCredentialsStore.load()
            val activeBackend = resolveSyncBackend(previousWorker, previous)
            if (activeBackend == SyncBackend.WORKER_OR_LOCAL && !replacingWorkerSync) {
                throw IllegalStateException("当前已配置其他同步方式，请先确认切换")
            }
            if (replacingWorkerSync && activeBackend != SyncBackend.WORKER_OR_LOCAL) {
                throw IllegalStateException("当前没有可替换的 Worker 或同一网络同步")
            }
            try {
                if (replacingWorkerSync) SyncJobScheduler.cancel(this@WooTodoApplication)
                webDavCredentialsStore.save(credentials)
                ensureDisplayConfigurationStored()
                if (replacingWorkerSync) {
                    SQLiteSyncStore.replaceSyncBinding(
                        database = database,
                        credentials = credentials.syncIdentity(),
                        onTasksChanged = { onRemoteTasksChanged() },
                        onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
                    )
                } else {
                    SQLiteSyncStore(database, credentials.syncIdentity())
                }
                syncBackendSelection.persist(SyncBackend.WEB_DAV)
            } catch (error: Exception) {
                if (previous == null) {
                    webDavCredentialsStore.delete()
                } else {
                    webDavCredentialsStore.save(previous)
                }
                if (previousWorker != null) {
                    syncRuntime.refreshConfiguration(configured = true)
                    SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
                    SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
                }
                throw error
            }
            syncRuntime.refreshConfiguration(configured = true)
            SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
            SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
        }
    }

    suspend fun switchToSavedWorkerOrLocalSync() = syncRuntime.withExclusiveConfiguration {
        withContext(Dispatchers.IO) {
            val credentials = syncCredentialsStore.load()
                ?: throw IllegalStateException("没有可切回的 Worker 或同一网络同步身份")
            val webDav = webDavCredentialsStore.load()
            when (resolveSyncBackend(credentials, webDav)) {
                SyncBackend.WORKER_OR_LOCAL -> return@withContext
                SyncBackend.WEB_DAV -> Unit
                null -> throw IllegalStateException("当前同步方式不可用")
            }
            SyncApiClient(credentials.endpoint)
            SyncJobScheduler.cancel(this@WooTodoApplication)
            ensureDisplayConfigurationStored()
            SQLiteSyncStore.replaceSyncBinding(
                database = database,
                credentials = credentials,
                onTasksChanged = { onRemoteTasksChanged() },
                onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
            )
            syncBackendSelection.persist(SyncBackend.WORKER_OR_LOCAL)
            syncRuntime.refreshConfiguration(configured = true)
            SyncJobScheduler.ensurePeriodic(this@WooTodoApplication)
            SyncJobScheduler.enqueueImmediate(this@WooTodoApplication)
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
                    // 在修改任何旧身份前先验证新端点，确保重绑后不会再因客户端构造失败回滚。
                    SyncApiClient(credentials.endpoint)
                    ensureDisplayConfigurationStored()
                    val previousWebDav = webDavCredentialsStore.load()
                    val previousBackend = resolveSyncBackend(credentials, previousWebDav)
                    if (!completion.replacedExistingCredentials &&
                        previousBackend != SyncBackend.WEB_DAV
                    ) {
                        SQLiteSyncStore(
                            database = database,
                            credentials = credentials,
                            onTasksChanged = { onRemoteTasksChanged() },
                            onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
                        )
                    } else {
                        SyncJobScheduler.cancel(this@WooTodoApplication)
                        SQLiteSyncStore.replaceSyncBinding(
                            database = database,
                            credentials = credentials,
                            onTasksChanged = { onRemoteTasksChanged() },
                            onDisplayConfigurationChanged = { onRemoteDisplayConfigurationChanged(it) },
                        )
                    }
                    syncBackendSelection.persist(SyncBackend.WORKER_OR_LOCAL)
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
                    runCatching { activeSyncBackend() != null }.getOrDefault(false)
                }
                syncRuntime.refreshConfiguration(configured = fallbackConfigured)
                if (fallbackConfigured) {
                    SyncJobScheduler.ensurePeriodic(this)
                    SyncJobScheduler.enqueueImmediate(this)
                } else {
                    SyncJobScheduler.cancel(this)
                }
                throw PairingException.LocalBindingFailed
            }
            syncRuntime.refreshConfiguration(configured = true)
            SyncJobScheduler.ensurePeriodic(this)
            SyncJobScheduler.enqueueImmediate(this)
        }
        applicationScope.launch { syncRuntime.synchronize() }
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
        applicationScope.launch {
            if (runCatching { activeSyncTransportMode() }.getOrNull() ==
                SyncTransportMode.LOCAL_NETWORK
            ) {
                requestAutomaticSync(replacePendingJob = true)
            }
        }
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
        val configured = runCatching { activeSyncBackend() != null }.getOrDefault(false)
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

    override fun onCreate() {
        super.onCreate()
        NotificationHelper.createChannel(this)
        ReminderScheduler.schedule(this)
        getSystemService(ConnectivityManager::class.java)
            ?.registerNetworkCallback(
                NetworkRequest.Builder()
                    .clearCapabilities()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .build(),
                networkCallback,
            )
        applicationScope.launch {
            val configured = runCatching {
                activeSyncBackend() != null
            }.getOrDefault(false)
            try {
                taskRepository.autoPassExpired()
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
