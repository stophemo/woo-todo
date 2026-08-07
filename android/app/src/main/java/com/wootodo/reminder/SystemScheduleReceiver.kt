package com.wootodo.reminder

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.wootodo.widget.TodayWidgetUpdater

class SystemScheduleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action !in SUPPORTED_ACTIONS) return
        ReminderScheduler.schedule(context)
        TaskReminderScheduler.scheduleAllAsync(context)
        TodayWidgetUpdater.updateAllAsync(context)
    }

    private companion object {
        val SUPPORTED_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_DATE_CHANGED,
        )
    }
}
