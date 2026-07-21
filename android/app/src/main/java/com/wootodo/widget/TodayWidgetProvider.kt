package com.wootodo.widget

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import com.wootodo.R
import com.wootodo.WooTodoApplication
import com.wootodo.display.DayCounterPreferences
import com.wootodo.domain.TaskStatus
import com.wootodo.domain.TaskDateRules
import com.wootodo.domain.TaskTimeType
import com.wootodo.ui.EditTaskActivity
import com.wootodo.ui.MainActivity
import com.wootodo.ui.labelRes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class TodayWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        val pendingResult = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                TodayWidgetUpdater.update(context, appWidgetIds)
            } finally {
                pendingResult.finish()
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_COLLECTION_ITEM) return
        val taskId = intent.getStringExtra(EXTRA_TASK_ID) ?: return
        when (intent.getStringExtra(EXTRA_COMMAND)) {
            COMMAND_COMPLETE -> completeTask(context, taskId)
            COMMAND_EDIT -> context.startActivity(
                Intent(context, EditTaskActivity::class.java).apply {
                    putExtra(EditTaskActivity.EXTRA_TASK_ID, taskId)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
        }
    }

    private fun completeTask(context: Context, taskId: String) {
        val pendingResult = goAsync()
        val appContext = context.applicationContext
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                val repository = (appContext as WooTodoApplication).taskRepository
                if (repository.settle(taskId, TaskStatus.COMPLETED)) {
                    (appContext as WooTodoApplication).notifyLocalMutation()
                }
                TodayWidgetUpdater.updateAll(appContext)
            } finally {
                pendingResult.finish()
            }
        }
    }

    companion object {
        const val ACTION_COLLECTION_ITEM = "com.wootodo.action.WIDGET_ITEM"
        const val EXTRA_COMMAND = "widget_command"
        const val EXTRA_TASK_ID = "widget_task_id"
        const val COMMAND_COMPLETE = "complete"
        const val COMMAND_EDIT = "edit"
    }
}

object TodayWidgetUpdater {
    fun updateAllAsync(context: Context) {
        val appContext = context.applicationContext
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            updateAll(appContext)
        }
    }

    suspend fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val component = android.content.ComponentName(context, TodayWidgetProvider::class.java)
        update(context, manager.getAppWidgetIds(component))
    }

    suspend fun update(context: Context, widgetIds: IntArray) {
        if (widgetIds.isEmpty()) return
        val manager = AppWidgetManager.getInstance(context)

        widgetIds.forEach { widgetId ->
            val remoteViews = RemoteViews(context.packageName, R.layout.widget_today)
            remoteViews.setOnClickPendingIntent(
                R.id.widget_header,
                activityPendingIntent(context, MainActivity::class.java, widgetId),
            )
            remoteViews.setOnClickPendingIntent(
                R.id.widget_add,
                addTaskPendingIntent(context, widgetId),
            )
            val counterText = DayCounterPreferences.displayText(context)
            remoteViews.setTextViewText(R.id.widget_counter, counterText.orEmpty())
            remoteViews.setViewVisibility(
                R.id.widget_counter,
                if (counterText == null) View.GONE else View.VISIBLE,
            )
            remoteViews.setPendingIntentTemplate(
                R.id.widget_list,
                collectionPendingIntent(context, widgetId),
            )
            remoteViews.setRemoteAdapter(
                R.id.widget_list,
                Intent(context, TodayWidgetService::class.java).apply {
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
                    data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
                },
            )
            remoteViews.setEmptyView(R.id.widget_list, R.id.widget_empty)
            manager.updateAppWidget(widgetId, remoteViews)
            manager.notifyAppWidgetViewDataChanged(widgetId, R.id.widget_list)
        }
    }

    private fun collectionPendingIntent(context: Context, widgetId: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            widgetId,
            Intent(context, TodayWidgetProvider::class.java).apply {
                action = TodayWidgetProvider.ACTION_COLLECTION_ITEM
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    private fun addTaskPendingIntent(context: Context, widgetId: Int): PendingIntent =
        PendingIntent.getActivity(
            context,
            widgetId + 10_000,
            Intent(context, EditTaskActivity::class.java).apply {
                putExtra(EditTaskActivity.EXTRA_TIME_TYPE, TaskTimeType.DAY.rawValue)
                putExtra(EditTaskActivity.EXTRA_TARGET_DATE, TaskDateRules.today().toString())
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun activityPendingIntent(
        context: Context,
        activity: Class<*>,
        requestCode: Int,
    ): PendingIntent = PendingIntent.getActivity(
        context,
        requestCode + 20_000,
        Intent(context, activity),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
