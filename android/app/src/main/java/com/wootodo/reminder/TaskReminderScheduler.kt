package com.wootodo.reminder

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import com.wootodo.WooTodoApplication
import com.wootodo.domain.Task
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskStatus
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

object TaskReminderPolicy {
    fun triggerAt(task: Task, zoneId: ZoneId = TaskDateRules.zoneId): Instant? {
        val date = task.targetDate ?: return null
        val time = task.reminderTime ?: return null
        if (task.status != TaskStatus.PENDING) return null
        return date.atTime(time).atZone(zoneId).toInstant()
    }
}

object TaskReminderScheduler {
    private const val FILE_NAME = "task_reminder_schedule"
    private const val KEY_IDS = "scheduled_task_ids"
    private const val KEY_TRIGGER_PREFIX = "trigger_"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()

    fun scheduleAllAsync(context: Context) {
        val appContext = context.applicationContext
        scope.launch {
            runCatching { scheduleAll(appContext) }
        }
    }

    suspend fun scheduleAll(context: Context, now: Instant = Instant.now()) {
        val appContext = context.applicationContext
        mutex.withLock {
            val tasks = (appContext as WooTodoApplication).taskRepository.allTasks()
            val previousIds = preferences(appContext).getStringSet(KEY_IDS, emptySet()).orEmpty()
            val currentIds = tasks.mapTo(mutableSetOf()) { it.id }
            (previousIds - currentIds).forEach { cancelLocked(appContext, it) }

            val scheduled = buildSet {
                tasks.forEach { task ->
                    cancelLocked(appContext, task.id)
                    val trigger = TaskReminderPolicy.triggerAt(task) ?: return@forEach
                    if (!trigger.isAfter(now)) return@forEach
                    val triggerMillis = trigger.toEpochMilli()
                    alarmManager(appContext).setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        triggerMillis,
                        pendingIntent(appContext, task.id, triggerMillis),
                    )
                    add(task.id)
                    preferences(appContext).edit()
                        .putLong(triggerKey(task.id), triggerMillis)
                        .apply()
                }
            }
            preferences(appContext).edit().putStringSet(KEY_IDS, scheduled).apply()
        }
    }

    suspend fun cancel(context: Context, taskId: String) {
        mutex.withLock { cancelLocked(context.applicationContext, taskId) }
    }

    /** 消费一个已触发的 generation；过期广播不会取消后来重排的闹钟。 */
    suspend fun consume(
        context: Context,
        taskId: String,
        expectedTriggerMillis: Long,
    ): Boolean = mutex.withLock {
        val appContext = context.applicationContext
        val storedTrigger = preferences(appContext).getLong(triggerKey(taskId), Long.MIN_VALUE)
        if (storedTrigger != expectedTriggerMillis) return@withLock false
        val ids = preferences(appContext).getStringSet(KEY_IDS, emptySet()).orEmpty() - taskId
        preferences(appContext).edit()
            .putStringSet(KEY_IDS, ids)
            .remove(triggerKey(taskId))
            .apply()
        true
    }

    private fun cancelLocked(context: Context, taskId: String) {
        alarmManager(context).cancel(pendingIntent(context, taskId, null))
        val ids = preferences(context).getStringSet(KEY_IDS, emptySet()).orEmpty() - taskId
        preferences(context).edit()
            .putStringSet(KEY_IDS, ids)
            .remove(triggerKey(taskId))
            .apply()
    }

    private fun alarmManager(context: Context): AlarmManager =
        context.getSystemService(AlarmManager::class.java)

    private fun pendingIntent(
        context: Context,
        taskId: String,
        triggerMillis: Long?,
    ): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            taskId.hashCode(),
            Intent(context, TaskReminderReceiver::class.java).apply {
                data = Uri.parse("wootodo://task-reminder/$taskId")
                putExtra(TaskReminderReceiver.EXTRA_TASK_ID, taskId)
                if (triggerMillis != null) {
                    putExtra(TaskReminderReceiver.EXTRA_TRIGGER_MILLIS, triggerMillis)
                }
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun triggerKey(taskId: String): String = KEY_TRIGGER_PREFIX + taskId

    private fun preferences(context: Context) =
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
}
