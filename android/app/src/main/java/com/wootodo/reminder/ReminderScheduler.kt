package com.wootodo.reminder

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import java.time.ZonedDateTime

object ReminderScheduler {
    private const val REQUEST_CODE = 23_10

    fun schedule(context: Context, now: ZonedDateTime = ZonedDateTime.now()) {
        val appContext = context.applicationContext
        val alarmManager = appContext.getSystemService(AlarmManager::class.java)
        val settings = ReminderPreferences.load(appContext)
        if (!settings.enabled) {
            alarmManager.cancel(alarmPendingIntent(appContext))
            return
        }
        val trigger = ReminderTimePolicy.nextTrigger(
            now,
            ReminderPreferences.lastHandledDate(appContext),
            settings.time,
        )
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            trigger.toInstant().toEpochMilli(),
            alarmPendingIntent(appContext),
        )
    }

    private fun alarmPendingIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            REQUEST_CODE,
            Intent(context, PlanningReminderReceiver::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
}
