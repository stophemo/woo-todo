package com.wootodo.sync

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.PersistableBundle
import com.wootodo.WooTodoApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap

object SyncJobScheduler {
    private const val IMMEDIATE_JOB_ID = 0x574F01
    private const val PERIODIC_JOB_ID = 0x574F02
    private const val BACKOFF_MILLIS = 30_000L
    private const val PERIOD_MILLIS = 15L * 60L * 1_000L
    private const val FLEX_MILLIS = 5L * 60L * 1_000L
    private const val SCHEDULER_VERSION = 2
    private const val EXTRA_SCHEDULER_VERSION = "sync_scheduler_version"
    private const val EXTRA_TRANSPORT_MODE = "sync_transport_mode"
    private const val RETRY_PREFS_NAME = "sync_job_retry"
    private const val KEY_IMMEDIATE_RETRY_COUNT = "immediate_retry_count"

    fun enqueueImmediate(context: Context, replaceExisting: Boolean = false): Boolean {
        val mode = activeMode(context) ?: return false
        val scheduler = context.getSystemService(JobScheduler::class.java)
        val pending = scheduler.getPendingJob(IMMEDIATE_JOB_ID)
        if (!replaceExisting && pending?.matches(mode) == true) return true
        if (replaceExisting && pending != null) scheduler.cancel(IMMEDIATE_JOB_ID)
        val info = baseBuilder(context, IMMEDIATE_JOB_ID, mode)
            .setBackoffCriteria(BACKOFF_MILLIS, SyncJobRetryPolicy.backoffPolicy(mode))
            .build()
        val scheduled = scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
        if (scheduled) clearImmediateRetryCount(context)
        return scheduled
    }

    fun ensurePeriodic(context: Context): Boolean {
        val mode = activeMode(context) ?: return false
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (scheduler.getPendingJob(PERIODIC_JOB_ID)?.matches(mode) == true) return true
        val info = baseBuilder(context, PERIODIC_JOB_ID, mode)
            .setPeriodic(PERIOD_MILLIS, FLEX_MILLIS)
            .build()
        return scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
    }

    fun cancelImmediate(context: Context) {
        context.getSystemService(JobScheduler::class.java).cancel(IMMEDIATE_JOB_ID)
    }

    fun cancel(context: Context) {
        context.getSystemService(JobScheduler::class.java).apply {
            cancel(IMMEDIATE_JOB_ID)
            cancel(PERIODIC_JOB_ID)
        }
    }

    private fun baseBuilder(
        context: Context,
        jobId: Int,
        mode: SyncTransportMode,
    ): JobInfo.Builder {
        val builder = JobInfo.Builder(
            jobId,
            ComponentName(context.applicationContext, SyncJobService::class.java),
        )
            .setExtras(PersistableBundle().apply {
                putInt(EXTRA_SCHEDULER_VERSION, SCHEDULER_VERSION)
                putString(EXTRA_TRANSPORT_MODE, mode.name)
            })
            .setPersisted(true)
        return builder.setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
    }

    private fun activeMode(context: Context): SyncTransportMode? = runCatching {
        (context.applicationContext as WooTodoApplication).activeSyncTransportMode()
    }.getOrNull()

    private fun JobInfo.matches(mode: SyncTransportMode): Boolean =
        extras.getInt(EXTRA_SCHEDULER_VERSION, 0) == SCHEDULER_VERSION &&
            extras.getString(EXTRA_TRANSPORT_MODE) == mode.name

    /**
     * 决定 Job 失败后是否由系统按退避策略再次调度。连续自动重试超过上限后停止，
     * 只依赖 periodic job、网络恢复回调或下次本地变更重新发起同步。
     */
    internal fun shouldReschedule(
        context: Context,
        jobId: Int,
        result: SyncExecutionResult,
    ): Boolean {
        if (jobId != IMMEDIATE_JOB_ID) return false
        if (result !is SyncExecutionResult.Failed || !result.retryable) {
            if (result is SyncExecutionResult.Succeeded) clearImmediateRetryCount(context)
            return false
        }
        val attempts = immediateRetryCount(context) + 1
        persistImmediateRetryCount(context, attempts)
        return SyncJobRetryPolicy.shouldReschedule(
            isImmediate = true,
            retryable = true,
            retryCount = attempts,
        )
    }

    private fun retryPreferences(context: Context): android.content.SharedPreferences =
        context.applicationContext.getSharedPreferences(RETRY_PREFS_NAME, android.content.Context.MODE_PRIVATE)

    private fun immediateRetryCount(context: Context): Int =
        retryPreferences(context).getInt(KEY_IMMEDIATE_RETRY_COUNT, 0)

    private fun persistImmediateRetryCount(context: Context, count: Int) {
        retryPreferences(context).edit().putInt(KEY_IMMEDIATE_RETRY_COUNT, count).apply()
    }

    private fun clearImmediateRetryCount(context: Context) {
        retryPreferences(context).edit().remove(KEY_IMMEDIATE_RETRY_COUNT).apply()
    }
}

internal object SyncJobRetryPolicy {
    /** 一次由外部事件发起后的最大连续自动重试次数。 */
    const val MAX_IMMEDIATE_RETRIES = 10

    fun backoffPolicy(mode: SyncTransportMode): Int =
        if (mode == SyncTransportMode.LOCAL_NETWORK) {
            JobInfo.BACKOFF_POLICY_LINEAR
        } else {
            JobInfo.BACKOFF_POLICY_EXPONENTIAL
        }

    /**
     * 只有即时同步任务在可重试失败后由系统退避重试；周期任务失败不额外调度。
     * 连续失败计数达到上限后停止，等待外部事件（periodic job、网络恢复、本地变更）再次发起。
     */
    fun shouldReschedule(isImmediate: Boolean, retryable: Boolean, retryCount: Int = 0): Boolean =
        isImmediate && retryable && retryCount < MAX_IMMEDIATE_RETRIES
}

/** 只在系统授予的短时后台窗口执行，不创建前台服务。 */
class SyncJobService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val runningJobs = ConcurrentHashMap<Int, Job>()

    override fun onStartJob(params: JobParameters): Boolean {
        val runtime = (application as WooTodoApplication).syncRuntime
        runningJobs.remove(params.jobId)?.cancel()
        val job = scope.launch(start = CoroutineStart.LAZY) {
            val result = runtime.synchronize()
            val shouldRetry = SyncJobScheduler.shouldReschedule(
                this@SyncJobService,
                params.jobId,
                result,
            )
            runningJobs.remove(params.jobId)
            jobFinished(params, shouldRetry)
        }
        runningJobs[params.jobId] = job
        job.start()
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        runningJobs.remove(params.jobId)?.cancel()
        return true
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
