package com.wootodo.sync

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
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

    fun enqueueImmediate(context: Context): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (scheduler.getPendingJob(IMMEDIATE_JOB_ID) != null) return true
        val info = baseBuilder(context, IMMEDIATE_JOB_ID)
            .setBackoffCriteria(BACKOFF_MILLIS, JobInfo.BACKOFF_POLICY_EXPONENTIAL)
            .build()
        return scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
    }

    fun ensurePeriodic(context: Context): Boolean {
        val scheduler = context.getSystemService(JobScheduler::class.java)
        if (scheduler.getPendingJob(PERIODIC_JOB_ID) != null) return true
        val info = baseBuilder(context, PERIODIC_JOB_ID)
            .setPeriodic(PERIOD_MILLIS, FLEX_MILLIS)
            .build()
        return scheduler.schedule(info) == JobScheduler.RESULT_SUCCESS
    }

    fun cancel(context: Context) {
        context.getSystemService(JobScheduler::class.java).apply {
            cancel(IMMEDIATE_JOB_ID)
            cancel(PERIODIC_JOB_ID)
        }
    }

    private fun baseBuilder(context: Context, jobId: Int): JobInfo.Builder = JobInfo.Builder(
        jobId,
        ComponentName(context.applicationContext, SyncJobService::class.java),
    )
        .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
        .setPersisted(true)
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
            val shouldRetry = result is SyncExecutionResult.Failed && result.retryable
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
