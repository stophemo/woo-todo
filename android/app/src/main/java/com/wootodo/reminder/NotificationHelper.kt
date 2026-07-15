package com.wootodo.reminder

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.wootodo.R
import com.wootodo.domain.TaskTimeType
import com.wootodo.ui.EditTaskActivity
import java.time.LocalDate

object NotificationHelper {
    private const val CHANNEL_ID = "planning_reminder"
    private const val NOTIFICATION_ID = 2310

    fun createChannel(context: Context) {
        val channel = NotificationChannel(
            CHANNEL_ID,
            context.getString(R.string.reminder_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.reminder_channel_description)
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun showPlanningReminder(context: Context, tomorrow: LocalDate) {
        if (ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS,
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val editIntent = Intent(context, EditTaskActivity::class.java).apply {
            putExtra(EditTaskActivity.EXTRA_TIME_TYPE, TaskTimeType.DAY.rawValue)
            putExtra(EditTaskActivity.EXTRA_TARGET_DATE, tomorrow.toString())
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            NOTIFICATION_ID,
            editIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_app)
            .setContentTitle(context.getString(R.string.reminder_title))
            .setContentText(context.getString(R.string.reminder_text))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_REMINDER)
            .build()
        NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
    }
}
