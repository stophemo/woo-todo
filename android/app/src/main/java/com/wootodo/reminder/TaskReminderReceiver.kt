package com.wootodo.reminder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.wootodo.WooTodoApplication
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class TaskReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val taskId = intent?.getStringExtra(EXTRA_TASK_ID) ?: return
        val expectedTriggerMillis = intent.getLongExtra(EXTRA_TRIGGER_MILLIS, Long.MIN_VALUE)
        if (expectedTriggerMillis == Long.MIN_VALUE) return
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val task = (appContext as WooTodoApplication).taskRepository.get(taskId)
                if (task != null) {
                    val shouldNotify = TaskReminderPolicy.triggerAt(task)?.let { trigger ->
                        trigger.toEpochMilli() == expectedTriggerMillis &&
                            !trigger.isAfter(Instant.now().plusSeconds(60))
                    } == true
                    if (shouldNotify) {
                        NotificationHelper.showTaskReminder(appContext, task)
                    }
                }
                TaskReminderScheduler.consume(appContext, taskId, expectedTriggerMillis)
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        const val EXTRA_TASK_ID = "task_reminder_task_id"
        const val EXTRA_TRIGGER_MILLIS = "task_reminder_trigger_millis"
    }
}
