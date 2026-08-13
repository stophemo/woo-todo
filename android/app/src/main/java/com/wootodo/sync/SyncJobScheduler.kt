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

    fun enqueueImmediate(context: Context, replaceExisting: Boolean = false): Boolean {
        val mode = activeMode(context) ?: return false
        val scheduler = context.getSystemService(JobScheduler::class.java)
        val pending = scheduler.getPendingJob(IMMEDIATE_JOB_ID)
        if (!replaceExisting && pending?.matches(mode) == true) return true
        if (replaceExisting && pending != null) scheduler.cancel(IMMEDIATE_JOB_ID)
        val info = baseBuilder(context, IMMEDIATE_JOB_ID, mode)
            .setBackoffCriteria(BACKOFF_MILLIS, SyncJobRetryPolicy.backoffPolicy(mode))
            .build()
        return scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
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

    internal fun shouldReschedule(jobId: Int, result: SyncExecutionResult): Boolean =
        SyncJobRetryPolicy.shouldReschedule(
            isImmediate = jobId == IMMEDIATE_JOB_ID,
            retryable = result is SyncExecutionResult.Failed && result.retryable,
        )
}

internal object SyncJobRetryPolicy {
    fun backoffPolicy(mode: SyncTransportMode): Int =
        if (mode == SyncTransportMode.LOCAL_NETWORK) {
            JobInfo.BACKOFF_POLICY_LINEAR
        } else {
            JobInfo.BACKOFF_POLICY_EXPONENTIAL
        }

    fun shouldReschedule(isImmediate: Boolean, retryable: Boolean): Boolean =
        isImmediate && retryable
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
            val shouldRetry = SyncJobScheduler.shouldReschedule(params.jobId, result)
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
