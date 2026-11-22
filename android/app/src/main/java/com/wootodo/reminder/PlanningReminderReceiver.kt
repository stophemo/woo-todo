package com.wootodo.reminder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.wootodo.WooTodoApplication
import com.wootodo.domain.TaskDateRules
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class PlanningReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            val handledDate = TaskDateRules.today()
            if (!ReminderPreferences.load(appContext).enabled) {
                ReminderScheduler.schedule(appContext)
                pendingResult.finish()
                return@launch
            }
            try {
                val repository = (appContext as WooTodoApplication).taskRepository
                val summary = DailyDigestText.summary(repository.allTasks(), handledDate)
                NotificationHelper.showPlanningReminder(appContext, summary)
            } finally {
                ReminderPreferences.markHandled(appContext, handledDate)
                ReminderScheduler.schedule(appContext)
                pendingResult.finish()
            }
        }
    }
}
